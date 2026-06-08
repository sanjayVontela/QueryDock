import '../contracts/database_driver.dart';
import '../models/database_schema.dart';
import '../services/postgres_database.dart';
import 'database_dialects.dart';

class PostgresDriver implements DatabaseDriver<PostgresConnectionConfig> {
  final PostgresConnectionStore store;

  PostgresDriver({PostgresConnectionStore? store})
    : store = store ?? PostgresConnectionStore();

  @override
  DatabaseEngine get engine => DatabaseEngine.postgresql;

  @override
  String get displayName => 'PostgreSQL';

  @override
  DatabaseDialect get dialect => const PostgresDialect();

  @override
  DatabaseCapabilities get capabilities => const DatabaseCapabilities(
    transactions: true,
    queryCancellation: true,
    tableEditing: true,
    csvImport: true,
    objectSearch: true,
    sessionMonitor: true,
    sshTunnel: true,
  );

  @override
  Future<List<PostgresConnectionConfig>> loadProfiles() => store.load();

  @override
  Future<void> saveProfile(PostgresConnectionConfig profile) =>
      store.save(profile);

  @override
  Future<void> deleteProfile(PostgresConnectionConfig profile) =>
      store.delete(profile);

  @override
  Future<DatabaseSession> connect(PostgresConnectionConfig profile) async {
    return PostgresSession(
      profile: profile,
      database: await PostgresDatabase.connect(profile),
      driver: this,
    );
  }
}

class PostgresSession implements DatabaseSession {
  @override
  final PostgresConnectionConfig profile;
  final PostgresDatabase database;
  final PostgresDriver driver;

  const PostgresSession({
    required this.profile,
    required this.database,
    required this.driver,
  });

  @override
  DatabaseCapabilities get capabilities => driver.capabilities;

  @override
  bool get autoCommit => database.autoCommit;

  @override
  bool get transactionActive => database.transactionActive;

  @override
  Future<List<DatabaseSchema>> loadSchemas({bool forceRefresh = false}) =>
      database.loadSchemas(forceRefresh: forceRefresh);

  @override
  Future<List<DatabaseTable>> loadTables(
    String schema, {
    bool forceRefresh = false,
  }) => database.loadSchemaTables(schema, forceRefresh: forceRefresh);

  @override
  Future<DatabaseTable> loadTable(
    String schema,
    String table, {
    bool forceRefresh = false,
  }) => database.loadTableColumns(schema, table, forceRefresh: forceRefresh);

  @override
  Future<List<DatabaseQueryResult>> executeStatements(
    String sql, {
    int maxRows = 5000,
  }) async {
    final results = await database.executeStatements(sql, maxRows: maxRows);
    return results.map(_queryResult).toList(growable: false);
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
  Future<int> updateRows(List<DatabaseRowUpdate> updates) {
    return database.updateRows([
      for (final update in updates)
        PostgresRowUpdate(
          schema: update.schema,
          table: update.table,
          changes: update.changes,
          primaryKey: update.primaryKey,
          originalValues: update.originalValues,
        ),
    ]);
  }

  @override
  Future<int> importRows(
    String schema,
    String table,
    List<String> columns,
    List<List<dynamic>> rows,
  ) => database.importRows(schema, table, columns, rows);

  @override
  Future<List<DatabaseObjectSearchResult>> searchObjects(String query) async {
    return [
      for (final result in await database.searchObjects(query))
        DatabaseObjectSearchResult(
          type: result.type,
          schema: result.schema,
          name: result.name,
          detail: result.detail,
        ),
    ];
  }

  @override
  Future<List<DatabaseSessionInfo>> loadSessions() async {
    return [
      for (final session in await database.loadSessions())
        DatabaseSessionInfo(
          id: session.pid,
          database: session.database,
          username: session.username,
          application: session.application,
          client: session.client,
          state: session.state,
          waitEvent: session.waitEvent,
          queryStarted: session.queryStarted,
          query: session.query,
          lockCount: session.lockCount,
          blockingSessionIds: session.blockingPids,
        ),
    ];
  }

  @override
  Future<bool> cancelSession(int id) => database.cancelSession(id);

  @override
  Future<bool> cancelCurrentQuery() => database.cancelCurrentQuery();

  @override
  Future<void> setAutoCommit(bool enabled) => database.setAutoCommit(enabled);

  @override
  Future<void> commit() => database.commit();

  @override
  Future<void> rollback() => database.rollback();

  @override
  Future<void> close() => database.close();

  DatabaseQueryResult _queryResult(PostgresQueryResult result) {
    return DatabaseQueryResult(
      columns: result.columns,
      rows: result.rows,
      rowCount: result.rowCount,
      affectedRows: result.affectedRows,
      elapsed: result.elapsed,
      rowLimitApplied: result.rowLimitApplied,
    );
  }
}
