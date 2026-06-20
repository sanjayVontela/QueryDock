import '../models/database_schema.dart';

enum DatabaseEngine { postgresql, mysql, sqlite, db2 }

class DatabaseCapabilities {
  final bool schemas;
  final bool transactions;
  final bool queryCancellation;
  final bool tableEditing;
  final bool csvImport;
  final bool objectSearch;
  final bool sessionMonitor;
  final bool diagrams;
  final bool sshTunnel;
  final bool multipleResultSets;

  const DatabaseCapabilities({
    this.schemas = true,
    this.transactions = false,
    this.queryCancellation = false,
    this.tableEditing = false,
    this.csvImport = false,
    this.objectSearch = false,
    this.sessionMonitor = false,
    this.diagrams = true,
    this.sshTunnel = false,
    this.multipleResultSets = true,
  });
}

abstract interface class DatabaseProfile {
  DatabaseEngine get engine;
  String get id;
  String get displayName;
  String get databaseName;
  String get folder;
  List<String> get tags;
  bool get writeProtected;
}

class DatabaseQueryResult {
  final List<String> columns;
  final List<List<dynamic>> rows;
  final int rowCount;
  final int affectedRows;
  final Duration elapsed;
  final bool rowLimitApplied;

  const DatabaseQueryResult({
    required this.columns,
    required this.rows,
    int? rowCount,
    required this.affectedRows,
    required this.elapsed,
    this.rowLimitApplied = false,
  }) : rowCount = rowCount ?? rows.length;
}

class DatabaseObjectSearchResult {
  final String type;
  final String schema;
  final String name;
  final String detail;

  const DatabaseObjectSearchResult({
    required this.type,
    required this.schema,
    required this.name,
    required this.detail,
  });
}

class DatabaseSessionInfo {
  final int id;
  final String database;
  final String username;
  final String application;
  final String client;
  final String state;
  final String waitEvent;
  final DateTime? queryStarted;
  final String query;
  final int lockCount;
  final List<int> blockingSessionIds;

  const DatabaseSessionInfo({
    required this.id,
    required this.database,
    required this.username,
    required this.application,
    required this.client,
    required this.state,
    required this.waitEvent,
    required this.queryStarted,
    required this.query,
    required this.lockCount,
    required this.blockingSessionIds,
  });
}

class DatabaseRowUpdate {
  final String schema;
  final String table;
  final Map<String, Object?> changes;
  final Map<String, Object?> primaryKey;
  final Map<String, Object?> originalValues;

  const DatabaseRowUpdate({
    required this.schema,
    required this.table,
    required this.changes,
    required this.primaryKey,
    required this.originalValues,
  });
}

abstract interface class DatabaseSession {
  DatabaseProfile get profile;
  DatabaseCapabilities get capabilities;
  bool get autoCommit;
  bool get transactionActive;

  Future<List<DatabaseSchema>> loadSchemas({bool forceRefresh = false});
  Future<List<DatabaseTable>> loadTables(
    String schema, {
    bool forceRefresh = false,
  });
  Future<DatabaseTable> loadTable(
    String schema,
    String table, {
    bool forceRefresh = false,
  });
  Future<List<DatabaseQueryResult>> executeStatements(
    String sql, {
    int maxRows = 5000,
  });
  Future<DatabaseQueryResult> loadTableData(
    String schema,
    String table, {
    int limit = 500,
    int offset = 0,
    String? orderBy,
    bool ascending = true,
    List<String> filters = const [],
  });
  Future<int> updateRows(List<DatabaseRowUpdate> updates);
  Future<int> importRows(
    String schema,
    String table,
    List<String> columns,
    List<List<dynamic>> rows,
  );
  Future<List<DatabaseObjectSearchResult>> searchObjects(String query);
  Future<List<DatabaseSessionInfo>> loadSessions();
  Future<bool> cancelSession(int id);
  Future<bool> cancelCurrentQuery();
  Future<void> setAutoCommit(bool enabled);
  Future<void> commit();
  Future<void> rollback();
  Future<void> close();
}

abstract interface class DatabaseDialect {
  String quoteIdentifier(String value);
  String qualifiedTable(String schema, String table);
  String tableDataSql(
    String schema,
    String table, {
    required int limit,
    required int offset,
    String? orderBy,
    bool ascending = true,
    List<String> filters = const [],
  });
}

abstract interface class DatabaseDriver<P extends DatabaseProfile> {
  DatabaseEngine get engine;
  String get displayName;
  DatabaseCapabilities get capabilities;
  DatabaseDialect get dialect;
  Future<List<P>> loadProfiles();
  Future<void> saveProfile(P profile);
  Future<void> deleteProfile(P profile);
  Future<DatabaseSession> connect(P profile);
}
