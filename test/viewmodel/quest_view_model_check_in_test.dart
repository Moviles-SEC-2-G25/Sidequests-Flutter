import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:provider/provider.dart';
import 'package:sidequests/analytics/analytics_event_sink.dart';
import 'package:sidequests/analytics/analytics_tracker.dart';
import 'package:sidequests/core/app_exception.dart';
import 'package:sidequests/core/verification/step_verification_strategy.dart';
import 'package:sidequests/data/context/context_manager.dart';
import 'package:sidequests/data/services/battery_monitor.dart';
import 'package:sidequests/data/services/location_check_in_service.dart';
import 'package:sidequests/data/services/location_service.dart';
import 'package:sidequests/data/services/step_counter_service.dart';
import 'package:sidequests/models/abandonment_reason.dart';
import 'package:sidequests/models/photo_proof.dart';
import 'package:sidequests/models/quest.dart';
import 'package:sidequests/models/quest_step.dart';
import 'package:sidequests/models/step_session.dart';
import 'package:sidequests/models/user_quest.dart';
import 'package:sidequests/models/verified_check_in.dart';
import 'package:sidequests/repository/quest_repository.dart';
import 'package:sidequests/view/quests/mission_tab_view.dart';
import 'package:sidequests/viewmodel/quests/quest_view_model.dart';

const _questLat = 4.6473;
const _questLon = -74.0600;
const _degPerMeter = 1 / 111195;
const _savedNotice = '📍 Llegaste. Se guardará cuando vuelvas a tener conexión.';
const _noConnection = AppException('Sin conexión', isRetryable: true);

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

  /// What updateProgress/completeQuest throw: no connection, or a rejection.
  AppException? writeError;
  Completer<void>? writeGate;
  int writeAttempts = 0;
  VerifiedCheckIn? verifiedCheckIn;
  List<QuestPhotoProof> photoProofs = const [];

  @override
  VerifiedCheckIn? getVerifiedCheckIn() => verifiedCheckIn;

  @override
  Future<void> saveVerifiedCheckIn(VerifiedCheckIn? checkIn) async => verifiedCheckIn = checkIn;

  @override
  Future<List<Quest>> getCatalog() async => [quest];

  @override
  Future<List<UserQuest>> getUserQuests(String userId) async => userQuests;

  @override
  Future<List<QuestStep>> getSteps(String questId) async => steps;

  @override
  Future<UserQuest> updateProgress(UserQuest userQuest) async {
    writeAttempts++;
    await writeGate?.future;
    if (writeError != null) throw writeError!;
    progressUpdates.add(userQuest);
    userQuests = [userQuest];
    return userQuest;
  }

  @override
  Future<UserQuest> completeQuest(UserQuest userQuest) async {
    writeAttempts++;
    if (writeError != null) throw writeError!;
    final completed = userQuest.copyWithProgress(status: 'completed');
    completions.add(completed);
    userQuests = [completed];
    return completed;
  }

  @override
  Future<({UserQuest userQuest, bool queued})> abandonQuestOrQueue(
    UserQuest userQuest, {
    required String reason,
  }) async => (userQuest: userQuest.copyWithProgress(status: 'abandoned'), queued: false);

  // Podómetro storage: unused here (the step counter is unavailable).
  @override
  StepSession? getActiveStepSession() => null;

  // Photo proof: none uploaded or pending in these tests.
  @override
  List<PendingPhotoProof> getPendingPhotoProofs() => const [];

  @override
  Future<List<QuestPhotoProof>> getPhotoProofs(String attemptId) async => photoProofs;

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
  late DateTime now;

  QuestViewModel newViewModel() => QuestViewModel(
    repository,
    _contextManager(),
    _SilentTracker(),
    'user-1',
    stepCounter: StepCounterService(
      requestAccess: () async => StepCounterStatus.unavailable,
    ),
    locationCheckIn: checkIn,
    now: () => now,
  );

  setUp(() {
    now = DateTime.utc(2026, 10, 31, 15);
    repository = _FakeQuestRepository();
    gps = StreamController<CheckInFix>.broadcast();
    gpsSubscriptions = 0;
    requestAccess = () async => LocationAccess.granted;
    checkIn = LocationCheckInService(
      requestAccess: () => requestAccess(),
      isLowBattery: () async => false,
      isOffline: () async => false,
      offlineChanges: () => const Stream.empty(),
      positions: (_, _) {
        gpsSubscriptions++;
        return gps.stream;
      },
    );
    viewModel = newViewModel();
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

    await viewModel.abandonQuest(viewModel.currentMission!, reason: AbandonmentReason.ranOutOfTime);

    expect(checkIn.isWatching, isFalse);
  });

  group('verified without a connection', () {
    final twoSteps = [_step(0, 'location'), _step(1, 'none')];

    Future<void> arriveOffline(List<QuestStep> steps) async {
      await openMission(steps);
      repository.writeError = _noConnection;
      await walkTo(20);
    }

    /// A step already verified earlier, as a fresh launch would find it.
    void savedFor(int stepIndex, {String attempt = 'uq-a'}) {
      repository.verifiedCheckIn = VerifiedCheckIn(
        userQuestId: attempt,
        stepIndex: stepIndex,
        verifiedAt: DateTime.utc(2026, 10, 31, 9),
      );
    }

    UserQuest attemptAt(int step, {String status = 'in_progress'}) => UserQuest(
      id: 'uq-a',
      userId: 'user-1',
      questId: 'a',
      status: status,
      currentStep: step,
      completedSteps: [for (var i = 0; i < step; i++) i],
      acceptedAt: DateTime(2026, 1, 1),
    );

    test('saves attempt, step and time; the step stays and nothing is announced', () async {
      await arriveOffline(twoSteps);

      final saved = repository.verifiedCheckIn!;
      expect(saved.userQuestId, 'uq-a');
      expect(saved.stepIndex, 0);
      expect(saved.verifiedAt, now);
      expect(viewModel.isCheckInSavedForCurrentStep, isTrue);
      expect(viewModel.currentMission!.currentStep, 0);
      expect(repository.progressUpdates, isEmpty);
      expect(events, isEmpty);
    });

    test('stops retrying on every GPS fix, even past the 30 s between attempts', () async {
      await arriveOffline(twoSteps);
      expect(repository.writeAttempts, 1);

      now = now.add(const Duration(minutes: 5));
      await walkTo(15);
      now = now.add(const Duration(minutes: 5));
      await walkTo(10);

      expect(repository.writeAttempts, 1);
      expect(repository.verifiedCheckIn!.verifiedAt, DateTime.utc(2026, 10, 31, 15));
    });

    test('a rejection is not a lack of connection: nothing is saved', () async {
      await openMission(twoSteps);
      repository.writeError = const AppException('new row violates RLS');

      await walkTo(20);

      expect(repository.verifiedCheckIn, isNull);
      expect(viewModel.isCheckInSavedForCurrentStep, isFalse);
    });

    test('reconnecting (load) completes the step, clears the mark and announces it', () async {
      await arriveOffline(twoSteps);

      repository.writeError = null;
      await viewModel.load();

      expect(repository.progressUpdates.single.currentStep, 1);
      expect(repository.progressUpdates.single.completedSteps, [0]);
      expect(repository.verifiedCheckIn, isNull);
      expect(viewModel.isCheckInSavedForCurrentStep, isFalse);
      expect(viewModel.currentMission!.currentStep, 1);
      await _flush();
      expect(events.single.completedQuest, isFalse);
    });

    test('still without a connection: one more try per load, and the original time stays', () async {
      await arriveOffline(twoSteps);
      final verifiedAt = repository.verifiedCheckIn!.verifiedAt;

      now = now.add(const Duration(hours: 1));
      await viewModel.load();

      expect(repository.writeAttempts, 2);
      expect(repository.verifiedCheckIn!.verifiedAt, verifiedAt);
      expect(viewModel.isCheckInSavedForCurrentStep, isTrue);
      expect(viewModel.currentMission!.currentStep, 0);
      expect(events, isEmpty);
    });

    test('coming back to the foreground also completes it', () async {
      await arriveOffline(twoSteps);
      repository.writeError = null;

      viewModel.setForeground(false);
      viewModel.setForeground(true);
      await _flush();
      await _flush();

      expect(repository.progressUpdates, hasLength(1));
      expect(repository.verifiedCheckIn, isNull);
    });

    test('after an app restart, steps not loaded yet: completes it', () async {
      repository.steps = twoSteps;
      savedFor(0);

      await newViewModel().load();

      expect(repository.progressUpdates.single.currentStep, 1);
      expect(repository.verifiedCheckIn, isNull);
    });

    test('after an app restart, on the last step: completes the mission, not just the step', () async {
      repository.steps = [_step(0, 'none'), _step(1, 'location')];
      repository.userQuests = [attemptAt(1)];
      savedFor(1);

      await newViewModel().load();

      expect(repository.completions, hasLength(1));
      expect(repository.progressUpdates, isEmpty);
      expect(repository.verifiedCheckIn, isNull);
    });

    test('several loads at once complete the step only once', () async {
      repository.steps = twoSteps;
      savedFor(0);

      await Future.wait([viewModel.load(), viewModel.load(), viewModel.load()]);

      expect(repository.progressUpdates, hasLength(1));
    });

    test('a load arriving during a write that then fails keeps the mark and its original time', () async {
      repository.steps = twoSteps;
      savedFor(0);
      final verifiedAt = repository.verifiedCheckIn!.verifiedAt;
      repository.writeError = _noConnection;
      repository.writeGate = Completer<void>();

      final first = viewModel.load();
      await pumpEventQueue();
      expect(repository.writeAttempts, 1);

      await viewModel.load(); // finds the step being completed
      expect(repository.verifiedCheckIn?.verifiedAt, verifiedAt);

      repository.writeGate!.complete();
      await first;

      expect(repository.writeAttempts, 1);
      expect(repository.verifiedCheckIn?.verifiedAt, verifiedAt);
    });

    test('obsolete: the user advanced by hand, so the mark is only dropped', () async {
      repository.steps = twoSteps;
      repository.userQuests = [attemptAt(1)];
      savedFor(0);

      await viewModel.load();

      expect(repository.verifiedCheckIn, isNull);
      expect(repository.writeAttempts, 0);
      expect(viewModel.currentMission!.currentStep, 1);
      expect(events, isEmpty);
    });

    test('obsolete: the mission is no longer active', () async {
      for (final status in ['completed', 'abandoned']) {
        repository.steps = twoSteps;
        repository.userQuests = [attemptAt(0, status: status)];
        savedFor(0);

        await viewModel.load();

        expect(repository.verifiedCheckIn, isNull, reason: status);
        expect(repository.writeAttempts, 0, reason: status);
      }
    });

    test('obsolete: it belongs to another attempt', () async {
      repository.steps = twoSteps;
      savedFor(0, attempt: 'uq-old');

      await viewModel.load();

      expect(repository.verifiedCheckIn, isNull);
      expect(repository.writeAttempts, 0);
    });

    test('nothing known yet (offline, empty cache): the mark is kept', () async {
      repository.steps = twoSteps;
      repository.userQuests = [];
      savedFor(0);

      await viewModel.load();

      expect(repository.verifiedCheckIn, isNotNull);
    });

    test('the server rejects it on reconnecting: the mark does not retry forever', () async {
      repository.steps = twoSteps;
      savedFor(0);
      repository.writeError = const AppException('new row violates RLS');

      await viewModel.load();

      expect(repository.verifiedCheckIn, isNull);
      expect(events, isEmpty);
    });

    group('photo_and_location', () {
      final photoSteps = [_step(0, 'photo_and_location'), _step(1, 'none')];
      final proof = QuestPhotoProof(
        id: 'p-1',
        attemptId: 'uq-a',
        stepOrder: 0,
        storagePath: 'user-1/uq-a/a/step-1-x.jpg',
        uploadedAt: DateTime.utc(2026, 10, 31),
      );

      test('with the photo registered, it is saved offline like any other', () async {
        repository.photoProofs = [proof];

        await arriveOffline(photoSteps);

        expect(repository.verifiedCheckIn, isNotNull);
        expect(repository.writeAttempts, 1);
      });

      test('being there is not enough: no photo, no write, and no mark either', () async {
        await arriveOffline(photoSteps);

        expect(repository.writeAttempts, 0);
        expect(repository.verifiedCheckIn, isNull);
      });

      test('a saved mark without its photo does not complete the step and waits', () async {
        repository.steps = photoSteps;
        savedFor(0);

        await viewModel.load();

        expect(repository.writeAttempts, 0);
        expect(repository.verifiedCheckIn, isNotNull);
        expect(viewModel.isCheckInSavedForCurrentStep, isTrue);
      });

      test('once the photo is registered, the saved mark completes the step', () async {
        repository.steps = photoSteps;
        savedFor(0);
        await viewModel.load();

        repository.photoProofs = [proof];
        await viewModel.load();

        expect(repository.progressUpdates.single.currentStep, 1);
        expect(repository.verifiedCheckIn, isNull);
      });
    });

    test('a manual step without location is untouched by any of this', () async {
      await openMission([_step(0, 'none'), _step(1, 'none')]);
      repository.writeError = _noConnection;

      await viewModel.completeCurrentStep(viewModel.currentMission!);

      expect(viewModel.stepErrorMessage, 'Sin conexión');
      expect(repository.verifiedCheckIn, isNull);
    });
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

    testWidgets('verified offline: the step says so, even after walking away', (tester) async {
      await tester.runAsync(() => openMission([_step(0, 'location'), _step(1, 'none')]));
      await pumpMissionTab(tester);
      expect(find.text(_savedNotice), findsNothing);

      repository.writeError = _noConnection;
      await tester.runAsync(() => walkTo(20));
      await tester.pump();
      expect(find.text(_savedNotice), findsOneWidget);
      expect(find.text('Verificada automáticamente'), findsNothing);

      await tester.runAsync(() => walkTo(500));
      await tester.pump();
      expect(find.text(_savedNotice), findsOneWidget);

      repository.writeError = null;
      await tester.runAsync(() => viewModel.load());
      await tester.pump();
      expect(find.text(_savedNotice), findsNothing);
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
