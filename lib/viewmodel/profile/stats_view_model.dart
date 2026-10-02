import 'package:flutter/foundation.dart';

import '../../core/app_exception.dart';
import '../../core/completion_likelihood.dart';
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

/// "Mis estadísticas": completed missions, the user's own completion rate
/// per category (same CompletionLikelihood as Explore's labels) and total
/// walked steps. Screen-scoped — provided by StatsView.route(), so every
/// visit starts from fresh data and nothing outlives the screen.
class StatsViewModel extends ChangeNotifier {
  final QuestRepository _questRepository;
  final String _userId;
  final CompletionLikelihood _completionLikelihood;

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
    CompletionLikelihood completionLikelihood = const CompletionLikelihood(),
  }) : _completionLikelihood = completionLikelihood;

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

      final attempts = userQuests.where((uq) => uq.status != 'skipped').toList();
      isFromCache = fromCache;
      attemptCount = attempts.length;
      completedCount = attempts.where((uq) => uq.status == 'completed').length;

      categoryStats =
          _completionLikelihood
              .statsByCategory(catalog, userQuests)
              .values
              .map(
                (stats) => CategoryStat(
                  category: stats.category,
                  completed: stats.completed,
                  attempts: stats.attempts,
                  rate: stats.rate,
                  level: _completionLikelihood.levelOf(stats),
                ),
              )
              .toList()
            ..sort((a, b) {
              final byAttempts = b.attempts.compareTo(a.attempts);
              return byAttempts != 0 ? byAttempts : a.category.compareTo(b.category);
            });

      final attemptIds = userQuests.map((uq) => uq.id).toSet();
      final stepTotals = _questRepository
          .getStepTotals()
          .entries
          .where((entry) => attemptIds.contains(entry.key))
          .map((entry) => entry.value)
          .toList();
      totalSteps = stepTotals.isEmpty ? null : stepTotals.reduce((a, b) => a + b);

      if (attempts.isNotEmpty) {
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
