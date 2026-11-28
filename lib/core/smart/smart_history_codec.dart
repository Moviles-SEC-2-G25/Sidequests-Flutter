import '../../models/abandonment_reason.dart';
import 'smart_difficulty_advisor.dart';
import 'smart_time_advisor.dart';

/// Per-user history used by the smart features (mirror of Kotlin's
/// SmartHistory, persisted with DataStore there and SharedPreferences here).
class SmartHistory {
  final List<TimeChoice> timeChoices;
  final List<DifficultyOutcome> difficultyOutcomes;

  /// History size when the user dismissed the last difficulty suggestion.
  final int? difficultySuggestionDismissedAt;

  const SmartHistory({
    this.timeChoices = const [],
    this.difficultyOutcomes = const [],
    this.difficultySuggestionDismissedAt,
  });
}

/// Compact text format for the histories. Unknown or corrupted entries are
/// skipped instead of failing the whole load.
///  - time choices: "morning:15;evening:45"
///  - outcomes:     "medium:1:-;easy:0:too_difficult" (difficulty:completed:reason)
abstract final class SmartHistoryCodec {
  static const _timesOfDay = {'morning', 'afternoon', 'evening', 'night'};

  static String encodeTimeChoices(List<TimeChoice> choices) =>
      choices.map((c) => '${c.timeOfDay}:${c.minutes}').join(';');

  static List<TimeChoice> decodeTimeChoices(String? raw) {
    if (raw == null || raw.isEmpty) return const [];
    final result = <TimeChoice>[];
    for (final part in raw.split(';')) {
      final fields = part.split(':');
      if (fields.length != 2 || !_timesOfDay.contains(fields[0])) continue;
      final minutes = int.tryParse(fields[1]);
      if (minutes == null) continue;
      result.add(TimeChoice(timeOfDay: fields[0], minutes: minutes));
    }
    return result;
  }

  static String encodeOutcomes(List<DifficultyOutcome> outcomes) => outcomes
      .map((o) => '${o.difficulty}:${o.completed ? 1 : 0}:${o.reason?.code ?? '-'}')
      .join(';');

  static List<DifficultyOutcome> decodeOutcomes(String? raw) {
    if (raw == null || raw.isEmpty) return const [];
    final result = <DifficultyOutcome>[];
    for (final part in raw.split(';')) {
      final fields = part.split(':');
      if (fields.length != 3 || !kDifficultyLevels.contains(fields[0])) continue;
      if (fields[1] != '1' && fields[1] != '0') continue;
      final completed = fields[1] == '1';
      AbandonmentReason? reason;
      for (final candidate in AbandonmentReason.values) {
        if (candidate.code == fields[2]) reason = candidate;
      }
      result.add(DifficultyOutcome(difficulty: fields[0], completed: completed, reason: reason));
    }
    return result;
  }
}
