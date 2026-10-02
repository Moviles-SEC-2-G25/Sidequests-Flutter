import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sidequests/core/verification/check_in_sampling.dart';
import 'package:sidequests/core/verification/step_verification_strategy.dart';
import 'package:sidequests/data/services/location_check_in_service.dart';

const _targetLat = 4.6473;
const _targetLon = -74.0600;
const _degPerMeter = 1 / 111195;

CheckInFix _fixAt(double metersNorth) => CheckInFix(
  latitude: _targetLat + metersNorth * _degPerMeter,
  longitude: _targetLon,
  accuracyMeters: 10,
);

Future<void> _flush() => Future<void>.delayed(Duration.zero);

void main() {
  late StreamController<CheckInFix> gps;
  late List<(CheckInPrecision, int)> subscriptions;
  late Future<LocationAccess> Function() requestAccess;
  late bool lowBattery;
  late LocationCheckInService service;

  setUp(() {
    gps = StreamController<CheckInFix>.broadcast();
    subscriptions = [];
    requestAccess = () async => LocationAccess.granted;
    lowBattery = false;
    service = LocationCheckInService(
      requestAccess: () => requestAccess(),
      isLowBattery: () async => lowBattery,
      positions: (precision, distanceFilter) {
        subscriptions.add((precision, distanceFilter));
        return gps.stream;
      },
    );
  });

  tearDown(() => service.dispose());

  test('starts with a sparse, balanced stream — no polling, no precise GPS far away', () async {
    final access = await service.start(latitude: _targetLat, longitude: _targetLon);

    expect(access, LocationAccess.granted);
    expect(service.isWatching, isTrue);
    expect(subscriptions, [(CheckInPrecision.balanced, 50)]);
  });

  test('switches to precise GPS only in the last 300 m', () async {
    await service.start(latitude: _targetLat, longitude: _targetLon);

    gps.add(_fixAt(1000));
    await _flush();
    expect(subscriptions, hasLength(1)); // still far: no re-subscription

    gps.add(_fixAt(250));
    await _flush();
    expect(subscriptions.last, (CheckInPrecision.precise, 5));
  });

  test('hysteresis: GPS noise around 300 m does not flip the precision back and forth', () async {
    await service.start(latitude: _targetLat, longitude: _targetLon);
    gps.add(_fixAt(250));
    await _flush();

    gps.add(_fixAt(350)); // jitter just past 300 m
    await _flush();
    expect(subscriptions, hasLength(2));

    gps.add(_fixAt(450)); // really walking away
    await _flush();
    expect(subscriptions.last, (CheckInPrecision.balanced, 50));
  });

  test('low battery: coarser and sparser, but still precise once near', () async {
    lowBattery = true;
    await service.start(latitude: _targetLat, longitude: _targetLon);
    expect(subscriptions.single, (CheckInPrecision.coarse, 100));

    gps.add(_fixAt(100));
    await _flush();
    expect(subscriptions.last, (CheckInPrecision.precise, 15));
  });

  test('every fix is forwarded', () async {
    final fixes = <CheckInFix>[];
    service.fixes.listen(fixes.add);
    await service.start(latitude: _targetLat, longitude: _targetLon);

    gps
      ..add(_fixAt(800))
      ..add(_fixAt(700));
    await _flush();

    expect(fixes, hasLength(2));
  });

  test('without access nothing is subscribed', () async {
    requestAccess = () async => LocationAccess.denied;

    final access = await service.start(latitude: _targetLat, longitude: _targetLon);

    expect(access, LocationAccess.denied);
    expect(service.isWatching, isFalse);
    expect(subscriptions, isEmpty);
  });

  test('stop while the permission dialog is up: the late grant never subscribes', () async {
    final permission = Completer<LocationAccess>();
    requestAccess = () => permission.future;

    final starting = service.start(latitude: _targetLat, longitude: _targetLon);
    service.stop();
    permission.complete(LocationAccess.granted);
    await starting;

    expect(service.isWatching, isFalse);
    expect(subscriptions, isEmpty);
  });

  test('stop cancels the stream (later fixes are ignored)', () async {
    final fixes = <CheckInFix>[];
    service.fixes.listen(fixes.add);
    await service.start(latitude: _targetLat, longitude: _targetLon);

    service.stop();
    gps.add(_fixAt(10));
    await _flush();

    expect(service.isWatching, isFalse);
    expect(service.precision, isNull);
    expect(fixes, isEmpty);
  });

  test('a stream error (GPS switched off) stops watching and is forwarded', () async {
    Object? forwarded;
    service.fixes.listen((_) {}, onError: (Object e) => forwarded = e);
    await service.start(latitude: _targetLat, longitude: _targetLon);

    gps.addError(Exception('location service disabled'));
    await _flush();

    expect(service.isWatching, isFalse);
    expect(forwarded, isA<Exception>());
  });
}
