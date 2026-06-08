import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

class SqlHistoryEntry {
  final String id;
  final String sql;
  final String connection;
  final DateTime startedAt;
  final int elapsedMilliseconds;
  final int rowCount;
  final bool succeeded;
  final String error;

  const SqlHistoryEntry({
    required this.id,
    required this.sql,
    required this.connection,
    required this.startedAt,
    required this.elapsedMilliseconds,
    required this.rowCount,
    required this.succeeded,
    this.error = '',
  });

  Map<String, Object?> toJson() => {
    'id': id,
    'sql': sql,
    'connection': connection,
    'startedAt': startedAt.toIso8601String(),
    'elapsedMilliseconds': elapsedMilliseconds,
    'rowCount': rowCount,
    'succeeded': succeeded,
    'error': error,
  };

  static SqlHistoryEntry? fromJson(Map<String, dynamic> json) {
    final startedAt = DateTime.tryParse(json['startedAt']?.toString() ?? '');
    if (startedAt == null) return null;
    return SqlHistoryEntry(
      id: json['id']?.toString() ?? startedAt.microsecondsSinceEpoch.toString(),
      sql: json['sql']?.toString() ?? '',
      connection: json['connection']?.toString() ?? '',
      startedAt: startedAt,
      elapsedMilliseconds:
          int.tryParse(json['elapsedMilliseconds']?.toString() ?? '') ?? 0,
      rowCount: int.tryParse(json['rowCount']?.toString() ?? '') ?? 0,
      succeeded: json['succeeded'] == true,
      error: json['error']?.toString() ?? '',
    );
  }
}

class SqlHistoryStore {
  static const _key = 'workbench.sql_history.v1';
  static const _limit = 500;

  const SqlHistoryStore();

  Future<List<SqlHistoryEntry>> load() async {
    final preferences = await SharedPreferences.getInstance();
    final encoded = preferences.getStringList(_key) ?? const [];
    return [for (final item in encoded) ?_decode(item)];
  }

  Future<void> save(Iterable<SqlHistoryEntry> entries) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setStringList(_key, [
      for (final entry in entries.take(_limit)) jsonEncode(entry.toJson()),
    ]);
  }

  Future<void> clear() async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.remove(_key);
  }

  SqlHistoryEntry? _decode(String value) {
    try {
      final decoded = jsonDecode(value);
      if (decoded is Map<String, dynamic>) {
        return SqlHistoryEntry.fromJson(decoded);
      }
    } catch (_) {
      return null;
    }
    return null;
  }
}
