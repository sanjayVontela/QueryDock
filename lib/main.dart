import 'package:bitsdojo_window/bitsdojo_window.dart';
import 'package:flutter/material.dart';
import 'app.dart';
import 'services/crash_reporter.dart';
import 'services/theme_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  CrashReporter.install();
  await AppThemeController.load();

  doWhenWindowReady(() {
    appWindow.minSize = const Size(900, 600);
    appWindow.title = 'QueryDock';
    appWindow.maximize();
    appWindow.show();
  });

  runApp(const DBViewer());
}
