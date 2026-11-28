import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sidequests/core/app_exception.dart';
import 'package:sidequests/data/local/local_data_source.dart';
import 'package:sidequests/data/local/offline_pack_manifest_store.dart';
import 'package:sidequests/data/offline/offline_pack_entry.dart';
import 'package:sidequests/data/offline/offline_pack_manager.dart';
import 'package:sidequests/data/remote/supabase_remote_data_source.dart';
import 'package:sidequests/models/quest.dart';
import 'package:sidequests/models/quest_step.dart';
import 'package:sidequests/repository/auth_repository.dart';
import 'package:sidequests/repository/quest_repository.dart';

Quest _quest(String id) => Quest(
  id: id,
  title: 'Quest $id',
  category: 'food',
  durationMinutes: 30,
  difficulty: 'easy',
  locationMode: 'gps',
  socialLevel: 'solo',
);

List<QuestStep> _steps(String questId, {String description = 'Do it'}) => [
  for (var i = 0; i < 2; i++)
    QuestStep(id: i, questId: questId, stepOrder: i, title: 'Step $i', description: description),
];

/// QuestRepository with its Hive cache ([savedCatalog], [savedSteps]) and the
/// server ([remoteSteps]) in memory. [hold] keeps a quest's download waiting.
class _FakeRepository implements QuestRepository {
  final savedCatalog = <Quest>[];
  final remoteCatalog = <Quest>[];
  final savedSteps = <String, List<QuestStep>>{};
  final remoteSteps = <String, List<QuestStep>>{};
  final hold = <String, Completer<void>>{};
  final stepRequests = <String>[];
  bool offline = false;
  int active = 0;
  int maxActive = 0;

  @override
  bool catalogFromCache = false;

  @override
  List<Quest> getCachedCatalog() => [...savedCatalog];

  @override
  bool hasCachedSteps(String questId) => savedSteps.containsKey(questId);

  @override
  List<QuestStep>? getCachedSteps(String questId) => savedSteps[questId];

  @override
  Future<List<Quest>> getCatalog() async {
    catalogFromCache = offline;
    if (!offline) {
      savedCatalog
        ..clear()
        ..addAll(remoteCatalog);
    }
    return [...savedCatalog];
  }

  /// Like the real one: a server answer is saved; a failure falls back to
  /// what's saved, or throws when nothing is.
  @override
  Future<List<QuestStep>> getSteps(String questId) async {
    stepRequests.add(questId);
    active++;
    maxActive = math.max(maxActive, active);
    try {
      await hold[questId]?.future;
      final remote = remoteSteps[questId];
      if (offline || remote == null) {
        final saved = savedSteps[questId];
        if (saved != null) return saved;
        throw const AppException('Offline', isRetryable: true);
      }
      savedSteps[questId] = remote;
      return remote;
    } finally {
      active--;
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A quest the server has, with complete steps.
void _onServer(_FakeRepository repository, String id) {
  repository.remoteCatalog.add(_quest(id));
  repository.remoteSteps[id] = _steps(id);
}

/// A quest already saved on the device, complete.
void _saved(_FakeRepository repository, String id) {
  repository.savedCatalog.add(_quest(id));
  repository.savedSteps[id] = _steps(id);
  repository.remoteCatalog.add(_quest(id));
}

class _FakeRemote implements SupabaseRemoteDataSource {
  @override
  Future<void> signOut() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeLocal implements LocalDataSource {
  bool cleared = false;

  @override
  Future<void> clear() async => cleared = true;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late Directory directory;
  late File manifest;
  late _FakeRepository repository;
  late OfflinePackManager manager;

  OfflinePackManifestStore store() => OfflinePackManifestStore(directory: () async => directory, isWeb: false);

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('offline_pack_test');
    manifest = File('${directory.path}${Platform.pathSeparator}${OfflinePackManifestStore.fileName}');
    repository = _FakeRepository();
    manager = OfflinePackManager(repository, store());
  });

  tearDown(() => directory.delete(recursive: true));

  List<String> savedIds() =>
      ((jsonDecode(manifest.readAsStringSync()) as Map)['selectedQuestIds'] as List).cast<String>();

  OfflinePackStatus statusOf(String id) =>
      manager.entries.value.singleWhere((e) => e.questId == id).status;

  group('the manifest (local storage)', () {
    test('adding twice is the same as once', () async {
      _onServer(repository, 'a');

      await manager.addQuest('a', isOnline: true);
      await manager.addQuest('a', isOnline: true);

      expect(savedIds(), ['a']);
      expect(manager.entries.value, hasLength(1));
      expect(repository.stepRequests, ['a'], reason: 'ready the second time: no new download');
    });

    test('Kotlin\'s JSON, written through a .tmp that never stays behind', () async {
      _onServer(repository, 'a');
      _onServer(repository, 'b');

      await manager.addQuest('a', isOnline: false);
      await manager.addQuest('b', isOnline: false);

      expect(jsonDecode(manifest.readAsStringSync()), {
        'selectedQuestIds': ['a', 'b'],
      });
      expect(File('${manifest.path}.tmp').existsSync(), isFalse);
    });

    test('removing only changes the manifest: the cached quest and steps stay', () async {
      _saved(repository, 'a');
      await manager.addQuest('a', isOnline: true);

      await manager.removeQuest('a');

      expect(savedIds(), isEmpty);
      expect(manager.entries.value, isEmpty);
      expect(repository.hasCachedSteps('a'), isTrue);
      expect(repository.getCachedCatalog().map((q) => q.id), ['a']);
    });

    test('opening the app again restores the selection, checking what is cached', () async {
      _saved(repository, 'a');
      _onServer(repository, 'b');
      await manager.addQuest('a', isOnline: false);
      await manager.addQuest('b', isOnline: false);

      final reopened = OfflinePackManager(repository, store());
      await reopened.restore(isOnline: false);

      expect(reopened.entries.value, const [
        OfflinePackEntry('a', OfflinePackStatus.ready),
        OfflinePackEntry('b', OfflinePackStatus.pendingDownload),
      ]);
      expect(repository.stepRequests, isEmpty, reason: 'offline: nothing asked for');
    });

    test('opening the app online prepares the pending ones', () async {
      _onServer(repository, 'b');
      await manager.addQuest('b', isOnline: false);

      final reopened = OfflinePackManager(repository, store());
      await reopened.restore(isOnline: true);

      expect(reopened.entries.value.single.status, OfflinePackStatus.ready);
    });

    test('a damaged manifest reads as empty, and the next change replaces it', () async {
      manifest.writeAsStringSync('{"selectedQuestIds": [tru');

      await manager.restore(isOnline: true);
      expect(manager.entries.value, isEmpty);

      _onServer(repository, 'a');
      await manager.addQuest('a', isOnline: true);
      expect(savedIds(), ['a']);
    });

    test('a .tmp left by a write that died halfway is ignored, then replaced', () async {
      manifest.writeAsStringSync('{"selectedQuestIds": ["a"]}');
      File('${manifest.path}.tmp').writeAsStringSync('{"selectedQuestIds": ["b", "c"'); // cut off

      expect(await store().read(), ['a'], reason: 'the previous manifest, whole');

      await store().write(['a', 'd']);
      expect(savedIds(), ['a', 'd']);
      expect(File('${manifest.path}.tmp').existsSync(), isFalse);
    });

    test('valid JSON of the wrong shape reads as empty too', () async {
      for (final text in ['[]', '{"selectedQuestIds": "a"}', '{"selectedQuestIds": [1, null, ""]}']) {
        manifest.writeAsStringSync(text);
        expect(await store().read(), isEmpty, reason: text);
      }
    });

    test('signing out deletes the manifest and empties the pack', () async {
      _saved(repository, 'a');
      await manager.addQuest('a', isOnline: true);
      final local = _FakeLocal();

      await AuthRepository(_FakeRemote(), local, offlinePack: manager).signOut();

      expect(local.cleared, isTrue);
      expect(manifest.existsSync(), isFalse);
      expect(manager.entries.value, isEmpty);
      final nextAccount = OfflinePackManager(repository, store());
      await nextAccount.restore(isOnline: false);
      expect(nextAccount.entries.value, isEmpty);
    });

    test('on the web the same JSON lives in SharedPreferences', () async {
      SharedPreferences.setMockInitialValues({});
      final web = OfflinePackManifestStore(isWeb: true);

      await web.write(['a', 'b']);
      expect(await web.read(), ['a', 'b']);
      expect(
        jsonDecode((await SharedPreferences.getInstance()).getString('offline_pack_manifest')!),
        {'selectedQuestIds': ['a', 'b']},
      );

      await web.clear();
      expect(await web.read(), isEmpty);
    });
  });

  group('pre-loading (caching)', () {
    test('steps already saved: ready without asking the server', () async {
      _saved(repository, 'a');

      await manager.addQuest('a', isOnline: true);

      expect(statusOf('a'), OfflinePackStatus.ready);
      expect(repository.stepRequests, isEmpty);
    });

    test('no steps saved, online: downloads them into the cache and is ready', () async {
      _onServer(repository, 'a');

      await manager.addQuest('a', isOnline: true);

      expect(statusOf('a'), OfflinePackStatus.ready);
      expect(repository.stepRequests, ['a']);
      expect(repository.savedSteps['a'], hasLength(2));
      expect(repository.getCachedCatalog().map((q) => q.id), contains('a'));
    });

    test('offline: stays pendingDownload, saved in the manifest, nothing asked', () async {
      _onServer(repository, 'a');

      await manager.addQuest('a', isOnline: false);

      expect(statusOf('a'), OfflinePackStatus.pendingDownload);
      expect(savedIds(), ['a']);
      expect(repository.stepRequests, isEmpty);
    });

    test('a failed download is failed with a message, and keeps what was saved', () async {
      // Saved before, but incomplete (a step without description): not ready.
      repository.savedCatalog.add(_quest('a'));
      final before = _steps('a', description: '');
      repository.savedSteps['a'] = before;
      repository.offline = true; // the request fails

      await manager.addQuest('a', isOnline: true);

      final entry = manager.entries.value.single;
      expect(entry.status, OfflinePackStatus.failed);
      expect(entry.message, isNotNull);
      expect(repository.savedSteps['a'], same(before));
    });

    test('nothing saved and the request fails: failed with the download message', () async {
      repository.savedCatalog.add(_quest('a'));
      repository.offline = true;

      await manager.addQuest('a', isOnline: true);

      expect(manager.entries.value.single.message, OfflinePackManager.downloadFailedMessage);
    });

    test('never ready just for being online: steps without description are failed', () async {
      repository.remoteCatalog.add(_quest('a'));
      repository.remoteSteps['a'] = _steps('a', description: '  ');

      await manager.addQuest('a', isOnline: true);

      expect(manager.entries.value.single, const OfflinePackEntry(
        'a',
        OfflinePackStatus.failed,
        message: OfflinePackManager.incompleteMessage,
      ));
    });

    test('a quest missing from the saved catalogue is not ready, even with its steps', () async {
      repository.savedSteps['a'] = _steps('a');
      repository.offline = true; // and the catalogue can't be refreshed

      await manager.addQuest('a', isOnline: true);

      expect(statusOf('a'), OfflinePackStatus.failed);
    });

    test('back online, retry downloads the pending and the failed ones', () async {
      _onServer(repository, 'pending');
      repository.savedCatalog.add(_quest('failed'));
      repository.remoteCatalog.add(_quest('failed'));
      await manager.addQuest('pending', isOnline: false);
      repository.offline = true;
      await manager.addQuest('failed', isOnline: true);
      expect(statusOf('failed'), OfflinePackStatus.failed);

      repository.offline = false;
      repository.remoteSteps['failed'] = _steps('failed');
      await manager.retryPending(isOnline: true);

      expect(statusOf('pending'), OfflinePackStatus.ready);
      expect(statusOf('failed'), OfflinePackStatus.ready);
    });

    test('retry offline downloads nothing and keeps each status', () async {
      _onServer(repository, 'a');
      await manager.addQuest('a', isOnline: false);

      await manager.retryPending(isOnline: false);

      expect(statusOf('a'), OfflinePackStatus.pendingDownload);
      expect(repository.stepRequests, isEmpty);
    });
  });

  group('concurrency', () {
    test('never more than 3 downloads at once; the rest wait their turn', () async {
      final ids = ['q1', 'q2', 'q3', 'q4', 'q5', 'q6'];
      for (final id in ids) {
        _onServer(repository, id);
        repository.hold[id] = Completer<void>();
        await manager.addQuest(id, isOnline: false);
      }

      final retry = manager.retryPending(isOnline: true);
      await pumpEventQueue();
      expect(repository.active, 3);
      expect(
        manager.entries.value.map((e) => e.status),
        everyElement(OfflinePackStatus.downloading),
      );

      for (final id in ids) {
        repository.hold[id]!.complete();
        await pumpEventQueue();
      }
      await retry;

      expect(repository.maxActive, 3);
      expect(repository.stepRequests.toSet(), ids.toSet());
      expect(manager.entries.value.map((e) => e.status), everyElement(OfflinePackStatus.ready));
    });

    test('the same quest is never downloaded twice at once', () async {
      _onServer(repository, 'a');
      repository.hold['a'] = Completer<void>();

      final add = manager.addQuest('a', isOnline: true);
      await pumpEventQueue();
      final retry = manager.retryPending(isOnline: true);
      final restore = manager.restore(isOnline: true);
      await pumpEventQueue();
      repository.hold['a']!.complete();
      await Future.wait([add, retry, restore]);

      expect(repository.stepRequests, ['a']);
      expect(statusOf('a'), OfflinePackStatus.ready);
    });

    test('removed and added again while its download runs: joins that download', () async {
      _onServer(repository, 'a');
      repository.hold['a'] = Completer<void>();

      final first = manager.addQuest('a', isOnline: true);
      await pumpEventQueue();
      await manager.removeQuest('a');
      final second = manager.addQuest('a', isOnline: true); // pending again, same quest
      // Its manifest write is real disk I/O: wait until it's back in the pack.
      for (var i = 0; i < 200 && manager.entries.value.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      await pumpEventQueue();
      expect(statusOf('a'), OfflinePackStatus.downloading, reason: 'shown as the download it joined');
      repository.hold['a']!.complete();
      await Future.wait([first, second]);

      expect(repository.stepRequests, ['a']);
      expect(statusOf('a'), OfflinePackStatus.ready);
    });

    test('manifest operations are serialized: concurrent adds and a remove all land', () async {
      for (final id in ['a', 'b', 'c']) {
        _onServer(repository, id);
      }

      await Future.wait([
        manager.addQuest('a', isOnline: false),
        manager.addQuest('b', isOnline: false),
        manager.removeQuest('a'),
        manager.addQuest('c', isOnline: false),
      ]);

      expect(savedIds(), ['b', 'c']);
      expect(manager.entries.value.map((e) => e.questId), ['b', 'c']);
    });

    test('a quest removed while downloading does not come back', () async {
      _onServer(repository, 'a');
      repository.hold['a'] = Completer<void>();

      final add = manager.addQuest('a', isOnline: true);
      await pumpEventQueue();
      await manager.removeQuest('a');
      repository.hold['a']!.complete();
      await add;

      expect(manager.entries.value, isEmpty);
      expect(savedIds(), isEmpty);
    });
  });
}
