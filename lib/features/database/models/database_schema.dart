class DatabaseSchema {
  final String name;
  final List<DatabaseTable> tables;
  final bool tablesLoaded;

  const DatabaseSchema({
    required this.name,
    required this.tables,
    this.tablesLoaded = false,
  });

  DatabaseSchema copyWith({
    String? name,
    List<DatabaseTable>? tables,
    bool? tablesLoaded,
  }) {
    return DatabaseSchema(
      name: name ?? this.name,
      tables: tables ?? this.tables,
      tablesLoaded: tablesLoaded ?? this.tablesLoaded,
    );
  }
}

class DatabaseTable {
  final String name;
  final List<DatabaseColumn> columns;
  final String ddl;
  final bool columnsLoaded;

  const DatabaseTable({
    required this.name,
    required this.columns,
    required this.ddl,
    this.columnsLoaded = false,
  });

  DatabaseTable copyWith({
    String? name,
    List<DatabaseColumn>? columns,
    String? ddl,
    bool? columnsLoaded,
  }) {
    return DatabaseTable(
      name: name ?? this.name,
      columns: columns ?? this.columns,
      ddl: ddl ?? this.ddl,
      columnsLoaded: columnsLoaded ?? this.columnsLoaded,
    );
  }
}

class DatabaseColumn {
  final String name;
  final String dataType;
  final bool nullable;

  const DatabaseColumn({
    required this.name,
    required this.dataType,
    required this.nullable,
  });

  String get displayType {
    final nullability = nullable ? 'NULL' : 'NOT NULL';
    return '$dataType $nullability';
  }
}
