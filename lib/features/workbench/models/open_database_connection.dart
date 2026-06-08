import '../../database/drivers/mysql_driver.dart';
import '../../database/models/database_schema.dart';
import '../../database/services/mysql_database.dart';
import '../../database/services/postgres_database.dart';

class OpenPostgresConnection {
  PostgresConnectionConfig config;
  PostgresDatabase? database;
  List<DatabaseSchema> schemas;
  bool isConnecting;
  String? connectionError;

  OpenPostgresConnection({
    required this.config,
    required List<DatabaseSchema> schemas,
    this.database,
    this.isConnecting = false,
    this.connectionError,
  }) : schemas = List<DatabaseSchema>.of(schemas);

  bool get connected => database != null;
}

class OpenMySqlConnection {
  MySqlConnectionConfig config;
  MySqlDatabase? database;
  MySqlSession? session;
  List<DatabaseTable> tables;
  bool isConnecting;
  String? connectionError;

  OpenMySqlConnection({
    required this.config,
    this.database,
    this.session,
    List<DatabaseTable> tables = const [],
    this.isConnecting = false,
    this.connectionError,
  }) : tables = List<DatabaseTable>.of(tables);

  bool get connected => session != null;
}
