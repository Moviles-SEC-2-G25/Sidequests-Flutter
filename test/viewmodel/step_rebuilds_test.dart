import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:provider/provider.dart';
import 'package:sidequests/analytics/analytics_event_sink.dart';
import 'package:sidequests/analytics/analytics_tracker.dart';
import 'package:sidequests/data/context/context_manager.dart';
import 'package:sidequests/data/services/battery_monitor.dart';
import 'package:sidequests/data/services/location_service.dart';
import 'package:sidequests/data/services/step_counter_service.dart';
import 'package:sidequests/models/abandonment_reason.dart';
import 'package:sidequests/models/photo_proof.dart';
import 'package:sidequests/models/quest.dart';
import 'package:sidequests/models/quest_step.dart';
import 'package:sidequests/models/step_log_entry.dart';
import 'package:sidequests/models/step_session.dart';
import 'package:sidequests/models/user_quest.dart';
import 'package:sidequests/models/verified_check_in.dart';
import 'package:sidequests/repository/quest_repository.dart';
import 'package:sidequests/view/quests/mission_tab_view.dart';
import 'package:sidequests/viewmodel/quests/quest_view_model.dart';

/// Micro-optimization of the podómetro: how many times a widget that does
/// `context.watch<QuestViewModel>()` rebuilds while the user walks.

const _quest = Quest(
  id: 'a',
  title: 'Quest a',
  category: 'food',
  durationMinutes: 20,
  difficulty: 'easy',
  locationMode: 'anywhere',
  socialLevel: 'solo',
);

class _FakeRepository implements QuestRepository {
  final List<StepSession?> savedSessions = [];

  @override
  Future<List<Quest>> getCatalog() async => const [_quest];

  @override
  Future<List<UserQuest>> getUserQuests(String userId) async => [
    UserQuest(
      id: 'uq-a',
      userId: 'user-1',
      questId: 'a',
      status: 'in_progress',
      acceptedAt: DateTime(2026, 11, 27),
    ),
  ];

  @override
  Future<List<QuestStep>> getSteps(String questId) async => [
    const QuestStep(id: 1, questId: 'a', stepOrder: 0, title: 'Camina', verificationType: 'none'),
  ];

  @override
  Map<String, int> getStepTotals() => const {};

  @override
  Future<void> saveStepTotal(String userQuestId, int steps) async {}

  @override
  Future<void> logWalk(StepLogEntry walk) async {}

  @override
  Future<({UserQuest userQuest, bool queued})> abandonQuestOrQueue(
    UserQuest userQuest, {
    required String reason,
  }) async => (userQuest: userQuest.copyWithProgress(status: 'abandoned'), queued: false);

  @override
  StepSession? getActiveStepSession() => null;

  @override
  Future<void> saveActiveStepSession(StepSession? session) async => savedSessions.add(session);

  @override
  VerifiedCheckIn? getVerifiedCheckIn() => null;

  @override
  List<PendingPhotoProof> getPendingPhotoProofs() => const [];

  @override
  Future<List<QuestPhotoProof>> getPhotoProofs(String attemptId) async => const [];

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

class _NullSink implements AnalyticsEventSink {
  @override
  Future<void> insertAnalyticsEvent(Map<String, dynamic> event) async {}
}

/// Watches the ViewModel like Explorar, Cerca, Perfil… do, and counts its builds.
class _Probe extends StatelessWidget {
  final void Function() onBuild;

  const _Probe({required this.onBuild});

  @override
  Widget build(BuildContext context) {
    context.watch<QuestViewModel>();
    onBuild();
    return const SizedBox.shrink();
  }
}

void main() {
  late StreamController<int> sensor;
  late QuestViewModel viewModel;
  late _FakeRepository repository;

  setUp(() {
    // sync: each reading reaches the ViewModel when it's emitted, like a
    // pedometer event between two frames (not two readings in one frame).
    sensor = StreamController<int>.broadcast(sync: true);
    repository = _FakeRepository();
    final contextManager = ContextManager(locationService: _NoLocation(), batteryMonitor: _FullBattery());
    viewModel = QuestViewModel(
      repository,
      contextManager,
      AnalyticsTracker(eventSink: _NullSink(), contextManager: contextManager, sessionId: 'unused'),
      'user-1',
      stepCounter: StepCounterService(
        cumulativeSteps: () => sensor.stream,
        requestAccess: () async => StepCounterStatus.counting,
        openSettings: () async => true,
      ),
    );
  });

  tearDown(() => sensor.close());

  /// The Misión tab and the probe, the mission loaded and the podómetro counting.
  Future<void> pumpCounting(WidgetTester tester, void Function() onProbeBuild) async {
    tester.view.physicalSize = const Size(400, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(() async {
      await viewModel.load();
      await viewModel.loadSteps('a');
    });
    await tester.pumpWidget(
      ChangeNotifierProvider<QuestViewModel>.value(
        value: viewModel,
        child: MaterialApp(
          home: Column(
            children: [
              _Probe(onBuild: onProbeBuild),
              const Expanded(child: MissionTabView()),
            ],
          ),
        ),
      ),
    );
    // In the test's zone, so the sensor's events arrive with each pump.
    unawaited(viewModel.retryStepTracking()); // starts counting
    await tester.pumpAndSettle();
    sensor.add(5000); // the baseline reading: "0 pasos caminados"
    await tester.pumpAndSettle();
  }

  testWidgets('walking 50 steps: the widget watching the ViewModel does not rebuild, the card counts',
      (tester) async {
    var probeBuilds = 0;
    await pumpCounting(tester, () => probeBuilds++);
    expect(find.text('0 steps walked'), findsOneWidget);

    final buildsBefore = probeBuilds;
    var notifications = 0;
    viewModel.addListener(() => notifications++);
    for (var step = 1; step <= 50; step++) {
      sensor.add(5000 + step);
      await tester.pumpAndSettle(); // each step drawn before the next one
    }
    final rebuildsFromSteps = probeBuilds - buildsBefore;
    // ignore: avoid_print
    print('REBUILDS of a context.watch<QuestViewModel>() widget during 50 steps: $rebuildsFromSteps '
        '(notifyListeners: $notifications)');

    expect(find.text('50 steps walked'), findsOneWidget, reason: 'the card shows every step');
    expect(viewModel.missionSteps, 50);
    expect(notifications, 0);
    expect(rebuildsFromSteps, 0);
  });

  testWidgets('a podómetro status change does notify: the card switches to "sin sensor"',
      (tester) async {
    var probeBuilds = 0;
    await pumpCounting(tester, () => probeBuilds++);
    final buildsBefore = probeBuilds;
    var notifications = 0;
    viewModel.addListener(() => notifications++);

    sensor.addError(Exception('StepCount not available')); // no sensor
    await tester.pumpAndSettle();

    expect(viewModel.stepStatus, StepCounterStatus.unavailable);
    expect(notifications, 1);
    expect(probeBuilds - buildsBefore, 1);
    expect(find.text('Your phone has no step counter.'), findsOneWidget);
    expect(viewModel.missionStepsListenable.value, isNull, reason: 'no session, no number');
  });

  test('the session starting and ending notifies; the steps in between only the listenable', () async {
    await viewModel.load();
    var notifications = 0;
    final heard = <int?>[];
    viewModel.addListener(() => notifications++);
    viewModel.missionStepsListenable.addListener(() => heard.add(viewModel.missionStepsListenable.value));

    await viewModel.retryStepTracking(); // the session starts
    await pumpEventQueue();
    expect(notifications, 1);

    for (final reading in [100, 110, 120]) {
      sensor.add(reading);
      await pumpEventQueue(); // one reading at a time, as the sensor sends them
    }
    expect(notifications, 1, reason: 'readings do not notify');
    expect(heard, [0, 10, 20]);
    expect(viewModel.missionSteps, 20, reason: 'the getter is still there');

    await viewModel.abandonQuest(viewModel.currentMission!, reason: AbandonmentReason.ranOutOfTime);
    await pumpEventQueue();
    expect(viewModel.stepStatus, StepCounterStatus.idle);
    expect(notifications, greaterThan(1), reason: 'the session ended');
    expect(viewModel.missionStepsListenable.value, isNull);
  });

  test('the session is still saved every 25 steps, not on every step', () async {
    await viewModel.load();
    await viewModel.retryStepTracking();
    await pumpEventQueue();
    repository.savedSessions.clear();

    for (var reading = 1000; reading <= 1050; reading++) {
      sensor.add(reading);
      await pumpEventQueue();
    }

    // The baseline (0), then +25 and +50: three writes for 51 readings.
    expect(repository.savedSessions.map((s) => s?.steps), [0, 25, 50]);
  });

  test('dispose releases the steps notifier', () async {
    final listenable = viewModel.missionStepsListenable as ValueNotifier<int?>;
    viewModel.dispose();

    expect(() => listenable.addListener(() {}), throwsFlutterError);
    // tearDown closes the sensor; the ViewModel no longer listens to it.
  });
}
