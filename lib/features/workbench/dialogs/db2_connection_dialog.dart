import 'package:flutter/material.dart';

import '../../database/services/db2_database.dart';
import '../widgets/db_viewer_widgets.dart';

class Db2ConnectionDialog extends StatefulWidget {
  final Db2ConnectionConfig? initial;

  const Db2ConnectionDialog({super.key, this.initial});

  @override
  State<Db2ConnectionDialog> createState() => _Db2ConnectionDialogState();
}

class _Db2ConnectionDialogState extends State<Db2ConnectionDialog> {
  late final TextEditingController _name;
  late final TextEditingController _host;
  late final TextEditingController _port;
  late final TextEditingController _database;
  late final TextEditingController _username;
  late final TextEditingController _password;
  late final TextEditingController _backendUrl;
  late final TextEditingController _folder;
  late final TextEditingController _tags;
  late bool _writeProtected;

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    _name = TextEditingController(text: initial?.name ?? '');
    _host = TextEditingController(text: initial?.host ?? 'localhost');
    _port = TextEditingController(text: '${initial?.port ?? 50000}');
    _database = TextEditingController(text: initial?.database ?? '');
    _username = TextEditingController(text: initial?.username ?? 'db2inst1');
    _password = TextEditingController(text: initial?.password ?? '');
    _backendUrl = TextEditingController(
      text: initial?.backendUrl ?? 'http://127.0.0.1:8792',
    );
    _folder = TextEditingController(text: initial?.folder ?? '');
    _tags = TextEditingController(text: initial?.tags.join(', ') ?? '');
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
      _backendUrl,
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
        widget.initial == null ? 'DB2 Connection' : 'Edit DB2 Connection',
      ),
      content: SizedBox(
        width: 460,
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
              const SizedBox(height: 10),
              ConnectionTextField(
                controller: _backendUrl,
                label: 'Go backend URL',
                icon: Icons.api_outlined,
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
    final backend = Uri.tryParse(_backendUrl.text.trim());
    if (_host.text.trim().isEmpty ||
        port == null ||
        _database.text.trim().isEmpty ||
        _username.text.trim().isEmpty ||
        backend == null ||
        !backend.hasScheme) {
      return;
    }
    Navigator.pop(
      context,
      Db2ConnectionConfig(
        name: _name.text.trim(),
        host: _host.text.trim(),
        port: port,
        database: _database.text.trim(),
        username: _username.text.trim(),
        password: _password.text,
        backendUrl: backend.toString(),
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
