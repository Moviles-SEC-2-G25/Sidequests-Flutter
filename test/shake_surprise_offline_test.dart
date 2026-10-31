import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:provider/provider.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:sidequests/analytics/analytics_event_sink.dart';
import 'package:sidequests/analytics/analytics_event_type.dart';
import 'package:sidequests/analytics/analytics_tracker.dart';
import 'package:sidequests/core/verification/step_verification_strategy.dart';
import 'package:sidequests/data/context/context_manager.dart';
import 'package:sidequests/data/local/local_data_source.dart';
import 'package:sidequests/data/remote/supabase_remote_data_source.dart';
import 'package:sidequests/data/services/battery_monitor.dart';
import 'package:sidequests/data/services/biometric_service.dart';
import 'package:sidequests/data/services/location_check_in_service.dart';
import 'package:sidequests/data/services/location_service.dart';
import 'package:sidequests/data/services/reverse_geocoding_service.dart';
import 'package:sidequests/data/services/shake_detector.dart';
import 'package:sidequests/data/services/step_counter_service.dart';
import 'package:sidequests/data/services/weather_service.dart';
import 'package:sidequests/models/app_context.dart';
import 'package:sidequests/models/quest.dart';
import 'package:sidequests/repository/auth_repository.dart';
import 'package:sidequests/repository/profile_repository.dart';
import 'package:sidequests/repository/quest_repository.dart';
import 'package:sidequests/repository/social_repository.dart';
import 'package:sidequests/view/home_shell.dart';
import 'package:sidequests/view/quests/quest_detail_view.dart';
import 'package:sidequests/viewmodel/auth/auth_view_model.dart';
import 'package:sidequests/viewmodel/profile/profile_view_model.dart';
import 'package:sidequests/viewmodel/quests/quest_view_model.dart';
import 'package:sidequests/viewmodel/social/social_view_model.dart';
import 'package:sidequests/viewmodel/theme_view_model.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show AuthState, Session;

const _userId = 'user-1';
const _noCatalog =
    'Sin conexión y sin misiones guardadas: conéctate una vez para usar la misión sorpresa';
const _noCandidates = 'No hay misiones disponibles para sorprenderte ahora.';
const _noSavedData =
    'Sin conexión y sin datos guardados en el teléfono. Reintenta cuando tengas internet.';

Map<String, dynamic> _questRow(String id, {int minutes = 20}) => {
  'id': id,
  'title': 'Quest $id',
  'category': 'food',
  'duration_minutes': minutes,
  'difficulty': 'easy',
  'location_mode': 'anywhere',
  'social_level': 'solo',
};

List<Map<String, dynamic>> _stepRows(String questId, int count) => [
  for (var i = 0; i < count; i++)
    {'id': i, 'quest_id': questId, 'step_order': i, 'title': 'Paso $i de $questId'},
];

/// Supabase in memory. [offline] fails every call like a dropped connection.
class _FakeRemote implements SupabaseRemoteDataSource {
  bool offline = false;
  List<Map<String, dynamic>> recommendations = const [];
  List<Map<String, dynamic>> quests = [_questRow('a'), _questRow('b'), _questRow('c')];
  final Map<String, List<Map<String, dynamic>>> steps = {
    'a': _stepRows('a', 1),
    'b': _stepRows('b', 2),
    'c': _stepRows('c', 3),
  };
  final List<Map<String, dynamic>> userQuests = [];

  void _failIfDown() {
    if (offline) throw const SocketException('offline');
  }

  @override
  Session? get currentSession => null;

  @override
  String? get currentUserEmail => null;

  @override
  Stream<AuthState> get authStateChanges => const Stream.empty();

  @override
  Future<List<Map<String, dynamic>>> getActiveQuests() async {
    _failIfDown();
    return quests;
  }

  @override
  Future<List<Map<String, dynamic>>> getQuestSteps(String questId) async {
    _failIfDown();
    return steps[questId] ?? [];
  }

  @override
  Future<List<Map<String, dynamic>>> getUserQuests(String userId) async {
    _failIfDown();
    return userQuests;
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
  Future<List<Map<String, dynamic>>> recommendQuests({
    required int availableMinutes,
    required String socialLevel,
    List<String> interests = const [],
    String locationMode = 'all',
    List<String> excludedQuestIds = const [],
    int limit = 3,
  }) async => recommendations; // never fails: not what these tests are about

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// The Hive box and SharedPreferences, in memory.
class _FakeLocal implements LocalDataSource {
  List<Map<String, dynamic>> catalog = [];
  List<Map<String, dynamic>> userQuests = [];
  List<Map<String, dynamic>> pendingAnalytics = [];
  final Map<String, List<Map<String, dynamic>>> steps = {};

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
  List<Map<String, dynamic>> getUserQuests() => userQuests;

  @override
  Future<void> cacheUserQuests(List<Map<String, dynamic>> rows) async => userQuests = rows;

  @override
  Future<void> cacheActiveQuestId(String? questId) async {}

  @override
  List<Map<String, dynamic>> getPendingAnalyticsEvents() => [...pendingAnalytics];

  @override
  Future<void> savePendingAnalyticsEvents(List<Map<String, dynamic>> events) async =>
      pendingAnalytics = events;

  @override
  Map<String, dynamic>? getActiveStepSession() => null;

  @override
  List<Map<String, dynamic>> getPendingWrites() => const [];

  @override
  ({String batchId, List<Map<String, dynamic>> rows})? getSavedRecommendations() => null;

  @override
  List<Map<String, dynamic>> getPendingPhotoProofs() => const [];

  @override
  List<Map<String, dynamic>>? getPhotoProofs(String attemptId) => null;

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
  bool isDarkMode() => false;

  @override
  bool isBiometricEnabled() => false;

  @override
  bool missionNotificationsEnabled() => true;

  @override
  bool dailyRemindersEnabled() => false;

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

class _CountingContextManager extends ContextManager {
  int snapshots = 0;

  _CountingContextManager()
    : super(
        locationService: _NoLocation(),
        batteryMonitor: _FullBattery(),
        connectivity: _FakeConnectivity(),
      );

  @override
  Future<AppContext> snapshot({int? availableMinutes}) {
    snapshots++;
    return super.snapshot(availableMinutes: availableMinutes);
  }
}

class _SpyTracker extends AnalyticsTracker {
  final List<({String type, String? questId})> calls = [];

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
  }) async => calls.add((type: eventType, questId: questId));

  Iterable<String?> get shakes =>
      calls.where((c) => c.type == AnalyticsEventType.shakeSurprise).map((c) => c.questId);
}

void main() {
  late _FakeRemote remote;
  late _FakeLocal local;
  late QuestRepository repository;
  late _SpyTracker tracker;

  QuestViewModel newViewModel(AnalyticsTracker analyticsTracker, {ContextManager? contextManager}) => QuestViewModel(
    repository,
    contextManager ?? _contextManager(),
    analyticsTracker,
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

  List<String> ids(Iterable<dynamic> quests) => [for (final quest in quests) quest.id as String];

  setUp(() {
    remote = _FakeRemote();
    local = _FakeLocal();
    repository = QuestRepository(remote, local);
    tracker = _SpyTracker();
  });

  group('shakeCandidates', () {
    test('with a connection: every quest, cached steps or not', () async {
      await repository.getSteps('a');
      final viewModel = newViewModel(tracker);
      await viewModel.load();

      expect(ids(viewModel.shakeCandidates()), ['a', 'b', 'c']);
    });

    test('offline: only quests with cached steps', () async {
      await repository.getSteps('b');
      final viewModel = newViewModel(tracker);
      await viewModel.load();

      expect(ids(viewModel.shakeCandidates(isOffline: true)), ['b']);
    });

    test('the last load came from the cache: same, even if connectivity says online', () async {
      await repository.getCatalog();
      await repository.getSteps('c');
      remote.offline = true; // e.g. a Wi-Fi network without internet
      final viewModel = newViewModel(tracker);
      await viewModel.load();

      expect(ids(viewModel.shakeCandidates()), ['c']);
    });

    test('a load with the network back returns to every quest', () async {
      await repository.getCatalog();
      await repository.getSteps('c');
      remote.offline = true;
      final viewModel = newViewModel(tracker);
      await viewModel.load();

      remote.offline = false;
      await viewModel.load();

      expect(ids(viewModel.shakeCandidates()), ['a', 'b', 'c']);
    });

    test('offline with no steps cached at all: any quest of the catalog', () async {
      final viewModel = newViewModel(tracker);
      await viewModel.load();

      expect(ids(viewModel.shakeCandidates(isOffline: true)), ['a', 'b', 'c']);
    });

    test('a cached empty step list counts: the detail opens without a connection', () async {
      local.steps['a'] = [];
      final viewModel = newViewModel(tracker);
      await viewModel.load();

      expect(ids(viewModel.shakeCandidates(isOffline: true)), ['a']);
    });

    test('offline it still respects filters and completed quests', () async {
      remote.quests = [_questRow('a'), _questRow('long', minutes: 500), _questRow('b')];
      remote.steps['long'] = _stepRows('long', 1);
      remote.userQuests.add({
        'id': 'uq-a',
        'user_id': _userId,
        'quest_id': 'a',
        'status': 'completed',
        'accepted_at': '2026-01-01T00:00:00Z',
      });
      for (final id in ['a', 'long', 'b']) {
        await repository.getSteps(id);
      }
      final viewModel = newViewModel(tracker);
      await viewModel.load();

      expect(ids(viewModel.shakeCandidates(isOffline: true)), ['b']);
    });

    test('a cached quest the filters exclude does not displace the others', () async {
      remote.quests = [_questRow('long', minutes: 500), _questRow('b')];
      remote.steps['long'] = _stepRows('long', 1);
      await repository.getSteps('long');
      final viewModel = newViewModel(tracker);
      await viewModel.load();

      expect(ids(viewModel.shakeCandidates(isOffline: true)), ['b']);
    });
  });

  group('shakeHasNoSavedCatalog', () {
    test('offline, loaded and empty', () async {
      remote.offline = true;
      final viewModel = newViewModel(tracker);
      await viewModel.load();

      expect(viewModel.shakeHasNoSavedCatalog(isOffline: true), isTrue);
      expect(viewModel.shakeHasNoSavedCatalog(), isTrue); // the load itself fell back
    });

    test('not while the first load is running', () async {
      remote.offline = true;
      final viewModel = newViewModel(tracker);

      final loading = viewModel.load();
      expect(viewModel.shakeHasNoSavedCatalog(isOffline: true), isFalse);
      await loading;
    });

    test('not when the server answered with an empty catalog', () async {
      remote.quests = [];
      final viewModel = newViewModel(tracker);
      await viewModel.load();

      expect(viewModel.shakeHasNoSavedCatalog(), isFalse);
    });

    test('not when filters exclude what is saved', () async {
      remote.quests = [_questRow('long', minutes: 500)];
      final viewModel = newViewModel(tracker);
      await viewModel.load();

      expect(viewModel.shakeCandidates(isOffline: true), isEmpty);
      expect(viewModel.shakeHasNoSavedCatalog(isOffline: true), isFalse);
    });
  });

  group('steps of a quest opened offline', () {
    test('no cache: the existing message, for that quest only, and no steps', () async {
      remote.offline = true;
      final viewModel = newViewModel(tracker);

      await viewModel.loadSteps('a');

      expect(viewModel.stepsOf('a'), isEmpty);
      expect(viewModel.stepsUnavailableMessage('a'), _noSavedData);
      expect(viewModel.stepsUnavailableMessage('b'), isNull);
    });

    test('a failure leaves the active mission its steps', () async {
      await repository.getSteps('a');
      final viewModel = newViewModel(tracker);
      await viewModel.loadSteps('a');
      remote.offline = true;

      await viewModel.loadSteps('b');

      expect(viewModel.stepsOf('b'), isEmpty);
      expect(viewModel.stepsOf('a').single.title, 'Paso 0 de a');
      expect(viewModel.steps.single.title, 'Paso 0 de a');
    });

    test('opening it later with the steps cached clears the message', () async {
      remote.offline = true;
      final viewModel = newViewModel(tracker);
      await viewModel.loadSteps('a');

      remote.offline = false;
      await viewModel.loadSteps('a');

      expect(viewModel.stepsUnavailableMessage('a'), isNull);
      expect(viewModel.stepsOf('a'), hasLength(1));
    });

    test('a rejection from the server is not "no saved data"', () async {
      final viewModel = newViewModel(tracker);
      await viewModel.loadSteps('unknown-is-fine');

      expect(viewModel.stepsUnavailableMessage('unknown-is-fine'), isNull);
    });
  });

  test('shake_surprise goes to the existing offline queue, then out', () async {
    final sink = _RecordingSink()..offline = true;
    final analytics = AnalyticsTracker(
      eventSink: sink,
      contextManager: _contextManager(),
      sessionId: 'session',
      localDataSource: local,
    );
    final viewModel = newViewModel(analytics);

    viewModel.trackShakeSurprise('a');
    await pumpEventQueue();

    expect(sink.sent, isEmpty);
    final queued = local.pendingAnalytics.single;
    expect(queued['event_type'], AnalyticsEventType.shakeSurprise);
    expect(queued['quest_id'], 'a');
    expect(queued['occurred_at'], isNotNull);

    sink.offline = false;
    await analytics.flushPending();

    expect(sink.sent.single['event_type'], AnalyticsEventType.shakeSurprise);
    expect(local.pendingAnalytics, isEmpty);
  });

  group('HomeShell', () {
    late StreamController<UserAccelerometerEvent> accelerometer;
    late DateTime now;

    const channels = [
      'dev.fluttercommunity.plus/connectivity',
      'dev.fluttercommunity.plus/connectivity_status',
      'dev.fluttercommunity.plus/battery',
      'dev.fluttercommunity.plus/charging',
    ];

    /// Real ContextStatusViewModel over the plugins' channels.
    void mockPlugins({required bool offline}) {
      final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      for (final channel in channels) {
        messenger.setMockMethodCallHandler(MethodChannel(channel), (call) async {
          return switch (call.method) {
            'check' => [offline ? 'none' : 'wifi'],
            'getBatteryLevel' => 100,
            _ => null,
          };
        });
      }
      addTearDown(() {
        for (final channel in channels) {
          messenger.setMockMethodCallHandler(MethodChannel(channel), null);
        }
      });
    }

    Future<void> pumpShell(WidgetTester tester, {ContextManager? contextManager}) async {
      accelerometer = StreamController<UserAccelerometerEvent>.broadcast();
      now = DateTime(2026, 1, 1, 12);
      final shakeDetector = ShakeDetector(
        accelerometerEvents: accelerometer.stream,
        now: () => now,
      );
      final viewModel = newViewModel(tracker, contextManager: contextManager);
      final authRepository = AuthRepository(remote, local);
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            Provider<LocalDataSource>.value(value: local),
            Provider<AnalyticsTracker>.value(value: tracker),
            Provider<LocationService>.value(value: _NoLocation()),
            Provider<WeatherService>.value(
              value: WeatherService(),
            ),
            Provider<ReverseGeocodingService>(
              create: (_) => ReverseGeocodingService(localDataSource: local),
            ),
            ChangeNotifierProvider(create: (_) => ThemeViewModel(local)),
            ChangeNotifierProvider(
              create: (_) => AuthViewModel(authRepository, BiometricService(), tracker),
            ),
            ChangeNotifierProvider<QuestViewModel>.value(value: viewModel),
            ChangeNotifierProvider(
              create: (_) => ProfileViewModel(
                ProfileRepository(remote, local),
                authRepository,
                _userId,
              ),
            ),
            ChangeNotifierProvider(create: (_) => SocialViewModel(SocialRepository())),
          ],
          child: MaterialApp(home: HomeShell(shakeDetector: shakeDetector)),
        ),
      );
      await tester.pump();
      await tester.pump();
      await tester.pump();
    }

    Future<void> shake(WidgetTester tester) async {
      now = now.add(const Duration(minutes: 1));
      accelerometer.add(UserAccelerometerEvent(ShakeDetector.threshold + 1, 0, 0, now));
      await tester.pump();
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
    }

    Future<void> goBack(WidgetTester tester) async {
      tester.state<NavigatorState>(find.byType(Navigator).first).pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
    }

    group('only listens on a visible Explorar, in the foreground', () {
      setUp(() => remote.recommendations = const []);

      testWidgets('12 shakes open 1 detail, and 1 shake_surprise', (tester) async {
        mockPlugins(offline: false);
        await pumpShell(tester);

        for (var i = 0; i < 12; i++) {
          await shake(tester);
        }

        expect(find.byType(QuestDetailView), findsOneWidget);
        expect(tracker.shakes, hasLength(1));
      });

      testWidgets('the sensor stops under another screen and resumes on coming back', (
        tester,
      ) async {
        mockPlugins(offline: false);
        await pumpShell(tester);
        expect(accelerometer.hasListener, isTrue);

        await shake(tester);
        expect(accelerometer.hasListener, isFalse);

        await goBack(tester);
        expect(accelerometer.hasListener, isTrue);

        await shake(tester);
        expect(find.byType(QuestDetailView), findsOneWidget);
        expect(tracker.shakes, hasLength(2));
      });

      testWidgets('the sensor stops on other tabs', (tester) async {
        mockPlugins(offline: false);
        await pumpShell(tester);

        await tester.tap(find.text('Social'));
        await tester.pump();
        expect(accelerometer.hasListener, isFalse);

        await tester.tap(find.text('Explorar'));
        await tester.pump();
        expect(accelerometer.hasListener, isTrue);
      });

      testWidgets('the sensor stops in the background', (tester) async {
        mockPlugins(offline: false);
        await pumpShell(tester);

        for (final state in const [
          AppLifecycleState.inactive,
          AppLifecycleState.hidden,
          AppLifecycleState.paused,
        ]) {
          tester.binding.handleAppLifecycleStateChanged(state);
        }
        await tester.pump();
        expect(accelerometer.hasListener, isFalse);

        for (final state in const [
          AppLifecycleState.hidden,
          AppLifecycleState.inactive,
          AppLifecycleState.resumed,
        ]) {
          tester.binding.handleAppLifecycleStateChanged(state);
        }
        await tester.pump();
        expect(accelerometer.hasListener, isTrue);
      });
    });

    testWidgets('offline with no catalog ever saved: says so, opens nothing, tracks nothing', (
      tester,
    ) async {
      remote.offline = true;
      mockPlugins(offline: true);
      await pumpShell(tester);

      await shake(tester);

      expect(find.text(_noCatalog), findsOneWidget);
      expect(find.byType(QuestDetailView), findsNothing);
      expect(tracker.shakes, isEmpty);
    });

    testWidgets('offline: opens the quest with cached steps and tracks it', (tester) async {
      await tester.runAsync(() async {
        await repository.getCatalog();
        await repository.getSteps('b');
      });
      remote.offline = true;
      mockPlugins(offline: true);
      await pumpShell(tester);

      await shake(tester);

      expect(find.text('Quest b'), findsWidgets);
      expect(find.byType(QuestDetailView), findsOneWidget);
      expect(find.text('Qué harás (2 pasos)'), findsOneWidget);
      expect(find.text(_noSavedData), findsNothing);
      expect(tracker.shakes, ['b']);
    });

    testWidgets('offline with no steps cached: the detail says so, without a stale count', (
      tester,
    ) async {
      await tester.runAsync(() => repository.getCatalog());
      remote.offline = true;
      mockPlugins(offline: true);
      await pumpShell(tester);

      await shake(tester);

      expect(find.byType(QuestDetailView), findsOneWidget);
      expect(find.text(_noSavedData), findsOneWidget);
      expect(find.text('Qué harás'), findsOneWidget);
      expect(tracker.shakes, hasLength(1));
      expect(tester.takeException(), isNull);
    });

    testWidgets('ContextStatusViewModel alone is enough: offline before any load fell back', (
      tester,
    ) async {
      await tester.runAsync(() => repository.getSteps('b'));
      mockPlugins(offline: true); // the catalog itself still answers from the server
      await pumpShell(tester);

      // The pick is random: several shakes, so 'b' can't come up by chance.
      for (var i = 0; i < 12; i++) {
        await shake(tester);
        await goBack(tester);
      }

      expect(repository.catalogFromCache, isFalse);
      expect(tracker.shakes, hasLength(12));
      expect(tracker.shakes.toSet(), {'b'});
    });

    testWidgets('the detail never shows the step count of the mission loaded before it', (
      tester,
    ) async {
      final viewModel = newViewModel(tracker);
      await tester.runAsync(() => viewModel.loadSteps('c')); // 3 steps
      remote.offline = true;

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<QuestViewModel>.value(value: viewModel),
            Provider<LocationService>.value(value: _NoLocation()),
            Provider<WeatherService>.value(value: WeatherService()),
          ],
          child: MaterialApp(home: QuestDetailView(quest: Quest.fromJson(_questRow('a')))),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(find.text('Qué harás (3 pasos)'), findsNothing);
      expect(find.text('Qué harás'), findsOneWidget);
      expect(find.text(_noSavedData), findsOneWidget);
    });

    testWidgets('with a connection: opens a quest as always, without the offline message', (
      tester,
    ) async {
      mockPlugins(offline: false);
      await pumpShell(tester);

      await shake(tester);

      expect(find.byType(QuestDetailView), findsOneWidget);
      expect(find.text(_noCatalog), findsNothing);
      expect(find.text(_noSavedData), findsNothing);
      expect(tracker.shakes, hasLength(1));
    });

    testWidgets('reconnecting refreshes the context without logging the live list again', (
      tester,
    ) async {
      remote.recommendations = [
        {'quest_id': 'a', 'score': 1.5},
      ];
      mockPlugins(offline: true);
      final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      late MockStreamHandlerEventSink connectivityEvents;
      const status = EventChannel('dev.fluttercommunity.plus/connectivity_status');
      messenger.setMockStreamHandler(
        status,
        MockStreamHandler.inline(
          onListen: (_, events) {
            connectivityEvents = events;
          },
        ),
      );
      addTearDown(() => messenger.setMockStreamHandler(status, null));
      final contextManager = _CountingContextManager();
      await pumpShell(tester, contextManager: contextManager);
      await tester.pump(const Duration(milliseconds: 100));
      final shownBefore = tracker.calls
          .where((c) => c.type == AnalyticsEventType.recommendationShown)
          .length;
      final snapshotsBefore = contextManager.snapshots;
      expect(shownBefore, 1);

      connectivityEvents.success(['wifi']);
      await tester.pump();
      await tester.pump(const Duration(seconds: 3));
      await tester.pump();
      await tester.pump();

      expect(contextManager.snapshots, snapshotsBefore + 1);
      expect(
        tracker.calls.where((c) => c.type == AnalyticsEventType.recommendationShown),
        hasLength(shownBefore),
      );
    });

    testWidgets('with a connection and an empty catalog: the usual message', (tester) async {
      remote.quests = [];
      mockPlugins(offline: false);
      await pumpShell(tester);

      await shake(tester);

      expect(find.text(_noCandidates), findsOneWidget);
      expect(find.text(_noCatalog), findsNothing);
    });
  });
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
