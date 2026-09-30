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

  /// True when [weatherCode] is a rain/drizzle/thunderstorm code. False
  /// (not unknown) when there's no weather reading, so callers can use it
  /// directly without a null check.
  final bool isRainy;

  const AppContext({
    this.latitude,
    this.longitude,
    required this.timeOfDay,
    required this.dayOfWeek,
    required this.isConnected,
    this.availableMinutes,
    this.weatherCode,
    this.isRainy = false,
  });

  bool get hasLocation => latitude != null && longitude != null;
}
