import 'package:db_viewer/features/workbench/home_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('SQL completion can be selected with keyboard', (tester) async {
    await _pumpWorkbench(tester);
    final editor = find.byType(EditableText).first;

    await tester.tap(editor);
    await tester.enterText(editor, 'sel');
    await tester.pump();

    expect(find.text('SELECT'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    expect(_editorText(tester, editor), 'SELECT');
    expect(find.text('SQL keyword'), findsNothing);
  });

  testWidgets('SQL completion can be selected with mouse', (tester) async {
    await _pumpWorkbench(tester);
    final editor = find.byType(EditableText).first;

    await tester.tap(editor);
    await tester.enterText(editor, 'sel');
    await tester.pump();

    await tester.tap(find.text('SELECT'));
    await tester.pump();

    expect(_editorText(tester, editor), 'SELECT');
    expect(find.text('SQL keyword'), findsNothing);
  });
}

Future<void> _pumpWorkbench(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1400, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    const MaterialApp(
      home: MyHomePage(title: 'DB Viewer', nativeWindowChrome: false),
    ),
  );
  await tester.pumpAndSettle();
}

String _editorText(WidgetTester tester, Finder editor) {
  return tester.widget<EditableText>(editor).controller.text;
}
