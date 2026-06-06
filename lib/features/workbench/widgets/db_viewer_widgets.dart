import 'package:bitsdojo_window/bitsdojo_window.dart';
import 'package:flutter/material.dart';
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
          const Icon(Icons.storage, color: Color(0xff8ab4f8), size: 18),
          const SizedBox(width: 8),
          const Text(
            'DB Viewer',
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
  final VoidCallback onToggleOutput;
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
    required this.onToggleOutput,
    required this.onCopy,
    required this.onPaste,
    required this.onSelectAll,
    required this.onAbout,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 32,
      color: const Color(0xffeeeeee),
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
                value: 'output',
                child: _MenuCommand('Toggle Output'),
              ),
            ],
          ),
          _WorkbenchMenu(
            label: 'Help',
            onSelected: _selectHelp,
            items: const [
              PopupMenuItem(
                value: 'about',
                child: _MenuCommand('About DB Viewer'),
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
      case 'output':
        onToggleOutput();
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
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 42,
      decoration: const BoxDecoration(
        color: Color(0xfff8f8f8),
        border: Border(bottom: BorderSide(color: Color(0xffd2d2d2))),
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
        style: const TextStyle(fontSize: 13, color: Colors.black87),
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
      tooltip: label,
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
        foregroundColor: Colors.black87,
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
      color: const Color(0xffe5e5e5),
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          Icon(icon, size: 16, color: Colors.black87),
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
          color: active ? Colors.white : const Color(0xffdddddd),
          border: const Border(right: BorderSide(color: Color(0xffcccccc))),
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
          color: active ? Colors.white : Colors.transparent,
          border: Border.all(
            color: active ? const Color(0xffb9c8d1) : Colors.transparent,
          ),
          borderRadius: BorderRadius.circular(4),
        ),
        alignment: Alignment.center,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 15, color: const Color(0xff45616f)),
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

class ResultGrid extends StatelessWidget {
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
  });

  @override
  Widget build(BuildContext context) {
    if (columns.isEmpty) {
      return const Center(
        child: Text(
          'No results yet. Click New Connection, then Execute.',
          style: TextStyle(color: Colors.black54),
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final gridWidth = (columns.length * 150)
            .clamp(constraints.maxWidth, double.infinity)
            .toDouble();

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              height: 34,
              color: const Color(0xffeeeeee),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: SizedBox(
                  width: gridWidth,
                  child: Row(
                    children: [
                      for (final column in columns)
                        _FastGridCell(
                          text: column,
                          header: true,
                          width: 150,
                          sortable: onSortColumn != null,
                          filterable: onFilterColumn != null,
                          filtered: filteredColumns.contains(column),
                          sorted: sortColumn == column,
                          sortAscending: sortAscending,
                          onSort: onSortColumn == null
                              ? null
                              : () => onSortColumn!(column),
                          onFilter: onFilterColumn == null
                              ? null
                              : () => onFilterColumn!(column),
                        ),
                    ],
                  ),
                ),
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: SizedBox(
                  width: gridWidth,
                  child: ListView.builder(
                    itemCount: rows.length,
                    itemExtent: 32,
                    itemBuilder: (context, rowIndex) {
                      final row = rows[rowIndex];

                      return Row(
                        children: [
                          for (int i = 0; i < columns.length; i++)
                            editable && (columnEditable?.call(i) ?? true)
                                ? _EditableGridCell(
                                    key: ValueKey('$rowIndex-$i'),
                                    text:
                                        cellValue?.call(rowIndex, i) ??
                                        (i < row.length
                                            ? row[i]?.toString() ?? ''
                                            : ''),
                                    width: 150,
                                    edited:
                                        cellEdited?.call(rowIndex, i) ?? false,
                                    onChanged: (value) =>
                                        onCellChanged?.call(rowIndex, i, value),
                                  )
                                : _FastGridCell(
                                    text: i < row.length
                                        ? row[i]?.toString() ?? 'NULL'
                                        : '',
                                    width: 150,
                                  ),
                        ],
                      );
                    },
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

class _EditableGridCell extends StatefulWidget {
  final String text;
  final double width;
  final bool edited;
  final ValueChanged<String> onChanged;

  const _EditableGridCell({
    super.key,
    required this.text,
    required this.width,
    required this.edited,
    required this.onChanged,
  });

  @override
  State<_EditableGridCell> createState() => _EditableGridCellState();
}

class _EditableGridCellState extends State<_EditableGridCell> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.text);
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
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: widget.width,
      height: 32,
      decoration: BoxDecoration(
        color: widget.edited ? const Color(0xfffff5cc) : Colors.white,
        border: const Border(
          right: BorderSide(color: Color(0xffd0d0d0)),
          bottom: BorderSide(color: Color(0xffd0d0d0)),
        ),
      ),
      child: TextField(
        controller: _controller,
        onChanged: widget.onChanged,
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
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: header ? 34 : 32,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      alignment: Alignment.centerLeft,
      decoration: const BoxDecoration(
        border: Border(
          right: BorderSide(color: Color(0xffd0d0d0)),
          bottom: BorderSide(color: Color(0xffd0d0d0)),
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
                        filtered ? Icons.filter_alt : Icons.filter_alt_outlined,
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
    );
  }
}

class MessagesView extends StatelessWidget {
  final List<String> logs;

  const MessagesView({super.key, required this.logs});

  @override
  Widget build(BuildContext context) {
    if (logs.isEmpty) {
      return const Center(
        child: Text('No messages.', style: TextStyle(color: Colors.black54)),
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
                  style: const TextStyle(
                    color: Colors.black87,
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
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: Color(0xffe0e0e0))),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              name,
              style: const TextStyle(fontSize: 12, color: Colors.black54),
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
                color: Colors.black54,
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
