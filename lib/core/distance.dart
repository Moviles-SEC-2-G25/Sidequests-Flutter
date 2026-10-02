import 'dart:math';

/// Great-circle distance between two coordinates, in kilometers.
double haversineKm(double lat1, double lon1, double lat2, double lon2) {
  const earthRadiusKm = 6371.0;
  final dLat = _degToRad(lat2 - lat1);
  final dLon = _degToRad(lon2 - lon1);
  final a =
      sin(dLat / 2) * sin(dLat / 2) +
      cos(_degToRad(lat1)) * cos(_degToRad(lat2)) * sin(dLon / 2) * sin(dLon / 2);
  final c = 2 * atan2(sqrt(a), sqrt(1 - a));
  return earthRadiusKm * c;
}

/// Same as [haversineKm], in meters (location check-in radius).
double haversineMeters(double lat1, double lon1, double lat2, double lon2) =>
    haversineKm(lat1, lon1, lat2, lon2) * 1000;

double _degToRad(double deg) => deg * pi / 180;
