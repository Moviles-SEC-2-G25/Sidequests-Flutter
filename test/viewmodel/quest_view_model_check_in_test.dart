import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:provider/provider.dart';
import 'package:sidequests/analytics/analytics_event_sink.dart';
import 'package:sidequests/analytics/analytics_tracker.dart';
import 'package:sidequests/core/verification/step_verification_strategy.dart';
import 'package:sidequests/data/context/context_manager.dart';
import 'package:sidequests/data/services/battery_monitor.dart';
import 'package:sidequests/data/services/location_check_in_service.dart';
import 'package:sidequests/data/services/location_service.dart';
import 'package:sidequests/data/services/step_counter_service.dart';
import 'package:sidequests/models/photo_proof.dart';
import 'package:sidequests/models/quest.dart';
import 'package:sidequests/models/quest_step.dart';
import 'package:sidequests/models/step_session.dart';
import 'package:sidequests/models/user_quest.dart';
import 'package:sidequests/repository/quest_repository.dart';
import 'package:sidequests/view/quests/mission_tab_view.dart';
import 'package:sidequests/viewmodel/quests/quest_view_model.dart';

const _questLat = 4.6473;
const _questLon = -74.0600;
const _degPerMeter = 1 / 111195;

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

Quest _quest({bool withCoordinates = true}) => Quest(
  id: 'a',
  title: 'Quest a',
  category: 'food',
  durationMinutes: 20,
  difficulty: 'easy',
  locationMode: 'gps',
  socialLevel: 'solo',
  latitude: withCoordinates ? _questLat : null,
  longitude: withCoordinates ? _questLon : null,
);

QuestStep _step(int order, String verificationType) => QuestStep(
  id: order,
  questId: 'a',
  stepOrder: order,
  title: 'Step $order',
  verificationType: verificationType,
);

class _FakeQuestRepository implements QuestRepository {
  Quest quest = _quest();
  List<QuestStep> steps = [];
  List<UserQuest> userQuests = [
    UserQuest(
      id: 'uq-a',
      userId: 'user-1',
      questId: 'a',
      status: 'in_progress',
      acceptedAt: DateTime(2026, 1, 1),
    ),
  ];
  final List<UserQuest> progressUpdates = [];
  final List<UserQuest> completions = [];

  @override
  Future<List<Quest>> getCatalog() async => [quest];

  @override
  Future<List<UserQuest>> getUserQuests(String userId) async => userQuests;

  @override
  Future<List<QuestStep>> getSteps(String questId) async => steps;

  @override
  Future<UserQuest> updateProgress(UserQuest userQuest) async {
    progressUpdates.add(userQuest);
    return userQuest;
  }

  @override
  Future<UserQuest> completeQuest(UserQuest userQuest) async {
    final completed = userQuest.copyWithProgress(status: 'completed');
    completions.add(completed);
    return completed;
  }

  @override
  Future<UserQuest> abandonQuest(UserQuest userQuest, {required String reason}) async =>
      userQuest.copyWithProgress(status: 'abandoned');

  // Podómetro storage: unused here (the step counter is unavailable).
  @override
  StepSession? getActiveStepSession() => null;

  // Photo proof: none uploaded or pending in these tests.
  @override
  List<PendingPhotoProof> getPendingPhotoProofs() => const [];

  @override
  Future<List<QuestPhotoProof>> getPhotoProofs(String attemptId) async => const [];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _flush() => Future<void>.delayed(Duration.zero);

void main() {
  late _FakeQuestRepository repository;
  late StreamController<CheckInFix> gps;
  late int gpsSubscriptions;
  late Future<LocationAccess> Function() requestAccess;
  late LocationCheckInService checkIn;
  late QuestViewModel viewModel;
  late List<CheckInEvent> events;

  setUp(() {
    repository = _FakeQuestRepository();
    gps = StreamController<CheckInFix>.broadcast();
    gpsSubscriptions = 0;
    requestAccess = () async => LocationAccess.granted;
    checkIn = LocationCheckInService(
      requestAccess: () => requestAccess(),
      isLowBattery: () async => false,
      positions: (_, _) {
        gpsSubscriptions++;
        return gps.stream;
      },
    );
    viewModel = QuestViewModel(
      repository,
      _contextManager(),
      _SilentTracker(),
      'user-1',
      stepCounter: StepCounterService(
        requestAccess: () async => StepCounterStatus.unavailable,
      ),
      locationCheckIn: checkIn,
    );
    events = [];
    viewModel.checkInEvents.listen(events.add);
  });

  /// Loads the mission and its steps, as MissionTabView does.
  Future<void> openMission(List<QuestStep> steps) async {
    repository.steps = steps;
    await viewModel.load();
    await viewModel.loadSteps('a');
    await _flush();
  }

  Future<void> walkTo(double metersNorth, {double accuracy = 10}) async {
    gps.add(
      CheckInFix(
        latitude: _questLat + metersNorth * _degPerMeter,
        longitude: _questLon,
        accuracyMeters: accuracy,
      ),
    );
    await _flush();
    await _flush();
  }

  VerificationResult currentLocationResult() {
    final step = repository.steps[viewModel.currentMission!.currentStep];
    final part = viewModel.verificationStrategyFor(step).parts.first;
    return viewModel.verificationResultFor(part, repository.quest);
  }

  test('arriving within 50 m completes a location step with no tap, then the GPS turns off', () async {
    await openMission([_step(0, 'location'), _step(1, 'none')]);
    expect(checkIn.isWatching, isTrue);

    await walkTo(500);
    expect(currentLocationResult(), isA<Pending>());
    expect(repository.progressUpdates, isEmpty);

    await walkTo(20);

    expect(repository.progressUpdates.single.currentStep, 1);
    expect(repository.progressUpdates.single.completedSteps, [0]);
    expect(events.single.completedQuest, isFalse);
    // Next step is 'none': nothing left to watch.
    expect(checkIn.isWatching, isFalse);
  });

  test('a location step that is the last one completes the whole mission', () async {
    await openMission([_step(0, 'none'), _step(1, 'location')]);
    expect(checkIn.isWatching, isFalse); // step 0 needs no location

    await viewModel.completeCurrentStep(viewModel.currentMission!); // manual step 0
    await _flush();
    expect(checkIn.isWatching, isTrue);

    await walkTo(10);

    expect(repository.completions, hasLength(1));
    expect(events.single.completedQuest, isTrue);
    expect(checkIn.isWatching, isFalse);
  });

  test('several fixes inside the radius advance the step only once', () async {
    await openMission([_step(0, 'location'), _step(1, 'none')]);

    gps
      ..add(CheckInFix(latitude: _questLat, longitude: _questLon, accuracyMeters: 5))
      ..add(CheckInFix(latitude: _questLat, longitude: _questLon, accuracyMeters: 5))
      ..add(CheckInFix(latitude: _questLat, longitude: _questLon, accuracyMeters: 5));
    await _flush();
    await _flush();

    expect(repository.progressUpdates, hasLength(1));
  });

  test('a fix too imprecise to prove it does not complete the step', () async {
    await openMission([_step(0, 'location'), _step(1, 'none')]);

    await walkTo(20, accuracy: 400);

    expect(repository.progressUpdates, isEmpty);
    expect(checkIn.isWatching, isTrue);
  });

  test('a quest without coordinates never turns the GPS on and falls back to manual', () async {
    repository.quest = _quest(withCoordinates: false);
    await openMission([_step(0, 'location'), _step(1, 'none')]);

    expect(gpsSubscriptions, 0);
    expect(currentLocationResult(), isA<Unavailable>());
  });

  test('a step without location verification never turns the GPS on', () async {
    await openMission([_step(0, 'none'), _step(1, 'photo')]);

    expect(gpsSubscriptions, 0);
  });

  test('photo_and_location: being there marks the location part but waits for the photo', () async {
    await openMission([_step(0, 'photo_and_location'), _step(1, 'none')]);

    await walkTo(10);

    expect(currentLocationResult(), isA<Verified>()); // the location row shows ✓
    expect(repository.progressUpdates, isEmpty); // the step doesn't advance
    // …and the button stays blocked until the photo is uploaded.
    expect(viewModel.canCompleteCurrentStep(repository.steps.first, repository.quest), isFalse);
  });

  test('permission denied: no GPS, the row explains why, the mission still works', () async {
    requestAccess = () async => LocationAccess.denied;
    await openMission([_step(0, 'location'), _step(1, 'none')]);

    expect(gpsSubscriptions, 0);
    final result = currentLocationResult();
    expect(result, isA<Unavailable>());
    expect((result as Unavailable).reason, contains('Permite'));

    await viewModel.completeCurrentStep(viewModel.currentMission!);
    expect(repository.progressUpdates.single.currentStep, 1);
  });

  test('the GPS stops in the background and resumes in the foreground', () async {
    await openMission([_step(0, 'location'), _step(1, 'none')]);
    expect(checkIn.isWatching, isTrue);

    viewModel.setForeground(false);
    expect(checkIn.isWatching, isFalse);

    viewModel.setForeground(true);
    await _flush();
    expect(checkIn.isWatching, isTrue);
  });

  test('abandoning the mission stops the GPS', () async {
    await openMission([_step(0, 'location'), _step(1, 'none')]);

    await viewModel.abandonQuest(viewModel.currentMission!, reason: 'no_time');

    expect(checkIn.isWatching, isFalse);
  });

  group('Misión tab', () {
    Future<void> pumpMissionTab(WidgetTester tester) async {
      tester.view.physicalSize = const Size(360, 690); // small phone: overflow fails
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ChangeNotifierProvider<QuestViewModel>.value(
          value: viewModel,
          child: const MaterialApp(home: MissionTabView()),
        ),
      );
      await tester.pump();
    }

    testWidgets('the location row shows how far away you are, live', (tester) async {
      await tester.runAsync(() => openMission([_step(0, 'location'), _step(1, 'none')]));
      await pumpMissionTab(tester);
      expect(find.text('Buscando tu ubicación…'), findsOneWidget);

      await tester.runAsync(() => walkTo(500));
      await tester.pump();

      expect(find.text('Ubicación'), findsOneWidget);
      expect(find.text('Acércate al lugar · estás a 500 m'), findsOneWidget);
    });

    testWidgets('photo_and_location: location ✓, photo asks for "Tomar foto"', (tester) async {
      await tester.runAsync(
        () => openMission([_step(0, 'photo_and_location'), _step(1, 'none')]),
      );
      await pumpMissionTab(tester);

      await tester.runAsync(() => walkTo(10));
      await tester.pump();

      expect(find.text('Verificada automáticamente'), findsOneWidget);
      expect(find.text('Foto de verificación'), findsOneWidget);
      expect(find.text('Tomar foto'), findsOneWidget);
    });
  });
}
