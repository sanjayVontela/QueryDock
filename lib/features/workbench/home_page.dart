import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:panes/panes.dart';
import 'package:path_provider/path_provider.dart';
import 'package:postgres/postgres.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
  static const String _showAllSqlScriptsKey = 'workbench.sql_scripts.show_all';
  static const String _globalScriptConnectionKey = 'global';

  late final IdeController _controller;
  final PostgresConnectionStore _connectionStore = PostgresConnectionStore();

  PostgresDatabase? _database;
  bool _isExecuting = false;
  bool _isConnecting = false;
  bool _showAllSqlScripts = false;
  double _resultPanelHeight = 260;

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
  final Set<String> _loadingSchemas = {};
  final Set<String> _loadingTables = {};

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
    _initializeSqlEditor();
    _loadSavedConnections();
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
    _activeResultTab.dispose();
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

  Future<void> _newConnection() async {
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

  Future<void> _deleteConnection(_OpenConnection connection) async {
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
    await _invalidateConnection(connection, quiet: true);

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

    await database.close();

    if (!mounted) return;

    setState(() {
      connection.database = null;
      connection.schemas = const [];
      connection.connectionError = null;
      connection.isConnecting = false;
      for (var index = _openTableTabs.length - 1; index >= 0; index--) {
        final tab = _openTableTabs[index];
        if (tab.database == database) {
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
      _isConnecting = _connections.any((item) => item.isConnecting);
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
        _isConnecting = _connections.any((item) => item.isConnecting);
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
        _isConnecting = _connections.any((item) => item.isConnecting);
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
    );
  }

  Future<PostgresQueryResult?> _runSql(
    String sql, {
    bool updateSqlResults = true,
    PostgresDatabase? databaseOverride,
    String? editorText,
    int editorOffset = 0,
  }) async {
    final database = databaseOverride ?? _database;

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
      _activeSqlTab?.error = null;
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
        _logs.add('[ERROR] Query failed: $error');
      });
      _showResultTab('Messages');
      return null;
    }
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

  Future<bool> _confirmProtectedWrite(PostgresConnectionConfig config) async {
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

    setState(() {
      _isExecuting = false;
      _logs.add('[WARN] Query execution stopped by user.');
    });
    _showResultTab('Messages');
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
      _activeCenterTab = _sqlTabs.length - 1;
      _logs.add('[INFO] Created SQL script: ${script.title}');
    });
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
          database: database,
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
    await _loadTableTabData(tab);
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
    if (tab.database.config.writeProtected &&
        !await _confirmProtectedWrite(tab.database.config)) {
      return;
    }

    setState(() {
      _isExecuting = true;
      _logs.add('[INFO] Saving ${tab.pendingChanges.length} edited rows');
    });

    try {
      var affectedRows = 0;
      for (final rowEntry in tab.pendingChanges.entries) {
        final originalRow = tab.rows[rowEntry.key];
        final changes = <String, Object?>{};
        for (final cell in rowEntry.value.entries) {
          final column = tab.columns[cell.key];
          changes[column.name] = _typedCellValue(column, cell.value);
        }
        final primaryKey = <String, Object?>{
          for (final column in tab.primaryKeyColumns)
            column.name: originalRow[tab.resultColumns.indexOf(column.name)],
        };
        affectedRows += await tab.database.updateRow(
          schema: tab.schema,
          table: tab.table,
          changes: changes,
          primaryKey: primaryKey,
        );
      }

      if (!mounted) return;
      setState(() {
        tab.pendingChanges.clear();
        _isExecuting = false;
        _logs.add('[INFO] Saved $affectedRows updated rows');
      });
      await _loadTableTabData(tab);
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
      tab.pendingChanges.clear();
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
  }

  void _filterSqlTabsForActiveConnection() {
    if (_sqlTabs.isEmpty) {
      _sqlTabs.add(_SqlScriptTab(title: 'SQL Editor', text: ''));
      _activeCenterTab = 0;
    } else if (_activeCenterTab >= _sqlTabs.length) {
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
    final textBeforeCursor = value.text.substring(0, cursor);
    final match = RegExp(
      r'[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z0-9_]*)?$',
    ).firstMatch(textBeforeCursor);
    final token = match?.group(0) ?? '';
    if (token.isEmpty) return const [];

    final lowerToken = token.toLowerCase();
    final tokenStart = match?.start ?? cursor;
    final connection = _connectionForKey(tab.connectionKey);
    final schemas =
        connection?.schemas ??
        _activeOpenConnection?.schemas ??
        const <DatabaseSchema>[];
    final aliases = _sqlAliases(value.text);

    if (token.contains('.')) {
      final dotIndex = token.indexOf('.');
      final qualifier = token.substring(0, dotIndex);
      final suffix = token.substring(dotIndex + 1).toLowerCase();
      final schema = schemas
          .where(
            (candidate) =>
                candidate.name.toLowerCase() == qualifier.toLowerCase(),
          )
          .firstOrNull;
      if (schema != null) {
        return [
          for (final table in schema.tables)
            if (table.name.toLowerCase().startsWith(suffix))
              _SqlCompletion(
                label: '${schema.name}.${table.name}',
                detail: 'Table',
                text: value.text.replaceRange(
                  tokenStart,
                  cursor,
                  '${schema.name}.${table.name} ${_tableAlias(table.name, aliases.keys)}',
                ),
                cursorOffset:
                    tokenStart +
                    schema.name.length +
                    table.name.length +
                    _tableAlias(table.name, aliases.keys).length +
                    2,
                schema: schema.name,
                table: table.name,
              ),
        ].take(12).toList();
      }

      final alias = qualifier;
      final columnPrefix = suffix;
      final tableReference = aliases[alias.toLowerCase()];
      if (tableReference == null) return const [];

      final table = _findTable(
        schemas,
        tableReference.schema,
        tableReference.table,
      );
      if (table == null || !table.columnsLoaded) return const [];

      return [
        for (final column in table.columns)
          if (column.name.toLowerCase().startsWith(columnPrefix))
            _SqlCompletion(
              label: '$alias.${column.name}',
              detail: column.displayType,
              text: value.text.replaceRange(
                tokenStart,
                cursor,
                '$alias.${column.name}',
              ),
              cursorOffset: tokenStart + alias.length + column.name.length + 1,
            ),
      ].take(12).toList();
    }

    final completions = <_SqlCompletion>[];
    final keywords = <String>{
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
    };

    for (final keyword in keywords) {
      if (keyword.toLowerCase().startsWith(lowerToken)) {
        completions.add(
          _SqlCompletion(
            label: keyword,
            detail: 'SQL keyword',
            text: value.text.replaceRange(tokenStart, cursor, keyword),
            cursorOffset: tokenStart + keyword.length,
          ),
        );
      }
    }

    for (final schema in schemas) {
      if (schema.name.toLowerCase().startsWith(lowerToken)) {
        completions.add(
          _SqlCompletion(
            label: schema.name,
            detail: 'Schema',
            text: value.text.replaceRange(tokenStart, cursor, schema.name),
            cursorOffset: tokenStart + schema.name.length,
          ),
        );
      }
      for (final table in schema.tables) {
        final qualifiedName = '${schema.name}.${table.name}';
        if (!table.name.toLowerCase().startsWith(lowerToken) &&
            !qualifiedName.toLowerCase().startsWith(lowerToken)) {
          continue;
        }
        final alias = _tableAlias(table.name, aliases.keys);
        final insertion = '${table.name} $alias';
        completions.add(
          _SqlCompletion(
            label: table.name,
            detail: 'Table  ->  $insertion',
            text: value.text.replaceRange(tokenStart, cursor, insertion),
            cursorOffset: tokenStart + insertion.length,
            schema: schema.name,
            table: table.name,
          ),
        );
      }
    }

    return completions.take(12).toList();
  }

  void _insertAutocompleteOption(_SqlCompletion option) {
    final sqlTab = _activeSqlTab;
    if (sqlTab == null) return;

    sqlTab.controller.value = TextEditingValue(
      text: option.text,
      selection: TextSelection.collapsed(offset: option.cursorOffset),
    );

    if (option.schema != null && option.table != null) {
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

  Map<String, _SqlTableReference> _sqlAliases(String sql) {
    final aliases = <String, _SqlTableReference>{};
    final pattern = RegExp(
      r'\b(?:from|join)\s+(?:(\w+)\.)?(\w+)\s+(?:as\s+)?(\w+)',
      caseSensitive: false,
    );
    const reserved = {
      'where',
      'join',
      'left',
      'right',
      'inner',
      'outer',
      'full',
      'cross',
      'order',
      'group',
      'limit',
      'on',
      'union',
    };

    for (final match in pattern.allMatches(sql)) {
      final alias = match.group(3)?.toLowerCase();
      if (alias == null || reserved.contains(alias)) continue;
      aliases[alias] = _SqlTableReference(
        schema: match.group(1),
        table: match.group(2)!,
      );
    }
    return aliases;
  }

  DatabaseTable? _findTable(
    List<DatabaseSchema> schemas,
    String? schemaName,
    String tableName,
  ) {
    for (final schema in schemas) {
      if (schemaName != null && schema.name != schemaName) continue;
      for (final table in schema.tables) {
        if (table.name == tableName) return table;
      }
    }
    return null;
  }

  String _tableAlias(String tableName, Iterable<String> existingAliases) {
    final parts = tableName
        .split(RegExp(r'[_\W]+'))
        .where((part) => part.isNotEmpty)
        .toList();
    var alias = parts.length > 1
        ? parts.map((part) => part[0]).join()
        : tableName.substring(0, tableName.length.clamp(1, 2));
    alias = alias.toLowerCase();
    final existing = existingAliases.map((item) => item.toLowerCase()).toSet();
    if (!existing.contains(alias)) return alias;

    var suffix = 2;
    while (existing.contains('$alias$suffix')) {
      suffix++;
    }
    return '$alias$suffix';
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
      applicationName: 'DB Viewer',
      applicationVersion: '1.0.0',
      applicationIcon: const Icon(Icons.storage, size: 32),
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

  String _lineNumberText(String text) {
    final lineCount = text.isEmpty ? 1 : '\n'.allMatches(text).length + 1;
    return [for (var line = 1; line <= lineCount; line++) '$line'].join('\n');
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

  _OpenConnection? get _activeOpenConnection {
    final database = _database;
    if (database == null) return null;

    for (final connection in _connections) {
      if (connection.database == database) return connection;
    }
    return null;
  }

  int get _tableTabOffset => _sqlTabs.length;

  String get _activeScriptConnectionKey {
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

  String _buildTableDataSql(_OpenTableTab tab) {
    final filter = tab.filterController.text.trim();
    final filters = [
      if (filter.isNotEmpty) '($filter)',
      for (final entry in tab.columnFilters.entries)
        _columnFilterSql(entry.key, entry.value),
    ];
    final buffer = StringBuffer()
      ..writeln('SELECT *')
      ..writeln(
        'FROM ${_quoteIdentifier(tab.schema)}.${_quoteIdentifier(tab.table)}',
      );

    if (filters.isNotEmpty) {
      buffer.writeln('WHERE ${filters.join('\n  AND ')}');
    }

    if (tab.sortColumn != null) {
      buffer.writeln(
        'ORDER BY ${_quoteIdentifier(tab.sortColumn!)} ${tab.sortAscending ? 'ASC' : 'DESC'}',
      );
    }

    buffer.write('LIMIT 500;');
    return buffer.toString();
  }

  String _columnFilterSql(String column, _ColumnFilter filter) {
    final identifier = _quoteIdentifier(column);
    switch (filter.operator) {
      case 'is-null':
        return '$identifier IS NULL';
      case 'is-not-null':
        return '$identifier IS NOT NULL';
      case 'contains':
        return '$identifier::text ILIKE ${_quoteSqlValue('%${filter.value}%')}';
      case 'starts-with':
        return '$identifier::text ILIKE ${_quoteSqlValue('${filter.value}%')}';
      case 'ends-with':
        return '$identifier::text ILIKE ${_quoteSqlValue('%${filter.value}')}';
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
        return IndexedStack(
          index: _resultTabIndex(activeTab),
          children: [
            ResultGrid(columns: _columns, rows: _rows),
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
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          backgroundColor: const Color(0xfff3f3f3),
          body: Column(
            children: [
              AppTitleBar(connectionName: _activeConnection, status: _status),
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
                    _controller.toggleRight();
                  });
                },
                onToggleOutput: () {
                  setState(() {
                    _controller.toggleBottom();
                  });
                },
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
                onExecute: _isExecuting || _isConnecting ? null : _executeSql,
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
                      'Add a PostgreSQL connection to begin.',
                      style: TextStyle(fontSize: 12, color: Colors.black54),
                    ),
                  ),
                for (final connection in _connections)
                  _ConnectionTreeItem(
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
                    onDelete: () => unawaited(_deleteConnection(connection)),
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
                            if (!await _ensureConnection(connection)) return;
                            await _loadTableColumns(schema, table);
                          },
                          onOpenTable: (schema, table) async {
                            if (!await _ensureConnection(connection)) return;
                            _openTable(schema, table);
                          },
                          onGenerateSql: (schema, table, statement) async {
                            if (!await _ensureConnection(connection)) return;
                            await _generateTableSql(
                              schema,
                              table.name,
                              statement,
                            );
                          },
                          onOpenTableData: (schema, table) async {
                            if (!await _ensureConnection(connection)) return;
                            await _openTableData(schema, table);
                          },
                          onOpenTableProperties: (schema, table) async {
                            if (!await _ensureConnection(connection)) return;
                            await _openTableData(
                              schema,
                              table,
                              initialTab: 'Properties',
                            );
                          },
                          onCopyName: (name) =>
                              _copyToClipboard(name, 'table name'),
                          onRefresh: () {
                            unawaited(
                              _ensureConnection(connection).then((connected) {
                                if (connected) return _refreshSchemas();
                              }),
                            );
                          },
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
          child: LayoutBuilder(
            builder: (context, constraints) {
              final maxResultHeight = (constraints.maxHeight - 140).clamp(
                120.0,
                constraints.maxHeight,
              );
              final resultHeight = _resultPanelHeight.clamp(
                120.0,
                maxResultHeight,
              );
              return Column(
                children: [
                  Expanded(child: _buildSqlEditorSurface(sqlTab)),
                  MouseRegion(
                    cursor: SystemMouseCursors.resizeRow,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onVerticalDragUpdate: (details) {
                        setState(() {
                          _resultPanelHeight =
                              (_resultPanelHeight - details.delta.dy).clamp(
                                120.0,
                                maxResultHeight,
                              );
                        });
                      },
                      child: Container(
                        height: 7,
                        color: const Color(0xffd8dee2),
                        alignment: Alignment.center,
                        child: Container(
                          width: 36,
                          height: 2,
                          color: const Color(0xff8b9aa3),
                        ),
                      ),
                    ),
                  ),
                  SizedBox(
                    height: resultHeight,
                    child: Column(
                      children: [
                        _buildResultHeader(),
                        Expanded(
                          child: Container(
                            color: Colors.white,
                            child: _buildResultContent(),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              );
            },
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
          decoration: const BoxDecoration(
            color: Color(0xfff5f7f8),
            border: Border(bottom: BorderSide(color: Color(0xffd8dee2))),
          ),
          child: Row(
            children: [
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
              const Spacer(),
              Text(
                activeTab == 'Data'
                    ? '${_rows.length} rows'
                    : '${_logs.length} messages',
                style: const TextStyle(fontSize: 12, color: Colors.black54),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildSqlEditorSurface(_SqlScriptTab sqlTab) {
    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(bottom: BorderSide(color: Color(0xffd2d2d2))),
      ),
      child: Column(
        children: [
          Container(
            height: 34,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: const BoxDecoration(
              color: Color(0xfff5f7f8),
              border: Border(bottom: BorderSide(color: Color(0xffd8dee2))),
            ),
            child: Row(
              children: [
                const Icon(Icons.terminal, size: 16, color: Colors.blueGrey),
                const SizedBox(width: 8),
                const Text(
                  'Connection:',
                  style: TextStyle(fontSize: 12, color: Colors.black54),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      value:
                          [
                            _globalScriptConnectionKey,
                            for (final connection in _connections)
                              connection.config.endpointName,
                          ].contains(sqlTab.connectionKey)
                          ? sqlTab.connectionKey
                          : _connectionForKey(
                                  sqlTab.connectionKey,
                                )?.config.endpointName ??
                                _globalScriptConnectionKey,
                      isDense: true,
                      isExpanded: true,
                      items: [
                        const DropdownMenuItem(
                          value: _globalScriptConnectionKey,
                          child: Text('No connection'),
                        ),
                        for (final connection in _connections)
                          DropdownMenuItem(
                            value: connection.config.endpointName,
                            child: Text(
                              connection.config.displayName,
                              overflow: TextOverflow.ellipsis,
                              maxLines: 1,
                            ),
                          ),
                      ],
                      onChanged: (value) {
                        if (value != null) {
                          unawaited(_setSqlTabConnection(sqlTab, value));
                        }
                      },
                    ),
                  ),
                ),
                const SizedBox(width: 6),
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
            ),
          ),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ValueListenableBuilder<TextEditingValue>(
                  valueListenable: sqlTab.controller,
                  builder: (context, value, child) {
                    return Container(
                      width: 52,
                      color: const Color(0xfff0f3f5),
                      padding: const EdgeInsets.only(top: 12, right: 8),
                      alignment: Alignment.topRight,
                      child: Text(
                        _lineNumberText(value.text),
                        textAlign: TextAlign.right,
                        style: const TextStyle(
                          color: Color(0xff7a858d),
                          fontFamily: 'Consolas',
                          fontSize: 13,
                          height: 1.5,
                        ),
                      ),
                    );
                  },
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: _SqlAutocompleteEditor(
                      controller: sqlTab.controller,
                      focusNode: sqlTab.focusNode,
                      error: sqlTab.error,
                      optionsBuilder: (value) =>
                          _sqlAutocompleteOptions(sqlTab, value),
                      onSelected: _insertAutocompleteOption,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
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
          decoration: const BoxDecoration(
            color: Color(0xfff5f7f8),
            border: Border(bottom: BorderSide(color: Color(0xffd8dee2))),
          ),
          child: Row(
            children: [
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
              hasChanges: tab.pendingChanges.isNotEmpty,
              canEdit: tab.canEdit,
              onSaveChanges: () => unawaited(_saveTableChanges(tab)),
              onCancelChanges: () => _cancelTableChanges(tab),
            ),
            Expanded(
              child: ResultGrid(
                columns: tab.resultColumns,
                rows: tab.rows,
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
  final Map<String, _ColumnFilter> columnFilters = {};
  final Map<int, Map<int, String>> pendingChanges = {};
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

  List<DatabaseColumn> get primaryKeyColumns =>
      columns.where((column) => column.primaryKey).toList();

  bool get canEdit =>
      primaryKeyColumns.isNotEmpty &&
      primaryKeyColumns.every((column) => resultColumns.contains(column.name));

  void dispose() {
    filterController.dispose();
  }
}

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
              style: const TextStyle(fontSize: 12, color: Colors.black54),
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
                  ? const Center(
                      child: Text(
                        'No saved scripts for this selection.',
                        style: TextStyle(color: Colors.black54),
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
  final TextEditingController controller;
  final FocusNode focusNode = FocusNode();
  _SqlEditorError? error;

  _SqlScriptTab({
    required this.title,
    this.file,
    this.connectionKey = _MyHomePageState._globalScriptConnectionKey,
    required String text,
  }) : controller = TextEditingController(text: text);

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
    controller.dispose();
    focusNode.dispose();
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

class _SqlCompletion {
  final String label;
  final String detail;
  final String text;
  final int cursorOffset;
  final String? schema;
  final String? table;

  const _SqlCompletion({
    required this.label,
    required this.detail,
    required this.text,
    required this.cursorOffset,
    this.schema,
    this.table,
  });
}

class _SqlTableReference {
  final String? schema;
  final String table;

  const _SqlTableReference({required this.schema, required this.table});
}

class _SqlAutocompleteEditor extends StatefulWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final _SqlEditorError? error;
  final List<_SqlCompletion> Function(TextEditingValue value) optionsBuilder;
  final ValueChanged<_SqlCompletion> onSelected;

  const _SqlAutocompleteEditor({
    required this.controller,
    required this.focusNode,
    required this.error,
    required this.optionsBuilder,
    required this.onSelected,
  });

  @override
  State<_SqlAutocompleteEditor> createState() => _SqlAutocompleteEditorState();
}

class _SqlAutocompleteEditorState extends State<_SqlAutocompleteEditor> {
  static const _textStyle = TextStyle(
    fontFamily: 'Consolas',
    fontSize: 14,
    height: 1.5,
  );

  List<_SqlCompletion> _options = const [];
  int _highlightedIndex = -1;
  bool _suppressNextChange = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_updateOptions);
    widget.focusNode.addListener(_handleFocusChange);
  }

  @override
  void didUpdateWidget(covariant _SqlAutocompleteEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_updateOptions);
      widget.controller.addListener(_updateOptions);
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

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent || _options.isEmpty) {
      return KeyEventResult.ignored;
    }

    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      setState(() {
        _highlightedIndex = (_highlightedIndex + 1).clamp(
          0,
          _options.length - 1,
        );
      });
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      setState(() {
        _highlightedIndex = _highlightedIndex <= 0
            ? _options.length - 1
            : _highlightedIndex - 1;
      });
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter) {
      _select(_options[_highlightedIndex < 0 ? 0 : _highlightedIndex]);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      setState(() {
        _options = const [];
        _highlightedIndex = -1;
      });
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
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

        return Focus(
          onKeyEvent: _handleKeyEvent,
          child: Stack(
            clipBehavior: Clip.hardEdge,
            children: [
              Positioned.fill(
                child: TextField(
                  controller: widget.controller,
                  focusNode: widget.focusNode,
                  maxLines: null,
                  expands: true,
                  textAlignVertical: TextAlignVertical.top,
                  style: _textStyle,
                  decoration: const InputDecoration(
                    border: InputBorder.none,
                    hintText:
                        'Write SQL here. Select a statement or run the whole script.',
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
                    color: Colors.white,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 240),
                      child: ListView.builder(
                        padding: EdgeInsets.zero,
                        shrinkWrap: true,
                        itemCount: _options.length,
                        itemBuilder: (context, index) {
                          final option = _options[index];
                          final highlighted = index == _highlightedIndex;
                          return InkWell(
                            onTap: () => _select(option),
                            child: Container(
                              height: 40,
                              color: highlighted
                                  ? const Color(0xffd9eaf7)
                                  : Colors.white,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                              ),
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
                                      style: const TextStyle(
                                        fontSize: 11,
                                        color: Colors.black54,
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
                    color: const Color(0xffffeeee),
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
                            style: const TextStyle(
                              color: Color(0xff8a1c1c),
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _OpenConnection {
  PostgresConnectionConfig config;
  PostgresDatabase? database;
  List<DatabaseSchema> schemas;
  bool isConnecting = false;
  String? connectionError;

  _OpenConnection({required this.config, required List<DatabaseSchema> schemas})
    : schemas = List<DatabaseSchema>.of(schemas);
}

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

    return _ContextMenuRegion(
      menuItems: [
        PopupMenuItem(
          value: connected ? 'activate' : 'connect',
          child: _MenuAction(connected ? 'Set active' : 'Connect'),
        ),
        const PopupMenuItem(
          value: 'edit',
          child: _MenuAction('Edit connection'),
        ),
        PopupMenuItem(
          value: 'invalidate',
          enabled: connected,
          child: const _MenuAction('Invalidate connection'),
        ),
        const PopupMenuItem(value: 'copy', child: _MenuAction('Copy name')),
        const PopupMenuItem(
          value: 'delete',
          child: _MenuAction('Delete connection'),
        ),
      ],
      onSelected: (value) {
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
      child: ExpansionTile(
        key: PageStorageKey('connection-${connection.config.endpointName}'),
        dense: true,
        initiallyExpanded: active,
        onExpansionChanged: (expanded) {
          if (expanded) {
            unawaited(onExpand());
          }
        },
        tilePadding: const EdgeInsets.only(left: 4, right: 8),
        leading: Icon(
          connected ? Icons.dns : Icons.storage_outlined,
          size: 16,
          color: active
              ? Colors.green.shade700
              : connection.connectionError == null
              ? Colors.blueGrey
              : Colors.red.shade700,
        ),
        title: InkWell(
          onTap: onActivate,
          child: _HoverTitle(
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    connection.config.displayName,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: active ? FontWeight.w600 : FontWeight.normal,
                    ),
                  ),
                ),
                if (connection.isConnecting)
                  const SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
              ],
            ),
          ),
        ),
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
      ),
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
  final Widget Function(DatabaseTable table) tableBuilder;

  const _SchemaTreeItem({
    required this.connectionKey,
    required this.schema,
    required this.isLoading,
    required this.onExpand,
    required this.onSelectSchema,
    required this.onRefresh,
    required this.onCopyName,
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
            unawaited(widget.onSelectSchema(widget.schema.name));
            break;
          case 'refresh':
            widget.onRefresh();
            break;
          case 'copy':
            widget.onCopyName(widget.schema.name);
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
        title: _HoverTitle(
          child: Text(widget.schema.name, style: const TextStyle(fontSize: 13)),
        ),
        children: [
          if (!widget.schema.tablesLoaded)
            Padding(
              padding: const EdgeInsets.only(left: 58, right: 8, bottom: 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: widget.isLoading
                    ? const Text(
                        'Loading tables...',
                        style: TextStyle(fontSize: 12, color: Colors.black54),
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
          for (final table in widget.schema.tables) widget.tableBuilder(table),
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
          child: _HoverTitle(
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
                      style: const TextStyle(
                        fontSize: 12,
                        color: Colors.black54,
                      ),
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
          _TableMetadataFolder(
            storageKey: 'constraints-$connectionKey-$schema-${table.name}',
            icon: Icons.key,
            title: 'Constraints',
            emptyText: 'No constraints found.',
            items: table.constraints,
            loaded: table.columnsLoaded,
            isLoading: isLoading,
            onLoad: () => onExpand(schema, table),
          ),
          _TableMetadataFolder(
            storageKey: 'indexes-$connectionKey-$schema-${table.name}',
            icon: Icons.format_list_numbered,
            title: 'Indexes',
            emptyText: 'No indexes found.',
            items: table.indexes,
            loaded: table.columnsLoaded,
            isLoading: isLoading,
            onLoad: () => onExpand(schema, table),
          ),
          _TableMetadataFolder(
            storageKey: 'foreign-keys-$connectionKey-$schema-${table.name}',
            icon: Icons.link,
            title: 'Foreign Keys',
            emptyText: 'No foreign keys found.',
            items: table.foreignKeys,
            loaded: table.columnsLoaded,
            isLoading: isLoading,
            onLoad: () => onExpand(schema, table),
          ),
          _TableMetadataFolder(
            storageKey: 'triggers-$connectionKey-$schema-${table.name}',
            icon: Icons.bolt,
            title: 'Triggers',
            emptyText: 'No triggers found.',
            items: table.triggers,
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
                style: const TextStyle(fontSize: 12, color: Colors.black54),
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
  final bool hasChanges;
  final bool canEdit;
  final VoidCallback onSaveChanges;
  final VoidCallback onCancelChanges;

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
    required this.onSaveChanges,
    required this.onCancelChanges,
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
            onPressed: hasChanges && !isExecuting ? onCancelChanges : null,
            icon: const Icon(Icons.undo, size: 18),
          ),
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
