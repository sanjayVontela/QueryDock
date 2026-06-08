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
      folder: 'Production',
      tags: ['critical', 'read-mostly'],
      sshEnabled: true,
      sshHost: 'bastion.example.com',
      sshPort: 2222,
      sshUsername: 'deploy',
      sshPrivateKeyPath: r'C:\keys\database_ed25519',
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
    expect(restored.folder, 'Production');
    expect(restored.tags, ['critical', 'read-mostly']);
    expect(restored.sshEnabled, isTrue);
    expect(restored.sshHost, 'bastion.example.com');
    expect(restored.sshPort, 2222);
    expect(restored.sshUsername, 'deploy');
    expect(restored.sshPrivateKeyPath, r'C:\keys\database_ed25519');
  });

  test('SQL splitter preserves quoted and procedural semicolons', () {
    const sql = '''
SELECT 'one;two';
-- ignored ; separator
DO \$body\$
BEGIN
  RAISE NOTICE 'still; one statement';
END;
\$body\$;
SELECT "semi;colon" FROM example;
''';

    final statements = PostgresDatabase.splitSqlStatements(sql);

    expect(statements, hasLength(3));
    expect(statements[0].sql, "SELECT 'one;two'");
    expect(statements[1].sql, contains('RAISE NOTICE'));
    expect(statements[2].sql, 'SELECT "semi;colon" FROM example');
    expect(statements[2].offset, sql.indexOf('SELECT "semi;colon"'));
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
