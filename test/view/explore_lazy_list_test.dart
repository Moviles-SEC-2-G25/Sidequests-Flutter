import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:provider/provider.dart';
import 'package:sidequests/analytics/analytics_event_sink.dart';
import 'package:sidequests/analytics/analytics_tracker.dart';
import 'package:sidequests/core/app_exception.dart';
import 'package:sidequests/core/category_labels.dart';
import 'package:sidequests/core/verification/step_verification_strategy.dart';
import 'package:sidequests/core/workers/similar_quest_worker.dart';
import 'package:sidequests/data/context/context_manager.dart';
import 'package:sidequests/data/services/battery_monitor.dart';
import 'package:sidequests/data/services/location_check_in_service.dart';
import 'package:sidequests/data/services/location_service.dart';
import 'package:sidequests/data/services/step_counter_service.dart';
import 'package:sidequests/data/services/weather_service.dart';
import 'package:sidequests/models/app_context.dart';
import 'package:sidequests/models/explore_filters.dart';
import 'package:sidequests/models/photo_proof.dart';
import 'package:sidequests/models/profile.dart';
import 'package:sidequests/models/quest.dart';
import 'package:sidequests/models/quest_recommendation.dart';
import 'package:sidequests/models/quest_step.dart';
import 'package:sidequests/models/step_session.dart';
import 'package:sidequests/models/user_preferences.dart';
import 'package:sidequests/models/user_quest.dart';
import 'package:sidequests/models/verified_check_in.dart';
import 'package:sidequests/repository/quest_repository.dart';
import 'package:sidequests/view/quests/explore_view.dart';
import 'package:sidequests/view/quests/quest_detail_view.dart';
import 'package:sidequests/viewmodel/profile/profile_view_model.dart';
import 'package:sidequests/viewmodel/quests/quest_view_model.dart';

/// Micro-optimization (Alejandro, Sprint 4): "Todas las misiones" in Explorar
/// is built lazily. These tests measure how many mission rows each Explore
/// rebuild builds (eager Column vs. lazy SliverList) and check that the
/// screen still behaves the same.
///
/// The before/after table prints with `flutter test test/view/explore_lazy_list_test.dart`.

/// A phone (iPhone 12–15 / Pixel 7 class), in logical pixels.
const _phone = Size(390, 844);

const _day = AppContext(timeOfDay: 'afternoon', dayOfWeek: 'friday', isConnected: true);

/// [count] synthetic missions. Every 5th is sponsored, so rows have two
/// heights like the real catalogue (the badge adds a line).
List<Quest> _syntheticCatalog(int count, {List<int> durations = const [20]}) => [
  for (var i = 0; i < count; i++)
    Quest(
      id: 'q$i',
      title: 'Misión ${i.toString().padLeft(3, '0')}',
      category: const ['art', 'food', 'nature', 'sports'][i % 4],
      emoji: '🎯',
      durationMinutes: durations[i % durations.length],
      estimatedCost: i.isEven ? 0 : 12,
      difficulty: const ['easy', 'medium', 'hard'][i % 3],
      locationMode: i % 3 == 0 ? 'anywhere' : 'gps',
      socialLevel: 'solo',
      isSponsored: i % 5 == 0,
      sponsorName: i % 5 == 0 ? 'Patrocinador $i' : null,
    ),
];

/// The shape of the real catalogue (Backend seed.sql + 010_bq12): 10
/// missions, 5 of them sponsored, 15–60 min.
List<Quest> _seedLikeCatalog() => [
  for (var i = 0; i < 10; i++)
    Quest(
      id: 'seed$i',
      title: 'Seed mission $i',
      category: const ['Outdoors', 'Food', 'Art', 'Wellness', 'Learning'][i % 5],
      emoji: '🌿',
      durationMinutes: const [45, 30, 15, 20, 60][i % 5],
      difficulty: 'easy',
      locationMode: i.isEven ? 'gps' : 'anywhere',
      socialLevel: 'solo',
      isSponsored: i >= 5,
      sponsorName: i >= 5 ? 'Sponsor $i' : null,
    ),
];

class _FakeRepository implements QuestRepository {
  List<Quest> catalog;
  List<UserQuest> attempts = [];
  List<QuestRecommendation> recommendations = [];
  bool recommendationsSaved = false;
  AppException? catalogError;
  int catalogCalls = 0;

  _FakeRepository(this.catalog);

  @override
  bool catalogFromCache = false;

  @override
  bool userQuestsFromCache = false;

  @override
  Future<List<Quest>> getCatalog() async {
    catalogCalls++;
    final error = catalogError;
    if (error != null) throw error;
    return catalog;
  }

  @override
  Future<List<UserQuest>> getUserQuests(String userId) async => attempts;

  @override
  Future<RecommendationBatch> getRecommendations({
    required AppContext context,
    required UserPreferences preferences,
    List<String> excludedQuestIds = const [],
    int limit = 3,
  }) async => RecommendationBatch(
    recommendations: recommendations,
    batchId: 'batch',
    fromCache: recommendationsSaved,
  );

  @override
  RecommendationBatch? savedRecommendations(List<String> excludedQuestIds) => null;

  @override
  Future<void> saveExploreFilters(ExploreFilters filters) async {}

  @override
  StepSession? getActiveStepSession() => null;

  @override
  VerifiedCheckIn? getVerifiedCheckIn() => null;

  @override
  List<PendingPhotoProof> getPendingPhotoProofs() => const [];

  @override
  Future<List<QuestPhotoProof>> getPhotoProofs(String attemptId) async => const [];

  @override
  Map<String, int> getStepTotals() => const {};

  @override
  bool hasCachedSteps(String questId) => true;

  @override
  Future<List<QuestStep>> getSteps(String questId) async => [
    QuestStep(id: 0, questId: questId, stepOrder: 0, title: 'Paso uno'),
  ];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _NoLocation extends LocationService {
  @override
  Future<Position?> getCurrentPosition({LocationAccuracy accuracy = LocationAccuracy.medium}) async =>
      null;
}

class _FullBattery extends BatteryMonitor {
  @override
  Future<bool> isLow() async => false;
}

/// The real plugin's channel never answers under testWidgets' fake clock.
class _Online implements Connectivity {
  @override
  Future<List<ConnectivityResult>> checkConnectivity() async => [ConnectivityResult.wifi];

  @override
  Stream<List<ConnectivityResult>> get onConnectivityChanged => const Stream.empty();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// The context the ViewModel reads before each recommendations load.
class _FixedContext extends ContextManager {
  AppContext value = _day;

  _FixedContext()
    : super(locationService: _NoLocation(), batteryMonitor: _FullBattery(), connectivity: _Online());

  @override
  Future<AppContext> snapshot({int? availableMinutes}) async => value;
}

class _NullSink implements AnalyticsEventSink {
  @override
  Future<void> insertAnalyticsEvent(Map<String, dynamic> event) async {}
}

class _SilentTracker extends AnalyticsTracker {
  _SilentTracker() : super(eventSink: _NullSink(), contextManager: _FixedContext(), sessionId: 'x');

  @override
  Future<void> trackDetailed(
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
    required Map<String, dynamic> Function(int? distanceMeters) metadataForDistance,
    bool withCoordinates = true,
  }) async {}
}

class _Profile extends ChangeNotifier implements ProfileViewModel {
  @override
  Profile? profile = Profile(id: 'u', displayName: 'Ana', createdAt: DateTime(2026, 9));

  @override
  UserPreferences preferences = const UserPreferences();

  @override
  bool isLoading = false;

  @override
  String? errorMessage;

  @override
  Future<void> load() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Harness {
  final _FakeRepository repository;
  final _FixedContext context = _FixedContext();
  late final QuestViewModel viewModel = QuestViewModel(
    repository,
    context,
    _SilentTracker(),
    'u',
    similarQuestRunner: const SynchronousSimilarQuestRunner(),
    stepCounter: StepCounterService(requestAccess: () async => StepCounterStatus.unavailable),
    locationCheckIn: LocationCheckInService(
      requestAccess: () async => LocationAccess.denied,
      isLowBattery: () async => false,
      isOffline: () async => false,
      offlineChanges: () => const Stream.empty(),
      positions: (_, _) => const Stream.empty(),
    ),
  );

  _Harness(List<Quest> catalog) : repository = _FakeRepository(catalog);

  Future<void> pump(WidgetTester tester, {required bool eager}) async {
    tester.view.physicalSize = _phone;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<QuestViewModel>.value(value: viewModel),
          ChangeNotifierProvider<ProfileViewModel>(create: (_) => _Profile()),
          Provider<LocationService>.value(value: _NoLocation()),
          Provider<WeatherService>.value(value: WeatherService()),
        ],
        child: MaterialApp(home: ExploreView(eagerMissionList: eager)),
      ),
    );
    await tester.pumpAndSettle(); // post-frame load, recommendations
  }
}

int _median(List<int> values) => (List.of(values)..sort())[values.length ~/ 2];

typedef _Measure = ({int rows, int pumpMicros});

/// [rebuilds] identical Explore rebuilds (the "1 hr+" chip tapped again:
/// same list, one notify each): rows built per rebuild and the time of the
/// pump that draws it (build + layout + paint of that frame), as medians.
Future<_Measure> _measureRebuilds(WidgetTester tester, _Harness harness, {int rebuilds = 20}) async {
  const warmUp = 5; // first layouts, text caches
  final rows = <int>[];
  final micros = <int>[];
  for (var i = 0; i < rebuilds + warmUp; i++) {
    harness.viewModel.setMinutes(60);
    final watch = Stopwatch()..start();
    await tester.pump();
    watch.stop();
    if (i < warmUp) continue;
    rows.add(ExploreBuildStats.lastRebuildRows);
    micros.add(watch.elapsedMicroseconds);
  }
  return (rows: _median(rows), pumpMicros: _median(micros));
}

final _results = <String>[];

void main() {
  setUp(ExploreBuildStats.reset);

  group('medición: filas construidas por rebuild de Explorar', () {
    // Not recorded: lets the JIT compile both paths, so the first measured
    // test isn't the slow one just for running first.
    testWidgets('calentamiento', (tester) async {
      for (final eager in [true, false]) {
        final harness = _Harness(_syntheticCatalog(200));
        await harness.pump(tester, eager: eager);
        await _measureRebuilds(tester, harness, rebuilds: 5);
      }
    });

    for (final (name, catalog) in [
      ('200 sintéticas', () => _syntheticCatalog(200)),
      ('catálogo real (seed, 10)', _seedLikeCatalog),
    ]) {
      for (final eager in [true, false]) {
        final mode = eager ? 'eager (EXPLORE_EAGER_LIST=true)' : 'lazy (por defecto)';
        testWidgets('$name, $mode', (tester) async {
          final harness = _Harness(catalog());
          await harness.pump(tester, eager: eager);

          final top = await _measureRebuilds(tester, harness);
          await tester.drag(find.byType(Scrollable).first, const Offset(0, -1500));
          await tester.pumpAndSettle();
          final scrolled = await _measureRebuilds(tester, harness);

          _results.add(
            '| $name | $mode | ${top.rows} | ${(top.pumpMicros / 1000).toStringAsFixed(2)} ms '
            '| ${scrolled.rows} | ${(scrolled.pumpMicros / 1000).toStringAsFixed(2)} ms |',
          );
          final total = harness.viewModel.filteredCatalog.length;
          if (eager) {
            // The baseline: the whole section is on screen, so every row.
            expect(top.rows, total);
          } else {
            // Regression guard: only what's visible plus the cache extent.
            expect(top.rows, lessThanOrEqualTo(total < 15 ? total : 15));
            expect(scrolled.rows, lessThanOrEqualTo(total < 20 ? total : 20));
          }
        });
      }
    }

    tearDownAll(() {
      // ignore: avoid_print
      print(
        [
          '',
          '| Catálogo | Lista | Filas/rebuild (arriba) | Pump/rebuild (arriba) '
              '| Filas/rebuild (scroll 1500 px) | Pump/rebuild (scroll) |',
          '|---|---|---|---|---|---|',
          ..._results,
        ].join('\n'),
      );
    });
  });

  group('lista perezosa: Explorar se comporta igual', () {
    Finder mission(int i) => find.text('Misión ${i.toString().padLeft(3, '0')}');
    // The screen's, not a chip row's. A getter: a Finder keeps what it found.
    Finder scrollable() => find.byType(Scrollable).first;
    Finder categoryChipRow() => find
        .descendant(of: find.byKey(const ValueKey('all-missions')), matching: find.byType(Scrollable))
        .first;

    /// Indexes of the mission rows that exist right now, in screen order.
    List<int> builtRows() => [
      for (final element in find.textContaining('Misión ').evaluate())
        int.parse((element.widget as Text).data!.substring('Misión '.length)),
    ];

    /// Scrolls the screen until the category chips are at the top, so the
    /// first rows are on screen (on a phone they start below the fold).
    Future<void> showList(WidgetTester tester) async {
      // The title first: a `.first` finder throws while nothing matches.
      await tester.scrollUntilVisible(find.text('Todas las misiones'), 200, scrollable: scrollable());
      await tester.ensureVisible(categoryChipRow());
      await tester.pumpAndSettle();
    }

    testWidgets('solo construye lo visible, y agitar sigue viendo todas las misiones', (tester) async {
      final harness = _Harness(_syntheticCatalog(200));
      await harness.pump(tester, eager: false);
      // The catalogue starts below the fold (the Kotlin layout's header).
      await tester.scrollUntilVisible(mission(0), 300, scrollable: scrollable());
      await tester.pumpAndSettle();

      expect(mission(0), findsOneWidget);
      expect(mission(199), findsNothing); // not built until scrolled to
      expect(ExploreBuildStats.questRowBuilds, lessThan(20));
      // "Agitar para misión sorpresa" picks from the ViewModel, not the rows.
      expect(harness.viewModel.shakeCandidates(), hasLength(200));
    });

    testWidgets('filtro de minutos: deja solo las que caben', (tester) async {
      final harness = _Harness(_syntheticCatalog(12, durations: [10, 20, 45]));
      await harness.pump(tester, eager: false);
      expect(harness.viewModel.selectedMinutes, 30); // the default
      await tester.tap(find.text('10m'));
      await tester.pumpAndSettle();
      expect(harness.viewModel.selectedMinutes, 10);

      await showList(tester);
      // Durations cycle 10, 20, 45: only 000, 003, 006, 009 take 10 min.
      expect(builtRows().take(3), [0, 3, 6]);
      expect(builtRows().every((i) => i % 3 == 0), isTrue, reason: '${builtRows()}');
    });

    testWidgets('cambio de categoría: la lista cambia', (tester) async {
      final harness = _Harness(_syntheticCatalog(40));
      await harness.pump(tester, eager: false);
      await showList(tester);
      expect(builtRows().first, 0); // art

      // The chip row scrolls sideways and builds its chips lazily too.
      final food = find.text(categoryLabelEs('food'));
      await tester.scrollUntilVisible(food, 80, scrollable: categoryChipRow());
      await tester.pumpAndSettle();
      await tester.tap(food);
      await tester.pumpAndSettle();

      expect(harness.viewModel.selectedCategory, 'food');
      // Categories cycle art, food, nature, sports: food is 001, 005, 009…
      expect(builtRows(), isNotEmpty);
      expect(builtRows().every((i) => i % 4 == 1), isTrue, reason: '${builtRows()}');
      await tester.scrollUntilVisible(mission(37), 300, scrollable: scrollable(), maxScrolls: 400);
      expect(mission(37), findsOneWidget); // the last food one
    });

    testWidgets('lluvia: el banner, y las misiones bajo techo primero en la lista perezosa', (tester) async {
      final harness = _Harness(_syntheticCatalog(60));
      harness.context.value = const AppContext(
        timeOfDay: 'afternoon',
        dayOfWeek: 'friday',
        isConnected: true,
        isRainy: true,
      );
      await harness.pump(tester, eager: false);

      expect(find.text('Está lloviendo: te mostramos primero misiones bajo techo.'), findsOneWidget);
      // 'anywhere' is every 3rd (000, 003, 006…): the first 20 rows, so
      // every row built near the top is one of them, in catalogue order.
      await showList(tester);
      final built = builtRows();
      expect(built.length, greaterThanOrEqualTo(3));
      expect(built.every((i) => i % 3 == 0), isTrue, reason: '$built');
      expect(built, orderedEquals([...built]..sort()));
    });

    testWidgets('noche: el banner de la noche', (tester) async {
      final harness = _Harness(_syntheticCatalog(10));
      harness.context.value = const AppContext(timeOfDay: 'night', dayOfWeek: 'friday', isConnected: true);
      await harness.pump(tester, eager: false);

      expect(find.text('Es de noche: priorizamos misiones cerca o en casa.'), findsOneWidget);
    });

    testWidgets('"Recomendaciones guardadas" arriba, y la lista sigue abajo', (tester) async {
      final harness = _Harness(_syntheticCatalog(200));
      harness.repository
        ..recommendations = [_recommendation('q7')]
        ..recommendationsSaved = true;
      await harness.pump(tester, eager: false);

      expect(find.text('Recomendaciones guardadas'), findsOneWidget);
      expect(find.text('#1 para ti'), findsOneWidget);
      await tester.scrollUntilVisible(mission(150), 500, scrollable: scrollable(), maxScrolls: 400);
      expect(mission(150), findsOneWidget);
    });

    testWidgets('estado vacío: el mensaje y ninguna fila', (tester) async {
      final harness = _Harness(_syntheticCatalog(30)); // all 20 min
      await harness.pump(tester, eager: false);

      harness.viewModel.setMinutes(10);
      await tester.pumpAndSettle();

      expect(find.text('No hay misiones que coincidan con estos filtros.'), findsOneWidget);
      expect(find.textContaining('Misión '), findsNothing);
      expect(ExploreBuildStats.lastRebuildRows, 0);
    });

    testWidgets('sin conexión y sin misiones guardadas: el mismo aviso', (tester) async {
      final harness = _Harness([]);
      harness.repository.catalogFromCache = true;
      await harness.pump(tester, eager: false);

      expect(
        find.text(
          'Sin conexión y sin misiones guardadas en el teléfono. '
          'Conéctate y desliza hacia abajo para cargarlas.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('error sin catálogo: el mensaje del error', (tester) async {
      final harness = _Harness([]);
      harness.repository.catalogError = const AppException('No pudimos cargar las misiones.');
      await harness.pump(tester, eager: false);

      expect(find.text('No pudimos cargar las misiones.'), findsOneWidget);
    });

    testWidgets('deslizar hacia abajo recarga', (tester) async {
      final harness = _Harness(_syntheticCatalog(200));
      await harness.pump(tester, eager: false);
      expect(harness.repository.catalogCalls, 1);

      await tester.fling(find.text('¿Qué te apetece hoy?'), const Offset(0, 400), 1000);
      await tester.pumpAndSettle();

      expect(harness.repository.catalogCalls, 2);
    });

    testWidgets('scroll hasta la última misión y abrir su detalle', (tester) async {
      final harness = _Harness(_syntheticCatalog(200));
      await harness.pump(tester, eager: false);

      await tester.scrollUntilVisible(mission(199), 600, scrollable: scrollable(), maxScrolls: 400);
      await tester.tap(mission(199));
      await tester.pumpAndSettle();

      expect(find.byType(QuestDetailView), findsOneWidget);
      expect(tester.widget<QuestDetailView>(find.byType(QuestDetailView)).quest.id, 'q199');
    });

    testWidgets('el State de las secciones de arriba sobrevive al banner "continuar"', (tester) async {
      final harness = _Harness(_syntheticCatalog(200));
      harness.repository.recommendations = [_recommendation('q7')];
      await harness.pump(tester, eager: false);

      // skipOffstage: false, as a section may scroll out of view while
      // staying built (inside the cache extent).
      State stateIn(String section, Finder matching) => tester.state(
        find
            .descendant(
              of: find.byKey(ValueKey(section), skipOffstage: false),
              matching: matching,
              skipOffstage: false,
            )
            .first,
      );
      final card = find.byWidgetPredicate(
        (w) => w.runtimeType.toString() == '_RecommendationCard',
        skipOffstage: false,
      );
      final minutesChips = stateIn('filters', find.byType(Scrollable, skipOffstage: false));
      final recommendation = stateIn('recommended', card);
      expect(find.text('CONTINÚA DONDE LO DEJASTE'), findsNothing);

      harness.viewModel.userQuests = [
        UserQuest(id: 'uq', userId: 'u', questId: 'q3', status: 'in_progress', acceptedAt: DateTime(2026, 11, 27)),
      ];
      harness.viewModel.setCategory(null); // any notify: Explore rebuilds with the banner
      await tester.pumpAndSettle();

      expect(find.text('CONTINÚA DONDE LO DEJASTE'), findsOneWidget);
      expect(identical(stateIn('filters', find.byType(Scrollable, skipOffstage: false)), minutesChips), isTrue);
      expect(identical(stateIn('recommended', card), recommendation), isTrue);

      // And the missions header (below the fold on a phone) when it goes.
      await showList(tester);
      final categoryChips = stateIn('all-missions', find.byType(Scrollable, skipOffstage: false));
      harness.viewModel.userQuests = [];
      harness.viewModel.setCategory(null);
      await tester.pumpAndSettle();
      expect(find.text('CONTINÚA DONDE LO DEJASTE', skipOffstage: false), findsNothing);
      expect(identical(stateIn('all-missions', find.byType(Scrollable, skipOffstage: false)), categoryChips), isTrue);
    });
  });
}

QuestRecommendation _recommendation(String questId) => QuestRecommendation(
  questId: questId,
  score: 1,
  timeMatch: true,
  interestMatch: false,
  socialMatch: false,
  locationMatch: false,
);
