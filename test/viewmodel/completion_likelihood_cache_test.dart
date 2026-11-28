import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:sidequests/analytics/analytics_event_sink.dart';
import 'package:sidequests/analytics/analytics_tracker.dart';
import 'package:sidequests/core/app_exception.dart';
import 'package:sidequests/core/completion_likelihood.dart';
import 'package:sidequests/data/context/context_manager.dart';
import 'package:sidequests/data/services/battery_monitor.dart';
import 'package:sidequests/data/services/location_service.dart';
import 'package:sidequests/data/services/step_counter_service.dart';
import 'package:sidequests/models/abandonment_reason.dart';
import 'package:sidequests/models/explore_filters.dart';
import 'package:sidequests/models/photo_proof.dart';
import 'package:sidequests/models/quest.dart';
import 'package:sidequests/models/quest_step.dart';
import 'package:sidequests/models/step_session.dart';
import 'package:sidequests/models/user_quest.dart';
import 'package:sidequests/models/verified_check_in.dart';
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

class _SilentTracker extends AnalyticsTracker {
  _SilentTracker()
    : super(eventSink: _NullSink(), contextManager: _contextManager(), sessionId: 'unused');
}

/// CompletionLikelihood that counts how many times it really computes.
class _CountingLikelihood extends CompletionLikelihood {
  int computations = 0;

  @override
  Map<String, CompletionLevel> byCategory(List<Quest> catalog, List<UserQuest> userQuests) {
    computations++;
    return super.byCategory(catalog, userQuests);
  }
}

Quest _quest(String id, {String category = 'food'}) => Quest(
  id: id,
  title: 'Quest $id',
  category: category,
  durationMinutes: 20,
  difficulty: 'easy',
  locationMode: 'anywhere',
  socialLevel: 'solo',
);

UserQuest _attempt(String id, String questId, String status) => UserQuest(
  id: id,
  userId: 'user-1',
  questId: questId,
  status: status,
  acceptedAt: DateTime(2026, 1, 1),
);

/// Hands out new lists on every load, like the real repository.
class _FakeQuestRepository implements QuestRepository {
  List<Quest> catalog = [_quest('f1'), _quest('f2'), _quest('f3'), _quest('f4')];
  List<UserQuest> userQuests = [];

  @override
  Future<List<Quest>> getCatalog() async => [...catalog];

  /// The attempts can't be fetched, while the catalogue still can.
  bool attemptsFail = false;

  @override
  Future<List<UserQuest>> getUserQuests(String userId) async {
    if (attemptsFail) throw const AppException('Offline');
    return [...userQuests];
  }

  @override
  Future<List<QuestStep>> getSteps(String questId) async => [
    QuestStep(id: 1, questId: questId, stepOrder: 0, title: 'Único paso'),
  ];

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
  Future<void> saveExploreFilters(ExploreFilters filters) async {}

  @override
  StepSession? getActiveStepSession() => null;

  @override
  VerifiedCheckIn? getVerifiedCheckIn() => null;

  @override
  List<PendingPhotoProof> getPendingPhotoProofs() => const [];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late _FakeQuestRepository repository;
  late _CountingLikelihood likelihood;
  late CompletionLikelihoodMemo memo;
  late QuestViewModel viewModel;

  QuestViewModel newViewModel() => QuestViewModel(
    repository,
    _contextManager(),
    _SilentTracker(),
    'user-1',
    completionLikelihood: likelihood,
    completionLikelihoodMemo: memo,
    stepCounter: StepCounterService(requestAccess: () async => StepCounterStatus.unavailable),
  );

  setUp(() async {
    repository = _FakeQuestRepository()
      ..userQuests = [
        _attempt('uq-1', 'f1', 'completed'),
        _attempt('uq-2', 'f2', 'completed'),
        _attempt('uq-3', 'f3', 'in_progress'), // 2 of 3: medium
      ];
    likelihood = _CountingLikelihood();
    memo = CompletionLikelihoodMemo();
    viewModel = newViewModel();
    await viewModel.load();
  });

  CompletionLevel foodLevel() => viewModel.completionLikelihoodByCategory['food']!;

  test('reading it again without new lists does not recompute', () {
    final first = viewModel.completionLikelihoodByCategory;
    viewModel.setMinutes(45); // a rebuild of Explore, same lists
    final second = viewModel.completionLikelihoodByCategory;

    expect(likelihood.computations, 1);
    expect(identical(first, second), isTrue);
    expect(first['food'], CompletionLevel.medium);
  });

  test('a new load (new lists) recomputes, even with the same contents', () async {
    viewModel.completionLikelihoodByCategory;

    await viewModel.load();
    viewModel.completionLikelihoodByCategory;

    expect(likelihood.computations, 2);
  });

  test('only the catalogue replaced (the attempts failed to load) still recomputes', () async {
    expect(foodLevel(), CompletionLevel.medium);
    final attemptsBefore = viewModel.userQuests;

    repository
      ..attemptsFail = true
      ..catalog = [for (final quest in repository.catalog) _quest(quest.id, category: 'art')];
    await viewModel.load();

    expect(identical(viewModel.userQuests, attemptsBefore), isTrue); // same attempts object
    expect(viewModel.completionLikelihoodByCategory.containsKey('food'), isFalse);
    expect(viewModel.completionLikelihoodByCategory['art'], CompletionLevel.medium);
    expect(likelihood.computations, 2);
  });

  test('completing a mission recomputes, and the label follows it', () async {
    expect(foodLevel(), CompletionLevel.medium);
    await viewModel.loadSteps('f3');

    await viewModel.completeCurrentStep(viewModel.currentMission!);

    expect(foodLevel(), CompletionLevel.high); // 3 of 3
    expect(likelihood.computations, 2);
  });

  test('abandoning a mission recomputes', () async {
    viewModel.completionLikelihoodByCategory;

    await viewModel.abandonQuest(viewModel.currentMission!, reason: AbandonmentReason.tooFar);
    viewModel.completionLikelihoodByCategory;

    expect(likelihood.computations, 2);
    expect(viewModel.userQuests.first.status, 'abandoned');
  });

  test('clearing the memo (sign-out) recomputes on the next read', () {
    viewModel.completionLikelihoodByCategory;

    memo.clear();
    viewModel.completionLikelihoodByCategory;

    expect(likelihood.computations, 2);
  });

  test('the shared map cannot be modified by a caller', () {
    expect(
      () => viewModel.completionLikelihoodByCategory['food'] = CompletionLevel.low,
      throwsUnsupportedError,
    );
  });
}
