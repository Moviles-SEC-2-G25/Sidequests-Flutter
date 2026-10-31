import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:sidequests/data/services/shake_detector.dart';

class _ThrowingStream extends Stream<UserAccelerometerEvent> {
  @override
  StreamSubscription<UserAccelerometerEvent> listen(
    void Function(UserAccelerometerEvent event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => throw UnsupportedError('no accelerometer');
}

void main() {
  late StreamController<UserAccelerometerEvent> source;
  late DateTime now;
  late ShakeDetector detector;

  UserAccelerometerEvent eventOfMagnitude(double magnitude) =>
      UserAccelerometerEvent(magnitude, 0, 0, now);

  setUp(() {
    source = StreamController<UserAccelerometerEvent>();
    now = DateTime(2026, 1, 1, 12);
    detector = ShakeDetector(accelerometerEvents: source.stream, now: () => now);
  });

  tearDown(() {
    detector.dispose();
    source.close();
  });

  test('emits a shake when magnitude crosses the threshold', () async {
    final shakes = <void>[];
    detector.onShake.listen(shakes.add);

    source.add(eventOfMagnitude(ShakeDetector.threshold + 1));
    await pumpEventQueue();

    expect(shakes, hasLength(1));
  });

  test('does not emit below or at the threshold', () async {
    final shakes = <void>[];
    detector.onShake.listen(shakes.add);

    source.add(eventOfMagnitude(ShakeDetector.threshold));
    source.add(eventOfMagnitude(ShakeDetector.threshold - 5));
    source.add(eventOfMagnitude(0));
    await pumpEventQueue();

    expect(shakes, isEmpty);
  });

  test('debounces a second shake within the debounce window', () async {
    final shakes = <void>[];
    detector.onShake.listen(shakes.add);

    source.add(eventOfMagnitude(20));
    await pumpEventQueue();
    now = now.add(const Duration(seconds: 1));
    source.add(eventOfMagnitude(20));
    await pumpEventQueue();

    expect(shakes, hasLength(1));
  });

  test('emits again once the debounce window has passed', () async {
    final shakes = <void>[];
    detector.onShake.listen(shakes.add);

    source.add(eventOfMagnitude(20));
    await pumpEventQueue();
    now = now.add(ShakeDetector.debounceDuration);
    source.add(eventOfMagnitude(20));
    await pumpEventQueue();

    expect(shakes, hasLength(2));
  });

  test('reads the sensor only while someone listens', () async {
    final sensor = StreamController<UserAccelerometerEvent>.broadcast();
    addTearDown(sensor.close);
    final lazy = ShakeDetector(accelerometerEvents: sensor.stream, now: () => now);
    addTearDown(lazy.dispose);
    expect(sensor.hasListener, isFalse);

    final first = lazy.onShake.listen(null);
    expect(sensor.hasListener, isTrue);

    await first.cancel();
    expect(sensor.hasListener, isFalse);

    final second = lazy.onShake.listen(null);
    expect(sensor.hasListener, isTrue);
    await second.cancel();
  });

  test('without an accelerometer it never shakes, with no unhandled error', () async {
    final shakes = <void>[];
    detector.onShake.listen(shakes.add);

    source.addError(Exception('NO_SENSOR'));
    await pumpEventQueue();

    expect(detector.isAvailable, isFalse);
    expect(source.hasListener, isFalse);
    expect(shakes, isEmpty);
  });

  test('a stream that fails to open leaves it disabled too', () async {
    final failing = ShakeDetector(accelerometerEvents: _ThrowingStream(), now: () => now);
    addTearDown(failing.dispose);

    failing.onShake.listen(null);

    expect(failing.isAvailable, isFalse);
  });

  test('once disabled, listening again does not touch the sensor', () async {
    final sensor = StreamController<UserAccelerometerEvent>.broadcast();
    addTearDown(sensor.close);
    final disabled = ShakeDetector(accelerometerEvents: sensor.stream, now: () => now);
    addTearDown(disabled.dispose);
    final subscription = disabled.onShake.listen(null);
    sensor.addError(Exception('NO_SENSOR'));
    await pumpEventQueue();
    await subscription.cancel();

    final again = disabled.onShake.listen(null);

    expect(sensor.hasListener, isFalse);
    await again.cancel();
  });

  test('dispose cancels the underlying subscription and closes the stream', () async {
    var isDone = false;
    detector.onShake.listen(null, onDone: () => isDone = true);

    detector.dispose();
    await pumpEventQueue();

    expect(isDone, isTrue);
    expect(source.hasListener, isFalse);
  });
}
