import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/app_exception.dart';
import '../data/local/local_data_source.dart';
import '../data/remote/supabase_remote_data_source.dart';
import '../models/app_context.dart';
import '../models/quest.dart';
import '../models/quest_recommendation.dart';
import '../models/quest_step.dart';
import '../models/user_preferences.dart';
import '../models/user_quest.dart';

/// Single source of truth for the quest catalogue, recommendations and a
/// user's quest progress. Falls back to the cache when the network fails.
class QuestRepository {
  final SupabaseRemoteDataSource _remoteDataSource;
  final LocalDataSource _localDataSource;

  QuestRepository(this._remoteDataSource, this._localDataSource);

  Future<List<Quest>> getCatalog() async {
    try {
      final rows = await _remoteDataSource.getActiveQuests();
      await _localDataSource.cacheQuestCatalog(rows);
      return rows.map(Quest.fromJson).toList();
    } catch (_) {
      return _localDataSource.getQuestCatalog().map(Quest.fromJson).toList();
    }
  }

  Future<List<QuestStep>> getSteps(String questId) async {
    try {
      final rows = await _remoteDataSource.getQuestSteps(questId);
      return rows.map(QuestStep.fromJson).toList();
    } on PostgrestException catch (e) {
      throw AppException(e.message);
    }
  }

  /// Delegates ranking to the shared `recommend_quests` RPC (BQ5) so Kotlin
  /// and Flutter never duplicate the recommendation logic.
  Future<List<QuestRecommendation>> getRecommendations({
    required AppContext context,
    required UserPreferences preferences,
    List<String> excludedQuestIds = const [],
    int limit = 3,
  }) async {
    try {
      final rows = await _remoteDataSource.recommendQuests(
        availableMinutes: context.availableMinutes ?? preferences.typicalTimeMinutes,
        socialLevel: preferences.socialLevel,
        interests: preferences.interests,
        locationMode: preferences.locationMode,
        excludedQuestIds: excludedQuestIds,
        limit: limit,
      );
      return rows.map(QuestRecommendation.fromJson).toList();
    } on PostgrestException catch (e) {
      throw AppException(e.message);
    }
  }

  Future<List<UserQuest>> getUserQuests(String userId) async {
    try {
      final rows = await _remoteDataSource.getUserQuests(userId);
      await _localDataSource.cacheUserQuests(rows);
      return rows.map(UserQuest.fromJson).toList();
    } catch (_) {
      return _localDataSource.getUserQuests().map(UserQuest.fromJson).toList();
    }
  }

  Future<UserQuest> acceptQuest({required String userId, required String questId}) async {
    try {
      final json = await _remoteDataSource.upsertUserQuest({
        'user_id': userId,
        'quest_id': questId,
        'status': 'accepted',
      });
      await _localDataSource.cacheActiveQuestId(questId);
      return UserQuest.fromJson(json);
    } on PostgrestException catch (e) {
      throw AppException(e.message);
    }
  }

  Future<UserQuest> updateProgress(UserQuest userQuest) async {
    try {
      final json = await _remoteDataSource.upsertUserQuest({
        'id': userQuest.id,
        'user_id': userQuest.userId,
        'quest_id': userQuest.questId,
        'status': userQuest.status,
        'current_step': userQuest.currentStep,
        'completed_steps': userQuest.completedSteps,
      });
      return UserQuest.fromJson(json);
    } on PostgrestException catch (e) {
      throw AppException(e.message);
    }
  }

  Future<UserQuest> abandonQuest(UserQuest userQuest, {required String reason}) async {
    try {
      final json = await _remoteDataSource.upsertUserQuest({
        'id': userQuest.id,
        'user_id': userQuest.userId,
        'quest_id': userQuest.questId,
        'status': 'abandoned',
        'abandon_reason': reason,
      });
      await _localDataSource.cacheActiveQuestId(null);
      return UserQuest.fromJson(json);
    } on PostgrestException catch (e) {
      throw AppException(e.message);
    }
  }

  Future<UserQuest> completeQuest(UserQuest userQuest) async {
    try {
      final json = await _remoteDataSource.upsertUserQuest({
        'id': userQuest.id,
        'user_id': userQuest.userId,
        'quest_id': userQuest.questId,
        'status': 'completed',
      });
      await _localDataSource.cacheActiveQuestId(null);
      return UserQuest.fromJson(json);
    } on PostgrestException catch (e) {
      throw AppException(e.message);
    }
  }
}
