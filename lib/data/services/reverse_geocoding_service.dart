import 'dart:convert';

import 'package:http/http.dart' as http;

/// External service: OpenStreetMap Nominatim reverse geocoding. Turns a
/// quest's coordinates into a human-readable address. No API key needed, but
/// Nominatim's usage policy requires an identifying User-Agent.
class ReverseGeocodingService {
  static const _userAgent = 'SidequestsApp/1.0 (co.bmlab.sidequests)';

  final http.Client _client;

  ReverseGeocodingService({http.Client? client}) : _client = client ?? http.Client();

  /// Returns the address, or null if the lookup fails (offline, rate limit…).
  Future<String?> addressFor(double latitude, double longitude) async {
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
      return json['display_name'] as String?;
    } catch (_) {
      return null;
    }
  }
}
