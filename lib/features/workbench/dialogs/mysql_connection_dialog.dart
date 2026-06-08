import 'package:flutter/material.dart';

import '../../database/services/mysql_database.dart';
import '../widgets/db_viewer_widgets.dart';

class MySqlConnectionDialog extends StatefulWidget {
  final MySqlConnectionConfig? initial;

  const MySqlConnectionDialog({super.key, this.initial});

  @override
  State<MySqlConnectionDialog> createState() => _MySqlConnectionDialogState();
}

class _MySqlConnectionDialogState extends State<MySqlConnectionDialog> {
  late final TextEditingController _name;
  late final TextEditingController _host;
  late final TextEditingController _port;
  late final TextEditingController _database;
  late final TextEditingController _username;
  late final TextEditingController _password;
  late final TextEditingController _folder;
  late final TextEditingController _tags;
  late bool _secure;
  late bool _writeProtected;

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    _name = TextEditingController(text: initial?.name ?? '');
    _host = TextEditingController(text: initial?.host ?? 'localhost');
    _port = TextEditingController(text: '${initial?.port ?? 3306}');
    _database = TextEditingController(text: initial?.database ?? '');
    _username = TextEditingController(text: initial?.username ?? 'root');
    _password = TextEditingController(text: initial?.password ?? '');
    _folder = TextEditingController(text: initial?.folder ?? '');
    _tags = TextEditingController(text: initial?.tags.join(', ') ?? '');
    _secure = initial?.secure ?? true;
    _writeProtected = initial?.writeProtected ?? false;
  }

  @override
  void dispose() {
    for (final controller in [
      _name,
      _host,
      _port,
      _database,
      _username,
      _password,
      _folder,
      _tags,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(
        widget.initial == null ? 'MySQL Connection' : 'Edit MySQL Connection',
      ),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ConnectionTextField(
                controller: _name,
                label: 'Connection name',
                icon: Icons.label_outline,
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: ConnectionTextField(
                      controller: _folder,
                      label: 'Folder',
                      icon: Icons.folder_outlined,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: ConnectionTextField(
                      controller: _tags,
                      label: 'Tags',
                      icon: Icons.sell_outlined,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: ConnectionTextField(
                      controller: _host,
                      label: 'Host',
                      icon: Icons.dns_outlined,
                    ),
                  ),
                  const SizedBox(width: 10),
                  SizedBox(
                    width: 120,
                    child: ConnectionTextField(
                      controller: _port,
                      label: 'Port',
                      icon: Icons.tag,
                      keyboardType: TextInputType.number,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              ConnectionTextField(
                controller: _database,
                label: 'Database',
                icon: Icons.storage_outlined,
              ),
              const SizedBox(height: 10),
              ConnectionTextField(
                controller: _username,
                label: 'Username',
                icon: Icons.person_outline,
              ),
              const SizedBox(height: 10),
              ConnectionTextField(
                controller: _password,
                label: 'Password',
                icon: Icons.password,
                obscureText: true,
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _secure,
                onChanged: (value) => setState(() => _secure = value),
                title: const Text('Use TLS'),
                subtitle: const Text(
                  'Disable only for a trusted local development server.',
                ),
              ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: _writeProtected,
                onChanged: (value) =>
                    setState(() => _writeProtected = value ?? false),
                title: const Text('Protect from updates'),
                subtitle: const Text(
                  'Ask for confirmation before changing data or schema.',
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Save')),
      ],
    );
  }

  void _submit() {
    final port = int.tryParse(_port.text.trim());
    if (_host.text.trim().isEmpty ||
        port == null ||
        _database.text.trim().isEmpty ||
        _username.text.trim().isEmpty) {
      return;
    }
    Navigator.pop(
      context,
      MySqlConnectionConfig(
        name: _name.text.trim(),
        host: _host.text.trim(),
        port: port,
        database: _database.text.trim(),
        username: _username.text.trim(),
        password: _password.text,
        secure: _secure,
        writeProtected: _writeProtected,
        folder: _folder.text.trim(),
        tags: _tags.text
            .split(',')
            .map((tag) => tag.trim())
            .where((tag) => tag.isNotEmpty)
            .toSet()
            .toList(),
      ),
    );
  }
}
