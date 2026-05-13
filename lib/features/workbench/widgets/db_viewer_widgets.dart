import 'package:bitsdojo_window/bitsdojo_window.dart';
import 'package:flutter/material.dart';
import 'package:postgres/postgres.dart';

import '../../database/services/postgres_database.dart';

class AppTitleBar extends StatelessWidget {
  final String connectionName;
  final String status;

  const AppTitleBar({
    super.key,
    required this.connectionName,
    required this.status,
  });

  @override
  Widget build(BuildContext context) {
    final connected = status.toLowerCase() == 'connected';

    return WindowTitleBarBox(
      child: Container(
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
            Expanded(child: MoveWindow()),
            const WindowButtons(),
          ],
        ),
      ),
    );
  }
}

class DbMenuBar extends StatelessWidget {
  const DbMenuBar({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 32,
      color: const Color(0xffeeeeee),
      child: const Row(
        children: [
          SizedBox(width: 12),
          MenuItemLabel('File'),
          MenuItemLabel('Edit'),
          MenuItemLabel('Database'),
          MenuItemLabel('SQL Editor'),
          MenuItemLabel('Window'),
          MenuItemLabel('Help'),
        ],
      ),
    );
  }
}

class DbToolbar extends StatelessWidget {
  final bool isExecuting;
  final bool isConnecting;
  final VoidCallback onNewConnection;
  final VoidCallback onNewSql;
  final VoidCallback? onExecute;
  final VoidCallback onStop;
  final VoidCallback onSave;
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
    required this.onSave,
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
          ToolbarButton(
            icon: Icons.save,
            label: 'Save',
            tooltip: 'Save SQL File (Ctrl+S)',
            onTap: onSave,
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

  const PostgresConnectionDialog({super.key, this.savedConnections = const []});

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

  SslMode _sslMode = SslMode.disable;
  String? _errorText;
  bool _canConnect = false;

  @override
  void initState() {
    super.initState();
    _hostController = TextEditingController(text: 'localhost');
    _portController = TextEditingController(text: '5432');
    _databaseController = TextEditingController(text: 'postgres');
    _usernameController = TextEditingController(text: 'postgres');
    _passwordController = TextEditingController();
    for (final controller in [
      _hostController,
      _portController,
      _databaseController,
      _usernameController,
      _passwordController,
    ]) {
      controller.addListener(_validate);
    }
    _validate();
  }

  @override
  void dispose() {
    _hostController.dispose();
    _portController.dispose();
    _databaseController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('PostgreSQL Connection'),
      content: SizedBox(
        width: 440,
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
                      child: Text(connection.displayName),
                    ),
                ],
                onChanged: (connection) {
                  if (connection == null) return;
                  _hostController.text = connection.host;
                  _portController.text = connection.port.toString();
                  _databaseController.text = connection.database;
                  _usernameController.text = connection.username;
                  _sslMode = connection.sslMode;
                  setState(() {});
                  _validate();
                },
              ),
              const SizedBox(height: 10),
            ],
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
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton.icon(
          onPressed: _canConnect ? _submit : null,
          icon: const Icon(Icons.link),
          label: const Text('Connect'),
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
        sslMode: _sslMode,
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
  final bool active;
  final VoidCallback? onTap;

  const ResultTab({
    super.key,
    required this.title,
    required this.active,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        height: 30,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          color: active ? Colors.white : const Color(0xffefefef),
          border: const Border(right: BorderSide(color: Color(0xffcccccc))),
        ),
        alignment: Alignment.center,
        child: Text(
          title,
          style: TextStyle(
            fontSize: 12,
            fontWeight: active ? FontWeight.w600 : FontWeight.normal,
          ),
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

  const ResultGrid({
    super.key,
    required this.columns,
    required this.rows,
    this.sortColumn,
    this.sortAscending = true,
    this.onSortColumn,
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
                          sorted: sortColumn == column,
                          sortAscending: sortAscending,
                          onSort: onSortColumn == null
                              ? null
                              : () => onSortColumn!(column),
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
                            _FastGridCell(
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

class _FastGridCell extends StatelessWidget {
  final String text;
  final bool header;
  final double width;
  final bool sortable;
  final bool sorted;
  final bool sortAscending;
  final VoidCallback? onSort;

  const _FastGridCell({
    required this.text,
    this.header = false,
    required this.width,
    this.sortable = false,
    this.sorted = false,
    this.sortAscending = true,
    this.onSort,
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
      child: header && sortable
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
                  width: 26,
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

    return ListView.builder(
      padding: const EdgeInsets.all(10),
      itemCount: logs.length,
      itemBuilder: (context, index) {
        final log = logs[index];

        return Text(
          log,
          style: TextStyle(
            color: log.contains('[ERROR]')
                ? Colors.red
                : log.contains('[WARN]')
                ? Colors.orange
                : Colors.black87,
            fontFamily: 'Consolas',
            fontSize: 13,
          ),
        );
      },
    );
  }
}

class ExecutionPlanView extends StatelessWidget {
  const ExecutionPlanView({super.key});

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.all(12),
      child: SelectableText(
        '''Mock Execution Plan

1. Parse SQL
2. Validate table metadata
3. Apply row limit
4. Execute query
5. Render result grid

Real execution plan will come from database later.''',
        style: TextStyle(fontFamily: 'Consolas', fontSize: 13, height: 1.5),
      ),
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
