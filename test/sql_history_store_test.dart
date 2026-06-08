import 'package:db_viewer/features/workbench/services/workbench_services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('SQL history persists execution details and clears them', () async {
    const store = SqlHistoryStore();
    final entry = SqlHistoryEntry(
      id: 'run-1',
      sql: 'SELECT 1;',
      connection: 'Local',
      startedAt: DateTime.utc(2026, 6, 7, 12),
      elapsedMilliseconds: 42,
      rowCount: 1,
      succeeded: true,
    );

    await store.save([entry]);
    final restored = await store.load();

    expect(restored, hasLength(1));
    expect(restored.single.id, 'run-1');
    expect(restored.single.sql, 'SELECT 1;');
    expect(restored.single.connection, 'Local');
    expect(restored.single.elapsedMilliseconds, 42);
    expect(restored.single.rowCount, 1);
    expect(restored.single.succeeded, isTrue);

    await store.clear();
    expect(await store.load(), isEmpty);
  });

  test('SQL history ignores malformed stored entries', () async {
    SharedPreferences.setMockInitialValues({
      'workbench.sql_history.v1': ['not-json'],
    });

    expect(await const SqlHistoryStore().load(), isEmpty);
  });
}
