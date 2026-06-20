import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../contracts/database_driver.dart';
import '../models/database_schema.dart';

class Db2ConnectionConfig implements DatabaseProfile {
  final String name;
  final String host;
  final int port;
  final String database;
  final String username;
  final String password;
  final String backendUrl;
  @override
  final bool writeProtected;
  @override
  final String folder;
  @override
  final List<String> tags;

  const Db2ConnectionConfig({
    this.name = '',
    required this.host,
    this.port = 50000,
    required this.database,
    required this.username,
    required this.password,
    this.backendUrl = 'http://127.0.0.1:8792',
    this.writeProtected = false,
    this.folder = '',
    this.tags = const [],
  });

  String get endpointName => '$username@$host:$port/$database';

  @override
  String get displayName => name.trim().isEmpty ? endpointName : name.trim();

  @override
  DatabaseEngine get engine => DatabaseEngine.db2;

  @override
  String get id => endpointName;

  @override
  String get databaseName => database;

  Db2ConnectionConfig copyWith({String? password}) {
    return Db2ConnectionConfig(
      name: name,
      host: host,
      port: port,
      database: database,
      username: username,
      password: password ?? this.password,
      backendUrl: backendUrl,
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
    'backendUrl': backendUrl,
    'writeProtected': writeProtected,
    'folder': folder,
    'tags': tags,
  };

  static Db2ConnectionConfig? fromStoredJson(Map<String, dynamic> json) {
    final host = json['host']?.toString() ?? '';
    final database = json['database']?.toString() ?? '';
    final username = json['username']?.toString() ?? '';
    final port = int.tryParse(json['port']?.toString() ?? '') ?? 50000;
    if (host.isEmpty || database.isEmpty || username.isEmpty) return null;
    return Db2ConnectionConfig(
      name: json['name']?.toString() ?? '',
      host: host,
      port: port,
      database: database,
      username: username,
      password: '',
      backendUrl: json['backendUrl']?.toString() ?? 'http://127.0.0.1:8792',
      writeProtected: json['writeProtected'] == true,
      folder: json['folder']?.toString() ?? '',
      tags: (json['tags'] as List<dynamic>? ?? const [])
          .map((tag) => tag.toString())
          .where((tag) => tag.isNotEmpty)
          .toList(),
    );
  }
}

class Db2ConnectionStore {
  static const _profilesKey = 'db2.connection.profiles.v1';
  static const _secureStorage = FlutterSecureStorage();

  const Db2ConnectionStore();

  Future<List<Db2ConnectionConfig>> load() async {
    final preferences = await SharedPreferences.getInstance();
    final profiles = <Db2ConnectionConfig>[];
    for (final encoded
        in preferences.getStringList(_profilesKey) ?? const <String>[]) {
      try {
        final decoded = jsonDecode(encoded);
        if (decoded is! Map<String, dynamic>) continue;
        final config = Db2ConnectionConfig.fromStoredJson(decoded);
        if (config == null) continue;
        final password = await _secureStorage.read(key: _passwordKey(config));
        profiles.add(config.copyWith(password: password ?? ''));
      } catch (_) {
        continue;
      }
    }
    return profiles;
  }

  Future<void> save(Db2ConnectionConfig config) async {
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

  Future<void> delete(Db2ConnectionConfig config) async {
    final preferences = await SharedPreferences.getInstance();
    final existing = await load();
    await _secureStorage.delete(key: _passwordKey(config));
    await preferences.setStringList(_profilesKey, [
      for (final item in existing)
        if (item.endpointName != config.endpointName)
          jsonEncode(item.toStoredJson()),
    ]);
  }

  String _passwordKey(Db2ConnectionConfig config) {
    return 'db2.password.${base64Url.encode(utf8.encode(config.endpointName))}';
  }
}

class Db2BackendDatabase {
  final Db2ConnectionConfig config;
  final String sessionId;
  final HttpClient _client;

  Db2BackendDatabase._({
    required this.config,
    required this.sessionId,
    required HttpClient client,
  }) : _client = client;

  static Future<Db2BackendDatabase> connect(Db2ConnectionConfig config) async {
    final client = HttpClient();
    final response = await _post(client, config.backendUrl, '/connect', {
      'host': config.host,
      'port': config.port,
      'database': config.database,
      'username': config.username,
      'password': config.password,
    });
    final sessionId = response['sessionId']?.toString();
    if (sessionId == null || sessionId.isEmpty) {
      client.close(force: true);
      throw StateError('DB2 backend did not return a session id.');
    }
    return Db2BackendDatabase._(
      config: config,
      sessionId: sessionId,
      client: client,
    );
  }

  Future<List<DatabaseSchema>> loadSchemas() async {
    final response = await _postSession('/schemas');
    return [
      for (final item in response['schemas'] as List<dynamic>? ?? const [])
        _schemaFromJson(item as Map<String, dynamic>),
    ];
  }

  Future<List<DatabaseTable>> loadTables(String schema) async {
    final response = await _postSession('/tables', {'schema': schema});
    return [
      for (final item in response['tables'] as List<dynamic>? ?? const [])
        _tableFromJson(item as Map<String, dynamic>),
    ];
  }

  Future<DatabaseTable> loadTable(String schema, String table) async {
    final response = await _postSession('/table', {
      'schema': schema,
      'table': table,
    });
    return _tableFromJson(response['table'] as Map<String, dynamic>);
  }

  Future<List<DatabaseQueryResult>> executeStatements(
    String sql, {
    int maxRows = 5000,
  }) async {
    final response = await _postSession('/query', {
      'sql': sql,
      'maxRows': maxRows,
    });
    return [
      for (final item in response['results'] as List<dynamic>? ?? const [])
        _resultFromJson(item as Map<String, dynamic>),
    ];
  }

  Future<DatabaseQueryResult> loadTableData(
    String schema,
    String table, {
    int limit = 500,
    int offset = 0,
    String? orderBy,
    bool ascending = true,
    List<String> filters = const [],
  }) async {
    final response = await _postSession('/table-data', {
      'schema': schema,
      'table': table,
      'limit': limit,
      'offset': offset,
      'orderBy': orderBy,
      'ascending': ascending,
      'filters': filters,
    });
    return _resultFromJson(response['result'] as Map<String, dynamic>);
  }

  Future<int> updateRows(List<DatabaseRowUpdate> updates) async {
    final response = await _postSession('/update-rows', {
      'updates': [
        for (final update in updates)
          {
            'schema': update.schema,
            'table': update.table,
            'changes': update.changes,
            'primaryKey': update.primaryKey,
            'originalValues': update.originalValues,
          },
      ],
    });
    return int.tryParse(response['affectedRows']?.toString() ?? '') ?? 0;
  }

  Future<int> importRows(
    String schema,
    String table,
    List<String> columns,
    List<List<dynamic>> rows,
  ) async {
    final response = await _postSession('/import-rows', {
      'schema': schema,
      'table': table,
      'columns': columns,
      'rows': rows,
    });
    return int.tryParse(response['affectedRows']?.toString() ?? '') ?? 0;
  }

  Future<List<DatabaseObjectSearchResult>> searchObjects(String query) async {
    final response = await _postSession('/search', {'query': query});
    return [
      for (final item in response['results'] as List<dynamic>? ?? const [])
        DatabaseObjectSearchResult(
          type: item['type']?.toString() ?? '',
          schema: item['schema']?.toString() ?? '',
          name: item['name']?.toString() ?? '',
          detail: item['detail']?.toString() ?? '',
        ),
    ];
  }

  Future<void> setAutoCommit(bool enabled) async {
    await _postSession('/autocommit', {'enabled': enabled});
  }

  Future<void> commit() => _postSession('/commit').then((_) {});

  Future<void> rollback() => _postSession('/rollback').then((_) {});

  Future<void> close() async {
    try {
      await _postSession('/close');
    } finally {
      _client.close(force: true);
    }
  }

  Future<Map<String, dynamic>> _postSession(
    String path, [
    Map<String, Object?> body = const {},
  ]) {
    return _post(_client, config.backendUrl, path, {
      'sessionId': sessionId,
      ...body,
    });
  }

  static Future<Map<String, dynamic>> _post(
    HttpClient client,
    String backendUrl,
    String path,
    Map<String, Object?> body,
  ) async {
    final base = Uri.parse(backendUrl);
    final request = await client.postUrl(base.resolve(path));
    request.headers.contentType = ContentType.json;
    request.write(jsonEncode(body));
    final response = await request.close();
    final text = await response.transform(utf8.decoder).join();
    final decoded = text.isEmpty ? <String, dynamic>{} : jsonDecode(text);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final message = decoded is Map
          ? decoded['error']?.toString() ?? text
          : text;
      throw StateError(message);
    }
    if (decoded is Map<String, dynamic>) return decoded;
    throw StateError('DB2 backend returned an invalid response.');
  }

  DatabaseSchema _schemaFromJson(Map<String, dynamic> json) {
    return DatabaseSchema(
      name: json['name']?.toString() ?? '',
      tablesLoaded: json['tablesLoaded'] == true,
      tables: [
        for (final item in json['tables'] as List<dynamic>? ?? const [])
          _tableFromJson(item as Map<String, dynamic>),
      ],
    );
  }

  DatabaseTable _tableFromJson(Map<String, dynamic> json) {
    return DatabaseTable(
      name: json['name']?.toString() ?? '',
      ddl: json['ddl']?.toString() ?? '',
      relationType: json['relationType']?.toString() ?? 'Table',
      owner: json['owner']?.toString() ?? '',
      comment: json['comment']?.toString() ?? '',
      estimatedRows: int.tryParse(json['estimatedRows']?.toString() ?? '') ?? 0,
      columnsLoaded: json['columnsLoaded'] == true,
      columns: [
        for (final item in json['columns'] as List<dynamic>? ?? const [])
          _columnFromJson(item as Map<String, dynamic>),
      ],
      constraints: [
        for (final item in json['constraints'] as List<dynamic>? ?? const [])
          DatabaseConstraint(
            name: item['name']?.toString() ?? '',
            type: item['type']?.toString() ?? '',
            definition: item['definition']?.toString() ?? '',
          ),
      ],
      indexes: [
        for (final item in json['indexes'] as List<dynamic>? ?? const [])
          DatabaseIndex(
            name: item['name']?.toString() ?? '',
            definition: item['definition']?.toString() ?? '',
            unique: item['unique'] == true,
            primary: item['primary'] == true,
          ),
      ],
      foreignKeys: [
        for (final item in json['foreignKeys'] as List<dynamic>? ?? const [])
          _foreignKeyFromJson(item as Map<String, dynamic>),
      ],
    );
  }

  DatabaseColumn _columnFromJson(Map<String, dynamic> json) {
    return DatabaseColumn(
      name: json['name']?.toString() ?? '',
      dataType: json['dataType']?.toString() ?? '',
      nullable: json['nullable'] != false,
      primaryKey: json['primaryKey'] == true,
      defaultValue: json['defaultValue']?.toString() ?? '',
      identity: json['identity']?.toString() ?? '',
      generated: json['generated']?.toString() ?? '',
      comment: json['comment']?.toString() ?? '',
    );
  }

  DatabaseForeignKey _foreignKeyFromJson(Map<String, dynamic> json) {
    return DatabaseForeignKey(
      name: json['name']?.toString() ?? '',
      sourceSchema: json['sourceSchema']?.toString() ?? '',
      sourceTable: json['sourceTable']?.toString() ?? '',
      sourceColumns: [
        for (final item in json['sourceColumns'] as List<dynamic>? ?? const [])
          item.toString(),
      ],
      referencedSchema: json['referencedSchema']?.toString() ?? '',
      referencedTable: json['referencedTable']?.toString() ?? '',
      referencedColumns: [
        for (final item
            in json['referencedColumns'] as List<dynamic>? ?? const [])
          item.toString(),
      ],
      definition: json['definition']?.toString() ?? '',
    );
  }

  DatabaseQueryResult _resultFromJson(Map<String, dynamic> json) {
    return DatabaseQueryResult(
      columns: [
        for (final item in json['columns'] as List<dynamic>? ?? const [])
          item.toString(),
      ],
      rows: [
        for (final row in json['rows'] as List<dynamic>? ?? const [])
          List<dynamic>.of(row as List<dynamic>),
      ],
      rowCount: int.tryParse(json['rowCount']?.toString() ?? ''),
      affectedRows: int.tryParse(json['affectedRows']?.toString() ?? '') ?? 0,
      elapsed: Duration(
        milliseconds: int.tryParse(json['elapsedMs']?.toString() ?? '') ?? 0,
      ),
      rowLimitApplied: json['rowLimitApplied'] == true,
    );
  }
}
