import 'package:db_viewer/features/workbench/widgets/db_viewer_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('result grid columns can be resized from the header edge', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 500,
            height: 300,
            child: ResultGrid(
              columns: ['id', 'name'],
              rows: [
                [1, 'Ada'],
              ],
            ),
          ),
        ),
      ),
    );

    final header = find.byKey(const ValueKey('result-grid-header-id'));
    final before = tester.getSize(header).width;
    await tester.drag(
      find.byKey(const ValueKey('result-grid-resize-id')),
      const Offset(70, 0),
    );
    await tester.pump();

    expect(tester.getSize(header).width, greaterThan(before));
  });

  testWidgets('result grid requests another page near the bottom', (
    tester,
  ) async {
    var loadCount = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 500,
            height: 240,
            child: ResultGrid(
              columns: const ['id'],
              rows: [
                for (var index = 0; index < 100; index++) [index],
              ],
              hasMoreRows: true,
              onLoadMore: () async {
                loadCount++;
              },
            ),
          ),
        ),
      ),
    );

    await tester.drag(
      find.byKey(const ValueKey('result-grid-rows')),
      const Offset(0, -4000),
    );
    await tester.pumpAndSettle();

    expect(loadCount, 1);
  });

  testWidgets('editable grid creates an editor only for the active cell', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 500,
            height: 300,
            child: ResultGrid(
              columns: const ['id', 'name'],
              rows: const [
                [1, 'Ada'],
                [2, 'Grace'],
              ],
              editable: true,
              onCellChanged: (_, _, _) {},
            ),
          ),
        ),
      ),
    );

    expect(find.byType(TextField), findsNothing);
    await tester.tap(find.text('Ada'));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.text('Ada'));
    await tester.pump();
    expect(find.byType(TextField), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 400));
  });

  testWidgets('Pluto renderer displays rows and invokes column filters', (
    tester,
  ) async {
    String? filteredColumn;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 700,
            height: 320,
            child: ResultGrid(
              renderer: ResultGridRenderer.pluto,
              columns: const ['id', 'name'],
              rows: const [
                [1, 'Ada'],
                [2, 'Grace'],
              ],
              onFilterColumn: (column) async {
                filteredColumn = column;
              },
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Ada'), findsOneWidget);
    expect(find.text('Grace'), findsOneWidget);
    await tester.tap(find.byTooltip('Filter name'));
    await tester.pump();
    expect(filteredColumn, 'name');
  });

  testWidgets('Pluto renderer reports edited cells using source indexes', (
    tester,
  ) async {
    (int, int, String)? edit;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 700,
            height: 320,
            child: ResultGrid(
              renderer: ResultGridRenderer.pluto,
              columns: const ['id', 'name'],
              rows: const [
                [1, 'Ada'],
                [2, 'Grace'],
              ],
              editable: true,
              onCellChanged: (row, column, value) {
                edit = (row, column, value);
              },
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Grace'));
    await tester.pump();
    await tester.tap(find.text('Grace'));
    await tester.pump();
    await tester.enterText(find.byType(TextField).last, 'Hopper');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();

    expect(edit, (1, 1, 'Hopper'));
  });

  for (final renderer in ResultGridRenderer.values) {
    testWidgets('${renderer.name} delays data-cell hover details', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 500,
              height: 260,
              child: ResultGrid(
                renderer: renderer,
                columns: const ['name'],
                rows: const [
                  ['A long cell value'],
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final tooltip = tester
          .widgetList<Tooltip>(find.byType(Tooltip))
          .where((item) => item.message == 'A long cell value')
          .single;
      expect(tooltip.waitDuration, const Duration(seconds: 2));
    });
  }
}
