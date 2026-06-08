import '../../database/contracts/database_driver.dart';

class DatabaseQueryRun {
  final String sql;
  final DatabaseProfile profile;
  final List<DatabaseQueryResult> results;
  final DateTime startedAt;
  final Duration elapsed;

  const DatabaseQueryRun({
    required this.sql,
    required this.profile,
    required this.results,
    required this.startedAt,
    required this.elapsed,
  });

  DatabaseQueryResult get last => results.last;
  int get rowCount =>
      results.fold(0, (total, result) => total + result.rowCount);
}

class DatabaseQueryRunner {
  const DatabaseQueryRunner();

  Future<DatabaseQueryRun> execute(
    DatabaseSession session,
    String sql, {
    int maxRows = 10000,
  }) async {
    final startedAt = DateTime.now();
    final stopwatch = Stopwatch()..start();
    try {
      final results = await session.executeStatements(sql, maxRows: maxRows);
      if (results.isEmpty) {
        throw StateError('The SQL did not contain an executable statement.');
      }
      return DatabaseQueryRun(
        sql: sql,
        profile: session.profile,
        results: results,
        startedAt: startedAt,
        elapsed: stopwatch.elapsed,
      );
    } finally {
      stopwatch.stop();
    }
  }
}
