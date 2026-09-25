import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sidequests/data/services/weather_service.dart';
import 'package:sidequests/models/weather_snapshot.dart';

Map<String, dynamic> _json({int code = 61, double temp = 18.4}) => {
  'current': {'weather_code': code, 'temperature_2m': temp},
  'hourly': {
    'precipitation_probability': [10, 40, 70],
  },
};

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
      expect(second, same(first));
    });

    test('returns null without cache on error, bad status or bad JSON', () async {
      for (final response in [http.Response('boom', 500), http.Response('not json', 200)]) {
        final service = WeatherService(client: MockClient((_) async => response));
        expect(await service.fetch(1, 1), isNull);
      }
      final throwing = WeatherService(client: MockClient((_) async => throw Exception('x')));
      expect(await throwing.fetch(1, 1), isNull);
    });
  });
}
