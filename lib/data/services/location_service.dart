import 'package:geolocator/geolocator.dart';

import '../../core/verification/step_verification_strategy.dart';

/// Wraps the GPS sensor. Used by the Context Manager and by quest views
/// that need the device's current position (e.g. nearby/location-mode quests).
class LocationService {
  /// Without a limit a GPS that never answers would hang every caller, and
  /// ContextManager's callers all share one reading. The permission dialog
  /// isn't limited: that wait is up to the user.
  static const fixTimeLimit = Duration(seconds: 10);

  /// Returns the current position, or null if permission is denied, location
  /// services are disabled or no fix arrives within [fixTimeLimit]. Callers
  /// treat a null position the same way the backend treats a missing one:
  /// features degrade, they don't crash.
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
        locationSettings: LocationSettings(accuracy: accuracy, timeLimit: fixTimeLimit),
      );
    } catch (_) {
      return null;
    }
  }

  /// GPS on + permission (asking if not decided yet) + precise location.
  /// Android 12+/iOS 14+ let users grant only an approximate location,
  /// which is too coarse for a 50 m check-in, so that's reported apart.
  Future<LocationAccess> ensureAccess() async {
    if (!await Geolocator.isLocationServiceEnabled()) return LocationAccess.serviceDisabled;

    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      return LocationAccess.denied;
    }

    try {
      final accuracy = await Geolocator.getLocationAccuracy();
      return accuracy == LocationAccuracyStatus.reduced
          ? LocationAccess.approximateOnly
          : LocationAccess.granted;
    } catch (_) {
      return LocationAccess.granted; // platform without the API: assume precise
    }
  }

  /// Emits only after moving [distanceFilter] meters — the OS does the
  /// filtering, so standing still costs nothing (vs. polling a fix).
  Stream<Position> positionStream({
    required LocationAccuracy accuracy,
    required int distanceFilter,
  }) => Geolocator.getPositionStream(
    locationSettings: LocationSettings(accuracy: accuracy, distanceFilter: distanceFilter),
  );
}
