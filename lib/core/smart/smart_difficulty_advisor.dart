import '../../models/abandonment_reason.dart';

/// Difficulty levels, easiest first: `quests.difficulty` and
/// `user_preferences.preferred_difficulty` use these codes.
const kDifficultyLevels = ['easy', 'medium', 'hard'];

String difficultyLabelEs(String difficulty) => switch (difficulty) {
  'easy' => 'Fácil',
  'medium' => 'Media',
  'hard' => 'Difícil',
  _ => difficulty,
};

int _rank(String difficulty) {
  final index = kDifficultyLevels.indexOf(difficulty);
  return index < 0 ? 0 : index;
}

/// One finished attempt (completed or abandoned) used by the smart difficulty
/// feature.
class DifficultyOutcome {
  final String difficulty; // easy | medium | hard
  final bool completed;
  final AbandonmentReason? reason;

  const DifficultyOutcome({required this.difficulty, required this.completed, this.reason});

  @override
  bool operator ==(Object other) =>
      other is DifficultyOutcome &&
      other.difficulty == difficulty &&
      other.completed == completed &&
      other.reason == reason;

  @override
  int get hashCode => Object.hash(difficulty, completed, reason);
}

class DifficultyStreaks {
  final int abandons;
  final int completions;

  const DifficultyStreaks({required this.abandons, required this.completions});
}

class DifficultySuggestion {
  final String current;
  final String suggested;
  final String explanation;

  const DifficultySuggestion({
    required this.current,
    required this.suggested,
    required this.explanation,
  });
}

/// Smart feature (BQ13, mirror of Kotlin's SmartDifficultyAdvisor): adapts the
/// preferred difficulty to how the user actually plays.
///
/// - Abandoning [easierAfterAbandons] quests in a row at the preferred
///   difficulty (or easier) because they were too difficult or took too long
///   → suggest the easier level.
/// - Completing [harderAfterCompletions] quests in a row at the preferred
///   difficulty (or harder) → suggest the harder level.
///
/// Abandons caused by things unrelated to difficulty (weather, distance,
/// budget, place closed) are ignored, so a rainy day does not lower the
/// user's level. Pure Dart on data the app already has: works offline.
abstract final class SmartDifficultyAdvisor {
  static const easierAfterAbandons = 2;
  static const harderAfterCompletions = 3;
  static const historySize = 10;

  static const _difficultyRelatedReasons = {
    AbandonmentReason.tooDifficult,
    AbandonmentReason.ranOutOfTime,
  };

  /// Current streaks of difficulty-related abandons and of completions at
  /// [preferred]. [history] is oldest first.
  static DifficultyStreaks streaks(List<DifficultyOutcome> history, String preferred) {
    final preferredRank = _rank(preferred);
    // Most recent first, only attempts that say something about the level:
    // - abandoning a quest at this level (or an easier one) because it was too
    //   hard/long means the level is too high;
    // - completing a quest at this level (or a harder one) means the user can
    //   handle more.
    final relevant = history.reversed.where((outcome) {
      if (outcome.completed) return _rank(outcome.difficulty) >= preferredRank;
      return _difficultyRelatedReasons.contains(outcome.reason) &&
          _rank(outcome.difficulty) <= preferredRank;
    }).toList();
    return DifficultyStreaks(
      abandons: relevant.takeWhile((o) => !o.completed).length,
      completions: relevant.takeWhile((o) => o.completed).length,
    );
  }

  static DifficultySuggestion? suggest(List<DifficultyOutcome> history, String preferred) {
    final streak = streaks(history, preferred);
    final rank = _rank(preferred);

    if (streak.abandons >= easierAfterAbandons) {
      if (rank == 0) return null;
      final easier = kDifficultyLevels[rank - 1];
      return DifficultySuggestion(
        current: preferred,
        suggested: easier,
        explanation:
            'Dejaste tus últimas ${streak.abandons} misiones de nivel '
            '${difficultyLabelEs(preferred)} porque eran muy difíciles o largas. '
            '¿Pruebas ${difficultyLabelEs(easier)} por un tiempo?',
      );
    }
    if (streak.completions >= harderAfterCompletions) {
      if (rank == kDifficultyLevels.length - 1) return null;
      final harder = kDifficultyLevels[rank + 1];
      return DifficultySuggestion(
        current: preferred,
        suggested: harder,
        explanation:
            'Completaste ${streak.completions} misiones de nivel '
            '${difficultyLabelEs(preferred)} seguidas. '
            '¿Te animas con ${difficultyLabelEs(harder)}?',
      );
    }
    return null;
  }
}
