import 'package:db_viewer/features/database/services/postgres_database.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('schema discovery includes all PostgreSQL relation types', () {
    final sql = PostgresDatabase.schemaRelationsSql;

    expect(sql, contains("'r'"));
    expect(sql, contains("'p'"));
    expect(sql, contains("'v'"));
    expect(sql, contains("'m'"));
    expect(sql, contains("'f'"));
    expect(sql, contains('ORDER BY c.relname'));
  });
}
