import 'package:flutter_test/flutter_test.dart';
import 'package:sidequests/analytics/analytics_event_sink.dart';
import 'package:sidequests/analytics/analytics_tracker.dart';
import 'package:sidequests/data/context/context_manager.dart';
import 'package:sidequests/models/app_context.dart';
import 'package:sidequests/models/explore_filters.dart';
import 'package:sidequests/models/quest.dart';
import 'package:sidequests/models/quest_recommendation.dart';
import 'package:sidequests/models/user_preferences.dart';
import 'package:sidequests/repository/quest_repository.dart';
import 'package:sidequests/view/quests/explore_view.dart' show formatDistanceKm, questMeta;
import 'package:sidequests/viewmodel/quests/quest_view_model.dart';

/// Reviewer feedback: "the location function does not work properly, as
/// suggestions do not update based on the user's location". The position read
/// by any context snapshot must reach the distances, the "📍 Nearby" order and
/// the quest cards — not only Nearby's "Turn on location" button.

/// A context whose GPS fix the test moves around (null: no fix).
class _MovableContext implements ContextManager {
  (double, double)? position;

  AppContext _context(int? availableMinutes) => AppContext(
    latitude: position?.$1,
    longitude: position?.$2,
    timeOfDay: 'afternoon',
    dayOfWeek: 'monday',
    isConnected: true,
    availableMinutes: availableMinutes,
  );

  @override
  Future<AppContext> snapshot({int? availableMinutes}) async => _context(availableMinutes);

  @override
  AppContext localSnapshot({int? availableMinutes}) => _context(availableMinutes)
      .copyWithoutLocation();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

extension on AppContext {
  AppContext copyWithoutLocation() => AppContext(
    timeOfDay: timeOfDay,
    dayOfWeek: dayOfWeek,
    isConnected: isConnected,
    availableMinutes: availableMinutes,
  );
}

class _Repository implements QuestRepository {
  final List<Quest> quests;

  _Repository(this.quests);

  @override
  Future<RecommendationBatch> getRecommendations({
    required AppContext context,
    required UserPreferences preferences,
    List<String> excludedQuestIds = const [],
    int limit = 3,
  }) async => const RecommendationBatch(recommendations: [], batchId: 'b-1');

  @override
  Future<void> saveExploreFilters(ExploreFilters filters) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _NullSink implements AnalyticsEventSink {
  @override
  Future<void> insertAnalyticsEvent(Map<String, dynamic> event) async {}
}

Quest _quest(String id, {double? latitude, double? longitude, String locationMode = 'gps'}) => Quest(
  id: id,
  title: 'Quest $id',
  category: 'food',
  durationMinutes: 20,
  difficulty: 'easy',
  locationMode: locationMode,
  socialLevel: 'solo',
  latitude: latitude,
  longitude: longitude,
);

void main() {
  // Bogotá: "far" is ~5.5 km north of "near"; "unknown" has no coordinates.
  final far = _quest('far', latitude: 4.70, longitude: -74.05);
  final unknown = _quest('unknown');
  final near = _quest('near', latitude: 4.601, longitude: -74.066);
  final indoor = _quest('indoor', locationMode: 'anywhere');

  late _MovableContext context;
  late QuestViewModel viewModel;

  setUp(() {
    context = _MovableContext();
    final manager = context as ContextManager;
    viewModel = QuestViewModel(
      _Repository([far, unknown, near, indoor]),
      manager,
      AnalyticsTracker(eventSink: _NullSink(), contextManager: manager, sessionId: 's'),
      'user-1',
    )..catalog = [far, unknown, near, indoor];
  });

  test('a fix read while loading suggestions becomes the user position', () async {
    context.position = (4.60, -74.07);

    await viewModel.loadRecommendations(const UserPreferences());

    expect(viewModel.userLatitude, 4.60);
    expect(viewModel.userLongitude, -74.07);
    expect(viewModel.userLocationUnavailable, isFalse);
    expect(viewModel.distanceKmTo(near), lessThan(1));
    expect(viewModel.distanceKmTo(far), greaterThan(5));
    expect(viewModel.distanceKmTo(unknown), isNull);
  });

  test('without a fix nothing is invented and the last known position stays', () async {
    await viewModel.loadRecommendations(const UserPreferences());
    expect(viewModel.userLatitude, isNull);
    expect(viewModel.distanceKmTo(near), isNull);

    context.position = (4.60, -74.07);
    await viewModel.refreshContext();
    context.position = null; // e.g. GPS off afterwards
    await viewModel.refreshContext();

    expect(viewModel.userLatitude, 4.60);
  });

  test('"📍 Nearby" lists the closest first, and follows the user when they move', () async {
    viewModel.setLocationScope('gps');
    // No position yet: the catalogue order.
    expect(viewModel.filteredCatalog.map((q) => q.id), ['far', 'unknown', 'near']);

    context.position = (4.60, -74.07); // next to "near"
    await viewModel.refreshContext();
    expect(viewModel.filteredCatalog.map((q) => q.id), ['near', 'far', 'unknown']);

    context.position = (4.71, -74.05); // next to "far"
    await viewModel.refreshContext();
    expect(viewModel.filteredCatalog.map((q) => q.id), ['far', 'near', 'unknown']);
  });

  test('"All" keeps the catalogue order (the server-ranked picks are never reordered)', () async {
    context.position = (4.60, -74.07);
    await viewModel.refreshContext();

    expect(viewModel.filteredCatalog.map((q) => q.id), ['far', 'unknown', 'near', 'indoor']);
  });

  test("Nearby's / Explore's \"turn on location\" also updates the live context", () async {
    context.position = (4.60, -74.07);

    await viewModel.requestUserLocation();

    expect(viewModel.userLatitude, 4.60);
    expect(viewModel.currentContext?.hasLocation, isTrue);
    expect(viewModel.isLocatingUser, isFalse);
  });

  test('the cards show the distance once it is known', () {
    expect(questMeta(near).last, '📍 Nearby');
    expect(questMeta(near, distanceKm: 0.35).last, '📍 350 m');
    expect(questMeta(far, distanceKm: 5.53).last, '📍 5.5 km');
    expect(questMeta(indoor, distanceKm: 2).last, '🏠 Anywhere');
    expect(formatDistanceKm(1.04), '1.0 km');
  });
}
