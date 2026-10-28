import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sidequests/analytics/analytics_event_sink.dart';
import 'package:sidequests/analytics/analytics_event_type.dart';
import 'package:sidequests/analytics/analytics_tracker.dart';
import 'package:sidequests/data/context/context_manager.dart';
import 'package:sidequests/data/local/local_data_source.dart';
import 'package:sidequests/data/services/battery_monitor.dart';
import 'package:sidequests/data/services/location_service.dart';
import 'package:sidequests/data/services/weather_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _questLat = 4.6473;
const _questLon = -74.0600;
const _degPerMeter = 1 / 111195;

/// `public.analytics_events`: [offline] fails like a dropped connection,
/// [rejection] like PostgREST refusing the row.
class _FlakySink implements AnalyticsEventSink {
  bool offline = false;
  PostgrestException? rejection;
  final List<Map<String, dynamic>> inserted = [];

  @override
  Future<void> insertAnalyticsEvent(Map<String, dynamic> event) async {
    if (offline) throw const SocketException('offline');
    if (rejection != null) throw rejection!;
    inserted.add(event);
  }
}

/// The Hive box, in memory.
class _FakeLocal implements LocalDataSource {
  List<Map<String, dynamic>> pending = [];

  @override
  List<Map<String, dynamic>> getPendingAnalyticsEvents() => [...pending];

  @override
  Future<void> savePendingAnalyticsEvents(List<Map<String, dynamic>> events) async =>
      pending = events;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A GPS fix [metersNorth] of the quest.
class _FakeLocation extends LocationService {
  double metersNorth = 1000;

  @override
  Future<Position?> getCurrentPosition({
    LocationAccuracy accuracy = LocationAccuracy.medium,
  }) async => Position(
    latitude: _questLat + metersNorth * _degPerMeter,
    longitude: _questLon,
    timestamp: DateTime(2026, 10, 27),
    accuracy: 10,
    altitude: 0,
    altitudeAccuracy: 0,
    heading: 0,
    headingAccuracy: 0,
    speed: 0,
    speedAccuracy: 0,
  );
}

class _FullBattery extends BatteryMonitor {
  @override
  Future<bool> isLow() async => false;
}

// The flush after a successful insert is fire-and-forget.
Future<void> _settle() => Future<void>.delayed(Duration.zero);

String? _reason(Map<String, dynamic> event) => (event['metadata'] as Map)['reason'] as String?;

void main() {
  late _FlakySink sink;
  late _FakeLocal local;
  late _FakeLocation location;
  late AnalyticsTracker tracker;

  setUp(() {
    sink = _FlakySink();
    local = _FakeLocal();
    location = _FakeLocation();
    tracker = AnalyticsTracker(
      eventSink: sink,
      contextManager: ContextManager(
        locationService: location,
        batteryMonitor: _FullBattery(),
        weatherService: WeatherService(client: MockClient((_) async => http.Response('', 503))),
      ),
      sessionId: '7f1c0c4e-0000-4000-8000-000000000000',
      localDataSource: local,
    );
  });

  Future<void> abandon({String reason = 'too_far'}) => tracker.track(
    AnalyticsEventType.questAbandoned,
    questId: 'ramen-spot',
    estimatedCost: 25000,
    questLatitude: _questLat,
    questLongitude: _questLon,
    metadata: {'reason': reason, 'step': 1},
  );

  test('an abandonment that fails offline is kept with its distance and when it happened', () async {
    sink.offline = true;
    final before = DateTime.now().toUtc();

    await abandon();

    expect(sink.inserted, isEmpty);
    final queued = local.pending.single;
    expect(queued['event_type'], AnalyticsEventType.questAbandoned);
    expect(queued['distance_meters'], 1000);
    expect(queued['estimated_cost'], 25000);
    expect(queued['metadata'], {'reason': 'too_far', 'step': 1});
    final occurredAt = DateTime.parse(queued['occurred_at'] as String);
    expect(occurredAt.isBefore(before), isFalse);
  });

  test('back online, the next event that goes through sends the queue — nothing recomputed',
      () async {
    sink.offline = true;
    await abandon();
    final queued = Map.of(local.pending.single);

    // Later, somewhere else, connected again.
    location.metersNorth = 0;
    sink.offline = false;
    await tracker.track(AnalyticsEventType.questCompleted, questId: 'mural-walk');
    await _settle();

    expect(sink.inserted, hasLength(2));
    expect(sink.inserted.first['event_type'], AnalyticsEventType.questCompleted);
    // Sent right away: the backend's now() is still its timestamp.
    expect(sink.inserted.first.containsKey('occurred_at'), isFalse);
    // Same distance (1000 m, not 0) and same occurred_at as when queued.
    expect(sink.inserted.last, queued);
    expect(local.pending, isEmpty);
  });

  test('still offline during a flush: everything stays queued, then goes out oldest first',
      () async {
    sink.offline = true;
    await abandon(reason: 'too_far');
    await abandon(reason: 'bad_weather');

    await tracker.flushPending();
    expect(local.pending.map(_reason), ['too_far', 'bad_weather']);

    sink.offline = false;
    await tracker.flushPending();
    expect(sink.inserted.map(_reason), ['too_far', 'bad_weather']);
    expect(local.pending, isEmpty);
  });

  test('a server rejection is not queued: retrying would not help', () async {
    sink.rejection = const PostgrestException(message: 'violates check constraint', code: '23514');

    await abandon();

    expect(local.pending, isEmpty);
  });

  test('a queued event the server rejects on flush is dropped, not retried forever', () async {
    sink.offline = true;
    await abandon(reason: 'too_far');
    await abandon(reason: 'bad_weather');

    sink
      ..offline = false
      ..rejection = const PostgrestException(message: 'violates check constraint', code: '23514');
    await tracker.flushPending();

    expect(local.pending, isEmpty);
  });

  test('the queue is bounded: past the limit the oldest events are dropped', () async {
    sink.offline = true;
    for (var i = 0; i <= AnalyticsTracker.maxPendingEvents; i++) {
      await abandon(reason: 'r$i');
    }

    expect(local.pending, hasLength(AnalyticsTracker.maxPendingEvents));
    expect(_reason(local.pending.first), 'r1');
    expect(_reason(local.pending.last), 'r${AnalyticsTracker.maxPendingEvents}');
  });
}
