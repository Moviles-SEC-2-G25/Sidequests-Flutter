/// What "Mis estadísticas" shows about the walks: the steps since a date, the
/// steps per category (most walked first) and the longest walk, if any.
typedef WalkStats = ({
  int recentSteps,
  List<({String category, int steps})> stepsByCategory,
  StepLogEntry? longestWalk,
});

/// One walk: the podómetro total of an attempt (`user_quests.id`) that was
/// completed or abandoned. Stored in SQLite (StepLogDatabase), local only.
class StepLogEntry {
  static const completed = 'completed';
  static const abandoned = 'abandoned';

  final String attemptId;
  final String questId;

  /// Lowercased, like CompletionLikelihood; null when the quest wasn't in
  /// the catalogue.
  final String? category;
  final int steps;

  /// [completed] or [abandoned].
  final String outcome;
  final DateTime finishedAt;

  const StepLogEntry({
    required this.attemptId,
    required this.questId,
    required this.category,
    required this.steps,
    required this.outcome,
    required this.finishedAt,
  });

  factory StepLogEntry.fromRow(Map<String, Object?> row) => StepLogEntry(
    attemptId: row['attempt_id'] as String,
    questId: row['quest_id'] as String,
    category: row['category'] as String?,
    steps: row['steps'] as int,
    outcome: row['outcome'] as String,
    finishedAt: DateTime.fromMillisecondsSinceEpoch(row['finished_at'] as int, isUtc: true),
  );

  Map<String, Object?> toRow() => {
    'attempt_id': attemptId,
    'quest_id': questId,
    'category': category,
    'steps': steps,
    'outcome': outcome,
    'finished_at': finishedAt.toUtc().millisecondsSinceEpoch,
  };
}
