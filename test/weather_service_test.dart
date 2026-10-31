import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sidequests/data/local/local_data_source.dart';
import 'package:sidequests/data/services/weather_service.dart';
import 'package:sidequests/models/weather_snapshot.dart';

Map<String, dynamic> _json({int code = 61, double temp = 18.4}) => {
  'current': {'weather_code': code, 'temperature_2m': temp},
  'hourly': {
    'precipitation_probability': [10, 40, 70],
  },
};

class _BrokenLocal implements LocalDataSource {
  @override
  Map<String, dynamic>? getWeatherSnapshot(String coordinatesKey) =>
      throw const FileSystemException('box is gone');

  @override
  Future<void> cacheWeatherSnapshot(String coordinatesKey, Map<String, dynamic> snapshot) =>
      throw const FileSystemException('disk full');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  final fetchedAt = DateTime(2026, 1, 1, 12);

  group('parseOpenMeteo', () {
    test('maps Open-Meteo JSON to WeatherSnapshot', () {
      final s = WeatherService.parseOpenMeteo(_json(), fetchedAt: fetchedAt);
      expect(s.weatherCode, 61);
      expect(s.temperatureC, 18.4);
      expect(s.precipitationProbabilityNext3h, [10, 40, 70]);
      expect(s.maxPrecipitationProbability, 70);
      expect(s.fetchedAt, fetchedAt);
      expect(s.description, 'Lluvia ligera');
      expect(s.isRainy, isTrue);
    });

    test('accepts integer temperature and missing hourly data', () {
      final s = WeatherService.parseOpenMeteo({
        'current': {'weather_code': 0, 'temperature_2m': 20},
      }, fetchedAt: fetchedAt);
      expect(s.temperatureC, 20.0);
      expect(s.precipitationProbabilityNext3h, isEmpty);
      expect(s.isRainy, isFalse);
      expect(s.description, 'Despejado');
    });

    test('isRainy follows WMO ranges 51-67, 80-82, 95-99', () {
      bool rainy(int code) => WeatherSnapshot(
        weatherCode: code,
        temperatureC: 0,
        precipitationProbabilityNext3h: const [],
        fetchedAt: fetchedAt,
      ).isRainy;
      for (final c in [51, 67, 80, 82, 95, 99]) {
        expect(rainy(c), isTrue, reason: '$c');
      }
      for (final c in [0, 3, 45, 50, 68, 71, 79, 83, 94]) {
        expect(rainy(c), isFalse, reason: '$c');
      }
    });
  });

  group('WeatherService.fetch', () {
    test('caches by coordinates rounded to 2 decimals', () async {
      var calls = 0;
      final service = WeatherService(
        client: MockClient((_) async {
          calls++;
          return http.Response(jsonEncode(_json()), 200);
        }),
      );
      await service.fetch(4.6012, -74.0601);
      await service.fetch(4.6049, -74.0649); // both round to (4.60, -74.06)
      expect(calls, 1);
      await service.fetch(4.65, -74.06);
      expect(calls, 2);
    });

    test('refetches after TTL and falls back to stale cache on error', () async {
      var now = fetchedAt;
      var fail = false;
      final service = WeatherService(
        now: () => now,
        client: MockClient((_) async {
          if (fail) throw http.ClientException('offline');
          return http.Response(jsonEncode(_json(temp: 10)), 200);
        }),
      );
      final first = await service.fetch(4.6, -74.0);
      now = now.add(const Duration(minutes: 16));
      fail = true;
      final second = await service.fetch(4.6, -74.0);
      expect(first!.isStale, isFalse);
      expect(second!.isStale, isTrue);
      expect(second.temperatureC, first.temperatureC);
      expect(second.fetchedAt, first.fetchedAt);
    });

    test('returns null without cache on error, bad status or bad JSON', () async {
      for (final response in [http.Response('boom', 500), http.Response('not json', 200)]) {
        final service = WeatherService(client: MockClient((_) async => response));
        expect(await service.fetch(1, 1), isNull);
      }
      final throwing = WeatherService(client: MockClient((_) async => throw Exception('x')));
      expect(await throwing.fetch(1, 1), isNull);
    });

    test('under the TTL answers from memory, as fresh, without the network', () async {
      var now = fetchedAt;
      var calls = 0;
      final service = WeatherService(
        now: () => now,
        client: MockClient((_) async {
          calls++;
          return http.Response(jsonEncode(_json()), 200);
        }),
      );
      await service.fetch(4.6, -74.0);
      now = now.add(const Duration(minutes: 14));

      final second = await service.fetch(4.6, -74.0);

      expect(calls, 1);
      expect(second!.isStale, isFalse);
    });

    test('discards the in-memory value at 6 h too', () async {
      var now = fetchedAt;
      var fail = false;
      final service = WeatherService(
        now: () => now,
        client: MockClient((_) async {
          if (fail) throw http.ClientException('offline');
          return http.Response(jsonEncode(_json()), 200);
        }),
      );
      await service.fetch(4.6, -74.0);
      fail = true;
      now = now.add(WeatherService.fallbackMaxAge);

      expect(await service.fetch(4.6, -74.0), isNull);
    });
  });

  group('WeatherService persistence (real Hive box on disk)', () {
    const lat = 4.6012;
    const lon = -74.0601;

    late Directory documents;
    late LocalDataSource local;
    late DateTime now;
    late bool offline;
    late int requests;

    const pathProvider = MethodChannel('plugins.flutter.io/path_provider');

    /// A new service over a box reopened from disk: what an app restart leaves.
    Future<WeatherService> restart({double networkTemp = 10}) async {
      await Hive.close();
      local = LocalDataSource();
      await local.init();
      return WeatherService(
        localDataSource: local,
        now: () => now,
        client: MockClient((_) async {
          requests++;
          if (offline) throw http.ClientException('offline');
          return http.Response(jsonEncode(_json(temp: networkTemp)), 200);
        }),
      );
    }

    setUp(() async {
      TestWidgetsFlutterBinding.ensureInitialized();
      documents = await Directory.systemTemp.createTemp('weather_test');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        pathProvider,
        (_) async => documents.path,
      );
      SharedPreferences.setMockInitialValues({});
      now = fetchedAt;
      offline = false;
      requests = 0;
    });

    tearDown(() async {
      await Hive.close();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        pathProvider,
        null,
      );
      await documents.delete(recursive: true);
    });

    test('after a restart offline, returns the persisted reading as stale', () async {
      final online = await restart();
      final original = await online.fetch(lat, lon);
      now = now.add(const Duration(hours: 2));
      offline = true;

      final restored = await (await restart()).fetch(lat, lon);

      expect(original!.isStale, isFalse);
      expect(restored!.isStale, isTrue);
      expect(restored.weatherCode, 61);
      expect(restored.temperatureC, 10);
      expect(restored.precipitationProbabilityNext3h, [10, 40, 70]);
      expect(restored.fetchedAt.isAtSameMomentAs(fetchedAt), isTrue);
    });

    test('a reading persisted minutes ago is still stale: the network failed', () async {
      await (await restart()).fetch(lat, lon);
      now = now.add(const Duration(minutes: 1));
      offline = true;

      final service = await restart();
      final restored = await service.fetch(lat, lon);
      final again = await service.fetch(lat, lon);

      expect(restored!.isStale, isTrue);
      expect(again!.isStale, isTrue);
      // Each call tried the network first: a fallback never counts as cached.
      expect(requests, 3);
    });

    test('uses the same rounded key, and only for that cell', () async {
      await (await restart()).fetch(lat, lon);
      offline = true;

      final service = await restart();

      expect(await service.fetch(4.6049, -74.0649), isNotNull); // also (4.60, -74.06)
      expect(await service.fetch(4.65, -74.06), isNull);
    });

    test('discards a persisted reading of 6 h or more', () async {
      await (await restart()).fetch(lat, lon);
      offline = true;

      now = fetchedAt.add(WeatherService.fallbackMaxAge - const Duration(minutes: 1));
      expect(await (await restart()).fetch(lat, lon), isNotNull);

      now = fetchedAt.add(WeatherService.fallbackMaxAge);
      expect(await (await restart()).fetch(lat, lon), isNull);
    });

    test('discards a reading from the future (the clock moved back)', () async {
      await (await restart()).fetch(lat, lon);
      offline = true;
      now = fetchedAt.subtract(const Duration(hours: 1));

      expect(await (await restart()).fetch(lat, lon), isNull);
    });

    test('with a connection the network wins over the persisted reading', () async {
      await (await restart(networkTemp: 10)).fetch(lat, lon);
      now = now.add(const Duration(minutes: 1)); // persisted one is recent

      final fresh = await (await restart(networkTemp: 25)).fetch(lat, lon);

      expect(requests, 2);
      expect(fresh!.temperatureC, 25);
      expect(fresh.isStale, isFalse);

      // ...and it replaced the persisted one.
      offline = true;
      expect((await (await restart()).fetch(lat, lon))!.temperatureC, 25);
    });

    test('a server error falls back like a dropped connection', () async {
      await (await restart()).fetch(lat, lon);
      await Hive.close();
      local = LocalDataSource();
      await local.init();
      final service = WeatherService(
        localDataSource: local,
        now: () => now,
        client: MockClient((_) async => http.Response('boom', 500)),
      );

      expect((await service.fetch(lat, lon))!.isStale, isTrue);
    });

    test('a corrupt persisted entry counts as no data, it does not throw', () async {
      final service = await restart();
      await local.cacheWeatherSnapshot('4.60,-74.06', {'weather_code': 'not a number'});
      offline = true;

      expect(await service.fetch(lat, lon), isNull);
    });

    test('signing out clears the persisted readings', () async {
      await (await restart()).fetch(lat, lon);
      await local.clear();
      offline = true;

      expect(await (await restart()).fetch(lat, lon), isNull);
    });
  });

  test('a failed Hive write still returns the reading', () async {
    final service = WeatherService(
      localDataSource: _BrokenLocal(),
      client: MockClient((_) async => http.Response(jsonEncode(_json()), 200)),
    );

    final snapshot = await service.fetch(4.6, -74.0);

    expect(snapshot!.isStale, isFalse);
    expect(snapshot.weatherCode, 61);
  });

  test('a failed Hive read counts as no data, it does not throw', () async {
    final service = WeatherService(
      localDataSource: _BrokenLocal(),
      client: MockClient((_) async => throw http.ClientException('offline')),
    );

    expect(await service.fetch(4.6, -74.0), isNull);
  });
}
