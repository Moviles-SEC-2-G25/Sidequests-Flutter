/// One explicit "Tengo X minutos" choice made by the user, tagged with the
/// part of the day (morning | afternoon | evening | night, as timeOfDayFor).
class TimeChoice {
  final String timeOfDay;
  final int minutes;

  const TimeChoice({required this.timeOfDay, required this.minutes});

  @override
  bool operator ==(Object other) =>
      other is TimeChoice && other.timeOfDay == timeOfDay && other.minutes == minutes;

  @override
  int get hashCode => Object.hash(timeOfDay, minutes);
}

String timeOfDayLabelEs(String timeOfDay) => switch (timeOfDay) {
  'morning' => 'la mañana',
  'afternoon' => 'la tarde',
  'evening' => 'la noche',
  'night' => 'la madrugada',
  _ => timeOfDay,
};

/// Smart feature (mirror of Kotlin's SmartTimeAdvisor): smart available time.
///
/// Learns which "Tengo..." option the user picks in each part of the day and
/// preselects it when Explore opens, so recommendations already match the
/// time the user usually has. Needs at least [minChoices] choices in that
/// part of the day; ties go to the most recent choice. Pure Dart: works
/// offline.
abstract final class SmartTimeAdvisor {
  static const minChoices = 2;
  static const historySize = 30;

  /// [history] is oldest first.
  static int? preferredMinutes(List<TimeChoice> history, String timeOfDay) {
    final relevant = history.where((c) => c.timeOfDay == timeOfDay).toList();
    if (relevant.length < minChoices) return null;
    final counts = <int, int>{};
    for (final choice in relevant) {
      counts[choice.minutes] = (counts[choice.minutes] ?? 0) + 1;
    }
    final best = counts.values.reduce((a, b) => a > b ? a : b);
    return relevant.reversed.firstWhere((c) => counts[c.minutes] == best).minutes;
  }
}
