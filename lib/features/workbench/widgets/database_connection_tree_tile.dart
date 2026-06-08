import 'dart:async';

import 'package:flutter/material.dart';

class DatabaseConnectionTreeTile extends StatelessWidget {
  final String storageKey;
  final String name;
  final bool connected;
  final bool active;
  final bool connecting;
  final String? error;
  final List<String> tags;
  final Future<void> Function() onExpand;
  final VoidCallback onActivate;
  final List<PopupMenuEntry<String>> menuItems;
  final ValueChanged<String> onMenuSelected;
  final List<Widget> children;

  const DatabaseConnectionTreeTile({
    super.key,
    required this.storageKey,
    required this.name,
    required this.connected,
    required this.active,
    required this.connecting,
    required this.error,
    required this.tags,
    required this.onExpand,
    required this.onActivate,
    required this.menuItems,
    required this.onMenuSelected,
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
    return DatabaseContextMenuRegion(
      menuItems: menuItems,
      onSelected: onMenuSelected,
      child: ExpansionTile(
        key: PageStorageKey(storageKey),
        dense: true,
        initiallyExpanded: active,
        shape: const Border(),
        collapsedShape: const Border(),
        tilePadding: const EdgeInsets.only(left: 4, right: 8),
        onExpansionChanged: (expanded) {
          if (expanded) unawaited(onExpand());
        },
        leading: Icon(
          connected ? Icons.dns : Icons.storage_outlined,
          size: 16,
          color: connected
              ? Colors.green.shade700
              : error == null
              ? Colors.blueGrey
              : Colors.red.shade700,
        ),
        title: InkWell(
          onTap: onActivate,
          child: DatabaseHoverTitle(
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    name,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      color: active
                          ? Theme.of(context).colorScheme.primary
                          : null,
                      fontWeight: active ? FontWeight.w600 : FontWeight.normal,
                    ),
                  ),
                ),
                if (connecting)
                  const SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
              ],
            ),
          ),
        ),
        subtitle: tags.isEmpty
            ? null
            : Text(
                tags.join(' | '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 10),
              ),
        children: children,
      ),
    );
  }
}

class DatabaseMenuAction extends StatelessWidget {
  final String label;

  const DatabaseMenuAction(this.label, {super.key});

  @override
  Widget build(BuildContext context) {
    return Text(label, style: const TextStyle(fontSize: 13));
  }
}

class DatabaseHoverTitle extends StatefulWidget {
  final Widget child;

  const DatabaseHoverTitle({super.key, required this.child});

  @override
  State<DatabaseHoverTitle> createState() => _DatabaseHoverTitleState();
}

class _DatabaseHoverTitleState extends State<DatabaseHoverTitle> {
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
          color: _hovering
              ? Theme.of(context).colorScheme.primaryContainer
              : Colors.transparent,
          borderRadius: BorderRadius.circular(4),
        ),
        child: widget.child,
      ),
    );
  }
}

class DatabaseContextMenuRegion extends StatelessWidget {
  final Widget child;
  final List<PopupMenuEntry<String>> menuItems;
  final ValueChanged<String> onSelected;

  const DatabaseContextMenuRegion({
    super.key,
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
        if (value != null) onSelected(value);
      },
      child: child,
    );
  }
}
