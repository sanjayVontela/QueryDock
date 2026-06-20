import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:csv/csv.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter_code_editor/flutter_code_editor.dart';
import 'package:flutter_highlight/themes/atom-one-dark.dart';
import 'package:flutter_highlight/themes/github.dart';
import 'package:highlight/languages/sql.dart';
import 'package:panes/panes.dart';
import 'package:path_provider/path_provider.dart';
import 'package:postgres/postgres.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../services/theme_controller.dart';
import '../ai/services/openai_assistant.dart';
import '../database/contracts/database_driver.dart';
import '../database/drivers/db2_driver.dart';
import '../database/drivers/mysql_driver.dart';
import '../database/drivers/postgres_driver.dart';
import '../database/models/database_schema.dart';
import '../database/models/workbench_connection.dart';
import '../database/services/db2_database.dart';
import '../database/services/postgres_database.dart';
import '../database/services/result_indexer.dart';
import '../database/services/mysql_database.dart';
import 'dialogs/db2_connection_dialog.dart';
import 'dialogs/mysql_connection_dialog.dart';
import 'models/open_database_connection.dart';
import 'sqlite_workbench_page.dart';
import 'services/database_query_runner.dart';
import 'services/sql_autocomplete.dart';
import 'services/workbench_services.dart';
import 'widgets/db_viewer_widgets.dart';
import 'widgets/database_connection_tree_tile.dart';
import 'widgets/workbench_center.dart';

class MyHomePage extends StatefulWidget {
  final String title;
  final bool nativeWindowChrome;

  const MyHomePage({
    super.key,
    required this.title,
    this.nativeWindowChrome = true,
  });

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  static const String _showAllSqlScriptsKey = 'workbench.sql_scripts.show_all';
  static const String _resultGridRendererKey =
      'workbench.results.grid_renderer';
  static const String _globalScriptConnectionKey = 'global';

  late final IdeController _controller;
  final PostgresConnectionStore _connectionStore = PostgresConnectionStore();
  final MySqlConnectionStore _mySqlConnectionStore =
      const MySqlConnectionStore();
  final Db2ConnectionStore _db2ConnectionStore = const Db2ConnectionStore();
  final PostgresDriver _postgresDriver = PostgresDriver();
  final MySqlDriver _mySqlDriver = const MySqlDriver();
  final Db2Driver _db2Driver = const Db2Driver();
  final AiAssistantSettingsStore _aiSettingsStore =
      const AiAssistantSettingsStore();
  final AiAssistantClient _aiClient = AiAssistantClient();
  final TextEditingController _aiPromptController = TextEditingController();
  final ScrollController _centerTabsController = ScrollController();
  final ScrollController _sqliteTabsController = ScrollController();
  final SqlHistoryStore _historyStore = const SqlHistoryStore();
  final DatabaseQueryRunner _queryRunner = const DatabaseQueryRunner();
  final SqlAutocompleteEngine _autocompleteEngine =
      const SqlAutocompleteEngine();
  final TextEditingController _objectSearchController = TextEditingController();

  PostgresDatabase? _database;
  _OpenMySqlConnection? _activeMySqlConnection;
  _OpenDb2Connection? _activeDb2Connection;
  PostgresDatabase? _executingDatabase;
  bool _isExecuting = false;
  bool _cancelRequested = false;
  String? _loadingOperation;
  bool _isConnecting = false;
  bool _showAllSqlScripts = false;
  bool _aiSending = false;
  bool _objectSearching = false;
  bool _sessionsLoading = false;
  bool _sqliteWorkbenchOpen = false;
  bool _sqliteWorkbenchActive = false;
  ResultGridRenderer _resultGridRenderer = ResultGridRenderer.queryDock;
  double _resultPanelHeight = 260;
  String _rightPanelMode = 'properties';
  AiAssistantSettings _aiSettings = const AiAssistantSettings();

  String _activeConnection = 'No Connection';
  String _activeSchema = '-';
  String _activeDriver = '-';
  String _status = 'Disconnected';
  int _activeCenterTab = 0;

  List<String> _logs = [];
  List<String> _columns = [];
  List<List<dynamic>> _rows = [];
  PostgresDatabase? _resultDatabase;
  String? _resultSchema;
  String? _resultTable;
  List<DatabaseColumn> _resultColumnMetadata = [];
  final Map<String, _ColumnFilter> _resultColumnFilters = {};
  final Map<int, Map<int, String>> _resultPendingChanges = {};
  List<int> _visibleResultIndexes = [];
  bool _resultIndexesReady = false;
  int _resultIndexGeneration = 0;
  String? _resultSortColumn;
  bool _resultSortAscending = true;
  List<DatabaseQueryResult> _statementResults = [];
  int _activeStatementResult = 0;
  List<SqlHistoryEntry> _sqlHistory = [];
  List<PostgresObjectSearchResult> _objectSearchResults = [];
  List<DatabaseSessionInfo> _sessions = [];

  final List<_OpenConnection> _connections = [];
  final List<_OpenMySqlConnection> _mySqlConnections = [];
  final List<_OpenDb2Connection> _db2Connections = [];
  final List<_SqlScriptTab> _sqlTabs = [];
  final List<_OpenTableTab> _openTableTabs = [];
  final Set<String> _loadingSchemas = {};
  final Set<String> _loadingTables = {};
  final Set<String> _autocompleteSchemaLoads = {};
  final List<AiAssistantMessage> _aiMessages = [];
  final List<_AiAttachment> _aiAttachments = [];

  final ValueNotifier<String> _activeResultTab = ValueNotifier('Data');

  @override
  void initState() {
    super.initState();

    _controller = IdeController(
      leftSize: PaneSize.pixel(280),
      rightSize: PaneSize.pixel(380),
      bottomSize: PaneSize.pixel(180),
      bottomVisible: true,
    );
    _controller.rootController.show(IdePane.right.id);

    _logs = ['[INFO] QueryDock started', '[INFO] No database connected'];
    _initializeSqlEditor();
    _loadSavedConnections();
    _loadSavedMySqlConnections();
    _loadSavedDb2Connections();
    _loadAiSettings();
    _loadResultGridRenderer();
    _loadSqlHistory();
  }

  @override
  void dispose() {
    for (final tab in _sqlTabs) {
      tab.dispose();
    }
    for (final tab in _openTableTabs) {
      tab.dispose();
    }
    for (final connection in _connections) {
      unawaited(connection.database?.close() ?? Future<void>.value());
    }
    for (final connection in _mySqlConnections) {
      unawaited(connection.database?.close() ?? Future<void>.value());
    }
    for (final connection in _db2Connections) {
      unawaited(connection.session?.close() ?? Future<void>.value());
    }
    _activeResultTab.dispose();
    _aiPromptController.dispose();
    _centerTabsController.dispose();
    _sqliteTabsController.dispose();
    _objectSearchController.dispose();
    _controller.dispose();
    super.dispose();
  }

  Future<void> _loadSavedConnections() async {
    final savedConnections = await _connectionStore.load();

    if (!mounted) return;

    setState(() {
      _connections
        ..clear()
        ..addAll([
          for (final config in savedConnections)
            _OpenConnection(config: config, schemas: const []),
        ]);
      if (savedConnections.isNotEmpty) {
        _logs.add('[INFO] Loaded ${savedConnections.length} saved connections');
      }
    });
  }

  Future<void> _loadSavedMySqlConnections() async {
    final profiles = await _mySqlConnectionStore.load();
    if (!mounted) return;
    setState(() {
      _mySqlConnections
        ..clear()
        ..addAll([
          for (final profile in profiles) _OpenMySqlConnection(config: profile),
        ]);
    });
  }

  Future<void> _loadSavedDb2Connections() async {
    final profiles = await _db2ConnectionStore.load();
    if (!mounted) return;
    setState(() {
      _db2Connections
        ..clear()
        ..addAll([
          for (final profile in profiles) _OpenDb2Connection(config: profile),
        ]);
    });
  }

  Future<void> _loadAiSettings() async {
    final settings = await _aiSettingsStore.load();
    if (!mounted) return;
    setState(() => _aiSettings = settings);
  }

  Future<void> _loadSqlHistory() async {
    final history = await _historyStore.load();
    if (!mounted) return;
    setState(() => _sqlHistory = history);
  }

  Future<void> _recordSqlHistory({
    required String sql,
    required String connection,
    required DateTime startedAt,
    required int elapsedMilliseconds,
    required int rowCount,
    required bool succeeded,
    String error = '',
  }) async {
    final entry = SqlHistoryEntry(
      id: startedAt.microsecondsSinceEpoch.toString(),
      sql: sql,
      connection: connection,
      startedAt: startedAt,
      elapsedMilliseconds: elapsedMilliseconds,
      rowCount: rowCount,
      succeeded: succeeded,
      error: error,
    );
    if (!mounted) return;
    setState(() {
      _sqlHistory = [entry, ..._sqlHistory].take(500).toList();
    });
    await _historyStore.save(_sqlHistory);
  }

  Future<void> _loadResultGridRenderer() async {
    final preferences = await SharedPreferences.getInstance();
    final saved = preferences.getString(_resultGridRendererKey);
    if (!mounted || saved == null) return;
    setState(() {
      _resultGridRenderer = saved == ResultGridRenderer.pluto.name
          ? ResultGridRenderer.pluto
          : ResultGridRenderer.queryDock;
    });
  }

  Future<void> _setResultGridRenderer(ResultGridRenderer renderer) async {
    if (_resultGridRenderer == renderer) return;
    setState(() => _resultGridRenderer = renderer);
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(_resultGridRendererKey, renderer.name);
  }

  void _showAiAssistant() {
    setState(() {
      _rightPanelMode = 'assistant';
      if (!_controller.rootController.isVisible(IdePane.right.id)) {
        _controller.rootController.show(IdePane.right.id);
      }
    });
  }

  Future<void> _showAiSettings() async {
    final settings = await showDialog<AiAssistantSettings>(
      context: context,
      builder: (context) => _AiSettingsDialog(initial: _aiSettings),
    );
    if (settings == null) return;
    await _aiSettingsStore.save(settings);
    if (!mounted) return;
    setState(() {
      _aiSettings = settings;
      _rightPanelMode = 'assistant';
      _logs.add('[INFO] AI assistant settings saved');
    });
  }

  void _attachCurrentScript() {
    final tab = _activeSqlTab;
    if (tab == null || tab.controller.text.trim().isEmpty) return;
    _addAiAttachment(
      _AiAttachment(
        id: 'script:${tab.title}',
        label: tab.title,
        icon: Icons.description_outlined,
        content: 'SQL script "${tab.title}":\n${tab.controller.text}',
      ),
    );
  }

  void _attachSelectedSql() {
    final tab = _activeSqlTab;
    if (tab == null) return;
    final selection = tab.controller.selection;
    if (!selection.isValid || selection.isCollapsed) {
      setState(() => _logs.add('[WARN] Select SQL before attaching it.'));
      return;
    }
    final sql = selection.textInside(tab.controller.text).trim();
    if (sql.isEmpty) return;
    _addAiAttachment(
      _AiAttachment(
        id: 'selection:${tab.title}:$sql',
        label: 'Selected SQL',
        icon: Icons.code,
        content: 'Selected SQL from "${tab.title}":\n$sql',
      ),
    );
  }

  Future<void> _attachSchema() async {
    final connection = _activeOpenConnection;
    if (connection == null || connection.schemas.isEmpty) {
      setState(() {
        _logs.add('[WARN] Connect and load a schema before attaching it.');
      });
      return;
    }
    final schema = await showDialog<DatabaseSchema>(
      context: context,
      builder: (context) => _AiSchemaPicker(schemas: connection.schemas),
    );
    if (!mounted || schema == null) return;
    _attachSchemaContext(connection, schema);
  }

  void _attachSchemaContext(_OpenConnection connection, DatabaseSchema schema) {
    final database = connection.config.database;
    _addAiAttachment(
      _AiAttachment(
        id: 'schema:${connection.config.endpointName}:${schema.name}',
        label: '$database.${schema.name}',
        icon: Icons.account_tree_outlined,
        content: _schemaAiContext(connection, schema),
      ),
    );
  }

  Future<void> _attachTable() async {
    final connection = _activeOpenConnection;
    if (connection == null) {
      setState(() => _logs.add('[WARN] Connect before attaching a table.'));
      return;
    }
    final choices = [
      for (final schema in connection.schemas)
        for (final table in schema.tables)
          _AiTableChoice(schema: schema.name, table: table),
    ];
    if (choices.isEmpty) {
      setState(() {
        _logs.add('[WARN] Expand a schema to load its tables first.');
      });
      return;
    }
    final choice = await showDialog<_AiTableChoice>(
      context: context,
      builder: (context) => _AiTablePicker(tables: choices),
    );
    if (!mounted || choice == null) return;

    var table = choice.table;
    if (!table.columnsLoaded) {
      await _loadTableColumnsForConnection(connection, choice.schema, table);
      table =
          connection.schemas
              .where((schema) => schema.name == choice.schema)
              .expand((schema) => schema.tables)
              .where((candidate) => candidate.name == table.name)
              .firstOrNull ??
          table;
    }
    if (!mounted) return;
    _attachTableContext(connection, choice.schema, table);
  }

  void _attachTableContext(
    _OpenConnection connection,
    String schema,
    DatabaseTable table,
  ) {
    final database = connection.config.database;
    _addAiAttachment(
      _AiAttachment(
        id: 'table:${connection.config.endpointName}:$schema.${table.name}',
        label: '$database.$schema.${table.name}',
        icon: Icons.table_chart_outlined,
        content: _tableAiContext(connection, schema, table),
      ),
    );
  }

  Future<void> _attachNavigatorSchema(
    _OpenConnection connection,
    DatabaseSchema schema,
  ) async {
    if (!await _ensureConnection(connection)) return;
    if (!schema.tablesLoaded) {
      await _loadSchemaTables(connection, schema.name);
    }
    if (!mounted) return;
    final loaded =
        connection.schemas
            .where((item) => item.name == schema.name)
            .firstOrNull ??
        schema;
    _attachSchemaContext(connection, loaded);
  }

  Future<void> _attachNavigatorTable(
    _OpenConnection connection,
    String schema,
    DatabaseTable table,
  ) async {
    if (!await _ensureConnection(connection)) return;
    var loaded = table;
    if (!table.columnsLoaded) {
      await _loadTableColumnsForConnection(connection, schema, table);
      loaded =
          connection.schemas
              .where((item) => item.name == schema)
              .expand((item) => item.tables)
              .where((item) => item.name == table.name)
              .firstOrNull ??
          table;
    }
    if (!mounted) return;
    _attachTableContext(connection, schema, loaded);
  }

  void _addAiAttachment(_AiAttachment attachment) {
    setState(() {
      _rightPanelMode = 'assistant';
      _aiAttachments.removeWhere((item) => item.id == attachment.id);
      _aiAttachments.add(attachment);
    });
  }

  String _schemaAiContext(_OpenConnection connection, DatabaseSchema schema) {
    final buffer = StringBuffer()
      ..writeln('Connection: ${connection.config.displayName}')
      ..writeln('Database: ${connection.config.database}')
      ..writeln('Schema: ${schema.name}');
    if (schema.tables.isEmpty) {
      buffer.writeln('Tables: metadata not loaded');
    } else {
      buffer.writeln('Tables:');
      for (final table in schema.tables) {
        buffer.writeln('- ${table.name}');
        if (table.columnsLoaded) {
          for (final column in table.columns) {
            buffer.writeln(
              '  - ${column.name}: ${column.dataType}'
              '${column.primaryKey ? ' PRIMARY KEY' : ''}'
              '${column.nullable ? '' : ' NOT NULL'}',
            );
          }
        }
      }
    }
    return buffer.toString();
  }

  String _tableAiContext(
    _OpenConnection connection,
    String schema,
    DatabaseTable table,
  ) {
    final buffer = StringBuffer()
      ..writeln('Connection: ${connection.config.displayName}')
      ..writeln('Database: ${connection.config.database}')
      ..writeln('Schema: $schema')
      ..writeln(
        'PostgreSQL table: ${connection.config.database}.$schema.${table.name}',
      )
      ..writeln('Columns:');
    for (final column in table.columns) {
      buffer.writeln(
        '- ${column.name}: ${column.dataType}'
        '${column.primaryKey ? ' PRIMARY KEY' : ''}'
        '${column.nullable ? '' : ' NOT NULL'}',
      );
    }
    if (table.constraints.isNotEmpty) {
      buffer
        ..writeln('Constraints:')
        ..writeln(table.constraints.map((item) => '- $item').join('\n'));
    }
    if (table.indexes.isNotEmpty) {
      buffer
        ..writeln('Indexes:')
        ..writeln(table.indexes.map((item) => '- $item').join('\n'));
    }
    if (table.foreignKeys.isNotEmpty) {
      buffer
        ..writeln('Foreign keys:')
        ..writeln(table.foreignKeys.map((item) => '- $item').join('\n'));
    }
    return buffer.toString();
  }

  Future<void> _sendAiPrompt() async {
    final prompt = _aiPromptController.text.trim();
    if (prompt.isEmpty || _aiSending) return;
    if (!_aiSettings.configured) {
      await _showAiSettings();
      if (!_aiSettings.configured) return;
    }

    final userMessage = AiAssistantMessage(role: 'user', text: prompt);
    final conversation = [..._aiMessages, userMessage];
    setState(() {
      _aiMessages.add(userMessage);
      _aiPromptController.clear();
      _aiSending = true;
    });

    try {
      final response = await _aiClient.respond(
        settings: _aiSettings,
        conversation: conversation,
        context: _aiAttachments.map((item) => item.content).join('\n\n---\n\n'),
        databaseEngine: _activeAiDatabaseEngine,
      );
      if (!mounted) return;
      setState(() {
        _aiMessages.add(AiAssistantMessage(role: 'assistant', text: response));
        _aiSending = false;
      });
    } on AiRequestCancelledException {
      if (!mounted) return;
      setState(() {
        _aiMessages.add(
          const AiAssistantMessage(
            role: 'assistant',
            text: 'Request cancelled.',
          ),
        );
        _aiSending = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _aiMessages.add(
          AiAssistantMessage(role: 'assistant', text: 'Error: $error'),
        );
        _aiSending = false;
      });
    }
  }

  void _cancelAiRequest() {
    if (!_aiSending) return;
    _aiClient.cancel();
  }

  String get _activeAiDatabaseEngine {
    final tab = _activeSqlTab;
    if (tab != null) {
      if (_db2ConnectionForKey(tab.connectionKey) != null) return 'DB2';
      if (_mySqlConnectionForKey(tab.connectionKey) != null) return 'MySQL';
      if (_connectionForKey(tab.connectionKey) != null) return 'PostgreSQL';
    }
    if (_activeDb2Connection?.session != null) return 'DB2';
    if (_activeMySqlConnection?.database != null) return 'MySQL';
    if (_sqliteWorkbenchActive) return 'SQLite';
    if (_database != null) return 'PostgreSQL';
    return 'SQL';
  }

  String? _sqlFromAiMessage(String text) {
    return RegExp(
      r'```sql\s*([\s\S]*?)```',
      caseSensitive: false,
    ).firstMatch(text)?.group(1)?.trim();
  }

  void _insertAiSql(String sql) {
    final controller = _activeSqlTab?.controller;
    if (controller == null) return;
    final selection = controller.selection;
    final start = selection.isValid ? selection.start : controller.text.length;
    final end = selection.isValid ? selection.end : controller.text.length;
    final prefix =
        start > 0 && !controller.text.substring(0, start).endsWith('\n')
        ? '\n'
        : '';
    final insertion = '$prefix$sql';
    controller.value = TextEditingValue(
      text: controller.text.replaceRange(start, end, insertion),
      selection: TextSelection.collapsed(offset: start + insertion.length),
    );
    controller.selection = TextSelection.collapsed(
      offset: start + insertion.length,
    );
    _activeSqlTab?.focusNode.requestFocus();
  }

  Future<void> _openAiSqlInNewScript(String sql) async {
    await _newSqlScript();
    final tab = _activeSqlTab;
    if (tab == null) return;
    tab.controller.value = TextEditingValue(
      text: sql,
      selection: TextSelection.collapsed(offset: sql.length),
    );
  }

  Future<void> _requestAiCompletion(_SqlScriptTab tab) async {
    if (tab.aiCompleting) return;
    if (!_aiSettings.configured) {
      await _showAiSettings();
      if (!_aiSettings.configured) return;
    }
    final selection = tab.controller.selection;
    final cursor = selection.isValid
        ? selection.baseOffset.clamp(0, tab.controller.text.length)
        : tab.controller.text.length;
    final prefix = tab.controller.text.substring(0, cursor);
    if (prefix.trim().isEmpty) return;

    setState(() {
      tab.aiCompleting = true;
      tab.aiSuggestion = null;
    });
    try {
      final response = await _aiClient.respond(
        settings: _aiSettings,
        conversation: [
          AiAssistantMessage(
            role: 'user',
            text:
                'Continue the SQL at the cursor. Return only the SQL text that '
                'should be appended, inside one ```sql block. Do not repeat the '
                'existing prefix.\n\nExisting prefix:\n$prefix',
          ),
        ],
        context: _aiAttachments.map((item) => item.content).join('\n\n---\n\n'),
        databaseEngine: _activeAiDatabaseEngine,
      );
      final suggestion = _sqlFromAiMessage(response) ?? response.trim();
      if (!mounted) return;
      setState(() {
        tab.aiCompleting = false;
        tab.aiSuggestion = suggestion.isEmpty ? null : suggestion;
      });
    } on AiRequestCancelledException {
      if (!mounted) return;
      setState(() => tab.aiCompleting = false);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        tab.aiCompleting = false;
        _logs.add('[ERROR] AI completion failed: $error');
      });
      _showResultTab('Messages');
    }
  }

  void _acceptAiCompletion(_SqlScriptTab tab) {
    final suggestion = tab.aiSuggestion;
    if (suggestion == null || suggestion.isEmpty) return;
    final controller = tab.controller;
    final selection = controller.selection;
    final start = selection.isValid ? selection.start : controller.text.length;
    final end = selection.isValid ? selection.end : controller.text.length;
    controller.value = TextEditingValue(
      text: controller.text.replaceRange(start, end, suggestion),
      selection: TextSelection.collapsed(offset: start + suggestion.length),
    );
    setState(() => tab.aiSuggestion = null);
  }

  Future<void> _newConnection() async {
    final engine = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('New Connection'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, 'postgresql'),
            child: const ListTile(
              leading: Icon(Icons.dns_outlined),
              title: Text('PostgreSQL'),
              subtitle: Text('Server connection'),
            ),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, 'sqlite'),
            child: const ListTile(
              leading: Icon(Icons.storage_outlined),
              title: Text('SQLite'),
              subtitle: Text('Local database file'),
            ),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, 'mysql'),
            child: const ListTile(
              leading: Icon(Icons.dns_outlined),
              title: Text('MySQL'),
              subtitle: Text('MySQL or MariaDB server'),
            ),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, 'db2'),
            child: const ListTile(
              leading: Icon(Icons.dns_outlined),
              title: Text('IBM Db2'),
              subtitle: Text('Db2 through local Go backend'),
            ),
          ),
        ],
      ),
    );
    if (!mounted || engine == null) return;
    if (engine == 'db2') {
      final config = await showDialog<Db2ConnectionConfig>(
        context: context,
        builder: (context) => const Db2ConnectionDialog(),
      );
      if (config == null) return;
      await _db2ConnectionStore.save(config);
      if (!mounted) return;
      setState(() {
        final existing = _db2Connections.indexWhere(
          (connection) => connection.config.endpointName == config.endpointName,
        );
        if (existing == -1) {
          _db2Connections.insert(0, _OpenDb2Connection(config: config));
        } else {
          _db2Connections[existing].config = config;
          _db2Connections[existing].connectionError = null;
        }
        _activeConnection = config.displayName;
        _activeSchema = '-';
        _activeDriver = 'db2';
        _status = 'Disconnected';
        _logs.add(
          '[INFO] Saved DB2 profile: ${config.displayName}. Expand it to connect.',
        );
      });
      _showResultTab('Messages');
      return;
    }
    if (engine == 'mysql') {
      final config = await showDialog<MySqlConnectionConfig>(
        context: context,
        builder: (context) => const MySqlConnectionDialog(),
      );
      if (config == null) return;
      await _mySqlConnectionStore.save(config);
      if (!mounted) return;
      setState(() {
        final existing = _mySqlConnections.indexWhere(
          (connection) => connection.config.endpointName == config.endpointName,
        );
        if (existing == -1) {
          _mySqlConnections.insert(0, _OpenMySqlConnection(config: config));
        } else {
          _mySqlConnections[existing].config = config;
          _mySqlConnections[existing].connectionError = null;
        }
        _activeConnection = config.displayName;
        _activeSchema = '-';
        _activeDriver = 'mysql';
        _status = 'Disconnected';
        _logs.add(
          '[INFO] Saved MySQL profile: ${config.displayName}. Expand it to connect.',
        );
      });
      _showResultTab('Messages');
      return;
    }
    if (engine == 'sqlite') {
      setState(() {
        _sqliteWorkbenchOpen = true;
        _sqliteWorkbenchActive = true;
        _activeConnection = 'SQLite';
        _activeSchema = 'main';
        _activeDriver = 'sqlite3';
        _status = 'Ready';
      });
      _revealLastCenterTab();
      return;
    }

    final savedConnections = await _connectionStore.load();

    if (!mounted) return;

    final config = await showDialog<PostgresConnectionConfig>(
      context: context,
      builder: (context) =>
          PostgresConnectionDialog(savedConnections: savedConnections),
    );

    if (config == null) return;

    await _connectionStore.save(config);

    if (!mounted) return;

    setState(() {
      final existingIndex = _connections.indexWhere(
        (connection) => connection.config.endpointName == config.endpointName,
      );
      if (existingIndex == -1) {
        _connections.insert(
          0,
          _OpenConnection(config: config, schemas: const []),
        );
      } else {
        _connections[existingIndex].config = config;
        _connections[existingIndex].connectionError = null;
      }
      _status = _database == null ? 'Disconnected' : _status;
      _logs.add(
        '[INFO] Saved PostgreSQL profile: ${config.displayName}. Expand it to connect.',
      );
    });
    _showResultTab('Messages');
  }

  Future<void> _editConnection(_OpenConnection connection) async {
    final savedConnections = await _connectionStore.load();

    if (!mounted) return;

    final previousConfig = connection.config;
    final config = await showDialog<PostgresConnectionConfig>(
      context: context,
      builder: (context) => PostgresConnectionDialog(
        savedConnections: savedConnections,
        initialConfig: previousConfig,
      ),
    );

    if (config == null) return;

    await _connectionStore.delete(previousConfig);
    await _connectionStore.save(config);
    await _invalidateConnection(connection, quiet: true);

    if (!mounted) return;

    setState(() {
      for (final tab in _sqlTabs) {
        if (tab.connectionKey == previousConfig.endpointName ||
            tab.connectionKey == previousConfig.displayName) {
          tab.connectionKey = config.endpointName;
        }
      }
      connection.config = config;
      connection.connectionError = null;
      _activeConnection = config.displayName;
      _activeDriver = 'postgres ${config.sslMode.name}';
      _logs.add('[INFO] Updated connection profile: ${config.displayName}');
    });
    _showResultTab('Messages');
  }

  Future<void> _editMySqlConnection(_OpenMySqlConnection connection) async {
    final previous = connection.config;
    final config = await showDialog<MySqlConnectionConfig>(
      context: context,
      builder: (context) => MySqlConnectionDialog(initial: previous),
    );
    if (config == null) return;
    if (config.endpointName != previous.endpointName) {
      await _mySqlConnectionStore.delete(previous);
    }
    await _mySqlConnectionStore.save(config);
    await _invalidateMySqlConnection(connection, quiet: true);
    if (!mounted) return;
    setState(() {
      for (final tab in _sqlTabs) {
        if (tab.connectionKey == _mySqlConnectionKey(previous)) {
          tab.connectionKey = _mySqlConnectionKey(config);
        }
      }
      connection.config = config;
      connection.connectionError = null;
      _logs.add('[INFO] Updated MySQL profile: ${config.displayName}');
    });
  }

  Future<void> _deleteMySqlConnection(_OpenMySqlConnection connection) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete MySQL Connection'),
        content: Text('Delete ${connection.config.displayName}?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _invalidateMySqlConnection(connection, quiet: true);
    await _mySqlConnectionStore.delete(connection.config);
    if (!mounted) return;
    setState(() {
      _mySqlConnections.remove(connection);
      _logs.add(
        '[INFO] Deleted MySQL profile: ${connection.config.displayName}',
      );
    });
  }

  Future<void> _invalidateMySqlConnection(
    _OpenMySqlConnection connection, {
    bool quiet = false,
  }) async {
    await connection.session?.close();
    if (!mounted) return;
    setState(() {
      final removed = _openTableTabs.where(
        (tab) =>
            tab.profile.engine == DatabaseEngine.mysql &&
            tab.profile.id == connection.config.id,
      );
      for (final tab in removed) {
        tab.dispose();
      }
      _openTableTabs.removeWhere(
        (tab) =>
            tab.profile.engine == DatabaseEngine.mysql &&
            tab.profile.id == connection.config.id,
      );
      connection.session = null;
      connection.database = null;
      connection.tables = const [];
      connection.connectionError = null;
      connection.isConnecting = false;
      if (!quiet) {
        _logs.add(
          '[INFO] Invalidated MySQL connection: ${connection.config.displayName}',
        );
      }
      final totalTabs = _sqlTabs.length + _openTableTabs.length;
      if (totalTabs == 0) {
        _activeCenterTab = 0;
      } else if (_activeCenterTab >= totalTabs) {
        _activeCenterTab = totalTabs - 1;
      }
    });
  }

  Future<bool> _ensureMySqlConnection(_OpenMySqlConnection connection) async {
    if (connection.session != null) {
      _activateMySqlConnection(connection);
      return true;
    }
    if (connection.isConnecting) return false;
    setState(() {
      connection.isConnecting = true;
      connection.connectionError = null;
      _isConnecting = true;
      _status = 'Connecting';
      _activeConnection = connection.config.displayName;
      _activeMySqlConnection = connection;
    });
    try {
      final session =
          await _mySqlDriver.connect(connection.config) as MySqlSession;
      final database = session.database;
      final tables = await session.loadTables(connection.config.database);
      if (!mounted) {
        await database.close();
        return false;
      }
      setState(() {
        connection.database = database;
        connection.session = session;
        connection.tables = tables;
        connection.isConnecting = false;
        _isConnecting =
            _connections.any((item) => item.isConnecting) ||
            _mySqlConnections.any((item) => item.isConnecting) ||
            _db2Connections.any((item) => item.isConnecting);
        _activeConnection = connection.config.displayName;
        _activeMySqlConnection = connection;
        _activeSchema = connection.config.database;
        _activeDriver = 'mysql ${connection.config.secure ? 'tls' : 'plain'}';
        _status = 'Connected';
        _logs.add('[INFO] Connected to MySQL ${connection.config.database}');
      });
      return true;
    } catch (error) {
      if (!mounted) return false;
      setState(() {
        connection.isConnecting = false;
        connection.connectionError = error.toString();
        _isConnecting =
            _connections.any((item) => item.isConnecting) ||
            _mySqlConnections.any((item) => item.isConnecting) ||
            _db2Connections.any((item) => item.isConnecting);
        _status = 'Connection failed';
        _logs.add('[ERROR] MySQL connection failed: $error');
      });
      _showResultTab('Messages');
      return false;
    }
  }

  void _activateMySqlConnection(_OpenMySqlConnection connection) {
    setState(() {
      _activeMySqlConnection = connection;
      _activeDb2Connection = null;
      _sessions = const [];
      _activeConnection = connection.config.displayName;
      _activeSchema = connection.config.database;
      _activeDriver = 'mysql ${connection.config.secure ? 'tls' : 'plain'}';
      _status = connection.database == null ? 'Disconnected' : 'Connected';
      _logs.add(
        '[INFO] Activated MySQL connection: ${connection.config.displayName}',
      );
    });
    if (_rightPanelMode == 'sessions') {
      unawaited(_refreshSessions());
    }
  }

  Future<void> _editDb2Connection(_OpenDb2Connection connection) async {
    final previous = connection.config;
    final config = await showDialog<Db2ConnectionConfig>(
      context: context,
      builder: (context) => Db2ConnectionDialog(initial: previous),
    );
    if (config == null) return;
    if (config.endpointName != previous.endpointName) {
      await _db2ConnectionStore.delete(previous);
    }
    await _db2ConnectionStore.save(config);
    await _invalidateDb2Connection(connection, quiet: true);
    if (!mounted) return;
    setState(() {
      for (final tab in _sqlTabs) {
        if (tab.connectionKey == _db2ConnectionKey(previous)) {
          tab.connectionKey = _db2ConnectionKey(config);
        }
      }
      connection.config = config;
      connection.connectionError = null;
      _logs.add('[INFO] Updated DB2 profile: ${config.displayName}');
    });
  }

  Future<void> _deleteDb2Connection(_OpenDb2Connection connection) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete DB2 Connection'),
        content: Text('Delete ${connection.config.displayName}?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _invalidateDb2Connection(connection, quiet: true);
    await _db2ConnectionStore.delete(connection.config);
    if (!mounted) return;
    setState(() {
      _db2Connections.remove(connection);
      _logs.add('[INFO] Deleted DB2 profile: ${connection.config.displayName}');
    });
  }

  Future<void> _invalidateDb2Connection(
    _OpenDb2Connection connection, {
    bool quiet = false,
  }) async {
    await connection.session?.close();
    if (!mounted) return;
    setState(() {
      final removed = _openTableTabs.where(
        (tab) =>
            tab.profile.engine == DatabaseEngine.db2 &&
            tab.profile.id == connection.config.id,
      );
      for (final tab in removed) {
        tab.dispose();
      }
      _openTableTabs.removeWhere(
        (tab) =>
            tab.profile.engine == DatabaseEngine.db2 &&
            tab.profile.id == connection.config.id,
      );
      connection.session = null;
      connection.database = null;
      connection.schemas = const [];
      connection.connectionError = null;
      connection.isConnecting = false;
      if (identical(_activeDb2Connection, connection)) {
        _activeDb2Connection = null;
      }
      if (!quiet) {
        _logs.add(
          '[INFO] Invalidated DB2 connection: ${connection.config.displayName}',
        );
      }
      final totalTabs = _sqlTabs.length + _openTableTabs.length;
      if (totalTabs == 0) {
        _activeCenterTab = 0;
      } else if (_activeCenterTab >= totalTabs) {
        _activeCenterTab = totalTabs - 1;
      }
    });
  }

  Future<bool> _ensureDb2Connection(_OpenDb2Connection connection) async {
    if (connection.session != null) {
      _activateDb2Connection(connection);
      return true;
    }
    if (connection.isConnecting) return false;
    setState(() {
      connection.isConnecting = true;
      connection.connectionError = null;
      _isConnecting = true;
      _status = 'Connecting';
      _activeConnection = connection.config.displayName;
      _activeDb2Connection = connection;
      _activeMySqlConnection = null;
    });
    try {
      final session = await _db2Driver.connect(connection.config) as Db2Session;
      final schemas = await session.loadSchemas();
      if (!mounted) {
        await session.close();
        return false;
      }
      setState(() {
        connection.database = session.database;
        connection.session = session;
        connection.schemas = schemas;
        connection.isConnecting = false;
        _isConnecting =
            _connections.any((item) => item.isConnecting) ||
            _mySqlConnections.any((item) => item.isConnecting) ||
            _db2Connections.any((item) => item.isConnecting);
        _activeDb2Connection = connection;
        _activeMySqlConnection = null;
        _activeConnection = connection.config.displayName;
        _activeSchema = schemas.isEmpty ? '-' : schemas.first.name;
        _activeDriver = 'db2 via Go';
        _status = 'Connected';
        _logs.add('[INFO] Connected to DB2 ${connection.config.database}');
      });
      return true;
    } catch (error) {
      if (!mounted) return false;
      setState(() {
        connection.isConnecting = false;
        connection.connectionError = error.toString();
        _isConnecting =
            _connections.any((item) => item.isConnecting) ||
            _mySqlConnections.any((item) => item.isConnecting) ||
            _db2Connections.any((item) => item.isConnecting);
        _status = 'Connection failed';
        _logs.add('[ERROR] DB2 connection failed: $error');
      });
      _showResultTab('Messages');
      return false;
    }
  }

  void _activateDb2Connection(_OpenDb2Connection connection) {
    setState(() {
      _activeDb2Connection = connection;
      _activeMySqlConnection = null;
      _sessions = const [];
      _activeConnection = connection.config.displayName;
      _activeSchema = connection.schemas.isEmpty
          ? '-'
          : connection.schemas.first.name;
      _activeDriver = 'db2 via Go';
      _status = connection.session == null ? 'Disconnected' : 'Connected';
      _logs.add(
        '[INFO] Activated DB2 connection: ${connection.config.displayName}',
      );
    });
  }

  Future<void> _deleteConnection(_OpenConnection connection) async {
    final database = connection.database;
    if (database != null && !await _confirmPendingTransaction(database)) {
      return;
    }
    if (!mounted) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Connection'),
        content: Text(
          'Delete ${connection.config.displayName} from the navigator?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    await _connectionStore.delete(connection.config);
    await _invalidateConnection(
      connection,
      quiet: true,
      skipTransactionPrompt: true,
    );

    if (!mounted) return;

    setState(() {
      _connections.remove(connection);
      if (_database == null ||
          _activeConnection == connection.config.displayName) {
        _activeConnection = 'No Connection';
        _activeSchema = '-';
        _activeDriver = '-';
        _status = 'Disconnected';
      }
      _logs.add(
        '[INFO] Deleted connection profile: ${connection.config.displayName}',
      );
    });
    _showResultTab('Messages');
  }

  Future<void> _invalidateConnection(
    _OpenConnection connection, {
    bool quiet = false,
    bool skipTransactionPrompt = false,
  }) async {
    final database = connection.database;
    if (database == null) {
      if (!quiet && mounted) {
        setState(() {
          connection.schemas = const [];
          connection.connectionError = null;
          _logs.add(
            '[INFO] Connection is already invalidated: ${connection.config.displayName}',
          );
        });
      }
      return;
    }

    if (!skipTransactionPrompt && !await _confirmPendingTransaction(database)) {
      return;
    }
    await database.close();

    if (!mounted) return;

    setState(() {
      connection.database = null;
      connection.schemas = const [];
      connection.connectionError = null;
      connection.isConnecting = false;
      for (var index = _openTableTabs.length - 1; index >= 0; index--) {
        final tab = _openTableTabs[index];
        if (tab.session is PostgresSession &&
            (tab.session as PostgresSession).database == database) {
          _openTableTabs.removeAt(index);
          tab.dispose();
        }
      }
      final centerTabCount = _sqlTabs.length + _openTableTabs.length;
      if (centerTabCount == 0) {
        _activeCenterTab = 0;
      } else if (_activeCenterTab >= centerTabCount) {
        _activeCenterTab = centerTabCount - 1;
      }
      if (_database == database) {
        _database = null;
        _activeConnection = connection.config.displayName;
        _activeSchema = '-';
        _activeDriver = 'postgres ${connection.config.sslMode.name}';
        _status = 'Disconnected';
      }
      _isConnecting =
          _connections.any((item) => item.isConnecting) ||
          _mySqlConnections.any((item) => item.isConnecting) ||
          _db2Connections.any((item) => item.isConnecting);
      if (!quiet) {
        _logs.add(
          '[INFO] Invalidated connection: ${connection.config.displayName}',
        );
      }
    });
    if (!quiet) {
      _showResultTab('Messages');
    }
  }

  void _invalidateActiveConnection() {
    final connection = _activeOpenConnection;
    if (connection == null) {
      setState(() {
        _logs.add('[WARN] No active connection to invalidate.');
      });
      _showResultTab('Messages');
      return;
    }
    unawaited(_invalidateConnection(connection));
  }

  Future<bool> _ensureConnection(_OpenConnection connection) async {
    if (connection.database != null) {
      if (connection.database != _database) {
        _activateConnection(connection);
      }
      return true;
    }
    if (connection.isConnecting) return false;

    setState(() {
      connection.isConnecting = true;
      connection.connectionError = null;
      _isConnecting = true;
      _status = 'Connecting';
      _activeConnection = connection.config.displayName;
      _logs.add(
        '[INFO] Connecting to PostgreSQL: ${connection.config.displayName}',
      );
    });
    _showResultTab('Messages');

    try {
      final database = await PostgresDatabase.connect(connection.config);
      final schemas = await database.loadSchemas(forceRefresh: true);

      if (!mounted) {
        unawaited(database.close());
        return false;
      }

      setState(() {
        connection.database = database;
        connection.schemas = List<DatabaseSchema>.of(schemas);
        connection.isConnecting = false;
        _isConnecting =
            _connections.any((item) => item.isConnecting) ||
            _mySqlConnections.any((item) => item.isConnecting) ||
            _db2Connections.any((item) => item.isConnecting);
        _database = database;
        _activeConnection = connection.config.displayName;
        _activeSchema = schemas.isEmpty ? '-' : schemas.first.name;
        _activeDriver = 'postgres ${connection.config.sslMode.name}';
        _status = 'Connected';
        _columns = [];
        _rows = [];
        _filterSqlTabsForActiveConnection();
        _logs.add('[INFO] Connected to ${connection.config.database}');
        _logs.add('[INFO] Loaded ${schemas.length} schemas');
      });
      return true;
    } catch (error) {
      if (!mounted) return false;

      setState(() {
        connection.isConnecting = false;
        connection.connectionError = error.toString();
        _isConnecting =
            _connections.any((item) => item.isConnecting) ||
            _mySqlConnections.any((item) => item.isConnecting) ||
            _db2Connections.any((item) => item.isConnecting);
        if (_database == null) {
          _status = 'Connection failed';
          _activeSchema = '-';
        }
        _logs.add('[ERROR] PostgreSQL connection failed: $error');
      });
      _showResultTab('Messages');
      return false;
    }
  }

  Future<void> _executeSql() async {
    final tab = _activeSqlTab;
    final db2Connection = tab == null
        ? null
        : _db2ConnectionForKey(tab.connectionKey);
    if (db2Connection != null) {
      if (!await _ensureDb2Connection(db2Connection)) return;
      final execution = _sqlToExecute();
      await _runSharedSessionSql(
        execution.sql,
        db2Connection.session!,
        engineName: 'DB2',
        loadingOperation: 'Executing DB2 SQL...',
        editorText: tab?.controller.text,
        editorOffset: execution.offset,
      );
      return;
    }
    final mySqlConnection = tab == null
        ? null
        : _mySqlConnectionForKey(tab.connectionKey);
    if (mySqlConnection != null) {
      if (!await _ensureMySqlConnection(mySqlConnection)) return;
      final execution = _sqlToExecute();
      await _runMySql(
        execution.sql,
        mySqlConnection.session!,
        editorText: tab?.controller.text,
        editorOffset: execution.offset,
      );
      return;
    }
    final database = tab == null ? _database : await _databaseForSqlTab(tab);
    if (tab != null &&
        tab.connectionKey != _globalScriptConnectionKey &&
        database == null) {
      return;
    }
    final execution = _sqlToExecute();
    await _runSql(
      execution.sql,
      databaseOverride: database,
      editorText: tab?.controller.text,
      editorOffset: execution.offset,
      loadingOperation: 'Executing SQL...',
    );
  }

  Future<void> _runMySql(
    String sql,
    MySqlSession session, {
    String? editorText,
    int editorOffset = 0,
  }) {
    return _runSharedSessionSql(
      sql,
      session,
      engineName: 'MySQL',
      loadingOperation: 'Executing MySQL SQL...',
      editorText: editorText,
      editorOffset: editorOffset,
    );
  }

  Future<void> _runSharedSessionSql(
    String sql,
    DatabaseSession session, {
    required String engineName,
    required String loadingOperation,
    String? editorText,
    int editorOffset = 0,
  }) async {
    if (sql.trim().isEmpty) return;
    if (session.profile.writeProtected &&
        _containsMutatingSql(sql) &&
        !await _confirmProtectedWrite(session.profile)) {
      setState(() {
        _logs.add(
          '[WARN] Update cancelled for protected connection: '
          '${session.profile.displayName}',
        );
      });
      _showResultTab('Messages');
      return;
    }
    final startedAt = DateTime.now();
    setState(() {
      _isExecuting = true;
      _cancelRequested = false;
      _loadingOperation = loadingOperation;
      _activeSqlTab?.error = null;
      _clearSqlResultState();
      _logs.add('[INFO] Executing $engineName SQL...');
    });
    try {
      final run = await _queryRunner.execute(session, sql);
      final results = run.results;
      final result = run.last;
      if (!mounted) return;
      setState(() {
        _statementResults = results;
        _activeStatementResult = results.length - 1;
        _columns = result.columns;
        _rows = result.rows;
        _resultDatabase = null;
        _resultSchema = null;
        _resultTable = null;
        _resultColumnMetadata = const [];
        _resultPendingChanges.clear();
        _resultColumnFilters.clear();
        _resultSortColumn = null;
        _resultIndexesReady = false;
        _isExecuting = false;
        _loadingOperation = null;
        _logs.add(
          '[INFO] $engineName query completed: ${result.rowCount} rows, '
          '${result.affectedRows} affected',
        );
      });
      await _refreshVisibleResultIndexes();
      _showResultTab('Data');
      unawaited(
        _recordSqlHistory(
          sql: sql,
          connection: session.profile.displayName,
          startedAt: startedAt,
          elapsedMilliseconds: DateTime.now()
              .difference(startedAt)
              .inMilliseconds,
          rowCount: results.fold(0, (total, item) => total + item.rowCount),
          succeeded: true,
        ),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _isExecuting = false;
        _loadingOperation = null;
        _clearSqlResultState();
        _activeSqlTab?.error = _SqlEditorError.fromPosition(
          editorText ?? sql,
          editorOffset + 1,
          error.toString(),
        );
        _logs.add('[ERROR] $engineName query failed: $error');
      });
      unawaited(
        _recordSqlHistory(
          sql: sql,
          connection: session.profile.displayName,
          startedAt: startedAt,
          elapsedMilliseconds: DateTime.now()
              .difference(startedAt)
              .inMilliseconds,
          rowCount: 0,
          succeeded: false,
          error: error.toString(),
        ),
      );
      _showResultTab('Messages');
    }
  }

  Future<PostgresQueryResult?> _runSql(
    String sql, {
    bool updateSqlResults = true,
    PostgresDatabase? databaseOverride,
    String? editorText,
    int editorOffset = 0,
    String? loadingOperation,
  }) async {
    final database = databaseOverride ?? _database;
    final startedAt = DateTime.now();

    if (database == null) {
      setState(() {
        _logs.add('[WARN] Not connected. Expand a saved connection first.');
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

    if (database.config.writeProtected &&
        _containsMutatingSql(sql) &&
        !await _confirmProtectedWrite(database.config)) {
      setState(() {
        _logs.add(
          '[WARN] Update cancelled for protected connection: ${database.config.displayName}',
        );
      });
      _showResultTab('Messages');
      return null;
    }

    setState(() {
      _isExecuting = true;
      _executingDatabase = database;
      _cancelRequested = false;
      _loadingOperation = loadingOperation;
      _activeSqlTab?.error = null;
      if (updateSqlResults) {
        _clearSqlResultState();
      }
      _logs.add('[INFO] Executing SQL...');
      _logs.add('[SQL] ${_sqlSummary(sql)}');
    });

    try {
      final streamedRows = <List<dynamic>>[];
      final streamUiStopwatch = Stopwatch()..start();
      final statements = PostgresDatabase.splitSqlStatements(sql);
      late final List<PostgresQueryResult> statementResults;
      if (updateSqlResults && statements.length > 1) {
        statementResults = await database.executeStatements(sql);
      } else {
        statementResults = [
          await database.execute(
            sql,
            onColumns: updateSqlResults
                ? (columns) {
                    if (!mounted || !_isExecuting) return;
                    setState(() {
                      _columns = columns;
                      _rows = [];
                      _visibleResultIndexes = [];
                      _resultIndexesReady = false;
                    });
                  }
                : null,
            onRowsChunk: updateSqlResults
                ? (rows) {
                    if (!mounted || !_isExecuting) return;
                    streamedRows.addAll(rows);
                    if (streamUiStopwatch.elapsedMilliseconds >= 80) {
                      streamUiStopwatch.reset();
                      setState(() {
                        _rows = List<List<dynamic>>.of(streamedRows);
                      });
                    }
                  }
                : null,
          ),
        ];
      }
      final result = statementResults.last;

      if (!_isExecuting) return null;

      final resultContext = updateSqlResults
          ? await _resolveSqlResultContext(sql, database, result)
          : null;
      if (!_isExecuting) return null;

      setState(() {
        if (updateSqlResults) {
          _statementResults = [
            for (final result in statementResults)
              DatabaseQueryResult(
                columns: result.columns,
                rows: result.rows,
                rowCount: result.rowCount,
                affectedRows: result.affectedRows,
                elapsed: result.elapsed,
                rowLimitApplied: result.rowLimitApplied,
              ),
          ];
          _activeStatementResult = statementResults.length - 1;
          _columns = result.columns;
          _rows = streamedRows.isEmpty ? result.rows : streamedRows;
          _resultDatabase = database;
          _resultSchema = resultContext?.schema;
          _resultTable = resultContext?.table;
          _resultColumnMetadata = resultContext?.columns ?? const [];
          _resultColumnFilters.clear();
          _resultPendingChanges.clear();
          _resultSortColumn = null;
          _resultSortAscending = true;
          _resultIndexesReady = false;
        }
        _isExecuting = false;
        _executingDatabase = null;
        _cancelRequested = false;
        _loadingOperation = null;
        _logs.add('[INFO] Query executed successfully');
        _logs.add(
          '[INFO] ${result.rowCount} rows fetched, ${result.affectedRows} affected in ${result.elapsed.inMilliseconds} ms',
        );
        if (result.rowLimitApplied) {
          _logs.add(
            '[INFO] Result limited to ${PostgresDatabase.defaultMaxRows} rows to keep the UI responsive.',
          );
        }
      });
      if (updateSqlResults) {
        await _refreshVisibleResultIndexes();
        _showResultTab('Data');
      }
      unawaited(
        _recordSqlHistory(
          sql: sql,
          connection: database.config.displayName,
          startedAt: startedAt,
          elapsedMilliseconds: DateTime.now()
              .difference(startedAt)
              .inMilliseconds,
          rowCount: statementResults.fold(
            0,
            (total, item) => total + item.rowCount,
          ),
          succeeded: true,
        ),
      );
      return result;
    } catch (error) {
      if (!_isExecuting) return null;

      setState(() {
        _isExecuting = false;
        _executingDatabase = null;
        final wasCancelled = _cancelRequested;
        _cancelRequested = false;
        _loadingOperation = null;
        if (updateSqlResults) {
          _clearSqlResultState();
        }
        if (updateSqlResults && error is PostgresQueryException) {
          _activeSqlTab?.error = _SqlEditorError.fromPostgresException(
            editorText ?? sql,
            error,
            editorOffset: editorOffset,
          );
        } else if (updateSqlResults && error is ServerException) {
          _activeSqlTab?.error = _SqlEditorError.fromServerException(
            editorText ?? sql,
            error,
            editorOffset: editorOffset,
          );
        }
        _logs.add(
          wasCancelled
              ? '[INFO] Query cancelled'
              : '[ERROR] Query failed: $error',
        );
      });
      unawaited(
        _recordSqlHistory(
          sql: sql,
          connection: database.config.displayName,
          startedAt: startedAt,
          elapsedMilliseconds: DateTime.now()
              .difference(startedAt)
              .inMilliseconds,
          rowCount: 0,
          succeeded: false,
          error: error.toString(),
        ),
      );
      _showResultTab('Messages');
      return null;
    }
  }

  void _clearSqlResultState() {
    _statementResults = const [];
    _activeStatementResult = 0;
    _columns = const [];
    _rows = const [];
    _resultDatabase = null;
    _resultSchema = null;
    _resultTable = null;
    _resultColumnMetadata = const [];
    _resultColumnFilters.clear();
    _resultPendingChanges.clear();
    _visibleResultIndexes = const [];
    _resultIndexesReady = true;
    _resultSortColumn = null;
    _resultSortAscending = true;
  }

  void _clearMessages() {
    setState(() => _logs = []);
  }

  void _selectStatementResult(int index) {
    if (index < 0 || index >= _statementResults.length) return;
    final result = _statementResults[index];
    setState(() {
      _activeStatementResult = index;
      _columns = result.columns;
      _rows = result.rows;
      _resultDatabase = null;
      _resultSchema = null;
      _resultTable = null;
      _resultColumnMetadata = const [];
      _resultPendingChanges.clear();
      _resultColumnFilters.clear();
      _resultSortColumn = null;
      _resultIndexesReady = false;
    });
    unawaited(_refreshVisibleResultIndexes());
  }

  Future<void> _exportRows({
    required String suggestedBaseName,
    required List<String> columns,
    required List<List<dynamic>> rows,
    required String format,
  }) async {
    if (columns.isEmpty) return;
    final isJson = format == 'json';
    final location = await getSaveLocation(
      suggestedName: '$suggestedBaseName.$format',
      acceptedTypeGroups: [
        XTypeGroup(label: isJson ? 'JSON' : 'CSV', extensions: [format]),
      ],
    );
    if (location == null) return;
    final content = isJson
        ? const JsonEncoder.withIndent('  ').convert([
            for (final row in rows)
              {
                for (final (index, column) in columns.indexed)
                  column: index < row.length ? row[index] : null,
              },
          ])
        : const ListToCsvConverter().convert([columns, ...rows]);
    await XFile.fromData(
      utf8.encode(content),
      name: '$suggestedBaseName.$format',
      mimeType: isJson ? 'application/json' : 'text/csv',
    ).saveTo(location.path);
    if (!mounted) return;
    setState(() => _logs.add('[INFO] Exported ${rows.length} rows'));
  }

  Future<void> _exportSqlResult(String format) {
    final visibleRows = _visibleSqlResultRows;
    return _exportRows(
      suggestedBaseName: 'querydock-result',
      columns: _columns,
      rows: [for (final item in visibleRows) item.row],
      format: format,
    );
  }

  Future<void> _exportTableData(_OpenTableTab tab, String format) {
    return _exportRows(
      suggestedBaseName: '${tab.schema}-${tab.table}',
      columns: tab.resultColumns,
      rows: tab.rows,
      format: format,
    );
  }

  Future<void> _importCsvIntoTable(_OpenTableTab tab) async {
    if (tab.profile.writeProtected &&
        !await _confirmProtectedWrite(tab.profile)) {
      return;
    }
    final file = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(label: 'CSV', extensions: ['csv']),
      ],
    );
    if (file == null) return;
    final records = const CsvToListConverter(
      shouldParseNumbers: false,
    ).convert(await file.readAsString());
    if (records.length < 2) return;
    final columns = records.first.map((value) => value.toString()).toList();
    final availableColumns = tab.columns.map((column) => column.name).toSet();
    if (columns.any((column) => !availableColumns.contains(column))) {
      if (!mounted) return;
      setState(() {
        _logs.add(
          '[ERROR] CSV columns must match table columns: ${columns.join(', ')}',
        );
      });
      _showResultTab('Messages');
      return;
    }
    setState(() {
      _isExecuting = true;
      _loadingOperation = 'Importing CSV...';
    });
    try {
      final inserted = await tab.session.importRows(
        tab.schema,
        tab.table,
        columns,
        [for (final record in records.skip(1)) List<dynamic>.of(record)],
      );
      if (!mounted) return;
      setState(() {
        _isExecuting = false;
        _loadingOperation = null;
        _logs.add('[INFO] Imported $inserted rows into ${tab.id}');
      });
      await _loadTableTabData(tab, reset: true);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _isExecuting = false;
        _loadingOperation = null;
        _logs.add('[ERROR] CSV import failed: $error');
      });
      _showResultTab('Messages');
    }
  }

  Future<_SqlResultContext?> _resolveSqlResultContext(
    String sql,
    PostgresDatabase database,
    PostgresQueryResult result,
  ) async {
    if (result.columns.isEmpty || result.rowCount == 0) return null;
    final reference = _singleTableSelectReference(sql);
    if (reference == null) return null;

    try {
      final table = await database.loadTableColumns(
        reference.schema,
        reference.table,
      );
      return _SqlResultContext(
        schema: reference.schema,
        table: reference.table,
        columns: table.columns,
      );
    } catch (error) {
      if (mounted) {
        setState(() {
          _logs.add(
            '[WARN] Result editing metadata unavailable for '
            '${reference.schema}.${reference.table}: $error',
          );
        });
      }
      return null;
    }
  }

  _EditableResultReference? _singleTableSelectReference(String sql) {
    final sanitized = sql
        .replaceAll(RegExp(r'--[^\r\n]*'), ' ')
        .replaceAll(RegExp(r'/\*[\s\S]*?\*/'), ' ')
        .trim();
    if (!RegExp(r'^select\b', caseSensitive: false).hasMatch(sanitized) ||
        RegExp(
          r'\b(join|union|intersect|except|group\s+by|having)\b',
          caseSensitive: false,
        ).hasMatch(sanitized)) {
      return null;
    }

    final matches = RegExp(
      r'\bfrom\s+((?:"(?:[^"]|"")+"|[A-Za-z_][\w$]*)(?:\s*\.\s*(?:"(?:[^"]|"")+"|[A-Za-z_][\w$]*))?)',
      caseSensitive: false,
    ).allMatches(sanitized).toList();
    if (matches.length != 1) return null;

    final parts = matches.single.group(1)!.split('.');
    final names = [for (final part in parts) _unquoteIdentifier(part.trim())];
    if (names.length == 2) {
      return _EditableResultReference(schema: names[0], table: names[1]);
    }
    final schema = _activeSchema != '-' ? _activeSchema : 'public';
    return _EditableResultReference(schema: schema, table: names.single);
  }

  String _unquoteIdentifier(String identifier) {
    if (identifier.length >= 2 &&
        identifier.startsWith('"') &&
        identifier.endsWith('"')) {
      return identifier
          .substring(1, identifier.length - 1)
          .replaceAll('""', '"');
    }
    return identifier;
  }

  String _sqlSummary(String sql) {
    final keyword =
        RegExp(r'^\s*([A-Za-z]+)').firstMatch(sql)?.group(1)?.toUpperCase() ??
        'SQL';
    return '$keyword statement (${sql.length} characters)';
  }

  bool _containsMutatingSql(String sql) {
    final sanitized = sql
        .replaceAll(RegExp(r'--[^\r\n]*'), ' ')
        .replaceAll(RegExp(r'/\*[\s\S]*?\*/'), ' ')
        .replaceAll(RegExp(r"'(?:''|[^'])*'"), "''")
        .replaceAll(RegExp(r'"(?:""|[^"])*"'), '""');

    return RegExp(
      r'\b(insert|update|delete|merge|truncate|create|alter|drop|grant|revoke|comment|copy|call|do|vacuum|reindex|cluster|refresh)\b',
      caseSensitive: false,
    ).hasMatch(sanitized);
  }

  Future<bool> _confirmProtectedWrite(DatabaseProfile config) async {
    if (!mounted) return false;

    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.lock_outline),
        title: const Text('Update locked'),
        content: Text(
          '${config.displayName} is protected from data changes. Do you want to continue with this update?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Continue'),
          ),
        ],
      ),
    );

    return confirmed == true;
  }

  Future<PostgresDatabase?> _databaseForSqlTab(_SqlScriptTab tab) async {
    if (tab.connectionKey == _globalScriptConnectionKey) {
      return _database;
    }

    final connection = _connectionForKey(tab.connectionKey);
    if (connection == null) {
      setState(() {
        _logs.add(
          '[WARN] Script connection is unavailable: ${tab.connectionKey}',
        );
      });
      _showResultTab('Messages');
      return null;
    }

    if (!await _ensureConnection(connection)) return null;
    return connection.database;
  }

  _OpenConnection? _connectionForKey(String connectionKey) {
    for (final connection in _connections) {
      if (connection.config.displayName == connectionKey ||
          connection.config.endpointName == connectionKey ||
          _safeFileSegment(connection.config.endpointName) == connectionKey ||
          _safeFileSegment(connection.config.displayName) == connectionKey) {
        return connection;
      }
    }
    return null;
  }

  String _mySqlConnectionKey(MySqlConnectionConfig config) {
    return 'mysql:${config.endpointName}';
  }

  String _db2ConnectionKey(Db2ConnectionConfig config) {
    return 'db2:${config.endpointName}';
  }

  _OpenMySqlConnection? _mySqlConnectionForKey(String connectionKey) {
    for (final connection in _mySqlConnections) {
      if (connectionKey == _mySqlConnectionKey(connection.config)) {
        return connection;
      }
    }
    return null;
  }

  _OpenDb2Connection? _db2ConnectionForKey(String connectionKey) {
    for (final connection in _db2Connections) {
      if (connectionKey == _db2ConnectionKey(connection.config)) {
        return connection;
      }
    }
    return null;
  }

  Future<void> _setSqlTabConnection(
    _SqlScriptTab tab,
    String connectionKey,
  ) async {
    final oldFile = tab.file;
    File? newFile;

    if (oldFile != null) {
      final directory = await _sqlScriptsDirectoryForConnection(connectionKey);
      newFile = File(_scriptPath(directory, tab.title));
      await newFile.writeAsString(tab.controller.text);
      if (oldFile.path != newFile.path && oldFile.existsSync()) {
        await oldFile.delete();
      }
    }

    if (!mounted) return;

    setState(() {
      tab.connectionKey = connectionKey;
      if (newFile != null) {
        tab.file = newFile;
      }
      _logs.add(
        '[INFO] Associated ${tab.title} with ${_scriptConnectionLabel(connectionKey)}',
      );
    });
  }

  String _scriptConnectionLabel(String connectionKey) {
    if (connectionKey == _globalScriptConnectionKey) {
      return 'No connection';
    }
    final mySql = _mySqlConnectionForKey(connectionKey);
    if (mySql != null) return '${mySql.config.displayName} (MySQL)';
    final db2 = _db2ConnectionForKey(connectionKey);
    if (db2 != null) return '${db2.config.displayName} (DB2)';
    return _connectionForKey(connectionKey)?.config.displayName ??
        connectionKey;
  }

  void _stopQuery() {
    if (!_isExecuting) {
      setState(() {
        _logs.add('[INFO] No running query to stop.');
      });
      return;
    }

    unawaited(_cancelRunningQuery());
  }

  Future<void> _setAutoCommit(bool enabled) async {
    final session = _activeDatabaseSession;
    if (session == null) return;
    try {
      await session.setAutoCommit(enabled);
      if (!mounted) return;
      setState(() {
        _logs.add(
          '[INFO] ${enabled ? 'Enabled auto-commit' : 'Enabled manual commit mode'}',
        );
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _logs.add('[WARN] $error'));
      _showResultTab('Messages');
    }
  }

  Future<void> _commitTransaction() async {
    final session = _activeDatabaseSession;
    if (session == null) return;
    await session.commit();
    if (!mounted) return;
    setState(() => _logs.add('[INFO] Transaction committed'));
  }

  Future<void> _rollbackTransaction() async {
    final session = _activeDatabaseSession;
    if (session == null) return;
    await session.rollback();
    if (!mounted) return;
    setState(() => _logs.add('[INFO] Transaction rolled back'));
  }

  Future<bool> _confirmPendingTransaction(PostgresDatabase? database) async {
    if (database == null || !database.transactionActive || !mounted) {
      return true;
    }
    final action = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.warning_amber_rounded),
        title: const Text('Pending transaction'),
        content: Text(
          '${database.config.displayName} has uncommitted changes. '
          'Commit or roll them back before disconnecting.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, 'cancel'),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, 'rollback'),
            child: const Text('Rollback'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, 'commit'),
            child: const Text('Commit'),
          ),
        ],
      ),
    );
    if (action == 'commit') {
      await database.commit();
      return true;
    }
    if (action == 'rollback') {
      await database.rollback();
      return true;
    }
    return false;
  }

  Future<void> _cancelRunningQuery() async {
    final database = _executingDatabase;
    if (database == null || _cancelRequested) return;
    setState(() {
      _cancelRequested = true;
      _logs.add('[INFO] Requesting PostgreSQL query cancellation...');
    });
    _showResultTab('Messages');

    try {
      final cancelled = await database.cancelCurrentQuery();
      if (!mounted) return;
      if (!cancelled) {
        setState(() {
          _cancelRequested = false;
          _logs.add('[WARN] PostgreSQL reported no cancellable query.');
        });
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _cancelRequested = false;
        _logs.add('[ERROR] Query cancellation failed: $error');
      });
    }
  }

  Future<void> _initializeSqlEditor() async {
    final preferences = await SharedPreferences.getInstance();
    final showAll = preferences.getBool(_showAllSqlScriptsKey) ?? false;

    if (!mounted) return;

    setState(() {
      _showAllSqlScripts = showAll;
      _sqlTabs.add(_SqlScriptTab(title: 'SQL Editor', text: ''));
      _activeCenterTab = 0;
      _logs.add('[INFO] SQL editor ready');
    });
  }

  Future<void> _newSqlScript() async {
    final scriptsDirectory = await _sqlScriptsDirectoryForActiveConnection();
    final title = _nextSqlScriptTitle(scriptsDirectory);
    final script = _SqlScriptTab(
      title: title,
      file: File(_scriptPath(scriptsDirectory, title)),
      connectionKey: _activeScriptConnectionKey,
      text: '',
    );

    setState(() {
      _sqlTabs.add(script);
      _sqliteWorkbenchActive = false;
      _activeCenterTab = _sqlTabs.length - 1;
      _logs.add('[INFO] Created SQL script: ${script.title}');
    });
    _revealLastCenterTab();
  }

  Future<void> _selectSqlScript() async {
    final scripts = await _availableSqlScripts();

    if (!mounted) return;

    final selected = await showDialog<_SqlScriptFile>(
      context: context,
      builder: (context) => _SqlScriptPickerDialog(
        scripts: scripts,
        showAllScripts: _showAllSqlScripts,
        onShowAllChanged: _setShowAllSqlScripts,
        loadScripts: _availableSqlScripts,
      ),
    );

    if (selected == null) return;

    final text = await selected.file.readAsString();
    final tab = _SqlScriptTab(
      title: _fileNameWithoutExtension(selected.file),
      file: selected.file,
      connectionKey: selected.connectionKey,
      text: text,
    );

    setState(() {
      final existingIndex = _sqlTabs.indexWhere(
        (script) => script.file?.path == selected.file.path,
      );
      if (existingIndex == -1) {
        _sqlTabs.add(tab);
        _activeCenterTab = _sqlTabs.length - 1;
      } else {
        tab.dispose();
        _activeCenterTab = existingIndex;
      }
      _logs.add('[INFO] Opened SQL script: ${selected.file.path}');
    });
    _revealLastCenterTab();
  }

  Future<Directory> _sqlScriptsRootDirectory() async {
    final appDirectory = await getApplicationSupportDirectory();
    final scriptsDirectory = Directory(
      '${appDirectory.path}${Platform.pathSeparator}sql_scripts',
    );

    if (!scriptsDirectory.existsSync()) {
      scriptsDirectory.createSync(recursive: true);
    }

    return scriptsDirectory;
  }

  Future<Directory> _sqlScriptsDirectoryForActiveConnection() {
    return _sqlScriptsDirectoryForConnection(_activeScriptConnectionKey);
  }

  Future<Directory> _sqlScriptsDirectoryForConnection(
    String connectionKey,
  ) async {
    final root = await _sqlScriptsRootDirectory();
    final directory = Directory(
      '${root.path}${Platform.pathSeparator}${_safeFileSegment(connectionKey)}',
    );

    if (!directory.existsSync()) {
      directory.createSync(recursive: true);
    }

    return directory;
  }

  Future<List<_SqlScriptFile>> _availableSqlScripts() async {
    final root = await _sqlScriptsRootDirectory();
    final activeKey = _activeScriptConnectionKey;
    final files = <_SqlScriptFile>[];

    if (_showAllSqlScripts) {
      for (final directory in root.listSync().whereType<Directory>()) {
        final connectionKey = _connectionKeyFromDirectory(directory);
        files.addAll(_sqlFilesInDirectory(directory, connectionKey));
      }
      files.addAll(_sqlFilesInDirectory(root, _globalScriptConnectionKey));
    } else {
      final activeDirectory = await _sqlScriptsDirectoryForConnection(
        activeKey,
      );
      files.addAll(_sqlFilesInDirectory(activeDirectory, activeKey));
    }

    files.sort((a, b) => a.label.compareTo(b.label));
    return files;
  }

  List<_SqlScriptFile> _sqlFilesInDirectory(
    Directory directory,
    String connectionKey,
  ) {
    return [
      if (directory.existsSync())
        for (final file in directory.listSync().whereType<File>())
          if (file.path.toLowerCase().endsWith('.sql'))
            _SqlScriptFile(file: file, connectionKey: connectionKey),
    ];
  }

  String _connectionKeyFromDirectory(Directory directory) {
    final segments = directory.path.split(Platform.pathSeparator);
    return segments.isEmpty ? directory.path : segments.last;
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

  String _scriptPath(Directory directory, String title) {
    final safeTitle = title.toLowerCase().endsWith('.sql')
        ? title.substring(0, title.length - 4)
        : title;
    return '${directory.path}${Platform.pathSeparator}$safeTitle.sql';
  }

  Future<void> _setShowAllSqlScripts(bool value) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool(_showAllSqlScriptsKey, value);
    if (!mounted) return;
    setState(() {
      _showAllSqlScripts = value;
      if (!value) {
        _filterSqlTabsForActiveConnection();
      }
      _logs.add(
        '[INFO] ${value ? 'Showing all SQL scripts' : 'Showing current connection SQL scripts'}',
      );
    });
  }

  Future<String?> _promptForScriptName(String initialName) {
    final controller = TextEditingController(text: initialName);
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Save SQL Script'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Script name',
            suffixText: '.sql',
          ),
          onSubmitted: (value) => Navigator.of(context).pop(value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    ).whenComplete(controller.dispose);
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

    if (tab.file == null) {
      final scriptsDirectory = await _sqlScriptsDirectoryForActiveConnection();
      final name = await _promptForScriptName(
        tab.title == 'SQL Editor'
            ? _nextSqlScriptTitle(scriptsDirectory)
            : tab.title,
      );
      final normalizedName = _normalizeScriptName(name);
      if (normalizedName == null) return;
      tab.title = normalizedName;
      tab.file = File(_scriptPath(scriptsDirectory, normalizedName));
      tab.connectionKey = _activeScriptConnectionKey;
    }

    await tab.save();

    setState(() {
      _logs.add('[INFO] Saved SQL script: ${tab.file?.path}');
    });
  }

  String? _normalizeScriptName(String? name) {
    final trimmed = name?.trim() ?? '';
    if (trimmed.isEmpty) return null;
    final withoutExtension = trimmed.toLowerCase().endsWith('.sql')
        ? trimmed.substring(0, trimmed.length - 4).trim()
        : trimmed;
    if (withoutExtension.isEmpty) return null;
    return withoutExtension.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
  }

  void _closeSqlTab(_SqlScriptTab tab) {
    setState(() {
      final index = _sqlTabs.indexOf(tab);
      if (index == -1) return;

      final wasActive = _activeCenterTab == index;
      _sqlTabs.removeAt(index);

      if (wasActive) {
        if (_sqlTabs.isNotEmpty) {
          _activeCenterTab = index.clamp(0, _sqlTabs.length - 1);
        } else {
          _activeCenterTab = 0;
        }
      } else if (_activeCenterTab > index) {
        _activeCenterTab--;
      }

      _logs.add('[INFO] Closed SQL script: ${tab.title}');
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => tab.dispose());
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
    if (_sqliteWorkbenchActive) {
      _closeSqliteWorkbench();
      return;
    }

    final sqlTab = _activeSqlTab;
    if (sqlTab != null) {
      _closeSqlTab(sqlTab);
      return;
    }

    final tableTab = _activeTableTab;
    if (tableTab != null) {
      _closeTableTab(tableTab);
      return;
    }
  }

  void _closeSqliteWorkbench() {
    setState(() {
      _sqliteWorkbenchOpen = false;
      _sqliteWorkbenchActive = false;
      _activeConnection = _database?.config.displayName ?? 'No Connection';
      _activeSchema = _database == null ? '-' : _activeSchema;
      _activeDriver = _database == null
          ? '-'
          : 'postgres ${_database!.config.sslMode.name}';
      _status = _database == null ? 'Disconnected' : 'Connected';
    });
  }

  void _attachSqliteContext(String label, String content) {
    _addAiAttachment(
      _AiAttachment(
        id: 'sqlite:$label',
        label: label,
        icon: Icons.storage_outlined,
        content: content,
      ),
    );
    setState(() {
      _rightPanelMode = 'assistant';
      if (!_controller.rootController.isVisible(IdePane.right.id)) {
        _controller.rootController.show(IdePane.right.id);
      }
    });
  }

  void _attachMySqlContext(String label, String content) {
    _addAiAttachment(
      _AiAttachment(
        id: 'mysql:$label',
        label: label,
        icon: Icons.dns_outlined,
        content: content,
      ),
    );
    setState(() {
      _rightPanelMode = 'assistant';
      if (!_controller.rootController.isVisible(IdePane.right.id)) {
        _controller.rootController.show(IdePane.right.id);
      }
    });
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
    final loadingKey = _schemaLoadingKey(connection, schema);
    if (_loadingSchemas.contains(loadingKey)) return;

    if (!mounted) return;
    setState(() {
      _loadingSchemas.add(loadingKey);
      _logs.add('[INFO] Loading tables for schema $schema');
    });

    try {
      final database = connection.database;
      if (database == null) return;
      final tables = await database.loadSchemaTables(
        schema,
        forceRefresh: forceRefresh,
      );

      if (!mounted) return;
      setState(() {
        _replaceSchema(connection, schema, tables, tablesLoaded: true);
        _logs.add('[INFO] Loaded ${tables.length} tables for schema $schema');
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _logs.add('[ERROR] Failed to load tables for schema $schema: $error');
      });
      _showResultTab('Messages');
    } finally {
      if (mounted) {
        setState(() {
          _loadingSchemas.remove(loadingKey);
        });
      }
    }
  }

  Future<void> _loadTableColumns(
    String schema,
    DatabaseTable table, {
    bool forceRefresh = false,
  }) async {
    final connection = _activeOpenConnection;
    if (connection == null) return;
    await _loadTableColumnsForConnection(
      connection,
      schema,
      table,
      forceRefresh: forceRefresh,
    );
  }

  Future<void> _loadTableColumnsForConnection(
    _OpenConnection connection,
    String schema,
    DatabaseTable table, {
    bool forceRefresh = false,
  }) async {
    final database = connection.database;
    if (database == null) return;

    final loadingKey = _tableLoadingKey(database, schema, table.name);
    if (_loadingTables.contains(loadingKey)) return;

    if (!mounted) return;
    setState(() {
      _loadingTables.add(loadingKey);
      _logs.add('[INFO] Loading columns for $schema.${table.name}');
    });

    try {
      final loadedTable = await database.loadTableColumns(
        schema,
        table.name,
        forceRefresh: forceRefresh,
      );

      if (!mounted) return;
      setState(() {
        _replaceTableInConnection(connection, schema, loadedTable);
        _logs.add(
          '[INFO] Loaded ${loadedTable.columns.length} columns for $schema.${table.name}',
        );
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _logs.add(
          '[ERROR] Failed to load columns for $schema.${table.name}: $error',
        );
      });
      _showResultTab('Messages');
    } finally {
      if (mounted) {
        setState(() {
          _loadingTables.remove(loadingKey);
        });
      }
    }
  }

  String _schemaLoadingKey(_OpenConnection connection, String schema) {
    return '${connection.config.displayName}.$schema';
  }

  String _tableLoadingKey(
    PostgresDatabase database,
    String schema,
    String table,
  ) {
    return '${identityHashCode(database)}.$schema.$table';
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
      if (connection.database == null || connection.database != _database) {
        continue;
      }
      _replaceTableInConnection(connection, schema, table);
      return;
    }
  }

  void _replaceTableInConnection(
    _OpenConnection connection,
    String schema,
    DatabaseTable table,
  ) {
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
  }

  Future<void> _loadDb2SchemaTables(
    _OpenDb2Connection connection,
    String schema,
  ) async {
    if (!await _ensureDb2Connection(connection)) return;
    final loadingKey = '${connection.config.endpointName}.$schema';
    if (!_loadingSchemas.add(loadingKey)) return;
    setState(() {});
    try {
      final tables = await connection.session!.loadTables(schema);
      if (!mounted) return;
      setState(() {
        final index = connection.schemas.indexWhere(
          (item) => item.name == schema,
        );
        if (index >= 0) {
          connection.schemas[index] = connection.schemas[index].copyWith(
            tables: tables,
            tablesLoaded: true,
          );
        }
        _logs.add('[INFO] Loaded ${tables.length} DB2 tables for $schema');
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _logs.add('[ERROR] Failed to load DB2 tables for $schema: $error');
      });
      _showResultTab('Messages');
    } finally {
      if (mounted) {
        setState(() {
          _loadingSchemas.remove(loadingKey);
        });
      }
    }
  }

  Future<void> _openTableData(
    String schema,
    DatabaseTable table, {
    String initialTab = 'Data',
  }) async {
    final database = _database;
    if (database == null) {
      setState(() {
        _logs.add('[WARN] Not connected. Expand a saved connection first.');
      });
      _showResultTab('Messages');
      return;
    }

    final loadedTable = await _ensureTableModelColumns(schema, table);
    if (!mounted) return;

    final existingIndex = _openTableTabs.indexWhere(
      (tab) => tab.schema == schema && tab.table == table.name,
    );

    late final _OpenTableTab tab;

    setState(() {
      if (existingIndex == -1) {
        tab = _OpenTableTab(
          session: PostgresSession(
            profile: database.config,
            database: database,
            driver: _postgresDriver,
          ),
          schema: schema,
          metadata: loadedTable,
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
    if (existingIndex == -1) {
      _revealLastCenterTab();
    }

    await _loadTableTabData(tab);
  }

  Future<void> _openMySqlTableData(
    _OpenMySqlConnection connection,
    DatabaseTable table,
  ) async {
    if (!await _ensureMySqlConnection(connection)) return;
    var metadata = table;
    if (!metadata.columnsLoaded) {
      metadata = await connection.database!.loadTable(table.name);
      if (!mounted) return;
      setState(() {
        final index = connection.tables.indexWhere(
          (item) => item.name == table.name,
        );
        if (index >= 0) connection.tables[index] = metadata;
      });
    }
    final existingIndex = _openTableTabs.indexWhere(
      (tab) =>
          tab.profile.engine == DatabaseEngine.mysql &&
          tab.profile.id == connection.config.id &&
          tab.table == table.name,
    );
    late final _OpenTableTab tab;
    setState(() {
      _sqliteWorkbenchActive = false;
      if (existingIndex == -1) {
        tab = _OpenTableTab(
          session: connection.session!,
          schema: connection.config.database,
          metadata: metadata,
        );
        _openTableTabs.add(tab);
        _activeCenterTab = _tableTabOffset + _openTableTabs.length - 1;
      } else {
        tab = _openTableTabs[existingIndex];
        _activeCenterTab = _tableTabOffset + existingIndex;
      }
      _activeMySqlConnection = connection;
      _activeConnection = connection.config.displayName;
      _activeSchema = connection.config.database;
      _activeDriver = 'mysql ${connection.config.secure ? 'tls' : 'plain'}';
      _status = 'Connected';
      _logs.add(
        '[INFO] Opened MySQL data browser: '
        '${connection.config.database}.${table.name}',
      );
    });
    if (existingIndex == -1) _revealLastCenterTab();
    await _loadTableTabData(tab);
  }

  Future<void> _openDb2TableData(
    _OpenDb2Connection connection,
    String schema,
    DatabaseTable table, {
    String initialTab = 'Data',
  }) async {
    if (!await _ensureDb2Connection(connection)) return;
    var metadata = table;
    if (!metadata.columnsLoaded) {
      metadata = await connection.session!.loadTable(schema, table.name);
      if (!mounted) return;
      setState(() {
        final schemaIndex = connection.schemas.indexWhere(
          (item) => item.name == schema,
        );
        if (schemaIndex >= 0) {
          final schemaModel = connection.schemas[schemaIndex];
          final tables = List<DatabaseTable>.of(schemaModel.tables);
          final tableIndex = tables.indexWhere(
            (item) => item.name == table.name,
          );
          if (tableIndex >= 0) tables[tableIndex] = metadata;
          connection.schemas[schemaIndex] = schemaModel.copyWith(
            tables: tables,
            tablesLoaded: true,
          );
        }
      });
    }
    final existingIndex = _openTableTabs.indexWhere(
      (tab) =>
          tab.profile.engine == DatabaseEngine.db2 &&
          tab.profile.id == connection.config.id &&
          tab.schema == schema &&
          tab.table == table.name,
    );
    late final _OpenTableTab tab;
    setState(() {
      _sqliteWorkbenchActive = false;
      if (existingIndex == -1) {
        tab = _OpenTableTab(
          session: connection.session!,
          schema: schema,
          metadata: metadata,
        );
        _openTableTabs.add(tab);
        _activeCenterTab = _tableTabOffset + _openTableTabs.length - 1;
      } else {
        tab = _openTableTabs[existingIndex];
        _activeCenterTab = _tableTabOffset + existingIndex;
      }
      tab.innerTab = initialTab;
      _activeDb2Connection = connection;
      _activeMySqlConnection = null;
      _activeConnection = connection.config.displayName;
      _activeSchema = schema;
      _activeDriver = 'db2 via Go';
      _status = 'Connected';
      _logs.add('[INFO] Opened DB2 data browser: $schema.${table.name}');
    });
    if (existingIndex == -1) _revealLastCenterTab();
    await _loadTableTabData(tab);
  }

  Future<void> _applyTableFilter(_OpenTableTab tab) async {
    setState(() {
      _logs.add('[INFO] Applied table filter: ${tab.id}');
    });

    await _loadTableTabData(tab, reset: true);
  }

  void _closeTableTab(_OpenTableTab tab) {
    setState(() {
      final index = _openTableTabs.indexOf(tab);
      if (index == -1) return;
      final removedIndex = _tableTabOffset + index;
      _openTableTabs.removeAt(index);
      tab.dispose();
      if (_activeCenterTab == removedIndex) {
        final totalTabs = _sqlTabs.length + _openTableTabs.length;
        _activeCenterTab = totalTabs == 0
            ? 0
            : removedIndex.clamp(0, totalTabs - 1);
      } else if (_activeCenterTab > removedIndex) {
        _activeCenterTab--;
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

    await _loadTableTabData(tab, reset: true);
  }

  Future<void> _filterTableColumn(_OpenTableTab tab, String columnName) async {
    final column = tab.columns
        .where((item) => item.name == columnName)
        .firstOrNull;
    if (column == null) return;

    final existing = tab.columnFilters[columnName];
    final filter = await showDialog<_ColumnFilter>(
      context: context,
      builder: (context) =>
          _ColumnFilterDialog(column: column, initialFilter: existing),
    );
    if (!mounted || filter == null) return;

    setState(() {
      if (filter.remove) {
        tab.columnFilters.remove(columnName);
      } else {
        tab.columnFilters[columnName] = filter;
      }
    });
    await _loadTableTabData(tab, reset: true);
  }

  void _editTableCell(
    _OpenTableTab tab,
    int rowIndex,
    int columnIndex,
    String value,
  ) {
    if (!tab.canEdit) return;
    final original = tab.rows[rowIndex][columnIndex]?.toString() ?? '';
    setState(() {
      if (value == original) {
        tab.pendingChanges[rowIndex]?.remove(columnIndex);
        if (tab.pendingChanges[rowIndex]?.isEmpty ?? false) {
          tab.pendingChanges.remove(rowIndex);
        }
      } else {
        tab.pendingChanges.putIfAbsent(
          rowIndex,
          () => <int, String>{},
        )[columnIndex] = value;
      }
    });
  }

  void _cancelTableChanges(_OpenTableTab tab) {
    setState(tab.pendingChanges.clear);
  }

  Future<void> _saveTableChanges(_OpenTableTab tab) async {
    if (!tab.canEdit || tab.pendingChanges.isEmpty) return;
    if (tab.profile.writeProtected &&
        !await _confirmProtectedWrite(tab.profile)) {
      return;
    }

    setState(() {
      _isExecuting = true;
      _logs.add('[INFO] Saving ${tab.pendingChanges.length} edited rows');
    });

    try {
      final updates = <DatabaseRowUpdate>[];
      for (final rowEntry in tab.pendingChanges.entries) {
        final originalRow = tab.rows[rowEntry.key];
        final changes = <String, Object?>{};
        final originalValues = <String, Object?>{};
        for (final cell in rowEntry.value.entries) {
          final column = tab.columns[cell.key];
          changes[column.name] = _typedCellValue(column, cell.value);
          originalValues[column.name] = originalRow[cell.key];
        }
        final primaryKey = <String, Object?>{
          for (final column in tab.primaryKeyColumns)
            column.name: originalRow[tab.resultColumns.indexOf(column.name)],
        };
        updates.add(
          DatabaseRowUpdate(
            schema: tab.schema,
            table: tab.table,
            changes: changes,
            primaryKey: primaryKey,
            originalValues: originalValues,
          ),
        );
      }
      final affectedRows = await tab.session.updateRows(updates);

      if (!mounted) return;
      setState(() {
        tab.pendingChanges.clear();
        _isExecuting = false;
        _logs.add('[INFO] Saved $affectedRows updated rows');
      });
      await _loadTableTabData(tab, reset: true);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _isExecuting = false;
        _logs.add('[ERROR] Failed to save table changes: $error');
      });
      _showResultTab('Messages');
    }
  }

  Object? _typedCellValue(DatabaseColumn column, String value) {
    final type = column.dataType.toLowerCase();
    if (RegExp(r'int|serial').hasMatch(type)) {
      return int.tryParse(value) ?? value;
    }
    if (RegExp(r'numeric|decimal|real|double|money').hasMatch(type)) {
      return double.tryParse(value) ?? value;
    }
    if (type.contains('bool')) {
      return value.toLowerCase() == 'true';
    }
    return value;
  }

  DatabaseColumn _resultColumn(String columnName, int columnIndex) {
    return _resultColumnMetadata
            .where((column) => column.name == columnName)
            .firstOrNull ??
        _inferResultColumn(columnName, columnIndex);
  }

  DatabaseColumn _inferResultColumn(String name, int columnIndex) {
    Object? sample;
    for (final row in _rows) {
      if (columnIndex < row.length && row[columnIndex] != null) {
        sample = row[columnIndex];
        break;
      }
    }
    final type = switch (sample) {
      int _ => 'integer',
      double _ || num _ => 'numeric',
      bool _ => 'boolean',
      DateTime _ => 'timestamp',
      _ => 'text',
    };
    return DatabaseColumn(name: name, dataType: type, nullable: true);
  }

  Future<void> _filterSqlResultColumn(String columnName) async {
    final columnIndex = _columns.indexOf(columnName);
    if (columnIndex == -1) return;
    final filter = await showDialog<_ColumnFilter>(
      context: context,
      builder: (context) => _ColumnFilterDialog(
        column: _resultColumn(columnName, columnIndex),
        initialFilter: _resultColumnFilters[columnName],
      ),
    );
    if (!mounted || filter == null) return;
    setState(() {
      if (filter.remove) {
        _resultColumnFilters.remove(columnName);
      } else {
        _resultColumnFilters[columnName] = filter;
      }
      _resultIndexesReady = false;
    });
    await _refreshVisibleResultIndexes();
  }

  void _sortSqlResult(String columnName) {
    setState(() {
      if (_resultSortColumn == columnName) {
        _resultSortAscending = !_resultSortAscending;
      } else {
        _resultSortColumn = columnName;
        _resultSortAscending = true;
      }
      _resultIndexesReady = false;
    });
    unawaited(_refreshVisibleResultIndexes());
  }

  List<({int sourceIndex, List<dynamic> row})> get _visibleSqlResultRows {
    final indexes = _resultIndexesReady
        ? _visibleResultIndexes
        : List<int>.generate(_rows.length, (index) => index);
    return [
      for (final index in indexes)
        if (index >= 0 && index < _rows.length)
          (sourceIndex: index, row: _rows[index]),
    ];
  }

  Future<void> _refreshVisibleResultIndexes() async {
    final generation = ++_resultIndexGeneration;
    final rows = List<List<dynamic>>.of(_rows);
    final filters = <ResultIndexFilter>[
      for (final entry in _resultColumnFilters.entries)
        if (_columns.contains(entry.key))
          ResultIndexFilter(
            column: _columns.indexOf(entry.key),
            operator: entry.value.operator,
            value: entry.value.value,
            kind: entry.value.kind.name,
          ),
    ];
    final sortColumn = _resultSortColumn == null
        ? null
        : _columns.indexOf(_resultSortColumn!);
    final indexes = await ResultIndexer.build(
      rows: rows,
      filters: filters,
      sortColumn: sortColumn != null && sortColumn >= 0 ? sortColumn : null,
      sortAscending: _resultSortAscending,
    );
    if (!mounted || generation != _resultIndexGeneration) return;
    setState(() {
      _visibleResultIndexes = indexes;
      _resultIndexesReady = true;
    });
  }

  bool get _canEditSqlResult {
    final primaryKeys = _resultColumnMetadata
        .where((column) => column.primaryKey)
        .toList();
    return _resultDatabase != null &&
        _resultSchema != null &&
        _resultTable != null &&
        primaryKeys.isNotEmpty &&
        primaryKeys.every((column) => _columns.contains(column.name)) &&
        _columns.toSet().length == _columns.length;
  }

  bool _canEditSqlResultColumn(int columnIndex) {
    if (!_canEditSqlResult || columnIndex >= _columns.length) return false;
    final name = _columns[columnIndex];
    return _resultColumnMetadata.any((column) => column.name == name);
  }

  void _editSqlResultCell(int sourceRow, int columnIndex, String value) {
    if (!_canEditSqlResultColumn(columnIndex)) return;
    final original = _rows[sourceRow][columnIndex]?.toString() ?? '';
    setState(() {
      if (value == original) {
        _resultPendingChanges[sourceRow]?.remove(columnIndex);
        if (_resultPendingChanges[sourceRow]?.isEmpty ?? false) {
          _resultPendingChanges.remove(sourceRow);
        }
      } else {
        _resultPendingChanges.putIfAbsent(
          sourceRow,
          () => <int, String>{},
        )[columnIndex] = value;
      }
    });
  }

  Future<void> _saveSqlResultChanges() async {
    final database = _resultDatabase;
    final schema = _resultSchema;
    final table = _resultTable;
    if (!_canEditSqlResult ||
        database == null ||
        schema == null ||
        table == null ||
        _resultPendingChanges.isEmpty) {
      return;
    }
    if (database.config.writeProtected &&
        !await _confirmProtectedWrite(database.config)) {
      return;
    }

    setState(() {
      _isExecuting = true;
      _logs.add(
        '[INFO] Saving ${_resultPendingChanges.length} edited result rows',
      );
    });
    try {
      final primaryKeys = _resultColumnMetadata
          .where((column) => column.primaryKey)
          .toList();
      final updates = <PostgresRowUpdate>[];
      for (final rowEntry in _resultPendingChanges.entries) {
        final originalRow = _rows[rowEntry.key];
        final changes = <String, Object?>{};
        final originalValues = <String, Object?>{};
        for (final cell in rowEntry.value.entries) {
          final columnName = _columns[cell.key];
          final column = _resultColumnMetadata.firstWhere(
            (item) => item.name == columnName,
          );
          changes[columnName] = _typedCellValue(column, cell.value);
          originalValues[columnName] = originalRow[cell.key];
        }
        updates.add(
          PostgresRowUpdate(
            schema: schema,
            table: table,
            changes: changes,
            primaryKey: {
              for (final column in primaryKeys)
                column.name: originalRow[_columns.indexOf(column.name)],
            },
            originalValues: originalValues,
          ),
        );
      }
      final affected = await database.updateRows(updates);
      if (!mounted) return;
      setState(() {
        for (final rowEntry in _resultPendingChanges.entries) {
          for (final cell in rowEntry.value.entries) {
            final column = _resultColumnMetadata.firstWhere(
              (item) => item.name == _columns[cell.key],
            );
            _rows[rowEntry.key][cell.key] = _typedCellValue(column, cell.value);
          }
        }
        _resultPendingChanges.clear();
        _isExecuting = false;
        _logs.add('[INFO] Saved $affected updated result rows');
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _isExecuting = false;
        _logs.add('[ERROR] Failed to save result changes: $error');
      });
      _showResultTab('Messages');
    }
  }

  Future<void> _loadTableTabData(_OpenTableTab tab, {bool reset = true}) async {
    if (tab.loadingPage || (!reset && !tab.hasMoreRows)) return;
    if (!reset && tab.pendingChanges.isNotEmpty) return;

    setState(() {
      tab.loadingPage = true;
      if (reset) {
        tab.hasMoreRows = true;
      }
    });

    final offset = reset ? 0 : tab.rows.length;
    if (reset) {
      setState(() {
        _isExecuting = true;
        _loadingOperation = 'Loading ${tab.schema}.${tab.table}...';
      });
    }
    try {
      final filters = [
        if (tab.filterController.text.trim().isNotEmpty)
          '(${tab.filterController.text.trim()})',
        for (final entry in tab.columnFilters.entries)
          _columnFilterSql(entry.key, entry.value, engine: tab.profile.engine),
      ];
      final orderBy =
          tab.sortColumn ??
          (tab.primaryKeyColumns.isEmpty
              ? null
              : tab.primaryKeyColumns.first.name);
      final result = await tab.session.loadTableData(
        tab.schema,
        tab.table,
        limit: _OpenTableTab.pageSize + 1,
        offset: offset,
        orderBy: orderBy,
        ascending: tab.sortColumn == null || tab.sortAscending,
        filters: filters,
      );
      if (!mounted) return;
      final hasMoreRows = result.rows.length > _OpenTableTab.pageSize;
      final pageRows = result.rows.take(_OpenTableTab.pageSize).toList();
      setState(() {
        tab.resultColumns = result.columns;
        if (reset) {
          tab.rows = pageRows;
          tab.pendingChanges.clear();
        } else {
          tab.rows.addAll(pageRows);
        }
        tab.hasMoreRows = hasMoreRows;
        tab.loadingPage = false;
        _isExecuting = false;
        _loadingOperation = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        tab.loadingPage = false;
        _isExecuting = false;
        _loadingOperation = null;
        _logs.add('[ERROR] Table load failed: $error');
      });
      _showResultTab('Messages');
    }
  }

  Future<void> _loadMoreTableRows(_OpenTableTab tab) {
    return _loadTableTabData(tab, reset: false);
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
        if (connection.database != null && connection.database == database) {
          connection.schemas = List<DatabaseSchema>.of(schemas);
          break;
        }
      }
      _logs.add('[INFO] Refreshed ${schemas.length} schemas');
    });
  }

  void _activateConnection(_OpenConnection connection) {
    final database = connection.database;
    if (database == null) {
      setState(() {
        _activeConnection = connection.config.displayName;
        _activeSchema = '-';
        _activeDriver = 'postgres ${connection.config.sslMode.name}';
        _status = connection.isConnecting ? 'Connecting' : 'Disconnected';
      });
      return;
    }

    setState(() {
      _activeMySqlConnection = null;
      _activeDb2Connection = null;
      _sessions = const [];
      _database = database;
      _activeConnection = database.config.displayName;
      _activeSchema = connection.schemas.isEmpty
          ? '-'
          : connection.schemas.first.name;
      _activeDriver = 'postgres ${database.config.sslMode.name}';
      _status = 'Connected';
      _filterSqlTabsForActiveConnection();
      _logs.add('[INFO] Activated connection: $_activeConnection');
    });
    if (_rightPanelMode == 'sessions') {
      unawaited(_refreshSessions());
    }
  }

  void _filterSqlTabsForActiveConnection() {
    if (_sqlTabs.isNotEmpty && _activeCenterTab >= _sqlTabs.length) {
      _activeCenterTab = _sqlTabs.length - 1;
    }
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

  List<_SqlCompletion> _sqlAutocompleteOptions(
    _SqlScriptTab tab,
    TextEditingValue value,
  ) {
    final cursor = value.selection.isValid
        ? value.selection.baseOffset
        : value.text.length;
    final connection = _connectionForKey(tab.connectionKey);
    final associatedDb2Connection = _db2ConnectionForKey(tab.connectionKey);
    final associatedMySqlConnection = _mySqlConnectionForKey(tab.connectionKey);
    final db2Connection =
        associatedDb2Connection ??
        (tab.connectionKey == _globalScriptConnectionKey
            ? _activeDb2Connection
            : null);
    final mySqlConnection =
        associatedMySqlConnection ??
        (tab.connectionKey == _globalScriptConnectionKey
            ? _activeMySqlConnection
            : null);
    final schemas = db2Connection != null
        ? db2Connection.schemas
        : mySqlConnection != null
        ? [
            DatabaseSchema(
              name: mySqlConnection.config.database,
              tables: mySqlConnection.tables,
              tablesLoaded: true,
            ),
          ]
        : connection?.schemas ??
              _activeOpenConnection?.schemas ??
              const <DatabaseSchema>[];
    final result = _autocompleteEngine.build(
      sql: value.text,
      cursor: cursor,
      schemas: schemas,
    );
    final request = result.metadataRequest;
    if (request?.table != null) {
      _loadAutocompleteTableColumns(
        tab,
        request!.schema,
        request.table!,
        connection: connection,
        db2Connection: db2Connection,
        mySqlConnection: mySqlConnection,
      );
    } else if (request?.schema != null && db2Connection != null) {
      final schema = schemas
          .where((item) => item.name == request!.schema)
          .firstOrNull;
      if (schema != null) {
        _loadAutocompleteDb2SchemaTables(db2Connection, schema, tab);
      }
    } else if (request?.schema != null && connection != null) {
      final schema = schemas
          .where((item) => item.name == request!.schema)
          .firstOrNull;
      if (schema != null) {
        _loadAutocompleteSchemaTables(connection, schema, tab);
      }
    }
    return result.options;
  }

  void _loadAutocompleteSchemaTables(
    _OpenConnection connection,
    DatabaseSchema schema,
    _SqlScriptTab tab,
  ) {
    final key = '${connection.config.endpointName}.${schema.name}';
    if (!_autocompleteSchemaLoads.add(key)) return;
    unawaited(
      _loadSchemaTables(connection, schema.name).whenComplete(() {
        _autocompleteSchemaLoads.remove(key);
        if (mounted) tab.controller.refreshCompletions();
      }),
    );
  }

  void _loadAutocompleteTableColumns(
    _SqlScriptTab tab,
    String? schema,
    DatabaseTable table, {
    _OpenConnection? connection,
    _OpenDb2Connection? db2Connection,
    _OpenMySqlConnection? mySqlConnection,
  }) {
    final engineKey =
        db2Connection?.config.id ??
        mySqlConnection?.config.id ??
        connection?.config.id;
    if (engineKey == null) return;
    final key = '$engineKey.${schema ?? ''}.${table.name}';
    if (!_autocompleteSchemaLoads.add(key)) return;

    Future<void> load() async {
      try {
        if (mySqlConnection != null) {
          final session = mySqlConnection.session;
          if (session == null) return;
          final loaded = await session.loadTable(
            mySqlConnection.config.database,
            table.name,
          );
          if (!mounted) return;
          final index = mySqlConnection.tables.indexWhere(
            (item) => item.name.toLowerCase() == loaded.name.toLowerCase(),
          );
          if (index >= 0) {
            mySqlConnection.tables[index] = loaded;
          }
        } else if (db2Connection != null && schema != null) {
          final session = db2Connection.session;
          if (session == null) return;
          final loaded = await session.loadTable(schema, table.name);
          if (!mounted) return;
          final schemaIndex = db2Connection.schemas.indexWhere(
            (item) => item.name == schema,
          );
          if (schemaIndex >= 0) {
            final schemaModel = db2Connection.schemas[schemaIndex];
            final tables = List<DatabaseTable>.of(schemaModel.tables);
            final tableIndex = tables.indexWhere(
              (item) => item.name.toLowerCase() == loaded.name.toLowerCase(),
            );
            if (tableIndex >= 0) {
              tables[tableIndex] = loaded;
              db2Connection.schemas[schemaIndex] = schemaModel.copyWith(
                tables: tables,
                tablesLoaded: true,
              );
            }
          }
        } else if (connection != null && schema != null) {
          await _loadTableColumnsForConnection(connection, schema, table);
        }
      } finally {
        _autocompleteSchemaLoads.remove(key);
        if (mounted) tab.controller.refreshCompletions();
      }
    }

    unawaited(load());
  }

  void _loadAutocompleteDb2SchemaTables(
    _OpenDb2Connection connection,
    DatabaseSchema schema,
    _SqlScriptTab tab,
  ) {
    final key = '${connection.config.endpointName}.${schema.name}';
    if (!_autocompleteSchemaLoads.add(key)) return;
    unawaited(
      _loadDb2SchemaTables(connection, schema.name).whenComplete(() {
        _autocompleteSchemaLoads.remove(key);
        if (mounted) tab.controller.refreshCompletions();
      }),
    );
  }

  void _insertAutocompleteOption(_SqlCompletion option) {
    final sqlTab = _activeSqlTab;
    if (sqlTab == null) return;

    sqlTab.controller.value = TextEditingValue(
      text: option.text,
      selection: TextSelection.collapsed(offset: option.cursorOffset),
    );

    if (option.schema != null && option.table != null) {
      final db2Connection = _db2ConnectionForKey(sqlTab.connectionKey);
      final effectiveDb2Connection =
          db2Connection ??
          (sqlTab.connectionKey == _globalScriptConnectionKey
              ? _activeDb2Connection
              : null);
      if (effectiveDb2Connection != null) {
        final table = effectiveDb2Connection.schemas
            .where((schema) => schema.name == option.schema)
            .expand((schema) => schema.tables)
            .where((table) => table.name == option.table)
            .firstOrNull;
        if (table != null && !table.columnsLoaded) {
          _loadAutocompleteTableColumns(
            sqlTab,
            option.schema,
            table,
            db2Connection: effectiveDb2Connection,
          );
        }
        return;
      }
      final mySqlConnection = _mySqlConnectionForKey(sqlTab.connectionKey);
      final effectiveMySqlConnection =
          mySqlConnection ??
          (sqlTab.connectionKey == _globalScriptConnectionKey
              ? _activeMySqlConnection
              : null);
      if (effectiveMySqlConnection != null) {
        final table = effectiveMySqlConnection.tables
            .where((item) => item.name == option.table)
            .firstOrNull;
        if (table != null && !table.columnsLoaded) {
          _loadAutocompleteTableColumns(
            sqlTab,
            option.schema,
            table,
            mySqlConnection: effectiveMySqlConnection,
          );
        }
        return;
      }
      final connection =
          _connectionForKey(sqlTab.connectionKey) ?? _activeOpenConnection;
      final table = connection?.schemas
          .where((schema) => schema.name == option.schema)
          .expand((schema) => schema.tables)
          .where((table) => table.name == option.table)
          .firstOrNull;
      if (connection != null && table != null && !table.columnsLoaded) {
        unawaited(
          _loadTableColumnsForConnection(connection, option.schema!, table),
        );
      }
    }
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

  void _copyFromEditor() {
    final controller = _activeSqlTab?.controller;
    if (controller == null) return;

    final selection = controller.selection;
    final text = selection.isValid && !selection.isCollapsed
        ? selection.textInside(controller.text)
        : controller.text;

    unawaited(Clipboard.setData(ClipboardData(text: text)));
    setState(() {
      _logs.add('[INFO] Copied SQL editor text');
    });
  }

  Future<void> _pasteIntoEditor() async {
    final controller = _activeSqlTab?.controller;
    if (controller == null) return;

    final clipboard = await Clipboard.getData(Clipboard.kTextPlain);
    final pastedText = clipboard?.text;
    if (pastedText == null || pastedText.isEmpty) return;

    final selection = controller.selection;
    final currentText = controller.text;
    final start = selection.isValid ? selection.start : currentText.length;
    final end = selection.isValid ? selection.end : currentText.length;
    final nextText = currentText.replaceRange(start, end, pastedText);
    final nextOffset = start + pastedText.length;

    controller.value = TextEditingValue(
      text: nextText,
      selection: TextSelection.collapsed(offset: nextOffset),
    );
    setState(() {
      _logs.add('[INFO] Pasted SQL editor text');
    });
  }

  void _selectAllSql() {
    final controller = _activeSqlTab?.controller;
    if (controller == null) return;

    controller.selection = TextSelection(
      baseOffset: 0,
      extentOffset: controller.text.length,
    );
  }

  void _showAboutDialog() {
    showAboutDialog(
      context: context,
      applicationName: 'QueryDock',
      applicationVersion: '1.0.0',
      applicationIcon: Image.asset(
        'assets/branding/querydock_logo.png',
        width: 40,
        height: 40,
        filterQuality: FilterQuality.medium,
      ),
      children: const [
        Text(
          'A lightweight PostgreSQL workbench with lazy navigator connections, SQL scripts, and table browsing.',
        ),
      ],
    );
  }

  ({String sql, int offset}) _sqlToExecute() {
    final controller = _activeSqlTab?.controller;
    if (controller == null) return (sql: '', offset: 0);

    final selection = controller.selection;
    final editorText = controller.text;

    if (selection.isValid && !selection.isCollapsed) {
      final start = selection.start.clamp(0, editorText.length);
      final end = selection.end.clamp(0, editorText.length);
      final rawSelection = editorText.substring(start, end);
      final selectedSql = rawSelection.trim();

      if (selectedSql.isNotEmpty) {
        return (
          sql: selectedSql,
          offset: start + rawSelection.indexOf(selectedSql),
        );
      }
    }

    final trimmed = editorText.trim();
    return (
      sql: trimmed,
      offset: trimmed.isEmpty ? 0 : editorText.indexOf(trimmed),
    );
  }

  void _showResultTab(String tab) {
    if (_activeResultTab.value == tab) return;
    _activeResultTab.value = tab;
  }

  _OpenTableTab? get _activeTableTab {
    if (_sqliteWorkbenchActive) return null;
    final tableIndex = _activeCenterTab - _sqlTabs.length;
    if (tableIndex < 0 || tableIndex >= _openTableTabs.length) {
      return null;
    }
    return _openTableTabs[tableIndex];
  }

  _SqlScriptTab? get _activeSqlTab {
    if (_sqliteWorkbenchActive) return null;
    if (_activeCenterTab < 0 || _activeCenterTab >= _sqlTabs.length) {
      return null;
    }
    return _sqlTabs[_activeCenterTab];
  }

  _OpenConnection? get _activeOpenConnection {
    final database = _database;
    if (database == null) return null;

    for (final connection in _connections) {
      if (connection.database == database) return connection;
    }
    return null;
  }

  PostgresDatabase? get _currentDatabase {
    if (_sqliteWorkbenchActive) return null;
    final tableTab = _activeTableTab;
    if (tableTab?.session case final PostgresSession session) {
      return session.database;
    }

    final sqlTab = _activeSqlTab;
    if (sqlTab != null && sqlTab.connectionKey != _globalScriptConnectionKey) {
      return _connectionForKey(sqlTab.connectionKey)?.database;
    }
    return _database;
  }

  DatabaseSession? get _activeDatabaseSession {
    final tableTab = _activeTableTab;
    if (tableTab != null) return tableTab.session;

    if (_activeMySqlConnection?.session != null) {
      return _activeMySqlConnection!.session;
    }

    if (_activeDb2Connection?.session != null) {
      return _activeDb2Connection!.session;
    }

    final sqlTab = _activeSqlTab;
    if (sqlTab != null) {
      final mysql = _mySqlConnectionForKey(sqlTab.connectionKey);
      if (mysql?.session != null) return mysql!.session;
      final db2 = _db2ConnectionForKey(sqlTab.connectionKey);
      if (db2?.session != null) return db2!.session;
      final postgres = _connectionForKey(sqlTab.connectionKey)?.database;
      if (postgres != null) {
        return PostgresSession(
          profile: postgres.config,
          database: postgres,
          driver: _postgresDriver,
        );
      }
    }

    final postgres = _database;
    if (postgres == null) return null;
    return PostgresSession(
      profile: postgres.config,
      database: postgres,
      driver: _postgresDriver,
    );
  }

  int get _tableTabOffset => _sqlTabs.length;

  String get _activeScriptConnectionKey {
    final db2 = _activeDb2Connection;
    if (db2 != null) return _db2ConnectionKey(db2.config);
    final mySql = _activeMySqlConnection;
    if (mySql != null) return _mySqlConnectionKey(mySql.config);
    final database = _database;
    if (database == null) return _globalScriptConnectionKey;
    return database.config.endpointName;
  }

  String _safeFileSegment(String value) {
    return value.replaceAll(RegExp(r'[\\/:*?"<>|@ ]'), '_');
  }

  String _quoteIdentifier(String identifier) {
    return '"${identifier.replaceAll('"', '""')}"';
  }

  String _columnFilterSql(
    String column,
    _ColumnFilter filter, {
    DatabaseEngine engine = DatabaseEngine.postgresql,
  }) {
    final identifier = engine == DatabaseEngine.mysql
        ? '`${column.replaceAll('`', '``')}`'
        : _quoteIdentifier(column);
    final textExpression = engine == DatabaseEngine.postgresql
        ? '$identifier::text'
        : 'CAST($identifier AS CHAR)';
    final likeOperator = engine == DatabaseEngine.postgresql ? 'ILIKE' : 'LIKE';
    switch (filter.operator) {
      case 'is-null':
        return '$identifier IS NULL';
      case 'is-not-null':
        return '$identifier IS NOT NULL';
      case 'contains':
        return '$textExpression $likeOperator ${_quoteSqlValue('%${filter.value}%')}';
      case 'starts-with':
        return '$textExpression $likeOperator ${_quoteSqlValue('${filter.value}%')}';
      case 'ends-with':
        return '$textExpression $likeOperator ${_quoteSqlValue('%${filter.value}')}';
      case 'not-equals':
        return '$identifier <> ${_filterValue(filter)}';
      case 'greater-than':
        return '$identifier > ${_filterValue(filter)}';
      case 'greater-or-equal':
        return '$identifier >= ${_filterValue(filter)}';
      case 'less-than':
        return '$identifier < ${_filterValue(filter)}';
      case 'less-or-equal':
        return '$identifier <= ${_filterValue(filter)}';
      case 'equals':
      default:
        return '$identifier = ${_filterValue(filter)}';
    }
  }

  String _filterValue(_ColumnFilter filter) {
    if (filter.kind == _ColumnFilterKind.number ||
        filter.kind == _ColumnFilterKind.boolean) {
      return filter.value;
    }
    return _quoteSqlValue(filter.value);
  }

  String _quoteSqlValue(String value) {
    return "'${value.replaceAll("'", "''")}'";
  }

  int _resultTabIndex(String tab) {
    switch (tab) {
      case 'Messages':
        return 1;
      case 'Data':
      default:
        return 0;
    }
  }

  Widget _buildResultContent() {
    return ValueListenableBuilder<String>(
      valueListenable: _activeResultTab,
      builder: (context, activeTab, child) {
        final visibleRows = _visibleSqlResultRows;
        return IndexedStack(
          index: _resultTabIndex(activeTab),
          children: [
            ResultGrid(
              columns: _columns,
              rows: [for (final item in visibleRows) item.row],
              renderer: _resultGridRenderer,
              sortColumn: _resultSortColumn,
              sortAscending: _resultSortAscending,
              filteredColumns: _resultColumnFilters.keys.toSet(),
              onSortColumn: _isExecuting
                  ? null
                  : (column) async => _sortSqlResult(column),
              onFilterColumn: _isExecuting ? null : _filterSqlResultColumn,
              editable: _canEditSqlResult && !_isExecuting,
              columnEditable: _canEditSqlResultColumn,
              cellValue: (row, column) {
                final sourceRow = visibleRows[row].sourceIndex;
                return _resultPendingChanges[sourceRow]?[column] ??
                    (_rows[sourceRow][column]?.toString() ?? '');
              },
              cellEdited: (row, column) {
                final sourceRow = visibleRows[row].sourceIndex;
                return _resultPendingChanges[sourceRow]?.containsKey(column) ??
                    false;
              },
              onCellChanged: (row, column, value) {
                _editSqlResultCell(visibleRows[row].sourceIndex, column, value);
              },
            ),
            MessagesView(logs: _logs),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
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
      },
      child: Focus(
        autofocus: true,
        onKeyEvent: (node, event) {
          if (event is KeyDownEvent &&
              event.logicalKey == LogicalKeyboardKey.keyW &&
              HardwareKeyboard.instance.isControlPressed) {
            _closeActiveCenterTab();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: Scaffold(
          backgroundColor: Theme.of(context).colorScheme.surface,
          body: Column(
            children: [
              AppTitleBar(
                connectionName: _activeConnection,
                status: _status,
                nativeWindowChrome: widget.nativeWindowChrome,
              ),
              DbMenuBar(
                onNewConnection: _newConnection,
                onNewSql: _newSqlScript,
                onSelectSql: _selectSqlScript,
                onSaveSql: _saveSql,
                onCloseTab: _closeActiveCenterTab,
                onExecuteSql: _executeShortcut,
                onStopSql: _stopQuery,
                onRefreshSchemas: () => unawaited(_refreshSchemas()),
                onInvalidateConnection: _invalidateActiveConnection,
                onToggleNavigator: () {
                  setState(() {
                    _controller.toggleLeft();
                  });
                },
                onToggleProperties: () {
                  setState(() {
                    _rightPanelMode = 'properties';
                    _controller.toggleRight();
                  });
                },
                onToggleAssistant: _showAiAssistant,
                onAiSettings: () => unawaited(_showAiSettings()),
                onToggleOutput: () {
                  setState(() {
                    _controller.toggleBottom();
                  });
                },
                onToggleTheme: () =>
                    unawaited(AppThemeController.toggle(context)),
                onCopy: _copyFromEditor,
                onPaste: () => unawaited(_pasteIntoEditor()),
                onSelectAll: _selectAllSql,
                onAbout: _showAboutDialog,
              ),
              DbToolbar(
                isExecuting: _isExecuting,
                isConnecting: _isConnecting,
                onNewConnection: _newConnection,
                onNewSql: _newSqlScript,
                onExecute:
                    _isExecuting || _isConnecting || _sqliteWorkbenchActive
                    ? null
                    : _executeSql,
                onStop: _stopQuery,
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
                onToggleAssistant: _showAiAssistant,
                autoCommit: _currentDatabase?.autoCommit ?? true,
                transactionActive: _currentDatabase?.transactionActive ?? false,
                onAutoCommitChanged: (enabled) =>
                    unawaited(_setAutoCommit(enabled)),
                onCommit: () => unawaited(_commitTransaction()),
                onRollback: () => unawaited(_rollbackTransaction()),
              ),
              Expanded(
                child: IdeLayout(
                  controller: _controller,
                  leftPanelBuilder: (context, animationProgress) =>
                      _buildNavigatorPanel(animationProgress),
                  centerBuilder: (context, animationProgress) =>
                      _buildEditorPanel(animationProgress),
                  rightPanelBuilder: (context, animationProgress) =>
                      _buildRightPanel(animationProgress),
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

  Widget _buildCenterTabs({ScrollController? controller}) {
    final tabsController = controller ?? _centerTabsController;
    return Container(
      height: 34,
      color: Theme.of(context).colorScheme.surfaceContainer,
      child: Row(
        children: [
          _CenterTabScrollButton(
            tooltip: 'Scroll tabs left',
            icon: Icons.chevron_left,
            onPressed: () =>
                _scrollCenterTabs(-220, controller: tabsController),
          ),
          Expanded(
            child: SingleChildScrollView(
              key: ValueKey(
                identical(tabsController, _centerTabsController)
                    ? 'center-tab-scroll-view'
                    : identical(tabsController, _sqliteTabsController)
                    ? 'sqlite-center-tab-scroll-view'
                    : 'mysql-center-tab-scroll-view',
              ),
              controller: tabsController,
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (int i = 0; i < _sqlTabs.length; i++)
                    EditorTab(
                      title: _sqlTabs[i].title,
                      active: !_sqliteWorkbenchActive && _activeCenterTab == i,
                      onTap: () => setState(() {
                        _sqliteWorkbenchActive = false;
                        _activeCenterTab = i;
                      }),
                      onClose: () => _closeSqlTab(_sqlTabs[i]),
                      onSecondaryTapDown: (details) =>
                          _showCenterTabMenu(i, details.globalPosition),
                    ),
                  for (int i = 0; i < _openTableTabs.length; i++)
                    EditorTab(
                      title: _openTableTabs[i].table,
                      active:
                          !_sqliteWorkbenchActive &&
                          _activeCenterTab == _tableTabOffset + i,
                      onTap: () => setState(() {
                        _sqliteWorkbenchActive = false;
                        _activeCenterTab = _tableTabOffset + i;
                      }),
                      onClose: () => _closeTableTab(_openTableTabs[i]),
                      onSecondaryTapDown: (details) => _showCenterTabMenu(
                        _tableTabOffset + i,
                        details.globalPosition,
                      ),
                    ),
                  if (_sqliteWorkbenchOpen)
                    EditorTab(
                      title: 'SQLite',
                      active: _sqliteWorkbenchActive,
                      onTap: () => setState(() {
                        _sqliteWorkbenchActive = true;
                      }),
                      onClose: _closeSqliteWorkbench,
                    ),
                ],
              ),
            ),
          ),
          _CenterTabScrollButton(
            tooltip: 'Scroll tabs right',
            icon: Icons.chevron_right,
            onPressed: () => _scrollCenterTabs(220, controller: tabsController),
          ),
        ],
      ),
    );
  }

  void _scrollCenterTabs(double delta, {ScrollController? controller}) {
    final tabsController = controller ?? _centerTabsController;
    if (!tabsController.hasClients) return;
    final position = tabsController.position;
    final target = (tabsController.offset + delta).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    tabsController.animateTo(
      target,
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
    );
  }

  void _revealLastCenterTab() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_centerTabsController.hasClients) return;
      _centerTabsController.animateTo(
        _centerTabsController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
      );
    });
  }

  Future<void> _showCenterTabMenu(int tabIndex, Offset position) async {
    final tabCount = _sqlTabs.length + _openTableTabs.length;
    if (tabIndex < 0 || tabIndex >= tabCount) return;

    setState(() {
      _activeCenterTab = tabIndex;
    });

    final action = await showMenu<_CenterTabAction>(
      context: context,
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy,
        position.dx,
        position.dy,
      ),
      items: [
        const PopupMenuItem(
          value: _CenterTabAction.close,
          child: _TabMenuCommand(
            icon: Icons.close,
            label: 'Close',
            shortcut: 'Ctrl+W',
          ),
        ),
        PopupMenuItem(
          value: _CenterTabAction.closeOthers,
          enabled: tabCount > 1,
          child: const _TabMenuCommand(
            icon: Icons.filter_center_focus,
            label: 'Close Others',
          ),
        ),
        PopupMenuItem(
          value: _CenterTabAction.closeAll,
          enabled: tabCount > 0,
          child: const _TabMenuCommand(
            icon: Icons.close_fullscreen,
            label: 'Close All',
          ),
        ),
        const PopupMenuDivider(),
        PopupMenuItem(
          value: _CenterTabAction.closeLeft,
          enabled: tabIndex > 0,
          child: const _TabMenuCommand(
            icon: Icons.keyboard_double_arrow_left,
            label: 'Close Tabs to the Left',
          ),
        ),
        PopupMenuItem(
          value: _CenterTabAction.closeRight,
          enabled: tabIndex < tabCount - 1,
          child: const _TabMenuCommand(
            icon: Icons.keyboard_double_arrow_right,
            label: 'Close Tabs to the Right',
          ),
        ),
      ],
    );
    if (!mounted || action == null) return;

    final indexes = switch (action) {
      _CenterTabAction.close => {tabIndex},
      _CenterTabAction.closeOthers => {
        for (var index = 0; index < tabCount; index++)
          if (index != tabIndex) index,
      },
      _CenterTabAction.closeAll => {
        for (var index = 0; index < tabCount; index++) index,
      },
      _CenterTabAction.closeLeft => {
        for (var index = 0; index < tabIndex; index++) index,
      },
      _CenterTabAction.closeRight => {
        for (var index = tabIndex + 1; index < tabCount; index++) index,
      },
    };
    _closeCenterTabs(indexes);
  }

  void _closeCenterTabs(Set<int> indexes) {
    if (indexes.isEmpty) return;

    final allTabs = <Object>[..._sqlTabs, ..._openTableTabs];
    final validIndexes = indexes
        .where((index) => index >= 0 && index < allTabs.length)
        .toSet();
    if (validIndexes.isEmpty) return;

    final activeIndex = _activeCenterTab.clamp(0, allTabs.length - 1);
    final activeTab = allTabs[activeIndex];
    final removedSqlTabs = <_SqlScriptTab>[];
    final removedTableTabs = <_OpenTableTab>[];

    for (final index in validIndexes) {
      final tab = allTabs[index];
      if (tab is _SqlScriptTab) {
        removedSqlTabs.add(tab);
      } else if (tab is _OpenTableTab) {
        removedTableTabs.add(tab);
      }
    }

    final survivingTabs = [
      for (var index = 0; index < allTabs.length; index++)
        if (!validIndexes.contains(index)) allTabs[index],
    ];
    Object? nextActiveTab;
    if (survivingTabs.contains(activeTab)) {
      nextActiveTab = activeTab;
    } else if (survivingTabs.isNotEmpty) {
      final nextIndex = [
        for (var index = activeIndex + 1; index < allTabs.length; index++)
          if (!validIndexes.contains(index)) index,
      ].firstOrNull;
      if (nextIndex != null) {
        nextActiveTab = allTabs[nextIndex];
      } else {
        final previousIndex = [
          for (var index = activeIndex - 1; index >= 0; index--)
            if (!validIndexes.contains(index)) index,
        ].firstOrNull;
        if (previousIndex != null) {
          nextActiveTab = allTabs[previousIndex];
        }
      }
    }

    setState(() {
      _sqlTabs.removeWhere(removedSqlTabs.contains);
      _openTableTabs.removeWhere(removedTableTabs.contains);
      if (nextActiveTab == null) {
        _activeCenterTab = 0;
      } else if (nextActiveTab is _SqlScriptTab) {
        _activeCenterTab = _sqlTabs.indexOf(nextActiveTab);
      } else {
        _activeCenterTab =
            _tableTabOffset +
            _openTableTabs.indexOf(nextActiveTab as _OpenTableTab);
      }
      _logs.add('[INFO] Closed ${validIndexes.length} editor tab(s)');
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final tab in removedSqlTabs) {
        tab.dispose();
      }
      for (final tab in removedTableTabs) {
        tab.dispose();
      }
    });
  }

  Widget _buildNavigatorPanel(double animationProgress) {
    final navigatorConnections = List<_OpenConnection>.of(_connections)
      ..sort((left, right) {
        final folder = left.config.folder.toLowerCase().compareTo(
          right.config.folder.toLowerCase(),
        );
        return folder != 0
            ? folder
            : left.config.displayName.toLowerCase().compareTo(
                right.config.displayName.toLowerCase(),
              );
      });
    final mySqlConnections = List<_OpenMySqlConnection>.of(_mySqlConnections)
      ..sort((left, right) {
        final folder = left.config.folder.toLowerCase().compareTo(
          right.config.folder.toLowerCase(),
        );
        return folder != 0
            ? folder
            : left.config.displayName.toLowerCase().compareTo(
                right.config.displayName.toLowerCase(),
              );
      });
    final db2Connections = List<_OpenDb2Connection>.of(_db2Connections)
      ..sort((left, right) {
        final folder = left.config.folder.toLowerCase().compareTo(
          right.config.folder.toLowerCase(),
        );
        return folder != 0
            ? folder
            : left.config.displayName.toLowerCase().compareTo(
                right.config.displayName.toLowerCase(),
              );
      });
    return Container(
      color: Theme.of(context).colorScheme.surface,
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
                if (_connections.isEmpty &&
                    _mySqlConnections.isEmpty &&
                    _db2Connections.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(
                      'Add a PostgreSQL, MySQL, DB2, or SQLite connection to begin.',
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                if (navigatorConnections.isNotEmpty)
                  const Padding(
                    padding: EdgeInsets.fromLTRB(12, 8, 8, 4),
                    child: Text(
                      'POSTGRESQL',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                for (
                  var connectionIndex = 0;
                  connectionIndex < navigatorConnections.length;
                  connectionIndex++
                ) ...[
                  if (navigatorConnections[connectionIndex].config.folder
                          .trim()
                          .isNotEmpty &&
                      (connectionIndex == 0 ||
                          navigatorConnections[connectionIndex - 1]
                                  .config
                                  .folder !=
                              navigatorConnections[connectionIndex]
                                  .config
                                  .folder))
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 10, 8, 4),
                      child: Row(
                        children: [
                          const Icon(Icons.folder_outlined, size: 15),
                          const SizedBox(width: 6),
                          Text(
                            navigatorConnections[connectionIndex].config.folder,
                            style: const TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  Builder(
                    builder: (context) {
                      final connection = navigatorConnections[connectionIndex];
                      return _ConnectionTreeItem(
                        connection: connection,
                        active:
                            connection.database != null &&
                            connection.database == _database,
                        onActivate: () {
                          if (connection.database == null) {
                            unawaited(_ensureConnection(connection));
                          } else {
                            _activateConnection(connection);
                          }
                        },
                        onExpand: () => _ensureConnection(connection),
                        onEdit: () => unawaited(_editConnection(connection)),
                        onDelete: () =>
                            unawaited(_deleteConnection(connection)),
                        onInvalidate: () =>
                            unawaited(_invalidateConnection(connection)),
                        onCopyName: () => unawaited(
                          _copyToClipboard(
                            connection.config.displayName,
                            'connection name',
                          ),
                        ),
                        schemaBuilder: (schema) => _SchemaTreeItem(
                          connectionKey: connection.config.endpointName,
                          schema: schema,
                          isLoading: _loadingSchemas.contains(
                            _schemaLoadingKey(connection, schema.name),
                          ),
                          onExpand: () async {
                            if (!await _ensureConnection(connection)) return;
                            await _loadSchemaTables(connection, schema.name);
                          },
                          onSelectSchema: (schemaName) async {
                            if (!await _ensureConnection(connection)) return;
                            _selectSchema(schemaName);
                          },
                          onRefresh: () {
                            unawaited(
                              _ensureConnection(connection).then((connected) {
                                if (connected) return _refreshSchemas();
                              }),
                            );
                          },
                          onCopyName: (name) =>
                              _copyToClipboard(name, 'schema name'),
                          onAddToAiContext: () => unawaited(
                            _attachNavigatorSchema(connection, schema),
                          ),
                          tableBuilder: (table) {
                            return _TableTreeItem(
                              connectionKey: connection.config.endpointName,
                              schema: schema.name,
                              table: table,
                              isLoading: _loadingTables.contains(
                                connection.database == null
                                    ? ''
                                    : _tableLoadingKey(
                                        connection.database!,
                                        schema.name,
                                        table.name,
                                      ),
                              ),
                              onExpand: (schema, table) async {
                                if (!await _ensureConnection(connection)) {
                                  return;
                                }
                                await _loadTableColumns(schema, table);
                              },
                              onOpenTable: (schema, table) async {
                                if (!await _ensureConnection(connection)) {
                                  return;
                                }
                                _openTable(schema, table);
                              },
                              onGenerateSql: (schema, table, statement) async {
                                if (!await _ensureConnection(connection)) {
                                  return;
                                }
                                await _generateTableSql(
                                  schema,
                                  table.name,
                                  statement,
                                );
                              },
                              onOpenTableData: (schema, table) async {
                                if (!await _ensureConnection(connection)) {
                                  return;
                                }
                                await _openTableData(schema, table);
                              },
                              onOpenTableProperties: (schema, table) async {
                                if (!await _ensureConnection(connection)) {
                                  return;
                                }
                                await _openTableData(
                                  schema,
                                  table,
                                  initialTab: 'Properties',
                                );
                              },
                              onCopyName: (name) =>
                                  _copyToClipboard(name, 'table name'),
                              onAddToAiContext: () => unawaited(
                                _attachNavigatorTable(
                                  connection,
                                  schema.name,
                                  table,
                                ),
                              ),
                              onRefresh: () {
                                unawaited(
                                  _ensureConnection(connection).then((
                                    connected,
                                  ) {
                                    if (connected) return _refreshSchemas();
                                  }),
                                );
                              },
                            );
                          },
                        ),
                      );
                    },
                  ),
                ],
                if (mySqlConnections.isNotEmpty)
                  const Padding(
                    padding: EdgeInsets.fromLTRB(12, 12, 8, 4),
                    child: Text(
                      'MYSQL',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                for (final connection in mySqlConnections)
                  _MySqlConnectionTreeItem(
                    connection: connection,
                    active:
                        connection.database != null &&
                        identical(_activeMySqlConnection, connection),
                    onExpand: () => _ensureMySqlConnection(connection),
                    onActivate: () {
                      if (connection.database == null) {
                        unawaited(_ensureMySqlConnection(connection));
                      } else {
                        _activateMySqlConnection(connection);
                      }
                    },
                    onEdit: () => unawaited(_editMySqlConnection(connection)),
                    onDelete: () =>
                        unawaited(_deleteMySqlConnection(connection)),
                    onInvalidate: () =>
                        unawaited(_invalidateMySqlConnection(connection)),
                    onOpenTable: (table) async {
                      await _openMySqlTableData(connection, table);
                    },
                    onLoadTable: (table) async {
                      final database = connection.database;
                      if (database == null || table.columnsLoaded) return;
                      final loaded = await database.loadTable(table.name);
                      if (!mounted) return;
                      setState(() {
                        final index = connection.tables.indexWhere(
                          (item) => item.name == table.name,
                        );
                        if (index >= 0) connection.tables[index] = loaded;
                      });
                    },
                    onAttachTable: (table) async {
                      if (!await _ensureMySqlConnection(connection)) return;
                      var loaded = table;
                      if (!loaded.columnsLoaded) {
                        loaded = await connection.database!.loadTable(
                          table.name,
                        );
                      }
                      final buffer = StringBuffer()
                        ..writeln(
                          'Connection: ${connection.config.displayName}',
                        )
                        ..writeln(
                          'MySQL database: ${connection.config.database}',
                        )
                        ..writeln('Table: ${loaded.name}')
                        ..writeln('Columns:');
                      for (final column in loaded.columns) {
                        buffer.writeln(
                          '- ${column.name}: ${column.dataType}'
                          '${column.primaryKey ? ' PRIMARY KEY' : ''}',
                        );
                      }
                      _attachMySqlContext(
                        '${connection.config.database}.${loaded.name}',
                        buffer.toString(),
                      );
                    },
                  ),
                if (db2Connections.isNotEmpty)
                  const Padding(
                    padding: EdgeInsets.fromLTRB(12, 12, 8, 4),
                    child: Text(
                      'DB2',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                for (final connection in db2Connections)
                  _Db2ConnectionTreeItem(
                    connection: connection,
                    active:
                        connection.session != null &&
                        identical(_activeDb2Connection, connection),
                    loadingSchemas: _loadingSchemas,
                    loadingTables: _loadingTables,
                    onExpand: () => _ensureDb2Connection(connection),
                    onActivate: () {
                      if (connection.session == null) {
                        unawaited(_ensureDb2Connection(connection));
                      } else {
                        _activateDb2Connection(connection);
                      }
                    },
                    onEdit: () => unawaited(_editDb2Connection(connection)),
                    onDelete: () => unawaited(_deleteDb2Connection(connection)),
                    onInvalidate: () =>
                        unawaited(_invalidateDb2Connection(connection)),
                    onLoadSchema: (schema) =>
                        _loadDb2SchemaTables(connection, schema.name),
                    onOpenTableData: (schema, table, initialTab) =>
                        _openDb2TableData(
                          connection,
                          schema,
                          table,
                          initialTab: initialTab,
                        ),
                    onLoadTable: (schema, table) async {
                      if (!await _ensureDb2Connection(connection)) return;
                      if (table.columnsLoaded) return;
                      final loaded = await connection.session!.loadTable(
                        schema,
                        table.name,
                      );
                      if (!mounted) return;
                      setState(() {
                        final schemaIndex = connection.schemas.indexWhere(
                          (item) => item.name == schema,
                        );
                        if (schemaIndex < 0) return;
                        final schemaModel = connection.schemas[schemaIndex];
                        final tables = List<DatabaseTable>.of(
                          schemaModel.tables,
                        );
                        final tableIndex = tables.indexWhere(
                          (item) => item.name == table.name,
                        );
                        if (tableIndex >= 0) tables[tableIndex] = loaded;
                        connection.schemas[schemaIndex] = schemaModel.copyWith(
                          tables: tables,
                          tablesLoaded: true,
                        );
                      });
                    },
                    onAttachTable: (schema, table) async {
                      if (!await _ensureDb2Connection(connection)) return;
                      var loaded = table;
                      if (!loaded.columnsLoaded) {
                        loaded = await connection.session!.loadTable(
                          schema,
                          table.name,
                        );
                      }
                      final buffer = StringBuffer()
                        ..writeln(
                          'Connection: ${connection.config.displayName}',
                        )
                        ..writeln('DB2 database: ${connection.config.database}')
                        ..writeln('Schema: $schema')
                        ..writeln('Table: ${loaded.name}')
                        ..writeln('Columns:');
                      for (final column in loaded.columns) {
                        buffer.writeln(
                          '- ${column.name}: ${column.dataType}'
                          '${column.primaryKey ? ' PRIMARY KEY' : ''}',
                        );
                      }
                      _addAiAttachment(
                        _AiAttachment(
                          id: 'db2-table:${connection.config.endpointName}:$schema.${loaded.name}',
                          label: '$schema.${loaded.name}',
                          icon: Icons.table_chart_outlined,
                          content: buffer.toString(),
                        ),
                      );
                    },
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEditorPanel(double animationProgress) {
    return Stack(
      children: [
        Positioned.fill(
          child: Offstage(
            offstage: _sqliteWorkbenchActive,
            child: TickerMode(
              enabled: !_sqliteWorkbenchActive,
              child: _buildPostgresEditorPanel(animationProgress),
            ),
          ),
        ),
        if (_sqliteWorkbenchOpen)
          Positioned.fill(
            child: Offstage(
              offstage: !_sqliteWorkbenchActive,
              child: TickerMode(
                enabled: _sqliteWorkbenchActive,
                child: Column(
                  children: [
                    _buildCenterTabs(controller: _sqliteTabsController),
                    Expanded(
                      child: SqliteWorkbenchPage(
                        onClose: _closeSqliteWorkbench,
                        onAttachContext: _attachSqliteContext,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildPostgresEditorPanel(double animationProgress) {
    if (_activeCenterTab >= _tableTabOffset) {
      final activeTab = _activeTableTab;
      if (activeTab != null) {
        return _buildTableDataPanel(activeTab);
      }
    }

    final sqlTab = _activeSqlTab;
    if (sqlTab == null) {
      return _buildEmptyEditorPanel();
    }

    return _withLoadingOverlay(
      WorkbenchCenterScaffold(
        tabBar: _buildCenterTabs(),
        editor: _buildSqlEditorSurface(sqlTab),
        resultHeader: _buildResultHeader(),
        resultContent: _buildResultContent(),
        initialResultHeight: _resultPanelHeight,
        onResultHeightChanged: (height) => _resultPanelHeight = height,
      ),
    );
  }

  Widget _buildEmptyEditorPanel() {
    return _withLoadingOverlay(
      Column(
        children: [
          _buildCenterTabs(),
          Expanded(
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.code_off_outlined,
                    size: 34,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(height: 10),
                  const Text(
                    'No editors open',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 10),
                  FilledButton.icon(
                    key: const ValueKey('empty-editor-new-sql'),
                    onPressed: () => unawaited(_newSqlScript()),
                    icon: const Icon(Icons.add, size: 17),
                    label: const Text('New SQL'),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _withLoadingOverlay(Widget child) {
    final operation = _loadingOperation;
    return Stack(
      children: [
        Positioned.fill(child: child),
        if (operation != null)
          Positioned.fill(
            child: ColoredBox(
              color: Theme.of(
                context,
              ).colorScheme.scrim.withValues(alpha: 0.28),
              child: Center(
                child: Material(
                  elevation: 8,
                  color: Theme.of(context).colorScheme.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(6),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minWidth: 240),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 22,
                        vertical: 18,
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const SizedBox(
                            width: 26,
                            height: 26,
                            child: CircularProgressIndicator(strokeWidth: 3),
                          ),
                          const SizedBox(height: 12),
                          Text(
                            _cancelRequested ? 'Cancelling...' : operation,
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          const SizedBox(height: 12),
                          OutlinedButton.icon(
                            key: const ValueKey('cancel-loading-operation'),
                            onPressed: _cancelRequested ? null : _stopQuery,
                            icon: const Icon(Icons.stop, size: 17),
                            label: const Text('Cancel'),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildResultHeader() {
    return ValueListenableBuilder<String>(
      valueListenable: _activeResultTab,
      builder: (context, activeTab, child) {
        return Container(
          height: 42,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainer,
            border: Border(
              bottom: BorderSide(color: Theme.of(context).dividerColor),
            ),
          ),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final compact = constraints.maxWidth < 620;
              final iconTabs = constraints.maxWidth < 360;
              final showCount = constraints.maxWidth >= 520;
              return Row(
                children: [
                  if (iconTabs) ...[
                    _CompactResultTab(
                      title: 'Data',
                      icon: Icons.table_rows_outlined,
                      active: activeTab == 'Data',
                      onTap: () => _selectResultTab('Data'),
                    ),
                    _CompactResultTab(
                      title: 'Messages',
                      icon: Icons.subject_outlined,
                      active: activeTab == 'Messages',
                      onTap: () => _selectResultTab('Messages'),
                    ),
                  ] else ...[
                    ResultTab(
                      title: 'Data',
                      icon: Icons.table_rows_outlined,
                      active: activeTab == 'Data',
                      onTap: () => _selectResultTab('Data'),
                    ),
                    ResultTab(
                      title: 'Messages',
                      icon: Icons.subject_outlined,
                      active: activeTab == 'Messages',
                      onTap: () => _selectResultTab('Messages'),
                    ),
                  ],
                  const Spacer(),
                  if (activeTab == 'Data' && _statementResults.length > 1)
                    PopupMenuButton<int>(
                      tooltip: 'Select result set',
                      initialValue: _activeStatementResult,
                      onSelected: _selectStatementResult,
                      itemBuilder: (context) => [
                        for (
                          var index = 0;
                          index < _statementResults.length;
                          index++
                        )
                          PopupMenuItem(
                            value: index,
                            child: Text(
                              'Result ${index + 1}  '
                              '(${_statementResults[index].rowCount} rows)',
                            ),
                          ),
                      ],
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 7),
                        child: Text(
                          'Result ${_activeStatementResult + 1}/'
                          '${_statementResults.length}',
                          style: const TextStyle(fontSize: 11),
                        ),
                      ),
                    ),
                  if (activeTab == 'Data' && _columns.isNotEmpty)
                    PopupMenuButton<String>(
                      tooltip: 'Export result data',
                      onSelected: (format) =>
                          unawaited(_exportSqlResult(format)),
                      itemBuilder: (context) => const [
                        PopupMenuItem(value: 'csv', child: Text('Export CSV')),
                        PopupMenuItem(
                          value: 'json',
                          child: Text('Export JSON'),
                        ),
                      ],
                      icon: const Icon(Icons.download_outlined, size: 18),
                    ),
                  if (activeTab == 'Data' && _resultColumnFilters.isNotEmpty)
                    IconButton(
                      tooltip: 'Clear all filters',
                      visualDensity: VisualDensity.compact,
                      onPressed: _isExecuting
                          ? null
                          : () {
                              setState(() {
                                _resultColumnFilters.clear();
                                _resultIndexesReady = false;
                              });
                              unawaited(_refreshVisibleResultIndexes());
                            },
                      icon: const Icon(Icons.filter_alt_off_outlined, size: 18),
                    ),
                  if (activeTab == 'Data')
                    _GridRendererControl(
                      value: _resultGridRenderer,
                      compact: compact,
                      onChanged: (renderer) =>
                          unawaited(_setResultGridRenderer(renderer)),
                    ),
                  if (activeTab == 'Data' && !compact) const SizedBox(width: 8),
                  if (activeTab == 'Data' &&
                      _resultPendingChanges.isNotEmpty) ...[
                    IconButton(
                      tooltip: 'Cancel data changes',
                      visualDensity: VisualDensity.compact,
                      onPressed: _isExecuting
                          ? null
                          : () => setState(_resultPendingChanges.clear),
                      icon: const Icon(Icons.undo, size: 18),
                    ),
                    IconButton(
                      tooltip: 'Save data changes',
                      visualDensity: VisualDensity.compact,
                      onPressed: _isExecuting
                          ? null
                          : () => unawaited(_saveSqlResultChanges()),
                      icon: const Icon(Icons.save_outlined, size: 18),
                    ),
                  ],
                  if (activeTab == 'Messages' && _logs.isNotEmpty)
                    IconButton(
                      tooltip: 'Clear messages',
                      visualDensity: VisualDensity.compact,
                      onPressed: _clearMessages,
                      icon: const Icon(Icons.delete_sweep_outlined, size: 18),
                    ),
                  if (showCount)
                    Text(
                      activeTab == 'Data'
                          ? '${_visibleSqlResultRows.length} / ${_rows.length} rows'
                          : '${_logs.length} messages',
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                ],
              );
            },
          ),
        );
      },
    );
  }

  Widget _buildSqlEditorSurface(_SqlScriptTab sqlTab) {
    return WorkbenchEditorSurface(
      toolbar: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 440;
          final connectionKeys = [
            _globalScriptConnectionKey,
            for (final connection in _connections)
              connection.config.endpointName,
            for (final connection in _mySqlConnections)
              _mySqlConnectionKey(connection.config),
            for (final connection in _db2Connections)
              _db2ConnectionKey(connection.config),
          ];
          final selectedKey = connectionKeys.contains(sqlTab.connectionKey)
              ? sqlTab.connectionKey
              : _globalScriptConnectionKey;
          final selectedLabel = _scriptConnectionLabel(selectedKey);
          final choices = [
            for (final connection in _connections)
              _SqlConnectionChoice(
                key: connection.config.endpointName,
                label: connection.config.displayName,
                engine: 'PostgreSQL',
              ),
            for (final connection in _mySqlConnections)
              _SqlConnectionChoice(
                key: _mySqlConnectionKey(connection.config),
                label: connection.config.displayName,
                engine: 'MySQL',
              ),
            for (final connection in _db2Connections)
              _SqlConnectionChoice(
                key: _db2ConnectionKey(connection.config),
                label: connection.config.displayName,
                engine: 'DB2',
              ),
          ];

          return Row(
            children: [
              if (!compact) ...[
                const Icon(Icons.terminal, size: 16, color: Colors.blueGrey),
                const SizedBox(width: 8),
                Text(
                  'Connection:',
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(width: 6),
              ],
              Expanded(
                child: _SqlConnectionSelector(
                  compact: compact,
                  value: selectedKey,
                  label: selectedLabel,
                  connections: choices,
                  globalKey: _globalScriptConnectionKey,
                  onChanged: (value) =>
                      unawaited(_setSqlTabConnection(sqlTab, value)),
                ),
              ),
              if (!compact) const SizedBox(width: 6),
              IconButton(
                tooltip: 'Complete SQL with AI',
                onPressed: sqlTab.aiCompleting
                    ? null
                    : () => unawaited(_requestAiCompletion(sqlTab)),
                icon: sqlTab.aiCompleting
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.auto_awesome_outlined, size: 17),
                padding: EdgeInsets.zero,
                visualDensity: VisualDensity.compact,
              ),
              IconButton(
                tooltip: 'Save SQL',
                onPressed: () => unawaited(_saveSql()),
                icon: const Icon(Icons.save, size: 17),
                padding: EdgeInsets.zero,
                visualDensity: VisualDensity.compact,
              ),
              IconButton(
                tooltip: 'Execute SQL',
                onPressed: _isExecuting || _isConnecting
                    ? null
                    : _executeShortcut,
                icon: const Icon(Icons.play_arrow, size: 18),
                padding: EdgeInsets.zero,
                visualDensity: VisualDensity.compact,
              ),
            ],
          );
        },
      ),
      editor: _SqlCodeEditor(
        controller: sqlTab.controller,
        focusNode: sqlTab.focusNode,
        error: sqlTab.error,
        onDismissError: () => setState(() => sqlTab.error = null),
        onExecute: _executeShortcut,
        aiSuggestion: sqlTab.aiSuggestion,
        onAcceptAiSuggestion: () => _acceptAiCompletion(sqlTab),
        onDismissAiSuggestion: () => setState(() => sqlTab.aiSuggestion = null),
        optionsBuilder: (value) => _sqlAutocompleteOptions(sqlTab, value),
        onSelected: _insertAutocompleteOption,
      ),
    );
  }

  Widget _buildTableDataPanel(_OpenTableTab tab) {
    return Column(
      children: [
        _buildCenterTabs(),
        Container(
          height: 42,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainer,
            border: Border(
              bottom: BorderSide(color: Theme.of(context).dividerColor),
            ),
          ),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final iconTabs = constraints.maxWidth < 520;
              return Row(
                children: [
                  if (iconTabs) ...[
                    _CompactResultTab(
                      title: 'Properties',
                      icon: Icons.tune,
                      active: tab.innerTab == 'Properties',
                      onTap: () => _setTableDataTab('Properties'),
                    ),
                    _CompactResultTab(
                      title: 'Data',
                      icon: Icons.table_rows_outlined,
                      active: tab.innerTab == 'Data',
                      onTap: () => _setTableDataTab('Data'),
                    ),
                    _CompactResultTab(
                      title: 'Diagram',
                      icon: Icons.account_tree_outlined,
                      active: tab.innerTab == 'Diagram',
                      onTap: () => _setTableDataTab('Diagram'),
                    ),
                  ] else ...[
                    ResultTab(
                      title: 'Properties',
                      icon: Icons.tune,
                      active: tab.innerTab == 'Properties',
                      onTap: () => _setTableDataTab('Properties'),
                    ),
                    ResultTab(
                      title: 'Data',
                      icon: Icons.table_rows_outlined,
                      active: tab.innerTab == 'Data',
                      onTap: () => _setTableDataTab('Data'),
                    ),
                    ResultTab(
                      title: 'Diagram',
                      icon: Icons.account_tree_outlined,
                      active: tab.innerTab == 'Diagram',
                      onTap: () => _setTableDataTab('Diagram'),
                    ),
                  ],
                  const Spacer(),
                  if (tab.innerTab == 'Data')
                    _GridRendererControl(
                      value: _resultGridRenderer,
                      compact: constraints.maxWidth < 680,
                      onChanged: (renderer) =>
                          unawaited(_setResultGridRenderer(renderer)),
                    ),
                ],
              );
            },
          ),
        ),
        Expanded(
          child: Container(
            color: Theme.of(context).colorScheme.surface,
            child: _buildTableDataTabContent(tab),
          ),
        ),
      ],
    );
  }

  Widget _buildTableDataTabContent(_OpenTableTab tab) {
    switch (tab.innerTab) {
      case 'Properties':
        return _TablePropertiesView(schema: tab.schema, metadata: tab.metadata);
      case 'Diagram':
        return _TableUmlDiagram(schema: tab.schema, metadata: tab.metadata);
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
              hasChanges: tab.pendingChanges.isNotEmpty,
              canEdit: tab.canEdit,
              loadedRows: tab.rows.length,
              hasMoreRows: tab.hasMoreRows,
              loadingMore: tab.loadingPage,
              onSaveChanges: () => unawaited(_saveTableChanges(tab)),
              onCancelChanges: () => _cancelTableChanges(tab),
              onExport: (format) => unawaited(_exportTableData(tab, format)),
              onImport: () => unawaited(_importCsvIntoTable(tab)),
            ),
            Expanded(
              child: ResultGrid(
                columns: tab.resultColumns,
                rows: tab.rows,
                renderer: _resultGridRenderer,
                hasMoreRows: tab.hasMoreRows,
                loadingMore: tab.loadingPage,
                onLoadMore: tab.pendingChanges.isEmpty
                    ? () => _loadMoreTableRows(tab)
                    : null,
                sortColumn: tab.sortColumn,
                sortAscending: tab.sortAscending,
                filteredColumns: tab.columnFilters.keys.toSet(),
                onSortColumn: _isExecuting
                    ? null
                    : (column) => _sortTableData(tab, column),
                onFilterColumn: _isExecuting
                    ? null
                    : (column) => _filterTableColumn(tab, column),
                editable: tab.canEdit && !_isExecuting,
                cellValue: (row, column) =>
                    tab.pendingChanges[row]?[column] ??
                    (tab.rows[row][column]?.toString() ?? ''),
                cellEdited: (row, column) =>
                    tab.pendingChanges[row]?.containsKey(column) ?? false,
                onCellChanged: (row, column, value) =>
                    _editTableCell(tab, row, column, value),
              ),
            ),
          ],
        );
    }
  }

  Widget _buildRightPanel(double animationProgress) {
    return Column(
      children: [
        Container(
          height: 36,
          color: Theme.of(context).colorScheme.surfaceContainer,
          child: Row(
            children: [
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      _RightPanelTab(
                        label: 'Properties',
                        icon: Icons.info_outline,
                        active: _rightPanelMode == 'properties',
                        onTap: () =>
                            setState(() => _rightPanelMode = 'properties'),
                      ),
                      _RightPanelTab(
                        label: 'Search',
                        icon: Icons.search,
                        active: _rightPanelMode == 'search',
                        onTap: () => setState(() => _rightPanelMode = 'search'),
                      ),
                      _RightPanelTab(
                        label: 'History',
                        icon: Icons.history,
                        active: _rightPanelMode == 'history',
                        onTap: () =>
                            setState(() => _rightPanelMode = 'history'),
                      ),
                      _RightPanelTab(
                        label: 'Sessions',
                        icon: Icons.monitor_heart_outlined,
                        active: _rightPanelMode == 'sessions',
                        onTap: () {
                          setState(() => _rightPanelMode = 'sessions');
                          unawaited(_refreshSessions());
                        },
                      ),
                      _RightPanelTab(
                        label: 'AI',
                        icon: Icons.auto_awesome_outlined,
                        active: _rightPanelMode == 'assistant',
                        onTap: _showAiAssistant,
                      ),
                    ],
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Close panel',
                onPressed: () => setState(_controller.toggleRight),
                icon: const Icon(Icons.close, size: 16),
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
        ),
        Expanded(
          child: switch (_rightPanelMode) {
            'assistant' => _buildAiAssistantPanel(),
            'search' => _buildObjectSearchPanel(),
            'history' => _buildSqlHistoryPanel(),
            'sessions' => _buildSessionsPanel(),
            _ => _buildPropertiesContent(),
          },
        ),
      ],
    );
  }

  Future<void> _searchDatabaseObjects() async {
    final database = _currentDatabase;
    final query = _objectSearchController.text.trim();
    if (database == null || query.isEmpty) return;
    setState(() => _objectSearching = true);
    try {
      final results = await database.searchObjects(query);
      if (!mounted) return;
      setState(() {
        _objectSearchResults = results;
        _objectSearching = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _objectSearching = false;
        _logs.add('[ERROR] Object search failed: $error');
      });
    }
  }

  Widget _buildObjectSearchPanel() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(8),
          child: TextField(
            key: const ValueKey('database-object-search'),
            controller: _objectSearchController,
            onSubmitted: (_) => unawaited(_searchDatabaseObjects()),
            decoration: InputDecoration(
              hintText: 'Tables, columns, views, functions',
              prefixIcon: const Icon(Icons.search, size: 18),
              suffixIcon: IconButton(
                tooltip: 'Search database',
                onPressed: _objectSearching
                    ? null
                    : () => unawaited(_searchDatabaseObjects()),
                icon: const Icon(Icons.arrow_forward, size: 18),
              ),
            ),
          ),
        ),
        if (_objectSearching) const LinearProgressIndicator(minHeight: 2),
        Expanded(
          child: _objectSearchResults.isEmpty
              ? const Center(child: Text('No search results'))
              : ListView.builder(
                  itemCount: _objectSearchResults.length,
                  itemBuilder: (context, index) {
                    final item = _objectSearchResults[index];
                    return ListTile(
                      dense: true,
                      leading: Icon(
                        item.type == 'Column'
                            ? Icons.view_column_outlined
                            : item.type == 'Function'
                            ? Icons.functions
                            : Icons.table_chart_outlined,
                        size: 17,
                      ),
                      title: Text(
                        '${item.schema}.${item.name}',
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        '${item.type}${item.detail.isEmpty ? '' : '  ${item.detail}'}',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      onTap: () {
                        final parts = item.name.split('.');
                        final table = parts.first;
                        if (item.type == 'Table' ||
                            item.type == 'Partitioned table' ||
                            item.type == 'View' ||
                            item.type == 'Materialized view' ||
                            item.type == 'Foreign table' ||
                            item.type == 'Column') {
                          final schema = _activeOpenConnection?.schemas
                              .where((schema) => schema.name == item.schema)
                              .firstOrNull;
                          final metadata = schema?.tables
                              .where((value) => value.name == table)
                              .firstOrNull;
                          if (metadata != null) {
                            unawaited(_openTableData(item.schema, metadata));
                          }
                        }
                      },
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildSqlHistoryPanel() {
    return Column(
      children: [
        Container(
          height: 38,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            children: [
              Text(
                '${_sqlHistory.length} executions',
                style: const TextStyle(fontSize: 12),
              ),
              const Spacer(),
              IconButton(
                tooltip: 'Clear SQL history',
                onPressed: _sqlHistory.isEmpty
                    ? null
                    : () async {
                        await _historyStore.clear();
                        if (mounted) setState(_sqlHistory.clear);
                      },
                icon: const Icon(Icons.delete_sweep_outlined, size: 18),
              ),
            ],
          ),
        ),
        Expanded(
          child: _sqlHistory.isEmpty
              ? const Center(child: Text('No SQL history'))
              : ListView.builder(
                  itemCount: _sqlHistory.length,
                  itemBuilder: (context, index) {
                    final item = _sqlHistory[index];
                    return ListTile(
                      dense: true,
                      leading: Icon(
                        item.succeeded
                            ? Icons.check_circle_outline
                            : Icons.error_outline,
                        size: 17,
                        color: item.succeeded
                            ? Colors.green.shade700
                            : Theme.of(context).colorScheme.error,
                      ),
                      title: Text(
                        item.sql.replaceAll(RegExp(r'\s+'), ' ').trim(),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontFamily: 'Consolas',
                          fontSize: 11,
                        ),
                      ),
                      subtitle: Text(
                        '${item.connection} | ${item.elapsedMilliseconds} ms | '
                        '${item.rowCount} rows',
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: IconButton(
                        tooltip: 'Open and rerun',
                        onPressed: () => _rerunHistory(item),
                        icon: const Icon(Icons.replay, size: 17),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  void _rerunHistory(SqlHistoryEntry entry) {
    final tab = _activeSqlTab;
    if (tab == null) return;
    setState(() {
      tab.controller.text = entry.sql;
      _activeCenterTab = _sqlTabs.indexOf(tab);
    });
    unawaited(_executeSql());
  }

  Future<void> _refreshSessions() async {
    final session = _activeDatabaseSession;
    if (session == null ||
        !session.capabilities.sessionMonitor ||
        _sessionsLoading) {
      if (mounted && session != null) {
        setState(() => _sessions = const []);
      }
      return;
    }
    setState(() => _sessionsLoading = true);
    try {
      final sessions = await session.loadSessions();
      if (!mounted) return;
      setState(() {
        _sessions = sessions;
        _sessionsLoading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _sessionsLoading = false;
        _logs.add('[ERROR] Session monitor failed: $error');
      });
    }
  }

  Widget _buildSessionsPanel() {
    final session = _activeDatabaseSession;
    final engine = session?.profile.engine;
    final engineName = switch (engine) {
      DatabaseEngine.mysql => 'MySQL',
      DatabaseEngine.sqlite => 'SQLite',
      DatabaseEngine.db2 => 'DB2',
      DatabaseEngine.postgresql => 'PostgreSQL',
      null => 'Database',
    };
    return Column(
      children: [
        Container(
          height: 38,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            children: [
              Text(
                '$engineName sessions',
                style: const TextStyle(fontSize: 12),
              ),
              const Spacer(),
              IconButton(
                tooltip: 'Refresh sessions',
                onPressed: _sessionsLoading
                    ? null
                    : () => unawaited(_refreshSessions()),
                icon: const Icon(Icons.refresh, size: 18),
              ),
            ],
          ),
        ),
        if (_sessionsLoading) const LinearProgressIndicator(minHeight: 2),
        Expanded(
          child: _sessions.isEmpty
              ? const Center(child: Text('No sessions loaded'))
              : ListView.builder(
                  itemCount: _sessions.length,
                  itemBuilder: (context, index) {
                    final session = _sessions[index];
                    return ListTile(
                      dense: true,
                      leading: CircleAvatar(
                        radius: 14,
                        child: Text(
                          '${session.id}',
                          style: const TextStyle(fontSize: 9),
                        ),
                      ),
                      title: Text(
                        '${session.username} | ${session.state}',
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        [
                          session.application,
                          if (session.waitEvent.isNotEmpty) session.waitEvent,
                          if (session.lockCount > 0)
                            '${session.lockCount} locks',
                          if (session.blockingSessionIds.isNotEmpty)
                            'blocked by ${session.blockingSessionIds.join(', ')}',
                          session.query,
                        ].where((value) => value.isNotEmpty).join('\n'),
                        maxLines: 4,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: IconButton(
                        tooltip: 'Cancel session query',
                        onPressed: session.query.isEmpty
                            ? null
                            : () async {
                                final cancelled = await _activeDatabaseSession
                                    ?.cancelSession(session.id);
                                if (!mounted) return;
                                setState(() {
                                  _logs.add(
                                    cancelled == true
                                        ? '[INFO] Cancelled session ${session.id}'
                                        : '[WARN] Session ${session.id} could not be cancelled',
                                  );
                                });
                                await _refreshSessions();
                              },
                        icon: const Icon(Icons.stop_circle_outlined, size: 18),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildPropertiesContent() {
    return Container(
      color: Theme.of(context).colorScheme.surface,
      child: Column(
        children: [
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

  Widget _buildAiAssistantPanel() {
    return Container(
      color: Theme.of(context).colorScheme.surface,
      child: Column(
        children: [
          Container(
            height: 38,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainer,
              border: Border(
                bottom: BorderSide(color: Theme.of(context).dividerColor),
              ),
            ),
            child: Row(
              children: [
                Tooltip(
                  message: 'Active provider',
                  child: Chip(
                    avatar: Icon(
                      _aiSettings.provider == AiProvider.openAi
                          ? Icons.key_outlined
                          : Icons.code,
                      size: 14,
                    ),
                    label: Text(
                      _aiSettings.providerName,
                      style: const TextStyle(fontSize: 11),
                    ),
                    visualDensity: VisualDensity.compact,
                  ),
                ),
                const SizedBox(width: 4),
                PopupMenuButton<String>(
                  tooltip: 'Attach context',
                  onSelected: (value) {
                    switch (value) {
                      case 'script':
                        _attachCurrentScript();
                        break;
                      case 'selection':
                        _attachSelectedSql();
                        break;
                      case 'schema':
                        unawaited(_attachSchema());
                        break;
                      case 'table':
                        unawaited(_attachTable());
                        break;
                    }
                  },
                  itemBuilder: (context) => const [
                    PopupMenuItem(
                      value: 'script',
                      child: Text('Current script'),
                    ),
                    PopupMenuItem(
                      value: 'selection',
                      child: Text('Selected SQL'),
                    ),
                    PopupMenuItem(value: 'schema', child: Text('Schema...')),
                    PopupMenuItem(value: 'table', child: Text('Table...')),
                  ],
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 8),
                    child: Row(
                      children: [
                        Icon(Icons.attach_file, size: 17),
                        SizedBox(width: 4),
                        Text('Attach', style: TextStyle(fontSize: 12)),
                      ],
                    ),
                  ),
                ),
                const Spacer(),
                IconButton(
                  tooltip: 'AI provider settings',
                  onPressed: () => unawaited(_showAiSettings()),
                  icon: Icon(
                    _aiSettings.configured
                        ? Icons.settings_outlined
                        : Icons.key_outlined,
                    size: 18,
                  ),
                  visualDensity: VisualDensity.compact,
                ),
                IconButton(
                  tooltip: 'Clear conversation',
                  onPressed: _aiMessages.isEmpty
                      ? null
                      : () => setState(_aiMessages.clear),
                  icon: const Icon(Icons.delete_sweep_outlined, size: 18),
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
          ),
          if (_aiAttachments.isNotEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(8, 7, 8, 5),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerLow,
                border: Border(
                  bottom: BorderSide(color: Theme.of(context).dividerColor),
                ),
              ),
              child: Wrap(
                spacing: 5,
                runSpacing: 5,
                children: [
                  for (final attachment in _aiAttachments)
                    InputChip(
                      avatar: Icon(attachment.icon, size: 14),
                      label: Text(
                        attachment.label,
                        overflow: TextOverflow.ellipsis,
                      ),
                      labelStyle: const TextStyle(fontSize: 11),
                      visualDensity: VisualDensity.compact,
                      onDeleted: () =>
                          setState(() => _aiAttachments.remove(attachment)),
                    ),
                ],
              ),
            ),
          Expanded(
            child: _aiMessages.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        'Attach a schema, table, script, or selection, then ask for SQL.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.all(10),
                    itemCount: _aiMessages.length,
                    itemBuilder: (context, index) {
                      final message = _aiMessages[index];
                      final sql = message.role == 'assistant'
                          ? _sqlFromAiMessage(message.text)
                          : null;
                      return _AiMessageView(
                        message: message,
                        sql: sql,
                        onInsert: sql == null ? null : () => _insertAiSql(sql),
                        onNewScript: sql == null
                            ? null
                            : () => unawaited(_openAiSqlInNewScript(sql)),
                      );
                    },
                  ),
          ),
          if (_aiSending) const LinearProgressIndicator(minHeight: 2),
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surface,
              border: Border(
                top: BorderSide(color: Theme.of(context).dividerColor),
              ),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: CallbackShortcuts(
                    bindings: {
                      const SingleActivator(
                        LogicalKeyboardKey.enter,
                        control: true,
                      ): () =>
                          unawaited(_sendAiPrompt()),
                    },
                    child: TextField(
                      key: const ValueKey('ai-prompt-field'),
                      controller: _aiPromptController,
                      minLines: 1,
                      maxLines: 5,
                      keyboardType: TextInputType.multiline,
                      textInputAction: TextInputAction.newline,
                      decoration: const InputDecoration(
                        hintText: 'Ask about the attached database context',
                        helperText: 'Ctrl+Enter to send',
                        isDense: true,
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                IconButton.filled(
                  tooltip: _aiSending
                      ? 'Cancel AI request'
                      : 'Send (Ctrl+Enter)',
                  onPressed: _aiSending
                      ? _cancelAiRequest
                      : () => unawaited(_sendAiPrompt()),
                  icon: Icon(_aiSending ? Icons.stop : Icons.send, size: 18),
                ),
              ],
            ),
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
            onClear: _logs.isEmpty ? null : _clearMessages,
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

class _EditableResultReference {
  final String schema;
  final String table;

  const _EditableResultReference({required this.schema, required this.table});
}

class _AiAttachment {
  final String id;
  final String label;
  final IconData icon;
  final String content;

  const _AiAttachment({
    required this.id,
    required this.label,
    required this.icon,
    required this.content,
  });
}

class _AiTableChoice {
  final String schema;
  final DatabaseTable table;

  const _AiTableChoice({required this.schema, required this.table});
}

class _RightPanelTab extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool active;
  final VoidCallback onTap;

  const _RightPanelTab({
    required this.label,
    required this.icon,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        height: 36,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: active
              ? Theme.of(context).colorScheme.surface
              : Colors.transparent,
          border: Border(
            bottom: BorderSide(
              color: active ? const Color(0xff1473a8) : Colors.transparent,
              width: 2,
            ),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 15),
            const SizedBox(width: 5),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: active ? FontWeight.w600 : FontWeight.normal,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AiMessageView extends StatelessWidget {
  final AiAssistantMessage message;
  final String? sql;
  final VoidCallback? onInsert;
  final VoidCallback? onNewScript;

  const _AiMessageView({
    required this.message,
    required this.sql,
    required this.onInsert,
    required this.onNewScript,
  });

  @override
  Widget build(BuildContext context) {
    final assistant = message.role == 'assistant';
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(9),
      decoration: BoxDecoration(
        color: assistant
            ? Theme.of(context).colorScheme.surfaceContainerLow
            : Theme.of(context).colorScheme.primaryContainer,
        border: Border.all(color: Theme.of(context).dividerColor),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                assistant ? Icons.auto_awesome_outlined : Icons.person_outline,
                size: 15,
                color: assistant
                    ? const Color(0xff1473a8)
                    : const Color(0xff45616f),
              ),
              const SizedBox(width: 6),
              Text(
                assistant ? 'Assistant' : 'You',
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 7),
          SelectableText(
            message.text,
            style: TextStyle(
              fontSize: 12,
              height: 1.35,
              fontFamily: sql == null ? null : 'Consolas',
            ),
          ),
          if (sql != null) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                TextButton.icon(
                  onPressed: onInsert,
                  icon: const Icon(Icons.subdirectory_arrow_left, size: 16),
                  label: const Text('Insert'),
                ),
                TextButton.icon(
                  onPressed: onNewScript,
                  icon: const Icon(Icons.note_add_outlined, size: 16),
                  label: const Text('New script'),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _AiSettingsDialog extends StatefulWidget {
  final AiAssistantSettings initial;

  const _AiSettingsDialog({required this.initial});

  @override
  State<_AiSettingsDialog> createState() => _AiSettingsDialogState();
}

class _AiSettingsDialogState extends State<_AiSettingsDialog> {
  late AiProvider _provider;
  late final TextEditingController _openAiKeyController;
  late final TextEditingController _copilotTokenController;
  late final TextEditingController _modelController;
  bool _obscureKey = true;

  @override
  void initState() {
    super.initState();
    _provider = widget.initial.provider;
    _openAiKeyController = TextEditingController(
      text: widget.initial.openAiApiKey,
    );
    _copilotTokenController = TextEditingController(
      text: widget.initial.githubCopilotToken,
    );
    _modelController = TextEditingController(text: widget.initial.model);
  }

  @override
  void dispose() {
    _openAiKeyController.dispose();
    _copilotTokenController.dispose();
    _modelController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('AI Provider Settings'),
      content: SizedBox(
        width: 430,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SegmentedButton<AiProvider>(
              segments: const [
                ButtonSegment(
                  value: AiProvider.openAi,
                  icon: Icon(Icons.key_outlined),
                  label: Text('OpenAI'),
                ),
                ButtonSegment(
                  value: AiProvider.githubCopilot,
                  icon: Icon(Icons.code),
                  label: Text('GitHub Copilot'),
                ),
              ],
              selected: {_provider},
              onSelectionChanged: (selection) {
                setState(() => _provider = selection.single);
              },
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _provider == AiProvider.openAi
                  ? _openAiKeyController
                  : _copilotTokenController,
              obscureText: _obscureKey,
              decoration: InputDecoration(
                labelText: _provider == AiProvider.openAi
                    ? 'OpenAI API key'
                    : 'GitHub Copilot token',
                helperText: _provider == AiProvider.openAi
                    ? 'Stored in the operating system credential store.'
                    : 'Use gho_, ghu_, or github_pat_. Requires Copilot CLI and a Copilot plan.',
                suffixIcon: IconButton(
                  tooltip: _obscureKey ? 'Show key' : 'Hide key',
                  onPressed: () => setState(() => _obscureKey = !_obscureKey),
                  icon: Icon(
                    _obscureKey ? Icons.visibility : Icons.visibility_off,
                  ),
                ),
              ),
            ),
            if (_provider == AiProvider.openAi) ...[
              const SizedBox(height: 14),
              TextField(
                controller: _modelController,
                decoration: const InputDecoration(
                  labelText: 'OpenAI model',
                  helperText: 'Default: gpt-5.4-mini',
                ),
              ),
            ] else ...[
              const SizedBox(height: 14),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Copilot will use the default model available for this '
                  'GitHub account.',
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            final model = _modelController.text.trim().isEmpty
                ? 'gpt-5.4-mini'
                : _modelController.text.trim();
            final copilotToken = _copilotTokenController.text.trim();
            if (_provider == AiProvider.githubCopilot &&
                copilotToken.startsWith('ghp_')) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text(
                    'Classic ghp_ tokens are unsupported. Use gho_, ghu_, or github_pat_.',
                  ),
                ),
              );
              return;
            }
            Navigator.of(context).pop(
              AiAssistantSettings(
                provider: _provider,
                openAiApiKey: _openAiKeyController.text.trim(),
                githubCopilotToken: copilotToken,
                model: model,
              ),
            );
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
}

class _AiSchemaPicker extends StatelessWidget {
  final List<DatabaseSchema> schemas;

  const _AiSchemaPicker({required this.schemas});

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Attach Schema'),
      content: SizedBox(
        width: 420,
        height: 360,
        child: ListView.builder(
          itemCount: schemas.length,
          itemBuilder: (context, index) {
            final schema = schemas[index];
            return ListTile(
              leading: const Icon(Icons.account_tree_outlined, size: 18),
              title: Text(schema.name),
              subtitle: Text('${schema.tables.length} loaded tables'),
              onTap: () => Navigator.of(context).pop(schema),
            );
          },
        ),
      ),
    );
  }
}

class _AiTablePicker extends StatelessWidget {
  final List<_AiTableChoice> tables;

  const _AiTablePicker({required this.tables});

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Attach Table'),
      content: SizedBox(
        width: 440,
        height: 400,
        child: ListView.builder(
          itemCount: tables.length,
          itemBuilder: (context, index) {
            final choice = tables[index];
            return ListTile(
              leading: const Icon(Icons.table_chart_outlined, size: 18),
              title: Text(choice.table.name),
              subtitle: Text(choice.schema),
              onTap: () => Navigator.of(context).pop(choice),
            );
          },
        ),
      ),
    );
  }
}

class _SqlResultContext {
  final String schema;
  final String table;
  final List<DatabaseColumn> columns;

  const _SqlResultContext({
    required this.schema,
    required this.table,
    required this.columns,
  });
}

typedef _OpenTableTab = WorkbenchTableTab<_ColumnFilter>;

enum _ColumnFilterKind { text, number, boolean, dateTime }

class _ColumnFilter {
  final _ColumnFilterKind kind;
  final String operator;
  final String value;
  final bool remove;

  const _ColumnFilter({
    required this.kind,
    required this.operator,
    required this.value,
    this.remove = false,
  });
}

class _ColumnFilterDialog extends StatefulWidget {
  final DatabaseColumn column;
  final _ColumnFilter? initialFilter;

  const _ColumnFilterDialog({
    required this.column,
    required this.initialFilter,
  });

  @override
  State<_ColumnFilterDialog> createState() => _ColumnFilterDialogState();
}

class _ColumnFilterDialogState extends State<_ColumnFilterDialog> {
  late final TextEditingController _valueController;
  late final _ColumnFilterKind _kind;
  late String _operator;

  @override
  void initState() {
    super.initState();
    _kind = _filterKind(widget.column.dataType);
    _operator = widget.initialFilter?.operator ?? _operators.first.$1;
    _valueController = TextEditingController(
      text:
          widget.initialFilter?.value ??
          (_kind == _ColumnFilterKind.boolean ? 'true' : ''),
    );
    _valueController.addListener(_valueChanged);
  }

  @override
  void dispose() {
    _valueController.removeListener(_valueChanged);
    _valueController.dispose();
    super.dispose();
  }

  void _valueChanged() {
    if (mounted) setState(() {});
  }

  List<(String, String)> get _operators {
    switch (_kind) {
      case _ColumnFilterKind.text:
        return const [
          ('contains', 'Contains'),
          ('equals', 'Equals'),
          ('not-equals', 'Does not equal'),
          ('starts-with', 'Starts with'),
          ('ends-with', 'Ends with'),
          ('is-null', 'Is null'),
          ('is-not-null', 'Is not null'),
        ];
      case _ColumnFilterKind.number:
      case _ColumnFilterKind.dateTime:
        return const [
          ('equals', 'Equals'),
          ('not-equals', 'Does not equal'),
          ('greater-than', 'Greater than / After'),
          ('greater-or-equal', 'Greater than or equal'),
          ('less-than', 'Less than / Before'),
          ('less-or-equal', 'Less than or equal'),
          ('is-null', 'Is null'),
          ('is-not-null', 'Is not null'),
        ];
      case _ColumnFilterKind.boolean:
        return const [
          ('equals', 'Is'),
          ('is-null', 'Is null'),
          ('is-not-null', 'Is not null'),
        ];
    }
  }

  bool get _needsValue => _operator != 'is-null' && _operator != 'is-not-null';

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Filter ${widget.column.name}'),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              widget.column.displayType,
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: _operator,
              decoration: const InputDecoration(labelText: 'Condition'),
              items: [
                for (final operator in _operators)
                  DropdownMenuItem(
                    value: operator.$1,
                    child: Text(operator.$2),
                  ),
              ],
              onChanged: (value) {
                if (value != null) {
                  setState(() => _operator = value);
                }
              },
            ),
            if (_needsValue) ...[
              const SizedBox(height: 12),
              if (_kind == _ColumnFilterKind.boolean)
                DropdownButtonFormField<String>(
                  initialValue: _valueController.text,
                  decoration: const InputDecoration(labelText: 'Value'),
                  items: const [
                    DropdownMenuItem(value: 'true', child: Text('True')),
                    DropdownMenuItem(value: 'false', child: Text('False')),
                  ],
                  onChanged: (value) {
                    if (value != null) _valueController.text = value;
                  },
                )
              else
                TextField(
                  controller: _valueController,
                  autofocus: true,
                  keyboardType: _kind == _ColumnFilterKind.number
                      ? const TextInputType.numberWithOptions(
                          decimal: true,
                          signed: true,
                        )
                      : null,
                  decoration: InputDecoration(
                    labelText: _kind == _ColumnFilterKind.dateTime
                        ? 'Date / time value'
                        : 'Value',
                    hintText: _kind == _ColumnFilterKind.dateTime
                        ? '2026-06-06 or 2026-06-06 14:30'
                        : null,
                  ),
                ),
            ],
          ],
        ),
      ),
      actions: [
        if (widget.initialFilter != null)
          TextButton(
            onPressed: () => Navigator.of(context).pop(
              _ColumnFilter(
                kind: _kind,
                operator: _operator,
                value: '',
                remove: true,
              ),
            ),
            child: const Text('Clear'),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: !_needsValue || _valueController.text.trim().isNotEmpty
              ? () => Navigator.of(context).pop(
                  _ColumnFilter(
                    kind: _kind,
                    operator: _operator,
                    value: _valueController.text.trim(),
                  ),
                )
              : null,
          child: const Text('Apply'),
        ),
      ],
    );
  }

  static _ColumnFilterKind _filterKind(String dataType) {
    final type = dataType.toLowerCase();
    if (RegExp(
      r'int|numeric|decimal|real|double|serial|money',
    ).hasMatch(type)) {
      return _ColumnFilterKind.number;
    }
    if (RegExp(r'bool').hasMatch(type)) {
      return _ColumnFilterKind.boolean;
    }
    if (RegExp(r'date|time').hasMatch(type)) {
      return _ColumnFilterKind.dateTime;
    }
    return _ColumnFilterKind.text;
  }
}

class _SqlScriptFile {
  final File file;
  final String connectionKey;

  const _SqlScriptFile({required this.file, required this.connectionKey});

  String get title {
    final segments = file.path.split(Platform.pathSeparator);
    final name = segments.isEmpty ? file.path : segments.last;
    return name.toLowerCase().endsWith('.sql')
        ? name.substring(0, name.length - 4)
        : name;
  }

  String get label => '$connectionKey / $title';
}

class _SqlScriptPickerDialog extends StatefulWidget {
  final List<_SqlScriptFile> scripts;
  final bool showAllScripts;
  final Future<void> Function(bool value) onShowAllChanged;
  final Future<List<_SqlScriptFile>> Function() loadScripts;

  const _SqlScriptPickerDialog({
    required this.scripts,
    required this.showAllScripts,
    required this.onShowAllChanged,
    required this.loadScripts,
  });

  @override
  State<_SqlScriptPickerDialog> createState() => _SqlScriptPickerDialogState();
}

class _SqlScriptPickerDialogState extends State<_SqlScriptPickerDialog> {
  late bool _showAllScripts = widget.showAllScripts;
  late List<_SqlScriptFile> _scripts = widget.scripts;
  bool _isRefreshing = false;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Select SQL Script'),
      content: SizedBox(
        width: 520,
        height: 360,
        child: Column(
          children: [
            CheckboxListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: const Text('Show scripts for all connections'),
              value: _showAllScripts,
              onChanged: (value) async {
                final nextValue = value ?? false;
                setState(() {
                  _showAllScripts = nextValue;
                  _isRefreshing = true;
                });
                await widget.onShowAllChanged(nextValue);
                final scripts = await widget.loadScripts();
                if (mounted) {
                  setState(() {
                    _scripts = scripts;
                    _isRefreshing = false;
                  });
                }
              },
            ),
            const Divider(height: 1),
            Expanded(
              child: _isRefreshing
                  ? const Center(child: CircularProgressIndicator())
                  : _scripts.isEmpty
                  ? Center(
                      child: Text(
                        'No saved scripts for this selection.',
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    )
                  : ListView.builder(
                      itemCount: _scripts.length,
                      itemBuilder: (context, index) {
                        final script = _scripts[index];
                        return ListTile(
                          dense: true,
                          leading: const Icon(Icons.description, size: 18),
                          title: Text(script.title),
                          subtitle: Text(script.connectionKey),
                          onTap: () => Navigator.of(context).pop(script),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}

class _SqlScriptTab {
  String title;
  File? file;
  String connectionKey;
  final _SqlCodeController controller;
  final FocusNode focusNode = FocusNode();
  _SqlEditorError? error;
  String? aiSuggestion;
  bool aiCompleting = false;
  bool _disposed = false;

  _SqlScriptTab({
    required this.title,
    this.file,
    this.connectionKey = _MyHomePageState._globalScriptConnectionKey,
    required String text,
  }) : controller = _SqlCodeController(text: text) {
    controller.popupController.enabled = false;
  }

  Future<void> save() async {
    final file = this.file;
    if (file == null) return;
    final parent = file.parent;
    if (!parent.existsSync()) {
      parent.createSync(recursive: true);
    }
    await file.writeAsString(controller.text);
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    controller.dispose();
    focusNode.dispose();
  }
}

class _SqlCodeController extends CodeController {
  KeyEventResult Function(KeyEvent event)? completionKeyHandler;

  _SqlCodeController({required String text}) : super(text: text, language: sql);

  void refreshCompletions() => notifyListeners();

  @override
  KeyEventResult onKey(KeyEvent event) {
    final completionResult = completionKeyHandler?.call(event);
    if (completionResult == KeyEventResult.handled) {
      return KeyEventResult.handled;
    }
    return super.onKey(event);
  }
}

class _SqlEditorError {
  final int offset;
  final int line;
  final int column;
  final String message;

  const _SqlEditorError({
    required this.offset,
    required this.line,
    required this.column,
    required this.message,
  });

  factory _SqlEditorError.fromServerException(
    String sql,
    ServerException exception, {
    int editorOffset = 0,
  }) {
    return _SqlEditorError.fromPosition(
      sql,
      (exception.position ?? 1) + editorOffset,
      exception.message,
    );
  }

  factory _SqlEditorError.fromPostgresException(
    String sql,
    PostgresQueryException exception, {
    int editorOffset = 0,
  }) {
    return _SqlEditorError.fromPosition(
      sql,
      (exception.position ?? 1) + editorOffset,
      exception.cause.message,
    );
  }

  factory _SqlEditorError.fromPosition(
    String sql,
    int? position,
    String message,
  ) {
    final offset = ((position ?? 1) - 1).clamp(0, sql.length);
    final before = sql.substring(0, offset);
    final line = '\n'.allMatches(before).length + 1;
    final lineStart = before.lastIndexOf('\n') + 1;
    return _SqlEditorError(
      offset: offset,
      line: line,
      column: offset - lineStart + 1,
      message: message,
    );
  }
}

typedef _SqlCompletion = SqlCompletion;

class _SqlCodeEditor extends StatefulWidget {
  final _SqlCodeController controller;
  final FocusNode focusNode;
  final _SqlEditorError? error;
  final VoidCallback onDismissError;
  final VoidCallback onExecute;
  final String? aiSuggestion;
  final VoidCallback onAcceptAiSuggestion;
  final VoidCallback onDismissAiSuggestion;
  final List<_SqlCompletion> Function(TextEditingValue value) optionsBuilder;
  final ValueChanged<_SqlCompletion> onSelected;

  const _SqlCodeEditor({
    required this.controller,
    required this.focusNode,
    required this.error,
    required this.onDismissError,
    required this.onExecute,
    required this.aiSuggestion,
    required this.onAcceptAiSuggestion,
    required this.onDismissAiSuggestion,
    required this.optionsBuilder,
    required this.onSelected,
  });

  @override
  State<_SqlCodeEditor> createState() => _SqlCodeEditorState();
}

class _SqlCodeEditorState extends State<_SqlCodeEditor> {
  static const _textStyle = TextStyle(
    fontFamily: 'Consolas',
    fontSize: 14,
    height: 1.5,
  );

  List<_SqlCompletion> _options = const [];
  int _highlightedIndex = -1;
  bool _suppressNextChange = false;
  bool _caretScrollScheduled = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_updateOptions);
    widget.focusNode.addListener(_handleFocusChange);
    widget.controller.completionKeyHandler = _handleKeyEvent;
  }

  @override
  void didUpdateWidget(covariant _SqlCodeEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.completionKeyHandler = null;
      oldWidget.controller.removeListener(_updateOptions);
      widget.controller.addListener(_updateOptions);
      widget.controller.completionKeyHandler = _handleKeyEvent;
      _options = const [];
      _highlightedIndex = -1;
    }
    if (oldWidget.focusNode != widget.focusNode) {
      oldWidget.focusNode.removeListener(_handleFocusChange);
      widget.focusNode.addListener(_handleFocusChange);
    }
  }

  @override
  void dispose() {
    widget.controller.completionKeyHandler = null;
    widget.controller.removeListener(_updateOptions);
    widget.focusNode.removeListener(_handleFocusChange);
    super.dispose();
  }

  void _handleFocusChange() {
    if (!widget.focusNode.hasFocus && _options.isNotEmpty && mounted) {
      setState(() {
        _options = const [];
        _highlightedIndex = -1;
      });
    }
  }

  void _updateOptions() {
    _scheduleCaretVisibility();
    if (_suppressNextChange) {
      _suppressNextChange = false;
      return;
    }
    final nextOptions = widget.focusNode.hasFocus
        ? widget.optionsBuilder(widget.controller.value)
        : const <_SqlCompletion>[];
    if (!mounted) return;
    setState(() {
      _options = nextOptions;
      _highlightedIndex = -1;
    });
  }

  KeyEventResult _handleKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent) {
      return KeyEventResult.ignored;
    }

    if (event.logicalKey == LogicalKeyboardKey.enter &&
        HardwareKeyboard.instance.isControlPressed) {
      widget.onExecute();
      return KeyEventResult.handled;
    }

    if (_options.isNotEmpty &&
        event.logicalKey == LogicalKeyboardKey.arrowDown) {
      setState(() {
        _highlightedIndex = (_highlightedIndex + 1).clamp(
          0,
          _options.length - 1,
        );
      });
      return KeyEventResult.handled;
    }
    if (_options.isNotEmpty && event.logicalKey == LogicalKeyboardKey.arrowUp) {
      setState(() {
        _highlightedIndex = _highlightedIndex <= 0
            ? _options.length - 1
            : _highlightedIndex - 1;
      });
      return KeyEventResult.handled;
    }
    if (_options.isNotEmpty &&
        (event.logicalKey == LogicalKeyboardKey.enter ||
            event.logicalKey == LogicalKeyboardKey.numpadEnter)) {
      _select(_options[_highlightedIndex < 0 ? 0 : _highlightedIndex]);
      return KeyEventResult.handled;
    }
    if (_options.isNotEmpty && event.logicalKey == LogicalKeyboardKey.escape) {
      setState(() {
        _options = const [];
        _highlightedIndex = -1;
      });
      return KeyEventResult.handled;
    }
    if (_options.isEmpty &&
        widget.aiSuggestion != null &&
        event.logicalKey == LogicalKeyboardKey.tab) {
      widget.onAcceptAiSuggestion();
      return KeyEventResult.handled;
    }
    if (_options.isEmpty &&
        widget.aiSuggestion != null &&
        event.logicalKey == LogicalKeyboardKey.escape) {
      widget.onDismissAiSuggestion();
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  void _scheduleCaretVisibility() {
    if (_caretScrollScheduled) return;
    _caretScrollScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _caretScrollScheduled = false;
      if (!mounted) return;
      _ensureCaretVisible();
    });
  }

  void _ensureCaretVisible() {
    final selection = widget.controller.selection;
    if (!selection.isValid) return;

    final cursor = selection.extentOffset.clamp(
      0,
      widget.controller.text.length,
    );
    final textBeforeCursor = widget.controller.text.substring(0, cursor);
    final line = '\n'.allMatches(textBeforeCursor).length;
    final caretTop = 10.0 + line * (_textStyle.fontSize! * _textStyle.height!);
    final caretBottom = caretTop + (_textStyle.fontSize! * _textStyle.height!);

    final positions = <ScrollPosition>[];
    void collect(Element element) {
      if (element is StatefulElement && element.state is ScrollableState) {
        final state = element.state as ScrollableState;
        final position = state.position;
        if (position.axis == Axis.vertical && position.hasPixels) {
          positions.add(position);
        }
      }
      element.visitChildren(collect);
    }

    (context as Element).visitChildren(collect);
    for (final position in positions) {
      final visibleTop = position.pixels;
      final visibleBottom = visibleTop + position.viewportDimension;
      double? target;
      if (caretBottom > visibleBottom - 12) {
        target = caretBottom - position.viewportDimension + 12;
      } else if (caretTop < visibleTop + 8) {
        target = caretTop - 8;
      }
      if (target == null) continue;
      position.jumpTo(
        target.clamp(position.minScrollExtent, position.maxScrollExtent),
      );
    }
  }

  void _select(_SqlCompletion option) {
    _suppressNextChange = true;
    widget.onSelected(option);
    setState(() {
      _options = const [];
      _highlightedIndex = -1;
    });
    widget.focusNode.requestFocus();
  }

  Offset _caretOffset(double maxWidth) {
    final value = widget.controller.value;
    final cursor = value.selection.isValid
        ? value.selection.baseOffset.clamp(0, value.text.length)
        : value.text.length;
    return _textOffset(cursor, maxWidth);
  }

  Offset _textOffset(int offset, double maxWidth) {
    final text = widget.controller.text;
    final safeOffset = offset.clamp(0, text.length);
    final textBeforeCursor = text.substring(0, safeOffset);
    final painter = TextPainter(
      text: const TextSpan(text: '', style: _textStyle),
      textDirection: TextDirection.ltr,
    );
    painter.text = TextSpan(text: textBeforeCursor, style: _textStyle);
    painter.layout(maxWidth: maxWidth);
    return painter.getOffsetForCaret(
      TextPosition(offset: textBeforeCursor.length),
      Rect.zero,
    );
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return LayoutBuilder(
      builder: (context, constraints) {
        final caret = _caretOffset(constraints.maxWidth);
        final popupWidth = constraints.maxWidth.clamp(180.0, 340.0);
        final popupLeft = caret.dx.clamp(
          0.0,
          (constraints.maxWidth - popupWidth).clamp(0.0, double.infinity),
        );
        final desiredTop = caret.dy + 25;
        final popupTop = desiredTop.clamp(
          0.0,
          (constraints.maxHeight - 80).clamp(0.0, double.infinity),
        );
        final errorOffset = widget.error == null
            ? null
            : _textOffset(widget.error!.offset, constraints.maxWidth);

        return Stack(
          clipBehavior: Clip.hardEdge,
          children: [
            Positioned.fill(
              child: CodeTheme(
                data: CodeThemeData(
                  styles: dark ? atomOneDarkTheme : githubTheme,
                ),
                child: CodeField(
                  controller: widget.controller,
                  focusNode: widget.focusNode,
                  expands: true,
                  wrap: false,
                  background: Theme.of(context).colorScheme.surface,
                  cursorColor: const Color(0xff1f6feb),
                  textStyle: _textStyle,
                  padding: const EdgeInsets.fromLTRB(10, 10, 12, 36),
                  lineNumberBuilder: (line, style) {
                    final isErrorLine =
                        widget.error != null && line == widget.error!.line;
                    return TextSpan(
                      text: '$line',
                      style: (style ?? const TextStyle()).copyWith(
                        color: isErrorLine
                            ? const Color(0xffb42318)
                            : const Color(0xff7a858d),
                        fontWeight: isErrorLine
                            ? FontWeight.w700
                            : FontWeight.normal,
                      ),
                    );
                  },
                ),
              ),
            ),
            if (_options.isNotEmpty)
              Positioned(
                left: popupLeft,
                top: popupTop,
                width: popupWidth,
                child: Material(
                  elevation: 6,
                  color: Theme.of(context).colorScheme.surfaceContainerHigh,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 240),
                    child: ListView.builder(
                      padding: EdgeInsets.zero,
                      shrinkWrap: true,
                      itemCount: _options.length,
                      itemBuilder: (context, index) {
                        final option = _options[index];
                        final highlighted = index == _highlightedIndex;
                        return GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTapDown: (_) => _select(option),
                          child: Container(
                            height: 40,
                            color: highlighted
                                ? Theme.of(context).colorScheme.primaryContainer
                                : Theme.of(context).colorScheme.surface,
                            padding: const EdgeInsets.symmetric(horizontal: 10),
                            child: Row(
                              children: [
                                const Icon(Icons.code, size: 15),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    option.label,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontFamily: 'Consolas',
                                      fontSize: 13,
                                      fontWeight: highlighted
                                          ? FontWeight.w600
                                          : FontWeight.normal,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Flexible(
                                  child: Text(
                                    option.detail,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ),
            if (errorOffset != null)
              Positioned(
                left: errorOffset.dx,
                top: errorOffset.dy + 20,
                child: Tooltip(
                  message: widget.error!.message,
                  child: Container(
                    width: 14,
                    height: 3,
                    decoration: BoxDecoration(
                      color: const Color(0xffd13438),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              ),
            if (widget.error != null)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 7,
                  ),
                  color: Theme.of(context).colorScheme.errorContainer,
                  child: Row(
                    children: [
                      const Icon(
                        Icons.error_outline,
                        size: 16,
                        color: Color(0xffb42318),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Line ${widget.error!.line}, column ${widget.error!.column}: ${widget.error!.message}',
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: Theme.of(
                              context,
                            ).colorScheme.onErrorContainer,
                            fontSize: 12,
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      SizedBox(
                        width: 26,
                        height: 26,
                        child: IconButton(
                          key: const ValueKey('dismiss-sql-error'),
                          tooltip: 'Dismiss error',
                          onPressed: widget.onDismissError,
                          padding: EdgeInsets.zero,
                          visualDensity: VisualDensity.compact,
                          icon: Icon(
                            Icons.close,
                            size: 16,
                            color: Theme.of(
                              context,
                            ).colorScheme.onErrorContainer,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            if (widget.aiSuggestion != null)
              Positioned(
                left: 10,
                right: 10,
                bottom: widget.error == null ? 8 : 46,
                child: Material(
                  elevation: 3,
                  color: Theme.of(context).colorScheme.secondaryContainer,
                  borderRadius: BorderRadius.circular(5),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 9,
                      vertical: 7,
                    ),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.auto_awesome_outlined,
                          size: 15,
                          color: Color(0xff1473a8),
                        ),
                        const SizedBox(width: 7),
                        Expanded(
                          child: Text(
                            widget.aiSuggestion!,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontFamily: 'Consolas',
                              fontSize: 12,
                              color: Theme.of(
                                context,
                              ).colorScheme.onSecondaryContainer,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          'Tab to accept',
                          style: TextStyle(
                            fontSize: 10,
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurfaceVariant,
                          ),
                        ),
                        IconButton(
                          tooltip: 'Dismiss',
                          onPressed: widget.onDismissAiSuggestion,
                          icon: const Icon(Icons.close, size: 15),
                          visualDensity: VisualDensity.compact,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

typedef _OpenMySqlConnection = OpenMySqlConnection;
typedef _OpenDb2Connection = OpenDb2Connection;

class _Db2ConnectionTreeItem extends StatelessWidget {
  final _OpenDb2Connection connection;
  final bool active;
  final Set<String> loadingSchemas;
  final Set<String> loadingTables;
  final Future<bool> Function() onExpand;
  final VoidCallback onActivate;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback onInvalidate;
  final Future<void> Function(DatabaseSchema schema) onLoadSchema;
  final Future<void> Function(String schema, DatabaseTable table) onLoadTable;
  final Future<void> Function(
    String schema,
    DatabaseTable table,
    String initialTab,
  )
  onOpenTableData;
  final Future<void> Function(String schema, DatabaseTable table) onAttachTable;

  const _Db2ConnectionTreeItem({
    required this.connection,
    required this.active,
    required this.loadingSchemas,
    required this.loadingTables,
    required this.onExpand,
    required this.onActivate,
    required this.onEdit,
    required this.onDelete,
    required this.onInvalidate,
    required this.onLoadSchema,
    required this.onLoadTable,
    required this.onOpenTableData,
    required this.onAttachTable,
  });

  @override
  Widget build(BuildContext context) {
    final connected = connection.session != null;
    return DatabaseConnectionTreeTile(
      storageKey: 'db2-${connection.config.endpointName}',
      name: connection.config.displayName,
      connected: connected,
      active: active,
      connecting: connection.isConnecting,
      error: connection.connectionError,
      tags: connection.config.tags,
      onExpand: () async {
        await onExpand();
      },
      onActivate: onActivate,
      menuItems: [
        PopupMenuItem(
          value: connected ? 'activate' : 'connect',
          child: DatabaseMenuAction(connected ? 'Set active' : 'Connect'),
        ),
        const PopupMenuItem(value: 'edit', child: DatabaseMenuAction('Edit')),
        PopupMenuItem(
          value: 'invalidate',
          enabled: connected,
          child: const DatabaseMenuAction('Invalidate connection'),
        ),
        const PopupMenuItem(
          value: 'delete',
          child: DatabaseMenuAction('Delete'),
        ),
      ],
      onMenuSelected: (value) {
        switch (value) {
          case 'activate':
          case 'connect':
            onActivate();
            break;
          case 'edit':
            onEdit();
            break;
          case 'invalidate':
            onInvalidate();
            break;
          case 'delete':
            onDelete();
            break;
        }
      },
      children: [
        if (connection.isConnecting)
          const TreeItem(
            icon: Icons.sync,
            title: 'Connecting...',
            level: 1,
            showArrow: false,
          )
        else if (connection.connectionError != null)
          TreeItem(
            icon: Icons.error_outline,
            title: 'Connection failed',
            level: 1,
            showArrow: false,
            onTap: () => unawaited(onExpand()),
          )
        else if (!connected)
          const TreeItem(
            icon: Icons.power_settings_new,
            title: 'Expand to connect',
            level: 1,
            showArrow: false,
          )
        else
          for (final schema in connection.schemas)
            _SchemaTreeItem(
              connectionKey: connection.config.endpointName,
              schema: schema,
              isLoading: loadingSchemas.contains(
                '${connection.config.endpointName}.${schema.name}',
              ),
              onExpand: () => onLoadSchema(schema),
              onSelectSchema: (schemaName) async {},
              onRefresh: () => unawaited(onLoadSchema(schema)),
              onCopyName: (name) async {
                await Clipboard.setData(ClipboardData(text: name));
              },
              onAddToAiContext: () {},
              tableBuilder: (table) => _TableTreeItem(
                connectionKey: connection.config.endpointName,
                schema: schema.name,
                table: table,
                isLoading: loadingTables.contains(
                  '${connection.config.endpointName}.${schema.name}.${table.name}',
                ),
                onExpand: (schemaName, table) => onLoadTable(schemaName, table),
                onOpenTable: (schemaName, tableName) =>
                    onOpenTableData(schemaName, table, 'Data'),
                onGenerateSql: (schemaName, table, statement) async {},
                onOpenTableData: (schemaName, table) =>
                    onOpenTableData(schemaName, table, 'Data'),
                onOpenTableProperties: (schemaName, table) =>
                    onOpenTableData(schemaName, table, 'Properties'),
                onCopyName: (name) async {
                  await Clipboard.setData(ClipboardData(text: name));
                },
                onAddToAiContext: () =>
                    unawaited(onAttachTable(schema.name, table)),
                onRefresh: () => unawaited(onLoadSchema(schema)),
              ),
            ),
      ],
    );
  }
}

class _MySqlConnectionTreeItem extends StatelessWidget {
  final _OpenMySqlConnection connection;
  final bool active;
  final Future<bool> Function() onExpand;
  final VoidCallback onActivate;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback onInvalidate;
  final Future<void> Function(DatabaseTable table) onLoadTable;
  final Future<void> Function(DatabaseTable table) onOpenTable;
  final Future<void> Function(DatabaseTable table) onAttachTable;

  const _MySqlConnectionTreeItem({
    required this.connection,
    required this.active,
    required this.onExpand,
    required this.onActivate,
    required this.onEdit,
    required this.onDelete,
    required this.onInvalidate,
    required this.onLoadTable,
    required this.onOpenTable,
    required this.onAttachTable,
  });

  @override
  Widget build(BuildContext context) {
    final connected = connection.database != null;
    return DatabaseConnectionTreeTile(
      storageKey: 'mysql-${connection.config.endpointName}',
      name: connection.config.displayName,
      connected: connected,
      active: active,
      connecting: connection.isConnecting,
      error: connection.connectionError,
      tags: connection.config.tags,
      onExpand: () async {
        await onExpand();
      },
      onActivate: onActivate,
      menuItems: [
        PopupMenuItem(
          value: connected ? 'activate' : 'connect',
          child: DatabaseMenuAction(connected ? 'Set active' : 'Connect'),
        ),
        const PopupMenuItem(value: 'edit', child: DatabaseMenuAction('Edit')),
        PopupMenuItem(
          value: 'invalidate',
          enabled: connected,
          child: const DatabaseMenuAction('Invalidate connection'),
        ),
        const PopupMenuItem(
          value: 'delete',
          child: DatabaseMenuAction('Delete'),
        ),
      ],
      onMenuSelected: (value) {
        switch (value) {
          case 'activate':
          case 'connect':
            onActivate();
            break;
          case 'edit':
            onEdit();
            break;
          case 'invalidate':
            onInvalidate();
            break;
          case 'delete':
            onDelete();
            break;
        }
      },
      children: [
        if (connection.isConnecting)
          const TreeItem(
            icon: Icons.sync,
            title: 'Connecting...',
            level: 1,
            showArrow: false,
          )
        else if (connection.connectionError != null)
          TreeItem(
            icon: Icons.error_outline,
            title: 'Connection failed',
            level: 1,
            showArrow: false,
            onTap: () => unawaited(onExpand()),
          )
        else if (!connected)
          const TreeItem(
            icon: Icons.power_settings_new,
            title: 'Expand to connect',
            level: 1,
            showArrow: false,
          )
        else
          for (final table in connection.tables)
            ExpansionTile(
              key: PageStorageKey(
                'mysql-table-${connection.config.endpointName}-${table.name}',
              ),
              dense: true,
              tilePadding: const EdgeInsets.only(left: 26, right: 8),
              shape: const Border(),
              collapsedShape: const Border(),
              leading: Icon(
                table.relationType == 'View'
                    ? Icons.visibility_outlined
                    : Icons.table_chart_outlined,
                size: 15,
              ),
              title: DatabaseContextMenuRegion(
                menuItems: const [
                  PopupMenuItem(
                    value: 'open',
                    child: DatabaseMenuAction('Open Data'),
                  ),
                  PopupMenuItem(
                    value: 'context',
                    child: DatabaseMenuAction('Add to AI context'),
                  ),
                ],
                onSelected: (value) {
                  if (value == 'open') {
                    unawaited(onOpenTable(table));
                  } else if (value == 'context') {
                    unawaited(onAttachTable(table));
                  }
                },
                child: GestureDetector(
                  onDoubleTap: () => unawaited(onOpenTable(table)),
                  child: Text(
                    table.name,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              ),
              trailing: IconButton(
                tooltip: 'Add table to AI context',
                visualDensity: VisualDensity.compact,
                onPressed: () => unawaited(onAttachTable(table)),
                icon: const Icon(Icons.add_link_outlined, size: 15),
              ),
              onExpansionChanged: (expanded) {
                if (expanded) unawaited(onLoadTable(table));
              },
              children: [
                if (table.columnsLoaded)
                  for (final column in table.columns)
                    TreeItem(
                      icon: column.primaryKey
                          ? Icons.key_outlined
                          : Icons.view_column_outlined,
                      title: '${column.name}  ${column.dataType}',
                      level: 2,
                      showArrow: false,
                    ),
              ],
            ),
      ],
    );
  }
}

typedef _OpenConnection = OpenPostgresConnection;

class _ConnectionTreeItem extends StatelessWidget {
  final _OpenConnection connection;
  final bool active;
  final VoidCallback onActivate;
  final Future<bool> Function() onExpand;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback onInvalidate;
  final VoidCallback onCopyName;
  final Widget Function(DatabaseSchema schema) schemaBuilder;

  const _ConnectionTreeItem({
    required this.connection,
    required this.active,
    required this.onActivate,
    required this.onExpand,
    required this.onEdit,
    required this.onDelete,
    required this.onInvalidate,
    required this.onCopyName,
    required this.schemaBuilder,
  });

  @override
  Widget build(BuildContext context) {
    final connected = connection.database != null;
    return DatabaseConnectionTreeTile(
      storageKey: 'connection-${connection.config.endpointName}',
      name: connection.config.displayName,
      connected: connected,
      active: active,
      connecting: connection.isConnecting,
      error: connection.connectionError,
      tags: connection.config.tags,
      onExpand: () async {
        await onExpand();
      },
      onActivate: onActivate,
      menuItems: [
        PopupMenuItem(
          value: connected ? 'activate' : 'connect',
          child: DatabaseMenuAction(connected ? 'Set active' : 'Connect'),
        ),
        const PopupMenuItem(
          value: 'edit',
          child: DatabaseMenuAction('Edit connection'),
        ),
        PopupMenuItem(
          value: 'invalidate',
          enabled: connected,
          child: const DatabaseMenuAction('Invalidate connection'),
        ),
        const PopupMenuItem(
          value: 'copy',
          child: DatabaseMenuAction('Copy name'),
        ),
        const PopupMenuItem(
          value: 'delete',
          child: DatabaseMenuAction('Delete connection'),
        ),
      ],
      onMenuSelected: (value) {
        switch (value) {
          case 'activate':
          case 'connect':
            onActivate();
            break;
          case 'edit':
            onEdit();
            break;
          case 'invalidate':
            onInvalidate();
            break;
          case 'copy':
            onCopyName();
            break;
          case 'delete':
            onDelete();
            break;
        }
      },
      children: [
        if (connection.isConnecting)
          const TreeItem(
            icon: Icons.sync,
            title: 'Connecting...',
            level: 1,
            showArrow: false,
          )
        else if (connection.connectionError != null)
          TreeItem(
            icon: Icons.error_outline,
            title: 'Connection failed',
            level: 1,
            showArrow: false,
            onTap: () => unawaited(onExpand()),
          )
        else if (!connected)
          const TreeItem(
            icon: Icons.power_settings_new,
            title: 'Expand to connect',
            level: 1,
            showArrow: false,
          ),
        for (final schema in connection.schemas) schemaBuilder(schema),
      ],
    );
  }
}

class _SchemaTreeItem extends StatefulWidget {
  final String connectionKey;
  final DatabaseSchema schema;
  final bool isLoading;
  final Future<void> Function() onExpand;
  final Future<void> Function(String schema) onSelectSchema;
  final VoidCallback onRefresh;
  final void Function(String name) onCopyName;
  final VoidCallback onAddToAiContext;
  final Widget Function(DatabaseTable table) tableBuilder;

  const _SchemaTreeItem({
    required this.connectionKey,
    required this.schema,
    required this.isLoading,
    required this.onExpand,
    required this.onSelectSchema,
    required this.onRefresh,
    required this.onCopyName,
    required this.onAddToAiContext,
    required this.tableBuilder,
  });

  @override
  State<_SchemaTreeItem> createState() => _SchemaTreeItemState();
}

class _SchemaTreeItemState extends State<_SchemaTreeItem> {
  bool _loadQueued = false;

  @override
  void didUpdateWidget(covariant _SchemaTreeItem oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.schema.tablesLoaded || widget.isLoading) {
      _loadQueued = false;
    }
  }

  void _requestLoad() {
    if (widget.schema.tablesLoaded || widget.isLoading || _loadQueued) return;
    _loadQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(widget.onExpand().whenComplete(() => _loadQueued = false));
    });
  }

  @override
  Widget build(BuildContext context) {
    return DatabaseContextMenuRegion(
      menuItems: [
        PopupMenuItem(value: 'select', child: DatabaseMenuAction('Set active')),
        PopupMenuItem(value: 'refresh', child: DatabaseMenuAction('Refresh')),
        PopupMenuItem(value: 'copy', child: DatabaseMenuAction('Copy name')),
        PopupMenuItem(
          value: 'ai-context',
          child: DatabaseMenuAction('Add to AI context'),
        ),
        PopupMenuItem(
          value: 'properties',
          child: DatabaseMenuAction('View properties'),
        ),
      ],
      onSelected: (value) {
        switch (value) {
          case 'select':
          case 'properties':
            unawaited(widget.onSelectSchema(widget.schema.name));
            break;
          case 'refresh':
            widget.onRefresh();
            break;
          case 'copy':
            widget.onCopyName(widget.schema.name);
            break;
          case 'ai-context':
            widget.onAddToAiContext();
            break;
        }
      },
      child: ExpansionTile(
        key: PageStorageKey(
          'schema-${widget.connectionKey}-${widget.schema.name}',
        ),
        dense: true,
        initiallyExpanded: false,
        onExpansionChanged: (expanded) {
          if (expanded) {
            _requestLoad();
          }
        },
        tilePadding: const EdgeInsets.only(left: 22, right: 8),
        leading: const Icon(Icons.folder, size: 16, color: Colors.blueGrey),
        title: DatabaseHoverTitle(
          child: Text(widget.schema.name, style: const TextStyle(fontSize: 13)),
        ),
        children: [
          if (!widget.schema.tablesLoaded)
            Padding(
              padding: const EdgeInsets.only(left: 58, right: 8, bottom: 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: widget.isLoading
                    ? Text(
                        'Loading tables...',
                        style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      )
                    : TextButton.icon(
                        onPressed: _requestLoad,
                        icon: const Icon(Icons.refresh, size: 14),
                        label: const Text('Load tables'),
                        style: TextButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          padding: EdgeInsets.zero,
                          textStyle: const TextStyle(fontSize: 12),
                        ),
                      ),
              ),
            ),
          if (widget.schema.tablesLoaded && widget.schema.tables.isEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 58, right: 8, bottom: 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'No tables found.',
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          for (final table in widget.schema.tables)
            KeyedSubtree(
              key: ValueKey(
                '${widget.connectionKey}.${widget.schema.name}.${table.name}',
              ),
              child: widget.tableBuilder(table),
            ),
        ],
      ),
    );
  }
}

class _TableTreeItem extends StatelessWidget {
  final String connectionKey;
  final String schema;
  final DatabaseTable table;
  final bool isLoading;
  final Future<void> Function(String schema, DatabaseTable table) onExpand;
  final Future<void> Function(String schema, String table) onOpenTable;
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
  final VoidCallback onAddToAiContext;
  final VoidCallback onRefresh;

  const _TableTreeItem({
    required this.connectionKey,
    required this.schema,
    required this.table,
    required this.isLoading,
    required this.onExpand,
    required this.onOpenTable,
    required this.onGenerateSql,
    required this.onOpenTableData,
    required this.onOpenTableProperties,
    required this.onCopyName,
    required this.onAddToAiContext,
    required this.onRefresh,
  });

  @override
  Widget build(BuildContext context) {
    return DatabaseContextMenuRegion(
      menuItems: [
        PopupMenuItem(
          value: 'open-data',
          child: DatabaseMenuAction('View data'),
        ),
        PopupMenuItem(enabled: false, child: DatabaseMenuAction('Generate')),
        PopupMenuItem(value: 'select', child: DatabaseMenuAction('  SELECT')),
        PopupMenuItem(value: 'insert', child: DatabaseMenuAction('  INSERT')),
        PopupMenuItem(value: 'update', child: DatabaseMenuAction('  UPDATE')),
        PopupMenuItem(value: 'delete', child: DatabaseMenuAction('  DELETE')),
        PopupMenuItem(value: 'refresh', child: DatabaseMenuAction('Refresh')),
        PopupMenuItem(value: 'copy', child: DatabaseMenuAction('Copy name')),
        PopupMenuItem(
          value: 'ai-context',
          child: DatabaseMenuAction('Add to AI context'),
        ),
        PopupMenuItem(
          value: 'properties',
          child: DatabaseMenuAction('View properties'),
        ),
      ],
      onSelected: (value) {
        switch (value) {
          case 'open-data':
            unawaited(onOpenTableData(schema, table));
            break;
          case 'select':
          case 'insert':
          case 'update':
          case 'delete':
            unawaited(onGenerateSql(schema, table, value));
            break;
          case 'refresh':
            onRefresh();
            break;
          case 'copy':
            onCopyName(table.name);
            break;
          case 'ai-context':
            onAddToAiContext();
            break;
          case 'properties':
            unawaited(onOpenTableProperties(schema, table));
            break;
        }
      },
      child: ExpansionTile(
        key: PageStorageKey('table-$connectionKey-$schema-${table.name}'),
        dense: true,
        tilePadding: const EdgeInsets.only(left: 58, right: 8),
        childrenPadding: EdgeInsets.zero,
        leading: const Icon(
          Icons.table_chart,
          size: 16,
          color: Colors.blueGrey,
        ),
        title: InkWell(
          onTap: () => unawaited(onOpenTable(schema, table.name)),
          onDoubleTap: () => unawaited(onOpenTableData(schema, table)),
          child: DatabaseHoverTitle(
            child: Text(table.name, style: const TextStyle(fontSize: 13)),
          ),
        ),
        children: [
          ExpansionTile(
            key: PageStorageKey('columns-$connectionKey-$schema-${table.name}'),
            dense: true,
            initiallyExpanded: false,
            onExpansionChanged: (expanded) {
              if (expanded && !table.columnsLoaded && !isLoading) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  unawaited(onExpand(schema, table));
                });
              }
            },
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
                Padding(
                  padding: const EdgeInsets.only(
                    left: 116,
                    right: 8,
                    bottom: 8,
                  ),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      isLoading
                          ? 'Loading columns...'
                          : 'Loading column metadata...',
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                )
              else if (table.columns.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(
                    left: 116,
                    right: 8,
                    bottom: 8,
                  ),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'No columns found.',
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
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
          _TableMetadataFolder(
            storageKey: 'constraints-$connectionKey-$schema-${table.name}',
            icon: Icons.key,
            title: 'Constraints',
            emptyText: 'No constraints found.',
            items: table.constraints.map((item) => item.toString()).toList(),
            loaded: table.columnsLoaded,
            isLoading: isLoading,
            onLoad: () => onExpand(schema, table),
          ),
          _TableMetadataFolder(
            storageKey: 'indexes-$connectionKey-$schema-${table.name}',
            icon: Icons.format_list_numbered,
            title: 'Indexes',
            emptyText: 'No indexes found.',
            items: table.indexes.map((item) => item.toString()).toList(),
            loaded: table.columnsLoaded,
            isLoading: isLoading,
            onLoad: () => onExpand(schema, table),
          ),
          _TableMetadataFolder(
            storageKey: 'foreign-keys-$connectionKey-$schema-${table.name}',
            icon: Icons.link,
            title: 'Foreign Keys',
            emptyText: 'No foreign keys found.',
            items: table.foreignKeys.map((item) => item.toString()).toList(),
            loaded: table.columnsLoaded,
            isLoading: isLoading,
            onLoad: () => onExpand(schema, table),
          ),
          _TableMetadataFolder(
            storageKey: 'triggers-$connectionKey-$schema-${table.name}',
            icon: Icons.bolt,
            title: 'Triggers',
            emptyText: 'No triggers found.',
            items: table.triggers.map((item) => item.toString()).toList(),
            loaded: table.columnsLoaded,
            isLoading: isLoading,
            onLoad: () => onExpand(schema, table),
          ),
        ],
      ),
    );
  }
}

class _TableMetadataFolder extends StatelessWidget {
  final String storageKey;
  final IconData icon;
  final String title;
  final String emptyText;
  final List<String> items;
  final bool loaded;
  final bool isLoading;
  final Future<void> Function() onLoad;

  const _TableMetadataFolder({
    required this.storageKey,
    required this.icon,
    required this.title,
    required this.emptyText,
    required this.items,
    required this.loaded,
    required this.isLoading,
    required this.onLoad,
  });

  @override
  Widget build(BuildContext context) {
    return ExpansionTile(
      key: PageStorageKey(storageKey),
      dense: true,
      initiallyExpanded: false,
      onExpansionChanged: (expanded) {
        if (expanded && !loaded && !isLoading) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            unawaited(onLoad());
          });
        }
      },
      tilePadding: const EdgeInsets.only(left: 80, right: 8),
      childrenPadding: EdgeInsets.zero,
      leading: Icon(icon, size: 16, color: Colors.blueGrey),
      title: Text(title, style: const TextStyle(fontSize: 13)),
      children: [
        if (items.isEmpty)
          Padding(
            padding: const EdgeInsets.only(left: 116, right: 8, bottom: 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                loaded
                    ? emptyText
                    : isLoading
                    ? 'Loading metadata...'
                    : 'Loading metadata...',
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          )
        else
          for (final item in items)
            TreeItem(icon: icon, title: item, level: 5, showArrow: false),
      ],
    );
  }
}

class _GridRendererControl extends StatelessWidget {
  final ResultGridRenderer value;
  final bool compact;
  final ValueChanged<ResultGridRenderer> onChanged;

  const _GridRendererControl({
    required this.value,
    required this.onChanged,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    if (compact) {
      return PopupMenuButton<ResultGridRenderer>(
        tooltip: 'Grid renderer: ${_label(value)}',
        initialValue: value,
        onSelected: onChanged,
        icon: Icon(
          value == ResultGridRenderer.pluto
              ? Icons.grid_on_outlined
              : Icons.view_column_outlined,
          size: 18,
        ),
        itemBuilder: (context) => [
          for (final renderer in ResultGridRenderer.values)
            PopupMenuItem(
              value: renderer,
              child: Row(
                children: [
                  Icon(
                    renderer == ResultGridRenderer.pluto
                        ? Icons.grid_on_outlined
                        : Icons.view_column_outlined,
                    size: 16,
                  ),
                  const SizedBox(width: 8),
                  Text(_label(renderer)),
                  if (renderer == value) ...[
                    const Spacer(),
                    const Icon(Icons.check, size: 16),
                  ],
                ],
              ),
            ),
        ],
      );
    }

    return SizedBox(
      height: 28,
      child: SegmentedButton<ResultGridRenderer>(
        showSelectedIcon: false,
        segments: const [
          ButtonSegment(
            value: ResultGridRenderer.queryDock,
            icon: Icon(Icons.view_column_outlined, size: 14),
            label: Text('QueryDock'),
          ),
          ButtonSegment(
            value: ResultGridRenderer.pluto,
            icon: Icon(Icons.grid_on_outlined, size: 14),
            label: Text('PlutoGrid'),
          ),
        ],
        selected: {value},
        onSelectionChanged: (selection) => onChanged(selection.first),
        style: ButtonStyle(
          visualDensity: VisualDensity.compact,
          padding: const WidgetStatePropertyAll(
            EdgeInsets.symmetric(horizontal: 8),
          ),
          textStyle: const WidgetStatePropertyAll(TextStyle(fontSize: 11)),
        ),
      ),
    );
  }

  String _label(ResultGridRenderer renderer) {
    return renderer == ResultGridRenderer.pluto ? 'PlutoGrid' : 'QueryDock';
  }
}

class _SqlConnectionSelector extends StatelessWidget {
  final bool compact;
  final String value;
  final String label;
  final List<_SqlConnectionChoice> connections;
  final String globalKey;
  final ValueChanged<String> onChanged;

  const _SqlConnectionSelector({
    required this.compact,
    required this.value,
    required this.label,
    required this.connections,
    required this.globalKey,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    if (compact) {
      return Align(
        alignment: Alignment.centerLeft,
        child: PopupMenuButton<String>(
          key: const ValueKey('sql-connection-compact-selector'),
          tooltip: 'Script connection: $label',
          initialValue: value,
          onSelected: onChanged,
          icon: Icon(
            value == globalKey
                ? Icons.link_off_outlined
                : Icons.storage_outlined,
            size: 18,
          ),
          itemBuilder: (context) => [
            PopupMenuItem(value: globalKey, child: const Text('No connection')),
            for (final connection in connections)
              PopupMenuItem(
                value: connection.key,
                child: Text('${connection.label} (${connection.engine})'),
              ),
          ],
        ),
      );
    }

    return DropdownButtonHideUnderline(
      child: DropdownButton<String>(
        key: const ValueKey('sql-connection-dropdown'),
        value: value,
        isDense: true,
        isExpanded: true,
        items: [
          DropdownMenuItem(
            value: globalKey,
            child: const Text('No connection'),
          ),
          for (final connection in connections)
            DropdownMenuItem(
              value: connection.key,
              child: Text(
                '${connection.label} (${connection.engine})',
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
              ),
            ),
        ],
        onChanged: (next) {
          if (next != null) onChanged(next);
        },
      ),
    );
  }
}

class _SqlConnectionChoice {
  final String key;
  final String label;
  final String engine;

  const _SqlConnectionChoice({
    required this.key,
    required this.label,
    required this.engine,
  });
}

class _CompactResultTab extends StatelessWidget {
  final String title;
  final IconData icon;
  final bool active;
  final VoidCallback onTap;

  const _CompactResultTab({
    required this.title,
    required this.icon,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: title,
      onPressed: onTap,
      visualDensity: VisualDensity.compact,
      style: IconButton.styleFrom(
        backgroundColor: active
            ? Theme.of(context).colorScheme.surface
            : Colors.transparent,
        side: active
            ? BorderSide(color: Theme.of(context).dividerColor)
            : BorderSide.none,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
      ),
      icon: Icon(icon, size: 17),
    );
  }
}

enum _CenterTabAction { close, closeOthers, closeAll, closeLeft, closeRight }

class _TabMenuCommand extends StatelessWidget {
  final IconData icon;
  final String label;
  final String? shortcut;

  const _TabMenuCommand({
    required this.icon,
    required this.label,
    this.shortcut,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 17),
        const SizedBox(width: 10),
        Expanded(child: Text(label)),
        if (shortcut != null) ...[
          const SizedBox(width: 24),
          Text(
            shortcut!,
            style: TextStyle(
              fontSize: 11,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );
  }
}

class _CenterTabScrollButton extends StatelessWidget {
  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;

  const _CenterTabScrollButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 28,
      height: 34,
      child: IconButton(
        tooltip: tooltip,
        onPressed: onPressed,
        padding: EdgeInsets.zero,
        visualDensity: VisualDensity.compact,
        icon: Icon(icon, size: 18),
      ),
    );
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
  final bool hasChanges;
  final bool canEdit;
  final int loadedRows;
  final bool hasMoreRows;
  final bool loadingMore;
  final VoidCallback onSaveChanges;
  final VoidCallback onCancelChanges;
  final ValueChanged<String> onExport;
  final VoidCallback onImport;

  const _TableDataBrowserBar({
    required this.schema,
    required this.table,
    required this.filterController,
    required this.isExecuting,
    required this.onApplyFilter,
    required this.onRefresh,
    required this.onClose,
    required this.hasChanges,
    required this.canEdit,
    required this.loadedRows,
    required this.hasMoreRows,
    required this.loadingMore,
    required this.onSaveChanges,
    required this.onCancelChanges,
    required this.onExport,
    required this.onImport,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 42,
      color: Theme.of(context).colorScheme.surfaceContainer,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 560;
          final medium = constraints.maxWidth < 900;
          return Row(
            children: [
              if (!compact) ...[
                const Icon(Icons.table_chart, size: 16, color: Colors.blueGrey),
                const SizedBox(width: 6),
                ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: medium ? 120 : 220),
                  child: Text(
                    '$schema.$table',
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
              ],
              Expanded(
                child: TextField(
                  key: const ValueKey('table-data-filter'),
                  controller: filterController,
                  enabled: !isExecuting,
                  onSubmitted: (_) => onApplyFilter(),
                  style: const TextStyle(fontFamily: 'Consolas', fontSize: 13),
                  decoration: InputDecoration(
                    prefixIcon: const Icon(Icons.filter_alt, size: 16),
                    hintText: compact
                        ? 'Filter rows'
                        : "Filter rows, e.g. status = 'ACTIVE'",
                    isDense: true,
                    border: const OutlineInputBorder(),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 8,
                    ),
                  ),
                ),
              ),
              if (!medium) ...[
                const SizedBox(width: 8),
                Text(
                  loadingMore
                      ? '$loadedRows rows, loading...'
                      : hasMoreRows
                      ? '$loadedRows rows loaded'
                      : '$loadedRows rows',
                  style: TextStyle(
                    fontSize: 11,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(width: 4),
              ],
              if (!compact) ...[
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
                PopupMenuButton<String>(
                  tooltip: 'Import or export data',
                  onSelected: (value) {
                    if (value == 'import') {
                      onImport();
                    } else {
                      onExport(value);
                    }
                  },
                  itemBuilder: (context) => [
                    const PopupMenuItem(
                      value: 'csv',
                      child: Text('Export CSV'),
                    ),
                    const PopupMenuItem(
                      value: 'json',
                      child: Text('Export JSON'),
                    ),
                    const PopupMenuDivider(),
                    PopupMenuItem(
                      value: 'import',
                      enabled: canEdit && !isExecuting,
                      child: const Text('Import CSV'),
                    ),
                  ],
                  icon: const Icon(Icons.import_export, size: 18),
                ),
              ],
              if (!medium) ...[
                IconButton(
                  tooltip: canEdit
                      ? 'Save row changes'
                      : 'Editing requires a primary key',
                  onPressed: hasChanges && canEdit && !isExecuting
                      ? onSaveChanges
                      : null,
                  icon: const Icon(Icons.save, size: 18),
                ),
                IconButton(
                  tooltip: 'Cancel row changes',
                  onPressed: hasChanges && !isExecuting
                      ? onCancelChanges
                      : null,
                  icon: const Icon(Icons.undo, size: 18),
                ),
                IconButton(
                  tooltip: 'Close data browser',
                  onPressed: onClose,
                  icon: const Icon(Icons.close, size: 18),
                ),
              ] else
                PopupMenuButton<String>(
                  key: const ValueKey('table-data-actions-menu'),
                  tooltip: 'Table data actions',
                  onSelected: (value) {
                    switch (value) {
                      case 'apply':
                        onApplyFilter();
                      case 'refresh':
                        onRefresh();
                      case 'save':
                        onSaveChanges();
                      case 'cancel':
                        onCancelChanges();
                      case 'close':
                        onClose();
                      case 'export-csv':
                        onExport('csv');
                      case 'export-json':
                        onExport('json');
                      case 'import':
                        onImport();
                    }
                  },
                  itemBuilder: (context) => [
                    PopupMenuItem(
                      value: 'apply',
                      enabled: !isExecuting,
                      child: const Text('Apply filter'),
                    ),
                    PopupMenuItem(
                      value: 'refresh',
                      enabled: !isExecuting,
                      child: const Text('Refresh data'),
                    ),
                    const PopupMenuDivider(),
                    PopupMenuItem(
                      value: 'save',
                      enabled: hasChanges && canEdit && !isExecuting,
                      child: const Text('Save changes'),
                    ),
                    PopupMenuItem(
                      value: 'cancel',
                      enabled: hasChanges && !isExecuting,
                      child: const Text('Cancel changes'),
                    ),
                    const PopupMenuDivider(),
                    const PopupMenuItem(
                      value: 'export-csv',
                      child: Text('Export CSV'),
                    ),
                    const PopupMenuItem(
                      value: 'export-json',
                      child: Text('Export JSON'),
                    ),
                    PopupMenuItem(
                      value: 'import',
                      enabled: canEdit && !isExecuting,
                      child: const Text('Import CSV'),
                    ),
                    const PopupMenuDivider(),
                    const PopupMenuItem(
                      value: 'close',
                      child: Text('Close data browser'),
                    ),
                  ],
                  icon: const Icon(Icons.more_vert, size: 18),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _TablePropertiesView extends StatelessWidget {
  final String schema;
  final DatabaseTable metadata;

  const _TablePropertiesView({required this.schema, required this.metadata});

  @override
  Widget build(BuildContext context) {
    final columns = metadata.columns;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          height: 36,
          color: Theme.of(context).colorScheme.surfaceContainer,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          alignment: Alignment.centerLeft,
          child: Text(
            '$schema.${metadata.name}',
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
        ),
        Expanded(
          child: DefaultTabController(
            length: 7,
            child: Column(
              children: [
                Container(
                  height: 34,
                  color: Theme.of(context).colorScheme.surfaceContainerHigh,
                  child: TabBar(
                    isScrollable: true,
                    tabAlignment: TabAlignment.start,
                    labelColor: Theme.of(context).colorScheme.onSurface,
                    unselectedLabelColor: Theme.of(
                      context,
                    ).colorScheme.onSurfaceVariant,
                    indicatorColor: Theme.of(context).colorScheme.primary,
                    tabs: const [
                      Tab(text: 'Overview'),
                      Tab(text: 'Columns'),
                      Tab(text: 'Constraints'),
                      Tab(text: 'Foreign Keys'),
                      Tab(text: 'Indexes'),
                      Tab(text: 'Triggers'),
                      Tab(text: 'DDL'),
                    ],
                  ),
                ),
                Expanded(
                  child: TabBarView(
                    children: [
                      _TableOverview(schema: schema, metadata: metadata),
                      ResultGrid(
                        columns: const [
                          'Name',
                          'Type',
                          'Nullable',
                          'Primary Key',
                          'Default',
                          'Identity',
                          'Generated',
                          'Comment',
                        ],
                        rows: [
                          for (final column in columns)
                            [
                              column.name,
                              column.dataType,
                              column.nullable ? 'YES' : 'NO',
                              column.primaryKey ? 'YES' : '',
                              column.defaultValue,
                              column.identity,
                              column.generated,
                              column.comment,
                            ],
                        ],
                      ),
                      ResultGrid(
                        columns: const ['Name', 'Type', 'Definition'],
                        rows: [
                          for (final item in metadata.constraints)
                            [item.name, item.type, item.definition],
                        ],
                      ),
                      ResultGrid(
                        columns: const [
                          'Name',
                          'Referenced Schema',
                          'Referenced Table',
                          'Definition',
                        ],
                        rows: [
                          for (final item in metadata.foreignKeys)
                            [
                              item.name,
                              item.referencedSchema,
                              item.referencedTable,
                              item.definition,
                            ],
                        ],
                      ),
                      ResultGrid(
                        columns: const [
                          'Name',
                          'Unique',
                          'Primary',
                          'Constraint-owned',
                          'Definition',
                        ],
                        rows: [
                          for (final item in metadata.indexes)
                            [
                              item.name,
                              item.unique ? 'YES' : 'NO',
                              item.primary ? 'YES' : 'NO',
                              item.constraintOwned ? 'YES' : 'NO',
                              item.definition,
                            ],
                        ],
                      ),
                      ResultGrid(
                        columns: const ['Name', 'State', 'Definition'],
                        rows: [
                          for (final item in metadata.triggers)
                            [item.name, item.enabled, item.definition],
                        ],
                      ),
                      _DdlViewer(ddl: metadata.ddl),
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

class _TableOverview extends StatelessWidget {
  final String schema;
  final DatabaseTable metadata;

  const _TableOverview({required this.schema, required this.metadata});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 6),
      children: [
        PropertyRow(name: 'Schema', value: schema),
        PropertyRow(name: 'Name', value: metadata.name),
        PropertyRow(name: 'Type', value: metadata.relationType),
        PropertyRow(
          name: 'Owner',
          value: metadata.owner.isEmpty ? '-' : metadata.owner,
        ),
        PropertyRow(name: 'Persistence', value: metadata.persistence),
        PropertyRow(
          name: 'Tablespace',
          value: metadata.tablespace.isEmpty
              ? 'pg_default'
              : metadata.tablespace,
        ),
        PropertyRow(name: 'Columns', value: '${metadata.columns.length}'),
        PropertyRow(
          name: 'Constraints',
          value: '${metadata.constraints.length + metadata.foreignKeys.length}',
        ),
        PropertyRow(name: 'Indexes', value: '${metadata.indexes.length}'),
        PropertyRow(name: 'Triggers', value: '${metadata.triggers.length}'),
        PropertyRow(
          name: 'Estimated rows',
          value: metadata.estimatedRows.toString(),
        ),
        PropertyRow(
          name: 'Table size',
          value: _formatBytes(metadata.tableBytes),
        ),
        PropertyRow(
          name: 'Index size',
          value: _formatBytes(metadata.indexBytes),
        ),
        PropertyRow(
          name: 'Total size',
          value: _formatBytes(metadata.totalBytes),
        ),
        PropertyRow(
          name: 'Comment',
          value: metadata.comment.isEmpty ? '-' : metadata.comment,
        ),
      ],
    );
  }

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    const units = ['KB', 'MB', 'GB', 'TB'];
    var value = bytes / 1024;
    var unit = 0;
    while (value >= 1024 && unit < units.length - 1) {
      value /= 1024;
      unit++;
    }
    return '${value.toStringAsFixed(value >= 10 ? 1 : 2)} ${units[unit]}';
  }
}

class _DdlViewer extends StatefulWidget {
  final String ddl;

  const _DdlViewer({required this.ddl});

  @override
  State<_DdlViewer> createState() => _DdlViewerState();
}

class _DdlViewerState extends State<_DdlViewer> {
  final ScrollController _verticalController = ScrollController();
  final ScrollController _horizontalController = ScrollController();

  @override
  void dispose() {
    _verticalController.dispose();
    _horizontalController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Theme.of(context).colorScheme.surface,
      padding: const EdgeInsets.all(12),
      alignment: Alignment.topLeft,
      child: Scrollbar(
        key: const ValueKey('ddl-vertical-scrollbar'),
        controller: _verticalController,
        notificationPredicate: (notification) =>
            notification.metrics.axis == Axis.vertical,
        child: SingleChildScrollView(
          controller: _verticalController,
          primary: false,
          child: Scrollbar(
            key: const ValueKey('ddl-horizontal-scrollbar'),
            controller: _horizontalController,
            scrollbarOrientation: ScrollbarOrientation.bottom,
            notificationPredicate: (notification) =>
                notification.metrics.axis == Axis.horizontal,
            child: SingleChildScrollView(
              controller: _horizontalController,
              primary: false,
              scrollDirection: Axis.horizontal,
              child: SelectableText(
                widget.ddl,
                style: const TextStyle(
                  fontFamily: 'Consolas',
                  fontSize: 13,
                  height: 1.45,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _TableUmlDiagram extends StatefulWidget {
  final String schema;
  final DatabaseTable metadata;

  const _TableUmlDiagram({required this.schema, required this.metadata});

  @override
  State<_TableUmlDiagram> createState() => _TableUmlDiagramState();
}

class _TableUmlDiagramState extends State<_TableUmlDiagram> {
  final TransformationController _transformationController =
      TransformationController();

  @override
  void dispose() {
    _transformationController.dispose();
    super.dispose();
  }

  void _zoom(double factor) {
    final current = _transformationController.value;
    final scale = current.getMaxScaleOnAxis();
    final next = (scale * factor).clamp(0.35, 2.5);
    _transformationController.value = Matrix4.diagonal3Values(next, next, 1);
  }

  void _reset() {
    _transformationController.value = Matrix4.identity();
  }

  @override
  Widget build(BuildContext context) {
    final metadata = widget.metadata;
    final relationships = [
      for (final foreignKey in metadata.foreignKeys)
        _DiagramRelationship(foreignKey: foreignKey, incoming: false),
      for (final foreignKey in metadata.incomingForeignKeys)
        _DiagramRelationship(foreignKey: foreignKey, incoming: true),
    ];
    final related = <String, _DiagramEntity>{};
    for (final relationship in relationships) {
      final foreignKey = relationship.foreignKey;
      final schema = relationship.incoming
          ? foreignKey.sourceSchema
          : foreignKey.referencedSchema;
      final table = relationship.incoming
          ? foreignKey.sourceTable
          : foreignKey.referencedTable;
      final columns = relationship.incoming
          ? foreignKey.sourceColumns
          : foreignKey.referencedColumns;
      final key = '$schema.$table';
      related.update(
        key,
        (entity) =>
            entity.copyWith(columns: {...entity.columns, ...columns}.toList()),
        ifAbsent: () =>
            _DiagramEntity(schema: schema, table: table, columns: columns),
      );
    }

    const canvasSize = Size(1400, 900);
    const centerRect = Rect.fromLTWH(550, 260, 300, 380);
    final relatedRects = <String, Rect>{};
    final entities = related.values.toList();
    for (var index = 0; index < entities.length; index++) {
      final angle = entities.length == 1
          ? 0.0
          : (index / entities.length) * math.pi * 2 - math.pi / 2;
      final x = 700 + math.cos(angle) * 470 - 130;
      final y = 450 + math.sin(angle) * 300 - 105;
      relatedRects[entities[index].key] = Rect.fromLTWH(x, y, 260, 225);
    }

    return Stack(
      children: [
        Positioned.fill(
          child: ColoredBox(
            color: Theme.of(context).colorScheme.surfaceContainerLowest,
            child: InteractiveViewer(
              key: const ValueKey('table-uml-diagram'),
              transformationController: _transformationController,
              constrained: false,
              minScale: 0.35,
              maxScale: 2.5,
              boundaryMargin: const EdgeInsets.all(240),
              child: SizedBox.fromSize(
                size: canvasSize,
                child: Stack(
                  children: [
                    Positioned.fromRect(
                      rect: centerRect,
                      child: _UmlEntityCard(
                        schema: widget.schema,
                        table: metadata.name,
                        columns: [
                          for (final column in metadata.columns)
                            _DiagramColumn(
                              name: column.name,
                              type: column.dataType,
                              primaryKey: column.primaryKey,
                              foreignKey: metadata.foreignKeys.any(
                                (foreignKey) => foreignKey.sourceColumns
                                    .contains(column.name),
                              ),
                              nullable: column.nullable,
                            ),
                        ],
                        focused: true,
                      ),
                    ),
                    for (final entity in entities)
                      Positioned.fromRect(
                        rect: relatedRects[entity.key]!,
                        child: _UmlEntityCard(
                          schema: entity.schema,
                          table: entity.table,
                          columns: [
                            for (final column in entity.columns)
                              _DiagramColumn(
                                name: column,
                                type: '',
                                foreignKey: relationships.any(
                                  (relationship) =>
                                      relationship.incoming &&
                                      relationship.foreignKey.sourceSchema ==
                                          entity.schema &&
                                      relationship.foreignKey.sourceTable ==
                                          entity.table &&
                                      relationship.foreignKey.sourceColumns
                                          .contains(column),
                                ),
                              ),
                          ],
                        ),
                      ),
                    Positioned.fill(
                      child: IgnorePointer(
                        child: CustomPaint(
                          key: const ValueKey('uml-relationship-overlay'),
                          painter: _DiagramRelationshipPainter(
                            centerRect: centerRect,
                            relatedRects: relatedRects,
                            relationships: relationships,
                            centerSchema: widget.schema,
                            centerTable: metadata.name,
                            colorScheme: Theme.of(context).colorScheme,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        Positioned(
          top: 10,
          right: 10,
          child: Material(
            color: Theme.of(context).colorScheme.surfaceContainer,
            elevation: 2,
            borderRadius: BorderRadius.circular(6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: 'Zoom out',
                  onPressed: () => _zoom(0.8),
                  icon: const Icon(Icons.remove, size: 18),
                ),
                IconButton(
                  tooltip: 'Reset diagram',
                  onPressed: _reset,
                  icon: const Icon(Icons.center_focus_strong, size: 18),
                ),
                IconButton(
                  tooltip: 'Zoom in',
                  onPressed: () => _zoom(1.25),
                  icon: const Icon(Icons.add, size: 18),
                ),
              ],
            ),
          ),
        ),
        Positioned(
          left: 12,
          bottom: 10,
          child: Text(
            relationships.isEmpty
                ? 'No foreign-key relationships found'
                : '${relationships.length} relationship${relationships.length == 1 ? '' : 's'}',
            style: TextStyle(
              fontSize: 11,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }
}

class _DiagramEntity {
  final String schema;
  final String table;
  final List<String> columns;

  const _DiagramEntity({
    required this.schema,
    required this.table,
    required this.columns,
  });

  String get key => '$schema.$table';

  _DiagramEntity copyWith({List<String>? columns}) {
    return _DiagramEntity(
      schema: schema,
      table: table,
      columns: columns ?? this.columns,
    );
  }
}

class _DiagramRelationship {
  final DatabaseForeignKey foreignKey;
  final bool incoming;

  const _DiagramRelationship({
    required this.foreignKey,
    required this.incoming,
  });
}

class _DiagramColumn {
  final String name;
  final String type;
  final bool primaryKey;
  final bool foreignKey;
  final bool nullable;

  const _DiagramColumn({
    required this.name,
    required this.type,
    this.primaryKey = false,
    this.foreignKey = false,
    this.nullable = true,
  });
}

class _UmlEntityCard extends StatelessWidget {
  final String schema;
  final String table;
  final List<_DiagramColumn> columns;
  final bool focused;

  const _UmlEntityCard({
    required this.schema,
    required this.table,
    required this.columns,
    this.focused = false,
  });

  @override
  Widget build(BuildContext context) {
    final visibleColumns = columns.take(focused ? 11 : 6).toList();
    return Material(
      color: Theme.of(context).colorScheme.surface,
      elevation: focused ? 5 : 2,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(6),
        side: BorderSide(
          color: focused
              ? Theme.of(context).colorScheme.primary
              : Theme.of(context).dividerColor,
          width: focused ? 2 : 1,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            height: 48,
            color: focused
                ? Theme.of(context).colorScheme.primaryContainer
                : Theme.of(context).colorScheme.surfaceContainerHigh,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  table,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  schema,
                  style: TextStyle(
                    fontSize: 10,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          for (final column in visibleColumns)
            SizedBox(
              height: 25,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Row(
                  children: [
                    SizedBox(
                      width: 38,
                      child: Row(
                        children: [
                          if (column.primaryKey)
                            const Icon(
                              Icons.key,
                              size: 13,
                              color: Colors.amber,
                            ),
                          if (column.foreignKey)
                            const Icon(
                              Icons.link,
                              size: 13,
                              color: Colors.blueGrey,
                            ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: Text(
                        column.name,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontFamily: 'Consolas',
                          fontSize: 11,
                        ),
                      ),
                    ),
                    if (column.type.isNotEmpty)
                      Flexible(
                        child: Text(
                          column.type,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.right,
                          style: TextStyle(
                            fontFamily: 'Consolas',
                            fontSize: 10,
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    if (!column.nullable)
                      const Padding(
                        padding: EdgeInsets.only(left: 4),
                        child: Text('*', style: TextStyle(fontSize: 11)),
                      ),
                  ],
                ),
              ),
            ),
          if (columns.length > visibleColumns.length)
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text(
                '+ ${columns.length - visibleColumns.length} more columns',
                style: TextStyle(
                  fontSize: 10,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _DiagramRelationshipPainter extends CustomPainter {
  final Rect centerRect;
  final Map<String, Rect> relatedRects;
  final List<_DiagramRelationship> relationships;
  final String centerSchema;
  final String centerTable;
  final ColorScheme colorScheme;

  const _DiagramRelationshipPainter({
    required this.centerRect,
    required this.relatedRects,
    required this.relationships,
    required this.centerSchema,
    required this.centerTable,
    required this.colorScheme,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final relationshipCounts = <String, int>{};
    for (final relationship in relationships) {
      final key = _relatedKey(relationship);
      relationshipCounts[key] = (relationshipCounts[key] ?? 0) + 1;
    }
    final relationshipIndexes = <String, int>{};

    for (final relationship in relationships) {
      final foreignKey = relationship.foreignKey;
      final relatedKey = _relatedKey(relationship);
      final relatedRect = relatedRects[relatedKey];
      if (relatedRect == null) continue;

      final fromRect = relationship.incoming ? relatedRect : centerRect;
      final toRect = relationship.incoming ? centerRect : relatedRect;
      final relationshipIndex = relationshipIndexes.update(
        relatedKey,
        (index) => index + 1,
        ifAbsent: () => 0,
      );
      final count = relationshipCounts[relatedKey] ?? 1;
      final lane = (relationshipIndex - (count - 1) / 2) * 14;
      final horizontal =
          (toRect.center.dx - fromRect.center.dx).abs() >=
          (toRect.center.dy - fromRect.center.dy).abs();
      final laneOffset = horizontal ? Offset(0, lane) : Offset(lane, 0);
      final from = _edgePoint(fromRect, toRect.center) + laneOffset;
      final to = _edgePoint(toRect, fromRect.center) + laneOffset;
      final middleX = (from.dx + to.dx) / 2;
      final path = ui.Path()
        ..moveTo(from.dx, from.dy)
        ..lineTo(middleX, from.dy)
        ..lineTo(middleX, to.dy)
        ..lineTo(to.dx, to.dy);

      final backingPaint = Paint()
        ..color = colorScheme.surface
        ..strokeWidth = 6
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke;
      final relationshipColor = relationship.incoming
          ? colorScheme.tertiary
          : colorScheme.primary;
      final linePaint = Paint()
        ..color = relationshipColor
        ..strokeWidth = 2.5
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke;
      canvas
        ..drawPath(path, backingPaint)
        ..drawPath(path, linePaint)
        ..drawCircle(to, 5, Paint()..color = colorScheme.surface)
        ..drawCircle(to, 3.5, Paint()..color = relationshipColor);
      _paintText(
        canvas,
        '*',
        from + const Offset(6, -17),
        colorScheme,
        relationshipColor,
      );
      _paintText(
        canvas,
        '1',
        to + const Offset(6, -17),
        colorScheme,
        relationshipColor,
      );
      _paintText(
        canvas,
        foreignKey.name,
        Offset(middleX + 5, (from.dy + to.dy) / 2 - 16),
        colorScheme,
        relationshipColor,
      );
    }
  }

  String _relatedKey(_DiagramRelationship relationship) {
    final foreignKey = relationship.foreignKey;
    return relationship.incoming
        ? '${foreignKey.sourceSchema}.${foreignKey.sourceTable}'
        : '${foreignKey.referencedSchema}.${foreignKey.referencedTable}';
  }

  Offset _edgePoint(Rect rect, Offset toward) {
    final dx = toward.dx - rect.center.dx;
    final dy = toward.dy - rect.center.dy;
    if (dx.abs() * rect.height > dy.abs() * rect.width) {
      return Offset(dx > 0 ? rect.right : rect.left, rect.center.dy);
    }
    return Offset(rect.center.dx, dy > 0 ? rect.bottom : rect.top);
  }

  void _paintText(
    Canvas canvas,
    String text,
    Offset offset,
    ColorScheme scheme,
    Color color,
  ) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: color,
          fontSize: 10,
          fontWeight: FontWeight.w600,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: 180);
    final backgroundRect = RRect.fromRectAndRadius(
      offset & Size(painter.width + 6, painter.height + 2),
      const Radius.circular(3),
    );
    canvas.drawRRect(
      backgroundRect,
      Paint()..color = scheme.surface.withValues(alpha: 0.94),
    );
    painter.paint(canvas, offset + const Offset(3, 1));
  }

  @override
  bool shouldRepaint(covariant _DiagramRelationshipPainter oldDelegate) {
    return oldDelegate.relationships != relationships ||
        oldDelegate.colorScheme != colorScheme;
  }
}
