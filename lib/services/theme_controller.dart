import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AppThemeController {
  static const _preferenceKey = 'appearance.theme_mode';
  static final mode = ValueNotifier<ThemeMode>(ThemeMode.system);

  static Future<void> load() async {
    final preferences = await SharedPreferences.getInstance();
    mode.value = ThemeMode.values.firstWhere(
      (item) => item.name == preferences.getString(_preferenceKey),
      orElse: () => ThemeMode.system,
    );
  }

  static Future<void> setMode(ThemeMode value) async {
    mode.value = value;
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(_preferenceKey, value.name);
  }

  static Future<void> toggle(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    return setMode(
      brightness == Brightness.dark ? ThemeMode.light : ThemeMode.dark,
    );
  }
}
