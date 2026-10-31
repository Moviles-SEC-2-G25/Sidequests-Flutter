import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:provider/provider.dart';
import 'package:sidequests/analytics/analytics_event_sink.dart';
import 'package:sidequests/analytics/analytics_event_type.dart';
import 'package:sidequests/analytics/analytics_tracker.dart';
import 'package:sidequests/core/app_exception.dart';
import 'package:sidequests/core/verification/step_verification_strategy.dart';
import 'package:sidequests/data/context/context_manager.dart';
import 'package:sidequests/data/services/battery_monitor.dart';
import 'package:sidequests/data/services/location_check_in_service.dart';
import 'package:sidequests/data/services/location_service.dart';
import 'package:sidequests/data/services/step_counter_service.dart';
import 'package:sidequests/data/services/weather_service.dart';
import 'package:sidequests/models/abandonment_reason.dart';
import 'package:sidequests/models/photo_proof.dart';
import 'package:sidequests/models/quest.dart';
import 'package:sidequests/models/quest_step.dart';
import 'package:sidequests/models/step_session.dart';
import 'package:sidequests/models/user_preferences.dart';
import 'package:sidequests/models/user_quest.dart';
import 'package:sidequests/models/verified_check_in.dart';
import 'package:sidequests/repository/quest_repository.dart';
import 'package:sidequests/view/quests/abandon_mission_view.dart';
import 'package:sidequests/view/quests/mission_tab_view.dart';
import 'package:sidequests/view/quests/quest_detail_view.dart';
import 'package:sidequests/viewmodel/profile/profile_view_model.dart';
import 'package:sidequests/viewmodel/quests/quest_view_model.dart';

/// What QuestRepository now throws when a write gets no answer.
const _offlineError = AppException(
  'Sin conexión: no se pudo guardar el cambio. Inténtalo de nuevo cuando tengas internet.',
  isRetryable: true,
);

const _quest = Quest(
  id: 'a',
  title: 'Quest a',
  category: 'food',
  durationMinutes: 20,
  difficulty: 'easy',
  locationMode: 'gps',
  socialLevel: 'solo',
);

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

class _SpyTracker extends AnalyticsTracker {
  final List<String> tracked = [];

  _SpyTracker()
    : super(
        eventSink: _NullSink(),
        contextManager: ContextManager(locationService: _NoLocation(), batteryMonitor: _FullBattery()),
        sessionId: 'unused',
      );

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
  }) async => tracked.add(eventType);

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
  }) async => tracked.add(eventType);
}

class _FakeProfile extends ChangeNotifier implements ProfileViewModel {
  @override
  UserPreferences get preferences => const UserPreferences();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

QuestStep _step(int order) =>
    QuestStep(id: order, questId: 'a', stepOrder: order, title: 'Step $order', verificationType: 'none');

/// [offline] makes the mission writes fail the way QuestRepository reports
/// a dropped connection.
class _FakeQuestRepository implements QuestRepository {
  bool offline = false;
  List<QuestStep> steps = const [];
  final UserQuest mission = UserQuest(
    id: 'uq-a',
    userId: 'user-1',
    questId: 'a',
    status: 'in_progress',
    acceptedAt: DateTime(2026, 1, 1),
  );

  @override
  Future<List<Quest>> getCatalog() async => [_quest];

  @override
  Future<List<UserQuest>> getUserQuests(String userId) async => [mission];

  @override
  Future<List<QuestStep>> getSteps(String questId) async => steps;

  @override
  Future<UserQuest> updateProgress(UserQuest userQuest) async {
    if (offline) throw _offlineError;
    return userQuest;
  }

  @override
  Future<UserQuest> completeQuest(UserQuest userQuest) async {
    if (offline) throw _offlineError;
    return userQuest.copyWithProgress(status: 'completed');
  }

  @override
  Future<UserQuest> acceptQuest({required String userId, required String questId}) async {
    if (offline) throw _offlineError;
    return UserQuest(
      id: 'uq-new',
      userId: userId,
      questId: questId,
      status: 'accepted',
      acceptedAt: DateTime(2026, 10, 27),
    );
  }

  @override
  Future<({UserQuest userQuest, bool queued})> abandonQuestOrQueue(
    UserQuest userQuest, {
    required String reason,
  }) async {
    if (offline) throw _offlineError;
    return (userQuest: userQuest.copyWithProgress(status: 'abandoned'), queued: false);
  }

  // Podómetro and photo proofs: nothing stored in these tests.
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

void main() {
  late _FakeQuestRepository repository;
  late _SpyTracker tracker;
  late QuestViewModel viewModel;

  setUp(() {
    repository = _FakeQuestRepository();
    tracker = _SpyTracker();
    viewModel = QuestViewModel(
      repository,
      ContextManager(locationService: _NoLocation(), batteryMonitor: _FullBattery()),
      tracker,
      'user-1',
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

  group('abandoning when it cannot even stay on the device', () {
    test('reports failure, keeps the mission active and tracks nothing', () async {
      await viewModel.load();
      repository.offline = true;

      final saved = await viewModel.abandonQuest(repository.mission, reason: AbandonmentReason.tooFar);

      expect(saved, isFalse);
      expect(viewModel.errorMessage, startsWith('Sin conexión'));
      expect(viewModel.currentMission?.status, 'in_progress');
      expect(tracker.tracked, isNot(contains(AnalyticsEventType.questAbandoned)));
    });

    test('online it still abandons and tracks quest_abandoned', () async {
      await viewModel.load();

      expect(await viewModel.abandonQuest(repository.mission, reason: AbandonmentReason.tooFar), isTrue);
      expect(tracker.tracked, contains(AnalyticsEventType.questAbandoned));
    });

    testWidgets('the screen stays, says why, and lets the user try again', (tester) async {
      repository.offline = true;
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<QuestViewModel>.value(value: viewModel),
            ChangeNotifierProvider<ProfileViewModel>.value(value: _FakeProfile()),
          ],
          child: MaterialApp(home: AbandonMissionView(mission: repository.mission, totalSteps: 3)),
        ),
      );

      await tester.ensureVisible(find.text('Empezar otra misión'));
      await tester.tap(find.text('Empezar otra misión'));
      await tester.pump(); // the write fails
      await tester.pump(); // SnackBar in

      expect(find.textContaining('Sin conexión'), findsOneWidget);
      expect(find.byType(AbandonMissionView), findsOneWidget);
      final button = tester.widget<OutlinedButton>(
        find.widgetWithText(OutlinedButton, 'Empezar otra misión'),
      );
      expect(button.onPressed, isNotNull);
    });
  });

  group('completing a step offline', () {
    Future<void> openMission() async {
      repository.steps = [_step(0), _step(1)];
      await viewModel.load();
      await viewModel.loadSteps('a');
    }

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

    test('says why, leaves the step where it was and tracks nothing', () async {
      await openMission();
      repository.offline = true;

      final completedQuest = await viewModel.completeCurrentStep(viewModel.currentMission!);

      expect(completedQuest, isFalse);
      expect(viewModel.stepErrorMessage, startsWith('Sin conexión'));
      expect(viewModel.currentMission!.currentStep, 0);
      expect(viewModel.isCompletingStep, isFalse);
      expect(tracker.tracked, isNot(contains(AnalyticsEventType.questCompleted)));
    });

    test('the next attempt that goes through clears the error and advances', () async {
      await openMission();
      repository.offline = true;
      await viewModel.completeCurrentStep(viewModel.currentMission!);

      repository.offline = false;
      final completedQuest = await viewModel.completeCurrentStep(viewModel.currentMission!);

      expect(completedQuest, isFalse); // a middle step: same return as before
      expect(viewModel.stepErrorMessage, isNull);
      expect(viewModel.currentMission!.currentStep, 1);
    });

    testWidgets('"Completar" offline shows why and can be tapped again', (tester) async {
      await tester.runAsync(openMission);
      repository.offline = true;
      await pumpMissionTab(tester);

      await tester.ensureVisible(find.text('Completar este paso →'));
      await tester.tap(find.text('Completar este paso →'));
      await tester.pump(); // the write fails
      await tester.pump(); // SnackBar in

      expect(find.textContaining('Sin conexión'), findsOneWidget);
      expect(viewModel.currentMission!.currentStep, 0);
      final button = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Completar este paso →'),
      );
      expect(button.onPressed, isNotNull);
    });

    testWidgets('"Completar" online still just advances, with no message', (tester) async {
      await tester.runAsync(openMission);
      await pumpMissionTab(tester);

      await tester.ensureVisible(find.text('Completar este paso →'));
      await tester.tap(find.text('Completar este paso →'));
      await tester.pump();
      await tester.pump();

      expect(find.byType(SnackBar), findsNothing);
      expect(viewModel.currentMission!.currentStep, 1);
      expect(find.text('Completar misión →'), findsOneWidget);
    });
  });

  group('accepting offline', () {
    test('reports failure and starts nothing', () async {
      repository.offline = true;

      expect(await viewModel.acceptQuest('a'), isFalse);
      expect(viewModel.errorMessage, startsWith('Sin conexión'));
      expect(tracker.tracked, isEmpty);
    });

    testWidgets('the detail stays, says why, and the button works again', (tester) async {
      repository.offline = true;
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<QuestViewModel>.value(value: viewModel),
            Provider<LocationService>.value(value: _NoLocation()),
            Provider<WeatherService>.value(value: WeatherService()),
          ],
          child: const MaterialApp(home: QuestDetailView(quest: _quest)),
        ),
      );
      await tester.pump(); // steps load after the first frame

      await tester.ensureVisible(find.text('Aceptar misión →'));
      await tester.tap(find.text('Aceptar misión →'));
      await tester.pump(); // the write fails
      await tester.pump(); // SnackBar in

      expect(find.textContaining('Sin conexión'), findsOneWidget);
      expect(find.byType(QuestDetailView), findsOneWidget);
      final button = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Aceptar misión →'),
      );
      expect(button.onPressed, isNotNull);
    });
  });
}
