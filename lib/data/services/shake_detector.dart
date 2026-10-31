import 'dart:async';
import 'dart:math';

import 'package:sensors_plus/sensors_plus.dart';

/// Detects the "shake the phone" gesture from the accelerometer.
///
/// Uses `userAccelerometerEvents` (gravity already subtracted) so tilting or
/// resting the phone doesn't trigger it — only an actual shake does. All the
/// threshold/debounce logic lives here, never in a view. The sensor is only
/// read while someone listens to [onShake], and a device without one simply
/// never shakes.
class ShakeDetector {
  /// Shake threshold, in m/s². Chosen well above gravity (9.8) so normal
  /// handling doesn't false-positive.
  static const threshold = 15.0;

  /// Minimum time between two detected shakes, so one physical shake (which
  /// crosses the threshold on several consecutive samples) fires once.
  static const debounceDuration = Duration(seconds: 2);

  final DateTime Function() _now;
  final Stream<UserAccelerometerEvent>? _accelerometerEvents;
  late final StreamController<void> _controller = StreamController<void>.broadcast(
    onListen: _startSensor,
    
  );
  StreamSubscription<UserAccelerometerEvent>? _subscription;
  DateTime? _lastShakeAt;

  /// False once the sensor failed: no accelerometer on this device.
  bool isAvailable = true;

  ShakeDetector({Stream<UserAccelerometerEvent>? accelerometerEvents, DateTime Function()? now})
    : _accelerometerEvents = accelerometerEvents,
      _now = now ?? DateTime.now;

  /// Emits an event each time a shake is detected.
  Stream<void> get onShake => _controller.stream;

  void _startSensor() {
    if (!isAvailable) return;
    try {
      _subscription = (_accelerometerEvents ?? userAccelerometerEventStream()).listen(
        _onEvent,
        onError: (Object _) => _disable(),
      );
    } catch (_) {
      _disable();
    }
  }

  void _stopSensor() {
    _subscription?.cancel();
    _subscription = null;
  }

  void _disable() {
    isAvailable = false;
    _stopSensor();
  }

  void _onEvent(UserAccelerometerEvent event) {
    final magnitude = sqrt(event.x * event.x + event.y * event.y + event.z * event.z);
    if (magnitude <= threshold) return;

    final now = _now();
    if (_lastShakeAt != null && now.difference(_lastShakeAt!) < debounceDuration) {
      return;
    }
    _lastShakeAt = now;
    _controller.add(null);
  }

  void dispose() {
    _stopSensor();
    _controller.close();
  }
}
