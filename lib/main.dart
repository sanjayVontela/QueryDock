import 'package:bitsdojo_window/bitsdojo_window.dart';
import 'package:flutter/material.dart';
import 'app.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  doWhenWindowReady(() {
    const initialSize = Size(1280, 720);
    appWindow.minSize = const Size(300, 300);
    appWindow.size = initialSize;
    appWindow.alignment = Alignment.center;
    appWindow.title = 'DB Viewer';
    appWindow.show();
  });

  runApp(const DBViewer());
}
