import 'package:db_viewer/features/database/models/database_schema.dart';
import 'package:db_viewer/features/workbench/services/sql_autocomplete.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const engine = SqlAutocompleteEngine();
  const users = DatabaseTable(
    name: 'user_details',
    columnsLoaded: true,
    columns: [
      DatabaseColumn(
        name: 'user_id',
        dataType: 'integer',
        nullable: false,
        primaryKey: true,
      ),
      DatabaseColumn(name: 'email', dataType: 'varchar(255)', nullable: false),
    ],
    ddl: '',
  );
  const schemas = [
    DatabaseSchema(name: 'app', tablesLoaded: true, tables: [users]),
  ];

  test('completes SQL keywords', () {
    final result = engine.build(sql: 'sel', cursor: 3, schemas: schemas);

    expect(result.options.first.label, 'SELECT');
    expect(result.options.first.text, 'SELECT');
  });

  test('completes schema tables with generated aliases', () {
    final result = engine.build(sql: 'app.', cursor: 4, schemas: schemas);

    expect(result.options.single.label, 'app.user_details');
    expect(result.options.single.text, 'app.user_details ud');
  });

  test('completes columns for aliases', () {
    const sql = 'SELECT ud. FROM app.user_details ud';
    final cursor = sql.indexOf(' FROM');
    final result = engine.build(sql: sql, cursor: cursor, schemas: schemas);

    expect(
      result.options.map((option) => option.label),
      containsAll(['ud.user_id', 'ud.email']),
    );
  });

  test('requests table metadata before completing alias columns', () {
    const unloadedSchemas = [
      DatabaseSchema(
        name: 'app',
        tablesLoaded: true,
        tables: [DatabaseTable(name: 'user_details', columns: [], ddl: '')],
      ),
    ];
    const sql = 'SELECT ud. FROM app.user_details ud';
    final result = engine.build(
      sql: sql,
      cursor: sql.indexOf(' FROM'),
      schemas: unloadedSchemas,
    );

    expect(result.options, isEmpty);
    expect(result.metadataRequest?.schema, 'app');
    expect(result.metadataRequest?.table?.name, 'user_details');
  });
}
