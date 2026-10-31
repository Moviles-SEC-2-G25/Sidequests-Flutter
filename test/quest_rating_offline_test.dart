import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:hive_flutter/hive_flutter.dart';
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
import 'package:sidequests/models/pending_write.dart';
import 'package:sidequests/models/quest.dart';
import 'package:sidequests/models/user_quest.dart';
import 'package:sidequests/repository/quest_repository.dart';
import 'package:sidequests/view/quests/quest_completed_view.dart';
import 'package:sidequests/viewmodel/quests/quest_view_model.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show PostgrestException;

const _userId = 'user-1';
const _queuedNotice = 'Calificación guardada en el teléfono: se enviará al reconectar';
const _rejected = PostgrestException(message: 'new row violates RLS', code: '42501');

Map<String, dynamic> _questRow(String id, {String category = 'food', int minutes = 20}) => {
  'id': id,
  'title': 'Quest $id',
  'category': category,
  'duration_minutes': minutes,
  'difficulty': 'easy',
  'location_mode': 'anywhere',
  'social_level': 'solo',
};

Map<String, dynamic> _attemptRow(String id, String questId, String status) => {
  'id': id,
  'user_id': _userId,
  'quest_id': questId,
  'status': status,
  'accepted_at': '2026-10-01T10:00:00Z',
};

/// What QuestCompletedView holds: the attempt from before it was completed.
UserQuest _beforeCompleting(String id, String questId) => UserQuest(
  id: id,
  userId: _userId,
  questId: questId,
  status: 'in_progress',
  acceptedAt: DateTime.utc(2026, 10, 1, 10),
);

/// Supabase in memory. [offline] fails every call like a dropped connection.
class _FakeRemote implements SupabaseRemoteDataSource {
  bool offline = false;

  /// Only the queued-write calls: the read after them can still go through.
  Object? syncError;

  /// Rejects the queued acceptance, but not what comes behind it.
  Object? acceptError;

  /// What reached the server, in order.
  final List<String> sent = [];
  final List<Map<String, dynamic>> userQuests = [];

  void _failIfDown() {
    if (offline) throw const SocketException('offline');
  }

  Map<String, dynamic> _upsert(Map<String, dynamic> values) {
    final existing = userQuests.where((row) => row['id'] == values['id']).firstOrNull;
    final row = {'status': 'accepted', ...?existing, ...values};
    userQuests
      ..removeWhere((r) => r['id'] == row['id'])
      ..insert(0, row);
    return row;
  }

  @override
  Future<List<Map<String, dynamic>>> getActiveQuests() async {
    _failIfDown();
    return [_questRow('ramen')];
  }

  @override
  Future<List<Map<String, dynamic>>> getUserQuests(String userId) async {
    _failIfDown();
    return [for (final row in userQuests) {...row}];
  }

  @override
  Future<Map<String, dynamic>> rateUserQuest({
    required String id,
    required String userId,
    required String questId,
    required int rating,
    required List<String> feedbackTags,
  }) async {
    _failIfDown();
    if (syncError != null) throw syncError!;
    sent.add('rate:$id');
    return _upsert({
      'id': id,
      'user_id': userId,
      'quest_id': questId,
      'rating': rating,
      'feedback_tags': feedbackTags,
    });
  }

  @override
  Future<void> insertUserQuestIfAbsent(Map<String, dynamic> userQuest) async {
    _failIfDown();
    if (syncError != null) throw syncError!;
    if (acceptError != null) throw acceptError!;
    sent.add('accept:${userQuest['id']}');
    if (!userQuests.any((row) => row['id'] == userQuest['id'])) userQuests.insert(0, {...userQuest});
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// The Hive box, in memory.
class _FakeLocal implements LocalDataSource {
  List<Map<String, dynamic>> pendingWrites = [];
  List<Map<String, dynamic>> userQuests = [];
  List<Map<String, dynamic>> catalog = [];
  List<Map<String, dynamic>> pendingAnalytics = [];

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
  List<Map<String, dynamic>> getPendingAnalyticsEvents() => [...pendingAnalytics];

  @override
  Future<void> savePendingAnalyticsEvents(List<Map<String, dynamic>> events) async =>
      pendingAnalytics = events;

  @override
  Map<String, dynamic>? getActiveStepSession() => null;

  @override
  Map<String, dynamic>? getVerifiedCheckIn() => null;

  @override
  List<Map<String, dynamic>> getPendingPhotoProofs() => const [];

  @override
  Map<String, dynamic>? getExploreFilters() => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// No Supabase at all: every call counts, and fails like no connection.
class _NoRemote implements SupabaseRemoteDataSource {
  int calls = 0;

  @override
  dynamic noSuchMethod(Invocation invocation) {
    calls++;
    throw const SocketException('offline');
  }
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

class _RecordingSink implements AnalyticsEventSink {
  bool offline = false;
  final List<Map<String, dynamic>> sent = [];

  @override
  Future<void> insertAnalyticsEvent(Map<String, dynamic> event) async {
    if (offline) throw const SocketException('offline');
    sent.add(event);
  }
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
}

QuestViewModel _viewModel(QuestRepository repository, AnalyticsTracker tracker) => QuestViewModel(
  repository,
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

void main() {
  late _FakeRemote remote;
  late _FakeLocal local;
  late QuestRepository repository;
  late _SpyTracker tracker;

  /// The mission is completed, on the server and in the cache.
  void completeMission() {
    final row = _attemptRow('uq-1', 'ramen', 'completed');
    remote.userQuests.add({...row});
    local.userQuests = [{...row}];
  }

  /// The acceptance still queued, like "Empezar ya" offline leaves it.
  void queueAcceptance(String id, {String status = 'completed'}) {
    local.pendingWrites = [
      PendingWrite(
        type: PendingWrite.acceptQuest,
        payload: _attemptRow(id, 'ramen', 'accepted'),
        createdAt: DateTime.utc(2026, 10, 1),
      ).toJson(),
    ];
    local.userQuests = [_attemptRow(id, 'ramen', status)];
  }

  Future<UserQuest> rate({int rating = 4, List<String> tags = const ['divertida']}) async =>
      (await repository.rateQuestOrQueue(_beforeCompleting('uq-1', 'ramen'), rating, tags)).userQuest;

  setUp(() {
    remote = _FakeRemote();
    local = _FakeLocal();
    repository = QuestRepository(remote, local);
    tracker = _SpyTracker();
  });

  group('rating offline', () {
    setUp(() {
      completeMission();
      remote.offline = true;
    });

    test('queues the operation and shows in the cached attempt', () async {
      final result = await repository.rateQuestOrQueue(
        _beforeCompleting('uq-1', 'ramen'),
        4,
        ['divertida', 'repetiría'],
      );

      expect(result.queued, isTrue);
      expect(result.userQuest.rating, 4);
      expect(result.userQuest.feedbackTags, ['divertida', 'repetiría']);

      final cached = local.userQuests.single;
      expect(cached['rating'], 4);
      expect(cached['feedback_tags'], ['divertida', 'repetiría']);

      final write = PendingWrite.fromJson(local.pendingWrites.single);
      expect(write.type, PendingWrite.rateQuest);
      expect(write.payload['id'], 'uq-1');
      expect(write.payload['rating'], 4);
      expect(write.payload['feedback_tags'], ['divertida', 'repetiría']);
    });

    test('the finished mission does not come back: the view holds its old copy', () async {
      final updated = await rate();

      expect(updated.status, 'completed');
      expect(local.userQuests.single['status'], 'completed');
    });

    test('an attempt that is not cached fails retryably: the view offers "Reintentar"', () async {
      local.userQuests = [];

      await expectLater(
        rate(),
        throwsA(isA<AppException>().having((e) => e.isRetryable, 'isRetryable', isTrue)),
      );

      expect(local.pendingWrites, isEmpty);
    });

    test('through the view model: success, no error, not loading, quest_rated tracked', () async {
      final viewModel = _viewModel(repository, tracker);
      await viewModel.load();

      final saved = await viewModel.submitRating(
        _beforeCompleting('uq-1', 'ramen'),
        rating: 5,
        tags: const ['divertida'],
      );

      expect(saved, isTrue);
      expect(viewModel.ratingQueued, isTrue);
      expect(viewModel.ratingErrorMessage, isNull);
      expect(viewModel.isSubmittingRating, isFalse);
      expect(viewModel.userQuests.single.rating, 5);
      expect(viewModel.currentMission, isNull);
      final rated = tracker.calls.where((c) => c.type == AnalyticsEventType.questRated).single;
      expect(rated.metadata, {'rating': 5, 'tags': ['divertida']});
    });

    test('quest_rated waits in the analytics queue and goes out later', () async {
      final sink = _RecordingSink()..offline = true;
      final analytics = AnalyticsTracker(
        eventSink: sink,
        contextManager: _contextManager(),
        sessionId: 'session',
        localDataSource: local,
      );
      final viewModel = _viewModel(repository, analytics);
      await viewModel.load();

      await viewModel.submitRating(
        _beforeCompleting('uq-1', 'ramen'),
        rating: 5,
        tags: const [],
      );
      await pumpEventQueue();

      expect(local.pendingAnalytics.single['event_type'], AnalyticsEventType.questRated);
      expect(local.pendingAnalytics.single['occurred_at'], isNotNull);

      sink.offline = false;
      await analytics.flushPending();

      expect(sink.sent.single['event_type'], AnalyticsEventType.questRated);
    });
  });

  group('rating online', () {
    setUp(completeMission);

    test('goes straight to the server, nothing queued', () async {
      final viewModel = _viewModel(repository, tracker);

      final saved = await viewModel.submitRating(
        _beforeCompleting('uq-1', 'ramen'),
        rating: 3,
        tags: const [],
      );

      expect(saved, isTrue);
      expect(viewModel.ratingQueued, isFalse);
      expect(remote.sent, ['rate:uq-1']);
      expect(local.pendingWrites, isEmpty);
    });

    test('a rejection is an error for the view, as before, and is not queued', () async {
      remote.syncError = _rejected;
      final viewModel = _viewModel(repository, tracker);

      final saved = await viewModel.submitRating(
        _beforeCompleting('uq-1', 'ramen'),
        rating: 3,
        tags: const [],
      );

      expect(saved, isFalse);
      expect(viewModel.ratingErrorMessage, _rejected.message);
      expect(local.pendingWrites, isEmpty);
    });
  });

  group('syncing the rating', () {
    setUp(completeMission);

    test('reaches the server on reconnection, without touching its status', () async {
      remote.offline = true;
      await rate(rating: 2, tags: const ['muy larga']);

      remote.offline = false;
      final viewModel = _viewModel(QuestRepository(remote, local), tracker);
      await viewModel.load();

      expect(local.pendingWrites, isEmpty);
      final row = remote.userQuests.single;
      expect(row['rating'], 2);
      expect(row['feedback_tags'], ['muy larga']);
      expect(row['status'], 'completed');
      expect(viewModel.userQuests.single.rating, 2);
    });

    test('a network failure keeps it queued', () async {
      remote.offline = true;
      await rate();

      await repository.syncPendingWrites();

      expect(local.pendingWrites, hasLength(1));
      expect(remote.userQuests.single['rating'], isNull);
    });

    test('a read that succeeds while it cannot be sent keeps the rating in the cache', () async {
      remote.offline = true;
      await rate(rating: 4, tags: const ['costosa']);
      remote.offline = false;
      remote.syncError = const SocketException('flapping');

      final (:userQuests, :fromCache) = await repository.getUserQuestsWithSource(_userId);

      expect(fromCache, isFalse);
      expect(userQuests.single.rating, 4);
      expect(userQuests.single.feedbackTags, ['costosa']);
      expect(local.userQuests.single['rating'], 4);
      expect(local.pendingWrites, hasLength(1));
    });

    test('a server rejection discards it without throwing, and the mission stays', () async {
      remote.offline = true;
      await rate();
      remote.offline = false;
      remote.syncError = _rejected;

      final (:userQuests, fromCache: _) = await repository.getUserQuestsWithSource(_userId);

      expect(local.pendingWrites, isEmpty);
      expect(userQuests.single.id, 'uq-1');
      expect(userQuests.single.rating, isNull);
    });
  });

  group('with the acceptance of the same mission still queued', () {
    test('offline it queues behind it, and they go out in that order', () async {
      queueAcceptance('uq-1');
      remote.offline = true;
      await rate();

      expect(
        local.pendingWrites.map((w) => w['type']),
        [PendingWrite.acceptQuest, PendingWrite.rateQuest],
      );

      remote.offline = false;
      await repository.syncPendingWrites();

      expect(remote.sent, ['accept:uq-1', 'rate:uq-1']);
      expect(local.pendingWrites, isEmpty);
      expect(remote.userQuests.single['rating'], 4);
    });

    test('online too: the acceptance goes first, never the rating alone', () async {
      queueAcceptance('uq-1');

      final result = await repository.rateQuestOrQueue(
        _beforeCompleting('uq-1', 'ramen'),
        4,
        const [],
      );

      expect(result.queued, isFalse);
      expect(remote.sent, ['accept:uq-1', 'rate:uq-1']);
    });

    test('if the acceptance cannot go, neither does the rating: it queues behind', () async {
      queueAcceptance('uq-1');
      remote.syncError = const SocketException('flapping');

      final result = await repository.rateQuestOrQueue(
        _beforeCompleting('uq-1', 'ramen'),
        4,
        const [],
      );
      await repository.syncPendingWrites();

      expect(result.queued, isTrue);
      expect(remote.sent, isEmpty);
      expect(local.pendingWrites, hasLength(2));
    });

    test('a rejected acceptance takes the rating with it: no row is recreated', () async {
      queueAcceptance('uq-1');
      remote.offline = true;
      await rate();
      remote.offline = false;
      remote.acceptError = _rejected;

      await repository.syncPendingWrites();

      expect(remote.sent, isEmpty);
      expect(remote.userQuests, isEmpty);
      expect(local.pendingWrites, isEmpty);
      expect(local.userQuests, isEmpty);
    });

    test('a rejected acceptance keeps the ratings of other missions', () async {
      queueAcceptance('uq-1');
      local.userQuests = [
        ...local.userQuests,
        _attemptRow('uq-2', 'ramen', 'completed'),
      ];
      remote.userQuests.add(_attemptRow('uq-2', 'ramen', 'completed'));
      remote.offline = true;
      await repository.rateQuestOrQueue(_beforeCompleting('uq-2', 'ramen'), 5, const []);
      remote.offline = false;
      remote.acceptError = _rejected;

      await repository.syncPendingWrites();

      expect(remote.sent, ['rate:uq-2']);
      expect(local.pendingWrites, isEmpty);
    });
  });

  group('real Hive box on disk, no Supabase at all', () {
    late Directory documents;
    late LocalDataSource hive;

    const pathProvider = MethodChannel('plugins.flutter.io/path_provider');

    Future<void> restart() async {
      await Hive.close();
      hive = LocalDataSource();
      await hive.init();
    }

    setUp(() async {
      TestWidgetsFlutterBinding.ensureInitialized();
      documents = await Directory.systemTemp.createTemp('rating_test');
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

    /// Only what an earlier online session left in LocalDataSource.
    Future<QuestViewModel> loadFromCacheOnly(_NoRemote noRemote) async {
      await hive.cacheQuestCatalog([
        _questRow('ramen'),
        _questRow('sushi'),
        _questRow('museo', category: 'art'),
        _questRow('tacos'),
        _questRow('pizza'),
        _questRow('largo', minutes: 500),
      ]);
      await hive.cacheUserQuests([
        _attemptRow('uq-1', 'ramen', 'completed'),
        _attemptRow('uq-2', 'tacos', 'in_progress'),
        _attemptRow('uq-3', 'pizza', 'completed'),
      ]);
      await restart();
      final viewModel = _viewModel(QuestRepository(noRemote, hive), tracker);
      await viewModel.load();
      return viewModel;
    }

    test('"Te podría gustar" comes out of the cache, with no network call of its own', () async {
      final noRemote = _NoRemote();
      final viewModel = await loadFromCacheOnly(noRemote);
      final callsToLoad = noRemote.calls;
      final completed = viewModel.questById('ramen')!;

      final liked = viewModel.similarQuests(completed: completed, rating: 5);
      final disliked = viewModel.similarQuests(completed: completed, rating: 1);

      // Same category first when liked, last when not; never what's done,
      // in progress or too long.
      expect(liked.map((q) => q.id), ['sushi', 'museo']);
      expect(disliked.map((q) => q.id), ['museo', 'sushi']);
      expect(noRemote.calls, callsToLoad);
    });

    test('rating offline over the real box still recommends, and survives a restart', () async {
      final noRemote = _NoRemote();
      final viewModel = await loadFromCacheOnly(noRemote);

      final saved = await viewModel.submitRating(
        _beforeCompleting('uq-1', 'ramen'),
        rating: 1,
        tags: const ['costosa', 'muy larga'],
      );

      expect(saved, isTrue);
      expect(viewModel.ratingQueued, isTrue);
      expect(
        viewModel.similarQuests(completed: viewModel.questById('ramen')!, rating: 1).map((q) => q.id),
        ['museo', 'sushi'],
      );

      await restart();
      final cached = hive.getUserQuests().firstWhere((row) => row['id'] == 'uq-1');
      expect(cached['rating'], 1);
      expect(cached['status'], 'completed');
      expect(hive.getPendingWrites(), hasLength(1));

      final online = _FakeRemote()..userQuests.add(_attemptRow('uq-1', 'ramen', 'completed'));
      await QuestRepository(online, hive).syncPendingWrites();

      expect(online.userQuests.single['rating'], 1);
      expect(online.userQuests.single['feedback_tags'], ['costosa', 'muy larga']);
      expect(hive.getPendingWrites(), isEmpty);
    });
  });

  group('QuestCompletedView', () {
    Future<QuestViewModel> pumpView(WidgetTester tester) async {
      remote.offline = false;
      final viewModel = _viewModel(repository, tracker);
      viewModel.catalog = [
        Quest.fromJson(_questRow('ramen')),
        Quest.fromJson(_questRow('sushi')),
      ];
      await tester.pumpWidget(
        ChangeNotifierProvider<QuestViewModel>.value(
          value: viewModel,
          child: MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: Center(
                  child: TextButton(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => QuestCompletedView(
                          mission: _beforeCompleting('uq-1', 'ramen'),
                          quest: Quest.fromJson(_questRow('ramen')),
                        ),
                      ),
                    ),
                    child: const Text('open'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      return viewModel;
    }

    Future<void> saveWithStars(WidgetTester tester) async {
      await tester.tap(find.byTooltip('4'));
      await tester.pump();
      await tester.ensureVisible(find.text('Guardar'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Guardar'));
      await tester.pump();
      await tester.pump();
    }

    testWidgets('offline: the suggestions show, it closes and says the rating waits', (
      tester,
    ) async {
      completeMission();
      await pumpView(tester);
      remote.offline = true;

      expect(find.text('Te podría gustar'), findsOneWidget);
      expect(find.text('Quest sushi'), findsOneWidget);

      await saveWithStars(tester);
      await tester.pumpAndSettle();

      expect(find.text(_queuedNotice), findsOneWidget);
      expect(find.byType(QuestCompletedView), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('Reintentar'), findsNothing);
      expect(local.pendingWrites, hasLength(1));
    });

    testWidgets('online: it closes with no notice', (tester) async {
      completeMission();
      await pumpView(tester);

      await saveWithStars(tester);
      await tester.pumpAndSettle();

      expect(find.text(_queuedNotice), findsNothing);
      expect(find.byType(QuestCompletedView), findsNothing);
      expect(remote.sent, ['rate:uq-1']);
    });

    testWidgets('when it cannot even be kept: it stays open, with "Reintentar"', (tester) async {
      await pumpView(tester); // the attempt isn't in the cache
      remote.offline = true;

      await saveWithStars(tester);
      await tester.pumpAndSettle();

      expect(find.byType(QuestCompletedView), findsOneWidget);
      expect(find.text('Reintentar'), findsOneWidget);
      expect(find.text(_queuedNotice), findsNothing);
    });
  });
}
