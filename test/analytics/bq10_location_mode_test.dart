import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:sidequests/analytics/analytics_event_sink.dart';
import 'package:sidequests/analytics/analytics_event_type.dart';
import 'package:sidequests/analytics/analytics_tracker.dart';
import 'package:sidequests/core/bq10_context.dart';
import 'package:sidequests/data/context/context_manager.dart';
import 'package:sidequests/data/services/battery_monitor.dart';
import 'package:sidequests/data/services/location_service.dart';
import 'package:sidequests/models/app_context.dart';
import 'package:sidequests/models/explore_filters.dart';
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
    calls.add({'eventType': eventType, 'locationMode': locationMode, 'metadata': metadata});
  }
}

class _FakeQuestRepository implements QuestRepository {
  final List<ExploreFilters> savedFilters = [];

  @override
  Future<void> saveExploreFilters(ExploreFilters filters) async => savedFilters.add(filters);

  @override
  Future<UserQuest> acceptQuest({required String userId, required String questId}) async =>
      UserQuest(id: 'uq-$questId', userId: userId, questId: questId, acceptedAt: DateTime(2026, 1, 1));

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

AppContext _context({int? weatherCode, bool isRainy = false}) => AppContext(
  timeOfDay: 'morning',
  dayOfWeek: 'monday',
  isConnected: true,
  weatherCode: weatherCode,
  isRainy: isRainy,
);

/// Exactly the same keys as Kotlin. The clock isn't injectable, so the time
/// is compared against the moments around the call: it can only differ
/// between them when the call lands right on a range boundary.
void _expectFullMetadata(
  Map<String, dynamic> call, {
  required String weatherCondition,
  required DateTime before,
}) {
  final metadata = call['metadata'] as Map;
  expect(metadata.keys, unorderedEquals(['location_mode', 'time_of_day', 'weather_condition']));
  expect(metadata['location_mode'], call['locationMode']);
  expect(metadata['weather_condition'], weatherCondition);
  expect(metadata['time_of_day'], isIn([timeOfDayFor(before), timeOfDayFor(DateTime.now())]));
}

void main() {
  late _FakeQuestRepository repository;
  late _SpyAnalyticsTracker tracker;
  late QuestViewModel viewModel;

  setUp(() {
    repository = _FakeQuestRepository();
    tracker = _SpyAnalyticsTracker();
    viewModel = QuestViewModel(repository, _contextManager(), tracker, 'user-1');
  });

  group('events', () {
    test("'anywhere' emits location_independent_mode_selected", () {
      viewModel.currentContext = _context(weatherCode: 61, isRainy: true);
      final before = DateTime.now();

      viewModel.setLocationScope('anywhere');

      final call = tracker.calls.single;
      expect(call['eventType'], 'location_independent_mode_selected');
      expect(call['eventType'], AnalyticsEventType.locationIndependentModeSelected);
      expect(call['locationMode'], 'anywhere');
      _expectFullMetadata(call, weatherCondition: 'rain', before: before);
    });

    test("'gps' emits location_based_mode_selected", () {
      viewModel.currentContext = _context(weatherCode: 0);
      final before = DateTime.now();

      viewModel.setLocationScope('gps');

      final call = tracker.calls.single;
      expect(call['eventType'], 'location_based_mode_selected');
      expect(call['eventType'], AnalyticsEventType.locationBasedModeSelected);
      expect(call['locationMode'], 'gps');
      _expectFullMetadata(call, weatherCondition: 'clear', before: before);
    });

    test('a cloudy snapshot is reported as cloudy, as Kotlin does', () {
      viewModel.currentContext = _context(weatherCode: 3);
      final before = DateTime.now();

      viewModel.setLocationScope('gps');

      _expectFullMetadata(tracker.calls.single, weatherCondition: 'cloudy', before: before);
    });

    test("'all' keeps location_mode_selected, without BQ10 metadata", () {
      viewModel.currentContext = _context(weatherCode: 0);

      viewModel.setLocationScope('all');

      final call = tracker.calls.single;
      expect(call['eventType'], 'location_mode_selected');
      expect(call['locationMode'], 'all');
      expect(call['metadata'], isEmpty);
    });

    test('before the first snapshot the weather is unknown and the time still known', () {
      expect(viewModel.currentContext, isNull);
      final before = DateTime.now();

      viewModel.setLocationScope('anywhere');

      _expectFullMetadata(tracker.calls.single, weatherCondition: 'unknown', before: before);
    });
  });

  group('the filter behaves as before', () {
    for (final scope in ['all', 'gps', 'anywhere']) {
      test("'$scope' updates the selection, saves it and notifies", () {
        var notified = 0;
        viewModel.addListener(() => notified++);

        viewModel.setLocationScope(scope);

        expect(viewModel.selectedLocationScope, scope);
        expect(repository.savedFilters.single.locationScope, scope);
        expect(notified, 1);
      });

      test("'$scope' counts as one BQ4 interaction", () async {
        viewModel.setLocationScope(scope);

        await viewModel.acceptQuest('a', wasRecommended: true);

        final accepted = tracker.calls.last;
        expect(accepted['eventType'], AnalyticsEventType.recommendationAccepted);
        expect(accepted['metadata']['interactions_to_start'], 1);
      });
    }
  });
}
