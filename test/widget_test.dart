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
}
