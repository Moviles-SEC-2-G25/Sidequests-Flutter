import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:provider/provider.dart';
import 'package:sidequests/analytics/analytics_event_sink.dart';
import 'package:sidequests/analytics/analytics_tracker.dart';
import 'package:sidequests/core/completion_likelihood.dart';
import 'package:sidequests/core/verification/step_verification_strategy.dart';
import 'package:sidequests/data/context/context_manager.dart';
import 'package:sidequests/data/local/local_data_source.dart';
import 'package:sidequests/data/remote/supabase_remote_data_source.dart';
import 'package:sidequests/data/services/battery_monitor.dart';
import 'package:sidequests/data/services/location_check_in_service.dart';
import 'package:sidequests/data/services/location_service.dart';
import 'package:sidequests/data/services/step_counter_service.dart';
import 'package:sidequests/models/quest.dart';
import 'package:sidequests/models/user_preferences.dart';
import 'package:sidequests/repository/auth_repository.dart';
import 'package:sidequests/repository/profile_repository.dart';
import 'package:sidequests/repository/quest_repository.dart';
import 'package:sidequests/view/quests/explore_view.dart';
import 'package:sidequests/viewmodel/profile/profile_view_model.dart';
import 'package:sidequests/viewmodel/profile/stats_view_model.dart';
import 'package:sidequests/viewmodel/quests/quest_view_model.dart';

const _userId = 'user-1';
const _note = 'Según tus datos guardados';

Map<String, dynamic> _questRow(String id) => {
  'id': id,
  'title': 'Quest $id',
  'category': 'food',
  'duration_minutes': 20,
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

/// Supabase in memory; catalogue and attempts can fail on their own.
class _FakeRemote implements SupabaseRemoteDataSource {
  bool catalogDown = false;
  bool attemptsDown = false;
  bool recommendationsDown = false;
  bool writesDown = false;
  List<Map<String, dynamic>> attempts = [];

  set offline(bool value) {
    catalogDown = attemptsDown = recommendationsDown = writesDown = value;
  }

  @override
  Future<List<Map<String, dynamic>>> getActiveQuests() async {
    if (catalogDown) throw const SocketException('offline');
    return [_questRow('a'), _questRow('b'), _questRow('c'), _questRow('d')];
  }

  @override
  Future<List<Map<String, dynamic>>> getUserQuests(String userId) async {
    if (attemptsDown) throw const SocketException('offline');
    return [...attempts];
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
    if (recommendationsDown) throw const SocketException('offline');
    return [
      {'quest_id': 'd', 'score': 1.5, 'variant': 'control', 'rank_position': 1},
    ];
  }

  @override
  Future<List<Map<String, dynamic>>> getQuestSteps(String questId) async => [
    {'id': 1, 'quest_id': questId, 'step_order': 0, 'title': 'Paso'},
  ];

  @override
  Future<Map<String, dynamic>> upsertUserQuest(Map<String, dynamic> userQuest) async {
    if (writesDown) throw const SocketException('offline');
    return {'accepted_at': '2026-10-01T10:00:00Z', ...userQuest};
  }

  @override
  Future<void> insertUserQuestIfAbsent(Map<String, dynamic> userQuest) async {
    if (writesDown) throw const SocketException('offline');
    attempts.insert(0, {...userQuest});
  }

  @override
  Future<Map<String, dynamic>> getProfile(String userId) async {
    if (catalogDown) throw const SocketException('offline');
    return {'id': userId, 'display_name': 'Ana'};
  }

  @override
  Future<Map<String, dynamic>> getPreferences(String userId) async {
    if (catalogDown) throw const SocketException('offline');
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
  List<Map<String, dynamic>> catalog = [];
  final Map<String, List<Map<String, dynamic>>> steps = {};
  Map<String, int> stepTotals = {};

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
  List<Map<String, dynamic>> getPendingPhotoProofs() => const [];

  @override
  List<Map<String, dynamic>>? getPhotoProofs(String attemptId) => null;

  @override
  Map<String, dynamic>? getActiveStepSession() => null;

  @override
  Map<String, dynamic>? getVerifiedCheckIn() => null;

  @override
  Map<String, int> getStepTotals() => stepTotals;

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

class _SilentTracker extends AnalyticsTracker {
  _SilentTracker()
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
  }) async {}
}

void main() {
  late _FakeRemote remote;
  late _FakeLocal local;
  late QuestRepository repository;
  late QuestViewModel viewModel;
  var nextId = 0;

  /// A fresh launch, as the cache would find it.
  QuestViewModel launch() {
    repository = QuestRepository(remote, local, newId: () => 'uuid-${++nextId}');
    return QuestViewModel(
      repository,
      _contextManager(),
      _SilentTracker(),
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
  }

  CompletionLevel foodLevel() =>
      viewModel.completionLevelFor(viewModel.questById('a')!, viewModel.completionLikelihoodByCategory);

  /// Everything saved by one online launch, then the app opens offline.
  Future<void> openOfflineAfter(List<Map<String, dynamic>> attempts) async {
    remote.attempts = attempts;
    final online = launch();
    await online.load();
    await online.loadSteps('c');
    remote.offline = true;
    viewModel = launch();
    await viewModel.load();
  }

  setUp(() {
    remote = _FakeRemote();
    local = _FakeLocal();
    viewModel = launch();
  });

  group('labels', () {
    test('online: computed from fresh data, and nothing to indicate', () async {
      remote.attempts = [
        _attemptRow('1', 'a', 'completed'),
        _attemptRow('2', 'b', 'completed'),
        _attemptRow('3', 'c', 'completed'),
      ];

      await viewModel.load();

      expect(foodLevel(), CompletionLevel.high);
      expect(viewModel.completionLabelsFromCache, isFalse);
    });

    test('with cached catalogue and attempts: still computed, and the indicator is on', () async {
      await openOfflineAfter([
        _attemptRow('1', 'a', 'completed'),
        _attemptRow('2', 'b', 'abandoned'),
        _attemptRow('3', 'c', 'abandoned'),
      ]);

      expect(viewModel.catalog, hasLength(4));
      expect(viewModel.userQuests, hasLength(3));
      expect(foodLevel(), CompletionLevel.low); // 1 of 3
      expect(viewModel.completionLabelsFromCache, isTrue);
    });

    test('an attempt accepted offline counts, as the repository mixes it in', () async {
      await openOfflineAfter([
        _attemptRow('1', 'a', 'completed'),
        _attemptRow('2', 'b', 'completed'),
      ]);
      expect(foodLevel(), CompletionLevel.newForYou); // only 2 attempts

      final started = await viewModel.startInstantPlan(Quest.fromJson(_questRow('c')));

      expect(started, isTrue);
      expect(viewModel.instantPlanQueued, isTrue);
      expect(foodLevel(), CompletionLevel.medium); // 2 of 3

      // Still counted after a restart, read back from the cache.
      viewModel = launch();
      await viewModel.load();
      expect(foodLevel(), CompletionLevel.medium);
      expect(viewModel.completionLabelsFromCache, isTrue);
    });
  });

  group('indicator', () {
    test('only the catalogue from the cache turns it on', () async {
      await viewModel.load();
      remote.catalogDown = true;

      await viewModel.load();

      expect(viewModel.completionLabelsFromCache, isTrue);
    });

    test('only the attempts from the cache turn it on', () async {
      await viewModel.load();
      remote.attemptsDown = true;

      await viewModel.load();

      expect(viewModel.completionLabelsFromCache, isTrue);
    });

    test('goes off once a load gets both from the server', () async {
      await openOfflineAfter([_attemptRow('1', 'a', 'completed')]);
      expect(viewModel.completionLabelsFromCache, isTrue);

      remote.offline = false;
      await viewModel.load();

      expect(viewModel.completionLabelsFromCache, isFalse);
    });

    test('agrees with what StatsView calls isFromCache for the attempts', () async {
      await viewModel.load();
      remote.attemptsDown = true;
      local.userQuests = [_attemptRow('1', 'a', 'completed')];

      final stats = StatsViewModel(
        repository,
        _userId,
        runner: (input) async => summarizeStats(input),
      );
      await stats.load();

      expect(stats.isFromCache, isTrue);
      expect(viewModel.completionLabelsFromCache, stats.isFromCache);
    });
  });

  group('Explore', () {
    Future<void> pumpExplore(WidgetTester tester) async {
      tester.view.physicalSize = const Size(800, 3000); // both sections on screen
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
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
    }

    final attempts = [
      _attemptRow('1', 'a', 'completed'),
      _attemptRow('2', 'b', 'completed'),
      _attemptRow('3', 'c', 'abandoned'),
    ];

    testWidgets('online: labels and no note', (tester) async {
      remote.attempts = attempts;

      await pumpExplore(tester);

      expect(find.text('Prob. media'), findsWidgets);
      expect(find.text(_note), findsNothing);
    });

    testWidgets('offline with a saved list: labels, and the note by both sections', (tester) async {
      remote.attempts = attempts;
      await tester.runAsync(() async {
        final online = launch();
        await online.load();
        await repository.getRecommendations(
          context: await _contextManager().snapshot(availableMinutes: 30),
          preferences: const UserPreferences(),
        );
      });
      remote.offline = true;
      viewModel = launch();

      await pumpExplore(tester);

      expect(viewModel.recommendations, isNotEmpty);
      expect(find.text('Prob. media'), findsWidgets);
      expect(find.text(_note), findsNWidgets(2));
    });

    testWidgets('offline with no saved list: the note stays with the catalogue', (tester) async {
      remote.attempts = attempts;
      await tester.runAsync(() => launch().load());
      remote.offline = true;
      viewModel = launch();

      await pumpExplore(tester);

      expect(viewModel.recommendations, isEmpty);
      expect(find.text('Prob. media'), findsWidgets);
      expect(find.text(_note), findsOneWidget);
    });

    testWidgets('filters that leave no quests: no labels, so no note either', (tester) async {
      remote.attempts = attempts;
      await tester.runAsync(() => launch().load());
      remote.offline = true;
      viewModel = launch();
      await pumpExplore(tester);
      expect(find.text(_note), findsOneWidget);

      viewModel.setMinutes(10); // every quest takes 20
      await tester.pumpAndSettle();

      expect(find.text('No hay misiones que coincidan con estos filtros.'), findsOneWidget);
      expect(find.text(_note), findsNothing);
    });

    testWidgets('the note goes away when fresh data arrives', (tester) async {
      remote.attempts = attempts;
      await tester.runAsync(() => launch().load());
      remote.offline = true;
      viewModel = launch();
      await pumpExplore(tester);
      expect(find.text(_note), findsOneWidget);

      remote.offline = false;
      await viewModel.load();
      await tester.pumpAndSettle();

      expect(find.text(_note), findsNothing);
    });
  });
}
