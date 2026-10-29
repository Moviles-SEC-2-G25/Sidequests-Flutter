import 'package:connectivity_plus/connectivity_plus.dart';
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
import 'package:sidequests/models/app_context.dart';
import 'package:sidequests/models/photo_proof.dart';
import 'package:sidequests/models/profile.dart';
import 'package:sidequests/models/quest.dart';
import 'package:sidequests/models/quest_recommendation.dart';
import 'package:sidequests/models/quest_step.dart';
import 'package:sidequests/models/step_session.dart';
import 'package:sidequests/models/user_preferences.dart';
import 'package:sidequests/models/user_quest.dart';
import 'package:sidequests/repository/auth_repository.dart';
import 'package:sidequests/repository/profile_repository.dart';
import 'package:sidequests/repository/quest_repository.dart';
import 'package:sidequests/view/profile/edit_preferences_view.dart';
import 'package:sidequests/view/quests/explore_view.dart';
import 'package:sidequests/viewmodel/profile/profile_view_model.dart';
import 'package:sidequests/viewmodel/quests/quest_view_model.dart';

/// What QuestRepository throws when recommend_quests gets no answer.
const _offlineError = AppException(
  'Sin conexión: no pudimos cargar tus recomendaciones. Reintenta cuando tengas internet.',
  isRetryable: true,
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

/// Without it the snapshot asks the (test) platform channel, which answers
/// later than the fire-and-forget refreshes are awaited here.
class _Online implements Connectivity {
  @override
  Future<List<ConnectivityResult>> checkConnectivity() async => const [ConnectivityResult.wifi];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _NullSink implements AnalyticsEventSink {
  @override
  Future<void> insertAnalyticsEvent(Map<String, dynamic> event) async {}
}

ContextManager _contextManager() => ContextManager(
  locationService: _NoLocation(),
  batteryMonitor: _FullBattery(),
  connectivity: _Online(),
);

class _SpyTracker extends AnalyticsTracker {
  final List<({String eventType, String? questId, int? availableMinutes})> calls = [];

  _SpyTracker() : super(eventSink: _NullSink(), contextManager: _contextManager(), sessionId: 'unused');

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
  }) async => calls.add((eventType: eventType, questId: questId, availableMinutes: availableMinutes));

  List<String?> get shownQuestIds => [
    for (final call in calls)
      if (call.eventType == AnalyticsEventType.recommendationShown) call.questId,
  ];
}

Quest _quest(String id) => Quest(
  id: id,
  title: 'Quest $id',
  category: 'food',
  durationMinutes: 10,
  difficulty: 'easy',
  locationMode: 'anywhere',
  socialLevel: 'solo',
);

Map<String, dynamic> _row(String id, int rank) => {
  'quest_id': id,
  'score': 10 - rank,
  'time_match': true,
  'variant': 'control',
  'rank_position': rank,
  'category': 'food',
};

List<Map<String, dynamic>> _rows(List<String> ids) => [
  for (final (index, id) in ids.indexed) _row(id, index + 1),
];

/// Plays the shared recommend_quests RPC: records the criteria of every call
/// and answers [rows] — or throws [error]. Mission writes always succeed.
class _FakeQuestRepository implements QuestRepository {
  final List<({AppContext context, UserPreferences preferences, List<String> excluded, int limit})>
  calls = [];
  List<Map<String, dynamic>> rows = _rows(['a', 'b', 'c']);
  AppException? error;

  @override
  Future<List<QuestRecommendation>> getRecommendations({
    required AppContext context,
    required UserPreferences preferences,
    List<String> excludedQuestIds = const [],
    int limit = 3,
  }) async {
    calls.add((context: context, preferences: preferences, excluded: excludedQuestIds, limit: limit));
    if (error != null) throw error!;
    return rows.map(QuestRecommendation.fromJson).toList();
  }

  @override
  Future<List<Quest>> getCatalog() async => [for (final id in ['a', 'b', 'c', 'd']) _quest(id)];

  @override
  Future<List<UserQuest>> getUserQuests(String userId) async => const [];

  @override
  Future<UserQuest> acceptQuest({required String userId, required String questId}) async =>
      UserQuest(id: 'uq-$questId', userId: userId, questId: questId, acceptedAt: DateTime(2026, 10, 28));

  @override
  Future<List<QuestStep>> getSteps(String questId) async => [
    QuestStep(id: 1, questId: questId, stepOrder: 0, title: 'Único paso'),
  ];

  @override
  Future<UserQuest> completeQuest(UserQuest userQuest) async =>
      userQuest.copyWithProgress(status: 'completed');

  @override
  Future<UserQuest> abandonQuest(UserQuest userQuest, {required String reason}) async =>
      userQuest.copyWithProgress(status: 'abandoned');

  // Podómetro and photo proofs: nothing stored in these tests.
  @override
  StepSession? getActiveStepSession() => null;

  @override
  List<PendingPhotoProof> getPendingPhotoProofs() => const [];

  @override
  Future<List<QuestPhotoProof>> getPhotoProofs(String attemptId) async => const [];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeProfileRepository implements ProfileRepository {
  UserPreferences preferences;

  _FakeProfileRepository(this.preferences);

  @override
  Future<Profile> getProfile(String userId) async => Profile(id: userId, displayName: 'Ana');

  @override
  Future<UserPreferences> getPreferences(String userId) async => preferences;

  @override
  Future<void> updatePreferences(String userId, UserPreferences preferences) async =>
      this.preferences = preferences;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeAuthRepository implements AuthRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

QuestViewModel _viewModel(_FakeQuestRepository repository, _SpyTracker tracker) => QuestViewModel(
  repository,
  _contextManager(),
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

/// Completing or abandoning a quest refreshes the list without awaiting it.
Future<void> _settle() => Future<void>.delayed(Duration.zero);

void main() {
  const profile = UserPreferences(
    interests: ['art', 'food'],
    typicalTimeMinutes: 45,
    socialLevel: 'social',
  );

  late _FakeQuestRepository repository;
  late _SpyTracker tracker;
  late QuestViewModel viewModel;

  setUp(() {
    repository = _FakeQuestRepository();
    tracker = _SpyTracker();
    viewModel = _viewModel(repository, tracker);
  });

  List<String> shownIds() => viewModel.recommendations.map((r) => r.questId).toList();

  test('minuteOptionFor: the largest chip that fits the typical time, else the shortest', () {
    expect(minuteOptionFor(5), 10);
    expect(minuteOptionFor(10), 10);
    expect(minuteOptionFor(25), 20);
    expect(minuteOptionFor(30), 30);
    expect(minuteOptionFor(59), 45);
    expect(minuteOptionFor(60), 60);
    expect(minuteOptionFor(240), 60);
  });

  group('BQ5 criteria sent to recommend_quests', () {
    test('available time, social level, interests and session skips reach the RPC, '
        'which is asked for three quests', () async {
      await viewModel.loadRecommendations(profile);
      await viewModel.skipRecommendation('b', profile);

      final sent = repository.calls.last;
      expect(sent.context.availableMinutes, 45);
      expect(sent.preferences.socialLevel, 'social');
      expect(sent.preferences.interests, ['art', 'food']);
      expect(sent.excluded, ['b']);
      expect(sent.limit, 3);
    });

    test("without a chip picked, the session's time follows the profile's typical time "
        'and is what recommendation_shown reports', () async {
      await viewModel.loadRecommendations(const UserPreferences(typicalTimeMinutes: 25));

      expect(viewModel.selectedMinutes, 20);
      expect(repository.calls.single.context.availableMinutes, 20);
      expect(tracker.calls.map((c) => c.availableMinutes).toSet(), {20});
    });

    test('an edited typical time applies too, while no chip was picked', () async {
      await viewModel.loadRecommendations(profile);
      await viewModel.loadRecommendations(profile.copyWith(typicalTimeMinutes: 10));

      expect(viewModel.selectedMinutes, 10);
      expect(repository.calls.last.context.availableMinutes, 10);
    });

    test('a chip picked this session wins over the profile, for this session only', () async {
      viewModel.setMinutes(10);
      await viewModel.loadRecommendations(profile);

      expect(viewModel.selectedMinutes, 10);
      expect(repository.calls.single.context.availableMinutes, 10);

      final nextSession = _viewModel(repository, tracker);
      await nextSession.loadRecommendations(profile);
      expect(nextSession.selectedMinutes, 45);
    });
  });

  group('the top three follow what the user does in the session', () {
    setUp(() async {
      await viewModel.load();
      await viewModel.loadRecommendations(profile);
    });

    test('an accepted quest leaves the list at once, without asking the RPC again', () async {
      await viewModel.acceptQuest('a', wasRecommended: true);

      expect(shownIds(), ['b', 'c']);
      expect(repository.calls, hasLength(1));
      expect(tracker.shownQuestIds, ['a', 'b', 'c']);
    });

    test('completing a quest ranks the list again on the new history', () async {
      expect(await viewModel.startInstantPlan(_quest('a')), isTrue);
      repository.rows = _rows(['b', 'c', 'd']);

      expect(await viewModel.completeCurrentStep(viewModel.currentMission!), isTrue);
      await _settle();

      expect(repository.calls, hasLength(2));
      expect(repository.calls.last.preferences.interests, profile.interests);
      expect(shownIds(), ['b', 'c', 'd']);
      expect(tracker.shownQuestIds.skip(3), ['b', 'c', 'd']);
    });

    test('abandoning a quest ranks the list again too', () async {
      await viewModel.acceptQuest('a', wasRecommended: true);
      repository.rows = _rows(['b', 'a', 'c']);

      expect(await viewModel.abandonQuest(viewModel.currentMission!, reason: 'too_far'), isTrue);
      await _settle();

      expect(repository.calls, hasLength(2));
      expect(shownIds(), ['b', 'a', 'c']);
    });
  });

  test('without a list loaded in Explore, finishing a quest asks the RPC nothing', () async {
    await viewModel.load();
    await viewModel.startInstantPlan(_quest('a'));

    await viewModel.completeCurrentStep(viewModel.currentMission!);
    await _settle();

    expect(repository.calls, isEmpty);
  });

  group('when recommend_quests cannot answer', () {
    test('offline: the list ranked for other criteria is cleared and the reason kept', () async {
      await viewModel.loadRecommendations(profile);
      viewModel.setMinutes(10);
      repository.error = _offlineError;

      await viewModel.loadRecommendations(profile);

      expect(viewModel.recommendations, isEmpty);
      expect(viewModel.recommendationsErrorMessage, _offlineError.message);
      expect(viewModel.isLoadingRecommendations, isFalse);
      expect(viewModel.errorMessage, isNull, reason: "the catalogue's error is not touched");
    });

    test('the next load that goes through clears the error', () async {
      repository.error = _offlineError;
      await viewModel.loadRecommendations(profile);

      repository.error = null;
      await viewModel.loadRecommendations(profile);

      expect(viewModel.recommendationsErrorMessage, isNull);
      expect(shownIds(), ['a', 'b', 'c']);
    });
  });

  group('views', () {
    late _FakeProfileRepository profileRepository;
    late ProfileViewModel profileViewModel;

    setUp(() {
      profileRepository = _FakeProfileRepository(profile);
      profileViewModel = ProfileViewModel(profileRepository, _FakeAuthRepository(), 'user-1');
    });

    Future<void> pump(WidgetTester tester, Widget home) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider.value(value: viewModel),
            ChangeNotifierProvider.value(value: profileViewModel),
          ],
          child: MaterialApp(home: home),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('Explore says why there are no recommendations and "Reintentar" loads them', (
      tester,
    ) async {
      repository.error = _offlineError;
      await pump(tester, const ExploreView());

      expect(find.text(_offlineError.message), findsOneWidget);
      expect(find.text('#1 para ti'), findsNothing);

      repository.error = null;
      await tester.tap(find.text('Reintentar'));
      await tester.pumpAndSettle();

      expect(find.text(_offlineError.message), findsNothing);
      expect(find.text('#1 para ti'), findsOneWidget);
      expect(find.text('#3 para ti'), findsOneWidget);
    });

    testWidgets('saving new preferences ranks the session again on them', (tester) async {
      await profileViewModel.load();
      await pump(
        tester,
        Builder(
          builder: (context) => TextButton(
            onPressed: () => Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (_) => const EditPreferencesView())),
            child: const Text('Editar'),
          ),
        ),
      );
      await tester.tap(find.text('Editar'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Aprendizaje'));
      await tester.ensureVisible(find.text('Guardar'));
      await tester.tap(find.text('Guardar'));
      await tester.pumpAndSettle();

      expect(find.byType(EditPreferencesView), findsNothing);
      expect(repository.calls.single.preferences.interests, ['art', 'food', 'learning']);
      expect(profileRepository.preferences.interests, ['art', 'food', 'learning']);
    });
  });
}
