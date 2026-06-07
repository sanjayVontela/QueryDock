import 'package:flutter/material.dart';

import 'features/workbench/home_page.dart';
import 'services/theme_controller.dart';

class DBViewer extends StatelessWidget {
  const DBViewer({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: AppThemeController.mode,
      builder: (context, themeMode, child) {
        return MaterialApp(
          title: 'QueryDock',
          debugShowCheckedModeBanner: false,
          themeMode: themeMode,
          theme: _theme(Brightness.light),
          darkTheme: _theme(Brightness.dark),
          home: const MyHomePage(title: 'QueryDock'),
        );
      },
    );
  }

  ThemeData _theme(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xff2f6f8f),
      brightness: brightness,
    );
    return ThemeData(
      brightness: brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: dark
          ? const Color(0xff181a1b)
          : const Color(0xfff4f6f7),
      canvasColor: dark ? const Color(0xff202325) : Colors.white,
      cardColor: dark ? const Color(0xff25282a) : Colors.white,
      dividerColor: dark ? const Color(0xff3b4043) : const Color(0xffd8dee2),
      visualDensity: VisualDensity.compact,
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: dark ? const Color(0xff25282a) : Colors.white,
        border: const OutlineInputBorder(),
        isDense: true,
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: dark ? const Color(0xff25282a) : Colors.white,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: dark ? const Color(0xff202325) : Colors.white,
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: dark ? const Color(0xffe4e7e9) : const Color(0xff282c2f),
          borderRadius: BorderRadius.circular(4),
        ),
        textStyle: TextStyle(
          color: dark ? const Color(0xff202325) : Colors.white,
          fontSize: 12,
        ),
      ),
    );
  }
}
