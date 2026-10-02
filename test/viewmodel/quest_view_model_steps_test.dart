import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:sidequests/analytics/analytics_event_sink.dart';
import 'package:sidequests/analytics/analytics_tracker.dart';
import 'package:sidequests/data/context/context_manager.dart';
import 'package:sidequests/data/services/battery_monitor.dart';
import 'package:sidequests/data/services/location_service.dart';
import 'package:sidequests/data/services/step_counter_service.dart';
import 'package:sidequests/models/photo_proof.dart';
import 'package:sidequests/models/quest.dart';
import 'package:sidequests/models/quest_step.dart';
import 'package:sidequests/models/step_session.dart';
import 'package:sidequests/models/user_quest.dart';
import 'package:sidequests/repository/quest_repository.dart';
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

/// Analytics are not under test here; this just keeps track() offline.
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

final _quest = Quest(
  id: 'a',
  title: 'Quest a',
  category: 'food',
  durationMinutes: 20,
  difficulty: 'easy',
  locationMode: 'anywhere',
  socialLevel: 'solo',
);

QuestStep _step(int order) => QuestStep(id: order, questId: 'a', stepOrder: order, title: 'Step $order');

UserQuest _userQuest(String status, {int currentStep = 0}) => UserQuest(
  id: 'uq-a',
  userId: 'user-1',
  questId: 'a',
  status: status,
  currentStep: currentStep,
  acceptedAt: DateTime(2026, 1, 1),
);

/// In-memory QuestRepository: the backend calls plus the local step
/// storage (what Hive holds in the real one).
class _FakeQuestRepository implements QuestRepository {
  List<UserQuest> userQuests = [];
  List<QuestStep> steps = [_step(1)];
  final Map<String, int> stepTotals = {};
  StepSession? activeSession;
  final List<StepSession?> savedSessions = [];

  @override
  Future<List<Quest>> getCatalog() async => [_quest];

  @override
  Future<List<UserQuest>> getUserQuests(String userId) async => userQuests;

  @override
  Future<UserQuest> acceptQuest({required String userId, required String questId}) async =>
      _userQuest('accepted');

  @override
  Future<List<QuestStep>> getSteps(String questId) async => steps;

  @override
  Future<UserQuest> updateProgress(UserQuest userQuest) async => userQuest;

  @override
  Future<UserQuest> completeQuest(UserQuest userQuest) async =>
      userQuest.copyWithProgress(status: 'completed');

  @override
  Future<UserQuest> abandonQuest(UserQuest userQuest, {required String reason}) async =>
      userQuest.copyWithProgress(status: 'abandoned');

  @override
  Map<String, int> getStepTotals() => stepTotals;

  @override
  Future<void> saveStepTotal(String userQuestId, int steps) async => stepTotals[userQuestId] = steps;

  @override
  StepSession? getActiveStepSession() => activeSession;

  @override
  Future<void> saveActiveStepSession(StepSession? session) async {
    activeSession = session;
    savedSessions.add(session);
  }

  // Photo proof: load() retries pending uploads; there are none here.
  @override
  List<PendingPhotoProof> getPendingPhotoProofs() => const [];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _flush() => Future<void>.delayed(Duration.zero);

void main() {
  late StreamController<int> sensor;
  late Future<StepCounterStatus> Function() requestAccess;
  late _FakeQuestRepository repository;
  late QuestViewModel viewModel;

  setUp(() {
    sensor = StreamController<int>.broadcast();
    requestAccess = () async => StepCounterStatus.counting;
    repository = _FakeQuestRepository();
    viewModel = QuestViewModel(
      repository,
      _contextManager(),
      _SilentTracker(),
      'user-1',
      stepCounter: StepCounterService(
        cumulativeSteps: () => sensor.stream,
        requestAccess: () => requestAccess(),
        openSettings: () async => true,
      ),
    );
  });

  Future<void> walk(List<int> cumulativeReadings) async {
    cumulativeReadings.forEach(sensor.add);
    await _flush();
  }

  test('accepting a quest starts counting; completing it saves the attempt total locally', () async {
    await viewModel.acceptQuest('a');
    await _flush();

    expect(viewModel.stepStatus, StepCounterStatus.counting);
    expect(viewModel.stepTrackedUserQuestId, 'uq-a');
    expect(viewModel.missionSteps, isNull); // no reading yet ≠ 0 steps

    await walk([5000, 5080]); // 5000 since boot when the mission started
    expect(viewModel.missionSteps, 80);

    await viewModel.loadSteps('a');
    final completed = await viewModel.completeCurrentStep(viewModel.currentMission!);

    expect(completed, isTrue);
    expect(repository.stepTotals, {'uq-a': 80});
    expect(repository.activeSession, isNull);
    expect(viewModel.stepStatus, StepCounterStatus.idle);
  });

  test('abandoning saves the attempt total and stops counting', () async {
    await viewModel.acceptQuest('a');
    await _flush();
    await walk([100, 145]);

    await viewModel.abandonQuest(viewModel.currentMission!, reason: 'no_time');

    expect(repository.stepTotals, {'uq-a': 45});
    expect(repository.activeSession, isNull);
    expect(viewModel.stepTrackedUserQuestId, isNull);
  });

  test('permission denied: the mission works, nothing is counted or stored', () async {
    requestAccess = () async => StepCounterStatus.permissionDenied;

    await viewModel.acceptQuest('a');
    await _flush();

    expect(viewModel.currentMission?.status, 'accepted');
    expect(viewModel.stepStatus, StepCounterStatus.permissionDenied);
    expect(viewModel.missionSteps, isNull);
    expect(repository.savedSessions, isEmpty);
  });

  test('retry after a denial starts counting once the permission is granted', () async {
    requestAccess = () async => StepCounterStatus.permissionDenied;
    await viewModel.acceptQuest('a');
    await _flush();

    requestAccess = () async => StepCounterStatus.counting;
    await viewModel.retryStepTracking();

    expect(viewModel.stepStatus, StepCounterStatus.counting);
    expect(viewModel.stepTrackedUserQuestId, 'uq-a');
  });

  test('app restart mid-mission: load() resumes the persisted session, including steps walked while closed', () async {
    repository.userQuests = [_userQuest('in_progress')];
    repository.activeSession = const StepSession(userQuestId: 'uq-a', baseline: 1000, lastReading: 1050);

    await viewModel.load();
    await _flush();
    await walk([1300]);

    expect(viewModel.stepTrackedUserQuestId, 'uq-a');
    expect(viewModel.missionSteps, 300);
  });

  test('resuming an abandoned attempt keeps adding to its saved total', () async {
    repository.userQuests = [_userQuest('abandoned')];
    repository.stepTotals['uq-a'] = 500;
    repository.steps = [_step(1), _step(2)];
    await viewModel.load();
    await viewModel.loadSteps('a');
    expect(viewModel.stepTrackedUserQuestId, isNull); // abandoned: paused

    await viewModel.completeCurrentStep(viewModel.currentMission!); // step 1 of 2 → in_progress
    await _flush();
    expect(viewModel.missionSteps, 500);

    await walk([20, 50]);
    expect(viewModel.missionSteps, 530);
  });

  test('the active session is written on start, on the first reading and every 25 steps — not on every reading', () async {
    await viewModel.acceptQuest('a');
    await _flush();
    expect(repository.savedSessions, hasLength(1)); // start, no baseline yet

    await walk([1000]); // baseline → persisted
    await walk([1010]); // +10 → skipped
    await walk([1030]); // +30 since last write → persisted

    expect(repository.savedSessions, hasLength(3));
    expect(repository.activeSession!.steps, 30);
  });

  test('abandoning while the permission dialog is still up never starts counting', () async {
    final permission = Completer<StepCounterStatus>();
    requestAccess = () => permission.future;

    await viewModel.acceptQuest('a');
    await viewModel.abandonQuest(viewModel.currentMission!, reason: 'no_time');
    permission.complete(StepCounterStatus.counting);
    await _flush();

    expect(viewModel.stepTrackedUserQuestId, isNull);
    expect(repository.activeSession, isNull);
  });
}
