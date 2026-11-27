import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

/// Caching strategy (Alejandro, Sprint 4): a two-level cache in front of the
/// GPS, so consecutive context snapshots reuse a recent fix instead of each
/// turning the radio on for a new one.
///
/// Problem: every ContextManager.snapshot() asked for a new fix (up to
/// LocationService.fixTimeLimit = 10 s of GPS), and snapshot() runs for every
/// analytics event, every recommendation load and the weather card. Its
/// single-flight only merges readings that overlap in time; one that started
/// right after another finished paid for a fix of its own.
///
/// - Level 1 (memory): the last position this app obtained.
/// - Level 2 (OS): Geolocator.getLastKnownPosition(), the fix the OS already
///   has, maybe from another app. When it's accepted it moves to level 1.
/// - Both miss: a new reading, which is kept in level 1. A null (no fix,
///   timeout) or an error is never kept.
///
/// A position from either level answers only when, by its own timestamp, it
/// is younger than [ttl] (60 s; a negative age, from a device clock moved
/// back, is a miss: the real age is unknown) and it's precise enough:
/// - its accuracy radius is within [coarseAccuracyMeters] (100 m) for
///   lowest/low/medium, [preciseAccuracyMeters] (30 m) for high and better, so
///   a coarse fix never answers a caller that needs a precise one; or
/// - the user granted only an approximate location: any radius, the device
///   can't do better. Asked to the OS once, until the permission changes or
///   the cache is invalidated; or
/// - "best available": the last new reading at the accuracy asked, still under
///   [ttl], missed the threshold too, and this one is at least as precise.
/// Without the last two, a phone giving only ±2 km (network location,
/// indoors) rejected every cached fix and read the GPS on every lookup.
///
/// Why not MemoryCache: that one keeps network data by key and ages it from
/// when it was stored, bounded by LRU size. Here there's one value, a sensor
/// reading, and whether it can be reused depends on the reading itself: when
/// it was taken (not stored: an OS fix may already be old when it arrives) and
/// how precise it is. A reading also can't go stale on a server, but it does
/// when the user walks, hence a TTL of seconds instead of minutes.
class PositionCache {
  static const ttl = Duration(seconds: 60);
  static const coarseAccuracyMeters = 100.0;
  static const preciseAccuracyMeters = 30.0;

  final DateTime Function() _now;
  final void Function(String message) _log;
  Position? _position;

  /// The last new reading per accuracy asked: what the device managed lately.
  final _lastFresh = <LocationAccuracy, Position>{};

  /// What [_accuracyStatus] was read under; a different one means asking again.
  LocationPermission? _permission;
  LocationAccuracyStatus? _accuracyStatus;

  int _memoryHits = 0;
  int _systemHits = 0;
  int _freshReads = 0;

  /// [log] receives a line with the outcome, why each level answered or not,
  /// and the counters after every lookup; by default it's debugPrint, and
  /// only in debug builds.
  PositionCache({DateTime Function()? now, void Function(String message)? log})
    : _now = now ?? DateTime.now,
      _log = log ?? _debugLog;

  /// Lookups answered by level 1 (memory).
  int get memoryHits => _memoryHits;

  /// Lookups answered by level 2 (the OS's last known position).
  int get systemHits => _systemHits;

  /// New GPS readings started, including those that ended without a fix.
  /// Without this cache, every lookup was one.
  int get freshReads => _freshReads;

  /// The accuracy radius a cached position needs to answer [accuracy], unless
  /// the location is approximate or nothing better is available.
  static double maxAccuracyMetersFor(LocationAccuracy accuracy) => switch (accuracy) {
    LocationAccuracy.high ||
    LocationAccuracy.best ||
    LocationAccuracy.bestForNavigation => preciseAccuracyMeters,
    _ => coarseAccuracyMeters,
  };

  /// Level 1, then level 2, then [readFresh]. [forceFresh] skips both levels;
  /// [maxAge] can make [ttl] stricter for this call, never longer. Either way
  /// a new reading still replaces level 1. An error from [readFresh] reaches
  /// the caller and nothing is kept. [permission] is the one the caller just
  /// checked; when it changes, whether the location is approximate is asked
  /// again.
  Future<Position?> get({
    required LocationAccuracy accuracy,
    required Future<Position?> Function() readFresh,
    LocationPermission? permission,
    Duration? maxAge,
    bool forceFresh = false,
  }) async {
    if (permission != null && permission != _permission) {
      _permission = permission;
      _accuracyStatus = null;
    }

    final reasons = <String>[];
    if (forceFresh) {
      reasons.add('forceFresh');
    } else {
      final limit = maxAge != null && maxAge < ttl ? maxAge : ttl;

      final cached = _position;
      if (cached == null) {
        reasons.add('L1 empty');
      } else {
        final verdict = await _judge(cached, accuracy, limit);
        reasons.add('L1 ${verdict.reason}');
        if (verdict.accepted) {
          _memoryHits++;
          _report('level 1 hit', cached, reasons);
          return cached;
        }
      }

      final lastKnown = await _lastKnown();
      if (lastKnown == null) {
        reasons.add('L2 empty');
      } else {
        final verdict = await _judge(lastKnown, accuracy, limit);
        reasons.add('L2 ${verdict.reason}');
        if (verdict.accepted) {
          _systemHits++;
          _position = lastKnown;
          _report('level 2 hit', lastKnown, reasons);
          return lastKnown;
        }
      }
    }

    _freshReads++;
    final position = await readFresh();
    if (position != null) {
      _position = position;
      _lastFresh[accuracy] = position;
    }
    _report(forceFresh ? 'fresh reading (forced)' : 'fresh reading', position, reasons);
    return position;
  }

  /// Signed out, or location access is gone: the next lookup can't be
  /// answered by memory, and what was learned about the device (approximate
  /// permission, best available accuracy) is asked again. The counters stay,
  /// they measure the whole run.
  void invalidate() {
    _position = null;
    _lastFresh.clear();
    _permission = null;
    _accuracyStatus = null;
  }

  Future<({bool accepted, String reason})> _judge(
    Position position,
    LocationAccuracy accuracy,
    Duration maxAge,
  ) async {
    final age = _ageOf(position);
    if (age.isNegative) return (accepted: false, reason: 'rejected: clock moved back');
    if (age >= maxAge) {
      return (
        accepted: false,
        reason: maxAge < ttl
            ? 'rejected: older than maxAge (age ${age.inSeconds} s)'
            : 'rejected: TTL expired (age ${age.inSeconds} s)',
      );
    }

    final radius = position.accuracy;
    // iOS reports an invalid fix with a negative radius.
    if (!(radius >= 0)) return (accepted: false, reason: 'rejected: invalid accuracy');

    final threshold = maxAccuracyMetersFor(accuracy);
    if (radius <= threshold) {
      return (accepted: true, reason: 'accepted: within ${threshold.round()} m');
    }
    if (await _isApproximateOnly()) {
      return (accepted: true, reason: 'accepted: approximate permission');
    }
    final best = _bestAvailable(accuracy);
    if (best != null && radius <= best) {
      return (accepted: true, reason: 'accepted: best available (last fresh ${_meters(best)})');
    }
    final why = best == null
        ? ' > ${threshold.round()} m'
        : ', worse than last fresh ${_meters(best)}';
    return (accepted: false, reason: 'rejected: accuracy too low (${_meters(radius)}$why)');
  }

  /// The radius of the last new reading at [accuracy], when it missed the
  /// threshold too and is still under [ttl]: the best the device gives now.
  /// Once it met the threshold, or is older, there's nothing to excuse.
  double? _bestAvailable(LocationAccuracy accuracy) {
    final last = _lastFresh[accuracy];
    if (last == null) return null;
    final age = _ageOf(last);
    if (age.isNegative || age >= ttl) return null;
    final radius = last.accuracy;
    if (!(radius >= 0) || radius <= maxAccuracyMetersFor(accuracy)) return null;
    return radius;
  }

  Future<bool> _isApproximateOnly() async {
    final status = _accuracyStatus ??= await _readAccuracyStatus();
    return status == LocationAccuracyStatus.reduced;
  }

  /// Like LocationService.ensureAccess: a platform without the API (or one
  /// that fails) is taken as precise.
  Future<LocationAccuracyStatus> _readAccuracyStatus() async {
    try {
      return await Geolocator.getLocationAccuracy();
    } catch (_) {
      return LocationAccuracyStatus.precise;
    }
  }

  /// A platform without it (the web) or one that fails is just a miss.
  Future<Position?> _lastKnown() async {
    try {
      return await Geolocator.getLastKnownPosition();
    } catch (_) {
      return null;
    }
  }

  Duration _ageOf(Position position) => _now().difference(position.timestamp);

  static String _meters(double radius) => radius.isFinite ? '±${radius.round()} m' : '±? m';

  void _report(String outcome, Position? position, List<String> reasons) {
    final detail = position == null
        ? 'no fix'
        : 'age ${_ageOf(position).inSeconds} s, ${_meters(position.accuracy)}';
    _log(
      'PositionCache: $outcome ($detail) — ${reasons.join('; ')} | '
      'L1 hits $_memoryHits · L2 hits $_systemHits · fresh reads $_freshReads',
    );
  }

  static void _debugLog(String message) {
    if (kDebugMode) debugPrint(message);
  }
}
