import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sidequests/core/app_exception.dart';
import 'package:sidequests/core/workers/evidence_workers.dart';
import 'package:sidequests/data/cache/byte_lru_cache.dart';
import 'package:sidequests/data/remote/network_guard.dart';
import 'package:sidequests/repository/evidence_repository.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show StorageException;

import '../helpers/evidence_fakes.dart';

void main() {
  late FakeEvidenceRemote remote;
  late FakeEvidenceQuestRepository quests;
  late FakeEvidenceLocal local;
  late MemoryEvidenceStore store;
  late FakeThumbnailMaker thumbnails;
  late ByteLruCache<String> thumbnailCache;
  late ByteLruCache<String> photoCache;
  late bool offline;
  late List<String> logs;
  late EvidenceRepository repository;
  late DownloadPool pool;

  final proof = proofOf('proof-1');

  setUp(() {
    remote = FakeEvidenceRemote();
    quests = FakeEvidenceQuestRepository();
    local = FakeEvidenceLocal();
    store = MemoryEvidenceStore();
    thumbnails = FakeThumbnailMaker();
    thumbnailCache = ByteLruCache(maxBytes: kEvidenceThumbnailCacheBytes);
    photoCache = ByteLruCache(maxBytes: kEvidencePhotoCacheBytes);
    offline = false;
    logs = [];
    repository = EvidenceRepository(
      quests,
      remote,
      local,
      store: store,
      network: NetworkGuard(isOffline: () async => offline),
      thumbnailCache: thumbnailCache,
      photoCache: photoCache,
      makeThumbnail: thumbnails.call,
      log: logs.add,
    );
    pool = DownloadPool(log: (_) {});
    remote.addProof(proof, fakeJpeg(1));
  });

  group('three levels: memory -> disk -> network', () {
    test('network the first time (and saved on the phone), then memory, then disk once memory is gone', () async {
      final first = await repository.thumbnail(proof, pool: pool);
      expect(first.source, EvidenceLevel.network);
      expect(first.onPhone, isTrue);
      expect(remote.downloads, hasLength(1));
      expect(thumbnails.calls, 1);
      expect(store.saved.keys, ['proof-1']);

      final second = await repository.thumbnail(proof, pool: pool);
      expect(second.source, EvidenceLevel.memory);
      expect(identical(second.bytes, first.bytes), isTrue);

      thumbnailCache.clear(); // like a restart: memory is empty, the disk isn't
      final third = await repository.thumbnail(proof, pool: pool);
      expect(third.source, EvidenceLevel.disk);
      expect(thumbnailCache.containsKey('proof-1'), isTrue, reason: 'what comes from disk goes to memory');

      expect(remote.downloads, hasLength(1));
      expect((repository.memoryHits, repository.diskHits, repository.networkHits), (1, 1, 1));
      expect(logs.last, contains('memoria 1 · disco 1 · red 1'));
    });

    test('the full photo has its own levels, and the download made for the thumbnail serves it', () async {
      await repository.thumbnail(proof, pool: pool);

      final photo = await repository.photo(proof, pool: pool);
      expect(photo.source, EvidenceLevel.memory);
      expect(photo.bytes, fakeJpeg(1));

      photoCache.clear();
      expect((await repository.photo(proof, pool: pool)).source, EvidenceLevel.disk);
      expect(remote.downloads, hasLength(1));
    });

    test('the thumbnail and the photo asked at the same time share one download', () async {
      final gate = Completer<void>();
      remote.gates[proof.storagePath] = gate;

      final thumbnail = repository.thumbnail(proof, pool: pool);
      final photo = repository.photo(proof, pool: pool);
      await Future<void>.delayed(Duration.zero);
      gate.complete();
      await Future.wait([thumbnail, photo]);

      expect(remote.downloads, hasLength(1));
    });
  });

  group('offline and failures', () {
    test('offline and not saved: unavailable at once, no request, no turn in the pool', () async {
      offline = true;

      await expectLater(repository.thumbnail(proof, pool: pool), throwsA(isA<EvidenceUnavailableException>()));

      expect(remote.downloads, isEmpty);
      expect(pool.peakActive, 0);
      expect(repository.unavailable, 1);
    });

    test('offline and saved: from the disk', () async {
      await repository.thumbnail(proof, pool: pool);
      thumbnailCache.clear();
      photoCache.clear();
      offline = true;

      expect((await repository.thumbnail(proof, pool: pool)).source, EvidenceLevel.disk);
      expect((await repository.photo(proof, pool: pool)).source, EvidenceLevel.disk);
    });

    testWidgets('a download that never answers ends at NetworkGuard\'s 5 s timeout, retryable', (tester) async {
      remote.gates[proof.storagePath] = Completer<void>(); // never completes
      Object? error;
      unawaited(repository.thumbnail(proof, pool: pool).then<void>((_) {}, onError: (Object e) => error = e));

      await tester.pump(const Duration(seconds: 4));
      expect(error, isNull);
      await tester.pump(const Duration(seconds: 2));

      expect(error, isA<AppException>().having((e) => e.isRetryable, 'isRetryable', isTrue));
      expect(pool.active, 0, reason: 'the slot is freed');
    });

    test('one photo failing doesn\'t break the others', () async {
      final ok1 = proofOf('ok-1');
      final broken = proofOf('broken');
      final ok2 = proofOf('ok-2');
      remote
        ..addProof(ok1, fakeJpeg(2))
        ..addProof(broken, fakeJpeg(3))
        ..addProof(ok2, fakeJpeg(4));
      remote.failing[broken.storagePath] = const StorageException('Internal', statusCode: '500');

      final results = await Future.wait([
        for (final p in [ok1, broken, ok2])
          repository.thumbnail(p, pool: pool).then<Object>((image) => image, onError: (Object e) => e),
      ]);

      expect(results[0], isA<EvidenceImage>());
      expect(results[1], isA<AppException>().having((e) => e.isRetryable, 'isRetryable', isTrue));
      expect(results[2], isA<EvidenceImage>());
      expect(store.saved.keys.toSet(), {'ok-1', 'ok-2'});
    });

    test('a proof gone from the bucket is not retryable', () async {
      remote.failing[proof.storagePath] = const StorageException('Object not found', statusCode: '404');

      await expectLater(
        repository.thumbnail(proof, pool: pool),
        throwsA(isA<AppException>().having((e) => e.isRetryable, 'isRetryable', isFalse)),
      );
    });

    test('a photo the thumbnailer can\'t decode is still shown and saved, with itself as thumbnail', () async {
      final repository = EvidenceRepository(
        quests,
        remote,
        local,
        store: store,
        network: NetworkGuard(isOffline: () async => false),
        makeThumbnail: (_) async => throw const FormatException('bad'),
        log: (_) {},
      );

      final image = await repository.thumbnail(proof, pool: pool);

      expect(image.bytes, fakeJpeg(1));
      expect(image.onPhone, isTrue);
    });
  });

  group('save ("Guardar todas")', () {
    test('already saved: no download', () async {
      await repository.save(proof, pool: pool);
      final again = await repository.save(proof, pool: pool);

      expect(again.onPhone, isTrue);
      expect(remote.downloads, hasLength(1));
    });

    test('seen while it couldn\'t be saved: saved later from memory, without downloading again', () async {
      store.refuseSaves = true; // over the budget
      final seen = await repository.thumbnail(proof, pool: pool);
      expect(seen.onPhone, isFalse);

      store.refuseSaves = false;
      final saved = await repository.save(proof, pool: pool);

      expect(saved.onPhone, isTrue);
      expect(saved.source, EvidenceLevel.memory);
      expect(remote.downloads, hasLength(1));
    });
  });

  group('the list and the pending photos come from QuestRepository', () {
    test('getPhotoProofs / getSteps are QuestRepository\'s; pending photos are filtered to the attempt', () async {
      quests.serverProofs['attempt-1'] = [proof];
      quests.pending = [pendingOf('mine'), pendingOf('other', attemptId: 'attempt-2')];

      expect(await repository.getPhotoProofs('attempt-1'), [proof]);
      expect(quests.listReads, 1);
      expect(repository.getPendingPhotoProofs('attempt-1').map((p) => p.localPath), ['/pending/mine.jpg']);
    });

    test('a pending photo is read from its file and its thumbnail kept in memory', () async {
      final pending = pendingOf('p1');
      local.pendingFiles[pending.localPath] = fakeJpeg(9);

      final first = await repository.pendingThumbnail(pending);
      final second = await repository.pendingThumbnail(pending);

      expect(first.source, EvidenceLevel.disk);
      expect(second.source, EvidenceLevel.memory);
      expect(thumbnails.calls, 1);
      expect((await repository.pendingPhoto(pending)).bytes, fakeJpeg(9));
      expect(remote.downloads, isEmpty);
    });

    test('a pending photo whose file is gone fails on its own, with a clear message', () async {
      await expectLater(
        repository.pendingThumbnail(pendingOf('gone')),
        throwsA(isA<AppException>().having((e) => e.message, 'message', contains('ya no está en el teléfono'))),
      );
    });
  });
}
