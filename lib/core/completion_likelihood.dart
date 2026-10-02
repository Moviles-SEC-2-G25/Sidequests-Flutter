import '../models/quest.dart';
import '../models/user_quest.dart';

/// "Probabilidad de que la termines" label shown on Explore's quest cards.
enum CompletionLevel { high, medium, low, newForYou }

/// The user's own attempts and completions in one category.
class CategoryCompletion {
  final String category; // lowercased
  final int attempts; // non-'skipped' user_quests rows, always >= 1
  final int completed;

  const CategoryCompletion({
    required this.category,
    required this.attempts,
    required this.completed,
  });

  double get rate => completed / attempts;
}

/// Personal version of BQ9: the user's own completion rate per category
/// (completed / attempted, where every non-'skipped' user_quests row counts
/// as an attempt). Pure Dart, like SimilarQuestRecommender, so
/// QuestViewModel only wraps it and it's trivial to unit test on its own.
class CompletionLikelihood {
  const CompletionLikelihood();

  static const _minAttempts = 3;
  static const _highThreshold = 0.7;
  static const _mediumThreshold = 0.4;

  /// Raw counts for every category (lowercased) with at least one attempt —
  /// including those below [_minAttempts], which "Mis estadísticas" still
  /// lists (as "Nueva para ti").
  ///
  /// Accepted/in-progress quests count as attempts too (same formula as
  /// BQ9's completed / accepted), so a category's rate dips while a quest
  /// in it is still open. Rows whose quest isn't in [catalog] are ignored —
  /// there's no category to attribute them to.
  Map<String, CategoryCompletion> statsByCategory(List<Quest> catalog, List<UserQuest> userQuests) {
    final categoryByQuestId = {
      for (final quest in catalog) quest.id: quest.category.toLowerCase(),
    };

    final attempts = <String, int>{};
    final completions = <String, int>{};
    for (final userQuest in userQuests) {
      if (userQuest.status == 'skipped') continue;
      final category = categoryByQuestId[userQuest.questId];
      if (category == null) continue;
      attempts[category] = (attempts[category] ?? 0) + 1;
      if (userQuest.status == 'completed') {
        completions[category] = (completions[category] ?? 0) + 1;
      }
    }

    return {
      for (final entry in attempts.entries)
        entry.key: CategoryCompletion(
          category: entry.key,
          attempts: entry.value,
          completed: completions[entry.key] ?? 0,
        ),
    };
  }

  /// One level per category the user has at least [_minAttempts] attempts
  /// in. Categories below that — or never tried — are absent, which
  /// [levelFor] reads as "Nueva para ti".
  Map<String, CompletionLevel> byCategory(List<Quest> catalog, List<UserQuest> userQuests) => {
    for (final stats in statsByCategory(catalog, userQuests).values)
      if (stats.attempts >= _minAttempts) stats.category: levelOf(stats),
  };

  CompletionLevel levelFor(Quest quest, Map<String, CompletionLevel> byCategory) =>
      byCategory[quest.category.toLowerCase()] ?? CompletionLevel.newForYou;

  CompletionLevel levelOf(CategoryCompletion stats) =>
      stats.attempts < _minAttempts ? CompletionLevel.newForYou : _levelForRate(stats.rate);

  CompletionLevel _levelForRate(double rate) {
    if (rate >= _highThreshold) return CompletionLevel.high;
    if (rate >= _mediumThreshold) return CompletionLevel.medium;
    return CompletionLevel.low;
  }
}
