import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:postgres/postgres.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/database_schema.dart';

class PostgresConnectionConfig {
  final String name;
  final String host;
  final int port;
  final String database;
  final String username;
  final String password;
  final SslMode sslMode;
  final bool writeProtected;

  const PostgresConnectionConfig({
    this.name = '',
    required this.host,
    required this.port,
    required this.database,
    required this.username,
    required this.password,
    required this.sslMode,
    this.writeProtected = false,
  });

  String get endpointName => '$username@$host:$port/$database';

  String get displayName => name.trim().isEmpty ? endpointName : name.trim();

  PostgresConnectionConfig copyWith({
    String? name,
    String? host,
    int? port,
    String? database,
    String? username,
    String? password,
    SslMode? sslMode,
    bool? writeProtected,
  }) {
    return PostgresConnectionConfig(
      name: name ?? this.name,
      host: host ?? this.host,
      port: port ?? this.port,
      database: database ?? this.database,
      username: username ?? this.username,
      password: password ?? this.password,
      sslMode: sslMode ?? this.sslMode,
      writeProtected: writeProtected ?? this.writeProtected,
    );
  }

  Map<String, Object?> toStoredJson() {
    return {
      'name': name,
      'host': host,
      'port': port,
      'database': database,
      'username': username,
      'sslMode': sslMode.name,
      'writeProtected': writeProtected,
    };
  }

  static PostgresConnectionConfig? fromStoredJson(Map<String, dynamic> json) {
    final host = json['host']?.toString() ?? '';
    final port = json['port'] is int
        ? json['port'] as int
        : int.tryParse(json['port']?.toString() ?? '');
    final database = json['database']?.toString() ?? '';
    final username = json['username']?.toString() ?? '';
    final password = json['password']?.toString() ?? '';
    final name = json['name']?.toString() ?? '';
    final sslModeName = json['sslMode']?.toString() ?? SslMode.disable.name;
    final writeProtected = json['writeProtected'] == true;

    if (host.isEmpty || port == null || database.isEmpty || username.isEmpty) {
      return null;
    }

    return PostgresConnectionConfig(
      name: name,
      host: host,
      port: port,
      database: database,
      username: username,
      password: password,
      sslMode: SslMode.values.firstWhere(
        (mode) => mode.name == sslModeName,
        orElse: () => SslMode.disable,
      ),
      writeProtected: writeProtected,
    );
  }
}

class PostgresConnectionStore {
  static const _storageKey = 'postgres.connection.profiles';
  final ConnectionSecretStore _secretStore;

  PostgresConnectionStore({ConnectionSecretStore? secretStore})
    : _secretStore = secretStore ?? const SecureConnectionSecretStore();

  Future<List<PostgresConnectionConfig>> load() async {
    final preferences = await SharedPreferences.getInstance();
    final encodedProfiles = preferences.getStringList(_storageKey) ?? [];
    final profiles = <PostgresConnectionConfig>[];
    var migratedPlaintextPassword = false;

    for (final encodedProfile in encodedProfiles) {
      final decoded = _decodeProfile(encodedProfile);
      if (decoded == null) continue;
      final storedPassword = await _secretStore.read(decoded.endpointName);
      final password = storedPassword ?? decoded.password;
      if (storedPassword == null && decoded.password.isNotEmpty) {
        await _secretStore.write(decoded.endpointName, decoded.password);
        migratedPlaintextPassword = true;
      }
      profiles.add(decoded.copyWith(password: password));
    }

    if (migratedPlaintextPassword) {
      await _writeProfiles(preferences, profiles);
    }
    return profiles;
  }

  Future<void> save(PostgresConnectionConfig config) async {
    final preferences = await SharedPreferences.getInstance();
    final existingProfiles = await load();
    final profiles = [
      config,
      for (final profile in existingProfiles)
        if (profile.endpointName != config.endpointName) profile,
    ];
    await _secretStore.write(config.endpointName, config.password);
    await _writeProfiles(preferences, profiles.take(10));
  }

  Future<void> delete(PostgresConnectionConfig config) async {
    final preferences = await SharedPreferences.getInstance();
    final existingProfiles = await load();
    final profiles = [
      for (final profile in existingProfiles)
        if (profile.endpointName != config.endpointName) profile,
    ];
    await _secretStore.delete(config.endpointName);
    await _writeProfiles(preferences, profiles);
  }

  Future<void> _writeProfiles(
    SharedPreferences preferences,
    Iterable<PostgresConnectionConfig> profiles,
  ) {
    return preferences.setStringList(_storageKey, [
      for (final profile in profiles) jsonEncode(profile.toStoredJson()),
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

abstract interface class ConnectionSecretStore {
  Future<String?> read(String connectionKey);
  Future<void> write(String connectionKey, String password);
  Future<void> delete(String connectionKey);
}

class SecureConnectionSecretStore implements ConnectionSecretStore {
  static const _storage = FlutterSecureStorage();

  const SecureConnectionSecretStore();

  String _key(String connectionKey) {
    return 'postgres.password.${base64Url.encode(utf8.encode(connectionKey))}';
  }

  @override
  Future<String?> read(String connectionKey) {
    return _storage.read(key: _key(connectionKey));
  }

  @override
  Future<void> write(String connectionKey, String password) {
    if (password.isEmpty) return delete(connectionKey);
    return _storage.write(key: _key(connectionKey), value: password);
  }

  @override
  Future<void> delete(String connectionKey) {
    return _storage.delete(key: _key(connectionKey));
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

class PostgresQueryException implements Exception {
  final ServerException cause;
  final int? position;

  const PostgresQueryException({required this.cause, required this.position});

  @override
  String toString() => cause.toString();
}

class PostgresRowUpdate {
  final String schema;
  final String table;
  final Map<String, Object?> changes;
  final Map<String, Object?> primaryKey;
  final Map<String, Object?> originalValues;

  const PostgresRowUpdate({
    required this.schema,
    required this.table,
    required this.changes,
    required this.primaryKey,
    required this.originalValues,
  });
}

class PostgresRowConflictException implements Exception {
  final String schema;
  final String table;
  final Map<String, Object?> primaryKey;

  const PostgresRowConflictException({
    required this.schema,
    required this.table,
    required this.primaryKey,
  });

  @override
  String toString() {
    return 'Row changed or was deleted before save: $schema.$table '
        '${primaryKey.entries.map((entry) => '${entry.key}=${entry.value}').join(', ')}';
  }
}

class PostgresDatabase {
  static const int defaultMaxRows = 10000;
  static const int defaultChunkSize = 500;

  final PostgresConnectionConfig config;
  final Connection _connection;
  final int _backendPid;
  Connection? _controlConnection;
  bool _queryRunning = false;
  final List<DatabaseSchema> _schemaCache = [];
  final Map<String, List<DatabaseTable>> _tableCache = {};
  final Map<String, DatabaseTable> _tableDetailCache = {};

  PostgresDatabase._({
    required this.config,
    required Connection connection,
    required int backendPid,
  }) : _connection = connection,
       _backendPid = backendPid;

  static Future<PostgresDatabase> connect(
    PostgresConnectionConfig config,
  ) async {
    final connection = await _openConnection(config);
    final pidResult = await connection.execute('SELECT pg_backend_pid();');
    final backendPid = pidResult.first[0] as int;

    return PostgresDatabase._(
      config: config,
      connection: connection,
      backendPid: backendPid,
    );
  }

  static Future<Connection> _openConnection(PostgresConnectionConfig config) {
    return Connection.open(
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

    final primaryKeyResult = await _connection.execute(
      Sql.named('''
SELECT kcu.column_name
FROM information_schema.table_constraints tc
JOIN information_schema.key_column_usage kcu
  ON kcu.constraint_name = tc.constraint_name
 AND kcu.constraint_schema = tc.constraint_schema
WHERE tc.table_schema = @schema
  AND tc.table_name = @table
  AND tc.constraint_type = 'PRIMARY KEY'
ORDER BY kcu.ordinal_position;
'''),
      parameters: {'schema': schema, 'table': table},
    );
    final primaryKeys = {
      for (final row in primaryKeyResult) row[0]?.toString() ?? '',
    };

    final columns = <DatabaseColumn>[];
    for (final row in columnResult) {
      final column = row[2]?.toString() ?? '';
      final type = row[3]?.toString() ?? 'unknown';
      final nullable = row[4]?.toString() == 'YES';
      if (column.isEmpty) continue;

      columns.add(
        DatabaseColumn(
          name: column,
          dataType: type,
          nullable: nullable,
          primaryKey: primaryKeys.contains(column),
        ),
      );
    }

    final constraintResult = await _connection.execute(
      Sql.named('''
SELECT constraint_name, constraint_type
FROM information_schema.table_constraints
WHERE table_schema = @schema
  AND table_name = @table
ORDER BY constraint_type, constraint_name;
'''),
      parameters: {'schema': schema, 'table': table},
    );
    final constraints = [
      for (final row in constraintResult) '${row[0]}  [${row[1]}]',
    ];

    final indexResult = await _connection.execute(
      Sql.named('''
SELECT indexname
FROM pg_indexes
WHERE schemaname = @schema
  AND tablename = @table
ORDER BY indexname;
'''),
      parameters: {'schema': schema, 'table': table},
    );
    final indexes = [for (final row in indexResult) row[0]?.toString() ?? ''];

    final foreignKeyResult = await _connection.execute(
      Sql.named('''
SELECT tc.constraint_name,
       ccu.table_schema,
       ccu.table_name
FROM information_schema.table_constraints tc
JOIN information_schema.constraint_column_usage ccu
  ON ccu.constraint_name = tc.constraint_name
 AND ccu.constraint_schema = tc.constraint_schema
WHERE tc.table_schema = @schema
  AND tc.table_name = @table
  AND tc.constraint_type = 'FOREIGN KEY'
ORDER BY tc.constraint_name;
'''),
      parameters: {'schema': schema, 'table': table},
    );
    final foreignKeys = [
      for (final row in foreignKeyResult) '${row[0]}  -> ${row[1]}.${row[2]}',
    ];

    final triggerResult = await _connection.execute(
      Sql.named('''
SELECT trigger_name, event_manipulation
FROM information_schema.triggers
WHERE event_object_schema = @schema
  AND event_object_table = @table
ORDER BY trigger_name, event_manipulation;
'''),
      parameters: {'schema': schema, 'table': table},
    );
    final triggers = [
      for (final row in triggerResult) '${row[0]}  [${row[1]}]',
    ];

    final loadedTable = DatabaseTable(
      name: table,
      columns: columns,
      ddl: _buildCreateTableDdl(schema, table, columns),
      columnsLoaded: true,
      constraints: constraints,
      indexes: indexes.where((item) => item.isNotEmpty).toList(),
      foreignKeys: foreignKeys,
      triggers: triggers,
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
    late final Result result;
    _queryRunning = true;
    try {
      result = await _connection.execute(effectiveSql.sql);
    } on ServerException catch (error) {
      final position = error.position;
      throw PostgresQueryException(
        cause: error,
        position: position == null
            ? null
            : (position - effectiveSql.positionOffset).clamp(1, sql.length + 1),
      );
    } finally {
      _queryRunning = false;
    }
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

  Future<int> updateRows(List<PostgresRowUpdate> updates) async {
    if (updates.isEmpty) return 0;

    return _connection.runTx((session) async {
      var totalAffected = 0;
      for (final update in updates) {
        final parameters = <String, Object?>{};
        final assignments = <String>[];
        var index = 0;
        for (final entry in update.changes.entries) {
          final parameter = 'set_$index';
          assignments.add('${_quoteIdentifier(entry.key)} = @$parameter');
          parameters[parameter] = entry.value;
          index++;
        }

        final predicates = <String>[];
        index = 0;
        for (final entry in update.primaryKey.entries) {
          final parameter = 'pk_$index';
          predicates.add(
            '${_quoteIdentifier(entry.key)} IS NOT DISTINCT FROM @$parameter',
          );
          parameters[parameter] = entry.value;
          index++;
        }
        for (final entry in update.originalValues.entries) {
          final parameter = 'original_$index';
          predicates.add(
            '${_quoteIdentifier(entry.key)} IS NOT DISTINCT FROM @$parameter',
          );
          parameters[parameter] = entry.value;
          index++;
        }

        final result = await session.execute(
          Sql.named(
            'UPDATE ${_quoteIdentifier(update.schema)}.'
            '${_quoteIdentifier(update.table)} '
            'SET ${assignments.join(', ')} '
            'WHERE ${predicates.join(' AND ')};',
          ),
          parameters: parameters,
        );
        if (result.affectedRows != 1) {
          throw PostgresRowConflictException(
            schema: update.schema,
            table: update.table,
            primaryKey: update.primaryKey,
          );
        }
        totalAffected += result.affectedRows;
      }
      return totalAffected;
    });
  }

  Future<bool> cancelCurrentQuery() async {
    if (!_queryRunning) return false;
    final control = _controlConnection ??= await _openConnection(config);
    final result = await control.execute(
      Sql.named('SELECT pg_cancel_backend(@pid);'),
      parameters: {'pid': _backendPid},
    );
    return result.isNotEmpty && result.first[0] == true;
  }

  Future<void> close() async {
    await _controlConnection?.close();
    await _connection.close();
  }

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
      positionOffset: 'SELECT * FROM (\n'.length,
    );
  }
}

class _LimitedSql {
  final String sql;
  final bool limited;
  final int positionOffset;

  const _LimitedSql({
    required this.sql,
    required this.limited,
    this.positionOffset = 0,
  });
}
