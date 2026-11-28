import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sidequests/core/workers/evidence_workers.dart';
import 'package:sidequests/data/remote/network_guard.dart';
import 'package:sidequests/models/photo_proof.dart';
import 'package:sidequests/repository/evidence_repository.dart';
import 'package:sidequests/viewmodel/profile/attempt_evidence_view_model.dart';

import '../helpers/evidence_fakes.dart';

/// Measurement for the wiki (Multithreading strategy, Alejandro, Sprint 4):
/// 1. a thumbnail of a photo as the app captures it (1600 x 1200, JPEG): time
///    on a new isolate (Isolate.run) vs. what the same work blocks the UI
///    thread for when done inline;
/// 2. "Guardar todas" of [_photos] photos with concurrency 3 vs. 1: simulated
///    network ([_latency] per download, as on mobile data), real thumbnails on
///    real isolates, the disk faked in memory.
/// Prints a table; it only asserts what doesn't depend on the machine.
///
/// These are debug (JIT) numbers on the computer running the tests. On a
/// phone: `flutter run --profile`, open an attempt's evidence and read the
/// "[Evidencias] miniatura en Isolate.run", "pool de descargas" and "Guardar
/// todas" lines; build again with `--dart-define=EVIDENCE_DOWNLOAD_CONCURRENCY=1`
/// for the baseline.
///
/// Off in a normal `flutter test` (it keeps the CPU busy for seconds). Run it
/// with `flutter test --dart-define=MEASURE_EVIDENCE=true test/core/evidence_measurement_test.dart`.
const _measure = bool.fromEnvironment('MEASURE_EVIDENCE');

const _thumbnailRuns = 10;
const _photos = 9;
const _latency = Duration(milliseconds: 400);

void main() {
  test(
    'thumbnail on Isolate.run vs. inline, and "Guardar todas" with concurrency 3 vs. 1',
    () async {
      final photo = testJpeg(1600, 1200);

      // Warm-up (JIT, first isolate spawn).
      makeEvidenceThumbnail(photo);
      await makeEvidenceThumbnailInBackground(photo);

      final inline = <int>[];
      final onIsolate = <int>[];
      final blocked = <int>[];
      for (var i = 0; i < _thumbnailRuns; i++) {
        final stopwatch = Stopwatch()..start();
        makeEvidenceThumbnail(photo);
        inline.add(stopwatch.elapsedMilliseconds);

        stopwatch
          ..reset()
          ..start();
        // What the UI isolate itself is busy for: only starting the isolate;
        // the decoding happens elsewhere while this one is free.
        final pending = makeEvidenceThumbnailInBackground(photo);
        blocked.add(stopwatch.elapsedMilliseconds);
        await pending;
        onIsolate.add(stopwatch.elapsedMilliseconds);
      }
      expect(blocked.reduce((a, b) => a + b), lessThan(inline.reduce((a, b) => a + b)));

      Future<int> saveAll(int concurrency) async {
        final remote = FakeEvidenceRemote()..latency = _latency;
        final quests = FakeEvidenceQuestRepository()..steps = const [];
        final proofs = <QuestPhotoProof>[for (var i = 0; i < _photos; i++) proofOf('p$i')];
        for (final (i, proof) in proofs.indexed) {
          remote.addProof(proof, testJpeg(1600, 1200, seed: i));
        }
        quests.serverProofs['attempt-1'] = proofs;
        final repository = EvidenceRepository(
          quests,
          remote,
          FakeEvidenceLocal(),
          store: MemoryEvidenceStore(),
          network: NetworkGuard(isOffline: () async => false),
          log: (_) {},
        );
        final viewModel = AttemptEvidenceViewModel(
          repository,
          attempt: EvidenceAttempt(attemptId: 'attempt-1', questId: 'q', questTitle: 'q', date: DateTime(2026)),
          downloadConcurrency: concurrency,
          log: (_) {},
        );
        await viewModel.load();
        final stopwatch = Stopwatch()..start();
        await viewModel.saveAll();
        final elapsed = stopwatch.elapsedMilliseconds;
        expect(viewModel.savedCount, _photos);
        expect(remote.peak, concurrency);
        viewModel.dispose();
        return elapsed;
      }

      final one = await saveAll(1);
      final three = await saveAll(3);

      String stats(List<int> values) {
        final sorted = [...values]..sort();
        final mean = values.reduce((a, b) => a + b) / values.length;
        return 'media ${mean.toStringAsFixed(0)} ms, mediana ${sorted[sorted.length ~/ 2]} ms';
      }

      debugPrint('''
=== Evidencias de un intento: medición (debug/JIT, este computador) ===
Miniatura 1600x1200 -> 320 px (${(photo.length / 1024).toStringAsFixed(0)} KB), $_thumbnailRuns corridas:
  inline (bloquea el hilo de la UI todo ese tiempo): ${stats(inline)}
  Isolate.run, total hasta tener la miniatura: ${stats(onIsolate)}
  Isolate.run, hilo de la UI ocupado al lanzarlo: ${stats(blocked)}
"Guardar todas" $_photos fotos, red simulada ${_latency.inMilliseconds} ms/foto:
  concurrencia 1: $one ms
  concurrencia 3: $three ms  (${(one / three).toStringAsFixed(1)}x)
''');
      expect(three, lessThan(one));
    },
    skip: _measure ? false : 'measurement for the wiki: --dart-define=MEASURE_EVIDENCE=true',
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
