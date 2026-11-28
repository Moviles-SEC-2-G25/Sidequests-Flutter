import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sidequests/core/similar_quest_recommender.dart';
import 'package:sidequests/core/workers/similar_quest_worker.dart';
import 'package:sidequests/models/quest.dart';
import 'package:sidequests/models/user_quest.dart';

/// Measurement for the wiki (Multithreading strategy, Alejandro): UI-thread
/// time per "You might also like" re-ranking before (synchronous, on the UI
/// thread) and after (worker isolate), and the one-time costs of the worker
/// (spawning it, copying the catalog). Prints a table; it only asserts that
/// both give the same answer, since times depend on the machine.
///
/// These are debug (JIT) numbers on the computer running the tests. On a
/// phone: `flutter run --profile`, complete a mission, tap stars, and read the
/// "SimilarQuestWorker:" lines; for the "before" on the phone, run with
/// `--dart-define=SIMILAR_QUESTS_ON_UI_THREAD=true`.
///
/// Off in a normal `flutter test`: it keeps the CPU busy for several seconds,
/// which starves tests that wait on the real clock. Run it with
/// `flutter test --dart-define=MEASURE_SIMILAR_QUESTS=true test/core/similar_quest_worker_measurement_test.dart`.
const _measure = bool.fromEnvironment('MEASURE_SIMILAR_QUESTS');

const _requests = 60;
const _warmUp = 20;

List<Quest> _catalog(int size) => [
  for (var i = 0; i < size; i++)
    Quest(
      id: 'q$i',
      title: 'Quest $i',
      description: 'Una descripción de la misión número $i, como las del catálogo.',
      category: const ['food', 'art', 'sport', 'learning', 'nature'][i % 5],
      durationMinutes: 5 + (i * 7) % 90,
      estimatedCost: (i % 4) * 5.0,
      difficulty: const ['easy', 'medium', 'hard'][(i ~/ 2) % 3],
      locationMode: i.isEven ? 'anywhere' : 'gps',
      socialLevel: 'solo',
      tags: [
        for (var t = 0; t < 6; t++)
          if ((i >> t) & 1 == 1) const ['outdoor', 'indoor', 'cheap', 'calm', 'group', 'night'][t],
      ],
    ),
];

List<UserQuest> _attempts(int count) => [
  for (var i = 0; i < count; i++)
    UserQuest(
      id: 'uq$i',
      userId: 'u',
      questId: 'q${i * 3}',
      status: const ['completed', 'abandoned', 'in_progress', 'skipped'][i % 4],
      acceptedAt: DateTime(2026),
    ),
];

int _median(List<int> values) => (values.toList()..sort())[values.length ~/ 2];
int _p95(List<int> values) => (values.toList()..sort())[(values.length * 0.95).floor()];
String _ms(int micros) => (micros / 1000).toStringAsFixed(3);

void main() {
  test(
    'UI-thread time per re-ranking: synchronous vs worker',
    () async {
      final rows = <String>[];
      int? firstSpawn;

      for (final size in const [50, 500, 2000]) {
        final catalog = _catalog(size);
        final attempts = _attempts(size ~/ 5);
        final completed = catalog[13];
        int ratingOf(int i) => i % 6; // 0..5, like taps on the stars

        // Before: the whole ranking on the UI thread, as QuestCompletedView did.
        List<Quest> synchronous(int i) => const SimilarQuestRecommender().recommend(
          completed,
          catalog,
          attempts,
          ratingOf(i),
          60,
        );
        final expected = [for (var rating = 0; rating < 6; rating++) synchronous(rating)];
        for (var i = 0; i < _warmUp; i++) {
          synchronous(i);
        }
        final before = <int>[];
        for (var i = 0; i < _requests; i++) {
          final stopwatch = Stopwatch()..start();
          synchronous(i);
          before.add(stopwatch.elapsedMicroseconds);
        }

        // After: a new worker (so its spawn is measured), then the same taps.
        final worker = SimilarQuestWorker(useIsolate: true, log: (_) {});
        final after = <int>[];
        final inWorker = <int>[];
        final roundTrips = <int>[];
        var requestId = 0;
        Future<SimilarQuestAnswer> ask(int i, {List<int>? uiTimes}) async {
          final roundTrip = Stopwatch()..start();
          // The UI thread still works out the unavailable ids (QuestViewModel).
          final stopwatch = Stopwatch()..start();
          final query = SimilarQuestQuery(
            completed: completed,
            rating: ratingOf(i),
            maxMinutes: 60,
            unavailableQuestIds: SimilarQuestRecommender.unavailableQuestIds(attempts),
          );
          final idsTime = stopwatch.elapsedMicroseconds;
          final answer = await worker.recommend(
            requestId: ++requestId,
            catalog: catalog,
            query: query,
          );
          uiTimes?.add(idsTime + answer.uiThreadTime.inMicroseconds);
          if (uiTimes != null) {
            inWorker.add(answer.workerTime!.inMicroseconds);
            roundTrips.add(roundTrip.elapsedMicroseconds);
          }
          return answer;
        }

        final first = await ask(0);
        // The first isolate of the process is the real one-time cost; later
        // ones reuse code the isolate group already loaded.
        firstSpawn ??= worker.lastSpawnTime!.inMicroseconds;
        final catalogCopy = worker.lastCatalogSyncTime!.inMicroseconds;
        expect(first.quests, orderedEquals(expected[ratingOf(0)]));
        for (var i = 0; i < _warmUp; i++) {
          await ask(i);
        }
        for (var i = 0; i < _requests; i++) {
          final answer = await ask(i, uiTimes: after);
          expect(answer.rankedOn, SimilarQuestThread.worker);
          expect(answer.quests, orderedEquals(expected[ratingOf(i)]));
        }
        expect(worker.catalogMessagesSent, 1);
        expect(worker.spawnCount, 1);
        worker.close();

        rows.add(
          '| $size misiones | ${_ms(_median(before))} (p95 ${_ms(_p95(before))}) '
          '| ${_ms(_median(after))} (p95 ${_ms(_p95(after))}) '
          '| ${_ms(_median(inWorker))} | ${_ms(_median(roundTrips))} | ${_ms(catalogCopy)} |',
        );
      }

      debugPrint(
        [
          '',
          'Te podría gustar — ms en el hilo de UI por recálculo (mediana de $_requests toques, modo debug/JIT)',
          '| Catálogo | Antes: síncrono | Después: worker | Ranking dentro del worker '
              '| Ida y vuelta | Copiar el catálogo (1 vez por cambio) |',
          '|---|---|---|---|---|---|',
          ...rows,
          'Crear el isolate (1 vez por ejecución de la app): ${_ms(firstSpawn!)} ms',
        ].join('\n'),
      );
    },
    timeout: const Timeout(Duration(minutes: 3)),
    skip: _measure ? false : 'measurement for the wiki: --dart-define=MEASURE_SIMILAR_QUESTS=true',
  );
}
