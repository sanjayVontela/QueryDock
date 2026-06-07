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
}
