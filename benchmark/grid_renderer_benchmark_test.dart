import 'package:db_viewer/features/workbench/widgets/db_viewer_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final columns = [for (var column = 0; column < 30; column++) 'column_$column'];
  final rows = [
    for (var row = 0; row < 500; row++)
      [for (var column = 0; column < 30; column++) 'r$row-c$column'],
  ];

  for (final renderer in ResultGridRenderer.values) {
    testWidgets('${renderer.name} 500x30 comparison sample', (tester) async {
      final buildWatch = Stopwatch()..start();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 1200,
              height: 700,
              child: ResultGrid(
                renderer: renderer,
                columns: columns,
                rows: rows,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      buildWatch.stop();

      final scrollWatch = Stopwatch()..start();
      for (var index = 0; index < 12; index++) {
        await tester.drag(
          find.byType(ResultGrid),
          const Offset(0, -350),
          warnIfMissed: false,
        );
        await tester.pump(const Duration(milliseconds: 16));
      }
      scrollWatch.stop();

      // Debug-mode values are directional, not release performance guarantees.
      // ignore: avoid_print
      print(
        '${renderer.name}: build=${buildWatch.elapsedMicroseconds}us, '
        'scroll=${scrollWatch.elapsedMicroseconds}us',
      );
    });
  }
}
