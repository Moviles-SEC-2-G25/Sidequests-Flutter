import 'package:flutter_test/flutter_test.dart';
import 'package:sidequests/data/remote/network_guard.dart';
import 'package:sidequests/models/photo_proof.dart';
import 'package:sidequests/models/quest_step.dart';
import 'package:sidequests/repository/evidence_repository.dart';
import 'package:sidequests/viewmodel/profile/attempt_evidence_view_model.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show StorageException;

import '../helpers/evidence_fakes.dart';

const _reconnectDelay = Duration(milliseconds: 20);

final _attempt = EvidenceAttempt(
  attemptId: 'attempt-1',
  questId: 'quest-1',
  questTitle: 'Ramen escondido',
  date: DateTime(2026, 11, 20),
);

QuestStep _step(int stepOrder, String title) =>
    QuestStep(id: stepOrder, questId: 'quest-1', stepOrder: stepOrder, title: title, verificationType: 'photo');

void main() {
  late FakeEvidenceRemote remote;
  late FakeEvidenceQuestRepository quests;
  late FakeEvidenceLocal local;
  late MemoryEvidenceStore store;
  late FakeConnectivity connectivity;
  late EvidenceRepository repository;
  final logs = <String>[];

  AttemptEvidenceViewModel build({int downloadConcurrency = 3}) => AttemptEvidenceViewModel(
    repository,
    attempt: _attempt,
    connectivity: connectivity,
    downloadConcurrency: downloadConcurrency,
    reconnectDelay: _reconnectDelay,
    log: logs.add,
  );

  /// Uploaded proofs of attempt-1 on the server, with their bytes.
  List<QuestPhotoProof> seed(int count, {int stepOrder = 0}) {
    final proofs = [
      for (var i = 0; i < count; i++)
        proofOf('s$stepOrder-p$i', stepOrder: stepOrder, uploadedAt: DateTime(2026, 11, 20, 10, i)),
    ];
    for (final (i, proof) in proofs.indexed) {
      remote.addProof(proof, fakeJpeg(i));
    }
    quests.serverProofs['attempt-1'] = [...?quests.serverProofs['attempt-1'], ...proofs];
    return proofs;
  }

  /// The proofs were listed online once (QuestRepository keeps the copy in
  /// Hive), and now the device is offline.
  Future<void> goOfflineAfterListing() async {
    await repository.getPhotoProofs('attempt-1');
    quests.listOffline = true;
    connectivity.isOffline = true;
  }

  setUp(() {
    remote = FakeEvidenceRemote();
    quests = FakeEvidenceQuestRepository()
      ..steps = [_step(1, 'Encuentra el local'), _step(2, 'Pide el ramen'), _step(3, 'Foto del plato')];
    local = FakeEvidenceLocal();
    store = MemoryEvidenceStore();
    connectivity = FakeConnectivity();
    logs.clear();
    repository = EvidenceRepository(
      quests,
      remote,
      local,
      store: store,
      // The guard follows the same connectivity the screen does.
      network: NetworkGuard(isOffline: () async => connectivity.isOffline),
      makeThumbnail: FakeThumbnailMaker().call,
      log: logs.add,
    );
  });

  group('the list', () {
    test('grouped by step, "Paso N: título" by position (step_order starting at 1), pending first', () async {
      seed(2, stepOrder: 1);
      seed(1, stepOrder: 3);
      quests.pending = [pendingOf('new', stepOrder: 1)];
      local.pendingFiles['/pending/new.jpg'] = fakeJpeg(7);
      final viewModel = build();

      await viewModel.load();

      expect(viewModel.status, EvidenceStatus.data);
      expect(viewModel.groups.map((g) => g.label), ['Paso 1: Encuentra el local', 'Paso 3: Foto del plato']);
      expect(viewModel.groups.first.items.map((i) => i.id), ['pending:user-1/attempt-1/quest-1/step-2-new.jpg', 's1-p1', 's1-p0']);
      expect(viewModel.items, hasLength(4));
      expect(viewModel.stepLabelOf(viewModel.items.last), 'Paso 3: Foto del plato');
      viewModel.dispose();
    });

    test('steps never loaded on this phone: "Paso N" without a title', () async {
      seed(1, stepOrder: 0);
      quests.steps = null;
      final viewModel = build();

      await viewModel.load();

      expect(viewModel.groups.single.label, 'Paso 1');
      viewModel.dispose();
    });

    test('an attempt without photos is "empty"', () async {
      final viewModel = build();
      await viewModel.load();
      expect(viewModel.status, EvidenceStatus.empty);
      viewModel.dispose();
    });

    test('online, the server fails and nothing was ever saved: a recoverable error, not the raw message', () async {
      quests.listOffline = true; // no answer, no Hive copy
      final viewModel = build();

      await viewModel.load();

      expect(viewModel.status, EvidenceStatus.error);
      expect(viewModel.errorMessage, contains('No pudimos conectar con el servidor'));
      expect(viewModel.errorMessage, isNot(contains('tu foto quedó guardada')));

      quests.listOffline = false;
      seed(1);
      await viewModel.load();
      expect(viewModel.status, EvidenceStatus.data);
      viewModel.dispose();
    });

    test('the attempt is marked open while the screen lives (never evicted), and closed after', () async {
      final viewModel = build();
      expect(store.openAttempts, {'attempt-1'});
      viewModel.dispose();
      expect(store.openAttempts, isEmpty);
    });
  });

  group('online: download when shown', () {
    test('a tile asking for its thumbnail downloads it once and saves it on the phone', () async {
      final [proof] = seed(1);
      final viewModel = build();
      await viewModel.load();
      expect(viewModel.availabilityOf(proof.id), EvidenceAvailability.inCloud);

      viewModel
        ..ensureThumbnail(proof.id)
        ..ensureThumbnail(proof.id); // a rebuild asks again
      expect(viewModel.isThumbnailLoading(proof.id), isTrue);
      await pumpEventQueue();

      expect(viewModel.thumbnailOf(proof.id), isNotNull);
      expect(viewModel.availabilityOf(proof.id), EvidenceAvailability.onPhone);
      expect(viewModel.savedCount, 1);
      expect(viewModel.allSaved, isTrue);
      expect(remote.downloads, hasLength(1));
      viewModel.dispose();
    });

    test('the viewer keeps only a few full photos in the ViewModel', () async {
      final proofs = seed(5);
      final viewModel = build();
      await viewModel.load();

      for (final proof in proofs) {
        viewModel.ensurePhoto(proof.id);
        await pumpEventQueue();
      }

      expect(proofs.where((p) => viewModel.photoOf(p.id) != null), hasLength(3));
      expect(viewModel.photoOf(proofs.last.id), isNotNull);
      viewModel.dispose();
    });
  });

  group('multithreading: at most 3 downloads at once', () {
    test('"Guardar todas" never has more than 3 downloads out, and reports n of m', () async {
      seed(8);
      remote.holdAll = true;
      final viewModel = build();
      await viewModel.load();

      final saving = viewModel.saveAll();
      await pumpEventQueue();
      expect(viewModel.isSaving, isTrue);
      expect(viewModel.saveTotal, 8);
      expect(remote.active, 3);

      while (viewModel.isSaving) {
        remote.releaseAll();
        await pumpEventQueue();
        expect(remote.active, lessThanOrEqualTo(3));
      }
      await saving;

      expect(remote.peak, 3);
      expect(viewModel.saveDone, 8);
      expect(viewModel.savedCount, 8);
      expect(viewModel.canSaveAll, isFalse);
      expect(logs.where((line) => line.contains('Guardar todas: 8 fotos')), hasLength(1));
      viewModel.dispose();
    });

    test('the grid and "Guardar todas" share the same 3 slots', () async {
      final proofs = seed(8);
      remote.holdAll = true;
      final viewModel = build();
      await viewModel.load();

      for (final proof in proofs.take(4)) {
        viewModel.ensureThumbnail(proof.id);
      }
      final saving = viewModel.saveAll();
      await pumpEventQueue();
      expect(remote.active, 3);

      while (viewModel.isSaving) {
        remote.releaseAll();
        await pumpEventQueue();
      }
      await saving;
      expect(remote.peak, 3);
      expect(remote.downloads.toSet(), hasLength(8), reason: 'each photo downloaded once');
      viewModel.dispose();
    });

    test('with concurrency 1 (the measurement\'s baseline) they go one by one', () async {
      seed(4);
      final viewModel = build(downloadConcurrency: 1);
      await viewModel.load();

      await viewModel.saveAll();

      expect(remote.peak, 1);
      expect(logs.where((line) => line.contains('concurrencia 1')), hasLength(1));
      viewModel.dispose();
    });

    test('leaving the screen cancels what was still waiting for its turn', () async {
      seed(8);
      remote.holdAll = true;
      final viewModel = build();
      await viewModel.load();
      final saving = viewModel.saveAll();
      await pumpEventQueue();
      expect(remote.downloads, hasLength(3));

      viewModel.dispose();
      remote.releaseAll();
      await saving;
      await pumpEventQueue();

      expect(remote.downloads, hasLength(3), reason: 'the other 5 never started');
      expect(viewModel.downloadPool.isClosed, isTrue);
    });

    test('one photo failing doesn\'t stop the others; it can be retried', () async {
      final proofs = seed(4);
      remote.failing[proofs[1].storagePath] = const StorageException('Internal', statusCode: '500');
      final viewModel = build();
      await viewModel.load();

      await viewModel.saveAll();

      expect(viewModel.savedCount, 3);
      expect(viewModel.saveFailed, 1);
      expect(viewModel.availabilityOf(proofs[1].id), EvidenceAvailability.failed);
      expect(viewModel.errorOf(proofs[1].id), contains('Toca para reintentar'));

      remote.failing.clear();
      viewModel.retry(proofs[1].id);
      await pumpEventQueue();
      expect(viewModel.availabilityOf(proofs[1].id), EvidenceAvailability.onPhone);
      viewModel.dispose();
    });
  });

  group('eventual connectivity', () {
    test('offline with saved photos: the list from the saved copy, the images from the phone', () async {
      final proofs = seed(2);
      final online = build();
      await online.load();
      await online.saveAll();
      online.dispose();
      final downloadsOnline = remote.downloads.length;
      await goOfflineAfterListing();

      final viewModel = build();
      await viewModel.load();
      for (final proof in proofs) {
        viewModel.ensureThumbnail(proof.id);
      }
      await pumpEventQueue();

      expect(viewModel.isOffline, isTrue);
      expect(viewModel.status, EvidenceStatus.data);
      expect(proofs.map((p) => viewModel.availabilityOf(p.id)), everyElement(EvidenceAvailability.onPhone));
      expect(proofs.map((p) => viewModel.thumbnailOf(p.id)), everyElement(isNotNull));
      expect(viewModel.canSaveAll, isFalse);
      expect(remote.downloads, hasLength(downloadsOnline));
      viewModel.dispose();
    });

    test('offline and not saved: "Disponible al reconectar" at once, no request and no spinner', () async {
      final [proof] = seed(1);
      await goOfflineAfterListing();
      final viewModel = build();
      await viewModel.load();

      viewModel.ensureThumbnail(proof.id);

      expect(viewModel.availabilityOf(proof.id), EvidenceAvailability.availableOnReconnect);
      expect(viewModel.isThumbnailLoading(proof.id), isFalse);
      expect(viewModel.canSaveAll, isFalse);
      await pumpEventQueue();
      expect(remote.downloads, isEmpty);
      viewModel.dispose();
    });

    test('pending uploads of this attempt are shown from their file, "Pendiente de subir"', () async {
      seed(1);
      await goOfflineAfterListing();
      final pending = pendingOf('taken-offline', stepOrder: 0);
      quests.pending = [pending, pendingOf('elsewhere', attemptId: 'attempt-2')];
      local.pendingFiles[pending.localPath] = fakeJpeg(5);
      final viewModel = build();
      await viewModel.load();
      final item = viewModel.items.firstWhere((i) => i.isPending);

      viewModel.ensureThumbnail(item.id);
      await pumpEventQueue();

      expect(viewModel.pendingCount, 1);
      expect(viewModel.availabilityOf(item.id), EvidenceAvailability.pendingUpload);
      expect(viewModel.thumbnailOf(item.id), isNotNull);
      expect(remote.downloads, isEmpty);
      viewModel.dispose();
    });

    test('pending photos show even when the uploaded list was never loaded on this phone', () async {
      quests.listOffline = true;
      connectivity.isOffline = true;
      final pending = pendingOf('only-local');
      quests.pending = [pending];
      local.pendingFiles[pending.localPath] = fakeJpeg(5);
      final viewModel = build();

      await viewModel.load();

      expect(viewModel.status, EvidenceStatus.data);
      expect(viewModel.uploadedListMissing, isTrue);
      expect(viewModel.items.single.isPending, isTrue);
      viewModel.dispose();
    });

    test('never loaded and offline: a clear message, never the raw error', () async {
      quests.listOffline = true;
      connectivity.isOffline = true;
      final viewModel = build();

      await viewModel.load();

      expect(viewModel.status, EvidenceStatus.error);
      expect(viewModel.errorMessage, startsWith('Sin conexión: las fotos de este intento todavía no se habían cargado'));
      expect(viewModel.errorMessage, isNot(contains('tu foto quedó guardada')));
      viewModel.dispose();
    });

    test('reconnecting: the open screen reloads the list and downloads what is missing, 3 at a time', () async {
      final proofs = seed(5);
      await goOfflineAfterListing();
      final viewModel = build();
      await viewModel.load();
      expect(proofs.map((p) => viewModel.availabilityOf(p.id)), everyElement(EvidenceAvailability.availableOnReconnect));
      final readsOffline = quests.listReads;
      // Uploaded from Kotlin meanwhile: only the fresh list has it.
      final newer = seed(1, stepOrder: 2).single;

      quests.listOffline = false;
      remote.holdAll = true;
      connectivity.set(offline: false);
      expect(viewModel.isOffline, isFalse);
      expect(viewModel.isSyncing, isTrue);
      await Future<void>.delayed(_reconnectDelay * 2);
      await pumpEventQueue();

      expect(quests.listReads, readsOffline + 1);
      expect(viewModel.items.map((i) => i.id), contains(newer.id));
      expect(viewModel.isSaving, isTrue);
      expect(remote.active, 3);
      while (viewModel.isSaving) {
        remote.releaseAll();
        await pumpEventQueue();
      }

      expect(remote.peak, 3);
      expect(viewModel.savedCount, 6);
      expect(viewModel.items.map((i) => viewModel.availabilityOf(i.id)), everyElement(EvidenceAvailability.onPhone));
      expect(logs.where((line) => line.contains('Reconexión: 6 fotos')), hasLength(1));
      viewModel.dispose();
    });

    test('never loaded, then the connection comes back: it loads by itself', () async {
      seed(2);
      quests.listOffline = true;
      connectivity.isOffline = true;
      final viewModel = build();
      await viewModel.load();
      expect(viewModel.status, EvidenceStatus.error);

      quests.listOffline = false;
      connectivity.set(offline: false);
      await Future<void>.delayed(_reconnectDelay * 2);
      await pumpEventQueue();
      while (viewModel.isSaving) {
        await pumpEventQueue();
      }

      expect(viewModel.status, EvidenceStatus.data);
      expect(viewModel.savedCount, 2);
      viewModel.dispose();
    });

    test('a connection that drops again before holding doesn\'t reload', () async {
      seed(1);
      await goOfflineAfterListing();
      final viewModel = build();
      await viewModel.load();
      final reads = quests.listReads;

      connectivity.set(offline: false);
      connectivity.set(offline: true);
      await Future<void>.delayed(_reconnectDelay * 3);

      expect(quests.listReads, reads);
      expect(remote.downloads, isEmpty);
      viewModel.dispose();
    });

    test('going offline: what hadn\'t started becomes "Disponible al reconectar"', () async {
      final proofs = seed(2);
      final viewModel = build();
      await viewModel.load();

      connectivity.set(offline: true);

      expect(proofs.map((p) => viewModel.availabilityOf(p.id)), everyElement(EvidenceAvailability.availableOnReconnect));
      expect(viewModel.canSaveAll, isFalse);
      viewModel.dispose();
    });
  });
}
