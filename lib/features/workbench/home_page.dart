import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:panes/panes.dart';
import 'package:path_provider/path_provider.dart';

import '../database/models/database_schema.dart';
import '../database/services/postgres_database.dart';
import 'widgets/db_viewer_widgets.dart';

class MyHomePage extends StatefulWidget {
  final String title;

  const MyHomePage({super.key, required this.title});

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  late final IdeController _controller;
  final PostgresConnectionStore _connectionStore = PostgresConnectionStore();

  PostgresDatabase? _database;
  bool _isExecuting = false;
  bool _isConnected = false;
  bool _isConnecting = false;

  String _activeConnection = 'No Connection';
  String _activeSchema = '-';
  String _activeDriver = '-';
  String _status = 'Disconnected';
  int _activeCenterTab = 0;

  List<String> _logs = [];
  List<String> _columns = [];
  List<List<dynamic>> _rows = [];

  final List<_OpenConnection> _connections = [];
  final List<_SqlScriptTab> _sqlTabs = [];
  final List<_OpenTableTab> _openTableTabs = [];

  final ValueNotifier<String> _activeResultTab = ValueNotifier('Data');

  @override
  void initState() {
    super.initState();

    _controller = IdeController(
      leftSize: PaneSize.pixel(280),
      rightSize: PaneSize.pixel(240),
      bottomSize: PaneSize.pixel(180),
      bottomVisible: true,
    );

    _logs = ['[INFO] DB Viewer started', '[INFO] No database connected'];
    _loadSqlScripts();
  }

  @override
  void dispose() {
    unawaited(_database?.close() ?? Future<void>.value());
    for (final tab in _sqlTabs) {
      tab.dispose();
    }
    for (final tab in _openTableTabs) {
      tab.dispose();
    }
    for (final connection in _connections) {
      unawaited(connection.database.close());
    }
    _activeResultTab.dispose();
    _controller.dispose();
    super.dispose();
  }

  Future<void> _newConnection() async {
    final savedConnections = await _connectionStore.load();

    if (!mounted) return;

    final config = await showDialog<PostgresConnectionConfig>(
      context: context,
      builder: (context) =>
          PostgresConnectionDialog(savedConnections: savedConnections),
    );

    if (config == null) return;

    setState(() {
      _isConnecting = true;
      _status = 'Connecting';
      _logs.add('[INFO] Connecting to PostgreSQL: ${config.displayName}');
    });
    _showResultTab('Messages');

    try {
      final database = await PostgresDatabase.connect(config);
      final schemas = await database.loadSchemas(forceRefresh: true);
      await _connectionStore.save(config);
      final session = _OpenConnection(database: database, schemas: schemas);

      setState(() {
        _connections.add(session);
        _database = database;
        _isConnected = true;
        _isConnecting = false;
        _activeConnection = config.displayName;
        _activeSchema = schemas.isEmpty ? '-' : schemas.first.name;
        _activeDriver = 'postgres ${config.sslMode.name}';
        _status = 'Connected';
        _columns = [];
        _rows = [];
        _logs.add('[INFO] Connected to ${config.database}');
        _logs.add('[INFO] Loaded ${schemas.length} schemas');
      });
    } catch (error) {
      setState(() {
        _isConnected = false;
        _isConnecting = false;
        _status = 'Connection failed';
        _activeConnection = 'No Connection';
        _activeSchema = '-';
        _logs.add('[ERROR] PostgreSQL connection failed: $error');
      });
      _showResultTab('Messages');
    }
  }

  Future<void> _executeSql() async {
    await _runSql(_sqlToExecute());
  }

  Future<PostgresQueryResult?> _runSql(
    String sql, {
    bool updateSqlResults = true,
    PostgresDatabase? databaseOverride,
  }) async {
    final database = databaseOverride ?? _database;

    if (!_isConnected || database == null) {
      setState(() {
        _logs.add('[WARN] Not connected. Click New Connection first.');
      });
      _showResultTab('Messages');
      return null;
    }

    if (sql.isEmpty) {
      setState(() {
        _logs.add('[WARN] SQL editor is empty.');
      });
      _showResultTab('Messages');
      return null;
    }

    setState(() {
      _isExecuting = true;
      _logs.add('[INFO] Executing SQL...');
      _logs.add('[SQL] ${sql.replaceAll('\n', ' ')}');
    });

    try {
      final streamedRows = <List<dynamic>>[];
      final result = await database.execute(
        sql,
        onColumns: updateSqlResults
            ? (columns) {
                if (!mounted || !_isExecuting) return;
                setState(() {
                  _columns = columns;
                  _rows = [];
                });
              }
            : null,
        onRowsChunk: updateSqlResults
            ? (rows) {
                if (!mounted || !_isExecuting) return;
                streamedRows.addAll(rows);
                setState(() {
                  _rows = List<List<dynamic>>.of(streamedRows);
                });
              }
            : null,
      );

      if (!_isExecuting) return null;

      setState(() {
        if (updateSqlResults) {
          _columns = result.columns;
          _rows = result.rows;
        }
        _isExecuting = false;
        _logs.add('[INFO] Query executed successfully');
        _logs.add(
          '[INFO] ${result.rows.length} rows fetched, ${result.affectedRows} affected in ${result.elapsed.inMilliseconds} ms',
        );
        if (result.rowLimitApplied) {
          _logs.add(
            '[INFO] Result limited to ${PostgresDatabase.defaultMaxRows} rows to keep the UI responsive.',
          );
        }
      });
      if (updateSqlResults) {
        _showResultTab('Data');
      }
      return result;
    } catch (error) {
      if (!_isExecuting) return null;

      setState(() {
        _isExecuting = false;
        _logs.add('[ERROR] Query failed: $error');
      });
      _showResultTab('Messages');
      return null;
    }
  }

  void _stopQuery() {
    if (!_isExecuting) {
      setState(() {
        _logs.add('[INFO] No running query to stop.');
      });
      return;
    }

    setState(() {
      _isExecuting = false;
      _logs.add('[WARN] Query execution stopped by user.');
    });
    _showResultTab('Messages');
  }

  Future<void> _newSqlScript() async {
    final scriptsDirectory = await _sqlScriptsDirectory();
    final title = _nextSqlScriptTitle(scriptsDirectory);
    final script = _SqlScriptTab(
      title: title,
      file: File('${scriptsDirectory.path}${Platform.pathSeparator}$title.sql'),
      text: '',
    );

    setState(() {
      _sqlTabs.add(script);
      _activeCenterTab = _sqlTabs.length - 1;
      _logs.add('[INFO] Created SQL script: ${script.title}');
    });
  }

  Future<void> _loadSqlScripts() async {
    final scriptsDirectory = await _sqlScriptsDirectory();
    final files =
        scriptsDirectory
            .listSync()
            .whereType<File>()
            .where((file) => file.path.toLowerCase().endsWith('.sql'))
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path));

    final scripts = <_SqlScriptTab>[];
    for (final file in files) {
      scripts.add(
        _SqlScriptTab(
          title: _fileNameWithoutExtension(file),
          file: file,
          text: await file.readAsString(),
        ),
      );
    }

    if (scripts.isEmpty) {
      final file = File(
        '${scriptsDirectory.path}${Platform.pathSeparator}SQL Script 1.sql',
      );
      scripts.add(
        _SqlScriptTab(
          title: 'SQL Script 1',
          file: file,
          text: '''SELECT current_database() AS database_name,
       current_user AS connected_user,
       version() AS postgres_version;''',
        ),
      );
    }

    if (!mounted) return;

    setState(() {
      _sqlTabs.addAll(scripts);
      _activeCenterTab = 0;
      _logs.add('[INFO] Loaded ${scripts.length} SQL script files');
    });
  }

  Future<Directory> _sqlScriptsDirectory() async {
    final appDirectory = await getApplicationSupportDirectory();
    final scriptsDirectory = Directory(
      '${appDirectory.path}${Platform.pathSeparator}sql_scripts',
    );

    if (!scriptsDirectory.existsSync()) {
      scriptsDirectory.createSync(recursive: true);
    }

    return scriptsDirectory;
  }

  String _nextSqlScriptTitle(Directory scriptsDirectory) {
    final scriptNumberPattern = RegExp(
      r'^(?:SQL\s*)?Script\s*(\d+)$',
      caseSensitive: false,
    );
    var highestIndex = 0;

    void readScriptNumber(String title) {
      final match = scriptNumberPattern.firstMatch(title.trim());
      final number = int.tryParse(match?.group(1) ?? '');
      if (number != null && number > highestIndex) {
        highestIndex = number;
      }
    }

    for (final tab in _sqlTabs) {
      readScriptNumber(tab.title);
    }

    for (final file in scriptsDirectory.listSync().whereType<File>()) {
      if (file.path.toLowerCase().endsWith('.sql')) {
        readScriptNumber(_fileNameWithoutExtension(file));
      }
    }

    var index = highestIndex + 1;
    while (_sqlTabs.any((tab) => tab.title == 'SQL Script $index') ||
        File(
          '${scriptsDirectory.path}${Platform.pathSeparator}SQL Script $index.sql',
        ).existsSync()) {
      index++;
    }
    return 'SQL Script $index';
  }

  String _fileNameWithoutExtension(File file) {
    final segments = file.path.split(Platform.pathSeparator);
    final name = segments.isEmpty ? file.path : segments.last;
    final extensionIndex = name.toLowerCase().lastIndexOf('.sql');
    return extensionIndex == -1 ? name : name.substring(0, extensionIndex);
  }

  Future<void> _saveSql() async {
    final tab = _activeSqlTab;
    if (tab == null) return;

    await tab.save();

    setState(() {
      _logs.add('[INFO] Saved SQL script: ${tab.file.path}');
    });
  }

  void _closeSqlTab(_SqlScriptTab tab) {
    var needsReplacementScript = false;

    setState(() {
      final index = _sqlTabs.indexOf(tab);
      if (index == -1) return;

      final wasActive = _activeCenterTab == index;
      _sqlTabs.removeAt(index);
      tab.dispose();

      if (wasActive) {
        if (_sqlTabs.isNotEmpty) {
          _activeCenterTab = index.clamp(0, _sqlTabs.length - 1);
        } else {
          _activeCenterTab = 0;
          needsReplacementScript = _openTableTabs.isEmpty;
        }
      } else if (_activeCenterTab > index) {
        _activeCenterTab--;
      }

      _logs.add('[INFO] Closed SQL script: ${tab.title}');
    });

    if (needsReplacementScript) {
      unawaited(_newSqlScript());
    }
  }

  void _executeShortcut() {
    if (_isExecuting || _isConnecting) return;
    unawaited(_executeSql());
  }

  void _saveShortcut() {
    unawaited(_saveSql());
  }

  void _newSqlShortcut() {
    unawaited(_newSqlScript());
  }

  void _newConnectionShortcut() {
    if (_isConnecting) return;
    unawaited(_newConnection());
  }

  void _closeActiveCenterTab() {
    final sqlTab = _activeSqlTab;
    if (sqlTab != null) {
      _closeSqlTab(sqlTab);
      return;
    }

    final tableTab = _activeTableTab;
    if (tableTab != null) {
      _closeTableTab(tableTab);
    }
  }

  void _openTable(String schema, String table) {
    _generateTableSql(schema, table, 'select');
  }

  Future<void> _generateTableSql(
    String schema,
    String table,
    String statement,
  ) async {
    final sqlTab = _activeSqlTab ?? (_sqlTabs.isEmpty ? null : _sqlTabs.first);
    if (sqlTab == null) return;
    final loadedTable = await _ensureTableColumns(schema, table);

    if (!mounted) return;

    setState(() {
      _activeCenterTab = _sqlTabs.indexOf(sqlTab);
      _activeSchema = schema;
      sqlTab.controller.text = _buildGeneratedTableSql(
        schema,
        loadedTable,
        statement,
      );
      _logs.add(
        '[INFO] Generated ${statement.toUpperCase()} for $schema.$table',
      );
    });
  }

  String _buildGeneratedTableSql(
    String schema,
    DatabaseTable table,
    String statement,
  ) {
    final qualifiedName =
        '${_quoteIdentifier(schema)}.${_quoteIdentifier(table.name)}';
    final columns = table.columns;
    final columnList = columns.map((column) => _quoteIdentifier(column.name));

    switch (statement) {
      case 'insert':
        return [
          'INSERT INTO $qualifiedName (',
          '  ${columnList.join(',\n  ')}',
          ') VALUES (',
          '  ${columns.map((column) => '<${column.name}>').join(',\n  ')}',
          ');',
        ].join('\n');
      case 'update':
        return [
          'UPDATE $qualifiedName',
          'SET ${columns.map((column) => '${_quoteIdentifier(column.name)} = <${column.name}>').join(',\n    ')}',
          'WHERE <condition>;',
        ].join('\n');
      case 'delete':
        return ['DELETE FROM $qualifiedName', 'WHERE <condition>;'].join('\n');
      case 'select':
      default:
        return [
          'SELECT ${columnList.isEmpty ? '*' : columnList.join(',\n       ')}',
          'FROM $qualifiedName',
          'LIMIT 500;',
        ].join('\n');
    }
  }

  Future<DatabaseTable> _ensureTableModelColumns(
    String schema,
    DatabaseTable table,
  ) {
    return _ensureTableColumns(schema, table.name, existingTable: table);
  }

  Future<DatabaseTable> _ensureTableColumns(
    String schema,
    String tableName, {
    DatabaseTable? existingTable,
  }) async {
    if (existingTable?.columnsLoaded ?? false) return existingTable!;

    final database = _database;
    if (database == null) {
      return existingTable ??
          DatabaseTable(name: tableName, columns: const [], ddl: '');
    }

    final loadedTable = await database.loadTableColumns(schema, tableName);
    _replaceTableInActiveConnection(schema, loadedTable);
    return loadedTable;
  }

  Future<void> _loadSchemaTables(
    _OpenConnection connection,
    String schema, {
    bool forceRefresh = false,
  }) async {
    final tables = await connection.database.loadSchemaTables(
      schema,
      forceRefresh: forceRefresh,
    );

    if (!mounted) return;
    setState(() {
      _replaceSchema(connection, schema, tables, tablesLoaded: true);
      _logs.add('[INFO] Loaded ${tables.length} tables for schema $schema');
    });
  }

  Future<void> _loadTableColumns(
    String schema,
    DatabaseTable table, {
    bool forceRefresh = false,
  }) async {
    final database = _database;
    if (database == null) return;

    final loadedTable = await database.loadTableColumns(
      schema,
      table.name,
      forceRefresh: forceRefresh,
    );

    if (!mounted) return;
    setState(() {
      _replaceTableInActiveConnection(schema, loadedTable);
      _logs.add(
        '[INFO] Loaded ${loadedTable.columns.length} columns for $schema.${table.name}',
      );
    });
  }

  void _replaceSchema(
    _OpenConnection connection,
    String schema,
    List<DatabaseTable> tables, {
    required bool tablesLoaded,
  }) {
    final index = connection.schemas.indexWhere((item) => item.name == schema);
    if (index == -1) return;
    connection.schemas[index] = connection.schemas[index].copyWith(
      tables: tables,
      tablesLoaded: tablesLoaded,
    );
  }

  void _replaceTableInActiveConnection(String schema, DatabaseTable table) {
    for (final connection in _connections) {
      if (connection.database != _database) continue;
      final schemaIndex = connection.schemas.indexWhere(
        (item) => item.name == schema,
      );
      if (schemaIndex == -1) return;

      final schemaModel = connection.schemas[schemaIndex];
      final tables = List<DatabaseTable>.of(schemaModel.tables);
      final tableIndex = tables.indexWhere((item) => item.name == table.name);
      if (tableIndex == -1) {
        tables.add(table);
      } else {
        tables[tableIndex] = table;
      }
      connection.schemas[schemaIndex] = schemaModel.copyWith(
        tables: tables,
        tablesLoaded: true,
      );
      return;
    }
  }

  Future<void> _openTableData(
    String schema,
    DatabaseTable table, {
    String initialTab = 'Data',
  }) async {
    final loadedTable = await _ensureTableModelColumns(schema, table);
    if (!mounted) return;

    final existingIndex = _openTableTabs.indexWhere(
      (tab) => tab.schema == schema && tab.table == table.name,
    );

    late final _OpenTableTab tab;

    setState(() {
      if (existingIndex == -1) {
        tab = _OpenTableTab(
          database: _database!,
          connectionName: _activeConnection,
          schema: schema,
          table: loadedTable.name,
          columns: loadedTable.columns,
          ddl: loadedTable.ddl,
        );
        _openTableTabs.add(tab);
        _activeCenterTab = _tableTabOffset + _openTableTabs.length - 1;
      } else {
        tab = _openTableTabs[existingIndex];
        _activeCenterTab = _tableTabOffset + existingIndex;
      }
      tab.innerTab = initialTab;
      _activeSchema = schema;
      _logs.add('[INFO] Opened data browser: $schema.${table.name}');
    });

    await _loadTableTabData(tab);
  }

  Future<void> _applyTableFilter(_OpenTableTab tab) async {
    setState(() {
      _logs.add('[INFO] Applied table filter: ${tab.id}');
    });

    await _loadTableTabData(tab);
  }

  void _closeTableTab(_OpenTableTab tab) {
    setState(() {
      final index = _openTableTabs.indexOf(tab);
      if (index == -1) return;
      _openTableTabs.removeAt(index);
      tab.dispose();
      if (_activeCenterTab >= _tableTabOffset + _openTableTabs.length) {
        _activeCenterTab = _openTableTabs.isEmpty
            ? 0
            : _tableTabOffset + _openTableTabs.length - 1;
      }
      _logs.add('[INFO] Closed table data browser: ${tab.id}');
    });
  }

  Future<void> _sortTableData(_OpenTableTab tab, String column) async {
    setState(() {
      if (tab.sortColumn == column) {
        tab.sortAscending = !tab.sortAscending;
      } else {
        tab.sortColumn = column;
        tab.sortAscending = true;
      }
      _logs.add(
        '[INFO] Sorted table data: $column ${tab.sortAscending ? 'ASC' : 'DESC'}',
      );
    });

    await _loadTableTabData(tab);
  }

  Future<void> _loadTableTabData(_OpenTableTab tab) async {
    final result = await _runSql(
      _buildTableDataSql(tab),
      updateSqlResults: false,
      databaseOverride: tab.database,
    );
    if (result == null) return;
    setState(() {
      tab.resultColumns = result.columns;
      tab.rows = result.rows;
    });
  }

  Future<void> _refreshSchemas() async {
    final database = _database;
    if (database == null) return;

    setState(() {
      _logs.add('[INFO] Refreshing schemas');
    });

    final schemas = await database.loadSchemas(forceRefresh: true);
    setState(() {
      for (final connection in _connections) {
        if (connection.database == database) {
          connection.schemas = schemas;
          break;
        }
      }
      _logs.add('[INFO] Refreshed ${schemas.length} schemas');
    });
  }

  void _activateConnection(_OpenConnection connection) {
    setState(() {
      _database = connection.database;
      _activeConnection = connection.database.config.displayName;
      _activeSchema = connection.schemas.isEmpty
          ? '-'
          : connection.schemas.first.name;
      _activeDriver = 'postgres ${connection.database.config.sslMode.name}';
      _status = 'Connected';
      _logs.add('[INFO] Activated connection: $_activeConnection');
    });
  }

  void _selectSchema(String schema) {
    setState(() {
      _activeSchema = schema;
      _logs.add('[INFO] Selected schema: $schema');
    });
  }

  void _setTableDataTab(String tab) {
    final activeTab = _activeTableTab;
    if (activeTab == null || activeTab.innerTab == tab) return;
    setState(() {
      activeTab.innerTab = tab;
    });
  }

  Iterable<String> _sqlAutocompleteOptions(TextEditingValue value) {
    final textBeforeCursor = value.selection.isValid
        ? value.text.substring(0, value.selection.baseOffset)
        : value.text;
    final match = RegExp(
      r'[A-Za-z_][A-Za-z0-9_\.]*$',
    ).firstMatch(textBeforeCursor);
    final token = match?.group(0) ?? '';
    if (token.isEmpty) return const Iterable.empty();

    final lowerToken = token.toLowerCase();
    final options = <String>{
      'SELECT',
      'FROM',
      'WHERE',
      'ORDER BY',
      'GROUP BY',
      'LIMIT',
      'JOIN',
      'LEFT JOIN',
      'INNER JOIN',
      'INSERT',
      'UPDATE',
      'DELETE',
      for (final connection in _connections)
        for (final schema in connection.schemas) ...[
          schema.name,
          for (final table in schema.tables) ...[
            '${schema.name}.${table.name}',
            table.name,
            for (final column in table.columns) column.name,
          ],
        ],
    };

    return options
        .where((option) => option.toLowerCase().contains(lowerToken))
        .take(12);
  }

  void _insertAutocompleteOption(String option) {
    final sqlTab = _activeSqlTab;
    if (sqlTab == null) return;

    final controller = sqlTab.controller;
    final selection = controller.selection;
    final text = controller.text;
    final cursor = selection.isValid ? selection.baseOffset : text.length;
    final start =
        RegExp(
          r'[A-Za-z_][A-Za-z0-9_\.]*$',
        ).firstMatch(text.substring(0, cursor))?.start ??
        cursor;
    final nextText = text.replaceRange(start, cursor, option);

    controller.value = TextEditingValue(
      text: nextText,
      selection: TextSelection.collapsed(offset: start + option.length),
    );
  }

  Future<void> _copyToClipboard(String text, String label) async {
    await Clipboard.setData(ClipboardData(text: text));
    setState(() {
      _logs.add('[INFO] Copied $label to clipboard');
    });
  }

  void _selectResultTab(String tab) {
    _showResultTab(tab);
  }

  String _sqlToExecute() {
    final controller = _activeSqlTab?.controller;
    if (controller == null) return '';

    final selection = controller.selection;
    final editorText = controller.text;

    if (selection.isValid && !selection.isCollapsed) {
      final start = selection.start.clamp(0, editorText.length);
      final end = selection.end.clamp(0, editorText.length);
      final selectedSql = editorText.substring(start, end).trim();

      if (selectedSql.isNotEmpty) {
        return selectedSql;
      }
    }

    return editorText.trim();
  }

  void _showResultTab(String tab) {
    if (_activeResultTab.value == tab) return;
    _activeResultTab.value = tab;
  }

  _OpenTableTab? get _activeTableTab {
    final tableIndex = _activeCenterTab - _sqlTabs.length;
    if (tableIndex < 0 || tableIndex >= _openTableTabs.length) {
      return null;
    }
    return _openTableTabs[tableIndex];
  }

  _SqlScriptTab? get _activeSqlTab {
    if (_activeCenterTab < 0 || _activeCenterTab >= _sqlTabs.length) {
      return null;
    }
    return _sqlTabs[_activeCenterTab];
  }

  int get _tableTabOffset => _sqlTabs.length;

  String _quoteIdentifier(String identifier) {
    return '"${identifier.replaceAll('"', '""')}"';
  }

  String _buildTableDataSql(_OpenTableTab tab) {
    final filter = tab.filterController.text.trim();
    final buffer = StringBuffer()
      ..writeln('SELECT *')
      ..writeln(
        'FROM ${_quoteIdentifier(tab.schema)}.${_quoteIdentifier(tab.table)}',
      );

    if (filter.isNotEmpty) {
      buffer.writeln('WHERE $filter');
    }

    if (tab.sortColumn != null) {
      buffer.writeln(
        'ORDER BY ${_quoteIdentifier(tab.sortColumn!)} ${tab.sortAscending ? 'ASC' : 'DESC'}',
      );
    }

    buffer.write('LIMIT 500;');
    return buffer.toString();
  }

  int _resultTabIndex(String tab) {
    switch (tab) {
      case 'Messages':
        return 1;
      case 'Execution Plan':
        return 2;
      case 'Data':
      default:
        return 0;
    }
  }

  Widget _buildResultContent() {
    return ValueListenableBuilder<String>(
      valueListenable: _activeResultTab,
      builder: (context, activeTab, child) {
        return IndexedStack(
          index: _resultTabIndex(activeTab),
          children: [
            ResultGrid(columns: _columns, rows: _rows),
            MessagesView(logs: _logs),
            const ExecutionPlanView(),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.enter, control: true):
            _executeShortcut,
        const SingleActivator(LogicalKeyboardKey.f5): _executeShortcut,
        const SingleActivator(LogicalKeyboardKey.keyS, control: true):
            _saveShortcut,
        const SingleActivator(LogicalKeyboardKey.keyN, control: true):
            _newSqlShortcut,
        const SingleActivator(
          LogicalKeyboardKey.keyN,
          control: true,
          shift: true,
        ): _newConnectionShortcut,
        const SingleActivator(LogicalKeyboardKey.keyW, control: true):
            _closeActiveCenterTab,
        const SingleActivator(LogicalKeyboardKey.escape): _stopQuery,
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          backgroundColor: const Color(0xfff3f3f3),
          body: Column(
            children: [
              AppTitleBar(connectionName: _activeConnection, status: _status),
              const DbMenuBar(),
              DbToolbar(
                isExecuting: _isExecuting,
                isConnecting: _isConnecting,
                onNewConnection: _newConnection,
                onNewSql: _newSqlScript,
                onExecute: _isExecuting || _isConnecting ? null : _executeSql,
                onStop: _stopQuery,
                onSave: _saveSql,
                onToggleNavigator: () {
                  setState(() {
                    _controller.toggleLeft();
                  });
                },
                onToggleOutput: () {
                  setState(() {
                    _controller.toggleBottom();
                  });
                },
              ),
              Expanded(
                child: IdeLayout(
                  controller: _controller,
                  leftPanelBuilder: (context, animationProgress) =>
                      _buildNavigatorPanel(animationProgress),
                  centerBuilder: (context, animationProgress) =>
                      _buildEditorPanel(animationProgress),
                  rightPanelBuilder: (context, animationProgress) =>
                      _buildPropertiesPanel(animationProgress),
                  bottomPanelBuilder: (context, animationProgress) =>
                      _buildOutputPanel(animationProgress),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCenterTabs() {
    return Container(
      height: 34,
      color: const Color(0xffe6e6e6),
      child: Row(
        children: [
          for (int i = 0; i < _sqlTabs.length; i++)
            EditorTab(
              title: _sqlTabs[i].title,
              active: _activeCenterTab == i,
              onTap: () => setState(() => _activeCenterTab = i),
              onClose: () => _closeSqlTab(_sqlTabs[i]),
            ),
          for (int i = 0; i < _openTableTabs.length; i++)
            EditorTab(
              title: _openTableTabs[i].table,
              active: _activeCenterTab == _tableTabOffset + i,
              onTap: () =>
                  setState(() => _activeCenterTab = _tableTabOffset + i),
              onClose: () => _closeTableTab(_openTableTabs[i]),
            ),
        ],
      ),
    );
  }

  Widget _buildNavigatorPanel(double animationProgress) {
    return Container(
      color: const Color(0xfffafafa),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          PanelHeader(
            title: 'Database Navigator',
            icon: Icons.storage,
            onClose: () {
              setState(() {
                _controller.toggleLeft();
              });
            },
          ),
          Expanded(
            child: ListView(
              children: [
                if (_connections.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(12),
                    child: Text(
                      'Connect to PostgreSQL to browse schemas.',
                      style: TextStyle(fontSize: 12, color: Colors.black54),
                    ),
                  ),
                for (final connection in _connections)
                  _ConnectionTreeItem(
                    connection: connection,
                    active: connection.database == _database,
                    onActivate: () => _activateConnection(connection),
                    schemaBuilder: (schema) => _SchemaTreeItem(
                      schema: schema,
                      onExpand: () {
                        _activateConnection(connection);
                        return _loadSchemaTables(connection, schema.name);
                      },
                      onSelectSchema: (schemaName) {
                        _activateConnection(connection);
                        _selectSchema(schemaName);
                      },
                      onRefresh: _refreshSchemas,
                      onCopyName: (name) =>
                          _copyToClipboard(name, 'schema name'),
                      tableBuilder: (table) {
                        return _TableTreeItem(
                          schema: schema.name,
                          table: table,
                          onExpand: (schema, table) {
                            _activateConnection(connection);
                            return _loadTableColumns(schema, table);
                          },
                          onOpenTable: (schema, table) {
                            _activateConnection(connection);
                            _openTable(schema, table);
                          },
                          onGenerateSql: (schema, table, statement) {
                            _activateConnection(connection);
                            return _generateTableSql(
                              schema,
                              table.name,
                              statement,
                            );
                          },
                          onOpenTableData: (schema, table) {
                            _activateConnection(connection);
                            return _openTableData(schema, table);
                          },
                          onOpenTableProperties: (schema, table) {
                            _activateConnection(connection);
                            return _openTableData(
                              schema,
                              table,
                              initialTab: 'Properties',
                            );
                          },
                          onCopyName: (name) =>
                              _copyToClipboard(name, 'table name'),
                          onRefresh: _refreshSchemas,
                        );
                      },
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEditorPanel(double animationProgress) {
    if (_activeCenterTab >= _tableTabOffset) {
      final activeTab = _activeTableTab;
      if (activeTab != null) {
        return _buildTableDataPanel(activeTab);
      }
    }

    final sqlTab = _activeSqlTab;
    if (sqlTab == null) {
      return const Center(child: Text('Loading SQL scripts...'));
    }

    return Column(
      children: [
        _buildCenterTabs(),
        Expanded(
          flex: 2,
          child: Container(
            color: Colors.white,
            padding: const EdgeInsets.all(12),
            child: RawAutocomplete<String>(
              textEditingController: sqlTab.controller,
              focusNode: sqlTab.focusNode,
              optionsBuilder: _sqlAutocompleteOptions,
              onSelected: _insertAutocompleteOption,
              fieldViewBuilder:
                  (context, controller, focusNode, onFieldSubmitted) {
                    return TextField(
                      controller: controller,
                      focusNode: focusNode,
                      maxLines: null,
                      expands: true,
                      textAlignVertical: TextAlignVertical.top,
                      style: const TextStyle(
                        fontFamily: 'Consolas',
                        fontSize: 14,
                        height: 1.5,
                      ),
                      decoration: const InputDecoration(
                        border: InputBorder.none,
                        hintText: 'Write SQL here...',
                      ),
                    );
                  },
              optionsViewBuilder: (context, onSelected, options) {
                return Align(
                  alignment: Alignment.topLeft,
                  child: Material(
                    elevation: 4,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(
                        maxWidth: 260,
                        maxHeight: 220,
                      ),
                      child: ListView.builder(
                        padding: EdgeInsets.zero,
                        itemCount: options.length,
                        itemBuilder: (context, index) {
                          final option = options.elementAt(index);
                          return ListTile(
                            dense: true,
                            title: Text(
                              option,
                              style: const TextStyle(
                                fontFamily: 'Consolas',
                                fontSize: 13,
                              ),
                            ),
                            onTap: () => onSelected(option),
                          );
                        },
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
        ValueListenableBuilder<String>(
          valueListenable: _activeResultTab,
          builder: (context, activeTab, child) {
            return Container(
              height: 30,
              color: const Color(0xffefefef),
              child: Row(
                children: [
                  ResultTab(
                    title: 'Data',
                    active: activeTab == 'Data',
                    onTap: () => _selectResultTab('Data'),
                  ),
                  ResultTab(
                    title: 'Messages',
                    active: activeTab == 'Messages',
                    onTap: () => _selectResultTab('Messages'),
                  ),
                  ResultTab(
                    title: 'Execution Plan',
                    active: activeTab == 'Execution Plan',
                    onTap: () => _selectResultTab('Execution Plan'),
                  ),
                ],
              ),
            );
          },
        ),
        Expanded(
          flex: 2,
          child: Container(color: Colors.white, child: _buildResultContent()),
        ),
      ],
    );
  }

  Widget _buildTableDataPanel(_OpenTableTab tab) {
    return Column(
      children: [
        _buildCenterTabs(),
        Container(
          height: 30,
          color: const Color(0xffefefef),
          child: Row(
            children: [
              ResultTab(
                title: 'Properties',
                active: tab.innerTab == 'Properties',
                onTap: () => _setTableDataTab('Properties'),
              ),
              ResultTab(
                title: 'Data',
                active: tab.innerTab == 'Data',
                onTap: () => _setTableDataTab('Data'),
              ),
              ResultTab(
                title: 'Diagram',
                active: tab.innerTab == 'Diagram',
                onTap: () => _setTableDataTab('Diagram'),
              ),
            ],
          ),
        ),
        Expanded(
          child: Container(
            color: Colors.white,
            child: _buildTableDataTabContent(tab),
          ),
        ),
      ],
    );
  }

  Widget _buildTableDataTabContent(_OpenTableTab tab) {
    switch (tab.innerTab) {
      case 'Properties':
        return _TablePropertiesView(
          schema: tab.schema,
          table: tab.table,
          columns: tab.columns,
          ddl: tab.ddl,
        );
      case 'Diagram':
        return const _TableDiagramPlaceholder();
      case 'Data':
      default:
        return Column(
          children: [
            _TableDataBrowserBar(
              schema: tab.schema,
              table: tab.table,
              filterController: tab.filterController,
              isExecuting: _isExecuting,
              onApplyFilter: () => _applyTableFilter(tab),
              onRefresh: () => _applyTableFilter(tab),
              onClose: () => _closeTableTab(tab),
            ),
            Expanded(
              child: ResultGrid(
                columns: tab.resultColumns,
                rows: tab.rows,
                sortColumn: tab.sortColumn,
                sortAscending: tab.sortAscending,
                onSortColumn: _isExecuting
                    ? null
                    : (column) => _sortTableData(tab, column),
              ),
            ),
          ],
        );
    }
  }

  Widget _buildPropertiesPanel(double animationProgress) {
    return Container(
      color: const Color(0xfffafafa),
      child: Column(
        children: [
          const PanelHeader(title: 'Properties', icon: Icons.info_outline),
          PropertyRow(name: 'Connection', value: _activeConnection),
          PropertyRow(name: 'Schema', value: _activeSchema),
          PropertyRow(name: 'Driver', value: _activeDriver),
          PropertyRow(name: 'Status', value: _status),
          PropertyRow(name: 'Rows', value: '${_rows.length}'),
          ValueListenableBuilder<String>(
            valueListenable: _activeResultTab,
            builder: (context, activeTab, child) {
              return PropertyRow(name: 'Result Tab', value: activeTab);
            },
          ),
        ],
      ),
    );
  }

  Widget _buildOutputPanel(double animationProgress) {
    return Container(
      color: const Color(0xff1e1e1e),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          BottomHeader(
            onClose: () {
              setState(() {
                _controller.toggleBottom();
              });
            },
          ),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.all(10),
              itemCount: _logs.length,
              itemBuilder: (context, index) {
                final log = _logs[index];

                return Text(
                  log,
                  style: TextStyle(
                    color: log.contains('[ERROR]')
                        ? Colors.redAccent
                        : log.contains('[WARN]')
                        ? Colors.orangeAccent
                        : Colors.greenAccent,
                    fontFamily: 'Consolas',
                    fontSize: 13,
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _OpenTableTab {
  final PostgresDatabase database;
  final String connectionName;
  final String schema;
  final String table;
  final List<DatabaseColumn> columns;
  final String ddl;
  final TextEditingController filterController = TextEditingController();

  String innerTab = 'Data';
  String? sortColumn;
  bool sortAscending = true;
  List<String> resultColumns = [];
  List<List<dynamic>> rows = [];

  _OpenTableTab({
    required this.database,
    required this.connectionName,
    required this.schema,
    required this.table,
    required this.columns,
    required this.ddl,
  });

  String get id => '$schema.$table';

  void dispose() {
    filterController.dispose();
  }
}

class _SqlScriptTab {
  final String title;
  final File file;
  final TextEditingController controller;
  final FocusNode focusNode = FocusNode();

  _SqlScriptTab({required this.title, required this.file, required String text})
    : controller = TextEditingController(text: text);

  Future<void> save() async {
    final parent = file.parent;
    if (!parent.existsSync()) {
      parent.createSync(recursive: true);
    }
    await file.writeAsString(controller.text);
  }

  void dispose() {
    controller.dispose();
    focusNode.dispose();
  }
}

class _OpenConnection {
  final PostgresDatabase database;
  List<DatabaseSchema> schemas;

  _OpenConnection({required this.database, required this.schemas});
}

class _ConnectionTreeItem extends StatelessWidget {
  final _OpenConnection connection;
  final bool active;
  final VoidCallback onActivate;
  final Widget Function(DatabaseSchema schema) schemaBuilder;

  const _ConnectionTreeItem({
    required this.connection,
    required this.active,
    required this.onActivate,
    required this.schemaBuilder,
  });

  @override
  Widget build(BuildContext context) {
    return ExpansionTile(
      dense: true,
      initiallyExpanded: active,
      tilePadding: const EdgeInsets.only(left: 4, right: 8),
      leading: Icon(
        Icons.dns,
        size: 16,
        color: active ? Colors.green.shade700 : Colors.blueGrey,
      ),
      title: InkWell(
        onTap: onActivate,
        child: _HoverTitle(
          child: Text(
            connection.database.config.displayName,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 13,
              fontWeight: active ? FontWeight.w600 : FontWeight.normal,
            ),
          ),
        ),
      ),
      children: [
        for (final schema in connection.schemas) schemaBuilder(schema),
      ],
    );
  }
}

class _SchemaTreeItem extends StatelessWidget {
  final DatabaseSchema schema;
  final Future<void> Function() onExpand;
  final void Function(String schema) onSelectSchema;
  final VoidCallback onRefresh;
  final void Function(String name) onCopyName;
  final Widget Function(DatabaseTable table) tableBuilder;

  const _SchemaTreeItem({
    required this.schema,
    required this.onExpand,
    required this.onSelectSchema,
    required this.onRefresh,
    required this.onCopyName,
    required this.tableBuilder,
  });

  @override
  Widget build(BuildContext context) {
    return _ContextMenuRegion(
      menuItems: [
        PopupMenuItem(value: 'select', child: _MenuAction('Set active')),
        PopupMenuItem(value: 'refresh', child: _MenuAction('Refresh')),
        PopupMenuItem(value: 'copy', child: _MenuAction('Copy name')),
        PopupMenuItem(
          value: 'properties',
          child: _MenuAction('View properties'),
        ),
      ],
      onSelected: (value) {
        switch (value) {
          case 'select':
          case 'properties':
            onSelectSchema(schema.name);
            break;
          case 'refresh':
            onRefresh();
            break;
          case 'copy':
            onCopyName(schema.name);
            break;
        }
      },
      child: ExpansionTile(
        dense: true,
        initiallyExpanded: false,
        onExpansionChanged: (expanded) {
          if (expanded && !schema.tablesLoaded) {
            onExpand();
          }
        },
        tilePadding: const EdgeInsets.only(left: 22, right: 8),
        leading: const Icon(Icons.folder, size: 16, color: Colors.blueGrey),
        title: _HoverTitle(
          child: Text(schema.name, style: const TextStyle(fontSize: 13)),
        ),
        children: [
          if (!schema.tablesLoaded)
            const Padding(
              padding: EdgeInsets.only(left: 58, right: 8, bottom: 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Expand to load tables.',
                  style: TextStyle(fontSize: 12, color: Colors.black54),
                ),
              ),
            ),
          if (schema.tablesLoaded && schema.tables.isEmpty)
            const Padding(
              padding: EdgeInsets.only(left: 58, right: 8, bottom: 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'No tables found.',
                  style: TextStyle(fontSize: 12, color: Colors.black54),
                ),
              ),
            ),
          for (final table in schema.tables) tableBuilder(table),
        ],
      ),
    );
  }
}

class _TableTreeItem extends StatelessWidget {
  final String schema;
  final DatabaseTable table;
  final Future<void> Function(String schema, DatabaseTable table) onExpand;
  final void Function(String schema, String table) onOpenTable;
  final Future<void> Function(
    String schema,
    DatabaseTable table,
    String statement,
  )
  onGenerateSql;
  final Future<void> Function(String schema, DatabaseTable table)
  onOpenTableData;
  final Future<void> Function(String schema, DatabaseTable table)
  onOpenTableProperties;
  final void Function(String name) onCopyName;
  final VoidCallback onRefresh;

  const _TableTreeItem({
    required this.schema,
    required this.table,
    required this.onExpand,
    required this.onOpenTable,
    required this.onGenerateSql,
    required this.onOpenTableData,
    required this.onOpenTableProperties,
    required this.onCopyName,
    required this.onRefresh,
  });

  @override
  Widget build(BuildContext context) {
    return _ContextMenuRegion(
      menuItems: [
        PopupMenuItem(value: 'open-data', child: _MenuAction('View data')),
        PopupMenuItem(enabled: false, child: _MenuAction('Generate')),
        PopupMenuItem(value: 'select', child: _MenuAction('  SELECT')),
        PopupMenuItem(value: 'insert', child: _MenuAction('  INSERT')),
        PopupMenuItem(value: 'update', child: _MenuAction('  UPDATE')),
        PopupMenuItem(value: 'delete', child: _MenuAction('  DELETE')),
        PopupMenuItem(value: 'refresh', child: _MenuAction('Refresh')),
        PopupMenuItem(value: 'copy', child: _MenuAction('Copy name')),
        PopupMenuItem(
          value: 'properties',
          child: _MenuAction('View properties'),
        ),
      ],
      onSelected: (value) {
        switch (value) {
          case 'open-data':
            onOpenTableData(schema, table);
            break;
          case 'select':
          case 'insert':
          case 'update':
          case 'delete':
            onGenerateSql(schema, table, value);
            break;
          case 'refresh':
            onRefresh();
            break;
          case 'copy':
            onCopyName(table.name);
            break;
          case 'properties':
            onOpenTableProperties(schema, table);
            break;
        }
      },
      child: ExpansionTile(
        dense: true,
        onExpansionChanged: (expanded) {
          if (expanded && !table.columnsLoaded) {
            onExpand(schema, table);
          }
        },
        tilePadding: const EdgeInsets.only(left: 58, right: 8),
        childrenPadding: EdgeInsets.zero,
        leading: const Icon(
          Icons.table_chart,
          size: 16,
          color: Colors.blueGrey,
        ),
        title: InkWell(
          onTap: () => onOpenTable(schema, table.name),
          onDoubleTap: () => onOpenTableData(schema, table),
          child: _HoverTitle(
            child: Text(table.name, style: const TextStyle(fontSize: 13)),
          ),
        ),
        children: [
          ExpansionTile(
            dense: true,
            initiallyExpanded: true,
            tilePadding: const EdgeInsets.only(left: 80, right: 8),
            childrenPadding: EdgeInsets.zero,
            leading: const Icon(
              Icons.view_column,
              size: 16,
              color: Colors.blueGrey,
            ),
            title: const Text('Columns', style: TextStyle(fontSize: 13)),
            children: [
              if (!table.columnsLoaded)
                const Padding(
                  padding: EdgeInsets.only(left: 116, right: 8, bottom: 8),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'Expand to load columns.',
                      style: TextStyle(fontSize: 12, color: Colors.black54),
                    ),
                  ),
                )
              else if (table.columns.isEmpty)
                const Padding(
                  padding: EdgeInsets.only(left: 116, right: 8, bottom: 8),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'No columns found.',
                      style: TextStyle(fontSize: 12, color: Colors.black54),
                    ),
                  ),
                ),
              for (final column in table.columns)
                TreeItem(
                  icon: Icons.notes,
                  title: '${column.name}  ${column.displayType}',
                  level: 5,
                  showArrow: false,
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _HoverTitle extends StatefulWidget {
  final Widget child;

  const _HoverTitle({required this.child});

  @override
  State<_HoverTitle> createState() => _HoverTitleState();
}

class _HoverTitleState extends State<_HoverTitle> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 80),
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
        decoration: BoxDecoration(
          color: _hovering ? const Color(0xffe8f1fb) : Colors.transparent,
          borderRadius: BorderRadius.circular(4),
        ),
        child: widget.child,
      ),
    );
  }
}

class _ContextMenuRegion extends StatelessWidget {
  final Widget child;
  final List<PopupMenuEntry<String>> menuItems;
  final ValueChanged<String> onSelected;

  const _ContextMenuRegion({
    required this.child,
    required this.menuItems,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onSecondaryTapDown: (details) async {
        final value = await showMenu<String>(
          context: context,
          position: RelativeRect.fromLTRB(
            details.globalPosition.dx,
            details.globalPosition.dy,
            details.globalPosition.dx,
            details.globalPosition.dy,
          ),
          items: menuItems,
        );

        if (value != null) {
          onSelected(value);
        }
      },
      child: child,
    );
  }
}

class _MenuAction extends StatelessWidget {
  final String label;

  const _MenuAction(this.label);

  @override
  Widget build(BuildContext context) {
    return Text(label, style: const TextStyle(fontSize: 13));
  }
}

class _TableDataBrowserBar extends StatelessWidget {
  final String schema;
  final String table;
  final TextEditingController filterController;
  final bool isExecuting;
  final VoidCallback onApplyFilter;
  final VoidCallback onRefresh;
  final VoidCallback onClose;

  const _TableDataBrowserBar({
    required this.schema,
    required this.table,
    required this.filterController,
    required this.isExecuting,
    required this.onApplyFilter,
    required this.onRefresh,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 42,
      color: const Color(0xfff7f7f7),
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          const Icon(Icons.table_chart, size: 16, color: Colors.blueGrey),
          const SizedBox(width: 6),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 220),
            child: Text(
              '$schema.$table',
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: TextField(
              controller: filterController,
              enabled: !isExecuting,
              onSubmitted: (_) => onApplyFilter(),
              style: const TextStyle(fontFamily: 'Consolas', fontSize: 13),
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.filter_alt, size: 16),
                hintText: "Filter rows, e.g. status = 'ACTIVE'",
                isDense: true,
                border: OutlineInputBorder(),
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 8,
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            tooltip: 'Apply filter',
            onPressed: isExecuting ? null : onApplyFilter,
            icon: const Icon(Icons.check, size: 18),
          ),
          IconButton(
            tooltip: 'Refresh data',
            onPressed: isExecuting ? null : onRefresh,
            icon: const Icon(Icons.refresh, size: 18),
          ),
          IconButton(
            tooltip: 'Close data browser',
            onPressed: onClose,
            icon: const Icon(Icons.close, size: 18),
          ),
        ],
      ),
    );
  }
}

class _TablePropertiesView extends StatelessWidget {
  final String schema;
  final String table;
  final List<DatabaseColumn> columns;
  final String ddl;

  const _TablePropertiesView({
    required this.schema,
    required this.table,
    required this.columns,
    required this.ddl,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          height: 36,
          color: const Color(0xfff7f7f7),
          padding: const EdgeInsets.symmetric(horizontal: 10),
          alignment: Alignment.centerLeft,
          child: Text(
            '$schema.$table',
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
        ),
        PropertyRow(name: 'Schema', value: schema),
        PropertyRow(name: 'Table', value: table),
        PropertyRow(name: 'Columns', value: '${columns.length}'),
        Expanded(
          child: DefaultTabController(
            length: 2,
            child: Column(
              children: [
                Container(
                  height: 32,
                  color: const Color(0xffefefef),
                  child: const TabBar(
                    labelColor: Colors.black87,
                    unselectedLabelColor: Colors.black54,
                    indicatorColor: Colors.blueGrey,
                    tabs: [
                      Tab(text: 'Columns'),
                      Tab(text: 'DDL'),
                    ],
                  ),
                ),
                Expanded(
                  child: TabBarView(
                    children: [
                      ResultGrid(
                        columns: const ['Name', 'Type', 'Nullable'],
                        rows: [
                          for (final column in columns)
                            [
                              column.name,
                              column.dataType,
                              column.nullable ? 'YES' : 'NO',
                            ],
                        ],
                      ),
                      Container(
                        color: Colors.white,
                        padding: const EdgeInsets.all(12),
                        alignment: Alignment.topLeft,
                        child: SelectableText(
                          ddl,
                          style: const TextStyle(
                            fontFamily: 'Consolas',
                            fontSize: 13,
                            height: 1.45,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _TableDiagramPlaceholder extends StatelessWidget {
  const _TableDiagramPlaceholder();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Text(
        'Diagram view placeholder',
        style: TextStyle(color: Colors.black54),
      ),
    );
  }
}
