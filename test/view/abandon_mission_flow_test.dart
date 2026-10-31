import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:provider/provider.dart';
import 'package:sidequests/analytics/analytics_event_sink.dart';
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
import 'package:sidequests/models/pending_write.dart';
import 'package:sidequests/models/quest.dart';
import 'package:sidequests/repository/auth_repository.dart';
import 'package:sidequests/repository/profile_repository.dart';
import 'package:sidequests/repository/quest_repository.dart';
import 'package:sidequests/repository/social_repository.dart';
import 'package:sidequests/view/home_shell.dart';
import 'package:sidequests/view/quests/abandon_mission_view.dart';
import 'package:sidequests/view/quests/mission_tab_view.dart';
import 'package:sidequests/view/quests/quest_alternatives_view.dart';
import 'package:sidequests/view/quests/quest_detail_view.dart';
import 'package:sidequests/viewmodel/auth/auth_view_model.dart';
import 'package:sidequests/viewmodel/profile/profile_view_model.dart';
import 'package:sidequests/viewmodel/quests/quest_view_model.dart';
import 'package:sidequests/viewmodel/social/social_view_model.dart';
import 'package:sidequests/viewmodel/theme_view_model.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show AuthState, Session;

const _userId = 'user-1';

Map<String, dynamic> _questRow(String id, {int minutes = 20}) => {
  'id': id,
  'title': 'Quest $id',
  'category': 'food',
  'duration_minutes': minutes,
  'difficulty': 'easy',
  'location_mode': 'anywhere',
  'social_level': 'solo',
};

Map<String, dynamic> _attemptRow(String status) => {
  'id': 'uq-1',
  'user_id': _userId,
  'quest_id': 'source',
  'status': status,
  'current_step': 0,
  'completed_steps': <int>[],
  'accepted_at': '2026-10-01T10:00:00Z',
};

class _FakeRemote implements SupabaseRemoteDataSource {
  bool offline = false;
  final List<Map<String, dynamic>> userQuests = [_attemptRow('in_progress')];
  final List<Map<String, dynamic>> upserts = [];

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
    return [
      _questRow('source', minutes: 30),
      _questRow('option', minutes: 10),
    ];
  }

  @override
  Future<List<Map<String, dynamic>>> getQuestSteps(String questId) async {
    _failIfDown();
    return [
      {'id': 1, 'quest_id': questId, 'step_order': 0, 'title': 'Paso de $questId'},
      {'id': 2, 'quest_id': questId, 'step_order': 1, 'title': 'Otro paso de $questId'},
    ];
  }

  @override
  Future<List<Map<String, dynamic>>> getUserQuests(String userId) async {
    _failIfDown();
    return [...userQuests];
  }

  @override
  Future<Map<String, dynamic>> upsertUserQuest(Map<String, dynamic> userQuest) async {
    _failIfDown();
    upserts.add(userQuest);
    final id = userQuest['id'] ?? 'uq-new';
    final existing = userQuests.where((row) => row['id'] == id).firstOrNull;
    final row = {'accepted_at': '2026-10-02T10:00:00Z', ...?existing, ...userQuest, 'id': id};
    userQuests
      ..removeWhere((r) => r['id'] == id)
      ..insert(0, row);
    return row;
  }

  @override
  Future<List<Map<String, dynamic>>> getQuestPhotoProofs(String attemptId) async => const [];

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
  }) async => const [];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeLocal implements LocalDataSource {
  List<Map<String, dynamic>> catalog = [];
  List<Map<String, dynamic>> userQuests = [];
  List<Map<String, dynamic>> pendingWrites = [];
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
  Future<void> saveActiveStepSession(Map<String, dynamic>? session) async {}

  @override
  Map<String, int> getStepTotals() => const {};

  @override
  Map<String, dynamic>? getVerifiedCheckIn() => null;

  @override
  Future<void> saveVerifiedCheckIn(Map<String, dynamic>? checkIn) async {}

  @override
  List<Map<String, dynamic>> getPendingWrites() => pendingWrites;

  @override
  Future<void> savePendingWrites(List<Map<String, dynamic>> writes) async => pendingWrites = writes;

  @override
  ({String batchId, List<Map<String, dynamic>> rows})? getSavedRecommendations() => null;

  @override
  List<Map<String, dynamic>> getPendingPhotoProofs() => const [];

  @override
  List<Map<String, dynamic>>? getPhotoProofs(String attemptId) => null;

  @override
  Future<void> cachePhotoProofs(String attemptId, List<Map<String, dynamic>> proofs) async {}

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

class _CapturingSink implements AnalyticsEventSink {
  final List<Map<String, dynamic>> events = [];

  @override
  Future<void> insertAnalyticsEvent(Map<String, dynamic> event) async => events.add(event);
}

class _FakeConnectivity implements Connectivity {
  @override
  Future<List<ConnectivityResult>> checkConnectivity() async => [ConnectivityResult.wifi];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

ContextManager _contextManager() => ContextManager(
  locationService: _NoLocation(),
  batteryMonitor: _FullBattery(),
  connectivity: _FakeConnectivity(),
);

const _channels = [
  'dev.fluttercommunity.plus/connectivity',
  'dev.fluttercommunity.plus/connectivity_status',
  'dev.fluttercommunity.plus/battery',
  'dev.fluttercommunity.plus/charging',
];

void main() {
  late _FakeRemote remote;
  late _FakeLocal local;
  late _CapturingSink sink;
  late QuestViewModel viewModel;

  setUp(() {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final channel in _channels) {
      messenger.setMockMethodCallHandler(MethodChannel(channel), (call) async {
        return switch (call.method) {
          'check' => ['wifi'],
          'getBatteryLevel' => 100,
          _ => null,
        };
      });
    }
    addTearDown(() {
      for (final channel in _channels) {
        messenger.setMockMethodCallHandler(MethodChannel(channel), null);
      }
    });
    remote = _FakeRemote();
    local = _FakeLocal();
    sink = _CapturingSink();
    viewModel = QuestViewModel(
      QuestRepository(remote, local),
      _contextManager(),
      AnalyticsTracker(eventSink: sink, contextManager: _contextManager(), sessionId: 'session-1'),
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
  });

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.pump();
    }
    await tester.pump(const Duration(seconds: 1)); // the page transition ends
    await tester.pump();
  }

  Future<void> pumpShell(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1000, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final authRepository = AuthRepository(remote, local);
    final tracker = AnalyticsTracker(
      eventSink: sink,
      contextManager: _contextManager(),
      sessionId: 'session-1',
    );
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          Provider<LocalDataSource>.value(value: local),
          Provider<AnalyticsTracker>.value(value: tracker),
          Provider<LocationService>.value(value: _NoLocation()),
          Provider<WeatherService>.value(value: WeatherService()),
          Provider<ReverseGeocodingService>(
            create: (_) => ReverseGeocodingService(localDataSource: local),
          ),
          ChangeNotifierProvider(create: (_) => ThemeViewModel(local)),
          ChangeNotifierProvider(
            create: (_) => AuthViewModel(authRepository, BiometricService(), tracker),
          ),
          ChangeNotifierProvider<QuestViewModel>.value(value: viewModel),
          ChangeNotifierProvider(
            create: (_) => ProfileViewModel(ProfileRepository(remote, local), authRepository, _userId),
          ),
          ChangeNotifierProvider(create: (_) => SocialViewModel(SocialRepository())),
        ],
        child: MaterialApp(
          home: HomeShell(
            shakeDetector: ShakeDetector(
              accelerometerEvents: const Stream.empty(),
              now: () => DateTime(2026, 10, 31),
            ),
          ),
        ),
      ),
    );
    await settle(tester);
    await tester.runAsync(viewModel.load);
    await settle(tester);
  }

  Future<void> openAbandonScreen(WidgetTester tester) async {
    await tester.tap(find.text('Misión'));
    await settle(tester);
    await tester.runAsync(() => viewModel.loadSteps('source'));
    await settle(tester);
    await tester.tap(find.text('Salir'));
    await settle(tester);
    expect(find.byType(AbandonMissionView), findsOneWidget);
  }

  Future<void> tapVisible(WidgetTester tester, String text) async {
    await tester.ensureVisible(find.text(text));
    await tester.pump();
    await tester.tap(find.text(text));
    await settle(tester);
  }

  NavigationBar navigationBar(WidgetTester tester) =>
      tester.widget<NavigationBar>(find.byType(NavigationBar, skipOffstage: false));

  group('"Guardar y volver después"', () {
    testWidgets('only goes back: nothing written, nothing tracked, the mission stays', (tester) async {
      await pumpShell(tester);
      await openAbandonScreen(tester);
      sink.events.clear();

      await tapVisible(tester, 'Guardar y volver después');

      expect(find.byType(AbandonMissionView), findsNothing);
      expect(remote.upserts, isEmpty);
      expect(sink.events, isEmpty);
      expect(viewModel.currentMission?.status, 'in_progress');
    });
  });

  group('"Empezar otra misión"', () {
    testWidgets('abandons once and shows the alternatives over HomeShell', (tester) async {
      await pumpShell(tester);
      await openAbandonScreen(tester);

      await tapVisible(tester, AbandonmentReasonLabels.tooLong);
      await tapVisible(tester, 'Empezar otra misión');

      expect(find.byType(QuestAlternativesView), findsOneWidget);
      expect(find.text('Una mejor opción para ahora'), findsOneWidget);
      expect(find.textContaining(AbandonmentReasonLabels.tooLong), findsOneWidget);
      expect(find.text('Quest option'), findsOneWidget);
      expect(find.text('Por qué te sirve'), findsOneWidget);
      expect(find.textContaining('Es más corta que la misión que dejaste'), findsOneWidget);
      expect(remote.upserts, hasLength(1));
      expect(remote.upserts.single['abandon_reason'], 'ran_out_of_time');
      expect(find.byType(HomeShell, skipOffstage: false), findsOneWidget);
    });

    testWidgets('without choosing a reason it is saved as other', (tester) async {
      await pumpShell(tester);
      await openAbandonScreen(tester);

      await tapVisible(tester, 'Empezar otra misión');

      expect(remote.upserts.single['abandon_reason'], 'other');
    });

    testWidgets('offline: closes the mission, tells it is queued, and suggests from the cache', (
      tester,
    ) async {
      await pumpShell(tester);
      await openAbandonScreen(tester);
      remote.offline = true;

      await tapVisible(tester, 'Empezar otra misión');

      expect(find.textContaining('se sincronizará al reconectar'), findsOneWidget);
      expect(find.byType(QuestAlternativesView), findsOneWidget);
      expect(find.text('Quest option'), findsOneWidget);
      expect(viewModel.currentMission, isNull);
      expect(PendingWrite.fromJson(local.pendingWrites.single).type, PendingWrite.abandonQuest);
      expect(remote.upserts, isEmpty);
    });
  });

  group('the alternatives screen', () {
    Future<void> openAlternatives(WidgetTester tester) async {
      await pumpShell(tester);
      await openAbandonScreen(tester);
      await tapVisible(tester, 'Empezar otra misión');
    }

    testWidgets('"Volver a Explorar" lands on HomeShell, on the Explorar tab', (tester) async {
      await openAlternatives(tester);

      await tapVisible(tester, 'Volver a Explorar');

      expect(find.byType(QuestAlternativesView), findsNothing);
      expect(find.byType(NavigationBar), findsOneWidget);
      expect(navigationBar(tester).selectedIndex, 0);
      expect(viewModel.questAlternatives, isNull);
    });

    testWidgets('the system back button does the same', (tester) async {
      await openAlternatives(tester);

      await tester.state<NavigatorState>(find.byType(Navigator).first).maybePop();
      await settle(tester);

      expect(find.byType(QuestAlternativesView), findsNothing);
      expect(find.byType(NavigationBar), findsOneWidget);
      expect(navigationBar(tester).selectedIndex, 0);
      expect(viewModel.questAlternatives, isNull);
    });

    testWidgets('"Ver misión" opens the detail, accepting nothing', (tester) async {
      await openAlternatives(tester);
      final writesBefore = remote.upserts.length;

      await tapVisible(tester, 'Ver misión');

      expect(find.byType(QuestDetailView), findsOneWidget);
      expect(remote.upserts, hasLength(writesBefore));
      expect(viewModel.currentMission, isNull);
      expect(find.text('Aceptar misión →'), findsOneWidget);

      await tester.state<NavigatorState>(find.byType(Navigator).first).maybePop();
      await settle(tester);
      expect(find.byType(QuestAlternativesView), findsOneWidget);
    });

    testWidgets('the Misión tab no longer shows the abandoned mission', (tester) async {
      await openAlternatives(tester);
      await tapVisible(tester, 'Volver a Explorar');

      await tester.tap(find.text('Misión'));
      await settle(tester);

      expect(find.text('No tienes ninguna misión activa'), findsOneWidget);

      await tapVisible(tester, 'Explorar misiones');

      expect(find.byType(NavigationBar), findsOneWidget);
      expect(navigationBar(tester).selectedIndex, 0);
    });
  });

  testWidgets('the detail of an abandoned quest offers a new attempt, not to continue', (tester) async {
    remote.userQuests
      ..clear()
      ..add(_attemptRow('abandoned'));
    await tester.runAsync(viewModel.load);
    tester.view.physicalSize = const Size(1000, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<QuestViewModel>.value(value: viewModel),
          Provider<LocationService>.value(value: _NoLocation()),
          Provider<WeatherService>.value(value: WeatherService()),
          Provider<ReverseGeocodingService>(
            create: (_) => ReverseGeocodingService(localDataSource: local),
          ),
        ],
        child: MaterialApp(home: QuestDetailView(quest: Quest.fromJson(_questRow('source')))),
      ),
    );
    await settle(tester);

    expect(find.text('Aceptar misión →', skipOffstage: false), findsOneWidget);
    expect(find.text('Continuar misión →', skipOffstage: false), findsNothing);

    await tester.ensureVisible(find.text('Aceptar misión →'));
    await tester.pump();
    await tester.tap(find.text('Aceptar misión →'));
    await settle(tester);

    expect(find.byType(MissionTabView), findsOneWidget);
    expect(remote.upserts.single.containsKey('id'), isFalse); // a new attempt
    expect(viewModel.currentMission?.id, 'uq-new');
  });
}

/// Spelled out here: the screen shows exactly this text.
abstract final class AbandonmentReasonLabels {
  static const tooLong = 'Se me acabó el tiempo';
}
