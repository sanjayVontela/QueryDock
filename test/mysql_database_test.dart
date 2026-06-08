import 'package:db_viewer/features/database/services/mysql_database.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('MySQL stored profiles exclude passwords and preserve options', () {
    const config = MySqlConnectionConfig(
      name: 'Orders',
      host: 'mysql.example.com',
      port: 3307,
      database: 'orders',
      username: 'reader',
      password: 'secret',
      secure: true,
      folder: 'Production',
      tags: ['critical', 'mysql'],
    );

    final stored = config.toStoredJson();
    final restored = MySqlConnectionConfig.fromStoredJson(stored);

    expect(stored, isNot(contains('password')));
    expect(restored, isNotNull);
    expect(restored!.displayName, 'Orders');
    expect(restored.endpointName, 'reader@mysql.example.com:3307/orders');
    expect(restored.password, isEmpty);
    expect(restored.secure, isTrue);
    expect(restored.folder, 'Production');
    expect(restored.tags, ['critical', 'mysql']);
  });

  test('MySQL endpoint name is used when a profile has no custom name', () {
    const config = MySqlConnectionConfig(
      host: 'localhost',
      database: 'app',
      username: 'root',
      password: '',
    );

    expect(config.displayName, 'root@localhost:3306/app');
  });
}
