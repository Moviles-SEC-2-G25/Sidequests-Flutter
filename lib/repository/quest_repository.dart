import 'dart:typed_data';

import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../core/app_exception.dart';
import '../core/photo_proof_rules.dart';
import '../data/local/local_data_source.dart';
import '../data/remote/supabase_remote_data_source.dart';
import '../models/app_context.dart';
import '../models/photo_proof.dart';
import '../models/quest.dart';
import '../models/quest_recommendation.dart';
import '../models/quest_step.dart';
import '../models/step_session.dart';
import '../models/user_preferences.dart';
import '../models/user_quest.dart';

/// Single source of truth for the quest catalogue, recommendations and a
/// user's quest progress. Falls back to the cache when the network fails.
class QuestRepository {
  static const _offlineMessage =
      'Sin conexión: tu foto quedó guardada en el teléfono. Reintenta cuando tengas internet.';
  static const _serverRetryMessage = 'No se pudo subir la foto ahora. Inténtalo de nuevo.';

  final SupabaseRemoteDataSource _remoteDataSource;
  final LocalDataSource _localDataSource;
  final String Function() _newId;

  QuestRepository(this._remoteDataSource, this._localDataSource, {String Function()? newId})
    : _newId = newId ?? (() => const Uuid().v4());

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

  Future<List<UserQuest>> getUserQuests(String userId) async =>
      (await getUserQuestsWithSource(userId)).userQuests;

  /// Same as [getUserQuests], but also says whether it fell back to the
  /// Hive cache — so a view can tell "offline, last known data" apart from
  /// fresh data, and "offline with nothing cached" apart from "empty".
  Future<({List<UserQuest> userQuests, bool fromCache})> getUserQuestsWithSource(
    String userId,
  ) async {
    try {
      final rows = await _remoteDataSource.getUserQuests(userId);
      await _localDataSource.cacheUserQuests(rows);
      return (userQuests: rows.map(UserQuest.fromJson).toList(), fromCache: false);
    } catch (_) {
      return (
        userQuests: _localDataSource.getUserQuests().map(UserQuest.fromJson).toList(),
        fromCache: true,
      );
    }
  }

  /// Walked steps per attempt (`user_quests.id`), local-only.
  Map<String, int> getStepTotals() => _localDataSource.getStepTotals();

  Future<void> saveStepTotal(String userQuestId, int steps) =>
      _localDataSource.saveStepTotal(userQuestId, steps);

  StepSession? getActiveStepSession() {
    final json = _localDataSource.getActiveStepSession();
    return json == null ? null : StepSession.fromJson(json);
  }

  Future<void> saveActiveStepSession(StepSession? session) =>
      _localDataSource.saveActiveStepSession(session?.toJson());

  // --- Photo proof (feature f): migration 009 / docs/API_CONTRACT.md. A
  // photo counts only once BOTH the private Storage upload and its
  // quest_photo_proofs row exist. Until then it's kept on the device
  // (Retry tactic) and offered as "Reintentar subida". ---

  /// This attempt's registered proofs, newest first.
  Future<List<QuestPhotoProof>> getPhotoProofs(String attemptId) async {
    try {
      final rows = await _remoteDataSource.getQuestPhotoProofs(attemptId);
      return rows.map(QuestPhotoProof.fromJson).toList();
    } catch (error) {
      throw _photoProofException(error);
    }
  }

  List<PendingPhotoProof> getPendingPhotoProofs() =>
      _localDataSource.getPendingPhotoProofs().map(PendingPhotoProof.fromJson).toList();

  /// Stores a just-captured photo on the device before any network call,
  /// so a failed upload never loses it. One pending photo per step: a new
  /// capture replaces the previous one. The storage path is fixed here
  /// and reused on every retry.
  Future<PendingPhotoProof> savePendingPhotoProof({
    required UserQuest attempt,
    required int stepOrder,
    required Uint8List jpeg,
  }) async {
    if (!isJpeg(jpeg)) throw const AppException('La foto no es JPEG. Toma otra.');
    if (jpeg.length > kQuestProofMaxBytes) {
      throw const AppException('La foto pesa más de 25 MB. Toma otra.');
    }

    final id = _newId();
    final localPath = await _localDataSource.writePendingProofFile('$id.jpg', jpeg);
    final pending = PendingPhotoProof(
      localPath: localPath,
      storagePath: questProofStoragePath(
        userId: attempt.userId,
        attemptId: attempt.id,
        questId: attempt.questId,
        stepOrder: stepOrder,
        uniqueId: id,
      ),
      attemptId: attempt.id,
      questId: attempt.questId,
      stepOrder: stepOrder,
      sizeBytes: jpeg.length,
      capturedAt: DateTime.now(),
    );

    final others = <PendingPhotoProof>[];
    for (final existing in getPendingPhotoProofs()) {
      if (existing.attemptId == attempt.id && existing.stepOrder == stepOrder) {
        await _localDataSource.deletePendingProofFile(existing.localPath);
      } else {
        others.add(existing);
      }
    }
    await _savePending([...others, pending]);
    return pending;
  }

  /// Uploads [pending] and registers it in quest_photo_proofs; deletes the
  /// local copy only after both succeed. On failure throws AppException:
  /// retryable (no connection, server error) keeps the photo for "Reintentar
  /// subida"; not retryable (rejected, invalid) discards it.
  Future<QuestPhotoProof> uploadPendingPhotoProof(PendingPhotoProof pending) async {
    final bytes = await _localDataSource.readPendingProofFile(pending.localPath);
    if (bytes == null) {
      await discardPendingPhotoProof(pending);
      throw const AppException('La foto guardada ya no está en el teléfono. Toma otra.');
    }

    try {
      await _uploadUnlessAlreadyThere(pending.storagePath, bytes);
    } catch (error) {
      throw await _failPending(pending, _photoProofException(error));
    }

    try {
      final row = await _remoteDataSource.insertQuestPhotoProof(
        attemptId: pending.attemptId,
        stepOrder: pending.stepOrder,
        storagePath: pending.storagePath,
      );
      await discardPendingPhotoProof(pending);
      return QuestPhotoProof.fromJson(row);
    } catch (error) {
      // Contract: an upload without its row isn't a proof — remove it. If
      // that fails too (offline), the retry finds it via the 409 below.
      try {
        await _remoteDataSource.removeQuestProof(pending.storagePath);
      } catch (_) {}
      throw await _failPending(pending, _photoProofException(error));
    }
  }

  Future<void> discardPendingPhotoProof(PendingPhotoProof pending) async {
    await _localDataSource.deletePendingProofFile(pending.localPath);
    await _savePending(
      getPendingPhotoProofs().where((p) => p.storagePath != pending.storagePath).toList(),
    );
  }

  /// `upsert: false` answers 409 if the object already exists — only
  /// possible here when a previous try uploaded it but its insert failed
  /// and the cleanup couldn't run. Same path, same bytes: continue.
  Future<void> _uploadUnlessAlreadyThere(String storagePath, Uint8List bytes) async {
    try {
      await _remoteDataSource.uploadQuestProof(storagePath, bytes);
    } on StorageException catch (error) {
      final isDuplicate = error.statusCode == '409' || error.error == 'Duplicate';
      if (!isDuplicate) rethrow;
    }
  }

  Future<AppException> _failPending(PendingPhotoProof pending, AppException error) async {
    if (error.isRetryable) {
      await _savePending([
        for (final p in getPendingPhotoProofs())
          p.storagePath == pending.storagePath ? p.failedWith(error.message) : p,
      ]);
    } else {
      await discardPendingPhotoProof(pending);
    }
    return error;
  }

  Future<void> _savePending(List<PendingPhotoProof> proofs) =>
      _localDataSource.savePendingPhotoProofs(proofs.map((p) => p.toJson()).toList());

  /// StorageException / PostgrestException / network errors -> AppException,
  /// marking which ones are worth retrying.
  AppException _photoProofException(Object error) {
    if (error is AppException) return error;

    if (error is StorageException) {
      // storage_client wraps network failures as StorageException with the
      // error's type name ('ClientException', 'SocketException'...) as the
      // statusCode; real HTTP answers carry a number.
      final status = int.tryParse(error.statusCode ?? '');
      if (status == null || status >= 500 || status == 408 || status == 429) {
        return AppException(status == null ? _offlineMessage : _serverRetryMessage, isRetryable: true);
      }
      return switch (status) {
        413 => const AppException('La foto es demasiado grande. Toma otra.'),
        415 => const AppException('La foto no es JPEG. Toma otra.'),
        401 || 403 => const AppException('Este paso no admite foto o la misión no es tuya.'),
        _ => AppException(error.message),
      };
    }

    if (error is PostgrestException) {
      // 42501 = row-level security rejected the insert (wrong owner, step
      // without photo, object missing).
      if (error.code == '42501') {
        return const AppException('Este paso no admite foto o la misión no es tuya.');
      }
      final status = int.tryParse(error.code ?? '');
      if (status != null && status >= 500) {
        return const AppException(_serverRetryMessage, isRetryable: true);
      }
      return AppException(error.message);
    }

    // SocketException, http.ClientException, TimeoutException: offline.
    return const AppException(_offlineMessage, isRetryable: true);
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

  Future<UserQuest> rateQuest(
    UserQuest userQuest,
    int rating,
    List<String> tags,
  ) async {
    try {
      final json = await _remoteDataSource.rateUserQuest(
        id: userQuest.id,
        userId: userQuest.userId,
        questId: userQuest.questId,
        rating: rating,
        feedbackTags: tags,
      );
      return UserQuest.fromJson(json);
    } on PostgrestException catch (e) {
      throw AppException(e.message);
    }
  }
}
