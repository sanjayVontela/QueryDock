import '../contracts/database_driver.dart';
import 'mysql_driver.dart';
import 'postgres_driver.dart';
import 'sqlite_driver.dart';

class DatabaseDriverRegistry {
  final Map<DatabaseEngine, DatabaseDriver> _drivers;

  DatabaseDriverRegistry({
    PostgresDriver? postgres,
    MySqlDriver? mysql,
    SqliteDriver? sqlite,
  }) : _drivers = {
         DatabaseEngine.postgresql: postgres ?? PostgresDriver(),
         DatabaseEngine.mysql: mysql ?? const MySqlDriver(),
         DatabaseEngine.sqlite: sqlite ?? const SqliteDriver(),
       };

  List<DatabaseDriver> get drivers => List.unmodifiable(_drivers.values);

  DatabaseDriver driverFor(DatabaseEngine engine) {
    final driver = _drivers[engine];
    if (driver == null) {
      throw UnsupportedError('No database driver registered for $engine.');
    }
    return driver;
  }
}
