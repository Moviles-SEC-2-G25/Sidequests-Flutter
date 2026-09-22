import 'package:flutter/foundation.dart';

import '../../analytics/analytics_event_type.dart';
import '../../analytics/analytics_tracker.dart';
import '../../core/app_exception.dart';
import '../../data/context/context_manager.dart';
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

  List<Quest> catalog = [];
  List<QuestRecommendation> recommendations = [];
  List<UserQuest> userQuests = [];
  List<QuestStep> steps = [];
  String? _stepsQuestId;
  bool isLoading = false;
  bool isLoadingRecommendations = false;
  bool isLoadingSteps = false;
  String? errorMessage;

  int selectedMinutes = 30;
  String selectedLocationScope = 'all'; // all | gps | anywhere
  String? selectedCategory; // null = "Todo", 'sponsored', or a real category

  final Set<String> _sessionSkippedQuestIds = {};

  double? userLatitude;
  double? userLongitude;
  bool isLocatingUser = false;

  QuestViewModel(
    this._questRepository,
    this._contextManager,
    this._analyticsTracker,
    this._userId,
  );

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

  List<Quest> get filteredCatalog => catalog.where((quest) {
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
    notifyListeners();
  }

  void setCategory(String? category) {
    selectedCategory = category;
    notifyListeners();
  }

  /// BQ10 (location-independent mode usage) is measured from this event.
  void setLocationScope(String scope) {
    selectedLocationScope = scope;
    notifyListeners();
    _analyticsTracker.track(
      AnalyticsEventType.locationModeSelected,
      locationMode: scope,
    );
  }

  Future<void> loadRecommendations(UserPreferences preferences) async {
    isLoadingRecommendations = true;
    notifyListeners();
    try {
      final context = await _contextManager.snapshot(availableMinutes: selectedMinutes);
      recommendations = await _questRepository.getRecommendations(
        context: context,
        preferences: preferences.copyWith(locationMode: selectedLocationScope),
        excludedQuestIds: _sessionSkippedQuestIds.toList(),
      );
      for (final recommendation in recommendations) {
        _analyticsTracker.track(
          AnalyticsEventType.recommendationShown,
          questId: recommendation.questId,
          availableMinutes: selectedMinutes,
          locationMode: selectedLocationScope,
        );
      }
    } on AppException catch (e) {
      errorMessage = e.message;
    } finally {
      isLoadingRecommendations = false;
      notifyListeners();
    }
  }

  Future<void> acceptQuest(String questId, {bool wasRecommended = false}) async {
    try {
      final userQuest = await _questRepository.acceptQuest(
        userId: _userId,
        questId: questId,
      );
      _replaceUserQuest(userQuest);
      final quest = questById(questId);
      _analyticsTracker.track(
        wasRecommended
            ? AnalyticsEventType.recommendationAccepted
            : AnalyticsEventType.questStarted,
        questId: questId,
        category: quest?.category,
        questDurationMinutes: quest?.durationMinutes,
        questDifficulty: quest?.difficulty,
        estimatedCost: quest?.estimatedCost,
      );
    } on AppException catch (e) {
      errorMessage = e.message;
      notifyListeners();
    }
  }

  /// "Ahora no" on a recommendation card: excludes it from this session's
  /// recommendations (migration 007's `p_excluded_quest_ids`) and refreshes.
  Future<void> skipRecommendation(String questId, UserPreferences preferences) async {
    _sessionSkippedQuestIds.add(questId);
    recommendations = recommendations.where((r) => r.questId != questId).toList();
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
  Future<void> completeCurrentStep(UserQuest userQuest) async {
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
    } on AppException catch (e) {
      errorMessage = e.message;
      notifyListeners();
    }
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
        metadata: {'reason': reason},
      );
    } on AppException catch (e) {
      errorMessage = e.message;
      notifyListeners();
    }
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
