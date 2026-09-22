import 'package:flutter/foundation.dart';

import '../../analytics/analytics_event_type.dart';
import '../../analytics/analytics_tracker.dart';
import '../../core/app_exception.dart';
import '../../data/context/context_manager.dart';
import '../../models/quest.dart';
import '../../models/quest_recommendation.dart';
import '../../models/user_preferences.dart';
import '../../models/user_quest.dart';
import '../../repository/quest_repository.dart';

/// Explore, quest detail, mission-in-progress and nearby state.
class QuestViewModel extends ChangeNotifier {
  final QuestRepository _questRepository;
  final ContextManager _contextManager;
  final AnalyticsTracker _analyticsTracker;
  final String _userId;

  List<Quest> catalog = [];
  List<QuestRecommendation> recommendations = [];
  List<UserQuest> userQuests = [];
  bool isLoading = false;
  String? errorMessage;

  QuestViewModel(
    this._questRepository,
    this._contextManager,
    this._analyticsTracker,
    this._userId,
  );

  UserQuest? get activeQuest => userQuests
      .where((uq) => uq.status == 'accepted' || uq.status == 'in_progress')
      .cast<UserQuest?>()
      .firstWhere((_) => true, orElse: () => null);

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

  Future<void> loadRecommendations(UserPreferences preferences) async {
    try {
      final context = await _contextManager.snapshot(
        availableMinutes: preferences.typicalTimeMinutes,
      );
      recommendations = await _questRepository.getRecommendations(
        context: context,
        preferences: preferences,
      );
      for (final recommendation in recommendations) {
        _analyticsTracker.track(
          AnalyticsEventType.recommendationShown,
          questId: recommendation.questId,
        );
      }
      notifyListeners();
    } on AppException catch (e) {
      errorMessage = e.message;
      notifyListeners();
    }
  }

  Future<void> acceptQuest(String questId, {bool wasRecommended = false}) async {
    try {
      final userQuest = await _questRepository.acceptQuest(
        userId: _userId,
        questId: questId,
      );
      userQuests = [userQuest, ...userQuests.where((uq) => uq.id != userQuest.id)];
      _analyticsTracker.track(
        wasRecommended
            ? AnalyticsEventType.recommendationAccepted
            : AnalyticsEventType.questStarted,
        questId: questId,
      );
      notifyListeners();
    } on AppException catch (e) {
      errorMessage = e.message;
      notifyListeners();
    }
  }

  Future<void> skipRecommendation(String questId) =>
      _analyticsTracker.track(AnalyticsEventType.recommendationSkipped, questId: questId);

  Future<void> abandonQuest(UserQuest userQuest, {required String reason}) async {
    try {
      final updated = await _questRepository.abandonQuest(userQuest, reason: reason);
      _replaceUserQuest(updated);
      _analyticsTracker.track(
        AnalyticsEventType.questAbandoned,
        questId: updated.questId,
        metadata: {'reason': reason},
      );
    } on AppException catch (e) {
      errorMessage = e.message;
      notifyListeners();
    }
  }

  Future<void> completeQuest(UserQuest userQuest) async {
    try {
      final updated = await _questRepository.completeQuest(userQuest);
      _replaceUserQuest(updated);
      _analyticsTracker.track(AnalyticsEventType.questCompleted, questId: updated.questId);
    } on AppException catch (e) {
      errorMessage = e.message;
      notifyListeners();
    }
  }

  void _replaceUserQuest(UserQuest updated) {
    userQuests = [
      updated,
      ...userQuests.where((uq) => uq.id != updated.id),
    ];
    notifyListeners();
  }
}
