import '../models/app_context.dart';

/// morning | afternoon | evening | night. ContextManager's snapshots use it
/// too, so there's one definition of the ranges.
String timeOfDayFor(DateTime now) {
  final hour = now.hour;
  if (hour < 6) return 'night';
  if (hour < 12) return 'morning';
  if (hour < 18) return 'afternoon';
  if (hour < 22) return 'evening';
  return 'night';
}

/// clear | cloudy | rain | snow | storm | unknown: the same WMO code table as
/// Kotlin's WeatherService, so both apps land in the same BQ10 groups. Not
/// AppContext.isRainy, which treats storms as rain.
String weatherConditionFor(AppContext? context) {
  final code = context?.weatherCode;
  if (code == null) return 'unknown';
  return switch (code) {
    0 || 1 => 'clear',
    2 || 3 || 45 || 48 => 'cloudy',
    (>= 51 && <= 67) || (>= 80 && <= 82) => 'rain',
    (>= 71 && <= 77) || 85 || 86 => 'snow',
    >= 95 && <= 99 => 'storm',
    _ => 'unknown',
  };
}

/// Metadata of the BQ10 events (Sidequests-Analytics/docs/EVENT_SCHEMA.md),
/// with the same keys as Kotlin. The time comes from [now], so only the
/// weather depends on having a [context].
Map<String, String> bq10Metadata(String locationMode, AppContext? context, DateTime now) => {
  'location_mode': locationMode,
  'time_of_day': timeOfDayFor(now),
  'weather_condition': weatherConditionFor(context),
};
