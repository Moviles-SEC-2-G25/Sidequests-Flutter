import 'package:flutter/material.dart';

import '../data/local/local_data_source.dart';
import '../data/services/ambient_light_monitor.dart';

/// Drives the app's light/dark ThemeMode from the "Modo oscuro" setting, or
/// from the ambient light sensor when "Tema automático" is on (mirror of the
/// Kotlin app's auto theme). Lives above HomeShell (in the composition root)
/// since it must also apply to the auth/onboarding screens.
///
/// Both settings belong to the device, not the account. A manual choice turns
/// the automatic theme off, as in Kotlin.
class ThemeViewModel extends ChangeNotifier {
  final LocalDataSource _localDataSource;
  final AmbientLightMonitor? _lightMonitor;
  AppLifecycleListener? _lifecycleListener;

  bool _isDarkMode;
  bool _autoThemeEnabled;

  /// The device has an ambient light sensor (Android only).
  bool lightSensorAvailable = false;

  /// Latest ambient light reading, in lux; null until the sensor reports.
  double? ambientLux;

  /// Last decision of the sensor, kept so turning "auto" on applies it at once.
  bool? _lastAmbientDark;

  /// Without [lightMonitor] (tests) the theme is manual only.
  ThemeViewModel(this._localDataSource, {AmbientLightMonitor? lightMonitor})
    : _lightMonitor = lightMonitor,
      _isDarkMode = _read(() => _localDataSource.isDarkMode(), false),
      _autoThemeEnabled = _read(() => _localDataSource.isAutoThemeEnabled(), false) {
    final monitor = _lightMonitor;
    if (monitor != null) _initSensor(monitor);
  }

  // A test double that doesn't know a newer setting must not break the app.
  static bool _read(bool Function() read, bool fallback) {
    try {
      return read();
    } catch (_) {
      return fallback;
    }
  }

  Future<void> _initSensor(AmbientLightMonitor monitor) async {
    lightSensorAvailable = await monitor.isAvailable();
    if (!lightSensorAvailable) {
      _autoThemeEnabled = false;
      notifyListeners();
      return;
    }
    monitor.lux.addListener(_onLux);
    monitor.isDark.addListener(_onAmbientDecision);
    // Only while the app is visible: no sensor in the background.
    _lifecycleListener = AppLifecycleListener(
      onResume: monitor.start,
      onPause: monitor.stop,
    );
    monitor.start();
    notifyListeners();
  }

  bool get isDarkMode => _isDarkMode;
  bool get autoThemeEnabled => _autoThemeEnabled;

  ThemeMode get themeMode => _isDarkMode ? ThemeMode.dark : ThemeMode.light;

  /// Manual toggle: overrides the automatic (light sensor) theme.
  Future<void> setDarkMode(bool value) async {
    _isDarkMode = value;
    final wasAuto = _autoThemeEnabled;
    _autoThemeEnabled = false;
    notifyListeners();
    await _localDataSource.setDarkMode(value);
    if (wasAuto) await _localDataSource.setAutoThemeEnabled(false);
  }

  /// Turns the automatic (light sensor) theme on or off.
  Future<void> setAutoThemeEnabled(bool enabled) async {
    if (!lightSensorAvailable) return;
    _autoThemeEnabled = enabled;
    if (enabled && _lastAmbientDark != null) _isDarkMode = _lastAmbientDark!;
    notifyListeners();
    await _localDataSource.setAutoThemeEnabled(enabled);
    await _localDataSource.setDarkMode(_isDarkMode);
  }

  void _onLux() {
    final value = _lightMonitor?.lux.value;
    if (value == ambientLux) return;
    ambientLux = value;
    notifyListeners();
  }

  void _onAmbientDecision() {
    final dark = _lightMonitor?.isDark.value;
    if (dark == null) return;
    _lastAmbientDark = dark;
    if (!_autoThemeEnabled || dark == _isDarkMode) return;
    _isDarkMode = dark;
    notifyListeners();
    _localDataSource.setDarkMode(dark).catchError((Object _) {});
  }

  @override
  void dispose() {
    _lifecycleListener?.dispose();
    final monitor = _lightMonitor;
    if (monitor != null) {
      monitor.lux.removeListener(_onLux);
      monitor.isDark.removeListener(_onAmbientDecision);
      monitor.dispose();
    }
    super.dispose();
  }
}
