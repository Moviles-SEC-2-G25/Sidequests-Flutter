import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../models/weather_snapshot.dart';
import '../local/local_data_source.dart';

/// Adapter over the Open-Meteo forecast API (no API key). It is the only
/// place that knows Open-Meteo's JSON; callers get a [WeatherSnapshot].
///
/// Tactics: in-memory cache keyed by coordinates rounded to 2 decimals
/// (~1 km) with a 15 min TTL, a 5 s request timeout, and network falling
/// back to cache — every reading is also kept in [LocalDataSource] under the
/// same key, so it survives an app restart. [fetch] never throws: on any
/// failure it returns the last known value for that key, marked
/// [WeatherSnapshot.isStale], or null if that's too old or there is none.
/// Without a local data source (tests) only the in-memory value is left.
class WeatherService {
  static const cacheTtl = Duration(minutes: 15);
  static const requestTimeout = Duration(seconds: 5);

  /// Past this, the last known weather says nothing about the current one.
  static const fallbackMaxAge = Duration(hours: 6);

  final http.Client _client;
  final DateTime Function() _now;
  final LocalDataSource? _localDataSource;
  final Map<String, WeatherSnapshot> _cache = {};

  WeatherService({http.Client? client, DateTime Function()? now, LocalDataSource? localDataSource})
    : _client = client ?? http.Client(),
      _now = now ?? DateTime.now,
      _localDataSource = localDataSource;

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
      if (response.statusCode != 200) return _lastKnown(key);
      final json = jsonDecode(response.body) as Map<String, dynamic>;
      final snapshot = parseOpenMeteo(json, fetchedAt: _now());
      _cache[key] = snapshot;
      await _persist(key, snapshot);
      return snapshot;
    } catch (_) {
      return _lastKnown(key);
    }
  }

  /// Never stored in [_cache]: the TTL check above would pass a recent
  /// persisted value off as fresh and skip the network.
  WeatherSnapshot? _lastKnown(String key) {
    final snapshot = _cache[key] ?? _readPersisted(key);
    if (snapshot == null) return null;
    final age = _now().difference(snapshot.fetchedAt);
    // Negative: the device clock moved back, so its real age is unknown.
    return age.isNegative || age >= fallbackMaxAge ? null : snapshot.asStale();
  }

  WeatherSnapshot? _readPersisted(String key) {
    try {
      final json = _localDataSource?.getWeatherSnapshot(key);
      return json == null ? null : WeatherSnapshot.fromJson(json);
    } catch (_) {
      return null;
    }
  }

  Future<void> _persist(String key, WeatherSnapshot snapshot) async {
    try {
      await _localDataSource?.cacheWeatherSnapshot(key, snapshot.toJson());
    } catch (_) {
      // Not persisted this time; the reading itself is still good to show.
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
