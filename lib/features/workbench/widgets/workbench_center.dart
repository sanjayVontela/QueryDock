import 'package:flutter/material.dart';

class WorkbenchCenterScaffold extends StatefulWidget {
  final Widget? tabBar;
  final Widget editor;
  final Widget resultHeader;
  final Widget resultContent;
  final double initialResultHeight;
  final double minimumResultHeight;
  final double minimumEditorHeight;
  final ValueChanged<double>? onResultHeightChanged;

  const WorkbenchCenterScaffold({
    super.key,
    this.tabBar,
    required this.editor,
    required this.resultHeader,
    required this.resultContent,
    this.initialResultHeight = 260,
    this.minimumResultHeight = 120,
    this.minimumEditorHeight = 140,
    this.onResultHeightChanged,
  });

  @override
  State<WorkbenchCenterScaffold> createState() =>
      _WorkbenchCenterScaffoldState();
}

class _WorkbenchCenterScaffoldState extends State<WorkbenchCenterScaffold> {
  late double _resultHeight = widget.initialResultHeight;

  @override
  void didUpdateWidget(covariant WorkbenchCenterScaffold oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialResultHeight != widget.initialResultHeight &&
        _resultHeight == oldWidget.initialResultHeight) {
      _resultHeight = widget.initialResultHeight;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        if (widget.tabBar != null) widget.tabBar!,
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final maxResultHeight =
                  (constraints.maxHeight - widget.minimumEditorHeight).clamp(
                    0.0,
                    constraints.maxHeight,
                  );
              final minResultHeight =
                  maxResultHeight < widget.minimumResultHeight
                  ? maxResultHeight
                  : widget.minimumResultHeight;
              final resultHeight = _resultHeight.clamp(
                minResultHeight,
                maxResultHeight,
              );

              return Column(
                children: [
                  Expanded(child: widget.editor),
                  WorkbenchSplitHandle(
                    onDrag: (delta) {
                      setState(() {
                        _resultHeight = (_resultHeight - delta).clamp(
                          minResultHeight,
                          maxResultHeight,
                        );
                      });
                      widget.onResultHeightChanged?.call(_resultHeight);
                    },
                  ),
                  SizedBox(
                    height: resultHeight,
                    child: Column(
                      children: [
                        widget.resultHeader,
                        Expanded(
                          child: ColoredBox(
                            color: Theme.of(context).colorScheme.surface,
                            child: widget.resultContent,
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
}

class WorkbenchSplitHandle extends StatelessWidget {
  final ValueChanged<double> onDrag;

  const WorkbenchSplitHandle({super.key, required this.onDrag});

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.resizeRow,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onVerticalDragUpdate: (details) => onDrag(details.delta.dy),
        child: Container(
          height: 7,
          color: Theme.of(context).dividerColor,
          alignment: Alignment.center,
          child: Container(
            width: 36,
            height: 2,
            color: Theme.of(context).colorScheme.outline,
          ),
        ),
      ),
    );
  }
}

class WorkbenchEditorSurface extends StatelessWidget {
  final Widget toolbar;
  final Widget editor;

  const WorkbenchEditorSurface({
    super.key,
    required this.toolbar,
    required this.editor,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        border: Border(
          bottom: BorderSide(color: Theme.of(context).dividerColor),
        ),
      ),
      child: Column(
        children: [
          Container(
            height: 34,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainer,
              border: Border(
                bottom: BorderSide(color: Theme.of(context).dividerColor),
              ),
            ),
            child: toolbar,
          ),
          Expanded(child: editor),
        ],
      ),
    );
  }
}

class WorkbenchResultBar extends StatelessWidget {
  final Widget leading;
  final List<Widget> actions;
  final String? countText;

  const WorkbenchResultBar({
    super.key,
    required this.leading,
    this.actions = const [],
    this.countText,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 42,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainer,
        border: Border(
          bottom: BorderSide(color: Theme.of(context).dividerColor),
        ),
      ),
      child: Row(
        children: [
          leading,
          const Spacer(),
          ...actions,
          if (countText != null)
            Text(
              countText!,
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
        ],
      ),
    );
  }
}
