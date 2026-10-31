import 'dart:convert';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sidequests/analytics/analytics_event_sink.dart';
import 'package:sidequests/analytics/analytics_event_type.dart';
import 'package:sidequests/analytics/analytics_tracker.dart';
import 'package:sidequests/core/app_exception.dart';
import 'package:sidequests/core/verification/step_verification_strategy.dart';
import 'package:sidequests/data/context/context_manager.dart';
import 'package:sidequests/data/local/local_data_source.dart';
import 'package:sidequests/data/remote/supabase_remote_data_source.dart';
import 'package:sidequests/data/services/battery_monitor.dart';
import 'package:sidequests/data/services/location_check_in_service.dart';
import 'package:sidequests/data/services/location_service.dart';
import 'package:sidequests/data/services/step_counter_service.dart';
import 'package:sidequests/models/app_context.dart';
import 'package:sidequests/models/pending_write.dart';
import 'package:sidequests/models/quest.dart';
import 'package:sidequests/models/user_preferences.dart';
import 'package:sidequests/models/user_quest.dart';
import 'package:sidequests/models/verified_check_in.dart';
import 'package:sidequests/repository/auth_repository.dart';
import 'package:sidequests/repository/profile_repository.dart';
import 'package:sidequests/repository/quest_repository.dart';
import 'package:sidequests/view/quests/explore_view.dart';
import 'package:sidequests/view/quests/mission_tab_view.dart';
import 'package:sidequests/viewmodel/profile/profile_view_model.dart';
import 'package:sidequests/viewmodel/quests/quest_view_model.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _userId = 'user-1';
const _context = AppContext(timeOfDay: 'afternoon', dayOfWeek: 'monday', isConnected: true);
const _savedLabel = 'Recomendaciones guardadas';
const _queuedNotice = 'Misión iniciada sin conexión: se sincronizará al reconectar';

const _rejected = PostgrestException(message: 'new row violates RLS', code: '42501');

Map<String, dynamic> _questRow(String id) => {
  'id': id,
  'title': 'Quest $id',
  'category': 'food',
  'duration_minutes': 20,
  'difficulty': 'easy',
  'location_mode': 'anywhere',
  'social_level': 'solo',
};

Map<String, dynamic> _recommendationRow(String id, int rank) => {
  'quest_id': id,
  'score': 1.5,
  'variant': 'control',
  'rank_position': rank,
};

/// Supabase in memory. [offline] fails every call like a dropped connection.
class _FakeRemote implements SupabaseRemoteDataSource {
  bool offline = false;

  /// Only the queued-write call: the read after it can still go through.
  Object? syncError;

  /// The upsert reaches the server, but its answer never comes back.
  bool loseUpsertAnswer = false;
  int queuedWritesSent = 0;
  final List<String> uploads = [];

  List<Map<String, dynamic>> recommendations = [
    _recommendationRow('a', 1),
    _recommendationRow('b', 2),
  ];
  final Map<String, List<Map<String, dynamic>>> steps = {
    'a': [
      {'id': 1, 'quest_id': 'a', 'step_order': 0, 'title': 'Paso a'},
    ],
    'b': [
      {'id': 2, 'quest_id': 'b', 'step_order': 0, 'title': 'Paso b'},
    ],
  };
  final List<Map<String, dynamic>> userQuests = [];

  void _failIfDown() {
    if (offline) throw const SocketException('offline');
  }

  @override
  Future<List<Map<String, dynamic>>> getActiveQuests() async {
    _failIfDown();
    return [_questRow('a'), _questRow('b')];
  }

  @override
  Future<List<Map<String, dynamic>>> recommendQuests({
    required int availableMinutes,
    required String socialLevel,
    List<String> interests = const [],
    String locationMode = 'all',
    List<String> excludedQuestIds = const [],
    int limit = 3,
  }) async {
    _failIfDown();
    return recommendations;
  }

  @override
  Future<List<Map<String, dynamic>>> getQuestSteps(String questId) async {
    _failIfDown();
    return steps[questId] ?? [];
  }

  @override
  Future<List<Map<String, dynamic>>> getUserQuests(String userId) async {
    _failIfDown();
    return [...userQuests];
  }

  @override
  Future<Map<String, dynamic>> upsertUserQuest(Map<String, dynamic> userQuest) async {
    _failIfDown();
    final existing = userQuests.where((row) => row['id'] == userQuest['id']).firstOrNull;
    final row = {'accepted_at': '2026-10-01T10:00:00Z', ...?existing, ...userQuest};
    userQuests
      ..removeWhere((r) => r['id'] == row['id'])
      ..insert(0, row);
    if (loseUpsertAnswer) throw const SocketException('answer lost');
    return row;
  }

  @override
  Future<void> insertUserQuestIfAbsent(Map<String, dynamic> userQuest) async {
    _failIfDown();
    if (syncError != null) throw syncError!;
    queuedWritesSent++;
    if (userQuests.any((row) => row['id'] == userQuest['id'])) return;
    userQuests.insert(0, {...userQuest});
  }

  @override
  Future<void> uploadQuestProof(String storagePath, Uint8List jpeg) async {
    _failIfDown();
    uploads.add(storagePath);
  }

  @override
  Future<Map<String, dynamic>> insertQuestPhotoProof({
    required String attemptId,
    required int stepOrder,
    required String storagePath,
  }) async {
    _failIfDown();
    return {
      'id': 'proof-1',
      'attempt_id': attemptId,
      'step_order': stepOrder,
      'storage_path': storagePath,
      'uploaded_at': '2026-10-01T12:00:00Z',
    };
  }

  @override
  Future<Map<String, dynamic>> getProfile(String userId) async {
    _failIfDown();
    return {'id': userId, 'display_name': 'Ana'};
  }

  @override
  Future<Map<String, dynamic>> getPreferences(String userId) async {
    _failIfDown();
    return {'user_id': userId};
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// The Hive box, in memory.
class _FakeLocal implements LocalDataSource {
  ({String batchId, List<Map<String, dynamic>> rows})? saved;
  List<Map<String, dynamic>> pendingWrites = [];
  List<Map<String, dynamic>> userQuests = [];
  List<Map<String, dynamic>> pendingPhotos = [];
  List<Map<String, dynamic>> catalog = [];
  final Map<String, List<Map<String, dynamic>>> steps = {};
  final Map<String, List<Map<String, dynamic>>> proofs = {};
  final Map<String, Uint8List> files = {};

  @override
  ({String batchId, List<Map<String, dynamic>> rows})? getSavedRecommendations() => saved;

  @override
  Future<void> saveRecommendations(String batchId, List<Map<String, dynamic>> rows) async =>
      saved = (batchId: batchId, rows: rows);

  @override
  List<Map<String, dynamic>> getPendingWrites() => [...pendingWrites];

  @override
  Future<void> savePendingWrites(List<Map<String, dynamic>> writes) async => pendingWrites = writes;

  @override
  List<Map<String, dynamic>> getUserQuests() => [...userQuests];

  @override
  Future<void> cacheUserQuests(List<Map<String, dynamic>> rows) async => userQuests = rows;

  @override
  List<Map<String, dynamic>> getQuestCatalog() => catalog;

  @override
  Future<void> cacheQuestCatalog(List<Map<String, dynamic>> quests) async => catalog = quests;

  @override
  List<Map<String, dynamic>>? getQuestSteps(String questId) => steps[questId];

  @override
  Future<void> cacheQuestSteps(String questId, List<Map<String, dynamic>> rows) async =>
      steps[questId] = rows;

  @override
  Future<void> cacheActiveQuestId(String? questId) async {}

  @override
  List<Map<String, dynamic>> getPendingPhotoProofs() => [...pendingPhotos];

  @override
  Future<void> savePendingPhotoProofs(List<Map<String, dynamic>> photos) async =>
      pendingPhotos = photos;

  @override
  Future<String> writePendingProofFile(String fileName, Uint8List bytes) async {
    files[fileName] = bytes;
    return fileName;
  }

  @override
  Future<Uint8List?> readPendingProofFile(String path) async => files[path];

  @override
  Future<void> deletePendingProofFile(String path) async => files.remove(path);

  @override
  List<Map<String, dynamic>>? getPhotoProofs(String attemptId) => proofs[attemptId];

  @override
  Future<void> cachePhotoProofs(String attemptId, List<Map<String, dynamic>> rows) async =>
      proofs[attemptId] = rows;

  @override
  Map<String, dynamic>? getActiveStepSession() => null;

  @override
  Map<String, dynamic>? getVerifiedCheckIn() => null;

  @override
  Map<String, dynamic>? getExploreFilters() => null;

  @override
  Future<void> saveExploreFilters(Map<String, dynamic> filters) async {}

  @override
  Map<String, dynamic>? getProfile() => null;

  @override
  Future<void> cacheProfile(Map<String, dynamic> profile) async {}

  @override
  Map<String, dynamic>? getPreferences() => null;

  @override
  Future<void> cachePreferences(Map<String, dynamic> preferences) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _NoLocation extends LocationService {
  @override
  Future<Position?> getCurrentPosition({
    LocationAccuracy accuracy = LocationAccuracy.medium,
  }) async => null;
}

class _FullBattery extends BatteryMonitor {
  @override
  Future<bool> isLow() async => false;
}

class _NullSink implements AnalyticsEventSink {
  @override
  Future<void> insertAnalyticsEvent(Map<String, dynamic> event) async {}
}

/// The real plugin's channel never answers under testWidgets' fake clock.
class _FakeConnectivity implements Connectivity {
  @override
  Future<List<ConnectivityResult>> checkConnectivity() async => [ConnectivityResult.none];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

ContextManager _contextManager() => ContextManager(
  locationService: _NoLocation(),
  batteryMonitor: _FullBattery(),
  connectivity: _FakeConnectivity(),
);

class _SpyTracker extends AnalyticsTracker {
  final List<({String type, Map<String, dynamic> metadata})> calls = [];

  _SpyTracker()
    : super(eventSink: _NullSink(), contextManager: _contextManager(), sessionId: 'unused');

  @override
  Future<void> track(
    String eventType, {
    String? questId,
    String? category,
    int? availableMinutes,
    String? socialLevel,
    String? locationMode,
    int? questDurationMinutes,
    String? questDifficulty,
    double? estimatedCost,
    double? questLatitude,
    double? questLongitude,
    Map<String, dynamic> metadata = const {},
  }) async => calls.add((type: eventType, metadata: metadata));

  Iterable<Map<String, dynamic>> of(String type) =>
      calls.where((call) => call.type == type).map((call) => call.metadata);
}

Quest _quest(String id) => Quest.fromJson(_questRow(id));

void main() {
  late _FakeRemote remote;
  late _FakeLocal local;
  late QuestRepository repository;
  late _SpyTracker tracker;
  late int nextId;

  QuestRepository newRepository(LocalDataSource source) =>
      QuestRepository(remote, source, newId: () => 'uuid-${++nextId}');

  QuestViewModel newViewModel(QuestRepository questRepository) => QuestViewModel(
    questRepository,
    _contextManager(),
    tracker,
    _userId,
    stepCounter: StepCounterService(requestAccess: () async => StepCounterStatus.unavailable),
    locationCheckIn: LocationCheckInService(
      requestAccess: () async => LocationAccess.granted,
      isLowBattery: () async => false,
      isOffline: () async => false,
      offlineChanges: () => const Stream.empty(),
      positions: (_, _) => const Stream.empty(),
    ),
  );

  Future<void> loadRecommendationsOnline(QuestRepository questRepository) async {
    await questRepository.getRecommendations(
      context: _context,
      preferences: const UserPreferences(),
    );
    // The steps prefetch isn't awaited, and on a real box it writes to disk,
    // which pumpEventQueue doesn't wait for: closing the box first would fail.
    for (var i = 0; i < 200; i++) {
      final ids = remote.recommendations.map((row) => row['quest_id'] as String);
      if (ids.every(questRepository.hasCachedSteps)) break;
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  Future<RecommendationResult> loadOffline() async {
    remote.offline = true;
    final batch = await repository.getRecommendations(
      context: _context,
      preferences: const UserPreferences(),
    );
    return (ids: batch.recommendations.map((r) => r.questId).toList(), batch: batch.batchId, cached: batch.fromCache);
  }

  Future<UserQuest> acceptOffline(String questId) async {
    remote.offline = true;
    final result = await repository.acceptQuestOrQueue(userId: _userId, questId: questId);
    expect(result.queued, isTrue);
    return result.userQuest;
  }

  setUp(() {
    remote = _FakeRemote();
    local = _FakeLocal();
    tracker = _SpyTracker();
    nextId = 0;
    repository = newRepository(local);
  });

  group('Cache then network: recommendations', () {
    test('online: saves the list with its batch id and prefetches its steps', () async {
      final batch = await repository.getRecommendations(
        context: _context,
        preferences: const UserPreferences(),
      );
      await pumpEventQueue();

      expect(batch.fromCache, isFalse);
      expect(local.saved!.batchId, batch.batchId);
      expect(local.saved!.rows.map((row) => row['quest_id']), ['a', 'b']);
      expect(local.steps.keys, containsAll(['a', 'b']));
    });

    test('offline: returns the saved list, marked, with its original batch id', () async {
      await loadRecommendationsOnline(repository);
      final original = local.saved!.batchId;

      final result = await loadOffline();

      expect(result.cached, isTrue);
      expect(result.ids, ['a', 'b']);
      expect(result.batch, original);
    });

    test('offline with nothing saved: a retryable AppException, not a raw SocketException', () async {
      remote.offline = true;

      expect(
        repository.getRecommendations(context: _context, preferences: const UserPreferences()),
        throwsA(isA<AppException>().having((e) => e.isRetryable, 'isRetryable', isTrue)),
      );
    });

    test('a server rejection does not fall back: it is not a network failure', () async {
      await loadRecommendationsOnline(repository);
      final failing = _RejectingRecommendations();

      expect(
        QuestRepository(failing, local).getRecommendations(
          context: _context,
          preferences: const UserPreferences(),
        ),
        throwsA(isA<AppException>().having((e) => e.isRetryable, 'isRetryable', isFalse)),
      );
    });

    test('an empty answer keeps the last usable list', () async {
      await loadRecommendationsOnline(repository);
      remote.recommendations = [];

      await loadRecommendationsOnline(repository);

      expect(local.saved!.rows, hasLength(2));
    });

    test('the saved list leaves out skipped and already started quests', () async {
      await loadRecommendationsOnline(repository);
      await acceptOffline('a');

      expect((await loadOffline()).ids, ['b']);

      final batch = await repository.getRecommendations(
        context: _context,
        preferences: const UserPreferences(),
        excludedQuestIds: ['b'],
      );
      expect(batch.recommendations, isEmpty);
    });

    test('a saved list does not log recommendation_shown again', () async {
      final viewModel = newViewModel(repository);
      await viewModel.loadRecommendations(const UserPreferences());
      await pumpEventQueue();
      expect(tracker.of(AnalyticsEventType.recommendationShown), hasLength(2));

      remote.offline = true;
      await viewModel.loadRecommendations(const UserPreferences());

      expect(viewModel.recommendationsFromCache, isTrue);
      expect(viewModel.recommendations, hasLength(2));
      expect(tracker.of(AnalyticsEventType.recommendationShown), hasLength(2));
    });

    test('after a restart offline, BQ4 reuses the saved batch_id', () async {
      await loadRecommendationsOnline(repository);
      final savedBatch = local.saved!.batchId;
      remote.offline = true;

      final viewModel = newViewModel(newRepository(local));
      await viewModel.load();
      await viewModel.loadRecommendations(const UserPreferences());
      await viewModel.startInstantPlan(_quest('a'));

      expect(tracker.of(AnalyticsEventType.recommendationShown), isEmpty);
      expect(tracker.of(AnalyticsEventType.recommendationAccepted).single['batch_id'], savedBatch);
    });

    test('back online, a fresh list replaces the mark and logs its own impressions', () async {
      final viewModel = newViewModel(repository);
      await viewModel.loadRecommendations(const UserPreferences());
      await pumpEventQueue();
      remote.offline = true;
      await viewModel.loadRecommendations(const UserPreferences());

      remote.offline = false;
      await viewModel.loadRecommendations(const UserPreferences());

      expect(viewModel.recommendationsFromCache, isFalse);
      expect(tracker.of(AnalyticsEventType.recommendationShown), hasLength(4));
    });
  });

  group('Queue & sync: accepting offline', () {
    setUp(() => loadRecommendationsOnline(repository));

    test('creates the attempt locally and queues an upsert with that same id', () async {
      final userQuest = await acceptOffline('a');

      expect(userQuest.status, 'accepted');
      expect(userQuest.questId, 'a');
      expect(local.userQuests.single['id'], userQuest.id);

      final write = PendingWrite.fromJson(local.pendingWrites.single);
      expect(write.type, PendingWrite.acceptQuest);
      expect(write.payload['id'], userQuest.id);
      expect(write.payload['user_id'], _userId);
      expect(write.payload['status'], 'accepted');
      expect(DateTime.parse(write.payload['accepted_at'] as String), userQuest.acceptedAt);
    });

    test('the mission starts normally, with cached steps and the BQ4 event at that moment', () async {
      final viewModel = newViewModel(repository);
      await viewModel.loadRecommendations(const UserPreferences());
      remote.offline = true;

      final started = await viewModel.startInstantPlan(_quest('a'));

      expect(started, isTrue);
      expect(viewModel.instantPlanQueued, isTrue);
      expect(viewModel.currentMission!.questId, 'a');
      expect(viewModel.steps.single.title, 'Paso a');
      final metadata = tracker.of(AnalyticsEventType.recommendationAccepted).single;
      expect(metadata['start_path'], 'instant_plan');
      expect(metadata['seconds_to_start'], isA<int>());
      expect(metadata['interactions_to_start'], 0);
      expect(metadata['batch_id'], isNotNull);
    });

    test('without cached steps it fails as before: there would be nothing to follow', () async {
      local.steps.clear();
      final viewModel = newViewModel(repository);
      remote.offline = true;

      final started = await viewModel.startInstantPlan(_quest('a'));

      expect(started, isFalse);
      expect(viewModel.errorMessage, startsWith('Sin conexión'));
      expect(local.pendingWrites, isEmpty);
      expect(tracker.of(AnalyticsEventType.recommendationAccepted), isEmpty);
    });

    test('tapping the card again opens the same mission instead of queuing a second one', () async {
      final first = await acceptOffline('a');
      final second = await acceptOffline('a');

      expect(second.id, first.id);
      expect(local.pendingWrites, hasLength(1));
      expect(local.userQuests, hasLength(1));
    });

    test('a server rejection of the first try is not queued', () async {
      expect(
        QuestRepository(_RejectingWrites(), local).acceptQuestOrQueue(userId: _userId, questId: 'a'),
        throwsA(isA<AppException>()),
      );
      await pumpEventQueue();

      expect(local.pendingWrites, isEmpty);
    });

    test('other accepts do not queue: "Aceptar misión" still fails offline', () async {
      remote.offline = true;

      await expectLater(
        repository.acceptQuest(userId: _userId, questId: 'a'),
        throwsA(isA<AppException>()),
      );

      expect(local.pendingWrites, isEmpty);
    });

    test('progress offline still fails on a queued mission, unchanged', () async {
      final userQuest = await acceptOffline('a');

      await expectLater(
        repository.updateProgress(userQuest.copyWithProgress(status: 'in_progress', currentStep: 1)),
        throwsA(isA<AppException>().having((e) => e.isRetryable, 'isRetryable', isTrue)),
      );

      expect(local.userQuests.single['status'], 'accepted');
    });
  });

  group('Queue & sync: syncing', () {
    setUp(() => loadRecommendationsOnline(repository));

    test('success empties the queue and the server has the row with that id', () async {
      final userQuest = await acceptOffline('a');
      remote.offline = false;

      await repository.syncPendingWrites();

      expect(local.pendingWrites, isEmpty);
      expect(remote.userQuests.single['id'], userQuest.id);
      expect(remote.userQuests.single['accepted_at'], local.userQuests.single['accepted_at']);
    });

    test('app start with a connection syncs before reading the attempts', () async {
      final userQuest = await acceptOffline('a');
      remote.offline = false;

      final viewModel = newViewModel(newRepository(local));
      await viewModel.load();

      expect(local.pendingWrites, isEmpty);
      expect(viewModel.currentMission!.id, userQuest.id);
      expect(remote.userQuests.single['id'], userQuest.id);
    });

    test('a network failure keeps the queue, in order, and the next sync finishes it', () async {
      final first = await acceptOffline('a');
      final second = await acceptOffline('b');

      await repository.syncPendingWrites(); // still offline

      expect(local.pendingWrites, hasLength(2));
      expect(remote.queuedWritesSent, 0);

      remote.offline = false;
      await repository.syncPendingWrites();

      expect(local.pendingWrites, isEmpty);
      expect(remote.userQuests.map((row) => row['id']), [second.id, first.id]);
    });

    test('a failure midway stops there: nothing after it is sent', () async {
      await acceptOffline('a');
      await acceptOffline('b');
      remote.offline = false;
      remote.syncError = const SocketException('dropped');

      await repository.syncPendingWrites();

      expect(local.pendingWrites, hasLength(2));
      expect(remote.userQuests, isEmpty);
    });

    test('a server rejection discards the entry and its local mission, without throwing', () async {
      final userQuest = await acceptOffline('a');
      remote.offline = false;
      remote.syncError = _rejected;

      await repository.syncPendingWrites();

      expect(local.pendingWrites, isEmpty);
      expect(local.userQuests.where((row) => row['id'] == userQuest.id), isEmpty);
    });

    test('after a rejection the view model has no ghost mission', () async {
      await acceptOffline('a');
      remote.offline = false;
      remote.syncError = _rejected;

      final viewModel = newViewModel(newRepository(local));
      await viewModel.load();

      expect(viewModel.errorMessage, isNull);
      expect(viewModel.currentMission, isNull);
    });

    for (final (name, error) in [
      ('an expired session', const PostgrestException(message: 'JWT expired', code: 'PGRST303')),
      ('an old-format expired session', const PostgrestException(message: 'JWT expired', code: 'PGRST301')),
      ('HTTP 401', const PostgrestException(message: 'Unauthorized', code: '401')),
      ('a server error', const PostgrestException(message: 'Bad gateway', code: '502')),
      ('the database being down', const PostgrestException(message: 'no conn', code: 'PGRST000')),
      ('a deadlock', const PostgrestException(message: 'deadlock', code: '40P01')),
      ('too many connections', const PostgrestException(message: 'too many', code: '53300')),
    ]) {
      test('$name is not a rejection: the queue and the mission stay', () async {
        final userQuest = await acceptOffline('a');
        remote.offline = false;
        remote.syncError = error;

        await repository.syncPendingWrites();

        expect(local.pendingWrites, hasLength(1));
        expect(local.userQuests.single['id'], userQuest.id);
      });
    }

    for (final code in ['42501', '23503', '23514', '22P02', 'PGRST204']) {
      test('$code is a rejection: it would never pass', () async {
        await acceptOffline('a');
        remote.offline = false;
        remote.syncError = PostgrestException(message: 'no', code: code);

        await repository.syncPendingWrites();

        expect(local.pendingWrites, isEmpty);
      });
    }

    test('a rejection does not block the writes behind it', () async {
      await acceptOffline('a');
      final second = await acceptOffline('b');
      remote.offline = false;
      final failingOnce = _FailsOnce(remote, _rejected);

      await QuestRepository(failingOnce, local).syncPendingWrites();

      expect(local.pendingWrites, isEmpty);
      expect(remote.userQuests.single['id'], second.id);
    });

    test('replaying never undoes progress saved before the sync ran', () async {
      final userQuest = await acceptOffline('a');
      remote.offline = false;
      await repository.updateProgress(
        userQuest.copyWithProgress(status: 'in_progress', currentStep: 1, completedSteps: [0]),
      );

      await repository.syncPendingWrites();

      expect(local.pendingWrites, isEmpty);
      expect(remote.userQuests.single['status'], 'in_progress');
      expect(remote.userQuests.single['current_step'], 1);
    });

    test('a lost answer to the first try does not create a second attempt', () async {
      remote.loseUpsertAnswer = true;

      final result = await repository.acceptQuestOrQueue(userId: _userId, questId: 'a');
      remote.loseUpsertAnswer = false;
      await repository.syncPendingWrites();

      expect(result.queued, isTrue);
      expect(remote.userQuests.single['id'], result.userQuest.id);
    });

    test('a read that succeeds while the write cannot be sent keeps the mission', () async {
      final userQuest = await acceptOffline('a');
      remote.offline = false;
      remote.syncError = const SocketException('flapping');

      final (:userQuests, :fromCache) = await repository.getUserQuestsWithSource(_userId);

      expect(fromCache, isFalse);
      expect(userQuests.single.id, userQuest.id);
      expect(local.userQuests.single['id'], userQuest.id);
    });

    test('another account never inherits a queued mission', () async {
      await acceptOffline('a');
      remote.offline = false;
      remote.syncError = const SocketException('flapping');

      final (:userQuests, fromCache: _) = await repository.getUserQuestsWithSource('user-2');

      expect(userQuests, isEmpty);
    });

    test('concurrent syncs send each write once', () async {
      await acceptOffline('a');
      remote.offline = false;

      await Future.wait([repository.syncPendingWrites(), repository.syncPendingWrites()]);

      expect(remote.queuedWritesSent, 1);
    });
  });

  test('the real data source sends a queued write as ON CONFLICT DO NOTHING', () async {
    late http.Request sent;
    final client = SupabaseClient(
      'https://example.supabase.co',
      'key',
      httpClient: MockClient((request) async {
        sent = request;
        return http.Response('', 201, request: request);
      }),
    );

    await SupabaseRemoteDataSource(client).insertUserQuestIfAbsent({'id': 'uuid-1'});

    expect(sent.method, 'POST');
    expect(sent.url.path, endsWith('/user_quests'));
    expect(sent.headers['Prefer'], contains('resolution=ignore-duplicates'));
    expect(jsonDecode(sent.body), {'id': 'uuid-1'});
    await client.dispose();
  });

  group('photos of a queued mission', () {
    final jpeg = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0]);

    setUp(() => loadRecommendationsOnline(repository));

    test('stay on the device, retryable, while the attempt cannot reach the server', () async {
      final userQuest = await acceptOffline('a');
      final pending = await repository.savePendingPhotoProof(
        attempt: userQuest,
        stepOrder: 0,
        jpeg: jpeg,
      );
      remote.offline = false;
      remote.syncError = const SocketException('flapping');

      await expectLater(
        repository.uploadPendingPhotoProof(pending),
        throwsA(isA<AppException>().having((e) => e.isRetryable, 'isRetryable', isTrue)),
      );

      expect(remote.uploads, isEmpty);
      expect(repository.getPendingPhotoProofs(), hasLength(1));
    });

    test('go up right after the sync creates the attempt', () async {
      final userQuest = await acceptOffline('a');
      final pending = await repository.savePendingPhotoProof(
        attempt: userQuest,
        stepOrder: 0,
        jpeg: jpeg,
      );
      remote.offline = false;

      await repository.uploadPendingPhotoProof(pending);

      expect(remote.userQuests.single['id'], userQuest.id);
      expect(remote.uploads, [pending.storagePath]);
      expect(repository.getPendingPhotoProofs(), isEmpty);
    });
  });

  group('real Hive box on disk', () {
    late Directory documents;
    late LocalDataSource hive;

    const pathProvider = MethodChannel('plugins.flutter.io/path_provider');

    Future<void> restart() async {
      await Hive.close();
      hive = LocalDataSource();
      await hive.init();
      repository = newRepository(hive);
    }

    setUp(() async {
      TestWidgetsFlutterBinding.ensureInitialized();
      documents = await Directory.systemTemp.createTemp('instant_plan_test');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        pathProvider,
        (_) async => documents.path,
      );
      SharedPreferences.setMockInitialValues({});
      await restart();
    });

    tearDown(() async {
      await Hive.close();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        pathProvider,
        null,
      );
      await documents.delete(recursive: true);
    });

    test('list, steps, mission and queue survive restarts, then the queue syncs', () async {
      await loadRecommendationsOnline(repository);
      final batchId = hive.getSavedRecommendations()!.batchId;
      remote.offline = true;

      await restart();
      final batch = await repository.getRecommendations(
        context: _context,
        preferences: const UserPreferences(),
      );
      expect(batch.fromCache, isTrue);
      expect(batch.batchId, batchId);
      expect(batch.recommendations.map((r) => r.questId), ['a', 'b']);
      expect((await repository.getSteps('a')).single.title, 'Paso a');
      expect((await repository.getSteps('b')).single.title, 'Paso b');

      final started = await repository.acceptQuestOrQueue(userId: _userId, questId: 'a');
      expect(started.queued, isTrue);

      await restart();
      final (userQuests: cached, fromCache: _) = await repository.getUserQuestsWithSource(_userId);
      expect(cached.single.id, started.userQuest.id);
      expect(hive.getPendingWrites(), hasLength(1));

      remote.offline = false;
      await restart();
      final (userQuests: synced, :fromCache) = await repository.getUserQuestsWithSource(_userId);

      expect(fromCache, isFalse);
      expect(synced.single.id, started.userQuest.id);
      expect(hive.getPendingWrites(), isEmpty);
    });

    test('a verified check-in survives restarts, with its time, and signing out clears it', () async {
      final verifiedAt = DateTime.utc(2026, 10, 31, 15, 30);
      await repository.saveVerifiedCheckIn(
        VerifiedCheckIn(userQuestId: 'uq-1', stepIndex: 2, verifiedAt: verifiedAt),
      );

      await restart();

      final saved = repository.getVerifiedCheckIn()!;
      expect(saved.userQuestId, 'uq-1');
      expect(saved.stepIndex, 2);
      expect(saved.verifiedAt, verifiedAt);
      expect(hive.getPendingWrites(), isEmpty); // it isn't a queued write

      await repository.saveVerifiedCheckIn(null);
      await restart();
      expect(repository.getVerifiedCheckIn(), isNull);

      await repository.saveVerifiedCheckIn(saved);
      await hive.clear();
      expect(repository.getVerifiedCheckIn(), isNull);
    });

    test('signing out clears the queue and the saved list', () async {
      await loadRecommendationsOnline(repository);
      remote.offline = true;
      await repository.acceptQuestOrQueue(userId: _userId, questId: 'a');

      await hive.clear();

      expect(hive.getPendingWrites(), isEmpty);
      expect(hive.getSavedRecommendations(), isNull);
    });
  });

  testWidgets('Explore offline: label, "Empezar ya", notice and the mission opens', (tester) async {
    await tester.runAsync(() async {
      await loadRecommendationsOnline(repository);
      await repository.getCatalog();
    });
    remote.offline = true;

    final viewModel = newViewModel(newRepository(local));
    final profileViewModel = ProfileViewModel(
      ProfileRepository(remote, local),
      AuthRepository(remote, local),
      _userId,
    );
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<QuestViewModel>.value(value: viewModel),
          ChangeNotifierProvider<ProfileViewModel>.value(value: profileViewModel),
        ],
        child: const MaterialApp(home: ExploreView()),
      ),
    );
    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.text(_savedLabel), findsOneWidget);
    expect(tracker.of(AnalyticsEventType.recommendationShown), isEmpty);

    await tester.ensureVisible(find.text('Empezar ya →').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Empezar ya →').first);
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(find.text(_queuedNotice), findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.byType(MissionTabView), findsOneWidget);
    expect(find.text('Paso a'), findsOneWidget);
    expect(local.pendingWrites, hasLength(1));
  });
}

typedef RecommendationResult = ({List<String> ids, String batch, bool cached});

class _RejectingRecommendations extends _FakeRemote {
  @override
  Future<List<Map<String, dynamic>>> recommendQuests({
    required int availableMinutes,
    required String socialLevel,
    List<String> interests = const [],
    String locationMode = 'all',
    List<String> excludedQuestIds = const [],
    int limit = 3,
  }) async => throw const PostgrestException(message: 'boom');
}

class _RejectingWrites extends _FakeRemote {
  @override
  Future<Map<String, dynamic>> upsertUserQuest(Map<String, dynamic> userQuest) async =>
      throw _rejected;
}

/// Rejects the first queued write and delegates the rest to [inner].
class _FailsOnce extends _FakeRemote {
  final _FakeRemote inner;
  final Object error;
  bool _failed = false;

  _FailsOnce(this.inner, this.error);

  @override
  Future<void> insertUserQuestIfAbsent(Map<String, dynamic> userQuest) async {
    if (!_failed) {
      _failed = true;
      throw error;
    }
    await inner.insertUserQuestIfAbsent(userQuest);
  }
}
