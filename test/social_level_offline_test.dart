import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:provider/provider.dart';
import 'package:sidequests/analytics/analytics_event_sink.dart';
import 'package:sidequests/analytics/analytics_event_type.dart';
import 'package:sidequests/analytics/analytics_tracker.dart';
import 'package:sidequests/core/verification/step_verification_strategy.dart';
import 'package:sidequests/data/context/context_manager.dart';
import 'package:sidequests/data/local/local_data_source.dart';
import 'package:sidequests/data/remote/supabase_remote_data_source.dart';
import 'package:sidequests/data/services/battery_monitor.dart';
import 'package:sidequests/data/services/location_check_in_service.dart';
import 'package:sidequests/data/services/location_service.dart';
import 'package:sidequests/data/services/step_counter_service.dart';
import 'package:sidequests/models/user_preferences.dart';
import 'package:sidequests/repository/auth_repository.dart';
import 'package:sidequests/repository/profile_repository.dart';
import 'package:sidequests/repository/quest_repository.dart';
import 'package:sidequests/view/quests/explore_view.dart';
import 'package:sidequests/viewmodel/profile/profile_view_model.dart';
import 'package:sidequests/viewmodel/quests/quest_view_model.dart';

const _userId = 'user-1';
const _profile = UserPreferences(socialLevel: 'solo');
const _groupNotice =
    "Sin conexión: estas son tus últimas recomendaciones. Aplicaremos 'En grupo' al reconectar.";

Map<String, dynamic> _questRow(String id) => {
  'id': id,
  'title': 'Quest $id',
  'category': 'food',
  'duration_minutes': 20,
  'difficulty': 'easy',
  'location_mode': 'anywhere',
  'social_level': 'solo',
};

/// Supabase in memory. [offline] fails every call like a dropped connection;
/// [requestedLevels] is what recommend_quests actually received.
class _FakeRemote implements SupabaseRemoteDataSource {
  bool offline = false;
  final List<String> requestedLevels = [];

  void _failIfDown() {
    if (offline) throw const SocketException('offline');
  }

  @override
  Future<List<Map<String, dynamic>>> getActiveQuests() async {
    _failIfDown();
    return [_questRow('a'), _questRow('b')];
  }

  @override
  Future<List<Map<String, dynamic>>> recommendQuests({
    required int availableMinutes,
    required String socialLevel,
    List<String> interests = const [],
    String locationMode = 'all',
    List<String> excludedQuestIds = const [],
    int limit = 3,
  }) async {
    _failIfDown();
    requestedLevels.add(socialLevel);
    return [
      {'quest_id': 'a', 'score': 1.5, 'variant': 'control', 'rank_position': 1},
    ];
  }

  @override
  Future<List<Map<String, dynamic>>> getQuestSteps(String questId) async {
    _failIfDown();
    return [];
  }

  @override
  Future<List<Map<String, dynamic>>> getUserQuests(String userId) async {
    _failIfDown();
    return [];
  }

  @override
  Future<Map<String, dynamic>> getProfile(String userId) async {
    _failIfDown();
    return {'id': userId, 'display_name': 'Ana'};
  }

  @override
  Future<Map<String, dynamic>> getPreferences(String userId) async {
    _failIfDown();
    return {'user_id': userId, 'social_level': 'solo'};
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// The Hive box, in memory.
class _FakeLocal implements LocalDataSource {
  ({String batchId, List<Map<String, dynamic>> rows})? saved;
  List<Map<String, dynamic>> userQuests = [];
  List<Map<String, dynamic>> catalog = [];
  final Map<String, List<Map<String, dynamic>>> steps = {};

  @override
  ({String batchId, List<Map<String, dynamic>> rows})? getSavedRecommendations() => saved;

  @override
  Future<void> saveRecommendations(String batchId, List<Map<String, dynamic>> rows) async =>
      saved = (batchId: batchId, rows: rows);

  @override
  List<Map<String, dynamic>> getPendingWrites() => const [];

  @override
  List<Map<String, dynamic>> getUserQuests() => [...userQuests];

  @override
  Future<void> cacheUserQuests(List<Map<String, dynamic>> rows) async => userQuests = rows;

  @override
  List<Map<String, dynamic>> getQuestCatalog() => catalog;

  @override
  Future<void> cacheQuestCatalog(List<Map<String, dynamic>> quests) async => catalog = quests;

  @override
  List<Map<String, dynamic>>? getQuestSteps(String questId) => steps[questId];

  @override
  Future<void> cacheQuestSteps(String questId, List<Map<String, dynamic>> rows) async =>
      steps[questId] = rows;

  @override
  List<Map<String, dynamic>> getPendingPhotoProofs() => const [];

  @override
  Map<String, dynamic>? getActiveStepSession() => null;

  @override
  Map<String, dynamic>? getExploreFilters() => null;

  @override
  Future<void> saveExploreFilters(Map<String, dynamic> filters) async {}

  @override
  Map<String, dynamic>? getProfile() => null;

  @override
  Future<void> cacheProfile(Map<String, dynamic> profile) async {}

  @override
  Map<String, dynamic>? getPreferences() => null;

  @override
  Future<void> cachePreferences(Map<String, dynamic> preferences) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

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

/// The real plugin's channel never answers under testWidgets' fake clock.
class _FakeConnectivity implements Connectivity {
  @override
  Future<List<ConnectivityResult>> checkConnectivity() async => [ConnectivityResult.none];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

ContextManager _contextManager() => ContextManager(
  locationService: _NoLocation(),
  batteryMonitor: _FullBattery(),
  connectivity: _FakeConnectivity(),
);

class _SpyTracker extends AnalyticsTracker {
  final List<Map<String, dynamic>> shown = [];

  _SpyTracker()
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
  }) async {
    if (eventType != AnalyticsEventType.recommendationShown) return;
    shown.add({'socialLevel': socialLevel, 'source': metadata['social_level_source']});
  }
}

void main() {
  late _FakeRemote remote;
  late _FakeLocal local;
  late _SpyTracker tracker;
  late QuestViewModel viewModel;

  QuestViewModel newViewModel() => QuestViewModel(
    QuestRepository(remote, local),
    _contextManager(),
    tracker,
    _userId,
    stepCounter: StepCounterService(requestAccess: () async => StepCounterStatus.unavailable),
    locationCheckIn: LocationCheckInService(
      requestAccess: () async => LocationAccess.granted,
      isLowBattery: () async => false,
      isOffline: () async => false,
      offlineChanges: () => const Stream.empty(),
      positions: (_, _) => const Stream.empty(),
    ),
  );

  /// Same two calls as _SocialMoodFilter's chip.
  Future<void> tapChip(String level) {
    viewModel.setSessionSocialLevel(level);
    return viewModel.loadRecommendations(_profile);
  }

  /// A live list on screen (which also saves it), then the connection drops.
  Future<void> loadOnlineThenDrop() async {
    await viewModel.load();
    await viewModel.loadRecommendations(_profile);
    await pumpEventQueue();
    remote.offline = true;
    remote.requestedLevels.clear();
    tracker.shown.clear();
  }

  setUp(() {
    remote = _FakeRemote();
    local = _FakeLocal();
    tracker = _SpyTracker();
    viewModel = newViewModel();
  });

  group('tapping a chip offline', () {
    test('keeps the chip and marks it as waiting, over the saved list', () async {
      await loadOnlineThenDrop();

      await tapChip('group');

      expect(viewModel.sessionSocialLevel, 'group');
      expect(viewModel.effectiveSocialLevel(_profile), 'group');
      expect(viewModel.recommendationsFromCache, isTrue);
      expect(viewModel.recommendations.map((r) => r.questId), ['a']);
      expect(viewModel.socialLevelAwaitingReconnect, 'group');
    });

    test('does not log recommendation_shown for the saved list (BQ8/BQ9)', () async {
      await loadOnlineThenDrop();

      await tapChip('group');
      await tapChip('social');

      expect(tracker.shown, isEmpty);
    });

    test('the last chip tapped is the one waiting', () async {
      await loadOnlineThenDrop();

      await tapChip('group');
      await tapChip('social');

      expect(viewModel.socialLevelAwaitingReconnect, 'social');
    });

    test("going back to the saved list's own level leaves nothing to wait for", () async {
      await loadOnlineThenDrop();

      await tapChip('group');
      await tapChip('solo');

      expect(viewModel.recommendationsFromCache, isTrue);
      expect(viewModel.socialLevelAwaitingReconnect, isNull);
    });

    test('nothing saved: the chip stays and is applied on reconnecting', () async {
      remote.offline = true;

      await tapChip('group');

      expect(viewModel.recommendations, isEmpty);
      expect(viewModel.sessionSocialLevel, 'group');
      expect(viewModel.socialLevelAwaitingReconnect, isNull); // no list to say it about

      remote.offline = false;
      await viewModel.refreshAfterReconnect(_profile);
      expect(remote.requestedLevels, ['group']);
    });
  });

  group('without a chip tapped offline', () {
    test('online, a chip whose new list is still loading is not announced', () async {
      await viewModel.load();
      await viewModel.loadRecommendations(_profile);

      viewModel.setSessionSocialLevel('group');

      expect(viewModel.socialLevelAwaitingReconnect, isNull);
    });

    test('no chip this session: a saved list has nothing to wait for', () async {
      await loadOnlineThenDrop();

      await viewModel.loadRecommendations(_profile);

      expect(viewModel.recommendationsFromCache, isTrue);
      expect(viewModel.socialLevelAwaitingReconnect, isNull);
    });

    test('a chip already applied online is not announced again', () async {
      await viewModel.load();
      await tapChip('group');
      await pumpEventQueue();
      remote.offline = true;

      await viewModel.loadRecommendations(_profile); // e.g. another filter changed

      expect(viewModel.recommendationsFromCache, isTrue);
      expect(viewModel.socialLevelAwaitingReconnect, isNull);
    });
  });

  group('reconnecting', () {
    test('asks recommend_quests for the session level and clears the wait', () async {
      await loadOnlineThenDrop();
      await tapChip('group');

      remote.offline = false;
      await viewModel.refreshAfterReconnect(_profile);

      expect(remote.requestedLevels, ['group']);
      expect(viewModel.sessionSocialLevel, 'group');
      expect(viewModel.recommendationsFromCache, isFalse);
      expect(viewModel.socialLevelAwaitingReconnect, isNull);
    });

    test('logs recommendation_shown only for the new list, as a session choice', () async {
      await loadOnlineThenDrop();
      await tapChip('group');

      remote.offline = false;
      await viewModel.refreshAfterReconnect(_profile);

      expect(tracker.shown, [
        {'socialLevel': 'group', 'source': 'session'},
      ]);
    });

    test('still down during the reload: the chip keeps waiting and nothing is logged', () async {
      await loadOnlineThenDrop();
      await tapChip('group');

      await viewModel.refreshAfterReconnect(_profile);

      expect(remote.requestedLevels, isEmpty);
      expect(viewModel.socialLevelAwaitingReconnect, 'group');
      expect(tracker.shown, isEmpty);
    });

    test('a session choice is not saved as the profile', () async {
      await loadOnlineThenDrop();
      await tapChip('group');

      remote.offline = false;
      await viewModel.refreshAfterReconnect(_profile);

      expect(_profile.socialLevel, 'solo');
      expect(newViewModel().effectiveSocialLevel(_profile), 'solo');
    });
  });

  testWidgets('Explore: the notice appears on the chip tap and goes away with the new list', (tester) async {
    await tester.runAsync(loadOnlineThenDrop);
    remote.offline = false;
    final profileViewModel = ProfileViewModel(
      ProfileRepository(remote, local),
      AuthRepository(remote, local),
      _userId,
    );
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<QuestViewModel>.value(value: viewModel),
          ChangeNotifierProvider<ProfileViewModel>.value(value: profileViewModel),
        ],
        child: const MaterialApp(home: ExploreView()),
      ),
    );
    await tester.pumpAndSettle();
    remote.offline = true;
    remote.requestedLevels.clear();
    expect(find.text(_groupNotice), findsNothing);

    final chip = find.widgetWithText(ChoiceChip, '👥 En grupo');
    await tester.ensureVisible(chip);
    await tester.tap(chip);
    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.text(_groupNotice), findsOneWidget);
    expect(find.text('Recomendaciones guardadas'), findsOneWidget);
    expect(tester.widget<ChoiceChip>(chip).selected, isTrue);
    expect(remote.requestedLevels, isEmpty);

    remote.offline = false;
    await viewModel.refreshAfterReconnect(profileViewModel.preferences);
    await tester.pumpAndSettle();

    expect(remote.requestedLevels, ['group']);
    expect(find.text(_groupNotice), findsNothing);
    expect(find.text('Recomendaciones guardadas'), findsNothing);
    expect(tester.widget<ChoiceChip>(chip).selected, isTrue);
  });
}
