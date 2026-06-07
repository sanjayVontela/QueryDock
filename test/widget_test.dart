// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:db_viewer/widgets/db_viewer_widgets.dart';

void main() {
  testWidgets('Result grid smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: ResultGrid(
            columns: ['ID', 'NAME'],
            rows: [
              [1, 'Sample Row'],
            ],
          ),
        ),
      ),
    );

    expect(find.text('ID'), findsOneWidget);
    expect(find.text('Sample Row'), findsOneWidget);
  });

  testWidgets('Result grid only edits eligible columns', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ResultGrid(
            columns: const ['ID', 'CALCULATED'],
            rows: const [
              [1, 'read only'],
            ],
            editable: true,
            columnEditable: (column) => column == 0,
            onCellChanged: (_, _, _) {},
          ),
        ),
      ),
    );

    expect(find.byType(TextField), findsNothing);
    expect(find.text('read only'), findsOneWidget);

    await tester.tap(find.text('read only'));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.text('read only'));
    await tester.pump();
    expect(find.byType(TextField), findsNothing);

    await tester.tap(find.text('1'));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.text('1'));
    await tester.pump();
    expect(find.byType(TextField), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 400));
  });
}
