import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../cache/memory_cache.dart';
import '../local/local_data_source.dart';

/// External service: OpenStreetMap Nominatim reverse geocoding. Turns
/// coordinates into a human-readable address. No API key needed, but
/// Nominatim's usage policy requires an identifying User-Agent and at most
/// one request per second.
///
/// - [addressFor]: a quest's full address. Kept in [LocalDataSource] by
///   coordinates: a fixed point's address doesn't change, so a quest seen once
///   online shows its address offline too.
/// - [areaFor]: where the user is right now, short ("road, neighbourhood,
///   city"), mirror of the Kotlin app's "📍 Near: ...". Kept in an in-memory
///   LRU by coordinates rounded to ~100 m, so the same area isn't requested
///   again while the app is open.
///
/// Requests are serialized and spaced by [minInterval] (rate limit, as in
/// Kotlin). Failures are never stored — one offline visit must not hide the
/// address for good.
class ReverseGeocodingService {
  static const _userAgent = 'SidequestsApp/1.0 (co.bmlab.sidequests)';
  static const defaultMinInterval = Duration(milliseconds: 1100);

  final LocalDataSource _localDataSource;
  final http.Client _client;
  final Duration _minInterval;
  final DateTime Function() _now;
  final MemoryCache<String, String> _areas = MemoryCache(
    ttl: const Duration(hours: 6),
    maxEntries: 32,
  );

  /// Tail of the request queue: each request waits for the previous one.
  Future<void> _queue = Future.value();
  DateTime? _lastRequestAt;

  ReverseGeocodingService({
    required LocalDataSource localDataSource,
    http.Client? client,
    Duration minInterval = defaultMinInterval,
    DateTime Function()? now,
  }) : _localDataSource = localDataSource,
       _client = client ?? http.Client(),
       _minInterval = minInterval,
       _now = now ?? DateTime.now;

  /// Returns the address, or null if the lookup fails (offline, rate limit…)
  /// and it was never resolved before.
  Future<String?> addressFor(double latitude, double longitude) async {
    // 5 decimals (~1 m): the same point, whatever float noise it carries.
    final key = '${latitude.toStringAsFixed(5)},${longitude.toStringAsFixed(5)}';
    final cached = _localDataSource.getAddress(key);
    if (cached != null) return cached;

    final json = await _fetch(latitude, longitude, zoom: '18');
    final address = json?['display_name'] as String?;

    if (address != null) {
      try {
        await _localDataSource.cacheAddress(key, address);
      } catch (_) {
        // Not cached this time; the address itself is still good to show.
      }
    }
    return address;
  }

  /// Short address of the area around the user, or null when it can't be
  /// resolved (the caller keeps the last one it had).
  Future<String?> areaFor(double latitude, double longitude) async {
    // 3 decimals (~100 m): the same area while the user walks around.
    final key = '${latitude.toStringAsFixed(3)},${longitude.toStringAsFixed(3)}';
    final cached = _areas.get(key);
    if (cached != null) return cached;

    final json = await _fetch(latitude, longitude, zoom: '17', addressDetails: true);
    final area = json == null ? null : formatArea(json);
    if (area != null) _areas.put(key, area);
    return area;
  }

  /// "road, neighbourhood, city", falling back to the first three parts of
  /// display_name. Same rule as the Kotlin app.
  static String? formatArea(Map<String, dynamic> json) {
    final address = (json['address'] as Map?)?.cast<String, dynamic>();
    String? first(List<String> keys) {
      for (final key in keys) {
        final value = address?[key];
        if (value is String && value.trim().isNotEmpty) return value.trim();
      }
      return null;
    }

    final parts = <String>[];
    for (final part in [
      first(['road', 'pedestrian', 'footway']),
      first(['neighbourhood', 'suburb', 'quarter', 'city_district']),
      first(['city', 'town', 'village']),
    ]) {
      if (part != null && !parts.contains(part)) parts.add(part);
    }
    if (parts.isNotEmpty) return parts.join(', ');

    final displayName = json['display_name'];
    if (displayName is! String || displayName.trim().isEmpty) return null;
    return displayName.split(',').take(3).map((p) => p.trim()).join(', ');
  }

  /// One request at a time, at least [_minInterval] apart. Null on any
  /// failure.
  Future<Map<String, dynamic>?> _fetch(
    double latitude,
    double longitude, {
    required String zoom,
    bool addressDetails = false,
  }) {
    final result = _queue.then((_) async {
      final last = _lastRequestAt;
      if (last != null) {
        final wait = _minInterval - _now().difference(last);
        if (wait > Duration.zero) await Future<void>.delayed(wait);
      }
      try {
        final uri = Uri.https('nominatim.openstreetmap.org', '/reverse', {
          'format': 'jsonv2',
          'lat': '$latitude',
          'lon': '$longitude',
          'zoom': zoom,
          if (addressDetails) 'addressdetails': '1',
          'accept-language': 'es',
        });
        final response = await _client
            .get(uri, headers: {'User-Agent': _userAgent})
            .timeout(const Duration(seconds: 8));
        if (response.statusCode != 200) return null;
        return (jsonDecode(response.body) as Map).cast<String, dynamic>();
      } catch (_) {
        return null;
      } finally {
        _lastRequestAt = _now();
      }
    });
    _queue = result.then((_) {}, onError: (Object _) {});
    return result;
  }
}
