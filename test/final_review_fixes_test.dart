import 'dart:async';
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
import 'package:sidequests/core/verification/step_verification_strategy.dart';
import 'package:sidequests/data/context/context_manager.dart';
import 'package:sidequests/data/local/local_data_source.dart';
import 'package:sidequests/data/remote/network_guard.dart';
import 'package:sidequests/data/remote/supabase_remote_data_source.dart';
import 'package:sidequests/data/services/battery_monitor.dart';
import 'package:sidequests/data/services/biometric_service.dart';
import 'package:sidequests/data/services/location_check_in_service.dart';
import 'package:sidequests/data/services/location_service.dart';
import 'package:sidequests/data/services/step_counter_service.dart';
import 'package:sidequests/models/pending_write.dart';
import 'package:sidequests/models/photo_proof.dart';
import 'package:sidequests/models/quest.dart';
import 'package:sidequests/models/quest_recommendation.dart';
import 'package:sidequests/models/quest_step.dart';
import 'package:sidequests/models/step_session.dart';
import 'package:sidequests/models/user_preferences.dart';
import 'package:sidequests/models/user_quest.dart';
import 'package:sidequests/repository/auth_repository.dart';
import 'package:sidequests/repository/profile_repository.dart';
import 'package:sidequests/repository/quest_repository.dart';
import 'package:sidequests/view/profile/profile_view.dart';
import 'package:sidequests/view/quests/explore_view.dart';
import 'package:sidequests/view/quests/mission_tab_view.dart';
import 'package:sidequests/view/quests/quest_completed_view.dart';
import 'package:sidequests/viewmodel/auth/auth_view_model.dart';
import 'package:sidequests/viewmodel/profile/profile_view_model.dart';
import 'package:sidequests/viewmodel/quests/quest_view_model.dart';
import 'package:sidequests/viewmodel/theme_view_model.dart';
import 'package:supabase_flutter/supabase_flutter.dart'
    show AuthChangeEvent, AuthState, Session, SignOutReason, SupabaseClient, User;

const _userId = 'user-1';
const _limit = NetworkGuard.timeout;

Map<String, dynamic> _questRow(String id) => {
  'id': id,
  'title': 'Quest $id',
  'category': 'food',
  'duration_minutes': 20,
  'difficulty': 'easy',
  'location_mode': 'anywhere',
  'social_level': 'solo',
};

Quest _quest(String id) => Quest.fromJson(_questRow(id));

Map<String, dynamic> _attemptRow(String id, String questId, String status) => {
  'id': id,
  'user_id': _userId,
  'quest_id': questId,
  'status': status,
  'accepted_at': '2026-10-01T10:00:00Z',
};

/// Supabase that never answers (a network that swallows requests, or one that
/// answers after [delay]), never failing fast. Every call is counted.
class _StallingRemote implements SupabaseRemoteDataSource {
  Duration? delay;
  int calls = 0;

  Future<T> _answer<T>(T value) {
    calls++;
    if (delay == null) return Completer<T>().future;
    return Future.delayed(delay!, () => value);
  }

  @override
  Session? get currentSession => null;

  @override
  String? get currentUserEmail => null;

  @override
  Stream<AuthState> get authStateChanges => const Stream.empty();

  @override
  Future<List<Map<String, dynamic>>> getActiveQuests() => _answer([_questRow('server')]);

  @override
  Future<List<Map<String, dynamic>>> getUserQuests(String userId) => _answer([]);

  @override
  Future<List<Map<String, dynamic>>> getQuestSteps(String questId) => _answer([
    {'id': 9, 'quest_id': questId, 'step_order': 0, 'title': 'Del servidor'},
  ]);

  @override
  Future<List<Map<String, dynamic>>> getQuestPhotoProofs(String attemptId) => _answer([]);

  @override
  Future<List<Map<String, dynamic>>> recommendQuests({
    required int availableMinutes,
    required String socialLevel,
    List<String> interests = const [],
    String locationMode = 'all',
    List<String> excludedQuestIds = const [],
    int limit = 3,
  }) => _answer([
    {'quest_id': 'server', 'score': 1.5},
  ]);

  @override
  Future<Map<String, dynamic>> upsertUserQuest(Map<String, dynamic> userQuest) =>
      _answer({'accepted_at': '2026-10-01T10:00:00Z', 'status': 'accepted', ...userQuest});

  @override
  Future<Map<String, dynamic>> rateUserQuest({
    required String id,
    required String userId,
    required String questId,
    required int rating,
    required List<String> feedbackTags,
  }) => _answer({..._attemptRow(id, questId, 'completed'), 'rating': rating});

  @override
  Future<void> insertUserQuestIfAbsent(Map<String, dynamic> userQuest) => _answer(null);

  @override
  Future<Map<String, dynamic>> getProfile(String userId) =>
      _answer({'id': userId, 'display_name': 'Del servidor'});

  @override
  Future<Map<String, dynamic>> getPreferences(String userId) => _answer({'user_id': userId});

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// The Hive box and SharedPreferences, in memory.
class _FakeLocal implements LocalDataSource {
  List<Map<String, dynamic>> catalog = [];
  List<Map<String, dynamic>> attempts = [];
  List<Map<String, dynamic>> writes = [];
  ({String batchId, List<Map<String, dynamic>> rows})? saved;
  Map<String, dynamic>? profile;
  Map<String, dynamic>? preferences;
  bool biometric = false;
  final Map<String, List<Map<String, dynamic>>> steps = {};

  @override
  List<Map<String, dynamic>> getQuestCatalog() => catalog;

  @override
  Future<void> cacheQuestCatalog(List<Map<String, dynamic>> quests) async => catalog = quests;

  @override
  List<Map<String, dynamic>> getUserQuests() => [...attempts];

  @override
  Future<void> cacheUserQuests(List<Map<String, dynamic>> rows) async => attempts = rows;

  @override
  List<Map<String, dynamic>> getPendingWrites() => [...writes];

  @override
  Future<void> savePendingWrites(List<Map<String, dynamic>> pending) async => writes = pending;

  @override
  ({String batchId, List<Map<String, dynamic>> rows})? getSavedRecommendations() => saved;

  @override
  Future<void> saveRecommendations(String batchId, List<Map<String, dynamic>> rows) async =>
      saved = (batchId: batchId, rows: rows);

  @override
  List<Map<String, dynamic>>? getQuestSteps(String questId) => steps[questId];

  @override
  Future<void> cacheQuestSteps(String questId, List<Map<String, dynamic>> rows) async =>
      steps[questId] = rows;

  @override
  Future<void> cacheActiveQuestId(String? questId) async {}

  @override
  Map<String, dynamic>? getProfile() => profile;

  @override
  Future<void> cacheProfile(Map<String, dynamic> json) async => profile = json;

  @override
  Map<String, dynamic>? getPreferences() => preferences;

  @override
  Future<void> cachePreferences(Map<String, dynamic> json) async => preferences = json;

  @override
  Map<String, dynamic>? getVerifiedCheckIn() => null;

  @override
  Map<String, dynamic>? getActiveStepSession() => null;

  @override
  List<Map<String, dynamic>> getPendingPhotoProofs() => const [];

  @override
  List<Map<String, dynamic>>? getPhotoProofs(String attemptId) => null;

  @override
  Map<String, dynamic>? getExploreFilters() => null;

  @override
  Future<void> saveExploreFilters(Map<String, dynamic> filters) async {}

  @override
  bool isBiometricEnabled() => biometric;

  @override
  Future<void> setBiometricEnabled(bool value) async => biometric = value;

  @override
  bool isDarkMode() => false;

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

/// A GPS still looking for a fix.
class _StalledLocation extends LocationService {
  @override
  Future<Position?> getCurrentPosition({
    LocationAccuracy accuracy = LocationAccuracy.medium,
  }) => Completer<Position?>().future;
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
  Future<List<ConnectivityResult>> checkConnectivity() async => [ConnectivityResult.wifi];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Biometrics implements BiometricService {
  @override
  Future<bool> authenticate(String reason) async => true;

  @override
  Future<bool> isAvailable() async => true;
}

ContextManager _contextManager({LocationService? location}) => ContextManager(
  locationService: location ?? _NoLocation(),
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

QuestViewModel _viewModel(
  QuestRepository repository,
  AnalyticsTracker tracker, {
  ContextManager? contextManager,
  DateTime Function()? now,
}) => QuestViewModel(
  repository,
  contextManager ?? _contextManager(),
  tracker,
  _userId,
  now: now,
  stepCounter: StepCounterService(requestAccess: () async => StepCounterStatus.unavailable),
  locationCheckIn: LocationCheckInService(
    requestAccess: () async => LocationAccess.granted,
    isLowBattery: () async => false,
    isOffline: () async => false,
    offlineChanges: () => const Stream.empty(),
    positions: (_, _) => const Stream.empty(),
  ),
);

/// Fails if [future] hasn't finished once the clock passes the limit.
Future<T> _withinLimit<T>(WidgetTester tester, Future<T> future) async {
  var finished = false;
  unawaited(future.whenComplete(() => finished = true).then((_) {}, onError: (Object _) {}));
  await tester.pump(_limit);
  await tester.pump();
  expect(finished, isTrue, reason: 'still waiting after $_limit');
  return future;
}

void main() {
  group('hallazgo 1: nada espera más de ~5 s', () {
    late _StallingRemote remote;
    late _FakeLocal local;
    late QuestRepository repository;
    late _SpyTracker tracker;

    setUp(() {
      remote = _StallingRemote();
      local = _FakeLocal()
        ..catalog = [_questRow('a'), _questRow('b')]
        ..steps['a'] = [
          {'id': 1, 'quest_id': 'a', 'step_order': 0, 'title': 'Paso guardado'},
        ]
        ..saved = (
          batchId: 'saved-batch',
          rows: [
            {'quest_id': 'a', 'score': 1.5},
          ],
        );
      repository = QuestRepository(remote, local);
      tracker = _SpyTracker();
    });

    group('con una red que no responde', () {
      testWidgets('catálogo: la caché', (tester) async {
        final catalog = await _withinLimit(tester, repository.getCatalog());

        expect(catalog.map((q) => q.id), ['a', 'b']);
        expect(repository.catalogFromCache, isTrue);
      });

      testWidgets('misiones: la caché, compartiendo el límite con la sincronización', (tester) async {
        local.attempts = [_attemptRow('uq', 'a', 'accepted')];
        local.writes = [
          PendingWrite(
            type: PendingWrite.acceptQuest,
            payload: _attemptRow('uq', 'a', 'accepted'),
            createdAt: DateTime.utc(2026),
          ).toJson(),
        ];

        final result = await _withinLimit(tester, repository.getUserQuestsWithSource(_userId));

        expect(result.fromCache, isTrue);
        expect(result.userQuests.single.id, 'uq');
        expect(local.writes, hasLength(1), reason: 'sin respuesta no sale de la cola');
      });

      testWidgets('pasos: la caché', (tester) async {
        final steps = await _withinLimit(tester, repository.getSteps('a'));

        expect(steps.single.title, 'Paso guardado');
      });

      testWidgets('recomendaciones: la lista guardada', (tester) async {
        final batch = await _withinLimit(
          tester,
          repository.getRecommendations(
            context: _contextManager().localSnapshot(),
            preferences: const UserPreferences(),
          ),
        );

        expect(batch.fromCache, isTrue);
        expect(batch.batchId, 'saved-batch');
      });

      testWidgets('perfil y preferencias juntos: un solo límite, no uno por lectura', (tester) async {
        local.profile = {'id': _userId, 'display_name': 'Guardado'};
        final viewModel = ProfileViewModel(
          ProfileRepository(remote, local),
          _NoAuth(),
          _userId,
        );

        await _withinLimit(tester, viewModel.load());

        expect(viewModel.profile!.displayName, 'Guardado');
        expect(viewModel.isLoading, isFalse);
      });

      testWidgets('calificar: en la cola y sin spinner', (tester) async {
        local.attempts = [_attemptRow('uq', 'a', 'completed')];
        final viewModel = _viewModel(repository, tracker);

        final saved = await _withinLimit(
          tester,
          viewModel.submitRating(
            UserQuest(id: 'uq', userId: _userId, questId: 'a', acceptedAt: DateTime(2026)),
            rating: 4,
            tags: const [],
          ),
        );

        expect(saved, isTrue);
        expect(viewModel.ratingQueued, isTrue);
        expect(viewModel.isSubmittingRating, isFalse);
        expect(local.attempts.single['rating'], 4);
      });

      testWidgets('"Empezar ya": aceptar y cargar pasos dentro de un solo límite', (tester) async {
        final viewModel = _viewModel(repository, tracker)..catalog = [_quest('a')];

        final started = await _withinLimit(tester, viewModel.startInstantPlan(_quest('a')));

        expect(started, isTrue);
        expect(viewModel.instantPlanQueued, isTrue);
        expect(viewModel.steps.single.title, 'Paso guardado');
        expect(viewModel.currentMission!.questId, 'a');
      });

      testWidgets('escritura de misión sin cola: error de conexión, no spinner', (tester) async {
        final attempt = UserQuest(id: 'uq', userId: _userId, questId: 'a', acceptedAt: DateTime(2026));

        final viewModel = _viewModel(repository, tracker);
        final ok = await _withinLimit(tester, viewModel.abandonQuest(attempt, reason: 'x'));

        expect(ok, isFalse);
        expect(viewModel.errorMessage, startsWith('Sin conexión'));
      });

      testWidgets('Explore: catálogo y lista guardada, sin spinner, aunque el GPS tampoco responda', (
        tester,
      ) async {
        final viewModel = _viewModel(
          repository,
          tracker,
          contextManager: _contextManager(location: _StalledLocation()),
        );
        await tester.pumpWidget(
          MultiProvider(
            providers: [
              ChangeNotifierProvider<QuestViewModel>.value(value: viewModel),
              ChangeNotifierProvider(
                create: (_) => ProfileViewModel(ProfileRepository(remote, local), _NoAuth(), _userId),
              ),
            ],
            child: const MaterialApp(home: ExploreView()),
          ),
        );

        await tester.pump();
        await tester.pump(_limit);
        await tester.pump();

        expect(viewModel.isLoading, isFalse);
        expect(viewModel.filteredCatalog.map((q) => q.id), ['a', 'b']);
        expect(find.text('Quest a'), findsOneWidget);
        expect(find.text('Recomendaciones guardadas'), findsOneWidget);
        expect(find.byType(CircularProgressIndicator), findsNothing);
        expect(tracker.of(AnalyticsEventType.recommendationShown), isEmpty);

        await tester.pump(_limit * 3); // the slower requests run out
      });

      testWidgets('el switch de huella aparece y funciona', (tester) async {
        final authRepository = AuthRepository(remote, local);
        final auth = AuthViewModel(authRepository, _Biometrics(), tracker);
        final quests = _viewModel(repository, tracker);
        await tester.pumpWidget(
          MultiProvider(
            providers: [
              Provider<LocalDataSource>.value(value: local),
              ChangeNotifierProvider.value(value: auth),
              ChangeNotifierProvider<QuestViewModel>.value(value: quests),
              ChangeNotifierProvider(create: (_) => ThemeViewModel(local)),
              ChangeNotifierProvider(
                create: (_) => ProfileViewModel(
                  ProfileRepository(remote, local),
                  authRepository,
                  _userId,
                ),
              ),
            ],
            child: const MaterialApp(home: ProfileView()),
          ),
        );

        await tester.pump();
        await tester.pump(_limit);
        await tester.pump();

        await tester.scrollUntilVisible(
          find.text('Desbloquear con huella'),
          300,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.tap(find.widgetWithText(SwitchListTile, 'Desbloquear con huella'));
        await tester.pump();
        await tester.pump();

        expect(local.biometric, isTrue);
        await tester.pump(_limit * 3);
      });
    });

    group('sin red: ni siquiera llama a Supabase', () {
      setUp(() {
        repository = QuestRepository(
          remote,
          local,
          network: NetworkGuard(isOffline: () async => true),
        );
      });

      test('lecturas: caché al instante y cero llamadas', () async {
        await repository.getCatalog();
        await repository.getUserQuests(_userId);
        await repository.getSteps('a');
        final batch = await repository.getRecommendations(
          context: _contextManager().localSnapshot(),
          preferences: const UserPreferences(),
        );

        expect(batch.fromCache, isTrue);
        expect(repository.catalogFromCache, isTrue);
        expect(remote.calls, 0);
      });

      test('perfil y preferencias: cero llamadas', () async {
        local.profile = {'id': _userId, 'display_name': 'Guardado'};
        final profiles = ProfileRepository(
          remote,
          local,
          network: NetworkGuard(isOffline: () async => true),
        );

        expect((await profiles.getProfile(_userId)).displayName, 'Guardado');
        await profiles.getPreferences(_userId);

        expect(remote.calls, 0);
      });

      test('"Empezar ya" y calificar: a la cola, con cero llamadas', () async {
        local.attempts = [_attemptRow('uq', 'b', 'completed')];
        final viewModel = _viewModel(repository, tracker)..catalog = [_quest('a')];

        expect(await viewModel.startInstantPlan(_quest('a')), isTrue);
        expect(
          await viewModel.submitRating(
            UserQuest(id: 'uq', userId: _userId, questId: 'b', acceptedAt: DateTime(2026)),
            rating: 5,
            tags: const [],
          ),
          isTrue,
        );

        expect(local.writes, hasLength(2));
        expect(remote.calls, 0);
      });

      test('sincronizar: no intenta nada y la cola se queda', () async {
        local.writes = [
          PendingWrite(
            type: PendingWrite.acceptQuest,
            payload: _attemptRow('uq', 'a', 'accepted'),
            createdAt: DateTime.utc(2026),
          ).toJson(),
        ];

        await repository.syncPendingWrites();

        expect(remote.calls, 0);
        expect(local.writes, hasLength(1));
      });

      test('una foto pendiente no intenta subir: se queda para reintentar', () async {
        final pending = PendingPhotoProof(
          localPath: 'x.jpg',
          storagePath: 'user/uq/a/0/x.jpg',
          attemptId: 'uq',
          questId: 'a',
          stepOrder: 0,
          sizeBytes: 3,
          capturedAt: DateTime(2026),
        );
        final photos = _PhotoLocal()..pending = [pending.toJson()];

        await expectLater(
          QuestRepository(
            remote,
            photos,
            network: NetworkGuard(isOffline: () async => true),
          ).uploadPendingPhotoProof(pending),
          throwsA(anything),
        );

        expect(remote.calls, 0);
        expect(photos.pending, hasLength(1));
      });
    });

    group('con red el comportamiento no cambia', () {
      setUp(() => remote.delay = const Duration(seconds: 4));

      testWidgets('una respuesta lenta pero a tiempo gana a la caché', (tester) async {
        final catalog = repository.getCatalog();
        final steps = repository.getSteps('a');

        await tester.pump(const Duration(seconds: 4));
        await tester.pump();

        expect((await catalog).single.id, 'server');
        expect(repository.catalogFromCache, isFalse);
        expect((await steps).single.title, 'Del servidor');
      });

      testWidgets('calificar a tiempo no pasa por la cola', (tester) async {
        local.attempts = [_attemptRow('uq', 'a', 'completed')];

        final result = repository.rateQuestOrQueue(
          UserQuest(id: 'uq', userId: _userId, questId: 'a', acceptedAt: DateTime(2026)),
          4,
          const [],
        );
        await tester.pump(const Duration(seconds: 4));
        await tester.pump();

        expect((await result).queued, isFalse);
        expect(local.writes, isEmpty);
      });

      testWidgets('con la lista guardada y red, Explore no la muestra', (tester) async {
        final viewModel = _viewModel(repository, tracker);
        final loading = viewModel.load();
        await tester.pump(const Duration(seconds: 4));
        await tester.pump();
        await loading;

        viewModel.showSavedRecommendationsIfOffline();

        expect(viewModel.recommendations, isEmpty);
      });
    });

    test('una comprobación de conectividad que falla cuenta como con red', () async {
      final guard = NetworkGuard(isOffline: () async => throw PlatformException(code: 'x'));

      expect(await guard.isOffline, isFalse);
      expect(await guard.run(() async => 1), 1);
    });
  });

  group('hallazgo 2: los pasos de la misión activa', () {
    late _StepsRepository repository;
    late QuestViewModel viewModel;
    final mission = UserQuest(
      id: 'uq-a',
      userId: _userId,
      questId: 'A',
      status: 'in_progress',
      acceptedAt: DateTime(2026),
    );

    setUp(() {
      repository = _StepsRepository();
      viewModel = _viewModel(repository, _SpyTracker())
        ..catalog = [_quest('A'), _quest('B')]
        ..userQuests = [mission];
    });

    test('misión activa -> abrir otra -> completar el último paso completa la correcta', () async {
      await viewModel.loadSteps('A');
      await viewModel.loadSteps('B');

      final completed = await viewModel.completeCurrentStep(mission);

      expect(completed, isTrue);
      expect(repository.writes, ['completeQuest:A']);
    });

    test('el detalle ve los pasos de su misión, y la misión los suyos', () async {
      await viewModel.loadSteps('A');
      await viewModel.loadSteps('B');

      expect(viewModel.steps.map((s) => s.title), ['A-0']);
      expect(viewModel.stepsOf('A').map((s) => s.title), ['A-0']);
      expect(viewModel.stepsOf('B').map((s) => s.title), ['B-0', 'B-1', 'B-2']);
    });

    test('sin misión activa el detalle sigue cargando como antes', () async {
      viewModel.userQuests = [];

      await viewModel.loadSteps('B');

      expect(viewModel.steps, hasLength(3));
      expect(viewModel.stepsOf('B'), hasLength(3));
    });

    test('al aceptar otra misión, sus pasos pasan a ser los de la misión', () async {
      await viewModel.loadSteps('A');
      await viewModel.loadSteps('B');

      viewModel.userQuests = [
        UserQuest(id: 'uq-b', userId: _userId, questId: 'B', acceptedAt: DateTime(2026)),
        mission,
      ];
      await viewModel.loadSteps('B');

      expect(viewModel.steps, hasLength(3));
    });

    testWidgets('la pestaña Misión sigue mostrando los pasos de A tras abrir B', (tester) async {
      await tester.pumpWidget(
        ChangeNotifierProvider<QuestViewModel>.value(
          value: viewModel,
          child: const MaterialApp(home: MissionTabView()),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(find.text('A-0'), findsOneWidget);

      await viewModel.loadSteps('B');
      await tester.pump();

      expect(find.text('A-0'), findsOneWidget);
      expect(find.text('B-0'), findsNothing);
      expect(find.text('Completar misión →'), findsOneWidget);
    });
  });

  group('hallazgo 4: recommendation_accepted una vez por inicio', () {
    late _StallingRemote remote;
    late _FakeLocal local;
    late _SpyTracker tracker;
    late QuestViewModel viewModel;

    setUp(() {
      remote = _StallingRemote();
      local = _FakeLocal()..steps['a'] = [];
      tracker = _SpyTracker();
      viewModel = _viewModel(
        QuestRepository(remote, local, network: NetworkGuard(isOffline: () async => true)),
        tracker,
      )..catalog = [_quest('a')];
    });

    test('sin red, tocar dos veces: 1 en la cola, 1 evento, y la misión abre', () async {
      expect(await viewModel.startInstantPlan(_quest('a')), isTrue);
      expect(await viewModel.startInstantPlan(_quest('a')), isTrue);

      expect(local.writes, hasLength(1));
      expect(local.attempts, hasLength(1));
      expect(tracker.of(AnalyticsEventType.recommendationAccepted), hasLength(1));
      expect(viewModel.currentMission!.questId, 'a');
    });

    test('una misión ya en caché: sin evento y sin escribir, también con red', () async {
      local.attempts = [_attemptRow('uq', 'a', 'in_progress')];
      remote.delay = Duration.zero;
      final online = _viewModel(QuestRepository(remote, local), tracker)..catalog = [_quest('a')];

      expect(await online.startInstantPlan(_quest('a')), isTrue);

      expect(tracker.of(AnalyticsEventType.recommendationAccepted), isEmpty);
      expect(online.instantPlanQueued, isFalse);
      expect(online.currentMission!.id, 'uq');
    });

    test('una abandonada o completada sí es un inicio nuevo', () async {
      local.attempts = [_attemptRow('uq', 'a', 'completed')];

      await viewModel.startInstantPlan(_quest('a'));

      expect(tracker.of(AnalyticsEventType.recommendationAccepted), hasLength(1));
      expect(local.writes, hasLength(1));
    });
  });

  group('hallazgo 5: BQ4 en el segundo inicio', () {
    late DateTime clock;
    late _SpyTracker tracker;
    late QuestViewModel viewModel;

    Map<String, dynamic> lastStart() => tracker.calls.last.metadata;

    setUp(() {
      clock = DateTime(2026, 10, 30, 12);
      tracker = _SpyTracker();
      viewModel = _viewModel(_ListRepository(), tracker, now: () => clock)
        ..catalog = [_quest('a'), _quest('b')];
    });

    test('tiene su propio reloj, desde que vuelve a Explorar, y el batch de la lista visible', () async {
      await viewModel.loadRecommendations(const UserPreferences());
      clock = clock.add(const Duration(seconds: 30));
      await viewModel.startInstantPlan(_quest('a'));
      expect(lastStart()['seconds_to_start'], 30);
      final batchId = lastStart()['batch_id'];

      clock = clock.add(const Duration(minutes: 20)); // on the mission
      viewModel.onExploreVisible();
      clock = clock.add(const Duration(seconds: 7));
      await viewModel.startInstantPlan(_quest('b'));

      expect(lastStart()['seconds_to_start'], 7);
      expect(lastStart()['batch_id'], batchId);
      expect(lastStart()['interactions_to_start'], 0);
    });

    test('volver varias veces no reinicia el reloj', () async {
      await viewModel.loadRecommendations(const UserPreferences());
      await viewModel.startInstantPlan(_quest('a'));

      viewModel.onExploreVisible();
      clock = clock.add(const Duration(seconds: 7));
      viewModel.onExploreVisible(); // back from a quest's detail
      clock = clock.add(const Duration(seconds: 3));
      await viewModel.startInstantPlan(_quest('b'));

      expect(lastStart()['seconds_to_start'], 10);
    });

    test('nunca seconds_to_start=0 con batch_id=null si hay lista, aunque no pase por Explorar', () async {
      await viewModel.loadRecommendations(const UserPreferences());
      await viewModel.startInstantPlan(_quest('a'));

      clock = clock.add(const Duration(seconds: 12));
      await viewModel.acceptQuest('b'); // started from Cerca, say

      expect(lastStart()['seconds_to_start'], 12);
      expect(lastStart()['batch_id'], isNotNull);
    });

    test('sin ninguna lista: batch null, con un tiempo real', () async {
      clock = clock.add(const Duration(seconds: 9));

      await viewModel.acceptQuest('a');

      expect(lastStart()['seconds_to_start'], 9);
      expect(lastStart()['batch_id'], isNull);
    });
  });

  group('hallazgo 6: cierre de sesión forzado', () {
    group('razones', () {
      late _CountingAuthRepository repository;
      late bool offline;
      late AuthViewModel viewModel;

      setUp(() {
        repository = _CountingAuthRepository();
        offline = false;
        viewModel = AuthViewModel(
          repository,
          _Biometrics(),
          _SpyTracker(),
          isOffline: () async => offline,
        );
      });

      Future<void> emit(SignOutReason? reason, {AuthChangeEvent event = AuthChangeEvent.signedOut}) async {
        repository.changes.add(AuthState(event, null, signOutReason: reason));
        await pumpEventQueue();
      }

      test('token rechazado o sesión ilegible: limpia', () async {
        await emit(SignOutReason.sessionExpired);
        expect(repository.clears, 1);

        await emit(SignOutReason.sessionMissing);
        expect(repository.clears, 2);
        expect(viewModel.biometricEnabled, isFalse);
      });

      test('el usuario salió: signOut ya limpia, no se limpia dos veces', () async {
        await emit(SignOutReason.userInitiated);

        expect(repository.clears, 0);
      });

      test('sin razón (relevado desde otra pestaña, web): no limpia', () async {
        await emit(null);

        expect(repository.clears, 0);
      });

      test('otros eventos: no limpia', () async {
        await emit(null, event: AuthChangeEvent.tokenRefreshed);

        expect(repository.clears, 0);
      });

      test('sin red: no limpia', () async {
        offline = true;

        await emit(SignOutReason.sessionExpired);

        expect(repository.clears, 0);
      });

      test('si falla la limpieza, no rompe nada', () async {
        repository.clearError = const FileSystemException('disk');

        await emit(SignOutReason.sessionExpired);

        expect(viewModel.status, AuthStatus.unauthenticated);
      });
    });

    group('con el cliente de Supabase y Hive reales', () {
      late Directory documents;
      late LocalDataSource hive;
      const pathProvider = MethodChannel('plugins.flutter.io/path_provider');

      setUp(() async {
        TestWidgetsFlutterBinding.ensureInitialized();
        documents = await Directory.systemTemp.createTemp('forced_sign_out_test');
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
          pathProvider,
          (_) async => documents.path,
        );
        SharedPreferences.setMockInitialValues({'biometric_enabled': true});
        hive = LocalDataSource();
        await hive.init();
        await hive.savePendingAnalyticsEvents([
          {'event_type': 'quest_rated'},
        ]);
        await hive.savePendingWrites([
          {'type': PendingWrite.rateQuest, 'payload': <String, dynamic>{}, 'created_at': '2026-01-01T00:00:00Z'},
        ]);
        await hive.saveRecommendations('batch', [
          {'quest_id': 'a', 'score': 1},
        ]);
      });

      tearDown(() async {
        await Hive.close();
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
          pathProvider,
          null,
        );
        await documents.delete(recursive: true);
      });

      Future<AuthViewModel> expireSessionWith(
        http.Client httpClient, {
        bool offline = false,
      }) async {
        final client = SupabaseClient('https://example.supabase.co', 'key', httpClient: httpClient);
        addTearDown(client.dispose);
        final expired = jsonEncode(_session(const Duration(hours: -1)).toJson());
        await client.auth.setInitialSession(expired);
        final viewModel = AuthViewModel(
          AuthRepository(SupabaseRemoteDataSource(client), hive),
          _Biometrics(),
          _SpyTracker(),
          isOffline: () async => offline,
        );
        try {
          await client.auth.recoverSession(expired);
        } catch (_) {
          // What's being tested is how the view model reacts.
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
        return viewModel;
      }

      http.Client serverRejectsTheToken() => MockClient(
        (_) async => http.Response(
          jsonEncode({'error_code': 'refresh_token_not_found', 'msg': 'Invalid Refresh Token'}),
          400,
        ),
      );

      void expectKept() {
        expect(hive.getPendingAnalyticsEvents(), hasLength(1));
        expect(hive.getPendingWrites(), hasLength(1));
        expect(hive.isBiometricEnabled(), isTrue);
      }

      test('el servidor rechaza el token: borra analítica, cola, lista y huella', () async {
        final viewModel = await expireSessionWith(serverRejectsTheToken());

        expect(viewModel.status, AuthStatus.unauthenticated);
        expect(hive.getPendingAnalyticsEvents(), isEmpty);
        expect(hive.getPendingWrites(), isEmpty);
        expect(hive.getSavedRecommendations(), isNull);
        expect(hive.isBiometricEnabled(), isFalse);
      });

      test('sin red el refresh falla pero no hay cierre: conserva todo y sigue dentro', () async {
        final viewModel = await expireSessionWith(
          MockClient((_) async => throw const SocketException('offline')),
        );

        expect(viewModel.status, AuthStatus.authenticated);
        expectKept();
      }, timeout: const Timeout(Duration(minutes: 1)));

      test('un rechazo con el teléfono sin red tampoco borra', () async {
        await expireSessionWith(serverRejectsTheToken(), offline: true);

        expectKept();
      });
    });
  });

  group('hallazgo 8: QuestCompletedView', () {
    testWidgets('no abre con el error de la calificación anterior', (tester) async {
      final viewModel = _viewModel(QuestRepository(_StallingRemote(), _FakeLocal()), _SpyTracker())
        ..ratingErrorMessage = 'permission denied';

      await tester.pumpWidget(
        ChangeNotifierProvider<QuestViewModel>.value(
          value: viewModel,
          child: MaterialApp(
            home: QuestCompletedView(
              mission: UserQuest(id: 'uq', userId: _userId, questId: 'a', acceptedAt: DateTime(2026)),
              quest: _quest('a'),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('permission denied'), findsNothing);
      expect(find.text('Guardar'), findsOneWidget);
      expect(find.text('Reintentar'), findsNothing);
      expect(viewModel.ratingErrorMessage, isNull);
    });
  });
}

Session _session(Duration expiresIn) {
  String encode(Map<String, dynamic> json) =>
      base64Url.encode(utf8.encode(jsonEncode(json))).replaceAll('=', '');
  final expiry = DateTime.now().add(expiresIn).millisecondsSinceEpoch ~/ 1000;
  return Session(
    accessToken: '${encode({'alg': 'HS256'})}.${encode({'exp': expiry, 'sub': _userId})}.signature',
    refreshToken: 'refresh-token',
    tokenType: 'bearer',
    user: const User(
      id: _userId,
      appMetadata: {},
      userMetadata: {},
      aud: 'authenticated',
      createdAt: '2026-01-01T00:00:00Z',
    ),
  );
}

class _NoAuth implements AuthRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _CountingAuthRepository implements AuthRepository {
  final StreamController<AuthState> changes = StreamController<AuthState>.broadcast();
  Object? clearError;
  int clears = 0;

  @override
  bool get isAuthenticated => false;

  @override
  bool get isBiometricEnabled => true;

  @override
  Stream<AuthState> get authStateChanges => changes.stream;

  @override
  Future<void> clearLocalData() async {
    if (clearError != null) throw clearError!;
    clears++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _PhotoLocal extends _FakeLocal {
  List<Map<String, dynamic>> pending = [];

  @override
  Future<Uint8List?> readPendingProofFile(String path) async => Uint8List.fromList([1, 2, 3]);

  @override
  List<Map<String, dynamic>> getPendingPhotoProofs() => [...pending];

  @override
  Future<void> savePendingPhotoProofs(List<Map<String, dynamic>> proofs) async => pending = proofs;
}

/// A has one step, anything else three.
class _StepsRepository implements QuestRepository {
  final List<String> writes = [];

  @override
  Future<List<QuestStep>> getSteps(String questId) async => [
    for (var i = 0; i < (questId == 'A' ? 1 : 3); i++)
      QuestStep(id: i, questId: questId, stepOrder: i, title: '$questId-$i', verificationType: 'none'),
  ];

  @override
  Future<UserQuest> updateProgress(UserQuest userQuest) async {
    writes.add('updateProgress:${userQuest.questId}');
    return userQuest;
  }

  @override
  Future<UserQuest> completeQuest(UserQuest userQuest) async {
    writes.add('completeQuest:${userQuest.questId}');
    return userQuest.copyWithProgress(status: 'completed');
  }

  @override
  StepSession? getActiveStepSession() => null;

  @override
  List<PendingPhotoProof> getPendingPhotoProofs() => const [];

  @override
  Future<List<QuestPhotoProof>> getPhotoProofs(String attemptId) async => const [];

  @override
  Future<void> saveActiveStepSession(StepSession? session) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// One list, one batch per load; every start is accepted.
class _ListRepository implements QuestRepository {
  int _batches = 0;

  @override
  Future<RecommendationBatch> getRecommendations({
    required context,
    required UserPreferences preferences,
    List<String> excludedQuestIds = const [],
    int limit = 3,
  }) async => RecommendationBatch(
    recommendations: const [
      QuestRecommendation(
        questId: 'a',
        score: 1,
        timeMatch: true,
        interestMatch: true,
        socialMatch: true,
        locationMatch: true,
      ),
    ],
    batchId: 'batch-${++_batches}',
  );

  @override
  Future<({UserQuest userQuest, bool queued, bool alreadyStarted})> acceptQuestOrQueue({
    required String userId,
    required String questId,
  }) async => (
    userQuest: await acceptQuest(userId: userId, questId: questId),
    queued: false,
    alreadyStarted: false,
  );

  @override
  Future<UserQuest> acceptQuest({required String userId, required String questId}) async =>
      UserQuest(id: 'uq-$questId', userId: userId, questId: questId, acceptedAt: DateTime(2026));

  @override
  Future<List<QuestStep>> getSteps(String questId) async => const [];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
