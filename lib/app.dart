import 'package:flutter/material.dart';

import 'features/workbench/home_page.dart';

class DBViewer extends StatelessWidget {
  const DBViewer({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'DB Viewer',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
      ),
      home: const MyHomePage(title: 'DB Viewer'),
    );
  }
}
