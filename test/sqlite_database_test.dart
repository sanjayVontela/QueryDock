import 'dart:io';

import 'package:db_viewer/features/database/services/sqlite_database.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory directory;
  late String path;
  late SqliteDatabase database;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('querydock-sqlite-test-');
    path = '${directory.path}${Platform.pathSeparator}sample.sqlite';
    database = SqliteDatabase(path);
  });

  tearDown(() {
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });

  test('executes SQLite statements and returns multiple result sets', () async {
    final results = await database.executeStatements('''
CREATE TABLE users (
  id INTEGER PRIMARY KEY,
  name TEXT NOT NULL
);
INSERT INTO users (name) VALUES ('Ada'), ('Grace');
SELECT id, name FROM users ORDER BY id;
''');

    expect(results, hasLength(3));
    expect(results[1].affectedRows, 2);
    expect(results[2].columns, ['id', 'name']);
    expect(results[2].rows, [
      [1, 'Ada'],
      [2, 'Grace'],
    ]);
  });

  test('loads tables, views, columns, primary keys and foreign keys', () async {
    await database.executeStatements('''
PRAGMA foreign_keys = ON;
CREATE TABLE teams (
  id INTEGER PRIMARY KEY,
  name TEXT NOT NULL
);
CREATE TABLE members (
  id INTEGER PRIMARY KEY,
  team_id INTEGER NOT NULL REFERENCES teams(id),
  email TEXT
);
CREATE VIEW member_emails AS SELECT email FROM members;
''');

    final tables = await database.loadTables();
    final members = tables.singleWhere((table) => table.name == 'members');
    final view = tables.singleWhere((table) => table.name == 'member_emails');

    expect(members.columns.map((column) => column.name), [
      'id',
      'team_id',
      'email',
    ]);
    expect(
      members.columns.singleWhere((column) => column.name == 'id').primaryKey,
      isTrue,
    );
    expect(members.foreignKeys.single.referencedTable, 'teams');
    expect(view.relationType, 'View');
  });

  test('applies the configured result row limit', () async {
    await database.executeStatements('''
CREATE TABLE values_table (value INTEGER);
INSERT INTO values_table VALUES (1), (2), (3);
''');

    final result = await database.execute(
      'SELECT value FROM values_table ORDER BY value;',
      maxRows: 2,
    );

    expect(result.rows, [
      [1],
      [2],
    ]);
    expect(result.rowLimitApplied, isTrue);
  });

  test('new SQLite database names default to the db extension', () {
    expect(SqliteDatabase.ensureDatabaseExtension('database'), 'database.db');
    expect(
      SqliteDatabase.ensureDatabaseExtension('database.sqlite'),
      'database.sqlite',
    );
    expect(
      SqliteDatabase.ensureDatabaseExtension('database.sqlite3'),
      'database.sqlite3',
    );
  });
}
