import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:sidequests/analytics/analytics_event_sink.dart';
import 'package:sidequests/analytics/analytics_event_type.dart';
import 'package:sidequests/analytics/analytics_tracker.dart';
import 'package:sidequests/data/context/context_manager.dart';
import 'package:sidequests/data/services/battery_monitor.dart';
import 'package:sidequests/data/services/location_service.dart';
import 'package:sidequests/models/app_context.dart';
import 'package:sidequests/models/quest_recommendation.dart';
import 'package:sidequests/models/user_preferences.dart';
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

class _SpyAnalyticsTracker extends AnalyticsTracker {
  final List<Map<String, dynamic>> calls = [];

  _SpyAnalyticsTracker()
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
    calls.add({'eventType': eventType, 'socialLevel': socialLevel, 'metadata': metadata});
  }
}

class _NullSink implements AnalyticsEventSink {
  @override
  Future<void> insertAnalyticsEvent(Map<String, dynamic> event) async {}
}

ContextManager _contextManager() =>
    ContextManager(locationService: _NoLocation(), batteryMonitor: _FullBattery());

/// Records the preferences each recommend_quests call receives. Only
/// getRecommendations and acceptQuest are exercised.
class _RecordingQuestRepository implements QuestRepository {
  final List<UserPreferences> sentPreferences = [];

  @override
  Future<List<QuestRecommendation>> getRecommendations({
    required AppContext context,
    required UserPreferences preferences,
    List<String> excludedQuestIds = const [],
    int limit = 3,
  }) async {
    sentPreferences.add(preferences);
    return [QuestRecommendation.fromJson({'quest_id': 'a', 'score': 1.5})];
  }

  @override
  Future<UserQuest> acceptQuest({required String userId, required String questId}) async =>
      UserQuest(id: 'uq-$questId', userId: userId, questId: questId, acceptedAt: DateTime(2026, 1, 1));

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  const profile = UserPreferences(socialLevel: 'solo', interests: ['food']);

  late _RecordingQuestRepository repository;
  late _SpyAnalyticsTracker tracker;
  late QuestViewModel viewModel;

  setUp(() {
    repository = _RecordingQuestRepository();
    tracker = _SpyAnalyticsTracker();
    viewModel = QuestViewModel(repository, _contextManager(), tracker, 'user-1');
  });

  Map<String, dynamic> lastShown() =>
      tracker.calls.lastWhere((c) => c['eventType'] == AnalyticsEventType.recommendationShown);

  test('without a session choice, recommend_quests gets the profile social level', () async {
    await viewModel.loadRecommendations(profile);

    expect(viewModel.sessionSocialLevel, isNull);
    expect(viewModel.effectiveSocialLevel(profile), 'solo');
    expect(repository.sentPreferences.single.socialLevel, 'solo');

    final shown = lastShown();
    expect(shown['socialLevel'], 'solo');
    expect((shown['metadata'] as Map)['social_level_source'], 'profile');
  });

  test('a session choice overrides the profile for the RPC and the event', () async {
    viewModel.setSessionSocialLevel('group');
    await viewModel.loadRecommendations(profile);

    expect(viewModel.effectiveSocialLevel(profile), 'group');
    expect(repository.sentPreferences.single.socialLevel, 'group');

    final shown = lastShown();
    expect(shown['socialLevel'], 'group');
    expect((shown['metadata'] as Map)['social_level_source'], 'session');
  });

  test('the override coexists with the location scope and keeps the rest of the profile', () async {
    viewModel.setLocationScope('anywhere');
    viewModel.setSessionSocialLevel('social');
    await viewModel.loadRecommendations(profile);

    final sent = repository.sentPreferences.single;
    expect(sent.socialLevel, 'social');
    expect(sent.locationMode, 'anywhere');
    expect(sent.interests, ['food']);
  });

  test('the profile itself is never modified — the override is session-only', () async {
    viewModel.setSessionSocialLevel('group');
    await viewModel.loadRecommendations(profile);

    expect(profile.socialLevel, 'solo');
    // A fresh QuestViewModel (= next app session) starts from the profile.
    final nextSession = QuestViewModel(repository, _contextManager(), tracker, 'user-1');
    expect(nextSession.effectiveSocialLevel(profile), 'solo');
  });

  test('changing the chip counts as a BQ4 interaction', () async {
    await viewModel.loadRecommendations(profile);
    viewModel.setSessionSocialLevel('social');

    await viewModel.acceptQuest('a', wasRecommended: true);

    final accepted = tracker.calls.last;
    expect(accepted['eventType'], AnalyticsEventType.recommendationAccepted);
    expect((accepted['metadata'] as Map)['interactions_to_start'], 1);
  });

  test('setSessionSocialLevel notifies listeners so the chips repaint', () {
    var notified = 0;
    viewModel.addListener(() => notified++);

    viewModel.setSessionSocialLevel('group');

    expect(notified, 1);
  });
}
