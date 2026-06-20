import 'package:db_viewer/features/database/contracts/database_driver.dart';
import 'package:db_viewer/features/database/drivers/database_dialects.dart';
import 'package:db_viewer/features/database/drivers/database_driver_registry.dart';
import 'package:db_viewer/features/database/services/db2_database.dart';
import 'package:db_viewer/features/database/services/mysql_database.dart';
import 'package:db_viewer/features/database/services/postgres_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:postgres/postgres.dart';

void main() {
  test('all supported engines are registered behind one driver contract', () {
    final registry = DatabaseDriverRegistry();

    expect(
      registry.drivers.map((driver) => driver.engine).toSet(),
      DatabaseEngine.values.toSet(),
    );
    expect(
      registry.driverFor(DatabaseEngine.postgresql).capabilities.tableEditing,
      isTrue,
    );
    expect(
      registry.driverFor(DatabaseEngine.mysql).capabilities.tableEditing,
      isTrue,
    );
    expect(
      registry.driverFor(DatabaseEngine.sqlite).capabilities.tableEditing,
      isTrue,
    );
    expect(
      registry.driverFor(DatabaseEngine.db2).capabilities.tableEditing,
      isTrue,
    );
  });

  test('connection configs implement the shared profile model', () {
    const postgres = PostgresConnectionConfig(
      host: 'localhost',
      port: 5432,
      database: 'app',
      username: 'developer',
      password: 'secret',
      sslMode: SslMode.disable,
      writeProtected: true,
    );
    const mysql = MySqlConnectionConfig(
      host: 'localhost',
      database: 'app',
      username: 'developer',
      password: 'secret',
      writeProtected: true,
    );
    const db2 = Db2ConnectionConfig(
      host: 'localhost',
      database: 'app',
      username: 'developer',
      password: 'secret',
      writeProtected: true,
    );

    expect(postgres.engine, DatabaseEngine.postgresql);
    expect(mysql.engine, DatabaseEngine.mysql);
    expect(db2.engine, DatabaseEngine.db2);
    expect(postgres.databaseName, 'app');
    expect(mysql.databaseName, 'app');
    expect(db2.databaseName, 'app');
    expect(postgres.writeProtected, isTrue);
    expect(mysql.writeProtected, isTrue);
    expect(db2.writeProtected, isTrue);
  });

  test('dialects isolate engine-specific identifier syntax', () {
    expect(
      const PostgresDialect().qualifiedTable('public', 'user'),
      '"public"."user"',
    );
    expect(const MySqlDialect().qualifiedTable('app', 'user'), '`app`.`user`');
    expect(const SqliteDialect().qualifiedTable('main', 'user'), '"user"');
    expect(const Db2Dialect().qualifiedTable('APP', 'USER'), '"APP"."USER"');
  });
}
