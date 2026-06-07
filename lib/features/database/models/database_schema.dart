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
  final String relationType;
  final String owner;
  final String comment;
  final String tablespace;
  final String persistence;
  final int estimatedRows;
  final int totalBytes;
  final int tableBytes;
  final int indexBytes;
  final List<DatabaseConstraint> constraints;
  final List<DatabaseIndex> indexes;
  final List<DatabaseForeignKey> foreignKeys;
  final List<DatabaseForeignKey> incomingForeignKeys;
  final List<DatabaseTrigger> triggers;

  const DatabaseTable({
    required this.name,
    required this.columns,
    required this.ddl,
    this.columnsLoaded = false,
    this.relationType = 'Table',
    this.owner = '',
    this.comment = '',
    this.tablespace = '',
    this.persistence = 'Permanent',
    this.estimatedRows = 0,
    this.totalBytes = 0,
    this.tableBytes = 0,
    this.indexBytes = 0,
    this.constraints = const [],
    this.indexes = const [],
    this.foreignKeys = const [],
    this.incomingForeignKeys = const [],
    this.triggers = const [],
  });

  DatabaseTable copyWith({
    String? name,
    List<DatabaseColumn>? columns,
    String? ddl,
    bool? columnsLoaded,
    String? relationType,
    String? owner,
    String? comment,
    String? tablespace,
    String? persistence,
    int? estimatedRows,
    int? totalBytes,
    int? tableBytes,
    int? indexBytes,
    List<DatabaseConstraint>? constraints,
    List<DatabaseIndex>? indexes,
    List<DatabaseForeignKey>? foreignKeys,
    List<DatabaseForeignKey>? incomingForeignKeys,
    List<DatabaseTrigger>? triggers,
  }) {
    return DatabaseTable(
      name: name ?? this.name,
      columns: columns ?? this.columns,
      ddl: ddl ?? this.ddl,
      columnsLoaded: columnsLoaded ?? this.columnsLoaded,
      relationType: relationType ?? this.relationType,
      owner: owner ?? this.owner,
      comment: comment ?? this.comment,
      tablespace: tablespace ?? this.tablespace,
      persistence: persistence ?? this.persistence,
      estimatedRows: estimatedRows ?? this.estimatedRows,
      totalBytes: totalBytes ?? this.totalBytes,
      tableBytes: tableBytes ?? this.tableBytes,
      indexBytes: indexBytes ?? this.indexBytes,
      constraints: constraints ?? this.constraints,
      indexes: indexes ?? this.indexes,
      foreignKeys: foreignKeys ?? this.foreignKeys,
      incomingForeignKeys: incomingForeignKeys ?? this.incomingForeignKeys,
      triggers: triggers ?? this.triggers,
    );
  }
}

class DatabaseColumn {
  final String name;
  final String dataType;
  final bool nullable;
  final bool primaryKey;
  final String defaultValue;
  final String identity;
  final String generated;
  final String comment;

  const DatabaseColumn({
    required this.name,
    required this.dataType,
    required this.nullable,
    this.primaryKey = false,
    this.defaultValue = '',
    this.identity = '',
    this.generated = '',
    this.comment = '',
  });

  String get displayType {
    final nullability = nullable ? 'NULL' : 'NOT NULL';
    return '$dataType $nullability';
  }
}

class DatabaseConstraint {
  final String name;
  final String type;
  final String definition;

  const DatabaseConstraint({
    required this.name,
    required this.type,
    required this.definition,
  });

  @override
  String toString() => '$name  [$type]  $definition';
}

class DatabaseIndex {
  final String name;
  final String definition;
  final bool unique;
  final bool primary;
  final bool constraintOwned;

  const DatabaseIndex({
    required this.name,
    required this.definition,
    this.unique = false,
    this.primary = false,
    this.constraintOwned = false,
  });

  @override
  String toString() => name;
}

class DatabaseForeignKey {
  final String name;
  final String sourceSchema;
  final String sourceTable;
  final String referencedSchema;
  final String referencedTable;
  final List<String> sourceColumns;
  final List<String> referencedColumns;
  final String definition;

  const DatabaseForeignKey({
    required this.name,
    this.sourceSchema = '',
    this.sourceTable = '',
    required this.referencedSchema,
    required this.referencedTable,
    this.sourceColumns = const [],
    this.referencedColumns = const [],
    required this.definition,
  });

  @override
  String toString() => '$name  -> $referencedSchema.$referencedTable';
}

class DatabaseTrigger {
  final String name;
  final String enabled;
  final String definition;

  const DatabaseTrigger({
    required this.name,
    required this.enabled,
    required this.definition,
  });

  @override
  String toString() => '$name  [$enabled]';
}
