import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:sidequests/analytics/analytics_event_sink.dart';
import 'package:sidequests/analytics/analytics_event_type.dart';
import 'package:sidequests/analytics/analytics_tracker.dart';
import 'package:sidequests/data/context/context_manager.dart';
import 'package:sidequests/data/services/battery_monitor.dart';
import 'package:sidequests/data/services/location_service.dart';
import 'package:sidequests/models/app_context.dart';
import 'package:sidequests/models/quest.dart';
import 'package:sidequests/models/quest_recommendation.dart';
import 'package:sidequests/models/quest_step.dart';
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
    calls.add({'eventType': eventType, 'questId': questId, 'metadata': metadata});
  }
}

class _NullSink implements AnalyticsEventSink {
  @override
  Future<void> insertAnalyticsEvent(Map<String, dynamic> event) async {}
}

ContextManager _contextManager() =>
    ContextManager(locationService: _NoLocation(), batteryMonitor: _FullBattery());

/// Only getRecommendations, acceptQuest and getSteps are exercised; anything
/// else would throw.
class _FakeQuestRepository implements QuestRepository {
  final List<Map<String, dynamic>> recommendationRows;

  _FakeQuestRepository({this.recommendationRows = const []});

  @override
  Future<List<QuestRecommendation>> getRecommendations({
    required AppContext context,
    required UserPreferences preferences,
    List<String> excludedQuestIds = const [],
    int limit = 3,
  }) async => recommendationRows.map(QuestRecommendation.fromJson).toList();

  @override
  Future<UserQuest> acceptQuest({required String userId, required String questId}) async =>
      UserQuest(id: 'uq-$questId', userId: userId, questId: questId, acceptedAt: DateTime(2026, 1, 1));

  @override
  Future<List<QuestStep>> getSteps(String questId) async => const [];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Map<String, dynamic> _row(String id) => {'quest_id': id, 'score': 1.5};

Quest _quest(String id) => Quest(
  id: id,
  title: 'Quest $id',
  category: 'food',
  durationMinutes: 20,
  difficulty: 'easy',
  locationMode: 'anywhere',
  socialLevel: 'solo',
);

void main() {
  late _SpyAnalyticsTracker tracker;
  late QuestViewModel viewModel;

  setUp(() {
    tracker = _SpyAnalyticsTracker();
    viewModel = QuestViewModel(
      _FakeQuestRepository(recommendationRows: [_row('a'), _row('b')]),
      _contextManager(),
      tracker,
      'user-1',
    );
  });

  Map<String, dynamic>? lastMetadata() =>
      tracker.calls.isEmpty ? null : tracker.calls.last['metadata'] as Map<String, dynamic>;

  test(
    "'instant_plan': accepting straight from a recommendation card carries "
    'start_path, seconds_to_start, interactions_to_start and batch_id',
    () async {
      await viewModel.loadRecommendations(const UserPreferences());
      viewModel.setMinutes(20);
      viewModel.registerInteraction(); // an Explore->QuestDetailView open elsewhere

      final started = await viewModel.startInstantPlan(_quest('a'));

      expect(started, isTrue);
      expect(tracker.calls.last['eventType'], AnalyticsEventType.recommendationAccepted);
      final metadata = lastMetadata()!;
      expect(metadata['start_path'], 'instant_plan');
      expect(metadata['interactions_to_start'], 2);
      expect(metadata['seconds_to_start'], isA<int>());
      expect(metadata['batch_id'], isA<String>());
    },
  );

  test(
    "'standard': accepting from a recommendation's detail view carries "
    'start_path standard',
    () async {
      await viewModel.loadRecommendations(const UserPreferences());
      viewModel.registerInteraction(); // opened QuestDetailView from Explore

      await viewModel.acceptQuest('a', wasRecommended: true);

      expect(tracker.calls.last['eventType'], AnalyticsEventType.recommendationAccepted);
      final metadata = lastMetadata()!;
      expect(metadata['start_path'], 'standard');
      expect(metadata['interactions_to_start'], 1);
      expect(metadata['batch_id'], isA<String>());
    },
  );

  test(
    "'catalog': accepting from Todas las misiones carries start_path catalog "
    'and quest_started, not recommendation_accepted',
    () async {
      await viewModel.loadRecommendations(const UserPreferences());
      viewModel.setCategory('food');
      viewModel.setLocationScope('gps');

      await viewModel.acceptQuest('a');

      expect(tracker.calls.last['eventType'], AnalyticsEventType.questStarted);
      final metadata = lastMetadata()!;
      expect(metadata['start_path'], 'catalog');
      expect(metadata['interactions_to_start'], 2);
      expect(metadata['batch_id'], isA<String>());
    },
  );

  test('starting a quest resets the clock, counter and batch_id for the next journey', () async {
    await viewModel.loadRecommendations(const UserPreferences());
    viewModel.setMinutes(10);
    viewModel.setMinutes(20);
    await viewModel.acceptQuest('a');
    final firstBatchId = lastMetadata()!['batch_id'];

    // A fresh "shown" after the reset starts a new journey with a new batch.
    await viewModel.loadRecommendations(const UserPreferences());
    await viewModel.acceptQuest('b');

    final metadata = lastMetadata()!;
    expect(metadata['interactions_to_start'], 0);
    expect(metadata['batch_id'], isNot(firstBatchId));
  });

  test(
    'the batch_id stays the one from the first recommendations shown, even '
    'after later reloads (filter changes) generate new recommendation_shown batches',
    () async {
      await viewModel.loadRecommendations(const UserPreferences());
      final firstShownBatchId =
          tracker.calls
                  .where((c) => c['eventType'] == AnalyticsEventType.recommendationShown)
                  .first['metadata']
              as Map<String, dynamic>;

      await viewModel.loadRecommendations(const UserPreferences()); // e.g. a filter change reload
      await viewModel.acceptQuest('a', wasRecommended: true);

      expect(lastMetadata()!['batch_id'], firstShownBatchId['batch_id']);
    },
  );
}
