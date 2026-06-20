import '../contracts/database_driver.dart';
import '../models/database_schema.dart';
import '../services/db2_database.dart';
import 'database_dialects.dart';

class Db2Driver implements DatabaseDriver<Db2ConnectionConfig> {
  final Db2ConnectionStore store;

  const Db2Driver({this.store = const Db2ConnectionStore()});

  @override
  DatabaseEngine get engine => DatabaseEngine.db2;

  @override
  String get displayName => 'IBM Db2';

  @override
  DatabaseDialect get dialect => const Db2Dialect();

  @override
  DatabaseCapabilities get capabilities => const DatabaseCapabilities(
    schemas: true,
    transactions: true,
    queryCancellation: false,
    tableEditing: true,
    csvImport: true,
    objectSearch: true,
    sessionMonitor: false,
  );

  @override
  Future<List<Db2ConnectionConfig>> loadProfiles() => store.load();

  @override
  Future<void> saveProfile(Db2ConnectionConfig profile) => store.save(profile);

  @override
  Future<void> deleteProfile(Db2ConnectionConfig profile) =>
      store.delete(profile);

  @override
  Future<DatabaseSession> connect(Db2ConnectionConfig profile) async {
    return Db2Session(
      profile: profile,
      database: await Db2BackendDatabase.connect(profile),
      driver: this,
    );
  }
}

class Db2Session implements DatabaseSession {
  @override
  final Db2ConnectionConfig profile;
  final Db2BackendDatabase database;
  final Db2Driver driver;
  bool _autoCommit = true;
  bool _transactionActive = false;

  Db2Session({
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
  Future<List<DatabaseSchema>> loadSchemas({bool forceRefresh = false}) =>
      database.loadSchemas();

  @override
  Future<List<DatabaseTable>> loadTables(
    String schema, {
    bool forceRefresh = false,
  }) => database.loadTables(schema);

  @override
  Future<DatabaseTable> loadTable(
    String schema,
    String table, {
    bool forceRefresh = false,
  }) => database.loadTable(schema, table);

  @override
  Future<List<DatabaseQueryResult>> executeStatements(
    String sql, {
    int maxRows = 5000,
  }) async {
    if (!_autoCommit) _transactionActive = true;
    return database.executeStatements(sql, maxRows: maxRows);
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
  }) {
    return database.loadTableData(
      schema,
      table,
      limit: limit,
      offset: offset,
      orderBy: orderBy,
      ascending: ascending,
      filters: filters,
    );
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
  ) => database.importRows(schema, table, columns, rows);

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
    if (_autoCommit == enabled) return;
    if (enabled && _transactionActive) {
      throw StateError('Commit or roll back before enabling auto-commit.');
    }
    await database.setAutoCommit(enabled);
    _autoCommit = enabled;
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
}
