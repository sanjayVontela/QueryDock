import 'dart:convert';

import 'package:postgres/postgres.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/database_schema.dart';

class PostgresConnectionConfig {
  final String host;
  final int port;
  final String database;
  final String username;
  final String password;
  final SslMode sslMode;

  const PostgresConnectionConfig({
    required this.host,
    required this.port,
    required this.database,
    required this.username,
    required this.password,
    required this.sslMode,
  });

  String get displayName => '$username@$host:$port/$database';

  Map<String, Object?> toStoredJson() {
    return {
      'host': host,
      'port': port,
      'database': database,
      'username': username,
      'sslMode': sslMode.name,
    };
  }

  static PostgresConnectionConfig? fromStoredJson(Map<String, dynamic> json) {
    final host = json['host']?.toString() ?? '';
    final port = json['port'] is int
        ? json['port'] as int
        : int.tryParse(json['port']?.toString() ?? '');
    final database = json['database']?.toString() ?? '';
    final username = json['username']?.toString() ?? '';
    final sslModeName = json['sslMode']?.toString() ?? SslMode.disable.name;

    if (host.isEmpty || port == null || database.isEmpty || username.isEmpty) {
      return null;
    }

    return PostgresConnectionConfig(
      host: host,
      port: port,
      database: database,
      username: username,
      password: '',
      sslMode: SslMode.values.firstWhere(
        (mode) => mode.name == sslModeName,
        orElse: () => SslMode.disable,
      ),
    );
  }
}

class PostgresConnectionStore {
  static const _storageKey = 'postgres.connection.profiles';

  Future<List<PostgresConnectionConfig>> load() async {
    final preferences = await SharedPreferences.getInstance();
    final encodedProfiles = preferences.getStringList(_storageKey) ?? [];

    return [
      for (final encodedProfile in encodedProfiles)
        ?_decodeProfile(encodedProfile),
    ];
  }

  Future<void> save(PostgresConnectionConfig config) async {
    final preferences = await SharedPreferences.getInstance();
    final existingProfiles = await load();
    final profiles = [
      config,
      for (final profile in existingProfiles)
        if (profile.displayName != config.displayName) profile,
    ];

    await preferences.setStringList(_storageKey, [
      for (final profile in profiles.take(10))
        jsonEncode(profile.toStoredJson()),
    ]);
  }

  PostgresConnectionConfig? _decodeProfile(String encodedProfile) {
    try {
      final decoded = jsonDecode(encodedProfile);
      if (decoded is Map<String, dynamic>) {
        return PostgresConnectionConfig.fromStoredJson(decoded);
      }
    } catch (_) {
      return null;
    }

    return null;
  }
}

class PostgresQueryResult {
  final List<String> columns;
  final List<List<dynamic>> rows;
  final int affectedRows;
  final Duration elapsed;
  final bool rowLimitApplied;

  const PostgresQueryResult({
    required this.columns,
    required this.rows,
    required this.affectedRows,
    required this.elapsed,
    this.rowLimitApplied = false,
  });
}

class PostgresDatabase {
  static const int defaultMaxRows = 10000;
  static const int defaultChunkSize = 500;

  final PostgresConnectionConfig config;
  final Connection _connection;
  final List<DatabaseSchema> _schemaCache = [];
  final Map<String, List<DatabaseTable>> _tableCache = {};
  final Map<String, DatabaseTable> _tableDetailCache = {};

  PostgresDatabase._({required this.config, required Connection connection})
    : _connection = connection;

  static Future<PostgresDatabase> connect(
    PostgresConnectionConfig config,
  ) async {
    final connection = await Connection.open(
      Endpoint(
        host: config.host,
        port: config.port,
        database: config.database,
        username: config.username,
        password: config.password.isEmpty ? null : config.password,
      ),
      settings: ConnectionSettings(
        applicationName: 'DB Viewer',
        connectTimeout: const Duration(seconds: 10),
        queryTimeout: const Duration(minutes: 5),
        sslMode: config.sslMode,
      ),
    );

    return PostgresDatabase._(config: config, connection: connection);
  }

  Future<List<DatabaseSchema>> loadSchemas({bool forceRefresh = false}) async {
    if (_schemaCache.isNotEmpty && !forceRefresh) {
      return List.unmodifiable(_schemaCache);
    }

    if (forceRefresh) {
      _schemaCache.clear();
      _tableCache.clear();
      _tableDetailCache.clear();
    }

    final schemaResult = await _connection.execute('''
SELECT schema_name
FROM information_schema.schemata
WHERE schema_name <> 'information_schema'
  AND schema_name NOT LIKE 'pg_%'
ORDER BY schema_name;
''');

    final schemas = <DatabaseSchema>[];
    for (final row in schemaResult) {
      final schema = row[0]?.toString() ?? '';
      if (schema.isEmpty) continue;
      schemas.add(DatabaseSchema(name: schema, tables: const []));
    }

    _schemaCache
      ..clear()
      ..addAll(schemas);
    return List.unmodifiable(_schemaCache);
  }

  Future<List<DatabaseTable>> loadSchemaTables(
    String schema, {
    bool forceRefresh = false,
  }) async {
    final cacheKey = schema;
    if (_tableCache.containsKey(cacheKey) && !forceRefresh) {
      return List.unmodifiable(_tableCache[cacheKey]!);
    }

    if (forceRefresh) {
      _tableDetailCache.removeWhere((key, value) => key.startsWith('$schema.'));
    }

    final tableResult = await _connection.execute(
      Sql.named('''
SELECT table_name
FROM information_schema.tables
WHERE table_schema = @schema
  AND table_type = 'BASE TABLE'
ORDER BY table_name;
'''),
      parameters: {'schema': schema},
    );

    final tables = [
      for (final row in tableResult)
        DatabaseTable(
          name: row[0]?.toString() ?? '',
          columns: const [],
          ddl: '',
        ),
    ].where((table) => table.name.isNotEmpty).toList();

    _tableCache[cacheKey] = tables;
    _replaceCachedSchema(schema, tables, tablesLoaded: true);
    return List.unmodifiable(tables);
  }

  Future<DatabaseTable> loadTableColumns(
    String schema,
    String table, {
    bool forceRefresh = false,
  }) async {
    final cacheKey = '$schema.$table';
    final cached = _tableDetailCache[cacheKey];
    if (cached != null && !forceRefresh) {
      return cached;
    }

    final columnResult = await _connection.execute(
      Sql.named('''
SELECT c.table_schema,
       c.table_name,
       c.column_name,
       COALESCE(
         CASE
           WHEN c.data_type IN ('character varying', 'character', 'bit varying', 'bit')
             AND c.character_maximum_length IS NOT NULL
             THEN c.data_type || '(' || c.character_maximum_length || ')'
           WHEN c.data_type = 'numeric' AND c.numeric_precision IS NOT NULL
             THEN c.data_type || '(' || c.numeric_precision ||
                  COALESCE(',' || c.numeric_scale, '') || ')'
           ELSE c.data_type
         END,
         c.udt_name
       ) AS display_type,
       c.is_nullable
FROM information_schema.columns c
JOIN information_schema.tables t
  ON t.table_schema = c.table_schema
 AND t.table_name = c.table_name
 AND t.table_type = 'BASE TABLE'
WHERE c.table_schema = @schema
  AND c.table_name = @table
ORDER BY c.table_schema, c.table_name, c.ordinal_position;
'''),
      parameters: {'schema': schema, 'table': table},
    );

    final columns = <DatabaseColumn>[];
    for (final row in columnResult) {
      final column = row[2]?.toString() ?? '';
      final type = row[3]?.toString() ?? 'unknown';
      final nullable = row[4]?.toString() == 'YES';
      if (column.isEmpty) continue;

      columns.add(
        DatabaseColumn(name: column, dataType: type, nullable: nullable),
      );
    }

    final loadedTable = DatabaseTable(
      name: table,
      columns: columns,
      ddl: _buildCreateTableDdl(schema, table, columns),
      columnsLoaded: true,
    );
    _tableDetailCache[cacheKey] = loadedTable;
    _replaceCachedTable(schema, loadedTable);
    return loadedTable;
  }

  Future<PostgresQueryResult> execute(
    String sql, {
    int maxRows = defaultMaxRows,
    int chunkSize = defaultChunkSize,
    void Function(List<String> columns)? onColumns,
    void Function(List<List<dynamic>> rows)? onRowsChunk,
  }) async {
    final stopwatch = Stopwatch()..start();
    final effectiveSql = _limitReadQuery(sql, maxRows);
    final result = await _connection.execute(effectiveSql.sql);
    stopwatch.stop();

    final columns = [
      for (final (index, column) in result.schema.columns.indexed)
        _columnName(column.columnName, index),
    ];
    onColumns?.call(columns);

    if (columns.isEmpty) {
      return PostgresQueryResult(
        columns: const ['Affected Rows'],
        rows: [
          [result.affectedRows],
        ],
        affectedRows: result.affectedRows,
        elapsed: stopwatch.elapsed,
        rowLimitApplied: false,
      );
    }

    final rows = <List<dynamic>>[];
    final chunk = <List<dynamic>>[];
    for (final row in result) {
      final values = [for (final value in row) value];
      rows.add(values);
      chunk.add(values);
      if (chunk.length >= chunkSize) {
        onRowsChunk?.call(List<List<dynamic>>.of(chunk));
        chunk.clear();
        await Future<void>.delayed(Duration.zero);
      }
    }

    if (chunk.isNotEmpty) {
      onRowsChunk?.call(List<List<dynamic>>.of(chunk));
    }

    return PostgresQueryResult(
      columns: columns,
      rows: rows,
      affectedRows: result.affectedRows,
      elapsed: stopwatch.elapsed,
      rowLimitApplied: effectiveSql.limited,
    );
  }

  Future<void> close() => _connection.close();

  static String _columnName(String? name, int index) {
    if (name != null && name.isNotEmpty) {
      return name;
    }
    return 'column_${index + 1}';
  }

  static String _buildCreateTableDdl(
    String schema,
    String table,
    List<DatabaseColumn> columns,
  ) {
    final columnLines = [
      for (final column in columns)
        '  ${_quoteIdentifier(column.name)} ${column.dataType}${column.nullable ? '' : ' NOT NULL'}',
    ];

    return [
      'CREATE TABLE ${_quoteIdentifier(schema)}.${_quoteIdentifier(table)} (',
      columnLines.join(',\n'),
      ');',
    ].join('\n');
  }

  static String _quoteIdentifier(String identifier) {
    return '"${identifier.replaceAll('"', '""')}"';
  }

  void _replaceCachedSchema(
    String schema,
    List<DatabaseTable> tables, {
    required bool tablesLoaded,
  }) {
    final index = _schemaCache.indexWhere((item) => item.name == schema);
    if (index == -1) return;
    _schemaCache[index] = _schemaCache[index].copyWith(
      tables: tables,
      tablesLoaded: tablesLoaded,
    );
  }

  void _replaceCachedTable(String schema, DatabaseTable table) {
    final tables = List<DatabaseTable>.of(_tableCache[schema] ?? const []);
    final index = tables.indexWhere((item) => item.name == table.name);
    if (index == -1) {
      tables.add(table);
    } else {
      tables[index] = table;
    }
    _tableCache[schema] = tables;
    _replaceCachedSchema(schema, tables, tablesLoaded: true);
  }

  static _LimitedSql _limitReadQuery(String sql, int maxRows) {
    final trimmed = sql.trim();
    final withoutSemicolon = trimmed.endsWith(';')
        ? trimmed.substring(0, trimmed.length - 1).trim()
        : trimmed;
    final lower = withoutSemicolon.toLowerCase();
    final readOnly =
        lower.startsWith('select ') ||
        lower.startsWith('with ') ||
        lower.startsWith('values ');

    if (!readOnly) {
      return _LimitedSql(sql: sql, limited: false);
    }

    return _LimitedSql(
      sql:
          'SELECT * FROM (\n$withoutSemicolon\n) AS db_viewer_limited_query LIMIT $maxRows',
      limited: true,
    );
  }
}

class _LimitedSql {
  final String sql;
  final bool limited;

  const _LimitedSql({required this.sql, required this.limited});
}
