import 'dart:isolate';

class ResultIndexFilter {
  final int column;
  final String operator;
  final String value;
  final String kind;

  const ResultIndexFilter({
    required this.column,
    required this.operator,
    required this.value,
    required this.kind,
  });
}

class ResultIndexer {
  static Future<List<int>> build({
    required List<List<dynamic>> rows,
    required List<ResultIndexFilter> filters,
    int? sortColumn,
    bool sortAscending = true,
  }) {
    final sortableRows = [
      for (final row in rows) [for (final value in row) _isolateValue(value)],
    ];
    return Isolate.run(
      () => _buildIndexes(sortableRows, filters, sortColumn, sortAscending),
    );
  }

  static Object? _isolateValue(Object? value) {
    if (value == null || value is num || value is bool || value is String) {
      return value;
    }
    if (value is DateTime) return value.toIso8601String();
    return value.toString();
  }

  static List<int> _buildIndexes(
    List<List<Object?>> rows,
    List<ResultIndexFilter> filters,
    int? sortColumn,
    bool sortAscending,
  ) {
    final indexes = <int>[];
    for (var index = 0; index < rows.length; index++) {
      if (_matchesFilters(rows[index], filters)) indexes.add(index);
    }
    if (sortColumn != null) {
      indexes.sort((left, right) {
        final comparison = _compare(
          rows[left].elementAtOrNull(sortColumn),
          rows[right].elementAtOrNull(sortColumn),
        );
        return sortAscending ? comparison : -comparison;
      });
    }
    return indexes;
  }

  static bool _matchesFilters(
    List<Object?> row,
    List<ResultIndexFilter> filters,
  ) {
    for (final filter in filters) {
      if (!_matches(row.elementAtOrNull(filter.column), filter)) return false;
    }
    return true;
  }

  static bool _matches(Object? value, ResultIndexFilter filter) {
    if (filter.operator == 'is-null') return value == null;
    if (filter.operator == 'is-not-null') return value != null;
    if (value == null) return false;

    final actual = value.toString();
    final expected = filter.value;
    return switch (filter.operator) {
      'contains' => actual.toLowerCase().contains(expected.toLowerCase()),
      'starts-with' => actual.toLowerCase().startsWith(expected.toLowerCase()),
      'ends-with' => actual.toLowerCase().endsWith(expected.toLowerCase()),
      'not-equals' => _compareFilter(value, expected, filter.kind) != 0,
      'greater-than' => _compareFilter(value, expected, filter.kind) > 0,
      'greater-or-equal' => _compareFilter(value, expected, filter.kind) >= 0,
      'less-than' => _compareFilter(value, expected, filter.kind) < 0,
      'less-or-equal' => _compareFilter(value, expected, filter.kind) <= 0,
      _ => _compareFilter(value, expected, filter.kind) == 0,
    };
  }

  static int _compareFilter(Object value, String expected, String kind) {
    if (kind == 'number') {
      return (num.tryParse(value.toString()) ?? 0).compareTo(
        num.tryParse(expected) ?? 0,
      );
    }
    if (kind == 'dateTime') {
      final actualDate = DateTime.tryParse(value.toString());
      final expectedDate = DateTime.tryParse(expected);
      if (actualDate != null && expectedDate != null) {
        return actualDate.compareTo(expectedDate);
      }
    }
    return value.toString().toLowerCase().compareTo(expected.toLowerCase());
  }

  static int _compare(Object? left, Object? right) {
    if (left == null && right == null) return 0;
    if (left == null) return -1;
    if (right == null) return 1;
    if (left is num && right is num) return left.compareTo(right);
    return left.toString().toLowerCase().compareTo(
      right.toString().toLowerCase(),
    );
  }
}
