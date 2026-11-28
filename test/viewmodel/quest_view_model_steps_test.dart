import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:geolocator/geolocator.dart';
import 'package:sidequests/analytics/analytics_event_sink.dart';
import 'package:sidequests/analytics/analytics_tracker.dart';
import 'package:sidequests/data/context/context_manager.dart';
import 'package:sidequests/data/local/local_data_source.dart';
import 'package:sidequests/data/local/step_log_database.dart';
import 'package:sidequests/data/remote/supabase_remote_data_source.dart';
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
import 'package:sidequests/view/widgets/offline_notice.dart';
import 'package:sidequests/viewmodel/context/connectivity_view_model.dart';
import 'package:sidequests/viewmodel/quests/quest_view_model.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

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

  /// Walks handed to logWalk; with [walkLog] they also go through a real
  /// repository, so its own error handling is the one under test.
  final List<StepLogEntry> walks = [];
  QuestRepository? walkLog;

  /// The id acceptQuest gives the next attempt.
  String nextAttemptId = 'uq-a';

  @override
  Future<void> logWalk(StepLogEntry walk) async {
    walks.add(walk);
    await walkLog?.logWalk(walk);
  }

  List<Quest> catalog = [_quest];

  @override
  Future<List<Quest>> getCatalog() async => catalog;

  @override
  Future<List<UserQuest>> getUserQuests(String userId) async => userQuests;

  @override
  Future<UserQuest> acceptQuest({required String userId, required String questId}) async =>
      UserQuest(
        id: nextAttemptId,
        userId: 'user-1',
        questId: questId,
        status: 'accepted',
        acceptedAt: DateTime(2026, 1, 1),
      );

  @override
  Future<List<QuestStep>> getSteps(String questId) async => steps;

  @override
  Future<UserQuest> updateProgress(UserQuest userQuest) async => userQuest;

  @override
  Future<UserQuest> completeQuest(UserQuest userQuest) async =>
      userQuest.copyWithProgress(status: 'completed');

  @override
  Future<({UserQuest userQuest, bool queued})> abandonQuestOrQueue(
    UserQuest userQuest, {
    required String reason,
  }) async => (userQuest: userQuest.copyWithProgress(status: 'abandoned'), queued: false);

  @override
  Map<String, int> getStepTotals() => stepTotals;

  @override
  Future<void> saveStepTotal(String userQuestId, int steps) async => stepTotals[userQuestId] = steps;

  @override
  StepSession? getActiveStepSession() => activeSession;

  @override
  VerifiedCheckIn? getVerifiedCheckIn() => null;

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
  final now = DateTime.utc(2026, 11, 26, 15);

  setUpAll(sqfliteFfiInit);

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
      now: () => now,
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

    await viewModel.abandonQuest(viewModel.currentMission!, reason: AbandonmentReason.ranOutOfTime);

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

  test('an abandoned attempt is closed: it is not the current mission and counts nothing', () async {
    repository.userQuests = [_userQuest('abandoned')];
    repository.stepTotals['uq-a'] = 500;
    repository.steps = [_step(1), _step(2)];
    await viewModel.load();
    await viewModel.loadSteps('a');
    await _flush();

    expect(viewModel.currentMission, isNull);
    expect(viewModel.stepTrackedUserQuestId, isNull);
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
    await viewModel.abandonQuest(viewModel.currentMission!, reason: AbandonmentReason.ranOutOfTime);
    permission.complete(StepCounterStatus.counting);
    await _flush();

    expect(viewModel.stepTrackedUserQuestId, isNull);
    expect(repository.activeSession, isNull);
  });

  group('Misión tab: podómetro (ES12)', () {
    Future<void> pumpMission(WidgetTester tester, {bool offline = false}) async {
      await tester.runAsync(() async {
        await viewModel.load();
        await viewModel.acceptQuest('a');
        await viewModel.loadSteps('a');
        await _flush();
      });
      tester.view.physicalSize = const Size(360, 690);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<QuestViewModel>.value(value: viewModel),
            ChangeNotifierProvider(
              create: (_) => ConnectivityViewModel(connectivity: _StaticConnectivity(offline: offline)),
            ),
          ],
          child: const MaterialApp(home: MissionTabView()),
        ),
      );
      await tester.pump();
    }

    testWidgets('no permission: says how to allow it, with "Allow"', (tester) async {
      requestAccess = () async => StepCounterStatus.permissionDenied;

      await pumpMission(tester);

      expect(find.text('Turn on "Physical activity" to count them during the quest.'), findsOneWidget);
      expect(find.text('Allow'), findsOneWidget);
    });

    testWidgets('no sensor: says the phone has no step counter', (tester) async {
      requestAccess = () async => StepCounterStatus.unavailable;

      await pumpMission(tester);

      expect(find.text('Your phone has no step counter.'), findsOneWidget);
    });

    testWidgets('offline it keeps counting and adds no notice of its own', (tester) async {
      await pumpMission(tester, offline: true);
      await tester.runAsync(() => walk([3000, 3042]));
      await tester.pump();

      expect(find.text('42 steps walked'), findsOneWidget);
      // The only offline notice is the mission's own: nothing about the steps.
      expect(find.byType(OfflineNotice), findsOneWidget);
      expect(find.text(OfflineMessages.missionProgress), findsOneWidget);
    });
  });

  group('step log (SQLite)', () {
    /// Accepted with the catalogue loaded, so the walk knows its category.
    Future<void> startWalking() async {
      await viewModel.load();
      await viewModel.acceptQuest('a');
      await _flush();
    }

    Future<void> finishLastStep() async {
      await viewModel.loadSteps('a');
      await viewModel.completeCurrentStep(viewModel.currentMission!);
    }

    test('completing logs the walk as completed, with quest, category, steps and time', () async {
      // Stored lowercased, like CompletionLikelihood, so "Food" and "food" group together.
      repository.catalog = [
        Quest(
          id: 'a',
          title: 'Quest a',
          category: 'Food',
          durationMinutes: 20,
          difficulty: 'easy',
          locationMode: 'anywhere',
          socialLevel: 'solo',
        ),
      ];
      await startWalking();
      await walk([5000, 5080]);

      await finishLastStep();

      final logged = repository.walks.single;
      expect(logged.toRow(), {
        'attempt_id': 'uq-a',
        'quest_id': 'a',
        'category': 'food',
        'steps': 80,
        'outcome': 'completed',
        'finished_at': now.millisecondsSinceEpoch,
      });
      expect(repository.stepTotals, {'uq-a': 80}); // Hive, untouched
    });

    test('abandoning logs it as abandoned', () async {
      await startWalking();
      await walk([100, 145]);

      await viewModel.abandonQuest(viewModel.currentMission!, reason: AbandonmentReason.tooFar);

      expect(repository.walks.single.outcome, StepLogEntry.abandoned);
      expect(repository.walks.single.steps, 45);
    });

    test('a walk without steps is not logged', () async {
      await startWalking();
      await walk([700]); // a first reading only: 0 steps

      await finishLastStep();

      expect(repository.walks, isEmpty);
    });

    test('no reading at all: nothing logged either', () async {
      await startWalking();

      await finishLastStep();

      expect(repository.walks, isEmpty);
    });

    test('banking an attempt because another quest was accepted is not a finished walk', () async {
      await startWalking();
      await walk([100, 160]);

      repository.nextAttemptId = 'uq-b';
      await viewModel.acceptQuest('a');
      await _flush();

      expect(repository.stepTotals, {'uq-a': 60});
      expect(repository.walks, isEmpty);
    });

    test('a broken SQLite never stops completing or abandoning', () async {
      final notADatabase = await Directory.systemTemp.createTemp('step_log_broken');
      addTearDown(() => notADatabase.delete(recursive: true));
      repository.walkLog = QuestRepository(
        _UnusedRemote(),
        _UnusedLocal(),
        stepLog: StepLogDatabase(factory: databaseFactoryFfiNoIsolate, path: notADatabase.path),
      );
      await startWalking();
      await walk([1000, 1100]);

      await finishLastStep();

      expect(viewModel.currentMission, isNull); // completed
      expect(viewModel.stepErrorMessage, isNull);
      expect(repository.walks, hasLength(1)); // it was tried
      expect(repository.stepTotals, {'uq-a': 100});
    });
  });
}

/// The step log needs neither: only the SQLite part of the repository runs.
class _UnusedRemote implements SupabaseRemoteDataSource {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _UnusedLocal implements LocalDataSource {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A device that is online or offline for the whole test.
class _StaticConnectivity implements Connectivity {
  final bool offline;

  _StaticConnectivity({required this.offline});

  @override
  Future<List<ConnectivityResult>> checkConnectivity() async =>
      [offline ? ConnectivityResult.none : ConnectivityResult.wifi];

  @override
  Stream<List<ConnectivityResult>> get onConnectivityChanged => const Stream.empty();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
