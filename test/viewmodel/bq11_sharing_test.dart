import 'dart:async';
import 'dart:io';

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
import 'package:sidequests/core/bq11/commercial_blocks.dart';
import 'package:sidequests/core/verification/step_verification_strategy.dart';
import 'package:sidequests/data/context/context_manager.dart';
import 'package:sidequests/data/local/local_data_source.dart';
import 'package:sidequests/data/services/battery_monitor.dart';
import 'package:sidequests/data/services/bq11_fix_reader.dart';
import 'package:sidequests/data/services/location_check_in_service.dart';
import 'package:sidequests/data/services/location_service.dart';
import 'package:sidequests/data/services/step_counter_service.dart';
import 'package:sidequests/data/services/weather_service.dart';
import 'package:sidequests/models/photo_proof.dart';
import 'package:sidequests/models/quest.dart';
import 'package:sidequests/models/quest_step.dart';
import 'package:sidequests/models/step_session.dart';
import 'package:sidequests/models/user_quest.dart';
import 'package:sidequests/models/verified_check_in.dart';
import 'package:sidequests/repository/quest_repository.dart';
import 'package:sidequests/view/quests/mission_tab_view.dart';
import 'package:sidequests/viewmodel/quests/quest_view_model.dart';

const _attemptId = 'uq-bq11';
const _eventId = '3f1d1a52-6c1b-4c2e-9b55-1d2f4a7c9e01';
const _paloquemao = (lat: 4.616, lon: -74.08426);

const _gpsQuest = Quest(
  id: 'mercado',
  title: 'Mercado de Paloquemao',
  category: 'food',
  durationMinutes: 60,
  difficulty: 'easy',
  locationMode: 'gps',
  socialLevel: 'solo',
);

const _offline = AppException('Offline', isRetryable: true);

/// analytics_events: [offline] fails like a dropped connection.
class _Sink implements AnalyticsEventSink {
  bool offline = false;
  final List<Map<String, dynamic>> inserted = [];

  @override
  Future<void> insertAnalyticsEvent(Map<String, dynamic> event) async {
    if (offline) throw const SocketException('offline');
    inserted.add(event);
  }
}

/// The analytics Hive box, in memory.
class _FakeLocal implements LocalDataSource {
  List<Map<String, dynamic>> pending = [];

  @override
  List<Map<String, dynamic>> getPendingAnalyticsEvents() => [...pending];

  @override
  Future<void> savePendingAnalyticsEvents(List<Map<String, dynamic>> events) async =>
      pending = events;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// The context snapshot has a position: the BQ11 event must still leave it out.
class _SomeLocation extends LocationService {
  @override
  Future<Position?> getCurrentPosition({
    LocationAccuracy accuracy = LocationAccuracy.medium,
  }) async => Position(
    latitude: _paloquemao.lat,
    longitude: _paloquemao.lon,
    timestamp: DateTime(2026, 11, 28),
    accuracy: 5,
    altitude: 0,
    altitudeAccuracy: 0,
    heading: 0,
    headingAccuracy: 0,
    speed: 0,
    speedAccuracy: 0,
  );
}

class _FullBattery extends BatteryMonitor {
  @override
  Future<bool> isLow() async => false;
}

class _FakeTimer implements Timer {
  bool cancelled = false;

  @override
  void cancel() => cancelled = true;

  @override
  bool get isActive => !cancelled;

  @override
  int get tick => 0;
}

class _FakeRepository implements QuestRepository {
  Quest quest = _gpsQuest;
  bool offline = false;
  DateTime completedAt = DateTime.utc(2026, 11, 29, 2);
  int completions = 0;

  late UserQuest mission = UserQuest(
    id: _attemptId,
    userId: 'user-1',
    questId: quest.id,
    status: 'in_progress',
    acceptedAt: DateTime.utc(2026, 11, 29),
  );

  @override
  Future<List<Quest>> getCatalog() async => [quest];

  @override
  Future<List<UserQuest>> getUserQuests(String userId) async => [mission];

  @override
  Future<List<QuestStep>> getSteps(String questId) async => [
    QuestStep(id: 1, questId: questId, stepOrder: 0, title: 'Recorre el mercado', verificationType: 'none'),
  ];

  @override
  Future<UserQuest> completeQuest(UserQuest userQuest) async {
    if (offline) throw _offline;
    completions++;
    // The server's row, with its completed_at.
    return UserQuest(
      id: userQuest.id,
      userId: userQuest.userId,
      questId: userQuest.questId,
      status: 'completed',
      completedSteps: userQuest.completedSteps,
      acceptedAt: userQuest.acceptedAt,
      completedAt: completedAt,
    );
  }

  @override
  StepSession? getActiveStepSession() => null;

  @override
  VerifiedCheckIn? getVerifiedCheckIn() => null;

  @override
  List<PendingPhotoProof> getPendingPhotoProofs() => const [];

  @override
  Future<List<QuestPhotoProof>> getPhotoProofs(String attemptId) async => const [];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _settle() => pumpEventQueue();

void main() {
  late _Sink sink;
  late _FakeLocal local;
  late _FakeRepository repository;
  late QuestViewModel viewModel;
  late DateTime now;
  late Duration elapsed;
  late LocationAccess access;
  late ({double lat, double lon}) place;
  late int reads;
  late bool failReads;
  final timers = <(_FakeTimer, void Function(Timer))>[];
  final screen = Object();

  QuestViewModel build() => QuestViewModel(
    repository,
    ContextManager(locationService: _SomeLocation(), batteryMonitor: _FullBattery()),
    AnalyticsTracker(
      eventSink: sink,
      contextManager: ContextManager(
        locationService: _SomeLocation(),
        batteryMonitor: _FullBattery(),
        weatherService: WeatherService(client: MockClient((_) async => http.Response('', 503))),
      ),
      sessionId: '7f1c0c4e-0000-4000-8000-000000000000',
      localDataSource: local,
    ),
    'user-1',
    now: () => now,
    stepCounter: StepCounterService(requestAccess: () async => StepCounterStatus.unavailable),
    locationCheckIn: LocationCheckInService(
      requestAccess: () async => LocationAccess.granted,
      isLowBattery: () async => false,
      isOffline: () async => false,
      offlineChanges: () => const Stream.empty(),
      positions: (_, _) => const Stream.empty(),
    ),
    bq11FixReader: () async {
      reads++;
      if (failReads) return null; // no permission, no signal, timed out
      return Bq11Fix(latitude: place.lat, longitude: place.lon, accuracyMeters: 5, fixTime: now);
    },
    bq11RequestAccess: () async => access,
    bq11PeriodicTimer: (interval, callback) {
      expect(interval, kBq11SampleInterval);
      final timer = _FakeTimer();
      timers.add((timer, callback));
      return timer;
    },
    bq11Elapsed: () => elapsed,
    newEventId: () => _eventId,
  );

  setUp(() {
    sink = _Sink();
    local = _FakeLocal();
    repository = _FakeRepository();
    // Saturday 2026-11-28, 20:00 in Bogotá (Kotlin's test start).
    now = DateTime.utc(2026, 11, 29, 1);
    elapsed = Duration.zero;
    access = LocationAccess.granted;
    place = _paloquemao;
    reads = 0;
    failReads = false;
    timers.clear();
    viewModel = build();
  });

  tearDown(() => viewModel.dispose());

  _FakeTimer? runningTimer() {
    final live = timers.where((t) => !t.$1.cancelled);
    return live.isEmpty ? null : live.single.$1;
  }

  /// 15 s go by and the running timer fires.
  Future<void> tick([int times = 1]) async {
    for (var i = 0; i < times; i++) {
      now = now.add(kBq11SampleInterval);
      elapsed += kBq11SampleInterval;
      final live = timers.where((t) => !t.$1.cancelled).toList();
      for (final (timer, callback) in live) {
        callback(timer);
      }
      await _settle();
    }
  }

  /// The mission open on the Misión tab, sharing on: the first reading is taken at once.
  Future<void> openAndShare() async {
    await viewModel.load();
    await viewModel.loadSteps(repository.quest.id);
    viewModel.setMissionScreenVisible(screen, true);
    await viewModel.setBq11Sharing(true);
    await _settle();
  }

  Future<bool> complete() async {
    final completed = await viewModel.completeCurrentStep(viewModel.currentMission!);
    await _settle();
    return completed;
  }

  List<Map<String, dynamic>> bq11Events() => [
    for (final event in [...sink.inserted, ...local.pending])
      if (event['event_type'] == AnalyticsEventType.bq11CommercialBlockCompleted) event,
  ];

  group('who can share', () {
    test('a physical (gps) individual mission in progress', () async {
      await viewModel.load();
      final mission = viewModel.currentMission!;

      expect(viewModel.canShareBq11(mission, _gpsQuest), isTrue);
    });

    test('not a group challenge, a virtual quest or a finished attempt', () async {
      await viewModel.load();
      final mission = viewModel.currentMission!;
      const group = Quest(
        id: 'mercado',
        title: 'In a group',
        category: 'food',
        durationMinutes: 60,
        difficulty: 'easy',
        locationMode: 'gps',
        socialLevel: 'group',
        isGroup: true,
      );
      const virtual = Quest(
        id: 'mercado',
        title: 'Desde casa',
        category: 'food',
        durationMinutes: 60,
        difficulty: 'easy',
        locationMode: 'virtual',
        socialLevel: 'solo',
      );

      expect(viewModel.canShareBq11(mission, group), isFalse);
      expect(viewModel.canShareBq11(mission, virtual), isFalse);
      expect(viewModel.canShareBq11(mission.copyWithProgress(status: 'completed'), _gpsQuest), isFalse);
    });

    test('without precise location sharing stays off and says why', () async {
      access = LocationAccess.approximateOnly;
      await openAndShare();

      expect(viewModel.isSharingBq11, isFalse);
      expect(viewModel.bq11SharingError, kBq11NeedsPreciseLocation);
      expect(reads, 0);
    });
  });

  group('the event', () {
    test('over 20 min in a block: sent after completing, with Kotlin\'s payload', () async {
      await openAndShare();
      await tick(81); // 81 intervals of 15 s = 1,215,000 ms

      expect(bq11Events(), isEmpty, reason: 'nothing before the completion is saved');
      expect(await complete(), isTrue);

      final event = bq11Events().single;
      expect(event['quest_id'], _gpsQuest.id);
      // Kotlin's metadata keys and values; only platform differs.
      expect(event['metadata'], {
        'event_id': _eventId,
        'schema_version': 1,
        'platform': 'flutter',
        'attempt_id': _attemptId,
        'block_id': kBq11PaloquemaoBlockId,
        'weekend_start': '2026-11-28',
        'observed_ms': 1215000,
      });
      // Never where the user was.
      expect(event['latitude'], isNull);
      expect(event['longitude'], isNull);
      expect(event['distance_meters'], isNull);
      // Sent right away: occurred_at is the server's now(), next to completed_at.
      expect(event.containsKey('occurred_at'), isFalse);
      // Measurement over: nothing keeps reading.
      expect(viewModel.isSharingBq11, isFalse);
      expect(runningTimer(), isNull);
    });

    test('exactly 20 min (1,200,000 ms) is not over the threshold: no event', () async {
      await openAndShare();
      await tick(80);

      await complete();

      expect(bq11Events(), isEmpty);
    });

    test('offline it waits in the analytics queue with when the completion happened', () async {
      await openAndShare();
      await tick(81);
      sink.offline = true;
      final before = DateTime.now().toUtc();

      await complete();

      final queued = local.pending.singleWhere(
        (e) => e['event_type'] == AnalyticsEventType.bq11CommercialBlockCompleted,
      );
      final occurredAt = DateTime.parse(queued['occurred_at'] as String);
      expect(occurredAt.isBefore(before), isFalse);
      expect(occurredAt.difference(DateTime.now().toUtc()).inSeconds.abs(), lessThanOrEqualTo(60));
      expect(queued['latitude'], isNull);
      expect((queued['metadata'] as Map)['observed_ms'], 1215000);
    });

    test('sharing turned off before completing: the measurement is discarded', () async {
      await openAndShare();
      await tick(81);

      await viewModel.setBq11Sharing(false);
      expect(runningTimer(), isNull);
      await complete();

      expect(bq11Events(), isEmpty);
    });

    test('never shared: no reading and no event', () async {
      await viewModel.load();
      await viewModel.loadSteps(repository.quest.id);
      viewModel.setMissionScreenVisible(screen, true);
      await tick(90);

      await complete();

      expect(reads, 0);
      expect(timers, isEmpty);
      expect(bq11Events(), isEmpty);
    });

    test('a completion the server didn\'t confirm sends nothing; the one that goes through does',
        () async {
      await openAndShare();
      await tick(81);
      repository.offline = true;

      expect(await complete(), isFalse);
      expect(bq11Events(), isEmpty);
      expect(viewModel.isSharingBq11, isTrue, reason: 'the measurement survives the failure');

      repository.offline = false;
      expect(await complete(), isTrue);
      expect(bq11Events(), hasLength(1));
    });

    test('completed on another weekend than the time measured: no event', () async {
      await openAndShare();
      await tick(81);
      repository.completedAt = DateTime.utc(2026, 12, 6, 1);

      await complete();

      expect(bq11Events(), isEmpty);
    });
  });

  group('when it measures', () {
    test('the app going to the background cuts the interval', () async {
      await openAndShare();
      await tick(40);

      viewModel.setForeground(false);
      expect(runningTimer(), isNull, reason: 'no GPS in the background');
      // 15 s later, back: the timer starts over with a new first reading.
      now = now.add(kBq11SampleInterval);
      elapsed += kBq11SampleInterval;
      viewModel.setForeground(true);
      await _settle();
      await tick(40);

      // Without the cut: 81 intervals. With it: 40 + 40 = 1,200,000, not over.
      await complete();
      expect(bq11Events(), isEmpty);
    });

    test('the Misión screen hidden (another tab, a screen on top): no readings', () async {
      await openAndShare();
      final readsWhileVisible = reads;

      viewModel.setMissionScreenVisible(screen, false);
      expect(runningTimer(), isNull);
      await tick(10);

      expect(reads, readsWhileVisible);
    });

    test('on a weekday it doesn\'t even read the GPS', () async {
      now = DateTime.utc(2026, 11, 26, 18); // Thursday in Bogotá
      await openAndShare();
      await tick(90);
      repository.completedAt = now;

      await complete();

      expect(reads, 0);
      expect(bq11Events(), isEmpty);
    });

    test('the attempt no longer active (abandoned elsewhere): discarded, GPS off', () async {
      await openAndShare();
      await tick(81);

      repository.mission = repository.mission.copyWithProgress(status: 'abandoned');
      await viewModel.load();

      expect(viewModel.isSharingBq11, isFalse);
      expect(runningTimer(), isNull);
      final readsAfter = reads;
      await tick(5);
      expect(reads, readsAfter);
    });

    test('a reading that fails (no fix) cuts the interval', () async {
      await openAndShare();
      await tick(40); // 0..600 s
      failReads = true;
      await tick(); // 615 s: nothing
      failReads = false;
      await tick(41); // 630..1230 s: 40 intervals

      // Bridging the failed read (600 -> 630 s) would make it 1,230,000.
      await complete();
      expect(bq11Events(), isEmpty);
    });

    test('changing block halfway: neither block reaches the threshold', () async {
      await openAndShare();
      await tick(41);
      place = (lat: 4.69577, lon: -74.031); // Usaquén
      await tick(41);

      await complete();

      expect(bq11Events(), isEmpty);
    });
  });

  group('the switch on the Misión tab', () {
    Future<void> pumpMission(WidgetTester tester) async {
      tester.view.physicalSize = const Size(360, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.runAsync(() async {
        await viewModel.load();
        await viewModel.loadSteps(repository.quest.id);
      });
      await tester.pumpWidget(
        ChangeNotifierProvider<QuestViewModel>.value(
          value: viewModel,
          child: const MaterialApp(home: MissionTabView()),
        ),
      );
      await tester.pump();
    }

    testWidgets('shows for a physical individual mission, off, saying what is sent', (tester) async {
      await pumpMission(tester);

      expect(find.text('Share time in the area (anonymous)'), findsOneWidget);
      expect(find.textContaining('never your coordinates'), findsOneWidget);
      final toggle = tester.widget<SwitchListTile>(find.byKey(const Key('bq11SharingSwitch')));
      expect(toggle.value, isFalse);
    });

    testWidgets('not for a group challenge', (tester) async {
      repository.quest = const Quest(
        id: 'mercado',
        title: 'In a group',
        category: 'food',
        durationMinutes: 60,
        difficulty: 'easy',
        locationMode: 'gps',
        socialLevel: 'group',
        isGroup: true,
      );
      await pumpMission(tester);

      expect(find.byKey(const Key('bq11SharingSwitch')), findsNothing);
    });

    testWidgets('pushed Misión screen: measures while on screen, stops when covered or closed',
        (tester) async {
      await tester.runAsync(() async {
        await viewModel.load();
        await viewModel.loadSteps(repository.quest.id);
      });
      final navigatorKey = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        ChangeNotifierProvider<QuestViewModel>.value(
          value: viewModel,
          child: MaterialApp(
            navigatorKey: navigatorKey,
            home: const Scaffold(body: Text('Inicio')),
          ),
        ),
      );
      navigatorKey.currentState!.push(
        MaterialPageRoute<void>(builder: (_) => const MissionTabView(isTab: false)),
      );
      await tester.pumpAndSettle();
      await tester.runAsync(() => viewModel.setBq11Sharing(true));
      expect(runningTimer(), isNotNull);

      navigatorKey.currentState!.push(
        MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('Encima'))),
      );
      await tester.pumpAndSettle();
      expect(runningTimer(), isNull, reason: 'covered by another screen');

      navigatorKey.currentState!.pop();
      await tester.pumpAndSettle();
      expect(runningTimer(), isNotNull, reason: 'on screen again');

      navigatorKey.currentState!.pop();
      await tester.pumpAndSettle();
      expect(runningTimer(), isNull, reason: 'closed');
    });
  });
}
