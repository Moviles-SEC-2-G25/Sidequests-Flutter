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
    : super(
        eventSink: _NullSink(),
        contextManager: _contextManager(),
        sessionId: 'unused',
      );

  @override
  Future<void> track(
    String eventType, {
    String? questId,
    String? category,
    int? availableMinutes,
    String? locationMode,
    int? questDurationMinutes,
    String? questDifficulty,
    double? estimatedCost,
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

/// Only getRecommendations is exercised; anything else would throw.
class _FakeQuestRepository implements QuestRepository {
  final List<List<Map<String, dynamic>>> responses;
  int _call = 0;

  _FakeQuestRepository(this.responses);

  @override
  Future<List<QuestRecommendation>> getRecommendations({
    required AppContext context,
    required UserPreferences preferences,
    List<String> excludedQuestIds = const [],
    int limit = 3,
  }) async => responses[_call++].map(QuestRecommendation.fromJson).toList();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Map<String, dynamic> _row(String id, String variant, int rank) => {
  'quest_id': id,
  'score': 1.5,
  'variant': variant,
  'rank_position': rank,
  'category': 'food',
};

void main() {
  test('QuestRecommendation.fromJson tolerates missing BQ8 fields', () {
    final rec = QuestRecommendation.fromJson({'quest_id': 'q', 'score': 1});
    expect(rec.variant, 'control');
    expect(rec.rankPosition, 0);
    expect(rec.category, isNull);
  });

  test(
    'recommendation_shown metadata has variant, int rank and a batch_id that is '
    'shared within a list and differs between lists',
    () async {
      final tracker = _SpyAnalyticsTracker();
      final viewModel = QuestViewModel(
        _FakeQuestRepository([
          [_row('a', 'diverse', 1), _row('b', 'diverse', 2), _row('c', 'diverse', 3)],
          [_row('d', 'control', 1), _row('e', 'control', 2)],
        ]),
        _contextManager(),
        tracker,
        'user-1',
      );
      final preferences = const UserPreferences();

      await viewModel.loadRecommendations(preferences);
      await viewModel.loadRecommendations(preferences);

      final shown = tracker.calls
          .where((c) => c['eventType'] == AnalyticsEventType.recommendationShown)
          .toList();
      expect(shown, hasLength(5));

      for (final call in shown) {
        final metadata = call['metadata'] as Map<String, dynamic>;
        expect(metadata.keys.toSet(), {'variant', 'rank', 'batch_id'});
        expect(metadata['variant'], isA<String>());
        expect(metadata['rank'], isA<int>());
        expect(metadata['batch_id'], isA<String>());
      }

      List<Map<String, dynamic>> meta(Iterable<Map<String, dynamic>> calls) =>
          calls.map((c) => c['metadata'] as Map<String, dynamic>).toList();
      final first = meta(shown.take(3));
      final second = meta(shown.skip(3));

      expect(first.map((m) => m['rank']), [1, 2, 3]);
      expect(first.map((m) => m['variant']).toSet(), {'diverse'});
      expect(first.map((m) => m['batch_id']).toSet(), hasLength(1));
      expect(second.map((m) => m['variant']).toSet(), {'control'});
      expect(second.map((m) => m['batch_id']).toSet(), hasLength(1));
      expect(first.first['batch_id'], isNot(second.first['batch_id']));
    },
  );
}
