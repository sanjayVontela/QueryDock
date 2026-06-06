import 'package:db_viewer/features/database/services/postgres_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:postgres/postgres.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('connection profile JSON excludes credentials', () {
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
    expect(config.toStoredJson(), isNot(contains('password')));
    expect(restored.password, isEmpty);
    expect(restored.sslMode, SslMode.require);
    expect(restored.writeProtected, isTrue);
  });

  test('connection store keeps password in secret storage', () async {
    final secrets = _MemorySecretStore();
    final store = PostgresConnectionStore(secretStore: secrets);
    const config = PostgresConnectionConfig(
      name: 'Production',
      host: 'prod.example.com',
      port: 5432,
      database: 'app',
      username: 'reader',
      password: 'top-secret',
      sslMode: SslMode.require,
    );

    await store.save(config);
    final preferences = await SharedPreferences.getInstance();
    expect(
      preferences.getStringList('postgres.connection.profiles')!.single,
      isNot(contains('top-secret')),
    );

    final loaded = await store.load();
    expect(loaded.single.password, 'top-secret');
  });
}

class _MemorySecretStore implements ConnectionSecretStore {
  final Map<String, String> values = {};

  @override
  Future<void> delete(String connectionKey) async {
    values.remove(connectionKey);
  }

  @override
  Future<String?> read(String connectionKey) async => values[connectionKey];

  @override
  Future<void> write(String connectionKey, String password) async {
    values[connectionKey] = password;
  }
}
