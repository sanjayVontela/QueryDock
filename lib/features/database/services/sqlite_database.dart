import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/sqlite3.dart';

import '../contracts/database_driver.dart';
import '../models/database_schema.dart';
import 'postgres_database.dart';

class SqliteDatabase {
  static const int defaultMaxRows = 5000;

  final String path;

  const SqliteDatabase(this.path);

  String get displayName {
    final separator = Platform.pathSeparator;
    return path.split(separator).last;
  }

  static String ensureDatabaseExtension(String path) {
    final lower = path.toLowerCase();
    if (lower.endsWith('.db') ||
        lower.endsWith('.sqlite') ||
        lower.endsWith('.sqlite3')) {
      return path;
    }
    return '$path.db';
  }

  Future<List<DatabaseTable>> loadTables() {
    return Isolate.run(() => _loadTables(path));
  }

  Future<PostgresQueryResult> execute(
    String sql, {
    int maxRows = defaultMaxRows,
  }) {
    return Isolate.run(() => _execute(path, sql, maxRows));
  }

  Future<List<PostgresQueryResult>> executeStatements(
    String sql, {
    int maxRows = defaultMaxRows,
  }) async {
    final statements = PostgresDatabase.splitSqlStatements(sql);
    final results = <PostgresQueryResult>[];
    for (final statement in statements) {
      results.add(await execute(statement.sql, maxRows: maxRows));
    }
    return results;
  }

  Future<PostgresQueryResult> loadTableData(
    String table, {
    int limit = 500,
    int offset = 0,
  }) {
    final quoted = _quoteIdentifier(table);
    return execute('SELECT * FROM $quoted LIMIT $limit OFFSET $offset;');
  }

  Future<int> importRows(
    String table,
    List<String> columns,
    List<List<dynamic>> rows,
  ) {
    return Isolate.run(() => _importRows(path, table, columns, rows));
  }

  Future<int> updateRows(List<DatabaseRowUpdate> updates) {
    return Isolate.run(() => _updateRows(path, updates));
  }

  Future<List<DatabaseObjectSearchResult>> searchObjects(String query) {
    return Isolate.run(() => _searchObjects(path, query));
  }

  static List<DatabaseTable> _loadTables(String path) {
    final database = sqlite3.open(path);
    try {
      final objects = database.select('''
SELECT name, type, COALESCE(sql, '')
FROM sqlite_master
WHERE type IN ('table', 'view')
  AND name NOT LIKE 'sqlite_%'
ORDER BY type, name;
''');
      return [
        for (final object in objects)
          _loadTable(
            database,
            object['name'] as String,
            object['type'] as String,
            object['sql']?.toString() ?? '',
          ),
      ];
    } finally {
      database.close();
    }
  }

  static DatabaseTable _loadTable(
    Database database,
    String name,
    String type,
    String ddl,
  ) {
    final columns = database.select(
      'PRAGMA table_info(${_quoteIdentifier(name)});',
    );
    final foreignKeys = database.select(
      'PRAGMA foreign_key_list(${_quoteIdentifier(name)});',
    );
    final indexes = database.select(
      'PRAGMA index_list(${_quoteIdentifier(name)});',
    );
    final count = database.select(
      'SELECT COUNT(*) AS count FROM ${_quoteIdentifier(name)};',
    );

    return DatabaseTable(
      name: name,
      ddl: ddl,
      relationType: type == 'view' ? 'View' : 'Table',
      columnsLoaded: true,
      estimatedRows: (count.firstOrNull?['count'] as int?) ?? 0,
      columns: [
        for (final column in columns)
          DatabaseColumn(
            name: column['name']?.toString() ?? '',
            dataType: column['type']?.toString().isEmpty ?? true
                ? 'ANY'
                : column['type'].toString(),
            nullable: (column['notnull'] as int? ?? 0) == 0,
            primaryKey: (column['pk'] as int? ?? 0) > 0,
            defaultValue: column['dflt_value']?.toString() ?? '',
          ),
      ],
      indexes: [
        for (final index in indexes)
          DatabaseIndex(
            name: index['name']?.toString() ?? '',
            definition: '',
            unique: (index['unique'] as int? ?? 0) == 1,
            primary: (index['origin']?.toString() ?? '') == 'pk',
          ),
      ],
      foreignKeys: [
        for (final key in foreignKeys)
          DatabaseForeignKey(
            name: 'fk_${name}_${key['id']}',
            sourceSchema: 'main',
            sourceTable: name,
            sourceColumns: [key['from']?.toString() ?? ''],
            referencedSchema: 'main',
            referencedTable: key['table']?.toString() ?? '',
            referencedColumns: [key['to']?.toString() ?? ''],
            definition:
                'FOREIGN KEY (${key['from']}) REFERENCES ${key['table']} (${key['to']})',
          ),
      ],
    );
  }

  static PostgresQueryResult _execute(String path, String sql, int maxRows) {
    final database = sqlite3.open(path);
    final stopwatch = Stopwatch()..start();
    try {
      final result = database.select(sql);
      stopwatch.stop();
      final rows = [
        for (final row in result.take(maxRows)) List<dynamic>.of(row.values),
      ];
      final columns = result.columnNames;
      if (columns.isEmpty) {
        return PostgresQueryResult(
          columns: const ['Affected Rows'],
          rows: [
            [database.updatedRows],
          ],
          affectedRows: database.updatedRows,
          elapsed: stopwatch.elapsed,
        );
      }
      return PostgresQueryResult(
        columns: List<String>.of(columns),
        rows: rows,
        rowCount: rows.length,
        affectedRows: database.updatedRows,
        elapsed: stopwatch.elapsed,
        rowLimitApplied: result.length > maxRows,
      );
    } finally {
      database.close();
    }
  }

  static int _importRows(
    String path,
    String table,
    List<String> columns,
    List<List<dynamic>> rows,
  ) {
    if (columns.isEmpty || rows.isEmpty) return 0;
    final database = sqlite3.open(path);
    try {
      final columnsSql = columns.map(_quoteIdentifier).join(', ');
      final placeholders = List.filled(columns.length, '?').join(', ');
      final statement = database.prepare(
        'INSERT INTO ${_quoteIdentifier(table)} ($columnsSql) '
        'VALUES ($placeholders)',
      );
      try {
        database.execute('BEGIN');
        for (final row in rows) {
          statement.execute([
            for (var index = 0; index < columns.length; index++)
              index < row.length ? row[index] : null,
          ]);
        }
        database.execute('COMMIT');
        return rows.length;
      } catch (_) {
        database.execute('ROLLBACK');
        rethrow;
      } finally {
        statement.close();
      }
    } finally {
      database.close();
    }
  }

  static int _updateRows(String path, List<DatabaseRowUpdate> updates) {
    if (updates.isEmpty) return 0;
    final database = sqlite3.open(path);
    try {
      var affected = 0;
      database.execute('BEGIN');
      try {
        for (final update in updates) {
          if (update.changes.isEmpty || update.primaryKey.isEmpty) continue;
          final values = <Object?>[];
          final assignments = <String>[];
          for (final entry in update.changes.entries) {
            assignments.add('${_quoteIdentifier(entry.key)} = ?');
            values.add(entry.value);
          }
          final predicates = <String>[];
          for (final entry in {
            ...update.primaryKey,
            ...update.originalValues,
          }.entries) {
            if (entry.value == null) {
              predicates.add('${_quoteIdentifier(entry.key)} IS NULL');
            } else {
              predicates.add('${_quoteIdentifier(entry.key)} IS ?');
              values.add(entry.value);
            }
          }
          database.execute(
            'UPDATE ${_quoteIdentifier(update.table)} '
            'SET ${assignments.join(', ')} '
            'WHERE ${predicates.join(' AND ')}',
            values,
          );
          if (database.updatedRows != 1) {
            throw StateError(
              'Row changed or was deleted before save: ${update.table}',
            );
          }
          affected += database.updatedRows;
        }
        database.execute('COMMIT');
        return affected;
      } catch (_) {
        database.execute('ROLLBACK');
        rethrow;
      }
    } finally {
      database.close();
    }
  }

  static List<DatabaseObjectSearchResult> _searchObjects(
    String path,
    String query,
  ) {
    final text = query.trim();
    if (text.isEmpty) return const [];
    final database = sqlite3.open(path);
    try {
      final pattern = '%$text%';
      final objects = database.select(
        '''
SELECT CASE type WHEN 'view' THEN 'View' ELSE 'Table' END object_type,
       name, COALESCE(sql, '') detail
FROM sqlite_master
WHERE type IN ('table', 'view')
  AND name NOT LIKE 'sqlite_%'
  AND (name LIKE ? OR sql LIKE ?)
ORDER BY type, name
LIMIT 250
''',
        [pattern, pattern],
      );
      final columns = <DatabaseObjectSearchResult>[];
      for (final table in _loadTables(path)) {
        for (final column in table.columns) {
          if (column.name.toLowerCase().contains(text.toLowerCase()) ||
              column.dataType.toLowerCase().contains(text.toLowerCase())) {
            columns.add(
              DatabaseObjectSearchResult(
                type: 'Column',
                schema: 'main',
                name: '${table.name}.${column.name}',
                detail: column.dataType,
              ),
            );
          }
        }
      }
      return [
        for (final object in objects)
          DatabaseObjectSearchResult(
            type: object['object_type']?.toString() ?? '',
            schema: 'main',
            name: object['name']?.toString() ?? '',
            detail: object['detail']?.toString() ?? '',
          ),
        ...columns,
      ];
    } finally {
      database.close();
    }
  }

  static String _quoteIdentifier(String value) {
    return '"${value.replaceAll('"', '""')}"';
  }
}

class SqliteRecentStore {
  static const _key = 'sqlite.recent_databases.v1';
  static const _limit = 20;

  const SqliteRecentStore();

  Future<List<String>> load() async {
    final preferences = await SharedPreferences.getInstance();
    return [
      for (final path in preferences.getStringList(_key) ?? const <String>[])
        if (File(path).existsSync()) path,
    ];
  }

  Future<void> add(String path) async {
    final preferences = await SharedPreferences.getInstance();
    final existing = await load();
    await preferences.setStringList(
      _key,
      [
        path,
        for (final item in existing)
          if (item != path) item,
      ].take(_limit).toList(),
    );
  }

  Future<void> remove(String path) async {
    final preferences = await SharedPreferences.getInstance();
    final existing = await load();
    await preferences.setStringList(
      _key,
      existing.where((item) => item != path).toList(),
    );
  }
}
