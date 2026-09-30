import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:sidequests/data/services/shake_detector.dart';

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

  test('dispose cancels the underlying subscription and closes the stream', () async {
    var isDone = false;
    detector.onShake.listen(null, onDone: () => isDone = true);

    detector.dispose();
    await pumpEventQueue();

    expect(isDone, isTrue);
    expect(source.hasListener, isFalse);
  });
}
