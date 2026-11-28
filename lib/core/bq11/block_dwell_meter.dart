import 'commercial_blocks.dart';

/// Thresholds of Kotlin's Bq11Observation.
const kBq11MaxGap = Duration(seconds: 35);
const kBq11ThresholdMs = 20 * 60 * 1000;

/// Older fixes are stale (Kotlin: `age in 0..5 s` from the fix's own clock).
const kBq11MaxFixAge = Duration(seconds: 5);

/// The Saturday (UTC date) of the Bogotá weekend [time] falls in, or null on a
/// weekday. Bogotá is UTC−5 all year (no daylight saving), so no time zone
/// database is needed to match Kotlin's `atZone(America/Bogota)`.
DateTime? bogotaWeekendStart(DateTime time) {
  final local = time.toUtc().subtract(const Duration(hours: 5));
  final date = DateTime.utc(local.year, local.month, local.day);
  return switch (date.weekday) {
    DateTime.saturday => date,
    DateTime.sunday => date.subtract(const Duration(days: 1)),
    _ => null,
  };
}

/// "2026-11-28": Kotlin's `LocalDate.toString()`, and what the BQ11 query
/// compares weekend_start with.
String formatWeekendStart(DateTime saturday) =>
    '${saturday.year.toString().padLeft(4, '0')}-'
    '${saturday.month.toString().padLeft(2, '0')}-'
    '${saturday.day.toString().padLeft(2, '0')}';

/// Time spent in one block on one weekend.
class BlockDwell {
  final String blockId;
  final DateTime weekendStart;
  final int observedMs;

  const BlockDwell({required this.blockId, required this.weekendStart, required this.observedMs});

  @override
  bool operator ==(Object other) =>
      other is BlockDwell &&
      other.blockId == blockId &&
      other.weekendStart == weekendStart &&
      other.observedMs == observedMs;

  @override
  int get hashCode => Object.hash(blockId, weekendStart, observedMs);

  @override
  String toString() => 'BlockDwell($blockId, ${formatWeekendStart(weekendStart)}, $observedMs ms)';
}

/// BQ11 measurement of one attempt, in memory only: the same rules as Kotlin's
/// Bq11Observation. Time counts only between two fresh, precise fixes in the
/// same pilot block and the same Bogotá weekend, at most [kBq11MaxGap] apart.
/// An invalid fix, a pause or a hidden screen cuts the interval. Each fix is
/// reduced to a block id right away: no coordinates are kept.
class BlockDwellMeter {
  final _totals = <(String, DateTime), int>{};
  ({String block, DateTime weekend, Duration elapsed})? _last;
  String? _attemptId;
  bool _visible = true;

  /// The attempt (`user_quests.id`) being measured, or null.
  String? get attemptId => _attemptId;

  /// Starts measuring [attemptId] from zero; null stops and discards.
  void select(String? attemptId) {
    if (_attemptId == attemptId) return;
    _attemptId = attemptId;
    _last = null;
    _totals.clear();
  }

  /// The quest screen hidden or the app in the background: no interval spans it.
  void setVisible(bool visible) {
    _visible = visible;
    if (!visible) _last = null;
  }

  /// No usable fix this time (weekday, no permission, a failed read).
  void pause() => _last = null;

  /// One reading. [receivedAt] is the wall clock when it arrived, to tell its
  /// age; [elapsed] a monotonic clock, for the time between readings.
  void recordFix({
    required String attemptId,
    required double latitude,
    required double longitude,
    required double accuracyMeters,
    required DateTime fixTime,
    required DateTime receivedAt,
    required Duration elapsed,
    bool isMocked = false,
  }) {
    if (attemptId != _attemptId) return;
    if (!_visible) {
      _last = null;
      return;
    }
    final age = receivedAt.difference(fixTime);
    final isFresh = !isMocked && !age.isNegative && age <= kBq11MaxFixAge;
    final block = isFresh ? commercialBlockAt(latitude, longitude, accuracyMeters) : null;
    _observe(block, fixTime, elapsed);
  }

  void _observe(String? block, DateTime time, Duration elapsed) {
    final weekend = bogotaWeekendStart(time);
    final previous = _last;
    _last = block == null || weekend == null ? null : (block: block, weekend: weekend, elapsed: elapsed);
    if (block == null || weekend == null || previous == null) return;
    final delta = (elapsed - previous.elapsed).inMilliseconds;
    if (previous.block == block &&
        previous.weekend == weekend &&
        delta >= 1 &&
        delta <= kBq11MaxGap.inMilliseconds) {
      _totals[(block, weekend)] = (_totals[(block, weekend)] ?? 0) + delta;
    }
  }

  /// The blocks of [attemptId] over [kBq11ThresholdMs] (strictly) in the
  /// weekend of [completedAt]; then the measurement is over.
  List<BlockDwell> finish({required String attemptId, required DateTime completedAt}) {
    if (attemptId != _attemptId) return const [];
    final weekend = bogotaWeekendStart(completedAt);
    final result = [
      for (final MapEntry(key: (block, observedWeekend), value: millis) in _totals.entries)
        if (observedWeekend == weekend && millis > kBq11ThresholdMs)
          BlockDwell(blockId: block, weekendStart: observedWeekend, observedMs: millis),
    ];
    select(null);
    return result;
  }
}
