import '../contracts/database_driver.dart';
import '../models/database_schema.dart';
import '../services/mysql_database.dart';
import '../services/postgres_database.dart';
import 'database_dialects.dart';

class MySqlDriver implements DatabaseDriver<MySqlConnectionConfig> {
  final MySqlConnectionStore store;

  const MySqlDriver({this.store = const MySqlConnectionStore()});

  @override
  DatabaseEngine get engine => DatabaseEngine.mysql;

  @override
  String get displayName => 'MySQL';

  @override
  DatabaseDialect get dialect => const MySqlDialect();

  @override
  DatabaseCapabilities get capabilities => const DatabaseCapabilities(
    schemas: false,
    transactions: true,
    queryCancellation: true,
    tableEditing: true,
    csvImport: true,
    objectSearch: true,
    sessionMonitor: true,
  );

  @override
  Future<List<MySqlConnectionConfig>> loadProfiles() => store.load();

  @override
  Future<void> saveProfile(MySqlConnectionConfig profile) =>
      store.save(profile);

  @override
  Future<void> deleteProfile(MySqlConnectionConfig profile) =>
      store.delete(profile);

  @override
  Future<DatabaseSession> connect(MySqlConnectionConfig profile) async {
    return MySqlSession(
      profile: profile,
      database: await MySqlDatabase.connect(profile),
      driver: this,
    );
  }
}

class MySqlSession implements DatabaseSession {
  @override
  final MySqlConnectionConfig profile;
  final MySqlDatabase database;
  final MySqlDriver driver;
  bool _autoCommit = true;
  bool _transactionActive = false;

  MySqlSession({
    required this.profile,
    required this.database,
    required this.driver,
  });

  @override
  DatabaseCapabilities get capabilities => driver.capabilities;

  @override
  bool get autoCommit => _autoCommit;

  @override
  bool get transactionActive => _transactionActive;

  @override
  Future<List<DatabaseSchema>> loadSchemas({bool forceRefresh = false}) async {
    return [
      DatabaseSchema(
        name: profile.database,
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
  }) => database.loadTable(table);

  @override
  Future<List<DatabaseQueryResult>> executeStatements(
    String sql, {
    int maxRows = 5000,
  }) async {
    if (!_autoCommit) _transactionActive = true;
    return [
      for (final result in await database.execute(sql))
        _queryResult(result, maxRows),
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
    return _queryResult((await database.execute(sql)).last, limit);
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
  Future<List<DatabaseSessionInfo>> loadSessions() => database.loadSessions();

  @override
  Future<bool> cancelSession(int id) => database.cancelSession(id);

  @override
  Future<bool> cancelCurrentQuery() => database.cancelCurrentQuery();

  @override
  Future<void> setAutoCommit(bool enabled) async {
    if (_autoCommit == enabled) return;
    if (enabled && _transactionActive) {
      throw StateError('Commit or roll back before enabling auto-commit.');
    }
    _autoCommit = enabled;
    await database.setAutoCommit(enabled);
  }

  @override
  Future<void> commit() async {
    await database.commit();
    _transactionActive = false;
  }

  @override
  Future<void> rollback() async {
    await database.rollback();
    _transactionActive = false;
  }

  @override
  Future<void> close() => database.close();

  DatabaseQueryResult _queryResult(PostgresQueryResult result, int maxRows) {
    final rows = result.rows.take(maxRows).toList(growable: false);
    return DatabaseQueryResult(
      columns: result.columns,
      rows: rows,
      rowCount: rows.length,
      affectedRows: result.affectedRows,
      elapsed: result.elapsed,
      rowLimitApplied: result.rows.length > maxRows,
    );
  }
}
