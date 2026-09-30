import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:sidequests/analytics/analytics_event_sink.dart';
import 'package:sidequests/analytics/analytics_tracker.dart';
import 'package:sidequests/data/context/context_manager.dart';
import 'package:sidequests/data/services/battery_monitor.dart';
import 'package:sidequests/data/services/location_service.dart';
import 'package:sidequests/models/app_context.dart';
import 'package:sidequests/models/quest.dart';
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

/// Never actually called: `currentContext` is set directly in every test.
class _UnusedQuestRepository implements QuestRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Quest _quest(String id, {required String locationMode, int durationMinutes = 20}) => Quest(
  id: id,
  title: 'Quest $id',
  category: 'food',
  durationMinutes: durationMinutes,
  difficulty: 'easy',
  locationMode: locationMode,
  socialLevel: 'solo',
);

AppContext _appContext({bool isRainy = false, String timeOfDay = 'afternoon'}) =>
    AppContext(timeOfDay: timeOfDay, dayOfWeek: 'monday', isConnected: true, isRainy: isRainy);

void main() {
  late QuestViewModel viewModel;

  setUp(() {
    viewModel = QuestViewModel(
      _UnusedQuestRepository(),
      _contextManager(),
      AnalyticsTracker(eventSink: _NullSink(), contextManager: _contextManager(), sessionId: 'unused'),
      'user-1',
    );
    // Interleaved on purpose: order should be untouched unless adapting.
    viewModel.catalog = [
      _quest('gps-1', locationMode: 'gps'),
      _quest('anywhere-1', locationMode: 'anywhere'),
      _quest('gps-2', locationMode: 'gps'),
      _quest('anywhere-2', locationMode: 'anywhere'),
    ];
  });

  test('sin lluvia ni noche, filteredCatalog conserva el orden del catálogo', () {
    viewModel.currentContext = _appContext();

    expect(viewModel.isAdaptingToContext, isFalse);
    expect(viewModel.filteredCatalog.map((q) => q.id), [
      'gps-1',
      'anywhere-1',
      'gps-2',
      'anywhere-2',
    ]);
  });

  test('con lluvia, filteredCatalog pone primero las misiones anywhere sin ocultar las demás', () {
    viewModel.currentContext = _appContext(isRainy: true);

    expect(viewModel.isAdaptingToContext, isTrue);
    expect(viewModel.filteredCatalog.map((q) => q.id), [
      'anywhere-1',
      'anywhere-2',
      'gps-1',
      'gps-2',
    ]);
    expect(viewModel.filteredCatalog.length, viewModel.catalog.length);
  });

  test('de noche (sin lluvia) también prioriza las misiones anywhere', () {
    viewModel.currentContext = _appContext(timeOfDay: 'night');

    expect(viewModel.isAdaptingToContext, isTrue);
    expect(viewModel.filteredCatalog.map((q) => q.id), [
      'anywhere-1',
      'anywhere-2',
      'gps-1',
      'gps-2',
    ]);
  });

  test('sin contexto cargado todavía (currentContext null), no reordena', () {
    expect(viewModel.currentContext, isNull);
    expect(viewModel.isAdaptingToContext, isFalse);
    expect(viewModel.filteredCatalog.map((q) => q.id), [
      'gps-1',
      'anywhere-1',
      'gps-2',
      'anywhere-2',
    ]);
  });

  test('el reordenamiento por lluvia respeta el resto de filtros existentes (minutos)', () {
    viewModel.currentContext = _appContext(isRainy: true);
    viewModel.setMinutes(20);
    viewModel.catalog = [
      ...viewModel.catalog,
      _quest('anywhere-too-long', locationMode: 'anywhere', durationMinutes: 999),
    ];

    expect(viewModel.filteredCatalog.map((q) => q.id), isNot(contains('anywhere-too-long')));
  });
}
