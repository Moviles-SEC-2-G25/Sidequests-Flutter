import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:sidequests/analytics/analytics_event_sink.dart';
import 'package:sidequests/analytics/analytics_tracker.dart';
import 'package:sidequests/core/app_exception.dart';
import 'package:sidequests/data/context/context_manager.dart';
import 'package:sidequests/data/services/battery_monitor.dart';
import 'package:sidequests/data/services/location_service.dart';
import 'package:sidequests/models/photo_proof.dart';
import 'package:sidequests/models/quest.dart';
import 'package:sidequests/models/step_session.dart';
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

const _quest = Quest(
  id: 'ramen',
  title: 'Ramen',
  category: 'food',
  durationMinutes: 20,
  difficulty: 'easy',
  locationMode: 'anywhere',
  socialLevel: 'solo',
);

final _attempt = UserQuest(
  id: 'uq-1',
  userId: 'user-1',
  questId: 'ramen',
  status: 'completed',
  acceptedAt: DateTime(2026, 1, 1),
);

/// Each request stays open until its completer is finished by the test.
class _GatedQuestRepository implements QuestRepository {
  final catalog = Completer<List<Quest>>();
  final attempts = Completer<List<UserQuest>>();
  int catalogCalls = 0;
  int attemptCalls = 0;

  @override
  Future<List<Quest>> getCatalog() {
    catalogCalls++;
    return catalog.future;
  }

  @override
  Future<List<UserQuest>> getUserQuests(String userId) {
    attemptCalls++;
    return attempts.future;
  }

  @override
  StepSession? getActiveStepSession() => null;

  @override
  List<PendingPhotoProof> getPendingPhotoProofs() => const [];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late _GatedQuestRepository repository;
  late QuestViewModel viewModel;

  setUp(() {
    repository = _GatedQuestRepository();
    viewModel = QuestViewModel(
      repository,
      _contextManager(),
      AnalyticsTracker(eventSink: _NullSink(), contextManager: _contextManager(), sessionId: 'unused'),
      'user-1',
    );
  });

  test('asks for the catalogue and the attempts at once', () async {
    final load = viewModel.load();

    // Neither has answered, and both were already requested.
    expect(repository.catalogCalls, 1);
    expect(repository.attemptCalls, 1);
    expect(viewModel.isLoading, isTrue);

    repository.attempts.complete([_attempt]); // the second one answers first
    await pumpEventQueue();
    expect(viewModel.isLoading, isTrue);

    repository.catalog.complete([_quest]);
    await load;

    expect(viewModel.isLoading, isFalse);
    expect(viewModel.catalog, [_quest]);
    expect(viewModel.userQuests, [_attempt]);
    expect(viewModel.errorMessage, isNull);
  });

  test('attempts failing keeps the catalogue and reports the error', () async {
    final load = viewModel.load();

    repository.attempts.completeError(const AppException('Sin misiones'));
    repository.catalog.complete([_quest]);
    await load;

    expect(viewModel.catalog, [_quest]);
    expect(viewModel.errorMessage, 'Sin misiones');
    expect(viewModel.isLoading, isFalse);
  });

  test('catalogue failing keeps the attempts and reports the error', () async {
    final load = viewModel.load();

    repository.catalog.completeError(const AppException('Sin catálogo'));
    repository.attempts.complete([_attempt]);
    await load;

    expect(viewModel.userQuests, [_attempt]);
    expect(viewModel.errorMessage, 'Sin catálogo');
    expect(viewModel.isLoading, isFalse);
  });

  test('both failing is reported once, with nothing left unhandled', () async {
    final load = viewModel.load();

    repository.catalog.completeError(const AppException('Primero'));
    repository.attempts.completeError(const AppException('Segundo'));
    await load;

    expect(viewModel.errorMessage, 'Primero');
    expect(viewModel.isLoading, isFalse);
  });
}
