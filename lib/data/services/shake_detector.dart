import 'dart:async';
import 'dart:math';

import 'package:sensors_plus/sensors_plus.dart';

/// Detects the "shake the phone" gesture from the accelerometer.
///
/// Uses `userAccelerometerEvents` (gravity already subtracted) so tilting or
/// resting the phone doesn't trigger it — only an actual shake does. All the
/// threshold/debounce logic lives here, never in a view.
class ShakeDetector {
  /// Shake threshold, in m/s². Chosen well above gravity (9.8) so normal
  /// handling doesn't false-positive.
  static const threshold = 15.0;

  /// Minimum time between two detected shakes, so one physical shake (which
  /// crosses the threshold on several consecutive samples) fires once.
  static const debounceDuration = Duration(seconds: 2);

  final DateTime Function() _now;
  final StreamController<void> _controller = StreamController<void>.broadcast();
  late final StreamSubscription<UserAccelerometerEvent> _subscription;
  DateTime? _lastShakeAt;

  ShakeDetector({Stream<UserAccelerometerEvent>? accelerometerEvents, DateTime Function()? now})
    : _now = now ?? DateTime.now {
    _subscription = (accelerometerEvents ?? userAccelerometerEventStream()).listen(_onEvent);
  }

  /// Emits an event each time a shake is detected.
  Stream<void> get onShake => _controller.stream;

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
    _subscription.cancel();
    _controller.close();
  }
}
