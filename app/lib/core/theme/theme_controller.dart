import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../constants/app_constants.dart';

/// Holds the user's manual light/dark preference (as opposed to just
/// following the OS setting), persisted to disk. A ChangeNotifier so the
/// theme toggle button and [MaterialApp.themeMode] can both react to it
/// without a heavier state-management dependency -- same pattern as
/// [SessionManager].
class ThemeController extends ChangeNotifier {
  ThemeController._();
  static final ThemeController instance = ThemeController._();

  ThemeMode _mode = ThemeMode.system;
  ThemeMode get mode => _mode;

  Future<void> loadFromDisk() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(AppConstants.themeModeKey);
    _mode = switch (stored) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };
    notifyListeners();
  }

  /// Cycles light -> dark -> light. Starting from `system`, the first tap
  /// resolves to the opposite of whatever is currently rendered so it feels
  /// like a real toggle rather than jumping to a fixed default.
  Future<void> toggle(Brightness currentlyRendered) async {
    final next = currentlyRendered == Brightness.dark ? ThemeMode.light : ThemeMode.dark;
    _mode = next;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(AppConstants.themeModeKey, next == ThemeMode.dark ? 'dark' : 'light');
  }
}
