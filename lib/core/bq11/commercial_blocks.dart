import 'dart:math' as math;

/// BQ11 pilot areas: the same two blocks, ids and boundaries as Kotlin's
/// Bq11Blocks (Sidequests-Kotlin), so both apps report the same block ids.
/// Pilot geometries, not official property boundaries.
const kBq11UsaquenBlockId = 'usaquen-cra6a-c119';
const kBq11PaloquemaoBlockId = 'paloquemao-market';

/// A fix is only usable with an accuracy in this range, in meters (Kotlin's
/// `accuracyMeters in 1f..25f`).
const kBq11MinAccuracyMeters = 1.0;
const kBq11MaxAccuracyMeters = 25.0;

typedef _LatLng = ({double lat, double lon});

const _blocks = <(String, List<_LatLng>)>[
  // OSM way 88958128, the Carrera 6A segment north of Calle 119 at the flea market.
  (kBq11UsaquenBlockId, [
    (lat: 4.69552, lon: -74.03123),
    (lat: 4.69602, lon: -74.03101),
    (lat: 4.69593, lon: -74.03082),
    (lat: 4.69546, lon: -74.03102),
  ]),
  // OSM way 713156703, simplified outline of Plaza de Mercado de Paloquemao.
  (kBq11PaloquemaoBlockId, [
    (lat: 4.6150192, lon: -74.0841617),
    (lat: 4.6157865, lon: -74.0835081),
    (lat: 4.6161066, lon: -74.0837123),
    (lat: 4.6160390, lon: -74.0834997),
    (lat: 4.6164444, lon: -74.0834288),
    (lat: 4.6165365, lon: -74.0836106),
    (lat: 4.6169511, lon: -74.0837893),
    (lat: 4.6175530, lon: -74.0843562),
    (lat: 4.6166471, lon: -74.0847598),
    (lat: 4.6160083, lon: -74.0846366),
    (lat: 4.6153822, lon: -74.0844676),
  ]),
];

/// The pilot block a fix falls in, or null: outside both, too imprecise, or
/// (never with these two) inside more than one. Pure, like Kotlin's match().
String? commercialBlockAt(double latitude, double longitude, double accuracyMeters) {
  final usableAccuracy =
      accuracyMeters >= kBq11MinAccuracyMeters && accuracyMeters <= kBq11MaxAccuracyMeters;
  if (!latitude.isFinite || !longitude.isFinite || !usableAccuracy) return null;
  String? match;
  for (final (id, boundary) in _blocks) {
    if (!_includes(boundary, latitude, longitude, accuracyMeters)) continue;
    if (match != null) return null;
    match = id;
  }
  return match;
}

/// Kotlin's algorithm: vertices projected into local meters from the fix,
/// ray casting for "inside", and the accuracy as an inward buffer, so a fix
/// whose uncertainty reaches an edge doesn't count.
bool _includes(List<_LatLng> boundary, double lat, double lon, double accuracy) {
  final lonMeters = 111320 * math.cos(lat * math.pi / 180);
  final points = [
    for (final point in boundary) (x: (point.lon - lon) * lonMeters, y: (point.lat - lat) * 110540),
  ];
  var inside = false;
  for (var i = 0; i < points.length; i++) {
    final (:x, :y) = points[i];
    final next = points[(i + 1) % points.length];
    if ((y > 0) != (next.y > 0) && x - y * (next.x - x) / (next.y - y) > 0) inside = !inside;
    final dx = next.x - x;
    final dy = next.y - y;
    final t = (-(x * dx + y * dy) / (dx * dx + dy * dy)).clamp(0.0, 1.0);
    final nearestX = x + t * dx;
    final nearestY = y + t * dy;
    if (math.sqrt(nearestX * nearestX + nearestY * nearestY) < accuracy) return false;
  }
  return inside;
}
