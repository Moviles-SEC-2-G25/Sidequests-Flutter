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
/// is younger than [ttl] (60 s) and its accuracy radius is within what the
/// caller asked for: [coarseAccuracyMeters] (100 m) for lowest/low/medium,
/// [preciseAccuracyMeters] (30 m) for high and better. So a coarse fix never
/// answers a caller that needs a precise one. A negative age (the device clock
/// moved back) is a miss: the real age is unknown.
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
  int _memoryHits = 0;
  int _systemHits = 0;
  int _freshReads = 0;

  /// [log] receives a line with the counters after every lookup; by default
  /// it's debugPrint, and only in debug builds.
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

  /// The accuracy radius a cached position needs to answer [accuracy].
  static double maxAccuracyMetersFor(LocationAccuracy accuracy) => switch (accuracy) {
    LocationAccuracy.high ||
    LocationAccuracy.best ||
    LocationAccuracy.bestForNavigation => preciseAccuracyMeters,
    _ => coarseAccuracyMeters,
  };

  /// Level 1, then level 2, then [readFresh]. [forceFresh] skips both levels;
  /// [maxAge] can make [ttl] stricter for this call, never longer. Either way
  /// a new reading still replaces level 1. An error from [readFresh] reaches
  /// the caller and nothing is kept.
  Future<Position?> get({
    required LocationAccuracy accuracy,
    required Future<Position?> Function() readFresh,
    Duration? maxAge,
    bool forceFresh = false,
  }) async {
    if (!forceFresh) {
      final limit = maxAge != null && maxAge < ttl ? maxAge : ttl;

      final cached = _position;
      if (cached != null && _answers(cached, accuracy, limit)) {
        _memoryHits++;
        _report('level 1 hit', cached);
        return cached;
      }

      final lastKnown = await _lastKnown();
      if (lastKnown != null && _answers(lastKnown, accuracy, limit)) {
        _systemHits++;
        _position = lastKnown;
        _report('level 2 hit', lastKnown);
        return lastKnown;
      }
    }

    _freshReads++;
    final position = await readFresh();
    if (position != null) _position = position;
    _report(forceFresh ? 'fresh reading (forced)' : 'fresh reading', position);
    return position;
  }

  /// Signed out, or location access is gone: the next lookup can't be
  /// answered by memory. The counters stay, they measure the whole run.
  void invalidate() => _position = null;

  bool _answers(Position position, LocationAccuracy accuracy, Duration maxAge) {
    final age = _now().difference(position.timestamp);
    if (age.isNegative || age >= maxAge) return false;
    // iOS reports an invalid fix with a negative radius.
    return position.accuracy >= 0 && position.accuracy <= maxAccuracyMetersFor(accuracy);
  }

  /// A platform without it (the web) or one that fails is just a miss.
  Future<Position?> _lastKnown() async {
    try {
      return await Geolocator.getLastKnownPosition();
    } catch (_) {
      return null;
    }
  }

  void _report(String outcome, Position? position) {
    final detail = position == null
        ? 'no fix'
        : 'age ${_now().difference(position.timestamp).inSeconds} s, '
              '±${position.accuracy.round()} m';
    _log(
      'PositionCache: $outcome ($detail) | '
      'L1 hits $_memoryHits · L2 hits $_systemHits · fresh reads $_freshReads',
    );
  }

  static void _debugLog(String message) {
    if (kDebugMode) debugPrint(message);
  }
}
