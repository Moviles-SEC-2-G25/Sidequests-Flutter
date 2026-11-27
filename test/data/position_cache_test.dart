import 'dart:async';
import 'dart:convert';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sidequests/data/context/context_manager.dart';
import 'package:sidequests/data/local/local_data_source.dart';
import 'package:sidequests/data/remote/supabase_remote_data_source.dart';
import 'package:sidequests/data/services/battery_monitor.dart';
import 'package:sidequests/data/services/location_service.dart';
import 'package:sidequests/data/services/position_cache.dart';
import 'package:sidequests/data/services/weather_service.dart';
import 'package:sidequests/repository/auth_repository.dart';

Position _position({required DateTime at, double accuracy = 15, double latitude = 4.6}) => Position(
  latitude: latitude,
  longitude: -74.07,
  timestamp: at,
  accuracy: accuracy,
  altitude: 0,
  altitudeAccuracy: 0,
  heading: 0,
  headingAccuracy: 0,
  speed: 0,
  speedAccuracy: 0,
);

/// The plugin: GPS on and precise permission granted unless a test changes
/// it. A fresh fix is taken "now" by the test's clock; with [timesOut] none
/// arrives.
class _FakeGeolocator extends GeolocatorPlatform {
  final DateTime Function() clock;
  bool serviceEnabled = true;
  LocationPermission permission = LocationPermission.whileInUse;
  LocationAccuracyStatus accuracyStatus = LocationAccuracyStatus.precise;
  Position? lastKnown;
  double freshAccuracy = 15;
  bool timesOut = false;
  int lastKnownCalls = 0;
  int accuracyStatusCalls = 0;
  final List<LocationSettings?> freshRequests = [];

  _FakeGeolocator(this.clock);

  @override
  Future<bool> isLocationServiceEnabled() async => serviceEnabled;

  @override
  Future<LocationPermission> checkPermission() async => permission;

  @override
  Future<LocationPermission> requestPermission() async => permission;

  @override
  Future<LocationAccuracyStatus> getLocationAccuracy() async {
    accuracyStatusCalls++;
    return accuracyStatus;
  }

  @override
  Future<Position?> getLastKnownPosition({bool forceLocationManager = false}) async {
    lastKnownCalls++;
    return lastKnown;
  }

  @override
  Future<Position> getCurrentPosition({LocationSettings? locationSettings}) async {
    freshRequests.add(locationSettings);
    if (timesOut) throw TimeoutException('no fix', locationSettings?.timeLimit);
    return _position(at: clock(), accuracy: freshAccuracy);
  }
}

class _FullBattery extends BatteryMonitor {
  @override
  Future<bool> isLow() async => false;
}

class _Online implements Connectivity {
  @override
  Future<List<ConnectivityResult>> checkConnectivity() async => const [ConnectivityResult.wifi];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeRemote implements SupabaseRemoteDataSource {
  @override
  Future<void> signOut() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeLocal implements LocalDataSource {
  @override
  Future<void> clear() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late DateTime now;
  late GeolocatorPlatform original;
  late _FakeGeolocator geolocator;
  late List<String> logs;
  late PositionCache cache;
  late LocationService location;

  setUp(() {
    now = DateTime.utc(2026, 11, 27, 12);
    original = GeolocatorPlatform.instance;
    geolocator = _FakeGeolocator(() => now);
    GeolocatorPlatform.instance = geolocator;
    logs = [];
    cache = PositionCache(now: () => now, log: logs.add);
    location = LocationService(positionCache: cache);
  });

  tearDown(() => GeolocatorPlatform.instance = original);

  group('level 1 (memory)', () {
    test('a fix within the TTL answers the next call without the GPS', () async {
      final first = await location.getCurrentPosition();
      now = now.add(const Duration(seconds: 59));
      final second = await location.getCurrentPosition();

      expect(second, same(first));
      expect(geolocator.freshRequests, hasLength(1));
      expect((cache.memoryHits, cache.systemHits, cache.freshReads), (1, 0, 1));
      expect(logs.last, contains('level 1 hit'));
      expect(logs.last, contains('L1 hits 1 · L2 hits 0 · fresh reads 1'));
    });

    test('at the TTL it is a miss and the GPS is read again', () async {
      await location.getCurrentPosition();
      now = now.add(PositionCache.ttl);
      await location.getCurrentPosition();

      expect(geolocator.freshRequests, hasLength(2));
      expect(cache.memoryHits, 0);
      expect(logs.last, contains('L1 rejected: TTL expired (age 60 s)'));
    });

    test('a fix less precise than the caller asks for is a miss', () async {
      geolocator.freshAccuracy = 50;
      await location.getCurrentPosition();

      await location.getCurrentPosition(accuracy: LocationAccuracy.low);
      expect(cache.memoryHits, 1, reason: '50 m is enough for medium and low');

      await location.getCurrentPosition(accuracy: LocationAccuracy.high);
      expect(cache.memoryHits, 1, reason: 'high needs 30 m or better');
      expect(geolocator.freshRequests, hasLength(2));
      expect(geolocator.freshRequests.last?.accuracy, LocationAccuracy.high);
      expect(logs.last, contains('L1 rejected: accuracy too low (±50 m > 30 m)'));
    });

    test('the radius each caller accepts: 100 m up to medium, 30 m from high', () async {
      for (final coarse in [
        LocationAccuracy.lowest,
        LocationAccuracy.low,
        LocationAccuracy.medium,
      ]) {
        expect(PositionCache.maxAccuracyMetersFor(coarse), 100);
      }
      for (final precise in [
        LocationAccuracy.high,
        LocationAccuracy.best,
        LocationAccuracy.bestForNavigation,
      ]) {
        expect(PositionCache.maxAccuracyMetersFor(precise), 30);
      }

      // Through level 2 with no reading of this run yet, so nothing excuses a
      // coarser fix (that's the 'when the device can't do better' group).
      for (final (accuracy, limit) in [
        (LocationAccuracy.medium, 100.0),
        (LocationAccuracy.high, 30.0),
      ]) {
        for (final (radius, answers) in [(limit, true), (limit + 1, false)]) {
          cache.invalidate();
          final osFix = _position(at: now, accuracy: radius);
          geolocator.lastKnown = osFix;

          final position = await location.getCurrentPosition(accuracy: accuracy);

          expect(identical(position, osFix), answers, reason: '±$radius m for $accuracy');
        }
      }
    });

    test('a device clock moved back (negative age) is a miss', () async {
      await location.getCurrentPosition();
      now = now.subtract(const Duration(minutes: 5));
      await location.getCurrentPosition();

      expect(geolocator.freshRequests, hasLength(2));
      expect(cache.memoryHits, 0);
    });
  });

  group("when the device can't do better", () {
    test('approximate permission: a ±2000 m fix answers the second lookup from level 1', () async {
      geolocator.accuracyStatus = LocationAccuracyStatus.reduced;
      geolocator.freshAccuracy = 2000;

      final first = await location.getCurrentPosition();
      now = now.add(const Duration(seconds: 5));
      final second = await location.getCurrentPosition();

      expect(second, same(first));
      expect((cache.memoryHits, cache.freshReads), (1, 1));
      expect(logs.last, contains('L1 accepted: approximate permission'));
    });

    test('approximate permission takes a coarse OS fix too, even for a high caller', () async {
      geolocator.accuracyStatus = LocationAccuracyStatus.reduced;
      final osFix = _position(at: now.subtract(const Duration(seconds: 10)), accuracy: 2000);
      geolocator.lastKnown = osFix;

      final position = await location.getCurrentPosition(accuracy: LocationAccuracy.high);

      expect(position, same(osFix));
      expect(geolocator.freshRequests, isEmpty);
      expect(logs.last, contains('L2 accepted: approximate permission'));
    });

    test('approximate or not is asked once, again on a new permission or invalidation', () async {
      geolocator.accuracyStatus = LocationAccuracyStatus.reduced;
      geolocator.freshAccuracy = 2000;

      await location.getCurrentPosition(); // a fresh reading: nothing to judge yet
      await location.getCurrentPosition(); // asks
      await location.getCurrentPosition(); // remembers
      expect(geolocator.accuracyStatusCalls, 1);

      geolocator.permission = LocationPermission.always;
      await location.getCurrentPosition();
      expect(geolocator.accuracyStatusCalls, 2);

      cache.invalidate();
      await location.getCurrentPosition(); // level 1 empty: a fresh reading
      await location.getCurrentPosition();
      expect(geolocator.accuracyStatusCalls, 3);
      expect((cache.memoryHits, cache.freshReads), (4, 2));
    });

    test('above the threshold but as precise as the last fresh reading: best available', () async {
      geolocator.freshAccuracy = 2000; // precise permission, but only network location

      final first = await location.getCurrentPosition();
      now = now.add(const Duration(seconds: 30));
      final second = await location.getCurrentPosition();

      expect(second, same(first));
      expect((cache.memoryHits, cache.freshReads), (1, 1));
      expect(logs.last, contains('L1 accepted: best available (last fresh ±2000 m)'));
    });

    test('a cached fix worse than the last fresh reading at that accuracy is a miss', () async {
      geolocator.freshAccuracy = 500;
      await location.getCurrentPosition(); // medium manages ±500 m

      geolocator.freshAccuracy = 2000;
      now = now.add(const Duration(seconds: 5));
      await location.getCurrentPosition(accuracy: LocationAccuracy.low); // ±2000 m into level 1

      now = now.add(const Duration(seconds: 5));
      await location.getCurrentPosition();

      expect(geolocator.freshRequests, hasLength(3));
      expect(cache.memoryHits, 0);
      expect(
        logs.last,
        contains('L1 rejected: accuracy too low (±2000 m, worse than last fresh ±500 m)'),
      );
    });

    test('best available lasts only while that fresh reading is under the TTL', () async {
      geolocator.freshAccuracy = 2000;
      await location.getCurrentPosition();

      now = now.add(PositionCache.ttl);
      final osFix = _position(at: now.subtract(const Duration(seconds: 5)), accuracy: 2000);
      geolocator.lastKnown = osFix;

      expect(await location.getCurrentPosition(), isNot(same(osFix)));
      expect(logs.last, contains('L1 rejected: TTL expired (age 60 s)'));
      expect(logs.last, contains('L2 rejected: accuracy too low (±2000 m > 100 m)'));
    });
  });

  group('level 2 (the OS last known position)', () {
    test('a recent, precise one answers without the GPS and moves to level 1', () async {
      final osFix = _position(
        at: now.subtract(const Duration(seconds: 20)),
        accuracy: 12,
        latitude: 4.7,
      );
      geolocator.lastKnown = osFix;

      final first = await location.getCurrentPosition();
      final second = await location.getCurrentPosition();

      expect(first, same(osFix));
      expect(second, same(osFix));
      expect(geolocator.freshRequests, isEmpty);
      expect(geolocator.lastKnownCalls, 1, reason: 'the second call was a level 1 hit');
      expect((cache.memoryHits, cache.systemHits, cache.freshReads), (1, 1, 0));
    });

    test('the same age and accuracy rules apply to it', () async {
      final tooOld = _position(at: now.subtract(PositionCache.ttl), accuracy: 10);
      final tooCoarse = _position(at: now, accuracy: 500);
      final fromTheFuture = _position(at: now.add(const Duration(minutes: 1)), accuracy: 10);

      for (final osFix in [tooOld, tooCoarse, fromTheFuture]) {
        geolocator.lastKnown = osFix;
        cache.invalidate();
        expect(await location.getCurrentPosition(), isNot(same(osFix)));
      }

      expect(cache.systemHits, 0);
      expect(geolocator.freshRequests, hasLength(3));
    });

    test('a platform without it (e.g. the web) is just a miss', () async {
      GeolocatorPlatform.instance = _NoLastKnown(() => now);

      expect(await location.getCurrentPosition(), isNotNull);
      expect(cache.freshReads, 1);
    });
  });

  test('both levels miss: a fresh reading with the 10 s limit, kept in level 1', () async {
    await location.getCurrentPosition();
    now = now.add(const Duration(minutes: 2));
    geolocator.lastKnown = _position(at: now.subtract(const Duration(minutes: 3)));

    final fresh = await location.getCurrentPosition();
    final next = await location.getCurrentPosition();

    expect(geolocator.freshRequests, hasLength(2));
    expect(geolocator.freshRequests.last?.timeLimit, LocationService.fixTimeLimit);
    expect(fresh?.timestamp, now);
    expect(next, same(fresh));
    expect((cache.memoryHits, cache.systemHits, cache.freshReads), (1, 0, 2));
  });

  group('skipping the cache', () {
    test('forceFresh reads the GPS with a valid fix in both levels, and keeps it', () async {
      geolocator.lastKnown = _position(at: now, accuracy: 10, latitude: 4.7);
      await location.getCurrentPosition();
      now = now.add(const Duration(seconds: 5));

      final forced = await location.getPosition(forceFresh: true);
      final next = await location.getCurrentPosition();

      expect(geolocator.freshRequests, hasLength(1));
      expect(geolocator.lastKnownCalls, 1, reason: 'forceFresh skips level 2 too');
      expect(forced?.latitude, 4.6);
      expect(next, same(forced));
      expect(logs, contains(contains('fresh reading (forced)')));
    });

    test('maxAge can make the TTL stricter, never longer', () async {
      await location.getCurrentPosition();
      now = now.add(const Duration(seconds: 30));

      await location.getPosition(maxAge: const Duration(seconds: 10));
      expect(geolocator.freshRequests, hasLength(2));

      await location.getPosition(maxAge: const Duration(seconds: 10));
      expect(cache.memoryHits, 1, reason: 'the new fix is 0 s old');

      now = now.add(PositionCache.ttl);
      await location.getPosition(maxAge: const Duration(minutes: 5));
      expect(geolocator.freshRequests, hasLength(3));
    });
  });

  group('never caches a null or an error', () {
    test('a reading without a fix is not kept: the next call reads again', () async {
      geolocator.timesOut = true;
      expect(await location.getCurrentPosition(), isNull);

      geolocator.timesOut = false;
      expect(await location.getCurrentPosition(), isNotNull);
      expect(geolocator.freshRequests, hasLength(2));
      expect(cache.memoryHits, 0);
    });

    test('a null does not replace a fix that still answers less demanding callers', () async {
      geolocator.freshAccuracy = 50;
      final medium = await location.getCurrentPosition();

      geolocator.timesOut = true;
      expect(await location.getCurrentPosition(accuracy: LocationAccuracy.high), isNull);

      expect(await location.getCurrentPosition(), same(medium));
    });

    test('an error from the reading reaches the caller and is not kept', () async {
      await expectLater(
        cache.get(
          accuracy: LocationAccuracy.medium,
          readFresh: () async => throw StateError('GPS'),
        ),
        throwsStateError,
      );

      final position = await cache.get(
        accuracy: LocationAccuracy.medium,
        readFresh: () async => _position(at: now),
      );

      expect(position, isNotNull);
      expect((cache.memoryHits, cache.freshReads), (0, 2));
    });
  });

  group('invalidation', () {
    test('signing out empties it: the next account reads the GPS again', () async {
      await location.getCurrentPosition();

      await AuthRepository(_FakeRemote(), _FakeLocal(), positionCache: cache).signOut();
      await location.getCurrentPosition();

      expect(geolocator.freshRequests, hasLength(2));
      expect(cache.memoryHits, 0);
    });

    test('a session the server ended (clearLocalData) empties it too', () async {
      await location.getCurrentPosition();

      await AuthRepository(_FakeRemote(), _FakeLocal(), positionCache: cache).clearLocalData();
      await location.getCurrentPosition();

      expect(geolocator.freshRequests, hasLength(2));
    });

    test('losing the permission empties it, so it stays empty if granted again', () async {
      await location.getCurrentPosition();

      geolocator.permission = LocationPermission.deniedForever;
      expect(await location.getCurrentPosition(), isNull);

      geolocator.permission = LocationPermission.whileInUse;
      await location.getCurrentPosition();
      expect(geolocator.freshRequests, hasLength(2));
      expect(cache.memoryHits, 0);
    });

    test('turning location off empties it too', () async {
      await location.getCurrentPosition();

      geolocator.serviceEnabled = false;
      expect(await location.getCurrentPosition(), isNull);

      geolocator.serviceEnabled = true;
      await location.getCurrentPosition();
      expect(geolocator.freshRequests, hasLength(2));
    });
  });

  test('consecutive ContextManager.snapshot() calls make ONE fresh reading', () async {
    final manager = ContextManager(
      locationService: location,
      batteryMonitor: _FullBattery(),
      connectivity: _Online(),
      weatherService: WeatherService(
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'current': {'weather_code': 3, 'temperature_2m': 18.0},
            }),
            200,
          ),
        ),
      ),
      now: () => now,
    );

    final latitudes = <double?>[];
    for (var i = 0; i < 5; i++) {
      latitudes.add((await manager.snapshot()).latitude);
      now = now.add(const Duration(seconds: 10));
    }

    expect(geolocator.freshRequests, hasLength(1));
    expect((cache.memoryHits, cache.freshReads), (4, 1));
    expect(latitudes, everyElement(4.6));
  });
}

/// geolocator_web has no last known position: it throws.
class _NoLastKnown extends _FakeGeolocator {
  _NoLastKnown(super.clock);

  @override
  Future<Position?> getLastKnownPosition({bool forceLocationManager = false}) =>
      throw UnsupportedError('getLastKnownPosition');
}
