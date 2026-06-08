import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:mysql_client_plus/mysql_client_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../contracts/database_driver.dart';
import '../models/database_schema.dart';
import 'postgres_database.dart';

class MySqlConnectionConfig implements DatabaseProfile {
  final String name;
  final String host;
  final int port;
  final String database;
  final String username;
  final String password;
  final bool secure;
  @override
  final bool writeProtected;
  @override
  final String folder;
  @override
  final List<String> tags;

  const MySqlConnectionConfig({
    this.name = '',
    required this.host,
    this.port = 3306,
    required this.database,
    required this.username,
    required this.password,
    this.secure = true,
    this.writeProtected = false,
    this.folder = '',
    this.tags = const [],
  });

  String get endpointName => '$username@$host:$port/$database';
  @override
  String get displayName => name.trim().isEmpty ? endpointName : name.trim();

  @override
  DatabaseEngine get engine => DatabaseEngine.mysql;

  @override
  String get id => endpointName;

  @override
  String get databaseName => database;

  MySqlConnectionConfig copyWith({String? password}) {
    return MySqlConnectionConfig(
      name: name,
      host: host,
      port: port,
      database: database,
      username: username,
      password: password ?? this.password,
      secure: secure,
      writeProtected: writeProtected,
      folder: folder,
      tags: tags,
    );
  }

  Map<String, Object?> toStoredJson() => {
    'name': name,
    'host': host,
    'port': port,
    'database': database,
    'username': username,
    'secure': secure,
    'writeProtected': writeProtected,
    'folder': folder,
    'tags': tags,
  };

  static MySqlConnectionConfig? fromStoredJson(Map<String, dynamic> json) {
    final host = json['host']?.toString() ?? '';
    final database = json['database']?.toString() ?? '';
    final username = json['username']?.toString() ?? '';
    final port = int.tryParse(json['port']?.toString() ?? '') ?? 3306;
    if (host.isEmpty || database.isEmpty || username.isEmpty) return null;
    return MySqlConnectionConfig(
      name: json['name']?.toString() ?? '',
      host: host,
      port: port,
      database: database,
      username: username,
      password: '',
      secure: json['secure'] != false,
      writeProtected: json['writeProtected'] == true,
      folder: json['folder']?.toString() ?? '',
      tags: (json['tags'] as List<dynamic>? ?? const [])
          .map((tag) => tag.toString())
          .where((tag) => tag.isNotEmpty)
          .toList(),
    );
  }
}

class MySqlConnectionStore {
  static const _profilesKey = 'mysql.connection.profiles.v1';
  static const _secureStorage = FlutterSecureStorage();

  const MySqlConnectionStore();

  Future<List<MySqlConnectionConfig>> load() async {
    final preferences = await SharedPreferences.getInstance();
    final profiles = <MySqlConnectionConfig>[];
    for (final encoded
        in preferences.getStringList(_profilesKey) ?? const <String>[]) {
      try {
        final decoded = jsonDecode(encoded);
        if (decoded is! Map<String, dynamic>) continue;
        final config = MySqlConnectionConfig.fromStoredJson(decoded);
        if (config == null) continue;
        final password = await _secureStorage.read(key: _passwordKey(config));
        profiles.add(config.copyWith(password: password ?? ''));
      } catch (_) {
        continue;
      }
    }
    return profiles;
  }

  Future<void> save(MySqlConnectionConfig config) async {
    final preferences = await SharedPreferences.getInstance();
    final existing = await load();
    final profiles = [
      config,
      for (final item in existing)
        if (item.endpointName != config.endpointName) item,
    ];
    await _secureStorage.write(
      key: _passwordKey(config),
      value: config.password,
    );
    await preferences.setStringList(_profilesKey, [
      for (final item in profiles.take(100)) jsonEncode(item.toStoredJson()),
    ]);
  }

  Future<void> delete(MySqlConnectionConfig config) async {
    final preferences = await SharedPreferences.getInstance();
    final existing = await load();
    await _secureStorage.delete(key: _passwordKey(config));
    await preferences.setStringList(_profilesKey, [
      for (final item in existing)
        if (item.endpointName != config.endpointName)
          jsonEncode(item.toStoredJson()),
    ]);
  }

  String _passwordKey(MySqlConnectionConfig config) {
    return 'mysql.password.${base64Url.encode(utf8.encode(config.endpointName))}';
  }
}

class MySqlDatabase {
  final MySqlConnectionConfig config;
  final MySQLConnection _connection;
  int? _activeConnectionId;
  bool _queryRunning = false;

  MySqlDatabase._(this.config, this._connection);

  static Future<MySqlDatabase> connect(MySqlConnectionConfig config) async {
    final connection = await MySQLConnection.createConnection(
      host: config.host,
      port: config.port,
      userName: config.username,
      password: config.password,
      databaseName: config.database,
      secure: config.secure,
    );
    await connection.connect();
    return MySqlDatabase._(config, connection);
  }

  bool get connected => _connection.connected;

  Future<List<DatabaseTable>> loadTables() async {
    final result = await _connection.execute(
      '''
SELECT TABLE_NAME, TABLE_TYPE, COALESCE(TABLE_ROWS, 0), COALESCE(TABLE_COMMENT, '')
FROM information_schema.TABLES
WHERE TABLE_SCHEMA = :database
ORDER BY TABLE_TYPE, TABLE_NAME
''',
      {'database': config.database},
    );
    return [
      for (final row in result.rows)
        DatabaseTable(
          name: row.colAt(0)?.toString() ?? '',
          columns: const [],
          ddl: '',
          relationType: row.colAt(1)?.toString() == 'VIEW' ? 'View' : 'Table',
          comment: row.colAt(3)?.toString() ?? '',
          estimatedRows: int.tryParse(row.colAt(2)?.toString() ?? '') ?? 0,
        ),
    ];
  }

  Future<DatabaseTable> loadTable(String table) async {
    final columnsResult = await _connection.execute(
      '''
SELECT COLUMN_NAME, COLUMN_TYPE, IS_NULLABLE, COLUMN_KEY, COLUMN_DEFAULT,
       EXTRA, COALESCE(COLUMN_COMMENT, '')
FROM information_schema.COLUMNS
WHERE TABLE_SCHEMA = :database AND TABLE_NAME = :table
ORDER BY ORDINAL_POSITION
''',
      {'database': config.database, 'table': table},
    );
    final indexesResult = await _connection.execute(
      '''
SELECT INDEX_NAME, NON_UNIQUE, SEQ_IN_INDEX, COLUMN_NAME
FROM information_schema.STATISTICS
WHERE TABLE_SCHEMA = :database AND TABLE_NAME = :table
ORDER BY INDEX_NAME, SEQ_IN_INDEX
''',
      {'database': config.database, 'table': table},
    );
    final foreignKeysResult = await _connection.execute(
      '''
SELECT CONSTRAINT_NAME, COLUMN_NAME, REFERENCED_TABLE_SCHEMA,
       REFERENCED_TABLE_NAME, REFERENCED_COLUMN_NAME
FROM information_schema.KEY_COLUMN_USAGE
WHERE TABLE_SCHEMA = :database AND TABLE_NAME = :table
  AND REFERENCED_TABLE_NAME IS NOT NULL
ORDER BY CONSTRAINT_NAME, ORDINAL_POSITION
''',
      {'database': config.database, 'table': table},
    );
    final ddlResult = await _connection.execute(
      'SHOW CREATE TABLE `${table.replaceAll('`', '``')}`',
    );
    final ddl = ddlResult.rows.isEmpty
        ? ''
        : ddlResult.rows.first.colAt(1)?.toString() ?? '';

    return DatabaseTable(
      name: table,
      ddl: ddl,
      columnsLoaded: true,
      columns: [
        for (final row in columnsResult.rows)
          DatabaseColumn(
            name: row.colAt(0)?.toString() ?? '',
            dataType: row.colAt(1)?.toString() ?? '',
            nullable: row.colAt(2)?.toString() == 'YES',
            primaryKey: row.colAt(3)?.toString() == 'PRI',
            defaultValue: row.colAt(4)?.toString() ?? '',
            generated: row.colAt(5)?.toString() ?? '',
            comment: row.colAt(6)?.toString() ?? '',
          ),
      ],
      indexes: [
        for (final row in indexesResult.rows)
          DatabaseIndex(
            name: row.colAt(0)?.toString() ?? '',
            definition: row.colAt(3)?.toString() ?? '',
            unique: row.colAt(1)?.toString() == '0',
            primary: row.colAt(0)?.toString() == 'PRIMARY',
          ),
      ],
      foreignKeys: [
        for (final row in foreignKeysResult.rows)
          DatabaseForeignKey(
            name: row.colAt(0)?.toString() ?? '',
            sourceSchema: config.database,
            sourceTable: table,
            sourceColumns: [row.colAt(1)?.toString() ?? ''],
            referencedSchema: row.colAt(2)?.toString() ?? '',
            referencedTable: row.colAt(3)?.toString() ?? '',
            referencedColumns: [row.colAt(4)?.toString() ?? ''],
            definition:
                'FOREIGN KEY (${row.colAt(1)}) REFERENCES '
                '${row.colAt(2)}.${row.colAt(3)} (${row.colAt(4)})',
          ),
      ],
    );
  }

  Future<List<PostgresQueryResult>> execute(String sql) async {
    final stopwatch = Stopwatch()..start();
    _queryRunning = true;
    try {
      _activeConnectionId ??= await _connectionId();
      final raw = await _connection.execute(sql);
      stopwatch.stop();
      return [
        for (final result in raw) _convertResult(result, stopwatch.elapsed),
      ];
    } finally {
      _queryRunning = false;
    }
  }

  PostgresQueryResult _convertResult(IResultSet result, Duration elapsed) {
    final columns = [for (final column in result.cols) column.name];
    final rows = [
      for (final row in result.rows)
        [
          for (var index = 0; index < row.numOfColumns; index++)
            row.colAt(index),
        ],
    ];
    final affectedRows = result.affectedRows.toInt();
    if (columns.isEmpty) {
      return PostgresQueryResult(
        columns: const ['Affected Rows'],
        rows: [
          [affectedRows],
        ],
        affectedRows: affectedRows,
        elapsed: elapsed,
      );
    }
    return PostgresQueryResult(
      columns: columns,
      rows: rows,
      affectedRows: affectedRows,
      elapsed: elapsed,
    );
  }

  Future<void> setAutoCommit(bool enabled) {
    return _connection.execute('SET autocommit = ${enabled ? 1 : 0}');
  }

  Future<void> commit() => _connection.execute('COMMIT');

  Future<void> rollback() => _connection.execute('ROLLBACK');

  Future<int> importRows(
    String table,
    List<String> columns,
    List<List<dynamic>> rows,
  ) async {
    if (columns.isEmpty || rows.isEmpty) return 0;
    final quotedColumns = columns.map(_quoteIdentifier).join(', ');
    var inserted = 0;
    for (var rowIndex = 0; rowIndex < rows.length; rowIndex++) {
      final values = rows[rowIndex];
      final parameters = <String, dynamic>{};
      final placeholders = <String>[];
      for (var columnIndex = 0; columnIndex < columns.length; columnIndex++) {
        final key = 'value_$columnIndex';
        parameters[key] = columnIndex < values.length
            ? values[columnIndex]
            : null;
        placeholders.add(':$key');
      }
      final result = await _connection.execute(
        'INSERT INTO ${_quoteIdentifier(table)} ($quotedColumns) '
        'VALUES (${placeholders.join(', ')})',
        parameters,
      );
      inserted += result.affectedRows.toInt();
    }
    return inserted;
  }

  Future<int> updateRows(List<DatabaseRowUpdate> updates) async {
    var total = 0;
    for (final update in updates) {
      if (update.changes.isEmpty || update.primaryKey.isEmpty) continue;
      final parameters = <String, dynamic>{};
      final assignments = <String>[];
      var index = 0;
      for (final entry in update.changes.entries) {
        final key = 'set_$index';
        assignments.add('${_quoteIdentifier(entry.key)} = :$key');
        parameters[key] = entry.value;
        index++;
      }
      final predicates = <String>[];
      index = 0;
      for (final entry in {
        ...update.primaryKey,
        ...update.originalValues,
      }.entries) {
        final key = 'where_$index';
        final column = _quoteIdentifier(entry.key);
        if (entry.value == null) {
          predicates.add('$column IS NULL');
        } else {
          predicates.add('$column <=> :$key');
          parameters[key] = entry.value;
        }
        index++;
      }
      final result = await _connection.execute(
        'UPDATE ${_quoteIdentifier(update.table)} '
        'SET ${assignments.join(', ')} '
        'WHERE ${predicates.join(' AND ')}',
        parameters,
      );
      final affected = result.affectedRows.toInt();
      if (affected != 1) {
        throw StateError(
          'Row changed or was deleted before save: '
          '${update.schema}.${update.table}',
        );
      }
      total += affected;
    }
    return total;
  }

  Future<List<DatabaseObjectSearchResult>> searchObjects(String query) async {
    final text = query.trim();
    if (text.isEmpty) return const [];
    final result = await _connection.execute(
      '''
SELECT object_type, schema_name, object_name, detail
FROM (
  SELECT CASE WHEN TABLE_TYPE = 'VIEW' THEN 'View' ELSE 'Table' END object_type,
         TABLE_SCHEMA schema_name, TABLE_NAME object_name,
         COALESCE(TABLE_COMMENT, '') detail
  FROM information_schema.TABLES
  WHERE TABLE_SCHEMA = :database
  UNION ALL
  SELECT 'Column', TABLE_SCHEMA, CONCAT(TABLE_NAME, '.', COLUMN_NAME),
         COLUMN_TYPE
  FROM information_schema.COLUMNS
  WHERE TABLE_SCHEMA = :database
  UNION ALL
  SELECT ROUTINE_TYPE, ROUTINE_SCHEMA, ROUTINE_NAME,
         COALESCE(DATA_TYPE, '')
  FROM information_schema.ROUTINES
  WHERE ROUTINE_SCHEMA = :database
) objects
WHERE object_name LIKE :pattern OR detail LIKE :pattern
ORDER BY object_type, schema_name, object_name
LIMIT 250
''',
      {'database': config.database, 'pattern': '%$text%'},
    );
    return [
      for (final row in result.rows)
        DatabaseObjectSearchResult(
          type: row.colAt(0)?.toString() ?? '',
          schema: row.colAt(1)?.toString() ?? '',
          name: row.colAt(2)?.toString() ?? '',
          detail: row.colAt(3)?.toString() ?? '',
        ),
    ];
  }

  Future<List<DatabaseSessionInfo>> loadSessions() async {
    final result = await _connection.execute('''
SELECT ID, COALESCE(DB, ''), USER, COALESCE(HOST, ''), COMMAND,
       COALESCE(STATE, ''), TIME, COALESCE(INFO, '')
FROM information_schema.PROCESSLIST
ORDER BY TIME DESC, ID
''');
    final now = DateTime.now();
    return [
      for (final row in result.rows)
        DatabaseSessionInfo(
          id: int.tryParse(row.colAt(0)?.toString() ?? '') ?? 0,
          database: row.colAt(1)?.toString() ?? '',
          username: row.colAt(2)?.toString() ?? '',
          application: 'MySQL client',
          client: row.colAt(3)?.toString() ?? '',
          state: row.colAt(4)?.toString() ?? '',
          waitEvent: row.colAt(5)?.toString() ?? '',
          queryStarted: now.subtract(
            Duration(
              seconds: int.tryParse(row.colAt(6)?.toString() ?? '') ?? 0,
            ),
          ),
          query: row.colAt(7)?.toString() ?? '',
          lockCount: 0,
          blockingSessionIds: const [],
        ),
    ];
  }

  Future<bool> cancelSession(int id) async {
    final result = await _connection.execute('KILL QUERY $id');
    return result.affectedRows.toInt() >= 0;
  }

  Future<bool> cancelCurrentQuery() async {
    final id = _activeConnectionId;
    if (!_queryRunning || id == null) return false;
    final control = await _newConnection();
    try {
      await control.execute('KILL QUERY $id');
      return true;
    } finally {
      await control.close();
    }
  }

  Future<int> _connectionId() async {
    final result = await _connection.execute('SELECT CONNECTION_ID()');
    return int.tryParse(result.rows.first.colAt(0)?.toString() ?? '') ?? 0;
  }

  Future<MySQLConnection> _newConnection() async {
    final connection = await MySQLConnection.createConnection(
      host: config.host,
      port: config.port,
      userName: config.username,
      password: config.password,
      databaseName: config.database,
      secure: config.secure,
    );
    await connection.connect();
    return connection;
  }

  static String _quoteIdentifier(String value) {
    return '`${value.replaceAll('`', '``')}`';
  }

  Future<void> close() => _connection.close();
}
