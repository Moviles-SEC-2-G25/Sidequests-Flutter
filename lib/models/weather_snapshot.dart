/// Domain view of the weather at a point. Deliberately independent of any
/// provider's JSON shape (see WeatherService, which adapts Open-Meteo to it).
class WeatherSnapshot {
  final int weatherCode; // WMO code
  final double temperatureC;
  final List<int> precipitationProbabilityNext3h; // percent, one per hour
  final DateTime fetchedAt;

  /// True when the network failed and this is the last known value instead
  /// of a current reading. Says how it was obtained, so it's never persisted.
  final bool isStale;

  const WeatherSnapshot({
    required this.weatherCode,
    required this.temperatureC,
    required this.precipitationProbabilityNext3h,
    required this.fetchedAt,
    this.isStale = false,
  });

  WeatherSnapshot asStale() => WeatherSnapshot(
    weatherCode: weatherCode,
    temperatureC: temperatureC,
    precipitationProbabilityNext3h: precipitationProbabilityNext3h,
    fetchedAt: fetchedAt,
    isStale: true,
  );

  factory WeatherSnapshot.fromJson(Map<String, dynamic> json) => WeatherSnapshot(
    weatherCode: (json['weather_code'] as num).toInt(),
    temperatureC: (json['temperature_c'] as num).toDouble(),
    precipitationProbabilityNext3h: (json['precipitation_probability_next_3h'] as List)
        .cast<num>()
        .map((p) => p.toInt())
        .toList(),
    fetchedAt: DateTime.parse(json['fetched_at'] as String),
  );

  /// In UTC: the snapshot's age must survive a time zone change.
  Map<String, dynamic> toJson() => {
    'weather_code': weatherCode,
    'temperature_c': temperatureC,
    'precipitation_probability_next_3h': precipitationProbabilityNext3h,
    'fetched_at': fetchedAt.toUtc().toIso8601String(),
  };

  /// WMO drizzle/rain (51-67), rain showers (80-82), thunderstorm (95-99).
  bool get isRainy =>
      (weatherCode >= 51 && weatherCode <= 67) ||
      (weatherCode >= 80 && weatherCode <= 82) ||
      (weatherCode >= 95 && weatherCode <= 99);

  /// Highest rain probability over the next hours, 0 if unknown.
  int get maxPrecipitationProbability => precipitationProbabilityNext3h.isEmpty
      ? 0
      : precipitationProbabilityNext3h.reduce((a, b) => a > b ? a : b);

  String get description => switch (weatherCode) {
    0 => 'Despejado',
    1 => 'Mayormente despejado',
    2 => 'Parcialmente nublado',
    3 => 'Nublado',
    45 || 48 => 'Niebla',
    51 || 53 || 55 => 'Llovizna',
    56 || 57 => 'Llovizna helada',
    61 => 'Lluvia ligera',
    63 => 'Lluvia moderada',
    65 => 'Lluvia fuerte',
    66 || 67 => 'Lluvia helada',
    71 || 73 || 75 || 77 => 'Nieve',
    80 || 81 || 82 => 'Chubascos',
    85 || 86 => 'Chubascos de nieve',
    95 => 'Tormenta',
    96 || 99 => 'Tormenta con granizo',
    _ => 'Clima desconocido',
  };
}
