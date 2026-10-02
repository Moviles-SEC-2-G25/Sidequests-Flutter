import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sidequests/data/services/step_counter_service.dart';
import 'package:sidequests/models/step_session.dart';

/// Lets stream events reach their listeners.
Future<void> _flush() => Future<void>.delayed(Duration.zero);

void main() {
  // Cumulative-since-boot readings, as the OS step counter reports them.
  late StreamController<int> sensor;
  late StepCounterStatus access;
  late StepCounterService service;

  setUp(() {
    sensor = StreamController<int>.broadcast();
    access = StepCounterStatus.counting;
    service = StepCounterService(
      cumulativeSteps: () => sensor.stream,
      requestAccess: () async => access,
      openSettings: () async => true,
    );
  });

  tearDown(() => service.dispose());

  test('the first reading is the baseline: steps count from the mission start, not from boot', () async {
    service.start(const StepSession(userQuestId: 'uq-1'));

    sensor.add(5000); // already 5000 steps since boot
    await _flush();
    expect(service.session!.steps, 0);
    expect(service.session!.hasData, isTrue);

    sensor.add(5120);
    await _flush();
    expect(service.session!.steps, 120);
    expect(service.status, StepCounterStatus.counting);
  });

  test('before any reading there is no data (null), which is not the same as 0 steps', () {
    service.start(const StepSession(userQuestId: 'uq-1'));

    expect(service.session!.hasData, isFalse);
  });

  test('a restored session keeps its baseline and counts steps walked while the app was closed', () async {
    // Persisted before the app was killed: baseline 5000, last seen 5100.
    service.start(const StepSession(userQuestId: 'uq-1', baseline: 5000, lastReading: 5100));

    sensor.add(5400); // walked 300 more with the app closed
    await _flush();

    expect(service.session!.steps, 400);
  });

  test('a reboot (counter goes backwards) keeps what was counted and continues from 0', () async {
    service.start(const StepSession(userQuestId: 'uq-1'));
    sensor
      ..add(5000)
      ..add(5250); // 250 steps, then the phone reboots
    await _flush();

    sensor.add(40); // new boot: 40 steps since reboot
    await _flush();

    expect(service.session!.steps, 290);
    expect(service.session!.carried, 250);
  });

  test('resuming an abandoned attempt adds the new segment to its saved total', () async {
    service.start(const StepSession(userQuestId: 'uq-1', carried: 700));
    expect(service.session!.hasData, isTrue); // shows 700 before any reading

    sensor
      ..add(9000)
      ..add(9050);
    await _flush();

    expect(service.session!.steps, 750);
  });

  test('stop returns the final session, goes idle and ignores later readings', () async {
    service.start(const StepSession(userQuestId: 'uq-1'));
    sensor
      ..add(100)
      ..add(160);
    await _flush();

    final finished = service.stop();
    sensor.add(999);
    await _flush();

    expect(finished!.steps, 60);
    expect(service.session, isNull);
    expect(service.status, StepCounterStatus.idle);
  });

  test('a sensor error (no step counter on this phone) means unavailable, without throwing', () async {
    service.start(const StepSession(userQuestId: 'uq-1'));

    sensor.addError(Exception('StepCount not available'));
    await _flush();

    expect(service.status, StepCounterStatus.unavailable);
    expect(service.session, isNull);
  });

  test('requestAccess reports a denied permission and does not start counting', () async {
    access = StepCounterStatus.permissionDenied;
    expect(await service.requestAccess(), StepCounterStatus.permissionDenied);
    expect(service.status, StepCounterStatus.permissionDenied);

    access = StepCounterStatus.permissionPermanentlyDenied;
    expect(await service.requestAccess(), StepCounterStatus.permissionPermanentlyDenied);
    expect(service.session, isNull);
  });

  test('onChange fires on status changes and on every reading', () async {
    var changes = 0;
    service.onChange.listen((_) => changes++);

    service.start(const StepSession(userQuestId: 'uq-1')); // status -> counting
    sensor
      ..add(10)
      ..add(20);
    await _flush();

    expect(changes, 3);
  });

  test('StepSession survives a JSON round trip (what Hive stores)', () {
    const session = StepSession(userQuestId: 'uq-1', carried: 30, baseline: 5000, lastReading: 5100);

    final restored = StepSession.fromJson(session.toJson());

    expect(restored.userQuestId, 'uq-1');
    expect(restored.steps, 130);
    expect(StepSession.fromJson(const StepSession(userQuestId: 'x').toJson()).hasData, isFalse);
  });
}
