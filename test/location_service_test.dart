import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:sidequests/data/context/context_manager.dart';
import 'package:sidequests/data/services/battery_monitor.dart';
import 'package:sidequests/data/services/location_service.dart';

Position _position() => Position(
  latitude: 4.6,
  longitude: -74.07,
  timestamp: DateTime(2026, 1, 1),
  accuracy: 10,
  altitude: 0,
  altitudeAccuracy: 0,
  heading: 0,
  headingAccuracy: 0,
  speed: 0,
  speedAccuracy: 0,
);

/// The plugin itself: GPS on, permission granted. With [timesOut] no fix
/// arrives, which the real platforms report with a TimeoutException.
class _FakeGeolocator extends GeolocatorPlatform {
  bool timesOut = false;
  final List<LocationSettings?> requests = [];

  @override
  Future<bool> isLocationServiceEnabled() async => true;

  @override
  Future<LocationPermission> checkPermission() async => LocationPermission.whileInUse;

  @override
  Future<Position> getCurrentPosition({LocationSettings? locationSettings}) async {
    requests.add(locationSettings);
    if (timesOut) throw TimeoutException('no fix', locationSettings?.timeLimit);
    return _position();
  }
}

class _FullBattery extends BatteryMonitor {
  @override
  Future<bool> isLow() async => false;
}

void main() {
  late GeolocatorPlatform original;
  late _FakeGeolocator geolocator;

  setUp(() {
    original = GeolocatorPlatform.instance;
    geolocator = _FakeGeolocator();
    GeolocatorPlatform.instance = geolocator;
  });

  tearDown(() => GeolocatorPlatform.instance = original);

  test('every fix request carries the time limit and the asked accuracy', () async {
    final position = await LocationService().getCurrentPosition(accuracy: LocationAccuracy.low);

    expect(position?.latitude, 4.6);
    expect(geolocator.requests.single?.timeLimit, LocationService.fixTimeLimit);
    expect(geolocator.requests.single?.accuracy, LocationAccuracy.low);
  });

  test('no fix within the limit is a null position, not an error', () async {
    geolocator.timesOut = true;

    expect(await LocationService().getCurrentPosition(), isNull);
  });

  test('a timed-out reading frees the shared one: callers finish and the next call reads again', () async {
    final manager = ContextManager(
      locationService: LocationService(),
      batteryMonitor: _FullBattery(),
    );
    geolocator.timesOut = true;

    final contexts = await Future.wait([manager.snapshot(), manager.snapshot()]);

    expect(contexts.map((c) => c.hasLocation), [false, false]);
    expect(geolocator.requests, hasLength(1));

    await expectLater(manager.snapshot(), completes);
    expect(geolocator.requests, hasLength(2));
  });
}
