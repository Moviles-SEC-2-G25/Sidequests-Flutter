import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sidequests/analytics/analytics_event_sink.dart';
import 'package:sidequests/analytics/analytics_tracker.dart';
import 'package:sidequests/data/context/context_manager.dart';
import 'package:sidequests/data/local/local_data_source.dart';
import 'package:sidequests/data/remote/supabase_remote_data_source.dart';
import 'package:sidequests/data/services/battery_monitor.dart';
import 'package:sidequests/data/services/location_service.dart';
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

class _SilentTracker extends AnalyticsTracker {
  _SilentTracker()
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
  }) async {}
}

ContextManager _contextManager() =>
    ContextManager(locationService: _NoLocation(), batteryMonitor: _FullBattery());

/// Only the two reads QuestViewModel.load() needs; anything else would throw.
class _FakeRemote implements SupabaseRemoteDataSource {
  List<Map<String, dynamic>> quests = [];

  @override
  Future<List<Map<String, dynamic>>> getActiveQuests() async => quests;

  @override
  Future<List<Map<String, dynamic>>> getUserQuests(String userId) async => [];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Map<String, dynamic> _quest(String id, String category, {int minutes = 20}) => {
  'id': id,
  'title': 'Quest $id',
  'category': category,
  'duration_minutes': minutes,
  'difficulty': 'easy',
  'location_mode': 'anywhere',
  'social_level': 'solo',
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
  late Directory documents;
  late _FakeRemote remote;

  setUp(() async {
    documents = await Directory.systemTemp.createTemp('explore_filters_test');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      pathProvider,
      (_) async => documents.path,
    );
    SharedPreferences.setMockInitialValues({});
    remote = _FakeRemote()..quests = [_quest('a', 'food'), _quest('b', 'art', minutes: 60)];
  });

  tearDown(() async {
    await Hive.close();
    await documents.delete(recursive: true);
  });

  /// What main() and app.dart do on launch. Finishes pending writes and drops
  /// SharedPreferences' in-memory copy first, so whatever comes back was
  /// really read from the store.
  Future<(QuestViewModel, LocalDataSource)> launchApp() async {
    await pumpEventQueue();
    SharedPreferences.resetStatic();
    final local = LocalDataSource();
    await local.init();
    final repository = QuestRepository(remote, local);
    final viewModel = QuestViewModel(
      repository,
      _contextManager(),
      _SilentTracker(),
      'user-1',
      initialFilters: repository.getExploreFilters(),
    );
    return (viewModel, local);
  }

  test('primer arranque, sin nada guardado: usa los valores por defecto', () async {
    final (viewModel, _) = await launchApp();

    expect(viewModel.selectedMinutes, 30);
    expect(viewModel.selectedLocationScope, 'all');
    expect(viewModel.selectedCategory, isNull);
  });

  test('los tres filtros sobreviven a un reinicio y siguen filtrando el catálogo', () async {
    final (first, _) = await launchApp();
    first.setMinutes(60);
    first.setLocationScope('anywhere');
    first.setCategory('art');

    final (restarted, _) = await launchApp();
    await restarted.load();

    expect(restarted.selectedMinutes, 60);
    expect(restarted.selectedLocationScope, 'anywhere');
    expect(restarted.selectedCategory, 'art');
    expect(restarted.filteredCatalog.map((q) => q.id), ['b']);
  });

  test('volver a "Todo" también se guarda', () async {
    final (first, _) = await launchApp();
    first.setCategory('art');
    first.setCategory(null);

    final (restarted, _) = await launchApp();

    expect(restarted.selectedCategory, isNull);
  });

  test('cerrar sesión no los borra: son del dispositivo, como el modo oscuro', () async {
    final (first, local) = await launchApp();
    first.setMinutes(45);
    await pumpEventQueue();

    await local.clear();
    final (restarted, _) = await launchApp();

    expect(restarted.selectedMinutes, 45);
  });

  test('una categoría que ya no está en el catálogo vuelve a "Todo", también tras reiniciar', () async {
    final (first, _) = await launchApp();
    first.setMinutes(60);
    first.setCategory('art');

    remote.quests = [_quest('a', 'food')];
    final (afterCatalogChange, _) = await launchApp();
    await afterCatalogChange.load();

    expect(afterCatalogChange.selectedCategory, isNull);
    expect(afterCatalogChange.filteredCatalog.map((q) => q.id), ['a']);

    final (restarted, _) = await launchApp();
    expect(restarted.selectedCategory, isNull);
    expect(restarted.selectedMinutes, 60);
  });

  test('un catálogo vacío no descarta la categoría guardada', () async {
    final (first, _) = await launchApp();
    first.setCategory('art');

    remote.quests = [];
    final (restarted, _) = await launchApp();
    await restarted.load();

    expect(restarted.selectedCategory, 'art');
  });

  test('"¿Cómo te sientes hoy?" sigue siendo solo de la sesión', () async {
    final (first, _) = await launchApp();
    first.setSessionSocialLevel('group');

    final (restarted, _) = await launchApp();

    expect(restarted.sessionSocialLevel, isNull);
  });
}
