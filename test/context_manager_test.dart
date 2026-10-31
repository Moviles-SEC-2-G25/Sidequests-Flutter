import 'dart:async';
import 'dart:convert';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sidequests/data/context/context_manager.dart';
import 'package:sidequests/data/services/battery_monitor.dart';
import 'package:sidequests/data/services/location_service.dart';
import 'package:sidequests/data/services/weather_service.dart';

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

/// Counts GPS requests; with a [gate], each stays open until it's completed.
class _FakeLocation extends LocationService {
  Completer<Position?>? gate;
  Object? error;
  int calls = 0;
  LocationAccuracy? lastAccuracy;

  @override
  Future<Position?> getCurrentPosition({
    LocationAccuracy accuracy = LocationAccuracy.medium,
  }) async {
    calls++;
    lastAccuracy = accuracy;
    if (error != null) throw error!;
    return gate == null ? _position() : gate!.future;
  }
}

class _FakeBattery extends BatteryMonitor {
  bool low = false;

  @override
  Future<bool> isLow() async => low;
}

class _FakeConnectivity implements Connectivity {
  Completer<List<ConnectivityResult>>? gate;
  List<ConnectivityResult> current = const [ConnectivityResult.wifi];
  int calls = 0;

  @override
  Future<List<ConnectivityResult>> checkConnectivity() async {
    calls++;
    return gate == null ? current : gate!.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late _FakeLocation location;
  late _FakeBattery battery;
  late _FakeConnectivity connectivity;
  late int weatherCalls;
  late ContextManager manager;

  setUp(() {
    location = _FakeLocation();
    battery = _FakeBattery();
    connectivity = _FakeConnectivity();
    weatherCalls = 0;
    manager = ContextManager(
      locationService: location,
      batteryMonitor: battery,
      connectivity: connectivity,
      weatherService: WeatherService(
        client: MockClient((_) async {
          weatherCalls++;
          return http.Response(
            jsonEncode({
              'current': {'weather_code': 61, 'temperature_2m': 18.4},
            }),
            200,
          );
        }),
      ),
    );
  });

  group('parallel reading', () {
    test('connectivity is checked while the GPS is still working', () async {
      location.gate = Completer<Position?>();

      final snapshot = manager.snapshot();
      await pumpEventQueue();

      expect(location.calls, 1);
      expect(connectivity.calls, 1);

      location.gate!.complete(_position());
      expect((await snapshot).isConnected, isTrue);
    });

    test('the GPS and weather chain does not wait for connectivity', () async {
      connectivity.gate = Completer<List<ConnectivityResult>>();

      final snapshot = manager.snapshot();
      await pumpEventQueue();

      expect(location.calls, 1);
      expect(weatherCalls, 1);

      connectivity.gate!.complete(const [ConnectivityResult.none]);
      expect((await snapshot).isConnected, isFalse);
    });

    test('the chain keeps its order: battery sets the accuracy, the fix asks for weather', () async {
      battery.low = true;

      final context = await manager.snapshot();

      expect(location.lastAccuracy, LocationAccuracy.low);
      expect(context.latitude, 4.6);
      expect(context.weatherCode, 61);
      expect(context.isRainy, isTrue);
    });

    test('without a fix there is no weather request', () async {
      location.gate = Completer<Position?>()..complete(null);

      final context = await manager.snapshot();

      expect(weatherCalls, 0);
      expect(context.hasLocation, isFalse);
      expect(context.weatherCode, isNull);
    });
  });

  group('single-flight', () {
    test('simultaneous callers share one reading of each sensor', () async {
      location.gate = Completer<Position?>();

      final snapshots = [manager.snapshot(), manager.snapshot(), manager.snapshot()];
      await pumpEventQueue();
      location.gate!.complete(_position());
      final contexts = await Future.wait(snapshots);

      expect(location.calls, 1);
      expect(connectivity.calls, 1);
      expect(weatherCalls, 1);
      expect(contexts.map((c) => c.latitude), [4.6, 4.6, 4.6]);
    });

    test('a caller joining a reading already under way shares it too', () async {
      location.gate = Completer<Position?>();

      final first = manager.snapshot();
      await pumpEventQueue();
      final second = manager.snapshot();
      await pumpEventQueue();
      location.gate!.complete(_position());
      await Future.wait([first, second]);

      expect(location.calls, 1);
    });

    test('availableMinutes stays per caller, never shared', () async {
      location.gate = Completer<Position?>();

      final thirty = manager.snapshot(availableMinutes: 30);
      final sixty = manager.snapshot(availableMinutes: 60);
      final none = manager.snapshot();
      await pumpEventQueue();
      location.gate!.complete(_position());

      expect((await thirty).availableMinutes, 30);
      expect((await sixty).availableMinutes, 60);
      expect((await none).availableMinutes, isNull);
    });

    test('it is not a cache: a call after the reading finished reads again', () async {
      final first = await manager.snapshot();
      connectivity.current = const [ConnectivityResult.none];
      final second = await manager.snapshot();

      expect(location.calls, 2);
      expect(connectivity.calls, 2);
      expect(first.isConnected, isTrue);
      expect(second.isConnected, isFalse);
    });

    test('a failed reading reaches every caller and is not kept', () async {
      location.error = StateError('GPS');

      final first = manager.snapshot();
      final second = manager.snapshot();
      await expectLater(first, throwsStateError);
      await expectLater(second, throwsStateError);
      expect(location.calls, 1);

      location.error = null;
      final recovered = await manager.snapshot();
      expect(location.calls, 2);
      expect(recovered.latitude, 4.6);
    });
  });
}
