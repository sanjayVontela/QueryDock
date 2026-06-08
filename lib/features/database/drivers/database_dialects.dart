import '../contracts/database_driver.dart';

class PostgresDialect implements DatabaseDialect {
  const PostgresDialect();

  @override
  String quoteIdentifier(String value) => '"${value.replaceAll('"', '""')}"';

  @override
  String qualifiedTable(String schema, String table) =>
      '${quoteIdentifier(schema)}.${quoteIdentifier(table)}';

  @override
  String tableDataSql(
    String schema,
    String table, {
    required int limit,
    required int offset,
    String? orderBy,
    bool ascending = true,
    List<String> filters = const [],
  }) {
    return _selectSql(
      qualifiedTable(schema, table),
      limit: limit,
      offset: offset,
      orderBy: orderBy,
      ascending: ascending,
      filters: filters,
    );
  }
}

class MySqlDialect implements DatabaseDialect {
  const MySqlDialect();

  @override
  String quoteIdentifier(String value) => '`${value.replaceAll('`', '``')}`';

  @override
  String qualifiedTable(String schema, String table) =>
      '${quoteIdentifier(schema)}.${quoteIdentifier(table)}';

  @override
  String tableDataSql(
    String schema,
    String table, {
    required int limit,
    required int offset,
    String? orderBy,
    bool ascending = true,
    List<String> filters = const [],
  }) {
    return _selectSql(
      qualifiedTable(schema, table),
      limit: limit,
      offset: offset,
      orderBy: orderBy,
      ascending: ascending,
      filters: filters,
    );
  }
}

class SqliteDialect implements DatabaseDialect {
  const SqliteDialect();

  @override
  String quoteIdentifier(String value) => '"${value.replaceAll('"', '""')}"';

  @override
  String qualifiedTable(String schema, String table) => quoteIdentifier(table);

  @override
  String tableDataSql(
    String schema,
    String table, {
    required int limit,
    required int offset,
    String? orderBy,
    bool ascending = true,
    List<String> filters = const [],
  }) {
    return _selectSql(
      qualifiedTable(schema, table),
      limit: limit,
      offset: offset,
      orderBy: orderBy,
      ascending: ascending,
      filters: filters,
    );
  }
}

String _selectSql(
  String table, {
  required int limit,
  required int offset,
  String? orderBy,
  required bool ascending,
  required List<String> filters,
}) {
  final buffer = StringBuffer('SELECT * FROM $table');
  if (filters.isNotEmpty) {
    buffer.write(' WHERE ${filters.join(' AND ')}');
  }
  if (orderBy != null && orderBy.isNotEmpty) {
    buffer.write(' ORDER BY $orderBy ${ascending ? 'ASC' : 'DESC'}');
  }
  buffer.write(' LIMIT $limit OFFSET $offset;');
  return buffer.toString();
}
