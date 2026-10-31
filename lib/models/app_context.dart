/// One context snapshot produced by the Context Manager (CAS) per request:
/// location, time of day, day of week and connectivity. `availableMinutes`
/// is not a device sensor — it is supplied by the caller (e.g. the quest
/// search form) and carried on the snapshot so it travels with the rest of
/// the context to analytics and the recommender.
class AppContext {
  final double? latitude;
  final double? longitude;
  final String timeOfDay; // morning | afternoon | evening | night
  final String dayOfWeek; // monday .. sunday
  final bool isConnected;
  final int? availableMinutes;

  /// WMO weather code at [latitude]/[longitude], from the Weather Service —
  /// null when there's no location fix or the forecast couldn't be fetched.
  final int? weatherCode;

  /// True when [weatherCode] is a rain/drizzle/thunderstorm code recent enough
  /// to go by (see ContextManager.rainFallbackMaxAge). False (not unknown) when
  /// there's no weather reading, so callers can use it directly without a null
  /// check.
  final bool isRainy;

  /// The network failed and the weather is the last known one.
  final bool weatherIsStale;

  /// How old that last known weather was when this snapshot was taken; null
  /// when it's current or there is none.
  final Duration? weatherAge;

  const AppContext({
    this.latitude,
    this.longitude,
    required this.timeOfDay,
    required this.dayOfWeek,
    required this.isConnected,
    this.availableMinutes,
    this.weatherCode,
    this.isRainy = false,
    this.weatherIsStale = false,
    this.weatherAge,
  });

  bool get hasLocation => latitude != null && longitude != null;
}
