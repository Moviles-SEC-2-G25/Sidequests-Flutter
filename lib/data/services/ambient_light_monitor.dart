import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../core/ambient_light_classifier.dart';

/// Sensor feature (mirror of the Kotlin app's AmbientLightMonitor): the
/// ambient light sensor that drives the automatic theme.
///
/// Readings come from a platform channel registered in Android's
/// MainActivity. The native listener only exists while [start]ed (the app is
/// in the foreground), so it never drains battery in the background.
/// Light sensors are "on-change": they stop reporting while the light is
/// stable, so when a change is pending the last reading is re-evaluated after
/// the hold time instead of waiting for a new event.
/// Platforms without the channel (iOS, web, tests) report [isAvailable] false
/// and keep the manual toggle.
class AmbientLightMonitor {
  static const _info = MethodChannel('sidequests/ambient_light/info');
  static const _lux = EventChannel('sidequests/ambient_light/lux');

  final AmbientLightClassifier _classifier;
  final Stream<double> Function() _readings;
  final Future<bool> Function() _checkAvailable;
  final DateTime Function() _now;

  StreamSubscription<double>? _subscription;
  Timer? _recheck;
  double? _lastLux;

  /// Latest reading in lux (shown in Perfil so the behaviour can be checked
  /// live).
  final ValueNotifier<double?> lux = ValueNotifier(null);

  /// Latest dark/light decision; null until the first reading.
  final ValueNotifier<bool?> isDark = ValueNotifier(null);

  AmbientLightMonitor({
    AmbientLightClassifier? classifier,
    Stream<double> Function()? readings,
    Future<bool> Function()? checkAvailable,
    DateTime Function()? now,
  }) : _classifier = classifier ?? AmbientLightClassifier(),
       _readings = readings ?? _platformReadings,
       _checkAvailable = checkAvailable ?? _platformAvailable,
       _now = now ?? DateTime.now;

  static Stream<double> _platformReadings() =>
      _lux.receiveBroadcastStream().map((value) => (value as num).toDouble());

  static Future<bool> _platformAvailable() async {
    try {
      return await _info.invokeMethod<bool>('isAvailable') ?? false;
    } catch (_) {
      // MissingPluginException on iOS/web: no sensor there.
      return false;
    }
  }

  Future<bool> isAvailable() => _checkAvailable();

  void start() {
    if (_subscription != null) return;
    _subscription = _readings().listen(
      (value) {
        _lastLux = value;
        lux.value = value.roundToDouble();
        _evaluate(value);
      },
      onError: (Object _) {},
      cancelOnError: false,
    );
  }

  void stop() {
    _recheck?.cancel();
    _recheck = null;
    _subscription?.cancel();
    _subscription = null;
  }

  void _evaluate(double value) {
    final decision = _classifier.onReading(value, _now());
    if (decision != null) isDark.value = decision;
    _recheck?.cancel();
    if (_classifier.hasPendingChange) {
      _recheck = Timer(_classifier.minHold + const Duration(milliseconds: 100), () {
        final last = _lastLux;
        if (last != null) _evaluate(last);
      });
    }
  }

  void dispose() {
    stop();
    lux.dispose();
    isDark.dispose();
  }
}
