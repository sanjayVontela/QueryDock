import 'package:db_viewer/features/database/services/postgres_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:postgres/postgres.dart';

void main() {
  test('connection profile preserves alias and credentials', () {
    const config = PostgresConnectionConfig(
      name: 'Reporting',
      host: 'db.example.com',
      port: 5432,
      database: 'analytics',
      username: 'reader',
      password: 'secret',
      sslMode: SslMode.require,
      writeProtected: true,
    );

    final restored = PostgresConnectionConfig.fromStoredJson(
      config.toStoredJson(),
    );

    expect(restored, isNotNull);
    expect(restored!.displayName, 'Reporting');
    expect(restored.endpointName, 'reader@db.example.com:5432/analytics');
    expect(restored.password, 'secret');
    expect(restored.sslMode, SslMode.require);
    expect(restored.writeProtected, isTrue);
  });
}
