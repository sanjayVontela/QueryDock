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
  final List<String> constraints;
  final List<String> indexes;
  final List<String> foreignKeys;
  final List<String> triggers;

  const DatabaseTable({
    required this.name,
    required this.columns,
    required this.ddl,
    this.columnsLoaded = false,
    this.constraints = const [],
    this.indexes = const [],
    this.foreignKeys = const [],
    this.triggers = const [],
  });

  DatabaseTable copyWith({
    String? name,
    List<DatabaseColumn>? columns,
    String? ddl,
    bool? columnsLoaded,
    List<String>? constraints,
    List<String>? indexes,
    List<String>? foreignKeys,
    List<String>? triggers,
  }) {
    return DatabaseTable(
      name: name ?? this.name,
      columns: columns ?? this.columns,
      ddl: ddl ?? this.ddl,
      columnsLoaded: columnsLoaded ?? this.columnsLoaded,
      constraints: constraints ?? this.constraints,
      indexes: indexes ?? this.indexes,
      foreignKeys: foreignKeys ?? this.foreignKeys,
      triggers: triggers ?? this.triggers,
    );
  }
}

class DatabaseColumn {
  final String name;
  final String dataType;
  final bool nullable;
  final bool primaryKey;

  const DatabaseColumn({
    required this.name,
    required this.dataType,
    required this.nullable,
    this.primaryKey = false,
  });

  String get displayType {
    final nullability = nullable ? 'NULL' : 'NOT NULL';
    return '$dataType $nullability';
  }
}
