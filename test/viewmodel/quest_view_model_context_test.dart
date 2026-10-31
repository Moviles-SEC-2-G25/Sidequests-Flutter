import 'dart:convert';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:sidequests/analytics/analytics_event_sink.dart';
import 'package:sidequests/analytics/analytics_event_type.dart';
import 'package:sidequests/analytics/analytics_tracker.dart';
import 'package:sidequests/core/app_exception.dart';
import 'package:sidequests/data/context/context_manager.dart';
import 'package:sidequests/data/local/local_data_source.dart';
import 'package:sidequests/data/services/battery_monitor.dart';
import 'package:sidequests/data/services/location_service.dart';
import 'package:sidequests/data/services/weather_service.dart';
import 'package:sidequests/models/app_context.dart';
import 'package:sidequests/models/explore_filters.dart';
import 'package:sidequests/models/photo_proof.dart';
import 'package:sidequests/models/quest.dart';
import 'package:sidequests/models/quest_recommendation.dart';
import 'package:sidequests/models/step_session.dart';
import 'package:sidequests/models/user_preferences.dart';
import 'package:sidequests/models/user_quest.dart';
import 'package:sidequests/models/verified_check_in.dart';
import 'package:sidequests/repository/auth_repository.dart';
import 'package:sidequests/repository/profile_repository.dart';
import 'package:sidequests/repository/quest_repository.dart';
import 'package:sidequests/view/quests/explore_view.dart';
import 'package:sidequests/viewmodel/profile/profile_view_model.dart';
import 'package:sidequests/viewmodel/quests/quest_view_model.dart';

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

ContextManager _contextManager() =>
    ContextManager(locationService: _NoLocation(), batteryMonitor: _FullBattery());

/// Never actually read: `currentContext` is set directly in every test.
class _UnusedQuestRepository implements QuestRepository {
  @override
  Future<void> saveExploreFilters(ExploreFilters filters) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Quest _quest(String id, {required String locationMode, int durationMinutes = 20}) => Quest(
  id: id,
  title: 'Quest $id',
  category: 'food',
  durationMinutes: durationMinutes,
  difficulty: 'easy',
  locationMode: locationMode,
  socialLevel: 'solo',
);

AppContext _appContext({bool isRainy = false, String timeOfDay = 'afternoon'}) =>
    AppContext(timeOfDay: timeOfDay, dayOfWeek: 'monday', isConnected: true, isRainy: isRainy);

const _interleaved = ['gps-1', 'anywhere-1', 'gps-2', 'anywhere-2'];
const _anywhereFirst = ['anywhere-1', 'anywhere-2', 'gps-1', 'gps-2'];
const _rainCode = 61;
const _clearCode = 0;

class _AtOnePlace extends LocationService {
  bool hasFix = true;
  double latitude = 4.6;

  @override
  Future<Position?> getCurrentPosition({
    LocationAccuracy accuracy = LocationAccuracy.medium,
  }) async => !hasFix
      ? null
      : Position(
          latitude: latitude,
          longitude: -74.07,
          timestamp: DateTime(2026),
          accuracy: 10,
          altitude: 0,
          altitudeAccuracy: 0,
          heading: 0,
          headingAccuracy: 0,
          speed: 0,
          speedAccuracy: 0,
        );
}

/// The real plugin's channel never answers under testWidgets' fake clock.
class _NoConnection implements Connectivity {
  @override
  Future<List<ConnectivityResult>> checkConnectivity() async => [ConnectivityResult.none];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// The Hive box, in memory: readings come back through their JSON.
class _WeatherBox implements LocalDataSource {
  final Map<String, Map<String, dynamic>> readings = {};

  @override
  Map<String, dynamic>? getWeatherSnapshot(String coordinatesKey) => readings[coordinatesKey];

  @override
  Future<void> cacheWeatherSnapshot(String coordinatesKey, Map<String, dynamic> snapshot) async =>
      readings[coordinatesKey] = jsonDecode(jsonEncode(snapshot)) as Map<String, dynamic>;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Recommendations and catalog on demand; the rest of load() finds nothing.
class _FakeQuestRepository implements QuestRepository {
  final List<Quest> quests;
  RecommendationBatch? batch;
  AppException? recommendationsError;
  int recommendationCalls = 0;

  _FakeQuestRepository(this.quests);

  @override
  bool get catalogFromCache => false;

  @override
  Future<RecommendationBatch> getRecommendations({
    required AppContext context,
    required UserPreferences preferences,
    List<String> excludedQuestIds = const [],
    int limit = 3,
  }) async {
    recommendationCalls++;
    if (recommendationsError != null) throw recommendationsError!;
    return batch ?? const RecommendationBatch(recommendations: [], batchId: 'empty');
  }

  @override
  Future<List<Quest>> getCatalog() async => quests;

  @override
  Future<List<UserQuest>> getUserQuests(String userId) async => const [];

  @override
  StepSession? getActiveStepSession() => null;

  @override
  bool get userQuestsFromCache => false;

  @override
  VerifiedCheckIn? getVerifiedCheckIn() => null;

  @override
  List<PendingPhotoProof> getPendingPhotoProofs() => const [];

  @override
  Future<void> saveExploreFilters(ExploreFilters filters) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _SpyTracker extends AnalyticsTracker {
  final List<String> events = [];

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
  }) async => events.add(eventType);
}

class _RecordingSink implements AnalyticsEventSink {
  final List<Map<String, dynamic>> events = [];

  @override
  Future<void> insertAnalyticsEvent(Map<String, dynamic> event) async => events.add(event);
}

class _NoProfile implements ProfileRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw const AppException('sin perfil');
}

class _NoAuth implements AuthRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

void main() {
  group('sin red', () {
    late DateTime now;
    late bool online;
    late int weatherCode;
    late _AtOnePlace location;
    late _WeatherBox box;
    late _FakeQuestRepository repository;
    late _SpyTracker tracker;

    List<Quest> catalog() => [
      _quest('gps-1', locationMode: 'gps'),
      _quest('anywhere-1', locationMode: 'anywhere'),
      _quest('gps-2', locationMode: 'gps'),
      _quest('anywhere-2', locationMode: 'anywhere'),
    ];

    /// A new one has an empty memory: what an app restart leaves.
    ContextManager newManager() => ContextManager(
      locationService: location,
      batteryMonitor: _FullBattery(),
      connectivity: _NoConnection(),
      now: () => now,
      weatherService: WeatherService(
        now: () => now,
        localDataSource: box,
        client: MockClient((_) async {
          if (!online) throw http.ClientException('offline');
          return http.Response(
            jsonEncode({
              'current': {'weather_code': weatherCode, 'temperature_2m': 18.4},
            }),
            200,
          );
        }),
      ),
    );

    QuestViewModel newViewModel(ContextManager manager) => QuestViewModel(
      repository,
      manager,
      tracker,
      'user-1',
    )..catalog = catalog();

    /// Online once at 15:00, then the connection goes and the app restarts.
    Future<QuestViewModel> afterRestartOffline(Duration later) async {
      await newManager().snapshot();
      online = false;
      now = now.add(later);
      return newViewModel(newManager());
    }

    setUp(() {
      now = DateTime(2026, 10, 30, 15);
      online = true;
      weatherCode = _rainCode;
      location = _AtOnePlace();
      box = _WeatherBox();
      repository = _FakeQuestRepository(catalog());
      tracker = _SpyTracker();
    });

    group('lluvia de respaldo', () {
      test('reordena, y dice que es de respaldo y qué tan vieja es', () async {
        final viewModel = await afterRestartOffline(const Duration(minutes: 40));

        await viewModel.refreshContext();

        final context = viewModel.currentContext!;
        expect(context.isRainy, isTrue);
        expect(context.weatherIsStale, isTrue);
        expect(context.weatherAge, const Duration(minutes: 40));
        expect(viewModel.isAdaptingToContext, isTrue);
        expect(viewModel.filteredCatalog.map((q) => q.id), _anywhereFirst);
        expect(viewModel.filteredCatalog, hasLength(4));
      });

      test('avisa a la vista al recalcular, para que Explore se actualice', () async {
        final viewModel = await afterRestartOffline(const Duration(minutes: 40));
        var notified = 0;
        viewModel.addListener(() => notified++);

        await viewModel.refreshContext();

        expect(notified, 1);
      });

      test('también desde la memoria, sin reinicio', () async {
        final manager = newManager();
        await manager.snapshot();
        online = false;
        now = now.add(const Duration(minutes: 20));

        final context = await manager.snapshot();

        expect(context.isRainy, isTrue);
        expect(context.weatherIsStale, isTrue);
      });

      test('con red no es de respaldo', () async {
        final context = await newManager().snapshot();

        expect(context.isRainy, isTrue);
        expect(context.weatherIsStale, isFalse);
        expect(context.weatherAge, isNull);
      });

      test('un respaldo sin lluvia no adapta', () async {
        weatherCode = _clearCode;
        final viewModel = await afterRestartOffline(const Duration(minutes: 40));

        await viewModel.refreshContext();

        expect(viewModel.currentContext!.weatherIsStale, isTrue);
        expect(viewModel.isAdaptingToContext, isFalse);
      });

      test('otra zona sin clima guardado: no es lluvia ni respaldo', () async {
        final viewModel = await afterRestartOffline(const Duration(minutes: 40));
        location.latitude = 6.2;

        await viewModel.refreshContext();

        expect(viewModel.currentContext!.isRainy, isFalse);
        expect(viewModel.currentContext!.weatherIsStale, isFalse);
      });
    });

    group('respaldo de 3 h o más', () {
      test('justo antes de las 3 h todavía cuenta', () async {
        final viewModel = await afterRestartOffline(const Duration(hours: 2, minutes: 59));

        await viewModel.refreshContext();

        expect(viewModel.currentContext!.isRainy, isTrue);
      });

      for (final (name, age) in [
        ('a las 3 h exactas', const Duration(hours: 3)),
        ('con más de 3 h', const Duration(hours: 3, minutes: 1)),
      ]) {
        test('$name no cuenta como lluvia ni reordena', () async {
          final viewModel = await afterRestartOffline(age);

          await viewModel.refreshContext();

          final context = viewModel.currentContext!;
          expect(context.isRainy, isFalse);
          expect(context.weatherIsStale, isTrue);
          expect(context.weatherAge, age);
          expect(viewModel.isAdaptingToContext, isFalse);
          expect(viewModel.filteredCatalog.map((q) => q.id), _interleaved);
        });
      }

      test('weather_code se sigue enviando igual, sin campos nuevos en el evento', () async {
        final manager = newManager();
        final sink = _RecordingSink();
        final analytics = AnalyticsTracker(
          eventSink: sink,
          contextManager: manager,
          sessionId: 'session',
        );

        await analytics.track(AnalyticsEventType.shakeSurprise);
        online = false;
        now = now.add(const Duration(hours: 5));
        await analytics.track(AnalyticsEventType.shakeSurprise);
        await pumpEventQueue();

        expect(sink.events, hasLength(2));
        expect(sink.events.first['weather_code'], _rainCode);
        expect(sink.events.last['weather_code'], _rainCode);
        expect(sink.events.last.keys.toSet(), sink.events.first.keys.toSet());
      });
    });

    group('noche, regla local', () {
      for (final (hour, isNight) in [(23, true), (22, true), (5, true), (6, false), (21, false)]) {
        test('a las $hour:00, sin red ni GPS: ${isNight ? 'reordena' : 'no reordena'}', () async {
          online = false;
          location.hasFix = false;
          now = DateTime(2026, 10, 30, hour);
          final viewModel = newViewModel(newManager());

          await viewModel.refreshContext();

          expect(viewModel.currentContext!.weatherCode, isNull);
          expect(viewModel.isAdaptingToContext, isNight);
          expect(viewModel.filteredCatalog.map((q) => q.id), isNight ? _anywhereFirst : _interleaved);
        });
      }

      test('un respaldo de más de 3 h no le quita la noche', () async {
        final manager = newManager();
        await manager.snapshot();
        online = false;
        now = DateTime(2026, 10, 30, 23);
        final viewModel = newViewModel(newManager());

        await viewModel.refreshContext();

        expect(viewModel.currentContext!.isRainy, isFalse);
        expect(viewModel.isAdaptingToContext, isTrue);
        expect(viewModel.filteredCatalog.map((q) => q.id), _anywhereFirst);
      });
    });

    test('Explore lo recalcula sin red aunque las recomendaciones fallen', () async {
      final viewModel = await afterRestartOffline(const Duration(minutes: 40));
      repository.recommendationsError = const AppException('Sin conexión', isRetryable: true);
      await viewModel.load();

      await viewModel.loadRecommendations(const UserPreferences());

      expect(viewModel.isAdaptingToContext, isTrue);
      expect(viewModel.filteredCatalog.map((q) => q.id), _anywhereFirst);
      expect(viewModel.errorMessage, 'Sin conexión');
    });

    group('al reconectar', () {
      const live = RecommendationBatch(
        recommendations: [QuestRecommendation(
          questId: 'anywhere-1',
          score: 1,
          timeMatch: true,
          interestMatch: true,
          socialMatch: true,
          locationMatch: true,
        )],
        batchId: 'live',
      );

      test('una lista viva se queda: clima real, sin recommendation_shown ni otra petición', () async {
        final viewModel = await afterRestartOffline(const Duration(minutes: 40));
        online = true;
        repository.batch = live;
        await viewModel.loadRecommendations(const UserPreferences());
        online = false;
        now = now.add(const Duration(minutes: 20)); // past the memory's TTL
        await viewModel.refreshContext();
        expect(viewModel.currentContext!.weatherIsStale, isTrue);
        final shownBefore = tracker.events.where(_isShown).length;
        final callsBefore = repository.recommendationCalls;

        online = true;
        now = now.add(const Duration(minutes: 20)); // past the memory's TTL
        weatherCode = _clearCode;
        await viewModel.refreshAfterReconnect(const UserPreferences());

        expect(viewModel.currentContext!.weatherIsStale, isFalse);
        expect(viewModel.currentContext!.isRainy, isFalse);
        expect(viewModel.isAdaptingToContext, isFalse);
        expect(viewModel.filteredCatalog.map((q) => q.id), _interleaved);
        expect(tracker.events.where(_isShown).length, shownBefore);
        expect(repository.recommendationCalls, callsBefore);
      });

      test('una lista guardada sí se reemplaza, y esa nueva registra sus impresiones', () async {
        final viewModel = await afterRestartOffline(const Duration(minutes: 40));
        repository.batch = RecommendationBatch(
          recommendations: live.recommendations,
          batchId: 'saved',
          fromCache: true,
        );
        await viewModel.loadRecommendations(const UserPreferences());
        expect(tracker.events.where(_isShown), isEmpty);

        online = true;
        repository.batch = live;
        await viewModel.refreshAfterReconnect(const UserPreferences());

        expect(viewModel.recommendationsFromCache, isFalse);
        expect(viewModel.currentContext!.weatherIsStale, isFalse);
        expect(tracker.events.where(_isShown), hasLength(1));
      });

      test('sin lista también la pide', () async {
        final viewModel = await afterRestartOffline(const Duration(minutes: 40));
        online = true;

        await viewModel.refreshAfterReconnect(const UserPreferences());

        expect(repository.recommendationCalls, 1);
        expect(viewModel.currentContext!.weatherIsStale, isFalse);
      });
    });

    group('al volver a primer plano', () {
      test('un respaldo se vuelve a leer: con las horas deja de contar', () async {
        final viewModel = await afterRestartOffline(const Duration(minutes: 40));
        await viewModel.refreshContext();
        expect(viewModel.isAdaptingToContext, isTrue);

        viewModel.setForeground(false);
        now = now.add(const Duration(hours: 3));
        viewModel.setForeground(true);
        await pumpEventQueue();

        expect(viewModel.currentContext!.isRainy, isFalse);
        expect(viewModel.isAdaptingToContext, isFalse);
      });

      test('un clima real no gasta GPS ni red de más', () async {
        final viewModel = newViewModel(newManager());
        await viewModel.refreshContext();
        final before = viewModel.currentContext;

        viewModel.setForeground(false);
        viewModel.setForeground(true);
        await pumpEventQueue();

        expect(viewModel.currentContext, same(before));
      });
    });

    group('_ContextAdaptationBanner', () {
      const fresh = 'Está lloviendo: te mostramos primero misiones bajo techo.';
      const night = 'Es de noche: priorizamos misiones cerca o en casa.';

      Future<void> pumpExplore(WidgetTester tester, QuestViewModel viewModel) async {
        await tester.pumpWidget(
          MultiProvider(
            providers: [
              ChangeNotifierProvider<QuestViewModel>.value(value: viewModel),
              ChangeNotifierProvider(
                create: (_) => ProfileViewModel(_NoProfile(), _NoAuth(), 'user-1'),
              ),
            ],
            child: const MaterialApp(home: ExploreView()),
          ),
        );
        await tester.pump();
        await tester.pumpAndSettle();
      }

      testWidgets('lluvia de respaldo: dice de cuándo es', (tester) async {
        final viewModel = await tester.runAsync(
          () => afterRestartOffline(const Duration(minutes: 40)),
        );

        await pumpExplore(tester, viewModel!);

        expect(
          find.text(
            'Según el último clima conocido (hace 40 min): te mostramos primero misiones bajo techo.',
          ),
          findsOneWidget,
        );
        expect(find.text(fresh), findsNothing);
      });

      testWidgets('lluvia real: el texto de siempre', (tester) async {
        final viewModel = newViewModel(newManager());

        await pumpExplore(tester, viewModel);

        expect(find.text(fresh), findsOneWidget);
        expect(find.textContaining('último clima'), findsNothing);
      });

      testWidgets('respaldo vencido de noche: habla de la noche, no de lluvia', (tester) async {
        final viewModel = await tester.runAsync(() async {
          await newManager().snapshot();
          online = false;
          now = DateTime(2026, 10, 30, 23);
          return newViewModel(newManager());
        });

        await pumpExplore(tester, viewModel!);

        expect(find.text(night), findsOneWidget);
        expect(find.textContaining('último clima'), findsNothing);
      });

      testWidgets('respaldo vencido de día: sin banner', (tester) async {
        final viewModel = await tester.runAsync(
          () => afterRestartOffline(const Duration(hours: 4)),
        );

        await pumpExplore(tester, viewModel!);

        expect(find.text(fresh), findsNothing);
        expect(find.textContaining('último clima'), findsNothing);
        expect(find.text(night), findsNothing);
      });
    });
  });

  late QuestViewModel viewModel;

  setUp(() {
    viewModel = QuestViewModel(
      _UnusedQuestRepository(),
      _contextManager(),
      AnalyticsTracker(eventSink: _NullSink(), contextManager: _contextManager(), sessionId: 'unused'),
      'user-1',
    );
    // Interleaved on purpose: order should be untouched unless adapting.
    viewModel.catalog = [
      _quest('gps-1', locationMode: 'gps'),
      _quest('anywhere-1', locationMode: 'anywhere'),
      _quest('gps-2', locationMode: 'gps'),
      _quest('anywhere-2', locationMode: 'anywhere'),
    ];
  });

  test('sin lluvia ni noche, filteredCatalog conserva el orden del catálogo', () {
    viewModel.currentContext = _appContext();

    expect(viewModel.isAdaptingToContext, isFalse);
    expect(viewModel.filteredCatalog.map((q) => q.id), [
      'gps-1',
      'anywhere-1',
      'gps-2',
      'anywhere-2',
    ]);
  });

  test('con lluvia, filteredCatalog pone primero las misiones anywhere sin ocultar las demás', () {
    viewModel.currentContext = _appContext(isRainy: true);

    expect(viewModel.isAdaptingToContext, isTrue);
    expect(viewModel.filteredCatalog.map((q) => q.id), [
      'anywhere-1',
      'anywhere-2',
      'gps-1',
      'gps-2',
    ]);
    expect(viewModel.filteredCatalog.length, viewModel.catalog.length);
  });

  test('de noche (sin lluvia) también prioriza las misiones anywhere', () {
    viewModel.currentContext = _appContext(timeOfDay: 'night');

    expect(viewModel.isAdaptingToContext, isTrue);
    expect(viewModel.filteredCatalog.map((q) => q.id), [
      'anywhere-1',
      'anywhere-2',
      'gps-1',
      'gps-2',
    ]);
  });

  test('sin contexto cargado todavía (currentContext null), no reordena', () {
    expect(viewModel.currentContext, isNull);
    expect(viewModel.isAdaptingToContext, isFalse);
    expect(viewModel.filteredCatalog.map((q) => q.id), [
      'gps-1',
      'anywhere-1',
      'gps-2',
      'anywhere-2',
    ]);
  });

  test('el reordenamiento por lluvia respeta el resto de filtros existentes (minutos)', () {
    viewModel.currentContext = _appContext(isRainy: true);
    viewModel.setMinutes(20);
    viewModel.catalog = [
      ...viewModel.catalog,
      _quest('anywhere-too-long', locationMode: 'anywhere', durationMinutes: 999),
    ];

    expect(viewModel.filteredCatalog.map((q) => q.id), isNot(contains('anywhere-too-long')));
  });
}

bool _isShown(String event) => event == AnalyticsEventType.recommendationShown;
