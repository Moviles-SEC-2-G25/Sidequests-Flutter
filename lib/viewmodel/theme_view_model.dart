import 'package:flutter/material.dart';

import '../data/local/local_data_source.dart';

/// Drives the app's light/dark ThemeMode from the "Modo oscuro" setting.
/// Lives above HomeShell (in the composition root) since it must also apply
/// to the auth/onboarding screens, not just the signed-in app shell.
class ThemeViewModel extends ChangeNotifier {
  final LocalDataSource _localDataSource;

  ThemeViewModel(this._localDataSource);

  bool get isDarkMode => _localDataSource.isDarkMode();

  ThemeMode get themeMode => isDarkMode ? ThemeMode.dark : ThemeMode.light;

  Future<void> setDarkMode(bool value) async {
    await _localDataSource.setDarkMode(value);
    notifyListeners();
  }
}
