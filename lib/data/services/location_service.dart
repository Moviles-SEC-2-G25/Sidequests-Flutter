import 'package:geolocator/geolocator.dart';

import '../../core/verification/step_verification_strategy.dart';
import 'position_cache.dart';

/// Wraps the GPS sensor. Used by the Context Manager and by quest views
/// that need the device's current position (e.g. nearby/location-mode quests).
class LocationService {
  /// Without a limit a GPS that never answers would hang every caller, and
  /// ContextManager's callers all share one reading. The permission dialog
  /// isn't limited: that wait is up to the user.
  static const fixTimeLimit = Duration(seconds: 10);

  /// Recent fixes, so consecutive callers don't each wait for the GPS. app.dart
  /// gives one instance to ContextManager and the views, and its cache to
  /// AuthRepository, which clears it on sign-out.
  final PositionCache positionCache;

  LocationService({PositionCache? positionCache})
    : positionCache = positionCache ?? PositionCache();

  /// Returns the current position, or null if permission is denied, location
  /// services are disabled or no fix arrives within [fixTimeLimit]. Callers
  /// treat a null position the same way the backend treats a missing one:
  /// features degrade, they don't crash. A fix under a minute old and precise
  /// enough for [accuracy] is reused instead of read again (see [getPosition]).
  Future<Position?> getCurrentPosition({
    LocationAccuracy accuracy = LocationAccuracy.medium,
  }) => getPosition(accuracy: accuracy);

  /// [getCurrentPosition] for a caller that needs control over the cache:
  /// [forceFresh] always reads the GPS, [maxAge] only accepts a cached fix
  /// younger than it (stricter than PositionCache.ttl, never looser).
  ///
  /// Access is checked on every call, before the cache: with the GPS off or
  /// the permission gone the cache is emptied, so a fix kept from before is
  /// never handed out.
  Future<Position?> getPosition({
    LocationAccuracy accuracy = LocationAccuracy.medium,
    Duration? maxAge,
    bool forceFresh = false,
  }) async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      positionCache.invalidate();
      return null;
    }

    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      positionCache.invalidate();
      return null;
    }

    return positionCache.get(
      accuracy: accuracy,
      maxAge: maxAge,
      forceFresh: forceFresh,
      readFresh: () => _readFresh(accuracy),
    );
  }

  Future<Position?> _readFresh(LocationAccuracy accuracy) async {
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
