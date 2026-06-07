import 'package:db_viewer/features/database/services/result_indexer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('filters and sorts result indexes off the UI isolate', () async {
    final indexes = await ResultIndexer.build(
      rows: const [
        [1, 'beta'],
        [3, 'bravo'],
        [2, 'alpha'],
      ],
      filters: const [
        ResultIndexFilter(
          column: 1,
          operator: 'contains',
          value: 'b',
          kind: 'text',
        ),
      ],
      sortColumn: 0,
      sortAscending: false,
    );

    expect(indexes, [1, 0]);
  });

  test('handles numeric comparisons and null filters', () async {
    final numeric = await ResultIndexer.build(
      rows: const [
        [null],
        [5],
        [12],
      ],
      filters: const [
        ResultIndexFilter(
          column: 0,
          operator: 'greater-than',
          value: '6',
          kind: 'number',
        ),
      ],
    );
    final nulls = await ResultIndexer.build(
      rows: const [
        [null],
        [5],
      ],
      filters: const [
        ResultIndexFilter(
          column: 0,
          operator: 'is-null',
          value: '',
          kind: 'text',
        ),
      ],
    );

    expect(numeric, [2]);
    expect(nulls, [0]);
  });
}
