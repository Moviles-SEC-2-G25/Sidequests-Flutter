import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sidequests/data/local/local_data_source.dart';
import 'package:sidequests/data/local/offline_pack_manifest_store.dart';
import 'package:sidequests/data/offline/offline_pack_entry.dart';
import 'package:sidequests/data/offline/offline_pack_manager.dart';
import 'package:sidequests/data/remote/supabase_remote_data_source.dart';
import 'package:sidequests/repository/quest_repository.dart';

/// Supabase in memory; [offline] fails every call like a dropped connection.
class _FakeRemote implements SupabaseRemoteDataSource {
  bool offline = false;
  int stepRequests = 0;

  @override
  Future<List<Map<String, dynamic>>> getActiveQuests() async {
    if (offline) throw const SocketException('offline');
    return [
      {
        'id': 'mercado',
        'title': 'Mercado de Paloquemao',
        'category': 'food',
        'emoji': '🍍',
        'duration_minutes': 45,
        'difficulty': 'easy',
        'location_mode': 'gps',
        'social_level': 'solo',
      },
    ];
  }

  @override
  Future<List<Map<String, dynamic>>> getQuestSteps(String questId) async {
    stepRequests++;
    if (offline) throw const SocketException('offline');
    return [
      {'id': 2, 'quest_id': questId, 'step_order': 1, 'title': 'Prueba una fruta', 'description': 'Pide una que no conozcas.'},
      {'id': 1, 'quest_id': questId, 'step_order': 0, 'title': 'Llega al mercado', 'description': 'Entra por la Calle 19.'},
    ];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// The Hive box, in memory: the cache the app already has.
class _FakeLocal implements LocalDataSource {
  List<Map<String, dynamic>> catalog = [];
  final steps = <String, List<Map<String, dynamic>>>{};

  @override
  List<Map<String, dynamic>> getQuestCatalog() => catalog;

  @override
  Future<void> cacheQuestCatalog(List<Map<String, dynamic>> quests) async => catalog = quests;

  @override
  List<Map<String, dynamic>>? getQuestSteps(String questId) => steps[questId];

  @override
  Future<void> cacheQuestSteps(String questId, List<Map<String, dynamic>> rows) async =>
      steps[questId] = rows;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late Directory directory;

  setUp(() async => directory = await Directory.systemTemp.createTemp('offline_pack_real'));
  tearDown(() => directory.delete(recursive: true));

  test('a pack quest prepared online opens offline: its detail and steps come from the cache', () async {
    final remote = _FakeRemote();
    final local = _FakeLocal();
    final manager = OfflinePackManager(
      QuestRepository(remote, local),
      OfflinePackManifestStore(directory: () async => directory, isWeb: false),
    );

    await manager.addQuest('mercado', isOnline: true);
    expect(manager.entries.value.single.status, OfflinePackStatus.ready);

    // The connection drops and the app starts again (new repository: empty
    // memory cache, only what Hive kept).
    remote.offline = true;
    final offlineRepository = QuestRepository(remote, local);
    final reopened = OfflinePackManager(
      offlineRepository,
      OfflinePackManifestStore(directory: () async => directory, isWeb: false),
    );
    await reopened.restore(isOnline: false);

    expect(reopened.entries.value.single, const OfflinePackEntry('mercado', OfflinePackStatus.ready));
    final quest = (await offlineRepository.getCatalog()).single;
    expect(quest.title, 'Mercado de Paloquemao');
    final steps = await offlineRepository.getSteps('mercado');
    expect(steps.map((s) => s.title), ['Llega al mercado', 'Prueba una fruta']);
    expect(steps.first.description, 'Entra por la Calle 19.');
  });
}
