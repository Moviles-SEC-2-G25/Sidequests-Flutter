import '../models/quest.dart';
import '../models/user_quest.dart';

/// Statuses that mean the user already has a claim on that quest — it
/// shouldn't be suggested again right after finishing a different one.
const _activeOrCompletedStatuses = {'accepted', 'in_progress', 'completed'};

/// Scores and ranks "you might like" suggestions for QuestCompletedView's
/// "Te podría gustar" section. Pure Dart — no Flutter dependency — so
/// QuestViewModel's UI-facing wrapper is the only thing that needs a
/// BuildContext; this class is trivial to unit test on its own.
class SimilarQuestRecommender {
  const SimilarQuestRecommender();

  static const _sameCategoryScore = 3;
  static const _sameCategoryLowRatingPenalty = -3;
  static const _sharedTagScore = 1;
  static const _similarDurationScore = 2;
  static const _similarDurationThresholdMinutes = 15;
  static const _sameDifficultyScore = 1;
  static const _lowRatingThreshold = 2;
  static const _resultCount = 3;

  /// Ranks [catalog] against the just-finished [completed] quest.
  ///
  /// Excludes [completed] itself and any quest the user has already
  /// completed or has in progress (per [userQuests]), and any longer than
  /// [maxMinutes]. [rating] is the user's pending rating for [completed]
  /// (not yet saved) — a low one (<=2) turns "same category" from a plus
  /// into a minus, since it's a signal to steer away from it rather than
  /// toward it. Returns at most 3 quests, best score first, ties broken by
  /// the shorter duration.
  List<Quest> recommend(
    Quest completed,
    List<Quest> catalog,
    List<UserQuest> userQuests,
    int rating,
    int maxMinutes,
  ) {
    final unavailableQuestIds = userQuests
        .where((uq) => _activeOrCompletedStatuses.contains(uq.status))
        .map((uq) => uq.questId)
        .toSet();

    final candidates = catalog.where(
      (quest) =>
          quest.id != completed.id &&
          !unavailableQuestIds.contains(quest.id) &&
          quest.durationMinutes <= maxMinutes,
    );

    final ranked = candidates.toList()
      ..sort((a, b) {
        final byScore = _score(completed, b, rating).compareTo(_score(completed, a, rating));
        if (byScore != 0) return byScore;
        return a.durationMinutes.compareTo(b.durationMinutes);
      });

    return ranked.take(_resultCount).toList();
  }

  int _score(Quest completed, Quest candidate, int rating) {
    var score = 0;

    if (candidate.category == completed.category) {
      score += rating <= _lowRatingThreshold
          ? _sameCategoryLowRatingPenalty
          : _sameCategoryScore;
    }

    final sharedTags = candidate.tags.toSet().intersection(completed.tags.toSet());
    score += sharedTags.length * _sharedTagScore;

    final durationDifference = (candidate.durationMinutes - completed.durationMinutes).abs();
    if (durationDifference <= _similarDurationThresholdMinutes) {
      score += _similarDurationScore;
    }

    if (candidate.difficulty == completed.difficulty) {
      score += _sameDifficultyScore;
    }

    return score;
  }
}
