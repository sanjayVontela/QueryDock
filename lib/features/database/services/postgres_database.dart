import 'dart:async';
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
  final int rowCount;
  final int affectedRows;
  final Duration elapsed;
  final bool rowLimitApplied;

  const PostgresQueryResult({
    required this.columns,
    required this.rows,
    int? rowCount,
    required this.affectedRows,
    required this.elapsed,
    this.rowLimitApplied = false,
  }) : rowCount = rowCount ?? rows.length;
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
  static const schemaRelationsSql = '''
SELECT c.relname
FROM pg_catalog.pg_class c
JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = @schema
  AND c.relkind IN ('r', 'p', 'v', 'm', 'f')
ORDER BY c.relname;
''';

  final PostgresConnectionConfig config;
  final Pool<void> _pool;
  int? _activeBackendPid;
  bool _queryRunning = false;
  final List<DatabaseSchema> _schemaCache = [];
  final Map<String, List<DatabaseTable>> _tableCache = {};
  final Map<String, DatabaseTable> _tableDetailCache = {};

  PostgresDatabase._({required this.config, required Pool<void> pool})
    : _pool = pool;

  static Future<PostgresDatabase> connect(
    PostgresConnectionConfig config,
  ) async {
    final pool = Pool<void>.withEndpoints(
      [_endpoint(config)],
      settings: PoolSettings(
        maxConnectionCount: 4,
        maxConnectionAge: const Duration(minutes: 30),
        maxSessionUse: const Duration(minutes: 10),
        maxQueryCount: 1000,
        applicationName: 'QueryDock',
        connectTimeout: const Duration(seconds: 10),
        queryTimeout: const Duration(minutes: 5),
        sslMode: config.sslMode,
      ),
    );
    await pool.withConnection(
      (connection) => connection.execute('SELECT 1;', ignoreRows: true),
    );
    return PostgresDatabase._(config: config, pool: pool);
  }

  static Endpoint _endpoint(PostgresConnectionConfig config) {
    return Endpoint(
      host: config.host,
      port: config.port,
      database: config.database,
      username: config.username,
      password: config.password.isEmpty ? null : config.password,
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

    final schemaResult = await _pool.execute('''
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

    final tableResult = await _pool.execute(
      Sql.named(schemaRelationsSql),
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

    final metadataResult = await _pool.execute(
      Sql.named('''
SELECT 'column' AS kind,
       a.attname AS name,
       pg_catalog.format_type(a.atttypid, a.atttypmod) AS detail,
       CASE WHEN a.attnotnull THEN 'NO' ELSE 'YES' END AS extra,
       COALESCE(pg_get_expr(ad.adbin, ad.adrelid), '') AS value1,
       CASE a.attidentity
         WHEN 'a' THEN 'ALWAYS'
         WHEN 'd' THEN 'BY DEFAULT'
         ELSE ''
       END AS value2,
       CASE a.attgenerated WHEN 's' THEN 'STORED' ELSE '' END AS value3,
       COALESCE(col_description(a.attrelid, a.attnum), '') AS value4,
       '' AS value5,
       '' AS value6,
       '' AS value7,
       '' AS value8,
       a.attnum AS sort_order
FROM pg_catalog.pg_attribute a
JOIN pg_catalog.pg_class c ON c.oid = a.attrelid
JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
LEFT JOIN pg_catalog.pg_attrdef ad
  ON ad.adrelid = a.attrelid
 AND ad.adnum = a.attnum
WHERE n.nspname = @schema
  AND c.relname = @table
  AND a.attnum > 0
  AND NOT a.attisdropped
UNION ALL
SELECT 'relation',
       c.relname,
       CASE c.relkind
         WHEN 'r' THEN 'Table'
         WHEN 'p' THEN 'Partitioned table'
         WHEN 'v' THEN 'View'
         WHEN 'm' THEN 'Materialized view'
         WHEN 'f' THEN 'Foreign table'
         ELSE 'Relation'
       END,
       r.rolname,
       COALESCE(obj_description(c.oid, 'pg_class'), ''),
       COALESCE(ts.spcname, 'pg_default'),
       CASE c.relpersistence
         WHEN 'u' THEN 'Unlogged'
         WHEN 't' THEN 'Temporary'
         ELSE 'Permanent'
       END,
       GREATEST(c.reltuples::bigint, 0)::text,
       pg_total_relation_size(c.oid)::text,
       pg_relation_size(c.oid)::text,
       pg_indexes_size(c.oid)::text,
       CASE
         WHEN c.relkind IN ('v', 'm') THEN pg_get_viewdef(c.oid, true)
         WHEN c.relkind = 'p' THEN pg_get_partkeydef(c.oid)
         ELSE ''
       END,
       0
FROM pg_catalog.pg_class c
JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
JOIN pg_catalog.pg_roles r ON r.oid = c.relowner
LEFT JOIN pg_catalog.pg_tablespace ts ON ts.oid = c.reltablespace
WHERE n.nspname = @schema
  AND c.relname = @table
UNION ALL
SELECT CASE WHEN con.contype = 'f' THEN 'foreign-key' ELSE 'constraint' END,
       con.conname,
       CASE con.contype
         WHEN 'p' THEN 'PRIMARY KEY'
         WHEN 'u' THEN 'UNIQUE'
         WHEN 'c' THEN 'CHECK'
         WHEN 'x' THEN 'EXCLUDE'
         WHEN 'f' THEN 'FOREIGN KEY'
         ELSE con.contype::text
       END,
       pg_get_constraintdef(con.oid, true),
       COALESCE(ref_ns.nspname, ''),
       COALESCE(ref.relname, ''),
       COALESCE((
         SELECT string_agg(att.attname, chr(31) ORDER BY key_column.ordinality)
         FROM unnest(con.conkey) WITH ORDINALITY key_column(attnum, ordinality)
         JOIN pg_catalog.pg_attribute att
           ON att.attrelid = con.conrelid
          AND att.attnum = key_column.attnum
       ), ''),
       '', '', '', '', '',
       200000
FROM pg_catalog.pg_constraint con
JOIN pg_catalog.pg_class c ON c.oid = con.conrelid
JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
LEFT JOIN pg_catalog.pg_class ref ON ref.oid = con.confrelid
LEFT JOIN pg_catalog.pg_namespace ref_ns ON ref_ns.oid = ref.relnamespace
WHERE n.nspname = @schema
  AND c.relname = @table
UNION ALL
SELECT 'incoming-foreign-key',
       con.conname,
       'FOREIGN KEY',
       pg_get_constraintdef(con.oid, true),
       source_ns.nspname,
       source.relname,
       COALESCE((
         SELECT string_agg(att.attname, chr(31) ORDER BY key_column.ordinality)
         FROM unnest(con.conkey) WITH ORDINALITY key_column(attnum, ordinality)
         JOIN pg_catalog.pg_attribute att
           ON att.attrelid = con.conrelid
          AND att.attnum = key_column.attnum
       ), ''),
       COALESCE((
         SELECT string_agg(att.attname, chr(31) ORDER BY key_column.ordinality)
         FROM unnest(con.confkey) WITH ORDINALITY key_column(attnum, ordinality)
         JOIN pg_catalog.pg_attribute att
           ON att.attrelid = con.confrelid
          AND att.attnum = key_column.attnum
       ), ''),
       '', '', '', '',
       250000
FROM pg_catalog.pg_constraint con
JOIN pg_catalog.pg_class source ON source.oid = con.conrelid
JOIN pg_catalog.pg_namespace source_ns ON source_ns.oid = source.relnamespace
JOIN pg_catalog.pg_class target ON target.oid = con.confrelid
JOIN pg_catalog.pg_namespace target_ns ON target_ns.oid = target.relnamespace
WHERE con.contype = 'f'
  AND target_ns.nspname = @schema
  AND target.relname = @table
  AND con.conrelid <> con.confrelid
UNION ALL
SELECT 'index',
       idx.relname,
       pg_get_indexdef(idx.oid),
       CASE WHEN i.indisunique THEN 'YES' ELSE 'NO' END,
       CASE WHEN i.indisprimary THEN 'YES' ELSE 'NO' END,
       CASE WHEN con.oid IS NOT NULL THEN 'YES' ELSE 'NO' END,
       '', '', '', '', '', '',
       300000
FROM pg_catalog.pg_index i
JOIN pg_catalog.pg_class tbl ON tbl.oid = i.indrelid
JOIN pg_catalog.pg_namespace n ON n.oid = tbl.relnamespace
JOIN pg_catalog.pg_class idx ON idx.oid = i.indexrelid
LEFT JOIN pg_catalog.pg_constraint con ON con.conindid = idx.oid
WHERE n.nspname = @schema
  AND tbl.relname = @table
UNION ALL
SELECT 'trigger',
       trg.tgname,
       pg_get_triggerdef(trg.oid, true),
       CASE trg.tgenabled
         WHEN 'O' THEN 'Enabled'
         WHEN 'D' THEN 'Disabled'
         WHEN 'R' THEN 'Replica'
         WHEN 'A' THEN 'Always'
         ELSE trg.tgenabled::text
       END,
       '', '', '', '', '', '', '', '',
       400000
FROM pg_catalog.pg_trigger trg
JOIN pg_catalog.pg_class c ON c.oid = trg.tgrelid
JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = @schema
  AND c.relname = @table
  AND NOT trg.tgisinternal
ORDER BY sort_order, name;
'''),
      parameters: {'schema': schema, 'table': table},
    );

    final primaryKeys = <String>{};
    final rawColumns =
        <
          ({
            String name,
            String type,
            bool nullable,
            String defaultValue,
            String identity,
            String generated,
            String comment,
          })
        >[];
    final constraints = <DatabaseConstraint>[];
    final indexes = <DatabaseIndex>[];
    final foreignKeys = <DatabaseForeignKey>[];
    final incomingForeignKeys = <DatabaseForeignKey>[];
    final triggers = <DatabaseTrigger>[];
    var relationType = 'Table';
    var owner = '';
    var comment = '';
    var tablespace = '';
    var persistence = 'Permanent';
    var estimatedRows = 0;
    var totalBytes = 0;
    var tableBytes = 0;
    var indexBytes = 0;
    var viewDefinition = '';
    for (final row in metadataResult) {
      final kind = row[0]?.toString() ?? '';
      final name = row[1]?.toString() ?? '';
      final detail = row[2]?.toString() ?? '';
      final extra = row[3]?.toString() ?? '';
      final value1 = row[4]?.toString() ?? '';
      final value2 = row[5]?.toString() ?? '';
      final value3 = row[6]?.toString() ?? '';
      final value4 = row[7]?.toString() ?? '';
      final value5 = row[8]?.toString() ?? '';
      final value6 = row[9]?.toString() ?? '';
      final value7 = row[10]?.toString() ?? '';
      switch (kind) {
        case 'column':
          rawColumns.add((
            name: name,
            type: detail.isEmpty ? 'unknown' : detail,
            nullable: extra == 'YES',
            defaultValue: value1,
            identity: value2,
            generated: value3,
            comment: value4,
          ));
        case 'relation':
          relationType = detail;
          owner = extra;
          comment = value1;
          tablespace = value2;
          persistence = value3;
          estimatedRows = int.tryParse(value4) ?? 0;
          totalBytes = int.tryParse(value5) ?? 0;
          tableBytes = int.tryParse(value6) ?? 0;
          indexBytes = int.tryParse(value7) ?? 0;
          viewDefinition = row[11]?.toString() ?? '';
        case 'constraint':
          constraints.add(
            DatabaseConstraint(name: name, type: detail, definition: extra),
          );
          if (detail == 'PRIMARY KEY') {
            primaryKeys.addAll(
              value3.isEmpty
                  ? _constraintColumns(extra)
                  : value3.split(String.fromCharCode(31)),
            );
          }
        case 'index':
          indexes.add(
            DatabaseIndex(
              name: name,
              definition: detail,
              unique: extra == 'YES',
              primary: value1 == 'YES',
              constraintOwned: value2 == 'YES',
            ),
          );
        case 'foreign-key':
          final columns = _foreignKeyColumns(extra);
          foreignKeys.add(
            DatabaseForeignKey(
              name: name,
              sourceSchema: schema,
              sourceTable: table,
              referencedSchema: value1,
              referencedTable: value2,
              sourceColumns: columns.$1,
              referencedColumns: columns.$2,
              definition: extra,
            ),
          );
        case 'incoming-foreign-key':
          incomingForeignKeys.add(
            DatabaseForeignKey(
              name: name,
              sourceSchema: value1,
              sourceTable: value2,
              referencedSchema: schema,
              referencedTable: table,
              sourceColumns: value3.isEmpty
                  ? _foreignKeyColumns(extra).$1
                  : value3.split(String.fromCharCode(31)),
              referencedColumns: value4.isEmpty
                  ? _foreignKeyColumns(extra).$2
                  : value4.split(String.fromCharCode(31)),
              definition: extra,
            ),
          );
        case 'trigger':
          triggers.add(
            DatabaseTrigger(name: name, enabled: extra, definition: detail),
          );
      }
    }
    final columns = [
      for (final column in rawColumns)
        DatabaseColumn(
          name: column.name,
          dataType: column.type,
          nullable: column.nullable,
          primaryKey: primaryKeys.contains(column.name),
          defaultValue: column.defaultValue,
          identity: column.identity,
          generated: column.generated,
          comment: column.comment,
        ),
    ];

    final ddl = buildTableDdl(
      schema: schema,
      table: table,
      relationType: relationType,
      owner: owner,
      comment: comment,
      tablespace: tablespace,
      persistence: persistence,
      viewDefinition: viewDefinition,
      columns: columns,
      constraints: constraints,
      indexes: indexes,
      foreignKeys: foreignKeys,
      triggers: triggers,
    );
    final loadedTable = DatabaseTable(
      name: table,
      columns: columns,
      ddl: ddl,
      columnsLoaded: true,
      relationType: relationType,
      owner: owner,
      comment: comment,
      tablespace: tablespace,
      persistence: persistence,
      estimatedRows: estimatedRows,
      totalBytes: totalBytes,
      tableBytes: tableBytes,
      indexBytes: indexBytes,
      constraints: constraints,
      indexes: indexes,
      foreignKeys: foreignKeys,
      incomingForeignKeys: incomingForeignKeys,
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
    _queryRunning = true;
    try {
      return await _pool.withConnection((connection) async {
        final pidResult = await connection.execute('SELECT pg_backend_pid();');
        _activeBackendPid = pidResult.first[0] as int;
        final statement = await connection.prepare(effectiveSql.sql);
        try {
          final retainRows = onRowsChunk == null;
          final rows = <List<dynamic>>[];
          final chunk = <List<dynamic>>[];
          var rowCount = 0;
          final completed = Completer<void>();
          final stream = statement.bind(null);
          late final ResultStreamSubscription subscription;
          subscription = stream.listen(
            (row) {
              final values = [for (final value in row) value];
              rowCount++;
              if (retainRows) rows.add(values);
              chunk.add(values);
              if (chunk.length >= chunkSize) {
                onRowsChunk?.call(List<List<dynamic>>.of(chunk));
                chunk.clear();
              }
            },
            onError: completed.completeError,
            onDone: completed.complete,
            cancelOnError: true,
          );
          subscription.pause();
          final schema = await subscription.schema;
          final columns = [
            for (final (index, column) in schema.columns.indexed)
              _columnName(column.columnName, index),
          ];
          onColumns?.call(columns);
          subscription.resume();
          await completed.future;
          if (chunk.isNotEmpty) {
            onRowsChunk?.call(List<List<dynamic>>.of(chunk));
          }
          final affectedRows = await subscription.affectedRows;
          stopwatch.stop();

          if (columns.isEmpty) {
            return PostgresQueryResult(
              columns: const ['Affected Rows'],
              rows: [
                [affectedRows],
              ],
              affectedRows: affectedRows,
              elapsed: stopwatch.elapsed,
            );
          }
          return PostgresQueryResult(
            columns: columns,
            rows: rows,
            rowCount: rowCount,
            affectedRows: affectedRows,
            elapsed: stopwatch.elapsed,
            rowLimitApplied: effectiveSql.limited,
          );
        } finally {
          await statement.dispose();
        }
      });
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
      _activeBackendPid = null;
    }
  }

  Future<int> updateRows(List<PostgresRowUpdate> updates) async {
    if (updates.isEmpty) return 0;

    return _pool.runTx((session) async {
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
    final backendPid = _activeBackendPid;
    if (!_queryRunning || backendPid == null) return false;
    final result = await _pool.execute(
      Sql.named('SELECT pg_cancel_backend(@pid);'),
      parameters: {'pid': backendPid},
    );
    return result.isNotEmpty && result.first[0] == true;
  }

  Future<void> close() async {
    await _pool.close();
  }

  static String _columnName(String? name, int index) {
    if (name != null && name.isNotEmpty) {
      return name;
    }
    return 'column_${index + 1}';
  }

  static Set<String> _constraintColumns(String definition) {
    final match = RegExp(
      r'^(?:PRIMARY KEY|UNIQUE)\s*\((.*)\)',
      caseSensitive: false,
    ).firstMatch(definition);
    if (match == null) return const {};
    return {
      for (final item in match.group(1)!.split(','))
        item.trim().replaceAll(RegExp(r'^"|"$'), '').replaceAll('""', '"'),
    };
  }

  static (List<String>, List<String>) _foreignKeyColumns(String definition) {
    final match = RegExp(
      r'FOREIGN KEY\s*\(([^)]*)\)\s*REFERENCES\s+.+?\s*\(([^)]*)\)',
      caseSensitive: false,
    ).firstMatch(definition);
    if (match == null) return (const [], const []);
    List<String> parse(String value) => [
      for (final item in value.split(','))
        item.trim().replaceAll(RegExp(r'^"|"$'), '').replaceAll('""', '"'),
    ];
    return (parse(match.group(1)!), parse(match.group(2)!));
  }

  static String buildTableDdl({
    required String schema,
    required String table,
    required String relationType,
    required String owner,
    required String comment,
    required String tablespace,
    required String persistence,
    required String viewDefinition,
    required List<DatabaseColumn> columns,
    required List<DatabaseConstraint> constraints,
    required List<DatabaseIndex> indexes,
    required List<DatabaseForeignKey> foreignKeys,
    required List<DatabaseTrigger> triggers,
  }) {
    final qualifiedName =
        '${_quoteIdentifier(schema)}.${_quoteIdentifier(table)}';
    if (relationType == 'View' || relationType == 'Materialized view') {
      final materialized = relationType == 'Materialized view'
          ? 'MATERIALIZED '
          : '';
      return [
        'CREATE ${materialized}VIEW $qualifiedName AS',
        viewDefinition.trim().endsWith(';')
            ? viewDefinition.trim()
            : '${viewDefinition.trim()};',
        if (owner.isNotEmpty)
          'ALTER ${materialized}VIEW $qualifiedName OWNER TO ${_quoteIdentifier(owner)};',
        if (comment.isNotEmpty)
          'COMMENT ON ${materialized}VIEW $qualifiedName IS ${_quoteLiteral(comment)};',
      ].join('\n\n');
    }

    final columnLines = [
      for (final column in columns) '  ${_columnDefinition(column)}',
    ];

    final createPrefix = persistence == 'Unlogged'
        ? 'CREATE UNLOGGED TABLE'
        : 'CREATE TABLE';
    final statements = <String>[
      [
        '$createPrefix $qualifiedName (',
        columnLines.join(',\n'),
        relationType == 'Partitioned table' && viewDefinition.isNotEmpty
            ? ')\nPARTITION BY $viewDefinition;'
            : ');',
      ].join('\n'),
      for (final constraint in constraints)
        'ALTER TABLE $qualifiedName\n'
            '  ADD CONSTRAINT ${_quoteIdentifier(constraint.name)} '
            '${constraint.definition};',
      for (final foreignKey in foreignKeys)
        'ALTER TABLE $qualifiedName\n'
            '  ADD CONSTRAINT ${_quoteIdentifier(foreignKey.name)} '
            '${foreignKey.definition};',
      for (final index in indexes)
        if (!index.constraintOwned) '${_withoutSemicolon(index.definition)};',
      for (final trigger in triggers)
        '${_withoutSemicolon(trigger.definition)};',
      if (owner.isNotEmpty)
        'ALTER TABLE $qualifiedName OWNER TO ${_quoteIdentifier(owner)};',
      if (tablespace.isNotEmpty && tablespace != 'pg_default')
        'ALTER TABLE $qualifiedName SET TABLESPACE ${_quoteIdentifier(tablespace)};',
      if (comment.isNotEmpty)
        'COMMENT ON TABLE $qualifiedName IS ${_quoteLiteral(comment)};',
      for (final column in columns)
        if (column.comment.isNotEmpty)
          'COMMENT ON COLUMN $qualifiedName.${_quoteIdentifier(column.name)} '
              'IS ${_quoteLiteral(column.comment)};',
    ];
    return statements.join('\n\n');
  }

  static String _columnDefinition(DatabaseColumn column) {
    final buffer = StringBuffer()
      ..write(_quoteIdentifier(column.name))
      ..write(' ')
      ..write(column.dataType);
    if (column.identity.isNotEmpty) {
      buffer.write(' GENERATED ${column.identity} AS IDENTITY');
    } else if (column.generated.isNotEmpty && column.defaultValue.isNotEmpty) {
      buffer.write(' GENERATED ALWAYS AS (${column.defaultValue}) STORED');
    } else if (column.defaultValue.isNotEmpty) {
      buffer.write(' DEFAULT ${column.defaultValue}');
    }
    if (!column.nullable) buffer.write(' NOT NULL');
    return buffer.toString();
  }

  static String _withoutSemicolon(String value) {
    final trimmed = value.trim();
    return trimmed.endsWith(';')
        ? trimmed.substring(0, trimmed.length - 1)
        : trimmed;
  }

  static String _quoteLiteral(String value) {
    return "'${value.replaceAll("'", "''")}'";
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
