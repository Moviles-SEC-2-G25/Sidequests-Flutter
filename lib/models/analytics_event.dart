/// Mirrors `public.analytics_events`. Append-only from mobile clients.
class AnalyticsEvent {
  final String eventType;
  final String? sessionId;
  final String? questId;
  final String? category;
  final int? availableMinutes;
  final String? socialLevel;
  final double? latitude;
  final double? longitude;
  final int? weatherCode;
  final String? timeOfDay;
  final String? locationMode;
  final int? questDurationMinutes;
  final String? questDifficulty;
  final double? estimatedCost;
  final int? distanceMeters;
  final Map<String, dynamic> metadata;

  const AnalyticsEvent({
    required this.eventType,
    this.sessionId,
    this.questId,
    this.category,
    this.availableMinutes,
    this.socialLevel,
    this.latitude,
    this.longitude,
    this.weatherCode,
    this.timeOfDay,
    this.locationMode,
    this.questDurationMinutes,
    this.questDifficulty,
    this.estimatedCost,
    this.distanceMeters,
    this.metadata = const {},
  });

  /// `user_id` is not included: Supabase RLS requires the row's `user_id` to
  /// equal `auth.uid()`, so the remote data source stamps it from the active
  /// session at insert time rather than trusting a client-supplied value.
  Map<String, dynamic> toJson() => {
    'event_type': eventType,
    if (sessionId != null) 'session_id': sessionId,
    if (questId != null) 'quest_id': questId,
    if (category != null) 'category': category,
    if (availableMinutes != null) 'available_minutes': availableMinutes,
    if (socialLevel != null) 'social_level': socialLevel,
    if (latitude != null) 'latitude': latitude,
    if (longitude != null) 'longitude': longitude,
    if (weatherCode != null) 'weather_code': weatherCode,
    if (timeOfDay != null) 'time_of_day': timeOfDay,
    if (locationMode != null) 'location_mode': locationMode,
    if (questDurationMinutes != null)
      'quest_duration_minutes': questDurationMinutes,
    if (questDifficulty != null) 'quest_difficulty': questDifficulty,
    if (estimatedCost != null) 'estimated_cost': estimatedCost,
    if (distanceMeters != null) 'distance_meters': distanceMeters,
    if (metadata.isNotEmpty) 'metadata': metadata,
  };
}
