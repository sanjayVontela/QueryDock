import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:csv/csv.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_code_editor/flutter_code_editor.dart';
import 'package:flutter_highlight/themes/atom-one-dark.dart';
import 'package:flutter_highlight/themes/github.dart';
import 'package:highlight/languages/sql.dart';

import '../database/models/database_schema.dart';
import '../database/services/postgres_database.dart';
import '../database/services/sqlite_database.dart';
import 'widgets/db_viewer_widgets.dart';

class SqliteWorkbenchPage extends StatefulWidget {
  final VoidCallback onClose;
  final void Function(String label, String context) onAttachContext;

  const SqliteWorkbenchPage({
    super.key,
    required this.onClose,
    required this.onAttachContext,
  });

  @override
  State<SqliteWorkbenchPage> createState() => _SqliteWorkbenchPageState();
}

class _SqliteWorkbenchPageState extends State<SqliteWorkbenchPage> {
  static const _databaseTypes = XTypeGroup(
    label: 'SQLite databases',
    extensions: ['db', 'sqlite', 'sqlite3'],
  );

  final _recentStore = const SqliteRecentStore();
  final _editor = CodeController(language: sql);
  final _editorFocus = FocusNode();
  List<String> _recent = [];
  List<DatabaseTable> _tables = [];
  List<PostgresQueryResult> _results = [];
  List<String> _columns = [];
  List<List<dynamic>> _rows = [];
  SqliteDatabase? _database;
  bool _loading = false;
  int _activeResult = 0;
  String _message = 'Open or create a SQLite database.';

  @override
  void initState() {
    super.initState();
    unawaited(_loadRecent());
  }

  @override
  void dispose() {
    _editor.dispose();
    _editorFocus.dispose();
    super.dispose();
  }

  Future<void> _loadRecent() async {
    final recent = await _recentStore.load();
    if (mounted) setState(() => _recent = recent);
  }

  Future<void> _openDatabase() async {
    final file = await openFile(acceptedTypeGroups: const [_databaseTypes]);
    if (file != null) await _connect(file.path);
  }

  Future<void> _createDatabase() async {
    final location = await getSaveLocation(
      suggestedName: 'database.db',
      acceptedTypeGroups: const [_databaseTypes],
    );
    if (location == null) return;
    final file = File(SqliteDatabase.ensureDatabaseExtension(location.path));
    if (!file.existsSync()) await file.create(recursive: true);
    await _connect(file.path);
  }

  Future<void> _connect(String path) async {
    setState(() {
      _loading = true;
      _message = 'Opening SQLite database...';
    });
    try {
      final database = SqliteDatabase(path);
      final tables = await database.loadTables();
      await _recentStore.add(path);
      if (!mounted) return;
      setState(() {
        _database = database;
        _tables = tables;
        _loading = false;
        _message = 'Connected to ${database.displayName}';
      });
      await _loadRecent();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _message = 'SQLite connection failed: $error';
      });
    }
  }

  Future<void> _execute() async {
    final database = _database;
    if (database == null || _loading) return;
    final selection = _editor.selection;
    final text = selection.isValid && !selection.isCollapsed
        ? selection.textInside(_editor.text)
        : _editor.text;
    if (text.trim().isEmpty) return;
    setState(() {
      _loading = true;
      _message = 'Executing SQLite query...';
    });
    try {
      final results = await database.executeStatements(text);
      final result = results.last;
      if (!mounted) return;
      setState(() {
        _results = results;
        _activeResult = results.length - 1;
        _columns = result.columns;
        _rows = result.rows;
        _loading = false;
        _message =
            '${result.rowCount} rows, ${result.affectedRows} affected in '
            '${result.elapsed.inMilliseconds} ms';
      });
      if (_changesSchema(text)) {
        final tables = await database.loadTables();
        if (mounted) setState(() => _tables = tables);
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _message = 'SQLite query failed: $error';
      });
    }
  }

  bool _changesSchema(String sql) {
    return RegExp(
      r'\b(create|alter|drop|vacuum|reindex|attach|detach)\b',
      caseSensitive: false,
    ).hasMatch(sql);
  }

  Future<void> _openTable(DatabaseTable table) async {
    final query = 'SELECT * FROM "${table.name.replaceAll('"', '""')}";';
    _editor.value = TextEditingValue(
      text: query,
      selection: TextSelection.collapsed(offset: query.length),
    );
    await _execute();
  }

  void _attachTable(DatabaseTable table) {
    final database = _database;
    if (database == null) return;
    final buffer = StringBuffer()
      ..writeln('SQLite database: ${database.displayName}')
      ..writeln('File: ${database.path}')
      ..writeln('${table.relationType}: ${table.name}')
      ..writeln('Columns:');
    for (final column in table.columns) {
      buffer.writeln(
        '- ${column.name}: ${column.dataType}'
        '${column.primaryKey ? ' PRIMARY KEY' : ''}'
        '${column.nullable ? '' : ' NOT NULL'}',
      );
    }
    if (table.foreignKeys.isNotEmpty) {
      buffer
        ..writeln('Foreign keys:')
        ..writeln(table.foreignKeys.map((key) => '- $key').join('\n'));
    }
    widget.onAttachContext(
      '${database.displayName}.${table.name}',
      buffer.toString(),
    );
  }

  void _selectResult(int index) {
    final result = _results[index];
    setState(() {
      _activeResult = index;
      _columns = result.columns;
      _rows = result.rows;
    });
  }

  Future<void> _export(String format) async {
    if (_columns.isEmpty) return;
    final location = await getSaveLocation(
      suggestedName: 'sqlite-result.$format',
      acceptedTypeGroups: [
        XTypeGroup(label: format.toUpperCase(), extensions: [format]),
      ],
    );
    if (location == null) return;
    final content = format == 'json'
        ? const JsonEncoder.withIndent('  ').convert([
            for (final row in _rows)
              {
                for (final (index, column) in _columns.indexed)
                  column: index < row.length ? row[index] : null,
              },
          ])
        : const ListToCsvConverter().convert([_columns, ..._rows]);
    await XFile.fromData(
      utf8.encode(content),
      mimeType: format == 'json' ? 'application/json' : 'text/csv',
    ).saveTo(location.path);
  }

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.enter, control: true): () =>
            unawaited(_execute()),
        const SingleActivator(LogicalKeyboardKey.f5): () =>
            unawaited(_execute()),
      },
      child: Focus(
        autofocus: true,
        child: Column(
          children: [
            Container(
              height: 42,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              color: Theme.of(context).colorScheme.surfaceContainer,
              child: Row(
                children: [
                  const Icon(Icons.storage_outlined, size: 18),
                  const SizedBox(width: 7),
                  Expanded(
                    child: Text(
                      _database == null
                          ? 'SQLite Workbench'
                          : _database!.displayName,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Open SQLite database',
                    onPressed: _loading
                        ? null
                        : () => unawaited(_openDatabase()),
                    icon: const Icon(Icons.folder_open, size: 18),
                  ),
                  IconButton(
                    tooltip: 'Create SQLite database',
                    onPressed: _loading
                        ? null
                        : () => unawaited(_createDatabase()),
                    icon: const Icon(Icons.note_add_outlined, size: 18),
                  ),
                  IconButton(
                    tooltip: 'Execute SQLite SQL',
                    onPressed: _database == null || _loading
                        ? null
                        : () => unawaited(_execute()),
                    icon: const Icon(Icons.play_arrow, size: 19),
                  ),
                  IconButton(
                    tooltip: 'Close SQLite workbench',
                    onPressed: widget.onClose,
                    icon: const Icon(Icons.close, size: 18),
                  ),
                ],
              ),
            ),
            if (_loading) const LinearProgressIndicator(minHeight: 2),
            Expanded(
              child: Row(
                children: [
                  SizedBox(width: 270, child: _buildNavigator()),
                  VerticalDivider(
                    width: 1,
                    color: Theme.of(context).dividerColor,
                  ),
                  Expanded(child: _buildWorkspace()),
                ],
              ),
            ),
            Container(
              height: 28,
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              alignment: Alignment.centerLeft,
              color: Theme.of(context).colorScheme.surfaceContainer,
              child: Text(
                _message,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNavigator() {
    return Column(
      children: [
        const PanelHeader(title: 'SQLite Navigator', icon: Icons.storage),
        Expanded(
          child: ListView(
            children: [
              if (_database == null) ...[
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.folder_open, size: 18),
                  title: const Text('Open database'),
                  onTap: () => unawaited(_openDatabase()),
                ),
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.note_add_outlined, size: 18),
                  title: const Text('Create database'),
                  onTap: () => unawaited(_createDatabase()),
                ),
              ],
              if (_recent.isNotEmpty && _database == null)
                const Padding(
                  padding: EdgeInsets.fromLTRB(12, 12, 8, 4),
                  child: Text(
                    'RECENT DATABASES',
                    style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600),
                  ),
                ),
              if (_database == null)
                for (final path in _recent)
                  ListTile(
                    dense: true,
                    leading: const Icon(Icons.storage_outlined, size: 17),
                    title: Text(
                      path.split(Platform.pathSeparator).last,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(path, overflow: TextOverflow.ellipsis),
                    onTap: () => unawaited(_connect(path)),
                    trailing: IconButton(
                      tooltip: 'Remove from recent databases',
                      icon: const Icon(Icons.close, size: 16),
                      onPressed: () async {
                        await _recentStore.remove(path);
                        await _loadRecent();
                      },
                    ),
                  ),
              if (_database != null)
                ExpansionTile(
                  initiallyExpanded: true,
                  leading: const Icon(Icons.storage, size: 18),
                  title: Text(
                    _database!.displayName,
                    overflow: TextOverflow.ellipsis,
                  ),
                  children: [
                    for (final table in _tables)
                      ExpansionTile(
                        dense: true,
                        leading: Icon(
                          table.relationType == 'View'
                              ? Icons.visibility_outlined
                              : Icons.table_chart_outlined,
                          size: 17,
                        ),
                        title: Row(
                          children: [
                            Expanded(
                              child: GestureDetector(
                                onDoubleTap: () => unawaited(_openTable(table)),
                                child: Text(
                                  table.name,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ),
                            IconButton(
                              tooltip: 'Add table to AI context',
                              visualDensity: VisualDensity.compact,
                              onPressed: () => _attachTable(table),
                              icon: const Icon(
                                Icons.add_link_outlined,
                                size: 16,
                              ),
                            ),
                          ],
                        ),
                        onExpansionChanged: (expanded) {
                          if (!expanded) return;
                        },
                        children: [
                          for (final column in table.columns)
                            ListTile(
                              dense: true,
                              contentPadding: const EdgeInsets.only(left: 50),
                              title: Text(
                                column.name,
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: Text(
                                column.dataType,
                                overflow: TextOverflow.ellipsis,
                              ),
                              leading: Icon(
                                column.primaryKey
                                    ? Icons.key_outlined
                                    : Icons.view_column_outlined,
                                size: 15,
                              ),
                              onTap: () => unawaited(_openTable(table)),
                            ),
                        ],
                      ),
                  ],
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildWorkspace() {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Column(
      children: [
        SizedBox(
          height: 270,
          child: CodeTheme(
            data: CodeThemeData(styles: dark ? atomOneDarkTheme : githubTheme),
            child: CodeField(
              controller: _editor,
              focusNode: _editorFocus,
              expands: true,
              wrap: false,
              textStyle: const TextStyle(
                fontFamily: 'Consolas',
                fontSize: 13,
                height: 1.45,
              ),
            ),
          ),
        ),
        Divider(height: 1, color: Theme.of(context).dividerColor),
        Container(
          height: 40,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          color: Theme.of(context).colorScheme.surfaceContainer,
          child: Row(
            children: [
              const Icon(Icons.table_rows_outlined, size: 17),
              const SizedBox(width: 6),
              const Text('Data', style: TextStyle(fontSize: 12)),
              const Spacer(),
              if (_results.length > 1)
                DropdownButton<int>(
                  value: _activeResult,
                  underline: const SizedBox.shrink(),
                  items: [
                    for (var index = 0; index < _results.length; index++)
                      DropdownMenuItem(
                        value: index,
                        child: Text('Result ${index + 1}'),
                      ),
                  ],
                  onChanged: (value) {
                    if (value != null) _selectResult(value);
                  },
                ),
              PopupMenuButton<String>(
                tooltip: 'Export result',
                enabled: _columns.isNotEmpty,
                onSelected: (value) => unawaited(_export(value)),
                itemBuilder: (context) => const [
                  PopupMenuItem(value: 'csv', child: Text('Export CSV')),
                  PopupMenuItem(value: 'json', child: Text('Export JSON')),
                ],
                icon: const Icon(Icons.download_outlined, size: 18),
              ),
            ],
          ),
        ),
        Expanded(child: _buildResultGrid()),
      ],
    );
  }

  Widget _buildResultGrid() {
    return ResultGrid(
      columns: _columns,
      rows: _rows,
      renderer: ResultGridRenderer.queryDock,
    );
  }
}
