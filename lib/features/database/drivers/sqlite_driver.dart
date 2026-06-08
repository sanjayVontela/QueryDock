import 'dart:io';

import '../contracts/database_driver.dart';
import '../models/database_schema.dart';
import '../services/sqlite_database.dart';
import 'database_dialects.dart';

class SqliteProfile implements DatabaseProfile {
  final String path;

  const SqliteProfile(this.path);

  @override
  DatabaseEngine get engine => DatabaseEngine.sqlite;

  @override
  String get id => path;

  @override
  String get displayName => path.split(Platform.pathSeparator).last;

  @override
  String get databaseName => displayName;

  @override
  String get folder => '';

  @override
  List<String> get tags => const [];

  @override
  bool get writeProtected => false;
}

class SqliteDriver implements DatabaseDriver<SqliteProfile> {
  final SqliteRecentStore store;

  const SqliteDriver({this.store = const SqliteRecentStore()});

  @override
  DatabaseEngine get engine => DatabaseEngine.sqlite;

  @override
  String get displayName => 'SQLite';

  @override
  DatabaseDialect get dialect => const SqliteDialect();

  @override
  DatabaseCapabilities get capabilities => const DatabaseCapabilities(
    schemas: false,
    queryCancellation: false,
    tableEditing: true,
    csvImport: true,
    objectSearch: true,
    sessionMonitor: false,
    sshTunnel: false,
  );

  @override
  Future<List<SqliteProfile>> loadProfiles() async => [
    for (final path in await store.load()) SqliteProfile(path),
  ];

  @override
  Future<void> saveProfile(SqliteProfile profile) => store.add(profile.path);

  @override
  Future<void> deleteProfile(SqliteProfile profile) =>
      store.remove(profile.path);

  @override
  Future<DatabaseSession> connect(SqliteProfile profile) async => SqliteSession(
    profile: profile,
    database: SqliteDatabase(profile.path),
    driver: this,
  );
}

class SqliteSession implements DatabaseSession {
  @override
  final SqliteProfile profile;
  final SqliteDatabase database;
  final SqliteDriver driver;

  const SqliteSession({
    required this.profile,
    required this.database,
    required this.driver,
  });

  @override
  DatabaseCapabilities get capabilities => driver.capabilities;

  @override
  bool get autoCommit => true;

  @override
  bool get transactionActive => false;

  @override
  Future<List<DatabaseSchema>> loadSchemas({bool forceRefresh = false}) async {
    return [
      DatabaseSchema(
        name: 'main',
        tables: await database.loadTables(),
        tablesLoaded: true,
      ),
    ];
  }

  @override
  Future<List<DatabaseTable>> loadTables(
    String schema, {
    bool forceRefresh = false,
  }) => database.loadTables();

  @override
  Future<DatabaseTable> loadTable(
    String schema,
    String table, {
    bool forceRefresh = false,
  }) async {
    return (await database.loadTables()).firstWhere(
      (metadata) => metadata.name == table,
    );
  }

  @override
  Future<List<DatabaseQueryResult>> executeStatements(
    String sql, {
    int maxRows = 5000,
  }) async {
    return [
      for (final result in await database.executeStatements(
        sql,
        maxRows: maxRows,
      ))
        _queryResult(result),
    ];
  }

  @override
  Future<DatabaseQueryResult> loadTableData(
    String schema,
    String table, {
    int limit = 500,
    int offset = 0,
    String? orderBy,
    bool ascending = true,
    List<String> filters = const [],
  }) async {
    final sql = driver.dialect.tableDataSql(
      schema,
      table,
      limit: limit,
      offset: offset,
      orderBy: orderBy == null ? null : driver.dialect.quoteIdentifier(orderBy),
      ascending: ascending,
      filters: filters,
    );
    return _queryResult(await database.execute(sql, maxRows: limit));
  }

  @override
  Future<int> updateRows(List<DatabaseRowUpdate> updates) =>
      database.updateRows(updates);

  @override
  Future<int> importRows(
    String schema,
    String table,
    List<String> columns,
    List<List<dynamic>> rows,
  ) => database.importRows(table, columns, rows);

  @override
  Future<List<DatabaseObjectSearchResult>> searchObjects(String query) =>
      database.searchObjects(query);

  @override
  Future<List<DatabaseSessionInfo>> loadSessions() async => const [];

  @override
  Future<bool> cancelSession(int id) async => false;

  @override
  Future<bool> cancelCurrentQuery() async => false;

  @override
  Future<void> setAutoCommit(bool enabled) async {
    if (!enabled) {
      throw UnsupportedError('SQLite transaction mode is not available yet.');
    }
  }

  @override
  Future<void> commit() async {}

  @override
  Future<void> rollback() async {}

  @override
  Future<void> close() async {}

  DatabaseQueryResult _queryResult(dynamic result) {
    return DatabaseQueryResult(
      columns: result.columns as List<String>,
      rows: result.rows as List<List<dynamic>>,
      rowCount: result.rowCount as int,
      affectedRows: result.affectedRows as int,
      elapsed: result.elapsed as Duration,
      rowLimitApplied: result.rowLimitApplied as bool,
    );
  }
}
