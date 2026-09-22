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

  const AppContext({
    this.latitude,
    this.longitude,
    required this.timeOfDay,
    required this.dayOfWeek,
    required this.isConnected,
    this.availableMinutes,
  });

  bool get hasLocation => latitude != null && longitude != null;
}
