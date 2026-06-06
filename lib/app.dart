import 'package:flutter/material.dart';

import 'features/workbench/home_page.dart';

class DBViewer extends StatelessWidget {
  const DBViewer({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'DB Viewer',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xff2f6f8f),
          brightness: Brightness.light,
        ),
        scaffoldBackgroundColor: const Color(0xfff4f6f7),
        visualDensity: VisualDensity.compact,
        inputDecorationTheme: const InputDecorationTheme(
          filled: true,
          fillColor: Colors.white,
          border: OutlineInputBorder(),
          isDense: true,
        ),
      ),
      home: const MyHomePage(title: 'DB Viewer'),
    );
  }
}
