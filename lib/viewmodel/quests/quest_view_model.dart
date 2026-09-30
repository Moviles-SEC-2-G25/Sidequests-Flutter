import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../../analytics/analytics_event_type.dart';
import '../../analytics/analytics_tracker.dart';
import '../../core/app_exception.dart';
import '../../core/similar_quest_recommender.dart';
import '../../data/context/context_manager.dart';
import '../../models/app_context.dart';
import '../../models/quest.dart';
import '../../models/quest_recommendation.dart';
import '../../models/quest_step.dart';
import '../../models/user_preferences.dart';
import '../../models/user_quest.dart';
import '../../repository/quest_repository.dart';

const List<int> kAvailableMinuteOptions = [10, 20, 30, 45, 60];

/// Statuses that mean "not finished yet" — a quest in one of these can still
/// be resumed from the Explore "continue" banner or the Misión tab.
const _unfinishedStatuses = {'accepted', 'in_progress', 'abandoned'};

/// Explore, nearby, quest detail and mission-in-progress state.
class QuestViewModel extends ChangeNotifier {
  final QuestRepository _questRepository;
  final ContextManager _contextManager;
  final AnalyticsTracker _analyticsTracker;
  final String _userId;
  final SimilarQuestRecommender _similarQuestRecommender;

  List<Quest> catalog = [];
  List<QuestRecommendation> recommendations = [];
  List<UserQuest> userQuests = [];
  List<QuestStep> steps = [];
  String? _stepsQuestId;
  bool isLoading = false;
  bool isLoadingRecommendations = false;
  bool isLoadingSteps = false;
  String? errorMessage;
  bool isSubmittingRating = false;
  String? ratingErrorMessage;

  int selectedMinutes = 30;
  String selectedLocationScope = 'all'; // all | gps | anywhere
  String? selectedCategory; // null = "Todo", 'sponsored', or a real category

  final Set<String> _sessionSkippedQuestIds = {};

  double? userLatitude;
  double? userLongitude;
  bool isLocatingUser = false;

  /// Last Context Manager snapshot (location, time of day, weather...),
  /// refreshed whenever recommendations load. Drives Explore's automatic
  /// weather/time-of-day adaptation — null until the first load.
  AppContext? currentContext;

  // --- BQ4: "decision journey" toward starting a quest — how long, and how
  // many interactions, from the first recommendations shown (after opening
  // the app or after the last quest was started) to accepting one. ---
  DateTime? _decisionStartedAt;
  String? _decisionBatchId;
  int _interactionCount = 0;

  QuestViewModel(
    this._questRepository,
    this._contextManager,
    this._analyticsTracker,
    this._userId, {
    SimilarQuestRecommender similarQuestRecommender = const SimilarQuestRecommender(),
  }) : _similarQuestRecommender = similarQuestRecommender;

  /// The quest to resume from "Continúa donde lo dejaste" / the Misión tab:
  /// the most recently touched quest that isn't completed. `userQuests` is
  /// already ordered by `updated_at desc` by the repository query.
  UserQuest? get currentMission => userQuests
      .cast<UserQuest?>()
      .firstWhere((uq) => _unfinishedStatuses.contains(uq!.status), orElse: () => null);

  Quest? questById(String id) =>
      catalog.cast<Quest?>().firstWhere((q) => q!.id == id, orElse: () => null);

  List<String> get categories =>
      catalog.map((q) => q.category).toSet().toList()..sort();

  List<Quest> get filteredCatalog {
    final filtered = catalog.where((quest) {
      if (quest.durationMinutes > selectedMinutes) return false;
      if (selectedLocationScope != 'all' && quest.locationMode != selectedLocationScope) {
        return false;
      }
      if (selectedCategory == 'sponsored') return quest.isSponsored;
      if (selectedCategory != null &&
          quest.category.toLowerCase() != selectedCategory!.toLowerCase()) {
        return false;
      }
      return true;
    }).toList();

    if (!isAdaptingToContext) return filtered;

    // Stable partition, not a filter: 'anywhere' quests move first, but
    // nothing is dropped from the list.
    final anywhere = filtered.where((quest) => quest.locationMode == 'anywhere');
    final rest = filtered.where((quest) => quest.locationMode != 'anywhere');
    return [...anywhere, ...rest];
  }

  /// True when it's raining at the user's location or it's nighttime —
  /// Explore then prioritizes 'anywhere' (indoor/no-travel) quests and
  /// shows a banner explaining why.
  bool get isAdaptingToContext =>
      (currentContext?.isRainy ?? false) || currentContext?.timeOfDay == 'night';

  Future<void> load() async {
    isLoading = true;
    errorMessage = null;
    notifyListeners();
    try {
      catalog = await _questRepository.getCatalog();
      userQuests = await _questRepository.getUserQuests(_userId);
    } on AppException catch (e) {
      errorMessage = e.message;
    } finally {
      isLoading = false;
      notifyListeners();
    }
  }

  void setMinutes(int minutes) {
    selectedMinutes = minutes;
    registerInteraction();
    notifyListeners();
  }

  void setCategory(String? category) {
    selectedCategory = category;
    registerInteraction();
    notifyListeners();
  }

  /// BQ10 (location-independent mode usage) is measured from this event.
  void setLocationScope(String scope) {
    selectedLocationScope = scope;
    registerInteraction();
    notifyListeners();
    _analyticsTracker.track(
      AnalyticsEventType.locationModeSelected,
      locationMode: scope,
    );
  }

  /// BQ4: counts one step of browsing toward the decision to start a quest —
  /// a filter change, dismissing a recommendation, or opening a quest's
  /// detail from Explore. The final "accept" tap itself isn't counted.
  void registerInteraction() {
    _interactionCount++;
  }

  Future<void> loadRecommendations(UserPreferences preferences) async {
    isLoadingRecommendations = true;
    notifyListeners();
    try {
      final context = await _contextManager.snapshot(availableMinutes: selectedMinutes);
      currentContext = context;
      recommendations = await _questRepository.getRecommendations(
        context: context,
        preferences: preferences.copyWith(locationMode: selectedLocationScope),
        excludedQuestIds: _sessionSkippedQuestIds.toList(),
      );
      // One batch_id per RPC call so BQ8 can group the events of one list.
      final batchId = const Uuid().v4();
      // BQ4: starts the decision clock on the first non-empty list shown
      // since the app opened (or since the last quest was started) — later
      // reloads (filter changes, "Ahora no") don't restart it.
      if (recommendations.isNotEmpty) {
        _decisionStartedAt ??= DateTime.now();
        _decisionBatchId ??= batchId;
      }
      for (final recommendation in recommendations) {
        _analyticsTracker.track(
          AnalyticsEventType.recommendationShown,
          questId: recommendation.questId,
          category: recommendation.category,
          availableMinutes: selectedMinutes,
          locationMode: selectedLocationScope,
          metadata: {
            'variant': recommendation.variant,
            'rank': recommendation.rankPosition,
            'batch_id': batchId,
          },
        );
      }
    } on AppException catch (e) {
      errorMessage = e.message;
    } finally {
      isLoadingRecommendations = false;
      notifyListeners();
    }
  }

  /// [wasRecommended] also picks BQ4's start_path: 'standard' from a
  /// recommendation's detail view, 'catalog' from "Todas las misiones".
  Future<void> acceptQuest(String questId, {bool wasRecommended = false}) async {
    await _acceptQuest(
      questId,
      startPath: wasRecommended ? 'standard' : 'catalog',
      wasRecommended: wasRecommended,
    );
  }

  /// "Empezar ya" on a recommendation card (BQ4's 'instant_plan' start
  /// path): accepts the quest and preloads its steps, skipping
  /// QuestDetailView entirely. The caller navigates to MissionTabView once
  /// this returns true.
  Future<bool> startInstantPlan(Quest quest) async {
    final started = await _acceptQuest(quest.id, startPath: 'instant_plan', wasRecommended: true);
    if (!started) return false;
    await loadSteps(quest.id);
    return true;
  }

  Future<bool> _acceptQuest(
    String questId, {
    required String startPath,
    required bool wasRecommended,
  }) async {
    try {
      final userQuest = await _questRepository.acceptQuest(
        userId: _userId,
        questId: questId,
      );
      _replaceUserQuest(userQuest);
      final quest = questById(questId);
      // BQ4: how much a ready-to-execute plan (vs. browsing the detail page)
      // shortens the trip from seeing recommendations to starting a quest.
      final secondsToStart = _decisionStartedAt == null
          ? 0
          : DateTime.now().difference(_decisionStartedAt!).inSeconds;
      _analyticsTracker.track(
        wasRecommended
            ? AnalyticsEventType.recommendationAccepted
            : AnalyticsEventType.questStarted,
        questId: questId,
        category: quest?.category,
        questDurationMinutes: quest?.durationMinutes,
        questDifficulty: quest?.difficulty,
        estimatedCost: quest?.estimatedCost,
        metadata: {
          'start_path': startPath,
          'seconds_to_start': secondsToStart,
          'interactions_to_start': _interactionCount,
          'batch_id': _decisionBatchId,
        },
      );
      _resetDecisionJourney();
      return true;
    } on AppException catch (e) {
      errorMessage = e.message;
      notifyListeners();
      return false;
    }
  }

  /// A new decision journey starts the next time recommendations are shown.
  void _resetDecisionJourney() {
    _decisionStartedAt = null;
    _decisionBatchId = null;
    _interactionCount = 0;
  }

  /// "Ahora no" on a recommendation card: excludes it from this session's
  /// recommendations (migration 007's `p_excluded_quest_ids`) and refreshes.
  Future<void> skipRecommendation(String questId, UserPreferences preferences) async {
    _sessionSkippedQuestIds.add(questId);
    recommendations = recommendations.where((r) => r.questId != questId).toList();
    registerInteraction();
    notifyListeners();
    _analyticsTracker.track(
      AnalyticsEventType.recommendationSkipped,
      questId: questId,
      availableMinutes: selectedMinutes,
      locationMode: selectedLocationScope,
    );
    await loadRecommendations(preferences);
  }

  /// Real GPS capture (via the Context Manager's location snapshot) for the
  /// Cerca tab's distance sort. Not persisted — purely for this session's
  /// display, matching the Figma "Activar ubicación" affordance.
  Future<void> requestUserLocation() async {
    isLocatingUser = true;
    notifyListeners();
    final context = await _contextManager.snapshot();
    userLatitude = context.latitude;
    userLongitude = context.longitude;
    isLocatingUser = false;
    notifyListeners();
  }

  Future<void> loadSteps(String questId) async {
    isLoadingSteps = true;
    _stepsQuestId = questId;
    notifyListeners();
    try {
      steps = await _questRepository.getSteps(questId);
    } on AppException catch (e) {
      errorMessage = e.message;
    } finally {
      isLoadingSteps = false;
      notifyListeners();
    }
  }

  /// Advances the current step (or completes the quest on the last one).
  /// Transitions 'accepted' -> 'in_progress' on the first step so the
  /// backend's lifecycle trigger stamps `started_at` for real.
  /// Returns true only when this call completed the whole quest.
  Future<bool> completeCurrentStep(UserQuest userQuest) async {
    final nextCompleted = [...userQuest.completedSteps, userQuest.currentStep];
    final isLastStep = _stepsQuestId == userQuest.questId &&
        userQuest.currentStep >= steps.length - 1;

    try {
      final UserQuest updated;
      if (isLastStep) {
        updated = await _questRepository.completeQuest(
          userQuest.copyWithProgress(completedSteps: nextCompleted),
        );
        final quest = questById(userQuest.questId);
        _analyticsTracker.track(
          AnalyticsEventType.questCompleted,
          questId: updated.questId,
          category: quest?.category,
          questDurationMinutes: quest?.durationMinutes,
          questDifficulty: quest?.difficulty,
        );
      } else {
        updated = await _questRepository.updateProgress(
          userQuest.copyWithProgress(
            status: 'in_progress',
            currentStep: userQuest.currentStep + 1,
            completedSteps: nextCompleted,
          ),
        );
      }
      _replaceUserQuest(updated);
      return isLastStep;
    } on AppException catch (e) {
      errorMessage = e.message;
      notifyListeners();
      return false;
    }
  }

  /// Saves the post-mission rating/feedback and emits 'quest_rated'.
  /// Returns true on success; on failure `ratingErrorMessage` is set.
  Future<bool> submitRating(
    UserQuest userQuest, {
    required int rating,
    required List<String> tags,
  }) async {
    isSubmittingRating = true;
    ratingErrorMessage = null;
    notifyListeners();
    try {
      final updated = await _questRepository.rateQuest(userQuest, rating, tags);
      _replaceUserQuest(updated);
      final quest = questById(updated.questId);
      _analyticsTracker.track(
        AnalyticsEventType.questRated,
        questId: updated.questId,
        category: quest?.category,
        questDurationMinutes: quest?.durationMinutes,
        questDifficulty: quest?.difficulty,
        metadata: {'rating': rating, 'tags': tags},
      );
      return true;
    } on AppException catch (e) {
      ratingErrorMessage = e.message;
      return false;
    } finally {
      isSubmittingRating = false;
      notifyListeners();
    }
  }

  /// "Te podría gustar" on QuestCompletedView. Pure recomputation from
  /// [rating] each call (no caching), so the view just re-invokes it as the
  /// user picks a star rating, before saving — no separate "recalculate"
  /// step needed.
  List<Quest> similarQuests({required Quest completed, required int rating}) =>
      _similarQuestRecommender.recommend(completed, catalog, userQuests, rating, selectedMinutes);

  void trackSimilarQuestOpened({
    required String openedQuestId,
    required String sourceQuestId,
    required int rank,
  }) {
    _analyticsTracker.track(
      AnalyticsEventType.similarQuestOpened,
      questId: openedQuestId,
      metadata: {'source_quest_id': sourceQuestId, 'rank': rank},
    );
  }

  Future<void> abandonQuest(UserQuest userQuest, {required String reason}) async {
    try {
      final updated = await _questRepository.abandonQuest(userQuest, reason: reason);
      _replaceUserQuest(updated);
      final quest = questById(updated.questId);
      _analyticsTracker.track(
        AnalyticsEventType.questAbandoned,
        questId: updated.questId,
        category: quest?.category,
        questDurationMinutes: quest?.durationMinutes,
        questDifficulty: quest?.difficulty,
        estimatedCost: quest?.estimatedCost,
        questLatitude: quest?.latitude,
        questLongitude: quest?.longitude,
        metadata: {
          'reason': reason,
          'step': userQuest.currentStep,
          'completed_steps': userQuest.completedSteps.length,
        },
      );
    } on AppException catch (e) {
      errorMessage = e.message;
      notifyListeners();
    }
  }

  /// Candidates for the "shake to decide" gesture: same catalogue filter as
  /// Explore (respects `selectedMinutes`), minus quests already completed.
  List<Quest> get shakeCandidates {
    final completedIds = completedQuests.map((uq) => uq.questId).toSet();
    return filteredCatalog.where((quest) => !completedIds.contains(quest.id)).toList();
  }

  void trackShakeSurprise(String questId) {
    _analyticsTracker.track(
      AnalyticsEventType.shakeSurprise,
      questId: questId,
      metadata: {'quest_id': questId},
    );
  }

  void _replaceUserQuest(UserQuest updated) {
    userQuests = [updated, ...userQuests.where((uq) => uq.id != updated.id)];
    notifyListeners();
  }

  // --- Profile stats/rewards/badges, all computed from real user_quests +
  // catalog data (no rewards/badges table exists in the backend). ---

  List<UserQuest> get completedQuests {
    final list = userQuests.where((uq) => uq.status == 'completed').toList();
    list.sort(
      (a, b) => (b.completedAt ?? b.acceptedAt).compareTo(a.completedAt ?? a.acceptedAt),
    );
    return list;
  }

  int get completedCount => completedQuests.length;

  Set<String> get completedCategories => completedQuests
      .map((uq) => questById(uq.questId)?.category)
      .whereType<String>()
      .toSet();

  /// Consecutive days (ending today or yesterday) with at least one
  /// completed quest.
  int get currentStreakDays {
    final today = DateTime.now();
    final todayDate = DateTime(today.year, today.month, today.day);
    final dates =
        completedQuests
            .map((uq) => uq.completedAt)
            .whereType<DateTime>()
            .map((dt) => DateTime(dt.year, dt.month, dt.day))
            .toSet()
            .toList()
          ..sort((a, b) => b.compareTo(a));
    if (dates.isEmpty) return 0;

    var cursor = todayDate;
    if (dates.first != todayDate) {
      if (dates.first == todayDate.subtract(const Duration(days: 1))) {
        cursor = dates.first;
      } else {
        return 0;
      }
    }
    var streak = 0;
    for (final date in dates) {
      if (date == cursor) {
        streak++;
        cursor = cursor.subtract(const Duration(days: 1));
      } else if (date.isBefore(cursor)) {
        break;
      }
    }
    return streak;
  }

  bool _completedAnyIn(String category) => completedQuests.any(
    (uq) => questById(uq.questId)?.category.toLowerCase() == category,
  );

  bool get badgeFirstMission => completedCount >= 1;
  bool get badgeExplorer => completedCategories.length >= 3;
  bool get badgeGourmet => _completedAnyIn('food');
  bool get badgeArtLover => _completedAnyIn('art');
  bool get badgeSevenDayStreak => currentStreakDays >= 7;
  bool get badgeBookworm => _completedAnyIn('learning');
}
