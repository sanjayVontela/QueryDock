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

  testWidgets('AI assistant can attach the current SQL script', (tester) async {
    await _pumpWorkbench(tester);
    final editor = find.byType(EditableText).first;

    await tester.tap(editor);
    await tester.enterText(editor, 'SELECT 1;');
    await tester.tap(find.byTooltip('Open AI Assistant'));
    await tester.pump();

    expect(
      find.text(
        'Attach a schema, table, script, or selection, then ask for SQL.',
      ),
      findsOneWidget,
    );

    await tester.tap(find.byTooltip('Attach context'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Current script'));
    await tester.pump();

    expect(find.byType(InputChip), findsOneWidget);
  });

  testWidgets('upper menu labels do not repeat as hover tooltips', (
    tester,
  ) async {
    await _pumpWorkbench(tester);

    expect(find.text('File'), findsOneWidget);
    expect(find.byTooltip('File'), findsNothing);
    expect(find.byTooltip('Edit'), findsNothing);
    expect(find.byTooltip('Database'), findsNothing);
    expect(find.byTooltip('Window'), findsNothing);
    expect(find.byTooltip('AI'), findsNothing);
    expect(find.byTooltip('Help'), findsNothing);
  });

  testWidgets('dark mode uses themed workbench foreground colors', (
    tester,
  ) async {
    await _pumpWorkbench(tester, brightness: Brightness.dark);
    final context = tester.element(find.text('File'));
    final scheme = Theme.of(context).colorScheme;

    expect(Theme.of(context).brightness, Brightness.dark);
    expect(
      tester.widget<Text>(find.text('File')).style?.color,
      scheme.onSurface,
    );
    expect(
      tester
          .widget<Text>(find.text('Add a PostgreSQL connection to begin.'))
          .style
          ?.color,
      scheme.onSurfaceVariant,
    );

    await tester.tap(find.byTooltip('Open AI Assistant'));
    await tester.pump();
    expect(
      tester
          .widget<Text>(
            find.text(
              'Attach a schema, table, script, or selection, then ask for SQL.',
            ),
          )
          .style
          ?.color,
      scheme.onSurfaceVariant,
    );
  });
}

Future<void> _pumpWorkbench(
  WidgetTester tester, {
  Brightness brightness = Brightness.light,
}) async {
  tester.view.physicalSize = const Size(1800, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(
        brightness: brightness,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xff2f6f8f),
          brightness: brightness,
        ),
      ),
      home: const MyHomePage(title: 'QueryDock', nativeWindowChrome: false),
    ),
  );
  await tester.pumpAndSettle();
}

String _editorText(WidgetTester tester, Finder editor) {
  return tester.widget<EditableText>(editor).controller.text;
}
