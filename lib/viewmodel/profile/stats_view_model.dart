import 'package:flutter/foundation.dart';

import '../../core/app_exception.dart';
import '../../core/completion_likelihood.dart';
import '../../core/memo.dart';
import '../../models/quest.dart';
import '../../models/step_log_entry.dart';
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

/// The last [StatsSummary] and the [statsFingerprint] it was computed for.
/// One for the whole session (app.dart), since a StatsViewModel only lives
/// while its screen is open; signing out empties it.
typedef StatsSummaryCache = AsyncMemo<int, StatsSummary>;

/// A cheap fingerprint of everything [summarizeStats] reads: id and status of
/// each attempt (an attempt's quest never changes), id and category of each
/// quest, and the step totals. Equal fingerprints mean the same summary, so
/// the isolate isn't needed — barring a hash collision, which is unlikely but
/// possible: the price of not comparing the whole input.
int statsFingerprint(StatsInput input) {
  final stepTotals = input.stepTotals.entries.toList()..sort((a, b) => a.key.compareTo(b.key));
  return Object.hash(
    Object.hashAll([for (final uq in input.userQuests) Object.hash(uq.id, uq.status)]),
    Object.hashAll([for (final quest in input.catalog) Object.hash(quest.id, quest.category)]),
    Object.hashAll([for (final entry in stepTotals) Object.hash(entry.key, entry.value)]),
  );
}

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

  /// "Tus caminatas", from the step log (SQLite, on the device).
  static const walkWindow = Duration(days: 7);
  int walkStepsLast7Days = 0;
  List<({String category, int steps})> walkStepsByCategory = [];
  StepLogEntry? longestWalk;

  /// The title of [longestWalk]'s quest; null when it left the catalogue.
  String? longestWalkTitle;

  bool get hasWalks => longestWalk != null;

  final DateTime Function() _now;

  StatsViewModel(
    this._questRepository,
    this._userId, {
    StatsRunner runner = _summarizeInBackground,
    DateTime Function()? now,
    StatsSummaryCache? summaryCache,
  }) : _runner = runner,
       _now = now ?? DateTime.now,
       _summaryCache = summaryCache;

  /// Without it (tests), every load computes, as before the cache.
  final StatsSummaryCache? _summaryCache;

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
      // Local reads, so they don't wait on the network calls; never throws.
      final walksFuture = _questRepository.getWalkStats(since: _now().subtract(walkWindow));
      final (:userQuests, :fromCache) = await _questRepository.getUserQuestsWithSource(_userId);
      final catalog = await catalogFuture;
      final walks = await walksFuture;

      final input = StatsInput(
        catalog: catalog,
        userQuests: userQuests,
        stepTotals: _questRepository.getStepTotals(),
      );
      // Same data as last time: no isolate. The walks above are read anyway.
      final cache = _summaryCache;
      final summary = cache == null
          ? await _runner(input)
          : await cache.get(statsFingerprint(input), () => _runner(input));
      isFromCache = fromCache;
      attemptCount = summary.attemptCount;
      completedCount = summary.completedCount;
      categoryStats = summary.categoryStats;
      totalSteps = summary.totalSteps;
      walkStepsLast7Days = walks.recentSteps;
      walkStepsByCategory = walks.stepsByCategory;
      longestWalk = walks.longestWalk;
      longestWalkTitle = catalog
          .cast<Quest?>()
          .firstWhere((quest) => quest!.id == walks.longestWalk?.questId, orElse: () => null)
          ?.title;

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
