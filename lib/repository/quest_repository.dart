import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../core/app_exception.dart';
import '../core/photo_proof_rules.dart';
import '../data/cache/memory_cache.dart';
import '../data/local/local_data_source.dart';
import '../data/local/step_log_database.dart';
import '../data/remote/network_guard.dart';
import '../data/remote/supabase_remote_data_source.dart';
import '../models/app_context.dart';
import '../models/explore_filters.dart';
import '../models/pending_write.dart';
import '../models/photo_proof.dart';
import '../models/quest.dart';
import '../models/quest_recommendation.dart';
import '../models/quest_step.dart';
import '../models/step_log_entry.dart';
import '../models/step_session.dart';
import '../models/user_preferences.dart';
import '../models/user_quest.dart';
import '../models/verified_check_in.dart';



/// Single source of truth for the quest catalogue, recommendations and a
/// user's quest progress. Falls back to the cache when the network fails.
class QuestRepository {
  static const _offlineMessage =
      'Sin conexión: tu foto quedó guardada en el teléfono. Reintenta cuando tengas internet.';
  static const _serverRetryMessage = 'No se pudo subir la foto ahora. Inténtalo de nuevo.';
  static const _offlineNoCopyMessage =
      'Sin conexión: no se pudo subir la foto. Tómala de nuevo cuando tengas internet.';
  static const _noCacheMessage =
      'Sin conexión y sin datos guardados en el teléfono. Reintenta cuando tengas internet.';
  static const _offlineWriteMessage =
      'Sin conexión: no se pudo guardar el cambio. Inténtalo de nuevo cuando tengas internet.';

  /// Steps are catalogue content: they only change when someone edits a quest.
  static const stepsCacheTtl = Duration(minutes: 10);
  static const stepsCacheMaxQuests = 20;

  /// Smart Picks (mirror of the Kotlin app's CachedRecommendationRepository):
  /// the same request within 10 minutes is answered from memory.
  static const recommendationsCacheTtl = Duration(minutes: 10);
  static const recommendationsCacheMaxEntries = 16;

  final SupabaseRemoteDataSource _remoteDataSource;
  final LocalDataSource _localDataSource;
  final String Function() _newId;
  final NetworkGuard _network;
  final MemoryCache<String, List<QuestStep>> _stepsCache;
  final MemoryCache<String, RecommendationBatch> _recommendationsCache;
  final StepLogDatabase? _stepLog;
  Future<void>? _syncInFlight;

  /// The last [getCatalog] fell back to the cache. Catches what the
  /// connectivity check can't see, like a Wi-Fi network without internet.
  bool catalogFromCache = false;

  /// The last [getUserQuestsWithSource] fell back to the device, like
  /// [catalogFromCache]. Queued attempts are in that cache too.
  bool userQuestsFromCache = false;

  QuestRepository(
    this._remoteDataSource,
    this._localDataSource, {
    String Function()? newId,
    NetworkGuard network = const NetworkGuard(),
    MemoryCache<String, List<QuestStep>>? stepsCache,
    MemoryCache<String, RecommendationBatch>? recommendationsCache,
    StepLogDatabase? stepLog,
  }) : _newId = newId ?? (() => const Uuid().v4()),
       _network = network,
       _stepLog = stepLog,
       _stepsCache =
           stepsCache ?? MemoryCache(ttl: stepsCacheTtl, maxEntries: stepsCacheMaxQuests),
       _recommendationsCache =
           recommendationsCache ??
           MemoryCache(ttl: recommendationsCacheTtl, maxEntries: recommendationsCacheMaxEntries);

  Future<List<Quest>> getCatalog() async {
    try {
      final rows = await _network.run(_remoteDataSource.getActiveQuests);
      await _localDataSource.cacheQuestCatalog(rows);
      catalogFromCache = false;
      return rows.map(Quest.fromJson).toList();
    } catch (_) {
      catalogFromCache = true;
      return _localDataSource.getQuestCatalog().map(Quest.fromJson).toList();
    }
  }

  /// Whether [getSteps] can answer for [questId] without a connection.
  bool hasCachedSteps(String questId) => _localDataSource.getQuestSteps(questId) != null;

  /// Caching strategy: the detail view, the Misión tab and the prefetch of
  /// recommended missions all ask for the same steps again and again, so a
  /// server answer is kept in memory for [stepsCacheTtl] and repeat reads skip
  /// the network (no request, no spinner). Only server answers are kept there;
  /// a failure is never cached.
  /// Falls back to the Hive cache, so a mission opened once online can still
  /// be followed offline.
  /// Always in step_order, ascending: user_quests.current_step is a position
  /// in this list, so the order must be the same everywhere (and match
  /// Kotlin) — whatever order the server or an older cache returned.
  Future<List<QuestStep>> getSteps(String questId) async {
    final inMemory = _stepsCache.get(questId);
    if (inMemory != null) return inMemory;
    try {
      final rows = await _network.run(() => _remoteDataSource.getQuestSteps(questId));
      await _localDataSource.cacheQuestSteps(questId, rows);
      final steps = List<QuestStep>.unmodifiable(_sortedSteps(rows));
      _stepsCache.put(questId, steps);
      return steps;
    } catch (error) {
      final cached = _localDataSource.getQuestSteps(questId);
      if (cached != null) return _sortedSteps(cached);
      throw error is PostgrestException
          ? AppException(error.message)
          : const AppException(_noCacheMessage, isRetryable: true);
    }
  }

  List<QuestStep> _sortedSteps(List<Map<String, dynamic>> rows) =>
      rows.map(QuestStep.fromJson).toList()..sort((a, b) => a.stepOrder.compareTo(b.stepOrder));

  /// Delegates ranking to the shared `recommend_quests` RPC (BQ5) so Kotlin
  /// and Flutter never duplicate the recommendation logic. Every non-empty
  /// list is saved with its batch id and its missions' steps are prefetched,
  /// so the list and each mission's detail can still be browsed offline.
  ///
  /// Caching (mirror of the Kotlin app's LRU with TTL): the same request
  /// (time, social level, interests, location mode, exclusions, limit) within
  /// [recommendationsCacheTtl] is answered from memory with no network call
  /// ([RecommendationSource.memory]). When the network fails, an older answer
  /// to the same request comes back ([RecommendationSource.staleMemory]),
  /// else the saved list ([RecommendationSource.saved]). The cache is emptied
  /// on sign-out (it's a session cache), so an account never sees another's.
  Future<RecommendationBatch> getRecommendations({
    required AppContext context,
    required UserPreferences preferences,
    List<String> excludedQuestIds = const [],
    int limit = 3,
  }) async {
    final availableMinutes = context.availableMinutes ?? preferences.typicalTimeMinutes;
    final key = jsonEncode([
      availableMinutes,
      preferences.socialLevel,
      [...preferences.interests]..sort(),
      preferences.locationMode,
      [...excludedQuestIds]..sort(),
      limit,
    ]);
    final cached = _recommendationsCache.get(key);
    if (cached != null) {
      return RecommendationBatch(
        recommendations: _withoutUnavailable(cached.recommendations, excludedQuestIds),
        batchId: cached.batchId,
        source: RecommendationSource.memory,
      );
    }

    final List<Map<String, dynamic>> rows;
    try {
      rows = await _network.run(
        () => _remoteDataSource.recommendQuests(
          availableMinutes: availableMinutes,
          socialLevel: preferences.socialLevel,
          interests: preferences.interests,
          locationMode: preferences.locationMode,
          excludedQuestIds: excludedQuestIds,
          limit: limit,
        ),
      );
    } on PostgrestException catch (e) {
      throw AppException(e.message);
    } catch (_) {
      final stale = _recommendationsCache.getStale(key);
      if (stale != null) {
        return RecommendationBatch(
          recommendations: _withoutUnavailable(stale.recommendations, excludedQuestIds),
          batchId: stale.batchId,
          source: RecommendationSource.staleMemory,
        );
      }
      return _savedRecommendations(excludedQuestIds);
    }

    final batchId = _newId();
    final recommendations = rows.map(QuestRecommendation.fromJson).toList();
    final batch = RecommendationBatch(recommendations: recommendations, batchId: batchId);
    _recommendationsCache.put(key, batch);
    // An empty answer (e.g. a narrow filter) must not erase a usable list.
    if (rows.isNotEmpty) {
      try {
        await _localDataSource.saveRecommendations(batchId, rows);
      } catch (_) {
        // Not saved this time; the list itself is still good to show.
      }
      unawaited(_prefetchSteps(recommendations));
    }
    return batch;
  }

  /// For Explore to show right away when the catalog already fell back to the
  /// cache, instead of waiting out another request first. Null if none is saved.
  RecommendationBatch? savedRecommendations(List<String> excludedQuestIds) {
    if (_localDataSource.getSavedRecommendations() == null) return null;
    return _savedRecommendations(excludedQuestIds);
  }

  /// The saved list, minus what stopped making sense since it was saved:
  /// quests skipped this session and quests already started or completed.
  RecommendationBatch _savedRecommendations(List<String> excludedQuestIds) {
    final saved = _localDataSource.getSavedRecommendations();
    if (saved == null) throw const AppException(_noCacheMessage, isRetryable: true);

    return RecommendationBatch(
      recommendations: _withoutUnavailable(
        saved.rows.map(QuestRecommendation.fromJson).toList(),
        excludedQuestIds,
      ),
      batchId: saved.batchId,
      fromCache: true,
    );
  }

  /// A list answered earlier (saved, or in memory), minus what stopped making
  /// sense since: quests skipped this session and quests already started or
  /// completed.
  List<QuestRecommendation> _withoutUnavailable(
    List<QuestRecommendation> recommendations,
    List<String> excludedQuestIds,
  ) {
    List<Map<String, dynamic>> attempts;
    try {
      attempts = _localDataSource.getUserQuests();
    } catch (_) {
      attempts = const [];
    }
    final unavailable = {
      ...excludedQuestIds,
      for (final row in attempts)
        if (const {'accepted', 'in_progress', 'completed'}.contains(row['status']))
          row['quest_id'] as String,
    };
    return recommendations
        .where((recommendation) => !unavailable.contains(recommendation.questId))
        .toList();
  }

  /// Best effort, one request per mission not cached yet: opening a mission
  /// online refreshes its steps anyway.
  Future<void> _prefetchSteps(List<QuestRecommendation> recommendations) async {
    for (final recommendation in recommendations) {
      if (_localDataSource.getQuestSteps(recommendation.questId) != null) continue;
      try {
        await getSteps(recommendation.questId);
      } catch (_) {
        // Connection dropped: the next list tries again.
      }
    }
  }

  Future<List<UserQuest>> getUserQuests(String userId) async =>
      (await getUserQuestsWithSource(userId)).userQuests;

  /// Same as [getUserQuests], but also says whether it fell back to the
  /// Hive cache — so a view can tell "offline, last known data" apart from
  /// fresh data, and "offline with nothing cached" apart from "empty".
  /// Pending writes go first, so app start and every reconnection sync them
  /// (and before anything that needs their rows, like retried photo uploads).
  /// The sync and the read share one timeout: past it the sync goes on in the
  /// background, and the cache answers.
  Future<({List<UserQuest> userQuests, bool fromCache})> getUserQuestsWithSource(
    String userId,
  ) async {
    try {
      final serverRows = await _network.run(() async {
        await syncPendingWrites();
        return _remoteDataSource.getUserQuests(userId);
      });
      final rows = _withUnsentWrites(_withUnsyncedAttempts(serverRows, userId));
      await _localDataSource.cacheUserQuests(rows);
      await _saveUserQuestsSyncedAt();
      userQuestsFromCache = false;
      return (userQuests: rows.map(UserQuest.fromJson).toList(), fromCache: false);
    } catch (_) {
      userQuestsFromCache = true;
      return (
        userQuests: _localDataSource.getUserQuests().map(UserQuest.fromJson).toList(),
        fromCache: true,
      );
    }
  }

  /// Local storage strategy: when [getUserQuestsWithSource] last got the
  /// attempts from the server, saved in Hive next to them, so it survives a
  /// restart. Without a connection the attempts come from that copy, and this
  /// says how old it is (MissionHistoryView shows it). Null if the server
  /// never answered on this device.
  DateTime? userQuestsSyncedAt() => _localDataSource.getUserQuestsSyncedAt();

  /// Best effort, like saving the recommendations: a date that couldn't be
  /// saved must not turn a fresh read into an offline one.
  Future<void> _saveUserQuestsSyncedAt() async {
    try {
      await _localDataSource.saveUserQuestsSyncedAt(DateTime.now());
    } catch (_) {
      // Not saved this time; the attempts themselves are still fresh.
    }
  }

  /// Write-through of an attempt the backend just saved: replaces its
  /// cached copy, or adds it, at the front — the list is newest first. So
  /// the offline fallback never shows a stale status or misses a mission.
  Future<UserQuest> _cacheUserQuest(Map<String, dynamic> json) async {
    await _localDataSource.cacheUserQuests([
      json,
      ..._localDataSource.getUserQuests().where((row) => row['id'] != json['id']),
    ]);
    return UserQuest.fromJson(json);
  }

  /// The server's answer plus the attempts it can't know about yet: a read
  /// that replaced the cache with it alone would lose a queued mission.
  List<Map<String, dynamic>> _withUnsyncedAttempts(List<Map<String, dynamic>> rows, String userId) {
    final unsyncedIds = _unsyncedAttemptIds();
    if (unsyncedIds.isEmpty) return rows;
    final serverIds = rows.map((row) => row['id']).toSet();
    return [
      ..._localDataSource.getUserQuests().where(
        (row) =>
            row['user_id'] == userId &&
            unsyncedIds.contains(row['id']) &&
            !serverIds.contains(row['id']),
      ),
      ...rows,
    ];
  }

  /// Same for ratings and abandonments: the server's row doesn't have them yet.
  List<Map<String, dynamic>> _withUnsentWrites(List<Map<String, dynamic>> rows) {
    final unsent = <Object?, Map<String, dynamic>>{};
    for (final write in _pendingWrites()) {
      if (write.type == PendingWrite.rateQuest) {
        (unsent[write.payload['id']] ??= {}).addAll({
          'rating': write.payload['rating'],
          'feedback_tags': write.payload['feedback_tags'],
        });
      } else if (write.type == PendingWrite.abandonQuest) {
        (unsent[write.payload['id']] ??= {}).addAll({
          'status': write.payload['status'],
          'abandon_reason': write.payload['abandon_reason'],
          'abandoned_at': write.payload['abandoned_at'],
        });
      }
    }
    if (unsent.isEmpty) return rows;
    return [
      for (final row in rows)
        if (unsent[row['id']] case final columns?) {...row, ...columns} else row,
    ];
  }

  /// Attempts with a write still waiting for a connection — an acceptance, a
  /// rating or an abandonment: what the device shows that the server doesn't
  /// have yet. Read it after [getUserQuestsWithSource], which syncs first.
  Set<String> pendingSyncAttemptIds() => {
    for (final write in _pendingWrites())
      if (write.payload['id'] case final String id) id,
  };

  Set<String> _unsyncedAttemptIds() => {
    for (final write in _pendingWrites())
      if (write.type == PendingWrite.acceptQuest) write.payload['id'] as String,
  };

  List<PendingWrite> _pendingWrites() =>
      _localDataSource.getPendingWrites().map(PendingWrite.fromJson).toList();

  /// Sends the queued writes, oldest first; an entry leaves the queue only
  /// when the server answered. A failure that can pass (no connection, expired
  /// session, server down) stops here and keeps the rest for the next sync; a
  /// rejection discards that entry and moves on. Never throws, and concurrent
  /// callers share one run.
  Future<void> syncPendingWrites() => _syncInFlight ??= _flushPendingWrites().whenComplete(() {
    _syncInFlight = null;
  });

  Future<void> _flushPendingWrites() async {
    try {
      if (await _network.isOffline) return;
      while (true) {
        final pending = _pendingWrites();
        if (pending.isEmpty) return;
        final write = pending.first;
        try {
          await _sendPendingWrite(write);
        } on PostgrestException catch (e) {
          if (_canPass(e)) return;
          debugPrint('Pending ${write.type} rejected, discarding it: ${e.code} ${e.message}');
          await _undoPendingWrite(write);
        }
        // Re-read: writes queued while that one was in flight stay behind it.
        await _localDataSource.savePendingWrites(
          _localDataSource.getPendingWrites().skip(1).toList(),
        );
      }
    } catch (_) {
      // Still offline: the rest waits for the next sync.
    }
  }

  Future<void> _sendPendingWrite(PendingWrite write) async {
    switch (write.type) {
      case PendingWrite.acceptQuest:
        await _network.run(() => _remoteDataSource.insertUserQuestIfAbsent(write.payload));
      case PendingWrite.rateQuest:
        await _network.run(
          () => _remoteDataSource.rateUserQuest(
            id: write.payload['id'] as String,
            userId: write.payload['user_id'] as String,
            questId: write.payload['quest_id'] as String,
            rating: write.payload['rating'] as int,
            feedbackTags: (write.payload['feedback_tags'] as List).cast<String>(),
          ),
        );
      case PendingWrite.abandonQuest:
        await _network.run(() => _remoteDataSource.upsertUserQuest(write.payload));
      default:
        debugPrint('Unknown pending write ${write.type}, discarding it');
    }
  }

  /// The server said no: the mission that only existed on this device goes,
  /// and so does what's queued behind it — a rating is an upsert, and sending
  /// it would create the row that was just rejected. A rejected rating or
  /// abandonment just leaves: the next read replaces the cached one with the
  /// server's.
  Future<void> _undoPendingWrite(PendingWrite write) async {
    if (write.type != PendingWrite.acceptQuest) return;
    final attemptId = write.payload['id'];
    await _localDataSource.cacheUserQuests(
      _localDataSource.getUserQuests().where((row) => row['id'] != attemptId).toList(),
    );
    final queue = _localDataSource.getPendingWrites();
    await _localDataSource.savePendingWrites([
      queue.first, // the caller removes this one
      ...queue.skip(1).where((entry) => (entry['payload'] as Map)['id'] != attemptId),
    ]);
  }

  /// Whether a server error can go away on its own, as opposed to a real
  /// rejection. A session that expired while offline lands here too (401 /
  /// PGRST30x): discarding on it would lose the mission for nothing.
  static bool _canPass(PostgrestException error) {
    final code = error.code ?? '';
    final httpStatus = code.length == 3 ? int.tryParse(code) : null;
    if (httpStatus != null) {
      return httpStatus == 401 || httpStatus == 408 || httpStatus == 429 || httpStatus >= 500;
    }
    // PostgREST: can't reach the database, JWT. SQLSTATE: connection,
    // serialization/deadlock, out of resources, shutting down.
    return const ['PGRST0', 'PGRST30', '08', '40', '53', '57'].any(code.startsWith);
  }

  /// Explore's last filters, or the defaults on a first launch. Local-only.
  ExploreFilters getExploreFilters() {
    final json = _localDataSource.getExploreFilters();
    return json == null ? const ExploreFilters() : ExploreFilters.fromJson(json);
  }

  Future<void> saveExploreFilters(ExploreFilters filters) =>
      _localDataSource.saveExploreFilters(filters.toJson());

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

  /// Saves a finished walk in SQLite. A walk without steps isn't one, and
  /// without a database (web build) there's nowhere to keep it. Never throws:
  /// a storage failure must not stop the mission it came from.
  Future<void> logWalk(StepLogEntry walk) async {
    final stepLog = _stepLog;
    if (stepLog == null || walk.steps <= 0) return;
    try {
      await stepLog.insertOrReplace(walk);
    } catch (error) {
      debugPrint('Step log: walk not saved ($error)');
    }
  }

  static const WalkStats _noWalks = (recentSteps: 0, stepsByCategory: [], longestWalk: null);

  /// The walks for "Mis estadísticas", all from the device. Empty when there's
  /// no database or it can't be read: the rest of the screen still loads.
  Future<WalkStats> getWalkStats({required DateTime since}) async {
    final stepLog = _stepLog;
    if (stepLog == null) return _noWalks;
    try {
      final (recentSteps, stepsByCategory, longestWalk) = await (
        stepLog.stepsSince(since),
        stepLog.stepsByCategory(),
        stepLog.topWalk(),
      ).wait;
      return (recentSteps: recentSteps, stepsByCategory: stepsByCategory, longestWalk: longestWalk);
    } catch (error) {
      debugPrint('Step log: walks not read ($error)');
      return _noWalks;
    }
  }

  /// A location check-in waiting for a connection, local-only: QuestViewModel
  /// completes the step itself once it can, so nothing is queued here.
  VerifiedCheckIn? getVerifiedCheckIn() {
    final json = _localDataSource.getVerifiedCheckIn();
    return json == null ? null : VerifiedCheckIn.fromJson(json);
  }

  Future<void> saveVerifiedCheckIn(VerifiedCheckIn? checkIn) =>
      _localDataSource.saveVerifiedCheckIn(checkIn?.toJson());

  // --- Photo proof (feature f): migration 009 / docs/API_CONTRACT.md. A
  // photo counts only once BOTH the private Storage upload and its
  // quest_photo_proofs row exist. Until then it's kept on the device
  // (Retry tactic) and offered as "Reintentar subida". ---

  /// This attempt's registered proofs, newest first. Falls back to the
  /// cache, so the photo evidence survives an app restart offline.
  Future<List<QuestPhotoProof>> getPhotoProofs(String attemptId) async {
    try {
      final rows = await _network.run(() => _remoteDataSource.getQuestPhotoProofs(attemptId));
      await _localDataSource.cachePhotoProofs(attemptId, rows);
      return rows.map(QuestPhotoProof.fromJson).toList();
    } catch (error) {
      final cached = _localDataSource.getPhotoProofs(attemptId);
      if (cached != null) return cached.map(QuestPhotoProof.fromJson).toList();
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
    String? verificationType,
  }) async {
    _checkPhoto(jpeg);

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
      verificationType: verificationType,
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

    if (await _network.isOffline || !await _attemptReachedServer(pending.attemptId)) {
      throw await _failPending(pending, const AppException(_offlineMessage, isRetryable: true));
    }

    try {
      await _uploadUnlessAlreadyThere(pending.storagePath, bytes);
    } catch (error) {
      throw await _failPending(pending, _photoProofException(error));
    }

    final Map<String, dynamic> row;
    try {
      row = await _remoteDataSource.insertQuestPhotoProof(
        attemptId: pending.attemptId,
        stepOrder: pending.stepOrder,
        storagePath: pending.storagePath,
      );
    } catch (error) {
      // Contract: an upload without its row isn't a proof — remove it. If
      // that fails too (offline), the retry finds it via the 409 below.
      try {
        await _remoteDataSource.removeQuestProof(pending.storagePath);
      } catch (_) {}
      throw await _failPending(pending, _photoProofException(error));
    }

    // Outside the try above: a local failure must never undo a proof the
    // backend already has.
    await discardPendingPhotoProof(pending);
    await _localDataSource.cachePhotoProofs(pending.attemptId, [
      row,
      ...?_localDataSource.getPhotoProofs(pending.attemptId),
    ]);
    return QuestPhotoProof.fromJson(row);
  }

  /// Whether a photo can wait on the device for its upload (Retry tactic).
  /// False on the web build — see [uploadPhotoProofDirectly].
  bool get canKeepPhotosOnDevice => _localDataSource.canKeepPhotoFiles;

  /// Web build: uploads and registers the photo straight from memory. Same
  /// contract as [uploadPendingPhotoProof] (JPEG check, remove the object
  /// if the insert fails), but with nowhere to keep the photo there's no
  /// "Reintentar subida": a failure asks for a new photo.
  Future<QuestPhotoProof> uploadPhotoProofDirectly({
    required UserQuest attempt,
    required int stepOrder,
    required Uint8List jpeg,
  }) async {
    _checkPhoto(jpeg);
    if (await _network.isOffline || !await _attemptReachedServer(attempt.id)) {
      throw const AppException(_offlineNoCopyMessage, isRetryable: true);
    }
    final storagePath = questProofStoragePath(
      userId: attempt.userId,
      attemptId: attempt.id,
      questId: attempt.questId,
      stepOrder: stepOrder,
      uniqueId: _newId(),
    );

    try {
      await _remoteDataSource.uploadQuestProof(storagePath, jpeg);
    } catch (error) {
      throw _directUploadException(error);
    }

    final Map<String, dynamic> row;
    try {
      row = await _remoteDataSource.insertQuestPhotoProof(
        attemptId: attempt.id,
        stepOrder: stepOrder,
        storagePath: storagePath,
      );
    } catch (error) {
      try {
        await _remoteDataSource.removeQuestProof(storagePath);
      } catch (_) {}
      throw _directUploadException(error);
    }

    await _localDataSource.cachePhotoProofs(attempt.id, [
      row,
      ...?_localDataSource.getPhotoProofs(attempt.id),
    ]);
    return QuestPhotoProof.fromJson(row);
  }

  /// RLS (migration 009) rejects a proof whose attempt isn't on the server
  /// yet, and a rejected photo is discarded: an attempt still in the queue
  /// must get there first, or its photos wait.
  Future<bool> _attemptReachedServer(String attemptId) async {
    if (!_unsyncedAttemptIds().contains(attemptId)) return true;
    await syncPendingWrites();
    return !_unsyncedAttemptIds().contains(attemptId);
  }

  void _checkPhoto(Uint8List jpeg) {
    if (!isJpeg(jpeg)) throw const AppException('La foto no es JPEG. Toma otra.');
    if (jpeg.length > kQuestProofMaxBytes) {
      throw const AppException('La foto pesa más de 25 MB. Toma otra.');
    }
  }

  /// Like [_photoProofException], but never promises the photo was kept.
  AppException _directUploadException(Object error) {
    final exception = _photoProofException(error);
    return exception.message == _offlineMessage
        ? const AppException(_offlineNoCopyMessage, isRetryable: true)
        : exception;
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
    final json = await _remoteWrite(
      () => _remoteDataSource.upsertUserQuest({
        'user_id': userId,
        'quest_id': questId,
        'status': 'accepted',
      }),
    );
    await _localDataSource.cacheActiveQuestId(questId);
    return _cacheUserQuest(json);
  }

  /// The user's attempt at [questId] that is still being done, from the
  /// device; null if there is none. "Empezar ya" tapped again on a mission
  /// already started opens that one instead of starting a second attempt.
  ///
  /// A new mission is never started on the device: its progress can only be
  /// saved on the server, so starting one needs a connection ([acceptQuest]
  /// fails right away without one). Acceptances queued by earlier versions
  /// are still synced by [syncPendingWrites].
  UserQuest? activeAttempt({required String userId, required String questId}) {
    for (final row in _localDataSource.getUserQuests()) {
      final isActive = row['status'] == 'accepted' || row['status'] == 'in_progress';
      if (row['user_id'] == userId && row['quest_id'] == questId && isActive) {
        return UserQuest.fromJson(row);
      }
    }
    return null;
  }

  Future<UserQuest> updateProgress(UserQuest userQuest) async {
    final json = await _progressWrite({
      'id': userQuest.id,
      'user_id': userQuest.userId,
      'quest_id': userQuest.questId,
      'status': userQuest.status,
      'current_step': userQuest.currentStep,
      'completed_steps': userQuest.completedSteps,
    });
    return _cacheUserQuest(json);
  }

  /// A progress write goes after what's queued, within one timeout: otherwise
  /// the abandonment, older but sent later, would have the last word over
  /// newer data, and an attempt still queued as abandoned can't move forward.
  Future<Map<String, dynamic>> _progressWrite(Map<String, dynamic> row) => _remoteWrite(() async {
    if (_localDataSource.getPendingWrites().isNotEmpty) {
      await syncPendingWrites();
      final stillAbandoning = _pendingWrites().any(
        (write) => write.type == PendingWrite.abandonQuest && write.payload['id'] == row['id'],
      );
      if (stillAbandoning) throw const AppException(_offlineWriteMessage, isRetryable: true);
    }
    return _remoteDataSource.upsertUserQuest(row);
  });

  Future<UserQuest> abandonQuest(UserQuest userQuest, {required String reason}) async {
    final json = await _remoteWrite(
      () => _remoteDataSource.upsertUserQuest({
        'id': userQuest.id,
        'user_id': userQuest.userId,
        'quest_id': userQuest.questId,
        'status': 'abandoned',
        'abandon_reason': reason,
      }),
    );
    await _localDataSource.cacheActiveQuestId(null);
    return _cacheUserQuest(json);
  }

  /// Like [abandonQuest], but without a connection the mission is closed on
  /// the device and the abandonment is queued, with the moment it happened. An
  /// attempt whose acceptance is still queued goes first, so the abandonment
  /// always reaches the server after it.
  Future<({UserQuest userQuest, bool queued})> abandonQuestOrQueue(
    UserQuest userQuest, {
    required String reason,
  }) async {
    if (await _attemptReachedServer(userQuest.id)) {
      try {
        return (userQuest: await abandonQuest(userQuest, reason: reason), queued: false);
      } on AppException catch (error) {
        if (!error.isRetryable) rethrow;
      }
    }
    return (userQuest: await _queueAbandonment(userQuest, reason), queued: true);
  }

  /// Fails like [abandonQuest] if it can't be kept, so the mission stays active
  /// instead of looking abandoned on a device that will never send it.
  Future<UserQuest> _queueAbandonment(UserQuest userQuest, String reason) async {
    try {
      final cached = _localDataSource.getUserQuests().firstWhere(
        (row) => row['id'] == userQuest.id,
      );
      final now = DateTime.now().toUtc();
      final payload = {
        'id': userQuest.id,
        'user_id': userQuest.userId,
        'quest_id': userQuest.questId,
        'status': 'abandoned',
        'abandon_reason': reason,
        'abandoned_at': now.toIso8601String(),
      };
      final write = PendingWrite(type: PendingWrite.abandonQuest, payload: payload, createdAt: now);
      await _localDataSource.savePendingWrites([
        ..._localDataSource.getPendingWrites(),
        write.toJson(),
      ]);
      await _localDataSource.cacheActiveQuestId(null);
      return await _cacheUserQuest({...cached, ...payload});
    } catch (_) {
      throw const AppException(_offlineWriteMessage, isRetryable: true);
    }
  }

  Future<UserQuest> completeQuest(UserQuest userQuest) async {
    final json = await _progressWrite({
      'id': userQuest.id,
      'user_id': userQuest.userId,
      'quest_id': userQuest.questId,
      'status': 'completed',
    });
    await _localDataSource.cacheActiveQuestId(null);
    return _cacheUserQuest(json);
  }

  Future<UserQuest> rateQuest(
    UserQuest userQuest,
    int rating,
    List<String> tags,
  ) async {
    final json = await _remoteWrite(
      () => _remoteDataSource.rateUserQuest(
        id: userQuest.id,
        userId: userQuest.userId,
        questId: userQuest.questId,
        rating: rating,
        feedbackTags: tags,
      ),
    );
    return _cacheUserQuest(json);
  }

  /// Like [rateQuest], but without a connection the rating stays on the device
  /// and is queued. An attempt whose acceptance is still queued goes first, so
  /// the rating always reaches the server after it.
  Future<({UserQuest userQuest, bool queued})> rateQuestOrQueue(
    UserQuest userQuest,
    int rating,
    List<String> tags,
  ) async {
    if (await _attemptReachedServer(userQuest.id)) {
      try {
        return (userQuest: await rateQuest(userQuest, rating, tags), queued: false);
      } on AppException catch (error) {
        if (!error.isRetryable) rethrow;
      }
    }
    return (userQuest: await _queueRating(userQuest, rating, tags), queued: true);
  }

  /// Rates the cached row, not [userQuest]: QuestCompletedView holds the copy
  /// from before the mission was completed, and caching that would bring the
  /// finished mission back as active. Fails like [rateQuest] if it can't be
  /// kept, so the view offers "Reintentar" instead of losing the rating.
  Future<UserQuest> _queueRating(UserQuest userQuest, int rating, List<String> tags) async {
    try {
      final cached = _localDataSource.getUserQuests().firstWhere(
        (row) => row['id'] == userQuest.id,
      );
      final write = PendingWrite(
        type: PendingWrite.rateQuest,
        payload: {
          'id': userQuest.id,
          'user_id': userQuest.userId,
          'quest_id': userQuest.questId,
          'rating': rating,
          'feedback_tags': tags,
        },
        createdAt: DateTime.now(),
      );
      await _localDataSource.savePendingWrites([
        ..._localDataSource.getPendingWrites(),
        write.toJson(),
      ]);
      return await _cacheUserQuest({...cached, 'rating': rating, 'feedback_tags': tags});
    } catch (_) {
      throw const AppException(_offlineWriteMessage, isRetryable: true);
    }
  }

  /// The backend half of a mission write. A PostgREST rejection keeps its
  /// message; anything else means no answer came back — postgrest rethrows
  /// SocketException/ClientException/TimeoutException unwrapped — so it's
  /// reported as offline and retryable instead of escaping the ViewModel. So is
  /// [NetworkGuard]'s no-network and timeout.
  Future<T> _remoteWrite<T>(Future<T> Function() write) async {
    try {
      return await _network.run(write);
    } on PostgrestException catch (e) {
      throw AppException(e.message);
    } catch (_) {
      throw const AppException(_offlineWriteMessage, isRetryable: true);
    }
  }
}
