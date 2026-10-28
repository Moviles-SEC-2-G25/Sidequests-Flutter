/// GPS precision tiers, mapped to geolocator's LocationAccuracy by
/// LocationCheckInService (kept plugin-free here so it's unit-testable).
enum CheckInPrecision { coarse, balanced, precise }

/// Within this distance of the quest the stream switches to precise GPS.
const double kCheckInNearMeters = 300;

/// How often/precisely to sample while walking to a quest. Far away a
/// coarse, sparse stream is enough to know you're getting closer; the last
/// [kCheckInNearMeters] need precise GPS, since a 50 m check-in can't be
/// confirmed with a fix that's off by hundreds of meters. Low battery
/// samples less (bigger distanceFilter) but never drops below what the
/// check-in needs once near — same idea as ContextManager's battery rule.
///
/// Offline, far away asks for GPS as well: the coarse/balanced tiers are
/// mostly Wi-Fi/cell positioning (Android's low-power and balanced
/// priorities), which needs a network lookup — without it the stream can go
/// quiet and the user never "arrives" within 300 m. The far distanceFilter
/// still keeps it sparse.
({CheckInPrecision precision, int distanceFilterMeters}) checkInSampling({
  required bool lowBattery,
  bool offline = false,
  double? distanceMeters,
}) {
  final isNear = distanceMeters != null && distanceMeters <= kCheckInNearMeters;
  if (!isNear) {
    final networkTier = lowBattery ? CheckInPrecision.coarse : CheckInPrecision.balanced;
    return (
      precision: offline ? CheckInPrecision.precise : networkTier,
      distanceFilterMeters: lowBattery ? 100 : 50,
    );
  }
  return (precision: CheckInPrecision.precise, distanceFilterMeters: lowBattery ? 15 : 5);
}
