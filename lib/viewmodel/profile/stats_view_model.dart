import 'package:flutter/foundation.dart';

import '../../core/app_exception.dart';
import '../../core/completion_likelihood.dart';
import '../../models/quest.dart';
import '../../models/user_quest.dart';
import '../../repository/quest_repository.dart';

enum StatsStatus { loading, error, empty, data }

/// One "Por categoría" row, ready to paint. The Spanish category label is
/// presentation, so the view adds it (categoryLabelEs).
class CategoryStat {
  final String category; // lowercased
  final int completed;
  final int attempts;
  final double rate;
  final CompletionLevel level;

  const CategoryStat({
    required this.category,
    required this.completed,
    required this.attempts,
    required this.rate,
    required this.level,
  });
}

/// Everything [summarizeStats] needs, already read: it may run on another
/// isolate, where Hive and the repositories aren't available.
class StatsInput {
  final List<Quest> catalog;
  final List<UserQuest> userQuests;
  final Map<String, int> stepTotals;

  const StatsInput({required this.catalog, required this.userQuests, required this.stepTotals});
}

class StatsSummary {
  final int completedCount;
  final int attemptCount;
  final List<CategoryStat> categoryStats;
  final int? totalSteps;

  const StatsSummary({
    required this.completedCount,
    required this.attemptCount,
    required this.categoryStats,
    required this.totalSteps,
  });
}

/// Pure and top-level so compute() can run it: it must not capture a
/// ViewModel, whose repository can't be sent to another isolate.
StatsSummary summarizeStats(StatsInput input) {
  const completionLikelihood = CompletionLikelihood();
  final attempts = input.userQuests.where((uq) => uq.status != 'skipped').toList();

  final categoryStats =
      completionLikelihood
          .statsByCategory(input.catalog, input.userQuests)
          .values
          .map(
            (stats) => CategoryStat(
              category: stats.category,
              completed: stats.completed,
              attempts: stats.attempts,
              rate: stats.rate,
              level: completionLikelihood.levelOf(stats),
            ),
          )
          .toList()
        ..sort((a, b) {
          final byAttempts = b.attempts.compareTo(a.attempts);
          return byAttempts != 0 ? byAttempts : a.category.compareTo(b.category);
        });

  final attemptIds = input.userQuests.map((uq) => uq.id).toSet();
  final stepTotals = input.stepTotals.entries
      .where((entry) => attemptIds.contains(entry.key))
      .map((entry) => entry.value)
      .toList();

  return StatsSummary(
    completedCount: attempts.where((uq) => uq.status == 'completed').length,
    attemptCount: attempts.length,
    categoryStats: categoryStats,
    totalSteps: stepTotals.isEmpty ? null : stepTotals.reduce((a, b) => a + b),
  );
}

/// How [summarizeStats] gets run. Injectable because a real isolate never
/// finishes inside testWidgets' fake async zone.
typedef StatsRunner = Future<StatsSummary> Function(StatsInput input);

Future<StatsSummary> _summarizeInBackground(StatsInput input) => compute(summarizeStats, input);

/// "Mis estadísticas": completed missions, the user's own completion rate
/// per category (same CompletionLikelihood as Explore's labels) and total
/// walked steps. Screen-scoped — provided by StatsView.route(), so every
/// visit starts from fresh data and nothing outlives the screen.
class StatsViewModel extends ChangeNotifier {
  final QuestRepository _questRepository;
  final String _userId;
  final StatsRunner _runner;

  /// Starts as loading so the very first frame already shows the spinner.
  StatsStatus status = StatsStatus.loading;
  String? errorMessage;

  /// True when the data is the Hive cache (offline) — the view says so.
  bool isFromCache = false;

  int completedCount = 0;
  int attemptCount = 0;

  /// Most-attempted categories first.
  List<CategoryStat> categoryStats = [];

  /// Sum of the podómetro totals of this user's attempts; null when no
  /// attempt has step data (≠ 0 steps walked).
  int? totalSteps;

  StatsViewModel(
    this._questRepository,
    this._userId, {
    StatsRunner runner = _summarizeInBackground,
  }) : _runner = runner;

  double? get overallRate => attemptCount == 0 ? null : completedCount / attemptCount;

  /// On a refresh the current data stays on screen (no full-screen
  /// spinner) until the new result is in — like ProfileView, which only
  /// shows its spinner while `profile == null`.
  Future<void> load() async {
    if (status != StatsStatus.data) status = StatsStatus.loading;
    errorMessage = null;
    notifyListeners();
    try {
      final catalogFuture = _questRepository.getCatalog();
      final (:userQuests, :fromCache) = await _questRepository.getUserQuestsWithSource(_userId);
      final catalog = await catalogFuture;

      final summary = await _runner(
        StatsInput(
          catalog: catalog,
          userQuests: userQuests,
          stepTotals: _questRepository.getStepTotals(),
        ),
      );
      isFromCache = fromCache;
      attemptCount = summary.attemptCount;
      completedCount = summary.completedCount;
      categoryStats = summary.categoryStats;
      totalSteps = summary.totalSteps;

      if (attemptCount > 0) {
        status = StatsStatus.data;
      } else if (fromCache) {
        // Offline and nothing was ever cached: not "you have no missions".
        status = StatsStatus.error;
        errorMessage = 'Sin conexión y sin datos guardados. Conéctate para ver tus estadísticas.';
      } else {
        status = StatsStatus.empty;
      }
    } on AppException catch (e) {
      errorMessage = e.message;
      status = StatsStatus.error;
    } finally {
      notifyListeners();
    }
  }
}
