import 'package:geolocator/geolocator.dart';

/// Wraps the GPS sensor. Used by the Context Manager and by quest views
/// that need the device's current position (e.g. nearby/location-mode quests).
class LocationService {
  /// Returns the current position, or null if permission is denied or
  /// location services are disabled. Callers treat a null position the same
  /// way the backend treats a missing one: features degrade, they don't crash.
  Future<Position?> getCurrentPosition({
    LocationAccuracy accuracy = LocationAccuracy.medium,
  }) async {
    if (!await Geolocator.isLocationServiceEnabled()) return null;

    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      return null;
    }

    try {
      return await Geolocator.getCurrentPosition(
        locationSettings: LocationSettings(accuracy: accuracy),
      );
    } catch (_) {
      return null;
    }
  }
}
