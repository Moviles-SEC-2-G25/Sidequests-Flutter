import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:provider/provider.dart';
import 'package:sidequests/analytics/analytics_event_sink.dart';
import 'package:sidequests/analytics/analytics_tracker.dart';
import 'package:sidequests/core/verification/step_verification_strategy.dart';
import 'package:sidequests/data/context/context_manager.dart';
import 'package:sidequests/data/services/battery_monitor.dart';
import 'package:sidequests/data/services/location_check_in_service.dart';
import 'package:sidequests/data/services/location_service.dart';
import 'package:sidequests/data/services/step_counter_service.dart';
import 'package:sidequests/data/services/weather_service.dart';
import 'package:sidequests/models/quest.dart';
import 'package:sidequests/models/quest_step.dart';
import 'package:sidequests/models/weather_snapshot.dart';
import 'package:sidequests/repository/quest_repository.dart';
import 'package:sidequests/view/quests/quest_detail_view.dart';
import 'package:sidequests/viewmodel/quests/quest_view_model.dart';

const _unavailable = 'Clima no disponible sin conexión';

/// No coordinates, so the card asks [LocationService] for the position.
const _quest = Quest(
  id: 'a',
  title: 'Quest a',
  category: 'food',
  durationMinutes: 20,
  difficulty: 'easy',
  locationMode: 'anywhere',
  socialLevel: 'solo',
);

class _FakeLocation extends LocationService {
  final bool hasFix;

  _FakeLocation({this.hasFix = true});

  @override
  Future<Position?> getCurrentPosition({
    LocationAccuracy accuracy = LocationAccuracy.medium,
  }) async => hasFix
      ? Position(
          latitude: 4.6,
          longitude: -74.06,
          timestamp: DateTime(2026),
          accuracy: 10,
          altitude: 0,
          altitudeAccuracy: 0,
          heading: 0,
          headingAccuracy: 0,
          speed: 0,
          speedAccuracy: 0,
        )
      : null;
}

class _FakeWeather extends WeatherService {
  final Future<WeatherSnapshot?> result;

  _FakeWeather(this.result);

  @override
  Future<WeatherSnapshot?> fetch(double latitude, double longitude) => result;
}

class _FullBattery extends BatteryMonitor {
  @override
  Future<bool> isLow() async => false;
}

class _NullSink implements AnalyticsEventSink {
  @override
  Future<void> insertAnalyticsEvent(Map<String, dynamic> event) async {}
}

class _FakeQuestRepository implements QuestRepository {
  @override
  Future<List<QuestStep>> getSteps(String questId) async => const [];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

WeatherSnapshot _snapshot({required Duration age, required bool isStale}) {
  final snapshot = WeatherSnapshot(
    weatherCode: 61,
    temperatureC: 18.4,
    precipitationProbabilityNext3h: const [10, 40, 70],
    fetchedAt: DateTime.now().subtract(age),
  );
  return isStale ? snapshot.asStale() : snapshot;
}

void main() {
  Future<void> pumpDetail(
    WidgetTester tester, {
    required Future<WeatherSnapshot?> weather,
    bool hasFix = true,
  }) async {
    final contextManager = ContextManager(
      locationService: _FakeLocation(hasFix: false),
      batteryMonitor: _FullBattery(),
    );
    final viewModel = QuestViewModel(
      _FakeQuestRepository(),
      contextManager,
      AnalyticsTracker(eventSink: _NullSink(), contextManager: contextManager, sessionId: 'unused'),
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
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<QuestViewModel>.value(value: viewModel),
          Provider<LocationService>.value(value: _FakeLocation(hasFix: hasFix)),
          Provider<WeatherService>.value(value: _FakeWeather(weather)),
        ],
        child: const MaterialApp(home: QuestDetailView(quest: _quest)),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  testWidgets('fresh: rain chance and no offline label', (tester) async {
    await pumpDetail(
      tester,
      weather: Future.value(_snapshot(age: const Duration(minutes: 5), isStale: false)),
    );

    expect(find.text('18°C · Lluvia ligera'), findsOneWidget);
    expect(find.text('Lluvia próximas 3 h: 70%'), findsOneWidget);
    expect(find.textContaining('Último dato'), findsNothing);
  });

  testWidgets('stale under 3 h: says how old it is and keeps the rain chance', (tester) async {
    await pumpDetail(
      tester,
      weather: Future.value(_snapshot(age: const Duration(minutes: 45), isStale: true)),
    );

    expect(find.text('Último dato: hace 45 min · sin conexión'), findsOneWidget);
    expect(find.text('Lluvia próximas 3 h: 70%'), findsOneWidget);
  });

  testWidgets('stale over 3 h: hides the rain chance, the forecast ran out', (tester) async {
    await pumpDetail(
      tester,
      weather: Future.value(_snapshot(age: const Duration(hours: 3, minutes: 1), isStale: true)),
    );

    expect(find.text('Último dato: hace 181 min · sin conexión'), findsOneWidget);
    expect(find.text('18°C · Lluvia ligera'), findsOneWidget);
    expect(find.textContaining('Lluvia próximas'), findsNothing);
  });

  testWidgets('no data: small text instead of disappearing', (tester) async {
    await pumpDetail(tester, weather: Future.value(null));

    expect(find.text(_unavailable), findsOneWidget);
    expect(find.text('CLIMA EN EL LUGAR'), findsNothing);
  });

  testWidgets('still loading: no "not available" flash', (tester) async {
    final weather = Completer<WeatherSnapshot?>();
    await pumpDetail(tester, weather: weather.future);

    expect(find.text(_unavailable), findsNothing);

    weather.complete(null);
    await tester.pump();
    await tester.pump();

    expect(find.text(_unavailable), findsOneWidget);
  });

  testWidgets('no position: stays hidden, connectivity is not what failed', (tester) async {
    await pumpDetail(tester, weather: Future.value(null), hasFix: false);

    expect(find.text(_unavailable), findsNothing);
    expect(find.text('CLIMA EN EL LUGAR'), findsNothing);
  });
}
