import 'dart:convert';

import 'package:http/http.dart' as http;

import '../local/local_data_source.dart';

/// External service: OpenStreetMap Nominatim reverse geocoding. Turns a
/// quest's coordinates into a human-readable address. No API key needed, but
/// Nominatim's usage policy requires an identifying User-Agent.
///
/// Resolved addresses are kept in [LocalDataSource] by coordinates: a fixed
/// point's address doesn't change, so a quest seen once online shows its
/// address offline too, and repeat visits don't hit Nominatim's public,
/// rate-limited servers again. Failures are never stored — one offline
/// visit must not hide the address for good.
class ReverseGeocodingService {
  static const _userAgent = 'SidequestsApp/1.0 (co.bmlab.sidequests)';

  final LocalDataSource _localDataSource;
  final http.Client _client;

  ReverseGeocodingService({required LocalDataSource localDataSource, http.Client? client})
    : _localDataSource = localDataSource,
      _client = client ?? http.Client();

  /// Returns the address, or null if the lookup fails (offline, rate limit…)
  /// and it was never resolved before.
  Future<String?> addressFor(double latitude, double longitude) async {
    // 5 decimals (~1 m): the same point, whatever float noise it carries.
    final key = '${latitude.toStringAsFixed(5)},${longitude.toStringAsFixed(5)}';
    final cached = _localDataSource.getAddress(key);
    if (cached != null) return cached;

    final String? address;
    try {
      final uri = Uri.https('nominatim.openstreetmap.org', '/reverse', {
        'format': 'jsonv2',
        'lat': '$latitude',
        'lon': '$longitude',
        'zoom': '18',
        'accept-language': 'es',
      });
      final response = await _client
          .get(uri, headers: {'User-Agent': _userAgent})
          .timeout(const Duration(seconds: 8));
      if (response.statusCode != 200) return null;
      final json = jsonDecode(response.body) as Map<String, dynamic>;
      address = json['display_name'] as String?;
    } catch (_) {
      return null;
    }

    if (address != null) {
      try {
        await _localDataSource.cacheAddress(key, address);
      } catch (_) {
        // Not cached this time; the address itself is still good to show.
      }
    }
    return address;
  }
}
