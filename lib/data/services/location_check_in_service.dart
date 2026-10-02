import 'dart:async';

import 'package:geolocator/geolocator.dart';

import '../../core/distance.dart';
import '../../core/verification/check_in_sampling.dart';
import '../../core/verification/step_verification_strategy.dart';
import 'battery_monitor.dart';
import 'location_service.dart';

/// One GPS reading, without geolocator types leaking past this service.
class CheckInFix {
  final double latitude;
  final double longitude;
  final double accuracyMeters;

  const CheckInFix({
    required this.latitude,
    required this.longitude,
    required this.accuracyMeters,
  });
}

/// Watches the device position while the user walks to a quest, for the
/// automatic location check-in (feature c).
///
/// Uses a geolocator stream with a distanceFilter instead of polling, and
/// adapts it (see [checkInSampling]): coarse and sparse while far away,
/// precise in the last ~300 m, sparser on low battery. Re-subscribes only
/// when crossing that boundary, with hysteresis so GPS noise around 300 m
/// doesn't flip it back and forth.
class LocationCheckInService {
  /// Once precise, stays precise until this much farther than the switch
  /// distance.
  static const _hysteresisMeters = 100.0;

  final Future<LocationAccess> Function() _requestAccess;
  final Stream<CheckInFix> Function(CheckInPrecision precision, int distanceFilterMeters) _positions;
  final Future<bool> Function() _isLowBattery;

  final StreamController<CheckInFix> _controller = StreamController<CheckInFix>.broadcast();
  StreamSubscription<CheckInFix>? _subscription;
  ({double latitude, double longitude})? _target;
  CheckInPrecision? _precision;
  bool _isNear = false;

  /// Bumped on every start/stop so a start still awaiting the permission
  /// dialog can tell it was superseded.
  int _generation = 0;

  LocationCheckInService({
    LocationService? locationService,
    BatteryMonitor? batteryMonitor,
    Future<LocationAccess> Function()? requestAccess,
    Stream<CheckInFix> Function(CheckInPrecision precision, int distanceFilterMeters)? positions,
    Future<bool> Function()? isLowBattery,
  }) : _requestAccess = requestAccess ?? (locationService ?? LocationService()).ensureAccess,
       _positions = positions ?? _geolocatorPositions(locationService ?? LocationService()),
       _isLowBattery = isLowBattery ?? (batteryMonitor ?? BatteryMonitor()).isLow;

  /// Every fix while watching. Errors (e.g. GPS switched off mid-walk)
  /// are forwarded and stop the watch.
  Stream<CheckInFix> get fixes => _controller.stream;

  bool get isWatching => _subscription != null;

  /// The precision currently requested (null when not watching).
  CheckInPrecision? get precision => _precision;

  /// Asks for location access and, if granted, starts watching the way to
  /// ([latitude], [longitude]). Returns the access result either way.
  Future<LocationAccess> start({required double latitude, required double longitude}) async {
    stop();
    final generation = _generation;
    final access = await _requestAccess();
    if (generation != _generation || access != LocationAccess.granted) return access;

    _target = (latitude: latitude, longitude: longitude);
    await _subscribe(distanceMeters: null, generation: generation);
    return access;
  }

  void stop() {
    _generation++;
    _subscription?.cancel();
    _subscription = null;
    _target = null;
    _precision = null;
    _isNear = false;
  }

  Future<void> _subscribe({required double? distanceMeters, required int generation}) async {
    final lowBattery = await _safeIsLowBattery();
    if (generation != _generation) return;

    final sampling = checkInSampling(lowBattery: lowBattery, distanceMeters: distanceMeters);
    _subscription?.cancel();
    _precision = sampling.precision;
    _isNear = sampling.precision == CheckInPrecision.precise;
    _subscription = _positions(sampling.precision, sampling.distanceFilterMeters).listen(
      _onFix,
      onError: (Object error) {
        stop();
        _controller.addError(error);
      },
    );
  }

  void _onFix(CheckInFix fix) {
    final target = _target;
    if (target == null) return;
    _controller.add(fix);

    final distance = haversineMeters(fix.latitude, fix.longitude, target.latitude, target.longitude);
    final shouldBeNear = _isNear
        ? distance <= kCheckInNearMeters + _hysteresisMeters
        : distance <= kCheckInNearMeters;
    if (shouldBeNear != _isNear) {
      // Flip now: more fixes may arrive while the battery read is pending,
      // and they must not each trigger another re-subscription.
      _isNear = shouldBeNear;
      unawaited(_subscribe(distanceMeters: distance, generation: _generation));
    }
  }

  // A missing battery API must never stop the check-in (as in ContextManager).
  Future<bool> _safeIsLowBattery() async {
    try {
      return await _isLowBattery();
    } catch (_) {
      return false;
    }
  }

  static Stream<CheckInFix> Function(CheckInPrecision, int) _geolocatorPositions(
    LocationService locationService,
  ) => (precision, distanceFilterMeters) => locationService
      .positionStream(
        accuracy: switch (precision) {
          CheckInPrecision.coarse => LocationAccuracy.low,
          CheckInPrecision.balanced => LocationAccuracy.medium,
          CheckInPrecision.precise => LocationAccuracy.high,
        },
        distanceFilter: distanceFilterMeters,
      )
      .map(
        (position) => CheckInFix(
          latitude: position.latitude,
          longitude: position.longitude,
          accuracyMeters: position.accuracy,
        ),
      );

  void dispose() {
    stop();
    _controller.close();
  }
}
