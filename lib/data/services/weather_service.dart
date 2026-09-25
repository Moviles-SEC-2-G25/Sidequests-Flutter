import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../models/weather_snapshot.dart';

/// Adapter over the Open-Meteo forecast API (no API key). It is the only
/// place that knows Open-Meteo's JSON; callers get a [WeatherSnapshot].
///
/// Tactics: in-memory cache keyed by coordinates rounded to 2 decimals
/// (~1 km) with a 15 min TTL, a 5 s request timeout, and graceful
/// degradation — [fetch] never throws: on any failure it returns the last
/// cached value for that key (even if stale) or null.
class WeatherService {
  static const cacheTtl = Duration(minutes: 15);
  static const requestTimeout = Duration(seconds: 5);

  final http.Client _client;
  final DateTime Function() _now;
  final Map<String, WeatherSnapshot> _cache = {};

  WeatherService({http.Client? client, DateTime Function()? now})
    : _client = client ?? http.Client(),
      _now = now ?? DateTime.now;

  Future<WeatherSnapshot?> fetch(double latitude, double longitude) async {
    final key = _cacheKey(latitude, longitude);
    final cached = _cache[key];
    if (cached != null && _now().difference(cached.fetchedAt) < cacheTtl) {
      return cached;
    }

    try {
      final uri = Uri.https('api.open-meteo.com', '/v1/forecast', {
        'latitude': latitude.toStringAsFixed(2),
        'longitude': longitude.toStringAsFixed(2),
        'current': 'weather_code,temperature_2m',
        'hourly': 'precipitation_probability',
        'forecast_hours': '3',
        'timezone': 'auto',
      });
      final response = await _client.get(uri).timeout(requestTimeout);
      if (response.statusCode != 200) return cached;
      final json = jsonDecode(response.body) as Map<String, dynamic>;
      final snapshot = parseOpenMeteo(json, fetchedAt: _now());
      _cache[key] = snapshot;
      return snapshot;
    } catch (_) {
      return cached;
    }
  }

  /// Open-Meteo JSON -> domain model. Throws on a malformed payload
  /// ([fetch] catches it).
  @visibleForTesting
  static WeatherSnapshot parseOpenMeteo(
    Map<String, dynamic> json, {
    required DateTime fetchedAt,
  }) {
    final current = json['current'] as Map<String, dynamic>;
    final hourly = json['hourly'] as Map<String, dynamic>?;
    final probabilities = (hourly?['precipitation_probability'] as List? ?? const [])
        .whereType<num>()
        .map((p) => p.toInt())
        .take(3)
        .toList();
    return WeatherSnapshot(
      weatherCode: (current['weather_code'] as num).toInt(),
      temperatureC: (current['temperature_2m'] as num).toDouble(),
      precipitationProbabilityNext3h: probabilities,
      fetchedAt: fetchedAt,
    );
  }

  static String _cacheKey(double latitude, double longitude) =>
      '${latitude.toStringAsFixed(2)},${longitude.toStringAsFixed(2)}';
}
