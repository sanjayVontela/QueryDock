import 'package:bitsdojo_window/bitsdojo_window.dart';
import 'package:flutter/material.dart';
import 'package:pluto_grid/pluto_grid.dart';
import 'package:postgres/postgres.dart';

import '../../database/services/postgres_database.dart';

class AppTitleBar extends StatelessWidget {
  final String connectionName;
  final String status;
  final bool nativeWindowChrome;

  const AppTitleBar({
    super.key,
    required this.connectionName,
    required this.status,
    this.nativeWindowChrome = true,
  });

  @override
  Widget build(BuildContext context) {
    final connected = status.toLowerCase() == 'connected';

    final content = Container(
      height: 36,
      decoration: const BoxDecoration(
        color: Color(0xff242628),
        border: Border(bottom: BorderSide(color: Color(0xff111111))),
      ),
      child: Row(
        children: [
          const SizedBox(width: 12),
          Image.asset(
            'assets/branding/querydock_logo.png',
            width: 20,
            height: 20,
            filterQuality: FilterQuality.medium,
          ),
          const SizedBox(width: 8),
          const Text(
            'QueryDock',
            style: TextStyle(
              color: Colors.white,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(width: 14),
          Container(
            constraints: const BoxConstraints(maxWidth: 320),
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
            decoration: BoxDecoration(
              color: connected
                  ? const Color(0xff1f3a2c)
                  : const Color(0xff3a3020),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: connected
                    ? const Color(0xff3fb46f)
                    : const Color(0xffa87525),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  connected ? Icons.circle : Icons.circle_outlined,
                  size: 9,
                  color: connected
                      ? const Color(0xff77d697)
                      : const Color(0xffffc166),
                ),
                const SizedBox(width: 7),
                Flexible(
                  child: Text(
                    '$status - $connectionName',
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white, fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
          if (nativeWindowChrome) ...[
            Expanded(child: MoveWindow()),
            const WindowButtons(),
          ] else
            const Spacer(),
        ],
      ),
    );
    return nativeWindowChrome ? WindowTitleBarBox(child: content) : content;
  }
}

class DbMenuBar extends StatelessWidget {
  final VoidCallback onNewConnection;
  final VoidCallback onNewSql;
  final VoidCallback onSelectSql;
  final VoidCallback onSaveSql;
  final VoidCallback onCloseTab;
  final VoidCallback onExecuteSql;
  final VoidCallback onStopSql;
  final VoidCallback onRefreshSchemas;
  final VoidCallback onInvalidateConnection;
  final VoidCallback onToggleNavigator;
  final VoidCallback onToggleProperties;
  final VoidCallback onToggleAssistant;
  final VoidCallback onAiSettings;
  final VoidCallback onToggleOutput;
  final VoidCallback onToggleTheme;
  final VoidCallback onCopy;
  final VoidCallback onPaste;
  final VoidCallback onSelectAll;
  final VoidCallback onAbout;

  const DbMenuBar({
    super.key,
    required this.onNewConnection,
    required this.onNewSql,
    required this.onSelectSql,
    required this.onSaveSql,
    required this.onCloseTab,
    required this.onExecuteSql,
    required this.onStopSql,
    required this.onRefreshSchemas,
    required this.onInvalidateConnection,
    required this.onToggleNavigator,
    required this.onToggleProperties,
    required this.onToggleAssistant,
    required this.onAiSettings,
    required this.onToggleOutput,
    required this.onToggleTheme,
    required this.onCopy,
    required this.onPaste,
    required this.onSelectAll,
    required this.onAbout,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 32,
      color: Theme.of(context).colorScheme.surfaceContainer,
      child: Row(
        children: [
          const SizedBox(width: 12),
          _WorkbenchMenu(
            label: 'File',
            onSelected: _selectFile,
            items: const [
              PopupMenuItem(
                value: 'new-connection',
                child: _MenuCommand('New Connection'),
              ),
              PopupMenuDivider(),
              PopupMenuItem(value: 'new-sql', child: _MenuCommand('New SQL')),
              PopupMenuItem(
                value: 'open-sql',
                child: _MenuCommand('Open SQL...'),
              ),
              PopupMenuItem(value: 'save-sql', child: _MenuCommand('Save SQL')),
              PopupMenuDivider(),
              PopupMenuItem(
                value: 'close-tab',
                child: _MenuCommand('Close Tab'),
              ),
            ],
          ),
          _WorkbenchMenu(
            label: 'Edit',
            onSelected: _selectEdit,
            items: const [
              PopupMenuItem(value: 'copy', child: _MenuCommand('Copy')),
              PopupMenuItem(value: 'paste', child: _MenuCommand('Paste')),
              PopupMenuItem(
                value: 'select-all',
                child: _MenuCommand('Select All'),
              ),
            ],
          ),
          _WorkbenchMenu(
            label: 'Database',
            onSelected: _selectDatabase,
            items: const [
              PopupMenuItem(
                value: 'execute',
                child: _MenuCommand('Execute SQL'),
              ),
              PopupMenuItem(value: 'stop', child: _MenuCommand('Stop Query')),
              PopupMenuDivider(),
              PopupMenuItem(
                value: 'refresh',
                child: _MenuCommand('Refresh Schemas'),
              ),
              PopupMenuItem(
                value: 'invalidate',
                child: _MenuCommand('Invalidate Connection'),
              ),
            ],
          ),
          _WorkbenchMenu(
            label: 'Window',
            onSelected: _selectWindow,
            items: const [
              PopupMenuItem(
                value: 'navigator',
                child: _MenuCommand('Toggle Navigator'),
              ),
              PopupMenuItem(
                value: 'properties',
                child: _MenuCommand('Toggle Properties'),
              ),
              PopupMenuItem(
                value: 'assistant',
                child: _MenuCommand('AI Assistant'),
              ),
              PopupMenuItem(
                value: 'output',
                child: _MenuCommand('Toggle Output'),
              ),
              PopupMenuDivider(),
              PopupMenuItem(
                value: 'theme',
                child: _MenuCommand('Toggle Dark Mode'),
              ),
            ],
          ),
          _WorkbenchMenu(
            label: 'AI',
            onSelected: _selectAi,
            items: const [
              PopupMenuItem(
                value: 'assistant',
                child: _MenuCommand('Open Assistant'),
              ),
              PopupMenuItem(
                value: 'settings',
                child: _MenuCommand('Provider Settings...'),
              ),
            ],
          ),
          _WorkbenchMenu(
            label: 'Help',
            onSelected: _selectHelp,
            items: const [
              PopupMenuItem(
                value: 'about',
                child: _MenuCommand('About QueryDock'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _selectFile(String value) {
    switch (value) {
      case 'new-connection':
        onNewConnection();
        break;
      case 'new-sql':
        onNewSql();
        break;
      case 'open-sql':
        onSelectSql();
        break;
      case 'save-sql':
        onSaveSql();
        break;
      case 'close-tab':
        onCloseTab();
        break;
    }
  }

  void _selectEdit(String value) {
    switch (value) {
      case 'copy':
        onCopy();
        break;
      case 'paste':
        onPaste();
        break;
      case 'select-all':
        onSelectAll();
        break;
    }
  }

  void _selectDatabase(String value) {
    switch (value) {
      case 'execute':
        onExecuteSql();
        break;
      case 'stop':
        onStopSql();
        break;
      case 'refresh':
        onRefreshSchemas();
        break;
      case 'invalidate':
        onInvalidateConnection();
        break;
    }
  }

  void _selectWindow(String value) {
    switch (value) {
      case 'navigator':
        onToggleNavigator();
        break;
      case 'properties':
        onToggleProperties();
        break;
      case 'assistant':
        onToggleAssistant();
        break;
      case 'output':
        onToggleOutput();
        break;
      case 'theme':
        onToggleTheme();
        break;
    }
  }

  void _selectAi(String value) {
    switch (value) {
      case 'assistant':
        onToggleAssistant();
        break;
      case 'settings':
        onAiSettings();
        break;
    }
  }

  void _selectHelp(String value) {
    if (value == 'about') {
      onAbout();
    }
  }
}

class DbToolbar extends StatelessWidget {
  final bool isExecuting;
  final bool isConnecting;
  final VoidCallback onNewConnection;
  final VoidCallback onNewSql;
  final VoidCallback? onExecute;
  final VoidCallback onStop;
  final VoidCallback onToggleNavigator;
  final VoidCallback onToggleOutput;
  final VoidCallback onToggleAssistant;

  const DbToolbar({
    super.key,
    required this.isExecuting,
    required this.isConnecting,
    required this.onNewConnection,
    required this.onNewSql,
    required this.onExecute,
    required this.onStop,
    required this.onToggleNavigator,
    required this.onToggleOutput,
    required this.onToggleAssistant,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 42,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        border: Border(
          bottom: BorderSide(color: Theme.of(context).dividerColor),
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          ToolbarButton(
            icon: Icons.add,
            label: isConnecting ? 'Connecting...' : 'New Connection',
            tooltip: 'New Connection (Ctrl+Shift+N)',
            onTap: isConnecting ? null : onNewConnection,
          ),
          ToolbarButton(
            icon: Icons.note_add,
            label: 'New SQL',
            tooltip: 'New SQL File (Ctrl+N)',
            onTap: onNewSql,
          ),
          ToolbarButton(
            icon: Icons.play_arrow,
            label: isExecuting ? 'Running...' : 'Execute',
            tooltip: 'Execute SQL (Ctrl+Enter or F5)',
            onTap: onExecute,
          ),
          ToolbarButton(
            icon: Icons.stop,
            label: 'Stop',
            tooltip: 'Stop Query (Esc)',
            onTap: onStop,
          ),
          const Spacer(),
          ToolbarButton(
            icon: Icons.auto_awesome_outlined,
            label: 'AI',
            tooltip: 'Open AI Assistant',
            onTap: onToggleAssistant,
          ),
          ToolbarButton(
            icon: Icons.view_sidebar,
            label: 'Navigator',
            tooltip: 'Toggle Navigator',
            onTap: onToggleNavigator,
          ),
          ToolbarButton(
            icon: Icons.vertical_align_bottom,
            label: 'Output',
            tooltip: 'Toggle Output',
            onTap: onToggleOutput,
          ),
        ],
      ),
    );
  }
}

class PostgresConnectionDialog extends StatefulWidget {
  final List<PostgresConnectionConfig> savedConnections;
  final PostgresConnectionConfig? initialConfig;

  const PostgresConnectionDialog({
    super.key,
    this.savedConnections = const [],
    this.initialConfig,
  });

  @override
  State<PostgresConnectionDialog> createState() =>
      _PostgresConnectionDialogState();
}

class _PostgresConnectionDialogState extends State<PostgresConnectionDialog> {
  late final TextEditingController _hostController;
  late final TextEditingController _portController;
  late final TextEditingController _databaseController;
  late final TextEditingController _usernameController;
  late final TextEditingController _passwordController;
  late final TextEditingController _nameController;

  SslMode _sslMode = SslMode.disable;
  bool _writeProtected = false;
  String? _errorText;
  bool _canConnect = false;

  @override
  void initState() {
    super.initState();
    final initialConfig = widget.initialConfig;
    _nameController = TextEditingController(text: initialConfig?.name ?? '');
    _hostController = TextEditingController(
      text: initialConfig?.host ?? 'localhost',
    );
    _portController = TextEditingController(
      text: (initialConfig?.port ?? 5432).toString(),
    );
    _databaseController = TextEditingController(
      text: initialConfig?.database ?? 'postgres',
    );
    _usernameController = TextEditingController(
      text: initialConfig?.username ?? 'postgres',
    );
    _passwordController = TextEditingController(
      text: initialConfig?.password ?? '',
    );
    _sslMode = initialConfig?.sslMode ?? SslMode.disable;
    _writeProtected = initialConfig?.writeProtected ?? false;
    for (final controller in [
      _hostController,
      _portController,
      _databaseController,
      _usernameController,
      _passwordController,
      _nameController,
    ]) {
      controller.addListener(_validate);
    }
    _validate();
  }

  @override
  void dispose() {
    _hostController.dispose();
    _nameController.dispose();
    _portController.dispose();
    _databaseController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(
        widget.initialConfig == null
            ? 'PostgreSQL Connection'
            : 'Edit PostgreSQL Connection',
      ),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.savedConnections.isNotEmpty) ...[
                DropdownButtonFormField<PostgresConnectionConfig>(
                  decoration: const InputDecoration(
                    labelText: 'Recent connection',
                    prefixIcon: Icon(Icons.history),
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  items: [
                    for (final connection in widget.savedConnections)
                      DropdownMenuItem(
                        value: connection,
                        child: Text(
                          connection.name.trim().isEmpty
                              ? connection.displayName
                              : '${connection.displayName}  (${connection.endpointName})',
                        ),
                      ),
                  ],
                  onChanged: (connection) {
                    if (connection == null) return;
                    _hostController.text = connection.host;
                    _portController.text = connection.port.toString();
                    _databaseController.text = connection.database;
                    _usernameController.text = connection.username;
                    _passwordController.text = connection.password;
                    _nameController.text = connection.name;
                    _sslMode = connection.sslMode;
                    setState(() {});
                    _validate();
                  },
                ),
                const SizedBox(height: 10),
              ],
              ConnectionTextField(
                controller: _nameController,
                label: 'Connection name',
                icon: Icons.label_outline,
              ),
              const SizedBox(height: 10),
              ConnectionTextField(
                controller: _hostController,
                label: 'Host',
                icon: Icons.dns,
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: ConnectionTextField(
                      controller: _portController,
                      label: 'Port',
                      icon: Icons.tag,
                      keyboardType: TextInputType.number,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: DropdownButtonFormField<SslMode>(
                      initialValue: _sslMode,
                      decoration: const InputDecoration(
                        labelText: 'SSL',
                        prefixIcon: Icon(Icons.lock_outline),
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                      items: const [
                        DropdownMenuItem(
                          value: SslMode.disable,
                          child: Text('Disable'),
                        ),
                        DropdownMenuItem(
                          value: SslMode.require,
                          child: Text('Require'),
                        ),
                        DropdownMenuItem(
                          value: SslMode.verifyFull,
                          child: Text('Verify full'),
                        ),
                      ],
                      onChanged: (value) {
                        if (value == null) return;
                        _sslMode = value;
                      },
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              ConnectionTextField(
                controller: _databaseController,
                label: 'Database',
                icon: Icons.storage,
              ),
              const SizedBox(height: 10),
              ConnectionTextField(
                controller: _usernameController,
                label: 'Username',
                icon: Icons.person_outline,
              ),
              const SizedBox(height: 10),
              ConnectionTextField(
                controller: _passwordController,
                label: 'Password',
                icon: Icons.password,
                obscureText: true,
              ),
              const SizedBox(height: 4),
              CheckboxListTile(
                value: _writeProtected,
                onChanged: (value) {
                  setState(() {
                    _writeProtected = value ?? false;
                  });
                },
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                title: const Text(
                  'Protect this connection from data changes',
                  style: TextStyle(fontSize: 13),
                ),
                subtitle: const Text(
                  'INSERT, UPDATE, DELETE, DDL, and other writes require confirmation.',
                  style: TextStyle(fontSize: 12),
                ),
              ),
              if (_errorText != null) ...[
                const SizedBox(height: 10),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    _errorText!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton.icon(
          onPressed: _canConnect ? _submit : null,
          icon: const Icon(Icons.save),
          label: const Text('Save'),
        ),
      ],
    );
  }

  void _submit() {
    final host = _hostController.text.trim();
    final database = _databaseController.text.trim();
    final username = _usernameController.text.trim();
    final port = int.tryParse(_portController.text.trim());

    if (host.isEmpty || database.isEmpty || username.isEmpty || port == null) {
      setState(() {
        _errorText = 'Host, port, database, and username are required.';
      });
      return;
    }

    Navigator.pop(
      context,
      PostgresConnectionConfig(
        host: host,
        port: port,
        database: database,
        username: username,
        password: _passwordController.text,
        name: _nameController.text.trim(),
        sslMode: _sslMode,
        writeProtected: _writeProtected,
      ),
    );
  }

  void _validate() {
    final host = _hostController.text.trim();
    final database = _databaseController.text.trim();
    final username = _usernameController.text.trim();
    final port = int.tryParse(_portController.text.trim());
    final nextCanConnect =
        host.isNotEmpty &&
        database.isNotEmpty &&
        username.isNotEmpty &&
        port != null;

    if (_canConnect == nextCanConnect) {
      return;
    }

    setState(() {
      _canConnect = nextCanConnect;
      if (_canConnect) {
        _errorText = null;
      }
    });
  }
}

class ConnectionTextField extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final IconData icon;
  final bool obscureText;
  final TextInputType? keyboardType;

  const ConnectionTextField({
    super.key,
    required this.controller,
    required this.label,
    required this.icon,
    this.obscureText = false,
    this.keyboardType,
  });

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      obscureText: obscureText,
      keyboardType: keyboardType,
      decoration: InputDecoration(
        labelText: label,
        prefixIcon: Icon(icon),
        border: const OutlineInputBorder(),
        isDense: true,
      ),
    );
  }
}

class MenuItemLabel extends StatelessWidget {
  final String text;

  const MenuItemLabel(this.text, {super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 13,
          color: Theme.of(context).colorScheme.onSurface,
        ),
      ),
    );
  }
}

class _WorkbenchMenu extends StatelessWidget {
  final String label;
  final PopupMenuItemSelected<String> onSelected;
  final List<PopupMenuEntry<String>> items;

  const _WorkbenchMenu({
    required this.label,
    required this.onSelected,
    required this.items,
  });

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      tooltip: '',
      offset: const Offset(0, 28),
      onSelected: onSelected,
      itemBuilder: (context) => items,
      child: MenuItemLabel(label),
    );
  }
}

class _MenuCommand extends StatelessWidget {
  final String text;

  const _MenuCommand(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(text, style: const TextStyle(fontSize: 13));
  }
}

class ToolbarButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final String? tooltip;
  final VoidCallback? onTap;

  const ToolbarButton({
    super.key,
    required this.icon,
    required this.label,
    this.tooltip,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final button = TextButton.icon(
      onPressed: onTap,
      icon: Icon(icon, size: 18),
      label: Text(label),
      style: TextButton.styleFrom(
        foregroundColor: Theme.of(context).colorScheme.onSurface,
        padding: const EdgeInsets.symmetric(horizontal: 8),
      ),
    );

    if (tooltip == null) return button;
    return Tooltip(message: tooltip!, child: button);
  }
}

class PanelHeader extends StatelessWidget {
  final String title;
  final IconData icon;
  final VoidCallback? onClose;

  const PanelHeader({
    super.key,
    required this.title,
    required this.icon,
    this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 34,
      color: Theme.of(context).colorScheme.surfaceContainer,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          Icon(icon, size: 16, color: Theme.of(context).colorScheme.onSurface),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              title,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
          ),
          if (onClose != null)
            IconButton(
              onPressed: onClose,
              icon: const Icon(Icons.close, size: 16),
              padding: EdgeInsets.zero,
            ),
        ],
      ),
    );
  }
}

class EditorTab extends StatelessWidget {
  final String title;
  final bool active;
  final VoidCallback? onTap;
  final VoidCallback? onClose;

  const EditorTab({
    super.key,
    required this.title,
    required this.active,
    this.onTap,
    this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        height: 34,
        padding: const EdgeInsets.only(left: 14, right: 8),
        decoration: BoxDecoration(
          color: active
              ? Theme.of(context).colorScheme.surface
              : Theme.of(context).colorScheme.surfaceContainerHigh,
          border: Border(
            right: BorderSide(color: Theme.of(context).dividerColor),
          ),
        ),
        alignment: Alignment.center,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 160),
              child: Text(
                title,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13),
              ),
            ),
            if (onClose != null) ...[
              const SizedBox(width: 6),
              Tooltip(
                message: 'Close Tab (Ctrl+W)',
                child: InkWell(
                  onTap: onClose,
                  child: const Icon(Icons.close, size: 14),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class ResultTab extends StatelessWidget {
  final String title;
  final IconData? icon;
  final bool active;
  final VoidCallback? onTap;

  const ResultTab({
    super.key,
    required this.title,
    this.icon,
    required this.active,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        height: 32,
        margin: const EdgeInsets.symmetric(vertical: 5, horizontal: 2),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: active
              ? Theme.of(context).colorScheme.surface
              : Colors.transparent,
          border: Border.all(
            color: active ? Theme.of(context).dividerColor : Colors.transparent,
          ),
          borderRadius: BorderRadius.circular(4),
        ),
        alignment: Alignment.center,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(
                icon,
                size: 15,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 6),
            ],
            Text(
              title,
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

enum ResultGridRenderer { queryDock, pluto }

class ResultGrid extends StatefulWidget {
  final List<String> columns;
  final List<List<dynamic>> rows;
  final String? sortColumn;
  final bool sortAscending;
  final Future<void> Function(String column)? onSortColumn;
  final Future<void> Function(String column)? onFilterColumn;
  final Set<String> filteredColumns;
  final bool editable;
  final bool Function(int column)? columnEditable;
  final String Function(int row, int column)? cellValue;
  final void Function(int row, int column, String value)? onCellChanged;
  final bool Function(int row, int column)? cellEdited;
  final Future<void> Function()? onLoadMore;
  final bool hasMoreRows;
  final bool loadingMore;
  final ResultGridRenderer renderer;

  const ResultGrid({
    super.key,
    required this.columns,
    required this.rows,
    this.sortColumn,
    this.sortAscending = true,
    this.onSortColumn,
    this.onFilterColumn,
    this.filteredColumns = const {},
    this.editable = false,
    this.columnEditable,
    this.cellValue,
    this.onCellChanged,
    this.cellEdited,
    this.onLoadMore,
    this.hasMoreRows = false,
    this.loadingMore = false,
    this.renderer = ResultGridRenderer.queryDock,
  });

  @override
  State<ResultGrid> createState() => _ResultGridState();
}

class _ResultGridState extends State<ResultGrid> {
  static const _defaultColumnWidth = 150.0;
  static const _minimumColumnWidth = 80.0;
  static const _maximumColumnWidth = 600.0;
  final ScrollController _horizontalController = ScrollController();
  final ScrollController _verticalController = ScrollController();
  final Map<String, double> _columnWidths = {};
  bool _loadRequested = false;
  List<int> _currentVisibleColumns = const [];
  int? _editingRow;
  int? _editingColumn;

  @override
  void initState() {
    super.initState();
    _horizontalController.addListener(_handleHorizontalScroll);
    _verticalController.addListener(_handleVerticalScroll);
    _syncColumnWidths();
  }

  @override
  void didUpdateWidget(covariant ResultGrid oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncColumnWidths();
    if (oldWidget.columns.length != widget.columns.length ||
        !oldWidget.columns.indexed.every(
          (entry) => entry.$2 == widget.columns[entry.$1],
        )) {
      _currentVisibleColumns = const [];
    }
    if (!widget.loadingMore) _loadRequested = false;
  }

  @override
  void dispose() {
    _horizontalController
      ..removeListener(_handleHorizontalScroll)
      ..dispose();
    _verticalController
      ..removeListener(_handleVerticalScroll)
      ..dispose();
    super.dispose();
  }

  void _handleHorizontalScroll() {
    if (!mounted || !_horizontalController.hasClients) return;
    final viewportWidth = _horizontalController.position.viewportDimension;
    final next = _visibleColumns(_horizontalController.offset, viewportWidth);
    if (_sameIndexes(next, _currentVisibleColumns)) return;
    setState(() => _currentVisibleColumns = next);
  }

  void _handleVerticalScroll() {
    if (!_verticalController.hasClients ||
        _verticalController.position.extentAfter > 240 ||
        !widget.hasMoreRows ||
        widget.loadingMore ||
        _loadRequested ||
        widget.onLoadMore == null) {
      return;
    }
    _loadRequested = true;
    widget.onLoadMore!().whenComplete(() {
      if (mounted) _loadRequested = false;
    });
  }

  void _syncColumnWidths() {
    _columnWidths.removeWhere(
      (column, width) => !widget.columns.contains(column),
    );
    for (final column in widget.columns) {
      _columnWidths.putIfAbsent(column, () => _defaultColumnWidth);
    }
  }

  double _columnWidth(int index) =>
      _columnWidths[widget.columns[index]] ?? _defaultColumnWidth;

  double _columnLeft(int index) {
    var left = 0.0;
    for (var current = 0; current < index; current++) {
      left += _columnWidth(current);
    }
    return left;
  }

  double get _gridWidth {
    var width = 0.0;
    for (var index = 0; index < widget.columns.length; index++) {
      width += _columnWidth(index);
    }
    return width;
  }

  List<int> _visibleColumns(double offset, double viewportWidth) {
    final visible = <int>[];
    var left = 0.0;
    final start = (offset - _maximumColumnWidth).clamp(0.0, double.infinity);
    final end = offset + viewportWidth + _maximumColumnWidth;
    for (var index = 0; index < widget.columns.length; index++) {
      final right = left + _columnWidth(index);
      if (right >= start && left <= end) visible.add(index);
      if (left > end) break;
      left = right;
    }
    return visible;
  }

  bool _sameIndexes(List<int> left, List<int> right) {
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index++) {
      if (left[index] != right[index]) return false;
    }
    return true;
  }

  void _resizeColumn(int index, double delta) {
    final column = widget.columns[index];
    final width = (_columnWidth(index) + delta).clamp(
      _minimumColumnWidth,
      _maximumColumnWidth,
    );
    setState(() => _columnWidths[column] = width);
  }

  void _beginEditing(int row, int column) {
    if (!widget.editable || !(widget.columnEditable?.call(column) ?? true)) {
      return;
    }
    setState(() {
      _editingRow = row;
      _editingColumn = column;
    });
  }

  void _finishEditing() {
    if (_editingRow == null) return;
    setState(() {
      _editingRow = null;
      _editingColumn = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (widget.renderer == ResultGridRenderer.pluto) {
      return _PlutoResultGrid(result: widget);
    }

    if (widget.columns.isEmpty) {
      return Center(
        child: Text(
          'No results yet. Click New Connection, then Execute.',
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final gridWidth = _gridWidth
            .clamp(constraints.maxWidth, double.infinity)
            .toDouble();
        final offset = _horizontalController.hasClients
            ? _horizontalController.offset
            : 0.0;
        final calculatedColumns = _visibleColumns(offset, constraints.maxWidth);
        final visibleColumns = _currentVisibleColumns.isEmpty
            ? calculatedColumns
            : _currentVisibleColumns;
        if (_currentVisibleColumns.isEmpty) {
          _currentVisibleColumns = calculatedColumns;
        }

        return Scrollbar(
          controller: _horizontalController,
          scrollbarOrientation: ScrollbarOrientation.bottom,
          child: SingleChildScrollView(
            controller: _horizontalController,
            scrollDirection: Axis.horizontal,
            child: SizedBox(
              width: gridWidth,
              height: constraints.maxHeight,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Container(
                    height: 34,
                    color: Theme.of(context).colorScheme.surfaceContainerHigh,
                    child: Stack(
                      children: [
                        for (final columnIndex in visibleColumns)
                          Positioned(
                            left: _columnLeft(columnIndex),
                            width: _columnWidth(columnIndex),
                            top: 0,
                            bottom: 0,
                            child: Stack(
                              key: ValueKey(
                                'result-grid-header-${widget.columns[columnIndex]}',
                              ),
                              children: [
                                _FastGridCell(
                                  text: widget.columns[columnIndex],
                                  header: true,
                                  width: _columnWidth(columnIndex),
                                  sortable: widget.onSortColumn != null,
                                  filterable: widget.onFilterColumn != null,
                                  filtered: widget.filteredColumns.contains(
                                    widget.columns[columnIndex],
                                  ),
                                  sorted:
                                      widget.sortColumn ==
                                      widget.columns[columnIndex],
                                  sortAscending: widget.sortAscending,
                                  onSort: widget.onSortColumn == null
                                      ? null
                                      : () => widget.onSortColumn!(
                                          widget.columns[columnIndex],
                                        ),
                                  onFilter: widget.onFilterColumn == null
                                      ? null
                                      : () => widget.onFilterColumn!(
                                          widget.columns[columnIndex],
                                        ),
                                ),
                                Positioned(
                                  right: 0,
                                  top: 0,
                                  bottom: 0,
                                  width: 8,
                                  child: MouseRegion(
                                    key: ValueKey(
                                      'result-grid-resize-${widget.columns[columnIndex]}',
                                    ),
                                    cursor: SystemMouseCursors.resizeColumn,
                                    child: GestureDetector(
                                      behavior: HitTestBehavior.opaque,
                                      onHorizontalDragUpdate: (details) =>
                                          _resizeColumn(
                                            columnIndex,
                                            details.delta.dx,
                                          ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: ListView.builder(
                      key: const ValueKey('result-grid-rows'),
                      controller: _verticalController,
                      itemCount:
                          widget.rows.length + (widget.loadingMore ? 1 : 0),
                      itemExtent: 32,
                      itemBuilder: (context, rowIndex) {
                        if (rowIndex == widget.rows.length) {
                          return const Align(
                            alignment: Alignment.centerLeft,
                            child: SizedBox(
                              width: 180,
                              child: LinearProgressIndicator(minHeight: 2),
                            ),
                          );
                        }
                        final row = widget.rows[rowIndex];
                        return RepaintBoundary(
                          child: Stack(
                            children: [
                              for (final columnIndex in visibleColumns)
                                Positioned(
                                  left: _columnLeft(columnIndex),
                                  width: _columnWidth(columnIndex),
                                  top: 0,
                                  bottom: 0,
                                  child:
                                      _editingRow == rowIndex &&
                                          _editingColumn == columnIndex
                                      ? _EditableGridCell(
                                          key: ValueKey(
                                            '$rowIndex-$columnIndex',
                                          ),
                                          text:
                                              widget.cellValue?.call(
                                                rowIndex,
                                                columnIndex,
                                              ) ??
                                              (columnIndex < row.length
                                                  ? row[columnIndex]
                                                            ?.toString() ??
                                                        ''
                                                  : ''),
                                          width: _columnWidth(columnIndex),
                                          edited:
                                              widget.cellEdited?.call(
                                                rowIndex,
                                                columnIndex,
                                              ) ??
                                              false,
                                          onChanged: (value) =>
                                              widget.onCellChanged?.call(
                                                rowIndex,
                                                columnIndex,
                                                value,
                                              ),
                                          onDone: _finishEditing,
                                        )
                                      : _FastGridCell(
                                          text:
                                              widget.cellValue?.call(
                                                rowIndex,
                                                columnIndex,
                                              ) ??
                                              (columnIndex < row.length
                                                  ? row[columnIndex]
                                                            ?.toString() ??
                                                        'NULL'
                                                  : ''),
                                          width: _columnWidth(columnIndex),
                                          edited:
                                              widget.cellEdited?.call(
                                                rowIndex,
                                                columnIndex,
                                              ) ??
                                              false,
                                          onDoubleTap:
                                              widget.editable &&
                                                  (widget.columnEditable?.call(
                                                        columnIndex,
                                                      ) ??
                                                      true)
                                              ? () => _beginEditing(
                                                  rowIndex,
                                                  columnIndex,
                                                )
                                              : null,
                                        ),
                                ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _PlutoResultGrid extends StatefulWidget {
  final ResultGrid result;

  const _PlutoResultGrid({required this.result});

  @override
  State<_PlutoResultGrid> createState() => _PlutoResultGridState();
}

class _PlutoResultGridState extends State<_PlutoResultGrid> {
  PlutoGridStateManager? _stateManager;
  ScrollController? _verticalController;
  late List<PlutoColumn> _columns;
  late List<PlutoRow> _rows;
  late List<int> _sourceSignatures;
  bool _loadRequested = false;
  int _gridGeneration = 0;

  ResultGrid get result => widget.result;

  @override
  void initState() {
    super.initState();
    _rebuildModel();
  }

  @override
  void didUpdateWidget(covariant _PlutoResultGrid oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_sameColumns(oldWidget.result.columns, result.columns)) {
      _detachScrollController();
      _stateManager = null;
      _gridGeneration++;
      _rebuildModel();
      return;
    }
    if (!result.loadingMore) _loadRequested = false;
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncRows());
  }

  @override
  void dispose() {
    _detachScrollController();
    super.dispose();
  }

  bool _sameColumns(List<String> left, List<String> right) {
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index++) {
      if (left[index] != right[index]) return false;
    }
    return true;
  }

  void _rebuildModel() {
    _columns = _buildColumns();
    _rows = _buildRows();
    _sourceSignatures = _buildSourceSignatures();
  }

  List<PlutoColumn> _buildColumns() {
    return [
      for (var index = 0; index < result.columns.length; index++)
        PlutoColumn(
          title: result.columns[index],
          field: _field(index),
          type: PlutoColumnType.text(),
          width: 150,
          minWidth: 80,
          readOnly:
              !result.editable || !(result.columnEditable?.call(index) ?? true),
          enableEditingMode:
              result.editable && (result.columnEditable?.call(index) ?? true),
          enableSorting: result.onSortColumn != null,
          enableColumnDrag: true,
          enableDropToResize: true,
          enableContextMenu: true,
          enableFilterMenuItem: false,
          sort: result.sortColumn == result.columns[index]
              ? (result.sortAscending
                    ? PlutoColumnSort.ascending
                    : PlutoColumnSort.descending)
              : PlutoColumnSort.none,
          titleSpan: TextSpan(
            children: [
              TextSpan(text: result.columns[index]),
              if (result.onFilterColumn != null)
                WidgetSpan(
                  alignment: PlaceholderAlignment.middle,
                  child: Tooltip(
                    message: 'Filter ${result.columns[index]}',
                    child: InkResponse(
                      radius: 14,
                      onTap: () =>
                          result.onFilterColumn!(result.columns[index]),
                      child: Padding(
                        padding: const EdgeInsets.only(left: 5),
                        child: Icon(
                          result.filteredColumns.contains(result.columns[index])
                              ? Icons.filter_alt
                              : Icons.filter_alt_outlined,
                          size: 14,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
          renderer: (rendererContext) {
            final row = rendererContext.row.sortIdx;
            final edited = result.cellEdited?.call(row, index) ?? false;
            final value = rendererContext.cell.value?.toString() ?? 'NULL';
            return RepaintBoundary(
              child: Tooltip(
                message: value,
                waitDuration: const Duration(seconds: 2),
                child: Container(
                  color: edited
                      ? Theme.of(context).colorScheme.tertiaryContainer
                      : Colors.transparent,
                  alignment: Alignment.centerLeft,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Text(
                    value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontFamily: 'Consolas',
                      fontSize: 12,
                    ),
                  ),
                ),
              ),
            );
          },
        ),
    ];
  }

  List<PlutoRow> _buildRows({int start = 0}) {
    return [
      for (var row = start; row < result.rows.length; row++)
        PlutoRow(
          sortIdx: row,
          cells: {
            for (var column = 0; column < result.columns.length; column++)
              _field(column): PlutoCell(value: _cellValue(row, column)),
          },
        ),
    ];
  }

  String _cellValue(int row, int column) {
    final customValue = result.cellValue?.call(row, column);
    if (customValue != null) return customValue;
    final sourceRow = result.rows[row];
    if (column >= sourceRow.length) return '';
    return sourceRow[column]?.toString() ?? 'NULL';
  }

  String _field(int column) => 'querydock_column_$column';

  int _columnIndex(String field) {
    return int.tryParse(field.substring(field.lastIndexOf('_') + 1)) ?? 0;
  }

  List<int> _buildSourceSignatures() {
    return [for (final row in result.rows) Object.hashAll(row)];
  }

  void _onLoaded(PlutoGridOnLoadedEvent event) {
    _stateManager = event.stateManager;
    event.stateManager
      ..setSortOnlyEvent(true)
      ..setFilterOnlyEvent(true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _stateManager != event.stateManager) return;
      _attachScrollController(event.stateManager.scroll.bodyRowsVertical);
    });
  }

  void _attachScrollController(ScrollController? controller) {
    if (identical(_verticalController, controller)) return;
    _detachScrollController();
    _verticalController = controller;
    _verticalController?.addListener(_handleVerticalScroll);
  }

  void _detachScrollController() {
    _verticalController?.removeListener(_handleVerticalScroll);
    _verticalController = null;
  }

  void _handleVerticalScroll() {
    final controller = _verticalController;
    if (controller == null ||
        !controller.hasClients ||
        controller.position.extentAfter > 240 ||
        !result.hasMoreRows ||
        result.loadingMore ||
        _loadRequested ||
        result.onLoadMore == null) {
      return;
    }
    _loadRequested = true;
    result.onLoadMore!().whenComplete(() {
      if (mounted) _loadRequested = false;
    });
  }

  void _syncRows() {
    final manager = _stateManager;
    if (!mounted || manager == null) return;

    final nextSignatures = _buildSourceSignatures();
    final isAppend =
        nextSignatures.length >= _sourceSignatures.length &&
        _sourceSignatures.indexed.every(
          (entry) => nextSignatures[entry.$1] == entry.$2,
        );

    if (!isAppend) {
      manager.removeAllRows(notify: false);
      manager.appendRows(_buildRows());
    } else if (nextSignatures.length > _sourceSignatures.length) {
      manager.appendRows(_buildRows(start: _sourceSignatures.length));
    }

    var valuesChanged = false;
    final managedRows = manager.refRows.originalList;
    final rowCount = managedRows.length < result.rows.length
        ? managedRows.length
        : result.rows.length;
    for (var row = 0; row < rowCount; row++) {
      managedRows[row].sortIdx = row;
      for (var column = 0; column < result.columns.length; column++) {
        final cell = managedRows[row].cells[_field(column)];
        final value = _cellValue(row, column);
        if (cell != null && cell.value != value) {
          cell.value = value;
          valuesChanged = true;
        }
      }
    }
    if (valuesChanged) manager.notifyListeners();

    _sourceSignatures = nextSignatures;
  }

  PlutoGridConfiguration _configuration(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final divider = Theme.of(context).dividerColor;
    return PlutoGridConfiguration(
      enterKeyAction: PlutoGridEnterKeyAction.editingAndMoveDown,
      style: PlutoGridStyleConfig(
        enableGridBorderShadow: false,
        gridBackgroundColor: scheme.surface,
        rowColor: scheme.surface,
        oddRowColor: scheme.surface,
        evenRowColor: scheme.surfaceContainerLowest,
        activatedColor: scheme.primaryContainer,
        checkedColor: scheme.secondaryContainer,
        cellColorInEditState: scheme.surface,
        cellColorInReadOnlyState: scheme.surface,
        iconColor: scheme.onSurfaceVariant,
        disabledIconColor: scheme.onSurfaceVariant.withValues(alpha: 0.35),
        menuBackgroundColor: scheme.surfaceContainer,
        gridBorderColor: divider,
        borderColor: divider,
        activatedBorderColor: scheme.primary,
        inactivatedBorderColor: divider,
        rowHeight: 32,
        columnHeight: 34,
        columnTextStyle: TextStyle(
          color: scheme.onSurface,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
        cellTextStyle: TextStyle(
          color: scheme.onSurface,
          fontFamily: 'Consolas',
          fontSize: 12,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (result.columns.isEmpty) {
      return Center(
        child: Text(
          'No results yet. Click New Connection, then Execute.',
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }

    return Stack(
      children: [
        PlutoGrid(
          key: ValueKey('pluto-result-grid-$_gridGeneration'),
          columns: _columns,
          rows: _rows,
          onLoaded: _onLoaded,
          onChanged: (event) {
            final row = event.row.sortIdx;
            final column = _columnIndex(event.column.field);
            result.onCellChanged?.call(
              row,
              column,
              event.value?.toString() ?? '',
            );
          },
          onSorted: (event) {
            result.onSortColumn?.call(event.column.title);
          },
          noRowsWidget: Center(
            child: Text(
              'No rows',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          configuration: _configuration(context),
        ),
        if (result.loadingMore)
          const Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: LinearProgressIndicator(minHeight: 2),
          ),
      ],
    );
  }
}

class _EditableGridCell extends StatefulWidget {
  final String text;
  final double width;
  final bool edited;
  final ValueChanged<String> onChanged;
  final VoidCallback onDone;

  const _EditableGridCell({
    super.key,
    required this.text,
    required this.width,
    required this.edited,
    required this.onChanged,
    required this.onDone,
  });

  @override
  State<_EditableGridCell> createState() => _EditableGridCellState();
}

class _EditableGridCellState extends State<_EditableGridCell> {
  late final TextEditingController _controller;
  late final FocusNode _focusNode;
  bool _committed = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.text);
    _focusNode = FocusNode()..addListener(_handleFocus);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });
  }

  @override
  void didUpdateWidget(covariant _EditableGridCell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.text != _controller.text && !widget.edited) {
      _controller.text = widget.text;
    }
  }

  @override
  void dispose() {
    _focusNode
      ..removeListener(_handleFocus)
      ..dispose();
    _controller.dispose();
    super.dispose();
  }

  void _handleFocus() {
    if (!_focusNode.hasFocus) _commit();
  }

  void _commit() {
    if (_committed) return;
    _committed = true;
    widget.onChanged(_controller.text);
    widget.onDone();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: widget.width,
      height: 32,
      decoration: BoxDecoration(
        color: widget.edited
            ? Theme.of(context).colorScheme.tertiaryContainer
            : Theme.of(context).colorScheme.surface,
        border: Border(
          right: BorderSide(color: Theme.of(context).dividerColor),
          bottom: BorderSide(color: Theme.of(context).dividerColor),
        ),
      ),
      child: TextField(
        controller: _controller,
        focusNode: _focusNode,
        onSubmitted: (_) => _commit(),
        style: const TextStyle(fontFamily: 'Consolas', fontSize: 12),
        decoration: const InputDecoration(
          border: InputBorder.none,
          contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          isDense: true,
        ),
      ),
    );
  }
}

class _FastGridCell extends StatelessWidget {
  final String text;
  final bool header;
  final double width;
  final bool sortable;
  final bool filterable;
  final bool filtered;
  final bool sorted;
  final bool sortAscending;
  final VoidCallback? onSort;
  final VoidCallback? onFilter;
  final VoidCallback? onDoubleTap;
  final bool edited;

  const _FastGridCell({
    required this.text,
    this.header = false,
    required this.width,
    this.sortable = false,
    this.filterable = false,
    this.filtered = false,
    this.sorted = false,
    this.sortAscending = true,
    this.onSort,
    this.onFilter,
    this.onDoubleTap,
    this.edited = false,
  });

  @override
  Widget build(BuildContext context) {
    final cell = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onDoubleTap: onDoubleTap,
      child: Container(
        width: width,
        height: header ? 34 : 32,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        alignment: Alignment.centerLeft,
        decoration: BoxDecoration(
          color: edited
              ? Theme.of(context).colorScheme.tertiaryContainer
              : null,
          border: Border(
            right: BorderSide(color: Theme.of(context).dividerColor),
            bottom: BorderSide(color: Theme.of(context).dividerColor),
          ),
        ),
        child: header && (sortable || filterable)
            ? Row(
                children: [
                  Expanded(
                    child: Text(
                      text,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontFamily: 'Consolas',
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  SizedBox(
                    width: 24,
                    height: 26,
                    child: IconButton(
                      tooltip: sorted
                          ? 'Sort ${sortAscending ? 'descending' : 'ascending'}'
                          : 'Sort ascending',
                      padding: EdgeInsets.zero,
                      visualDensity: VisualDensity.compact,
                      onPressed: onSort,
                      icon: Icon(
                        sorted
                            ? sortAscending
                                  ? Icons.arrow_upward
                                  : Icons.arrow_downward
                            : Icons.unfold_more,
                        size: 15,
                      ),
                    ),
                  ),
                  if (filterable)
                    SizedBox(
                      width: 24,
                      height: 26,
                      child: IconButton(
                        tooltip: filtered ? 'Edit filter' : 'Filter column',
                        padding: EdgeInsets.zero,
                        visualDensity: VisualDensity.compact,
                        onPressed: onFilter,
                        icon: Icon(
                          filtered
                              ? Icons.filter_alt
                              : Icons.filter_alt_outlined,
                          size: 15,
                          color: filtered ? const Color(0xff1473a8) : null,
                        ),
                      ),
                    ),
                ],
              )
            : Text(
                text,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontFamily: 'Consolas',
                  fontSize: 12,
                  fontWeight: header ? FontWeight.bold : FontWeight.normal,
                ),
              ),
      ),
    );
    if (header) return cell;
    return Tooltip(
      message: text,
      waitDuration: const Duration(seconds: 2),
      child: cell,
    );
  }
}

class MessagesView extends StatelessWidget {
  final List<String> logs;

  const MessagesView({super.key, required this.logs});

  @override
  Widget build(BuildContext context) {
    if (logs.isEmpty) {
      return Center(
        child: Text(
          'No messages.',
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 6),
      itemCount: logs.length,
      separatorBuilder: (context, index) =>
          const Divider(height: 1, indent: 42),
      itemBuilder: (context, index) {
        final log = logs[index];
        final isError = log.contains('[ERROR]');
        final isWarning = log.contains('[WARN]');

        return Container(
          constraints: const BoxConstraints(minHeight: 38),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                isError
                    ? Icons.error_outline
                    : isWarning
                    ? Icons.warning_amber
                    : Icons.info_outline,
                size: 17,
                color: isError
                    ? const Color(0xffc43d3d)
                    : isWarning
                    ? const Color(0xffb36b00)
                    : const Color(0xff3b718f),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: SelectableText(
                  log,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurface,
                    fontFamily: 'Consolas',
                    fontSize: 12,
                    height: 1.35,
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

class PropertyRow extends StatelessWidget {
  final String name;
  final String value;

  const PropertyRow({super.key, required this.name, required this.value});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 32,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: Theme.of(context).dividerColor),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              name,
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Text(value, style: const TextStyle(fontSize: 12)),
        ],
      ),
    );
  }
}

class BottomHeader extends StatelessWidget {
  final VoidCallback? onClose;

  const BottomHeader({super.key, this.onClose});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 30,
      color: const Color(0xff2b2b2b),
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: Row(
        children: [
          const Text(
            'Output',
            style: TextStyle(color: Colors.white70, fontSize: 13),
          ),
          const Spacer(),
          if (onClose != null)
            IconButton(
              onPressed: onClose,
              icon: const Icon(Icons.close, size: 16, color: Colors.white70),
              padding: EdgeInsets.zero,
            ),
        ],
      ),
    );
  }
}

class WindowButtons extends StatelessWidget {
  const WindowButtons({super.key});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        MinimizeWindowButton(),
        MaximizeWindowButton(),
        CloseWindowButton(),
      ],
    );
  }
}

class TreeItem extends StatelessWidget {
  final IconData icon;
  final String title;
  final int level;
  final bool expanded;
  final bool showArrow;
  final VoidCallback? onTap;

  const TreeItem({
    super.key,
    required this.icon,
    required this.title,
    required this.level,
    this.expanded = false,
    this.showArrow = true,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        height: 28,
        padding: EdgeInsets.only(left: 8.0 + level * 18),
        child: Row(
          children: [
            if (showArrow)
              Icon(
                expanded
                    ? Icons.keyboard_arrow_down
                    : Icons.keyboard_arrow_right,
                size: 16,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              )
            else
              const SizedBox(width: 16),
            Icon(icon, size: 16, color: Colors.blueGrey),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                title,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
