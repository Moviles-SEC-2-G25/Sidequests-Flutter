import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:sidequests/analytics/analytics_event_sink.dart';
import 'package:sidequests/analytics/analytics_event_type.dart';
import 'package:sidequests/analytics/analytics_tracker.dart';
import 'package:sidequests/core/app_exception.dart';
import 'package:sidequests/core/bq6_evidence.dart';
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
import 'package:sidequests/models/weather_snapshot.dart';
import 'package:sidequests/repository/quest_repository.dart';
import 'package:sidequests/viewmodel/quests/quest_view_model.dart';

const _userId = 'user-1';
const _questLatitude = 4.6;
const _questLongitude = -74.07;
const _degreesPerMeter = 1 / 111195;

Quest _quest(
  String id, {
  String location = 'gps',
  int minutes = 20,
  double cost = 0,
  double? latitude,
  double? longitude,
}) => Quest(
  id: id,
  title: 'Quest $id',
  category: 'food',
  durationMinutes: minutes,
  estimatedCost: cost,
  difficulty: 'easy',
  locationMode: location,
  socialLevel: 'solo',
  latitude: latitude,
  longitude: longitude,
);

final _source = _quest(
  'source',
  minutes: 60,
  cost: 12,
  latitude: _questLatitude,
  longitude: _questLongitude,
);

QuestStep _step(int order, {String verification = 'none'}) => QuestStep(
  id: order,
  questId: 'source',
  stepOrder: order,
  title: 'Paso $order',
  verificationType: verification,
);

UserQuest _attempt({String id = 'uq-1', String questId = 'source', String status = 'in_progress'}) =>
    UserQuest(
      id: id,
      userId: _userId,
      questId: questId,
      status: status,
      currentStep: 1,
      completedSteps: const [0],
      acceptedAt: DateTime(2026, 10, 1),
    );

class _Location extends LocationService {
  /// Meters north of the quest; null: no GPS fix.
  int? metersFromQuest;
  Completer<void>? gate;

  @override
  Future<Position?> getCurrentPosition({
    LocationAccuracy accuracy = LocationAccuracy.medium,
  }) async {
    await gate?.future;
    final meters = metersFromQuest;
    if (meters == null) return null;
    return Position(
      latitude: _questLatitude + meters * _degreesPerMeter,
      longitude: _questLongitude,
      timestamp: DateTime(2026, 10, 1),
      accuracy: 10,
      altitude: 0,
      altitudeAccuracy: 0,
      heading: 0,
      headingAccuracy: 0,
      speed: 0,
      speedAccuracy: 0,
    );
  }
}

class _Weather extends WeatherService {
  int weatherCode = 0;
  bool isStale = false;
  DateTime fetchedAt = DateTime.now();

  @override
  Future<WeatherSnapshot?> fetch(double latitude, double longitude) async => WeatherSnapshot(
    weatherCode: weatherCode,
    temperatureC: 20,
    precipitationProbabilityNext3h: const [],
    fetchedAt: fetchedAt,
    isStale: isStale,
  );
}

class _FullBattery extends BatteryMonitor {
  @override
  Future<bool> isLow() async => false;
}

class _FakeConnectivity implements Connectivity {
  @override
  Future<List<ConnectivityResult>> checkConnectivity() async => [ConnectivityResult.wifi];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _CapturingSink implements AnalyticsEventSink {
  final List<Map<String, dynamic>> events = [];

  @override
  Future<void> insertAnalyticsEvent(Map<String, dynamic> event) async => events.add(event);
}

class _FakeRepository implements QuestRepository {
  List<Quest> quests = [];
  List<UserQuest> attempts = [];
  List<QuestStep> steps = const [];
  List<QuestPhotoProof> proofs = const [];
  List<PendingPhotoProof> pendingProofs = const [];
  bool queues = false;
  AppException? abandonError;
  Completer<void>? abandonGate;
  final List<({String id, String reason})> abandons = [];
  int accepts = 0;

  @override
  Future<List<Quest>> getCatalog() async => quests;

  @override
  Future<List<UserQuest>> getUserQuests(String userId) async => attempts;

  @override
  Future<List<QuestStep>> getSteps(String questId) async => steps;

  @override
  Future<({UserQuest userQuest, bool queued})> abandonQuestOrQueue(
    UserQuest userQuest, {
    required String reason,
  }) async {
    abandons.add((id: userQuest.id, reason: reason));
    await abandonGate?.future;
    if (abandonError != null) throw abandonError!;
    return (userQuest: userQuest.copyWithProgress(status: 'abandoned'), queued: queues);
  }

  @override
  Future<UserQuest> acceptQuest({required String userId, required String questId}) async {
    accepts++;
    throw const AppException('not expected');
  }

  @override
  StepSession? getActiveStepSession() => null;

  @override
  Future<void> saveActiveStepSession(StepSession? session) async {}

  @override
  Map<String, int> getStepTotals() => const {};

  @override
  VerifiedCheckIn? getVerifiedCheckIn() => null;

  @override
  Future<void> saveVerifiedCheckIn(VerifiedCheckIn? checkIn) async {}

  @override
  List<PendingPhotoProof> getPendingPhotoProofs() => pendingProofs;

  @override
  Future<List<QuestPhotoProof>> getPhotoProofs(String attemptId) async => proofs;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late _FakeRepository repository;
  late _Location location;
  late _Weather weather;
  late _CapturingSink sink;
  late QuestViewModel viewModel;

  Iterable<Map<String, dynamic>> eventsOf(String type) =>
      sink.events.where((event) => event['event_type'] == type);

  Map<String, dynamic> abandonedEvent() => eventsOf(AnalyticsEventType.questAbandoned).single;

  Map<String, dynamic> abandonedMetadata() =>
      (abandonedEvent()['metadata'] as Map).cast<String, dynamic>();

  Future<void> settle() => pumpEventQueue(times: 50);

  Future<void> loadMission() async {
    repository.attempts = [_attempt()];
    await viewModel.load();
    await viewModel.loadSteps('source');
    await settle();
  }

  setUp(() {
    repository = _FakeRepository()
      ..quests = [
        _source,
        _quest('a', location: 'anywhere', minutes: 10),
        _quest('b', location: 'anywhere', minutes: 15),
        _quest('c', location: 'anywhere', minutes: 18),
        _quest('d', location: 'anywhere', minutes: 25),
      ]
      ..steps = [_step(0), _step(1), _step(2)];
    location = _Location()..metersFromQuest = 850;
    weather = _Weather();
    sink = _CapturingSink();
    ContextManager contextManager() => ContextManager(
      locationService: location,
      batteryMonitor: _FullBattery(),
      connectivity: _FakeConnectivity(),
      weatherService: weather,
    );
    viewModel = QuestViewModel(
      repository,
      contextManager(),
      AnalyticsTracker(eventSink: sink, contextManager: contextManager(), sessionId: 'session-1'),
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
  });

  group('AbandonmentReason', () {
    test('has exactly Kotlin\'s codes and emojis, in its order', () {
      expect(AbandonmentReason.values.map((reason) => (reason.code, reason.emoji)), [
        ('ran_out_of_time', '⏰'),
        ('too_far', '📍'),
        ('too_expensive', '💸'),
        ('place_unavailable', '🔒'),
        ('too_difficult', '😅'),
        ('weather_or_mood_changed', '🌧'),
        ('other', '💬'),
      ]);
    });

    test('every reason has a label in Spanish', () {
      expect(AbandonmentReason.tooFar.label, 'Quedaba muy lejos');
      expect(AbandonmentReason.values.every((reason) => reason.label.isNotEmpty), isTrue);
    });
  });

  group('distance evidence', () {
    test('the bands use Kotlin\'s exact thresholds', () {
      String band(int? meters, {bool anywhere = false}) =>
          questDistanceBand(meters: meters, isAnywhere: anywhere);

      expect(band(0), 'under_500_m');
      expect(band(499), 'under_500_m');
      expect(band(500), '500_m_to_1_5_km');
      expect(band(1499), '500_m_to_1_5_km');
      expect(band(1500), 'over_1_5_km');
      expect(band(null), 'unknown');
      expect(band(null, anywhere: true), 'location_independent');
      expect(band(200, anywhere: true), 'location_independent');
    });

    test('the label reads the distance, with a decimal comma', () {
      String label(int? meters, {bool anywhere = false}) =>
          questDistanceLabel(meters: meters, isAnywhere: anywhere);

      expect(label(850), '850 m');
      expect(label(999), '999 m');
      expect(label(1000), '1,0 km');
      expect(label(1234), '1,2 km');
      expect(label(null), 'Desconocida');
      expect(label(50, anywhere: true), 'Donde sea');
    });

    test('progress rounds like Kotlin, and 0 without steps', () {
      expect(questProgressPercent(completedSteps: 1, totalSteps: 3), 33);
      expect(questProgressPercent(completedSteps: 1, totalSteps: 8), 13);
      expect(questProgressPercent(completedSteps: 2, totalSteps: 2), 100);
      expect(questProgressPercent(completedSteps: 0, totalSteps: 0), 0);
    });
  });

  group('quest_abandoned', () {
    test('sends Kotlin\'s metadata plus the GPS source and the platform', () async {
      await loadMission();

      await viewModel.abandonQuest(_attempt(), reason: AbandonmentReason.tooFar);
      await settle();

      final metadata = abandonedMetadata();
      final meters = abandonedEvent()['distance_meters'] as int;
      expect(metadata, {
        'schema_version': 1,
        'platform': 'flutter',
        'attempt_id': 'uq-1',
        'reason': 'too_far',
        'reason_code': 'too_far',
        'reason_label': 'Quedaba muy lejos',
        'quest_duration_minutes': 60,
        'estimated_cost': 12.0,
        'quest_distance_label': '$meters m',
        'quest_distance_meters': meters,
        'quest_distance_band': '500_m_to_1_5_km',
        'quest_distance_source': 'gps',
        'current_step_index': 1,
        'completed_step_count': 1,
        'total_step_count': 3,
        'progress_percent': 33,
        'had_photo_proof': false,
        'uploaded_photo_proof_count': 0,
      });
      expect(meters, closeTo(850, 2));
    });

    test('keeps the event columns, including the GPS distance and the coordinates', () async {
      await loadMission();

      await viewModel.abandonQuest(
        _attempt(),
        reason: AbandonmentReason.other,
        preferences: const UserPreferences(socialLevel: 'group'),
      );
      await settle();

      final event = abandonedEvent();
      expect(event['quest_id'], 'source');
      expect(event['category'], 'food');
      expect(event['available_minutes'], viewModel.selectedMinutes);
      expect(event['social_level'], 'group');
      expect(event['location_mode'], viewModel.selectedLocationScope);
      expect(event['quest_duration_minutes'], 60);
      expect(event['quest_difficulty'], 'easy');
      expect(event['estimated_cost'], 12.0);
      expect(event['distance_meters'], isNotNull);
      expect(event['latitude'], isNotNull);
      expect(event['longitude'], isNotNull);
    });

    test('a quest done anywhere has no distance in its evidence', () async {
      repository.quests = [_quest('source', location: 'anywhere', latitude: 4.6, longitude: -74.07)];
      await loadMission();

      await viewModel.abandonQuest(_attempt(), reason: AbandonmentReason.other);
      await settle();

      final metadata = abandonedMetadata();
      expect(metadata['quest_distance_band'], 'location_independent');
      expect(metadata['quest_distance_label'], 'Donde sea');
      expect(metadata.containsKey('quest_distance_meters'), isFalse);
    });

    test('without a GPS fix the band is unknown, and it is still sent', () async {
      location.metersFromQuest = null;
      await loadMission();

      await viewModel.abandonQuest(_attempt(), reason: AbandonmentReason.other);
      await settle();

      final metadata = abandonedMetadata();
      expect(metadata['quest_distance_band'], 'unknown');
      expect(metadata['quest_distance_label'], 'Desconocida');
      expect(metadata.containsKey('quest_distance_meters'), isFalse);
      expect(abandonedEvent().containsKey('distance_meters'), isFalse);
    });

    test('counts the photo proofs of this attempt', () async {
      repository
        ..steps = [_step(0, verification: 'photo'), _step(1)]
        ..proofs = [
          QuestPhotoProof(
            id: 'p1',
            attemptId: 'uq-1',
            stepOrder: 0,
            storagePath: 'x.jpg',
            uploadedAt: DateTime(2026, 10, 1),
          ),
        ];
      await loadMission();

      await viewModel.abandonQuest(_attempt(), reason: AbandonmentReason.other);
      await settle();

      expect(abandonedMetadata()['had_photo_proof'], isTrue);
      expect(abandonedMetadata()['uploaded_photo_proof_count'], 1);
    });

    test('a photo still waiting to upload counts as had, not as uploaded', () async {
      await loadMission();
      viewModel.pendingPhotoProofs = [
        PendingPhotoProof(
          localPath: 'x.jpg',
          storagePath: 'x.jpg',
          attemptId: 'uq-1',
          questId: 'source',
          stepOrder: 0,
          sizeBytes: 1,
          capturedAt: DateTime(2026, 10, 1),
        ),
      ];

      await viewModel.abandonQuest(_attempt(), reason: AbandonmentReason.other);
      await settle();

      expect(abandonedMetadata()['had_photo_proof'], isTrue);
      expect(abandonedMetadata()['uploaded_photo_proof_count'], 0);
    });

    test('another attempt\'s pending photo does not count', () async {
      await loadMission();
      viewModel.pendingPhotoProofs = [
        PendingPhotoProof(
          localPath: 'x.jpg',
          storagePath: 'x.jpg',
          attemptId: 'other-attempt',
          questId: 'source',
          stepOrder: 0,
          sizeBytes: 1,
          capturedAt: DateTime(2026, 10, 1),
        ),
      ];

      await viewModel.abandonQuest(_attempt(), reason: AbandonmentReason.other);
      await settle();

      expect(abandonedMetadata()['had_photo_proof'], isFalse);
    });

    test('uses the attempt as it is now, not the screen\'s older copy', () async {
      await loadMission();
      final older = UserQuest(
        id: 'uq-1',
        userId: _userId,
        questId: 'source',
        acceptedAt: DateTime(2026, 10, 1),
      );

      await viewModel.abandonQuest(older, reason: AbandonmentReason.other);
      await settle();

      expect(abandonedMetadata()['completed_step_count'], 1);
    });
  });

  group('abandoning', () {
    test('saves the reason\'s code', () async {
      await loadMission();

      await viewModel.abandonQuest(_attempt(), reason: AbandonmentReason.placeUnavailable);

      expect(repository.abandons.single.reason, 'place_unavailable');
    });

    test('closes the mission: no longer the current one', () async {
      await loadMission();

      expect(viewModel.currentMission, isNotNull);
      await viewModel.abandonQuest(_attempt(), reason: AbandonmentReason.other);

      expect(viewModel.currentMission, isNull);
    });

    test('an abandoned attempt from the server is not a current mission either', () async {
      repository.attempts = [_attempt(status: 'abandoned')];

      await viewModel.load();

      expect(viewModel.currentMission, isNull);
    });

    test('repeated taps: one write and one event', () async {
      await loadMission();
      repository.abandonGate = Completer<void>();

      final first = viewModel.abandonQuest(_attempt(), reason: AbandonmentReason.other);
      final second = viewModel.abandonQuest(_attempt(), reason: AbandonmentReason.tooFar);
      repository.abandonGate!.complete();

      expect(await first, isTrue);
      expect(await second, isTrue);
      await settle();
      expect(repository.abandons, hasLength(1));
      expect(eventsOf(AnalyticsEventType.questAbandoned), hasLength(1));
    });

    test('once abandoned, another call changes nothing', () async {
      await loadMission();
      await viewModel.abandonQuest(_attempt(), reason: AbandonmentReason.other);
      await settle();

      expect(await viewModel.abandonQuest(_attempt(), reason: AbandonmentReason.tooFar), isTrue);
      await settle();

      expect(repository.abandons, hasLength(1));
      expect(eventsOf(AnalyticsEventType.questAbandoned), hasLength(1));
    });

    test('a failed attempt can be retried and tracks nothing until it works', () async {
      await loadMission();
      repository.abandonError = const AppException('Sin conexión', isRetryable: true);

      expect(await viewModel.abandonQuest(_attempt(), reason: AbandonmentReason.other), isFalse);
      await settle();
      expect(sink.events, isEmpty);
      expect(viewModel.questAlternatives, isNull);
      expect(viewModel.currentMission, isNotNull);

      repository.abandonError = null;
      expect(await viewModel.abandonQuest(_attempt(), reason: AbandonmentReason.other), isTrue);
      await settle();
      expect(eventsOf(AnalyticsEventType.questAbandoned), hasLength(1));
    });

    test('queued: says so, tracks the event and still offers alternatives', () async {
      repository.queues = true;
      await loadMission();

      expect(await viewModel.abandonQuest(_attempt(), reason: AbandonmentReason.other), isTrue);
      await settle();

      expect(viewModel.abandonmentQueued, isTrue);
      expect(eventsOf(AnalyticsEventType.questAbandoned), hasLength(1));
      expect(viewModel.questAlternatives!.suggestions, isNotEmpty);
    });
  });

  group('alternatives', () {
    Future<void> abandon({AbandonmentReason reason = AbandonmentReason.other}) async {
      await loadMission();
      await viewModel.abandonQuest(_attempt(), reason: reason);
      await settle();
    }

    test('offers at most 3 and logs each one, with Kotlin\'s metadata', () async {
      await abandon(reason: AbandonmentReason.ranOutOfTime);

      final state = viewModel.questAlternatives!;
      expect(state.isLoading, isFalse);
      expect(state.suggestions.map((a) => a.quest.id), ['a', 'b', 'c']);

      final shown = eventsOf(AnalyticsEventType.questAlternativeShown).toList();
      expect(shown.map((event) => event['quest_id']), ['a', 'b', 'c']);
      final metadata = (shown.first['metadata'] as Map).cast<String, dynamic>();
      expect(metadata, {
        'platform': 'flutter',
        'algorithm_version': 'lex_alternatives_v1',
        'source_quest_id': 'source',
        'source_attempt_id': 'uq-1',
        'reason_code': 'ran_out_of_time',
        'rank': 1,
        'score': state.suggestions.first.score,
        'applied_rules': state.suggestions.first.ruleCodes.join(','),
        'time_of_day': state.context!.timeOfDay,
        'weather_condition': 'clear',
        'context_source': 'device',
      });
      expect(
        shown.map((event) => (event['metadata'] as Map)['rank']),
        [1, 2, 3],
      );
    });

    test('its events leave the coordinates out', () async {
      await abandon();

      for (final event in eventsOf(AnalyticsEventType.questAlternativeShown)) {
        expect(event.containsKey('latitude'), isFalse);
        expect(event.containsKey('longitude'), isFalse);
        expect(event.containsKey('distance_meters'), isFalse);
      }
    });

    test('a last known weather that is too old is logged as unknown', () async {
      weather
        ..isStale = true
        ..weatherCode = 61
        ..fetchedAt = DateTime.now().subtract(const Duration(hours: 4));

      await abandon();

      final shown = eventsOf(AnalyticsEventType.questAlternativeShown).first;
      expect((shown['metadata'] as Map)['weather_condition'], 'unknown');
    });

    test('leaves out every quest with an attempt and those skipped this session', () async {
      repository.attempts = [_attempt(), _attempt(id: 'uq-old', questId: 'a', status: 'completed')];
      await viewModel.load();
      await viewModel.loadSteps('source');

      await viewModel.abandonQuest(_attempt(), reason: AbandonmentReason.other);
      await settle();

      final ids = viewModel.questAlternatives!.suggestions.map((a) => a.quest.id);
      expect(ids, isNot(contains('a')));
      expect(ids, isNot(contains('source')));
    });

    test('the abandoned quest not in the catalogue: empty, not an error', () async {
      repository.quests = [_quest('a', location: 'anywhere')];
      await abandon();

      final state = viewModel.questAlternatives!;
      expect(state.isLoading, isFalse);
      expect(state.suggestions, isEmpty);
      expect(eventsOf(AnalyticsEventType.questAlternativeShown), isEmpty);
    });

    test('refreshing logs what it shows again', () async {
      await abandon();
      final firstLoad = eventsOf(AnalyticsEventType.questAlternativeShown).length;

      await viewModel.refreshQuestAlternatives(const UserPreferences());
      await settle();

      expect(eventsOf(AnalyticsEventType.questAlternativeShown), hasLength(firstLoad * 2));
    });

    test('selecting one records it and never accepts the mission', () async {
      await abandon();
      final state = viewModel.questAlternatives!;

      viewModel.trackQuestAlternativeSelected(state.suggestions[1]);
      await settle();

      final selected = eventsOf(AnalyticsEventType.questAlternativeSelected).single;
      expect(selected['quest_id'], state.suggestions[1].quest.id);
      expect((selected['metadata'] as Map)['rank'], 2);
      expect((selected['metadata'] as Map)['platform'], 'flutter');
      expect(selected.containsKey('latitude'), isFalse);
      expect(repository.accepts, 0);
      expect(viewModel.currentMission, isNull);
    });

    test('leaving while they load logs nothing, even when the GPS answers later', () async {
      await loadMission();
      location.gate = Completer<void>();

      await viewModel.abandonQuest(_attempt(), reason: AbandonmentReason.other);
      await settle();
      expect(viewModel.questAlternatives!.isLoading, isTrue);

      viewModel.dismissQuestAlternatives();
      location.gate!.complete();
      await settle();

      expect(viewModel.questAlternatives, isNull);
      expect(eventsOf(AnalyticsEventType.questAlternativeShown), isEmpty);
    });

    test('a refresh that overtakes the first load: only the last one logs', () async {
      await loadMission();
      location.gate = Completer<void>();

      await viewModel.abandonQuest(_attempt(), reason: AbandonmentReason.other);
      await settle();
      final refresh = viewModel.refreshQuestAlternatives(const UserPreferences());
      location.gate!.complete();
      await refresh;
      await settle();

      final shown = eventsOf(AnalyticsEventType.questAlternativeShown);
      expect(shown, hasLength(viewModel.questAlternatives!.suggestions.length));
    });
  });
}
