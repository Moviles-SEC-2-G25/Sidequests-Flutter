import 'package:geolocator/geolocator.dart';

/// One BQ11 reading, without geolocator types leaking past this file.
class Bq11Fix {
  final double latitude;
  final double longitude;
  final double accuracyMeters;
  final DateTime fixTime;
  final bool isMocked;

  const Bq11Fix({
    required this.latitude,
    required this.longitude,
    required this.accuracyMeters,
    required this.fixTime,
    this.isMocked = false,
  });
}

/// Reads one fresh fix, or null. Injectable for tests.
typedef Bq11FixReader = Future<Bq11Fix?> Function();

/// Kotlin's freshBq11Fix: a new high-accuracy fix (never a cached one), given
/// up after 8 s. Never asks for the permission — that happens once, when the
/// user turns sharing on — so a revoked permission just means no reading.
Future<Bq11Fix?> readBq11Fix() async {
  try {
    final permission = await Geolocator.checkPermission();
    if (permission != LocationPermission.always && permission != LocationPermission.whileInUse) {
      return null;
    }
    final position = await Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        timeLimit: Duration(seconds: 8),
      ),
    );
    return Bq11Fix(
      latitude: position.latitude,
      longitude: position.longitude,
      accuracyMeters: position.accuracy,
      fixTime: position.timestamp,
      isMocked: position.isMocked,
    );
  } catch (_) {
    return null;
  }
}
