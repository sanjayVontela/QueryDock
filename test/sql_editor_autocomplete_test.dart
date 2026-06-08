import 'package:db_viewer/features/workbench/home_page.dart';
import 'package:db_viewer/features/workbench/widgets/db_viewer_widgets.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_code_editor/flutter_code_editor.dart';
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

  testWidgets('Ctrl+Enter executes without replacing the SQL selection', (
    tester,
  ) async {
    await _pumpWorkbench(tester);
    final editor = find.byType(EditableText).first;
    final editable = tester.widget<EditableText>(editor);
    const sql = 'SELECT 1;\nSELECT 2;';

    await tester.tap(editor);
    await tester.enterText(editor, sql);
    editable.controller.selection = const TextSelection(
      baseOffset: 0,
      extentOffset: 9,
    );

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();

    expect(editable.controller.text, sql);
    expect(editable.controller.selection.start, 0);
    expect(editable.controller.selection.end, 9);
  });

  testWidgets('SQL editor keeps the caret visible after adding lines', (
    tester,
  ) async {
    await _pumpWorkbench(tester, size: const Size(1100, 650));
    final editor = find.byType(EditableText).first;
    final sql = List.generate(60, (index) => 'SELECT $index;').join('\n');

    await tester.tap(editor);
    await tester.enterText(editor, sql);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    final scrollables = find.descendant(
      of: find.byType(CodeField),
      matching: find.byType(Scrollable),
    );
    final verticalOffsets = tester
        .stateList<ScrollableState>(scrollables)
        .where((state) => state.position.axis == Axis.vertical)
        .map((state) => state.position.pixels);

    expect(verticalOffsets.any((offset) => offset > 0), isTrue);
    expect(tester.takeException(), isNull);
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

  testWidgets('Ctrl+Enter sends the AI prompt', (tester) async {
    await _pumpWorkbench(tester);
    await tester.tap(find.byTooltip('Open AI Assistant'));
    await tester.pump();

    final prompt = find.byKey(const ValueKey('ai-prompt-field'));
    await tester.tap(prompt);
    await tester.enterText(prompt, 'Generate a query');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();

    expect(find.text('AI Provider Settings'), findsOneWidget);
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
          .widget<Text>(
            find.text(
              'Add a PostgreSQL, MySQL, or SQLite connection to begin.',
            ),
          )
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

  testWidgets('narrow result toolbar does not overflow', (tester) async {
    await _pumpWorkbench(tester, size: const Size(1100, 650));

    expect(tester.takeException(), isNull);
    expect(find.byTooltip('Grid renderer: QueryDock'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('sql-connection-compact-selector')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('sql-connection-dropdown')), findsNothing);
  });

  testWidgets('many editor tabs use a scrollable tab rail', (tester) async {
    await _pumpWorkbench(tester, size: const Size(1100, 650));

    for (var index = 0; index < 10; index++) {
      await tester.tap(find.byTooltip('New SQL File (Ctrl+N)'));
      await tester.pumpAndSettle();
    }

    expect(tester.takeException(), isNull);
    expect(
      find.byKey(const ValueKey('center-tab-scroll-view')),
      findsOneWidget,
    );
    expect(find.byTooltip('Scroll tabs left'), findsOneWidget);
    expect(find.byTooltip('Scroll tabs right'), findsOneWidget);
  });

  testWidgets('editor tabs provide DBeaver-style close actions', (
    tester,
  ) async {
    await _pumpWorkbench(tester);

    final tabs = find.byType(EditorTab);
    await tester.tap(tabs.first, buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();

    expect(find.text('Close'), findsOneWidget);
    expect(find.text('Close Others'), findsOneWidget);
    expect(find.text('Close All'), findsOneWidget);
    expect(find.text('Close Tabs to the Left'), findsOneWidget);
    expect(find.text('Close Tabs to the Right'), findsOneWidget);

    await tester.tap(find.text('Close All'));
    await tester.pump();
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.byTooltip('Close Tab (Ctrl+W)'), findsNothing);
    expect(find.text('No editors open'), findsOneWidget);
  });

  testWidgets('closing the final editor shows an empty workspace safely', (
    tester,
  ) async {
    await _pumpWorkbench(tester);

    await tester.tap(find.byTooltip('Close Tab (Ctrl+W)'));
    await tester.pump();
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text('Loading SQL scripts...'), findsNothing);
    expect(find.text('No editors open'), findsOneWidget);
    expect(find.byKey(const ValueKey('empty-editor-new-sql')), findsOneWidget);
  });

  testWidgets('Ctrl+W closes the active editor from editor focus', (
    tester,
  ) async {
    await _pumpWorkbench(tester);
    await tester.tap(find.byType(EditableText).first);
    await tester.pump();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyW);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyW);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();

    expect(find.text('No editors open'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('messages can be cleared from the result panel', (tester) async {
    await _pumpWorkbench(tester);

    await tester.tap(find.text('Messages').first);
    await tester.pump();
    expect(find.textContaining('[INFO] QueryDock started'), findsWidgets);

    await tester.tap(find.byTooltip('Clear messages').first);
    await tester.pump();

    expect(find.text('No messages.'), findsOneWidget);
    expect(find.byTooltip('Clear messages'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('new connection can open the SQLite workbench', (tester) async {
    await _pumpWorkbench(tester);

    await tester.tap(find.text('New Connection').first);
    await tester.pumpAndSettle();
    expect(find.text('PostgreSQL'), findsOneWidget);
    expect(find.text('SQLite'), findsOneWidget);

    await tester.tap(find.text('SQLite'));
    await tester.pumpAndSettle();

    expect(find.text('SQLite Workbench'), findsOneWidget);
    expect(find.text('SQLite Navigator'), findsOneWidget);
    expect(find.text('Open database'), findsOneWidget);
    expect(find.text('Create database'), findsOneWidget);
    expect(find.text('AI'), findsWidgets);
    expect(find.text('Properties'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('MySQL uses the shared QueryDock workbench', (tester) async {
    await _pumpWorkbench(tester);

    await tester.tap(find.text('New Connection').first);
    await tester.pumpAndSettle();
    expect(find.text('MySQL'), findsOneWidget);

    await tester.tap(find.text('MySQL'));
    await tester.pumpAndSettle();

    expect(find.text('MySQL Connection'), findsOneWidget);
    expect(find.text('Host'), findsOneWidget);
    expect(find.text('Database'), findsWidgets);
    expect(find.text('MySQL Workbench'), findsNothing);
    expect(find.text('MySQL Connections'), findsNothing);
    expect(find.text('AI'), findsWidgets);
    expect(find.text('Database Navigator'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

Future<void> _pumpWorkbench(
  WidgetTester tester, {
  Brightness brightness = Brightness.light,
  Size size = const Size(1800, 900),
}) async {
  tester.view.physicalSize = size;
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
