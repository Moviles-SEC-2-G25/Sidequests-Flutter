import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:sidequests/core/similar_quest_recommender.dart';
import 'package:sidequests/core/workers/similar_quest_worker.dart';
import 'package:sidequests/data/local/local_data_source.dart';
import 'package:sidequests/data/remote/supabase_remote_data_source.dart';
import 'package:sidequests/models/quest.dart';
import 'package:sidequests/models/user_quest.dart';
import 'package:sidequests/repository/auth_repository.dart';

/// Multithreading strategy (Alejandro): "You might also like" ranked by a
/// long-lived worker isolate. These run a real isolate (plain test(), not
/// testWidgets) to prove the answer is the very same as the synchronous
/// ranking, and that the worker's lifecycle and fallbacks behave.

const _categories = ['food', 'art', 'sport', 'learning', 'nature'];
const _difficulties = ['easy', 'medium', 'hard'];
const _tagPool = ['outdoor', 'indoor', 'cheap', 'calm', 'group', 'night'];

/// Varied enough that category, tags, duration and difficulty all matter.
List<Quest> _catalog(int size, {int durationShift = 0}) => [
  for (var i = 0; i < size; i++)
    Quest(
      id: 'q$i',
      title: 'Quest $i',
      description: 'Descripción $i',
      category: _categories[i % _categories.length],
      emoji: i.isEven ? '🎯' : null,
      durationMinutes: 5 + (i * 7 + durationShift) % 90,
      estimatedCost: (i % 4) * 5.0,
      difficulty: _difficulties[(i ~/ 2) % _difficulties.length],
      locationMode: i.isEven ? 'anywhere' : 'gps',
      socialLevel: 'solo',
      latitude: i.isEven ? null : 4.6 + i / 1000,
      longitude: i.isEven ? null : -74.07,
      tags: [
        for (var t = 0; t < _tagPool.length; t++)
          if ((i >> t) & 1 == 1) _tagPool[t],
      ],
      isSponsored: i % 11 == 0,
      sponsorName: i % 11 == 0 ? 'Sponsor $i' : null,
    ),
];

UserQuest _attempt(String questId, String status) => UserQuest(
  id: 'uq-$questId',
  userId: 'user-1',
  questId: questId,
  status: status,
  acceptedAt: DateTime(2026, 1, 1),
);

final _attempts = [
  _attempt('q1', 'completed'),
  _attempt('q2', 'in_progress'),
  _attempt('q3', 'accepted'),
  _attempt('q4', 'abandoned'), // can be suggested again
  _attempt('q6', 'skipped'),
];

/// The ranking as it ran on the UI thread before the worker.
List<Quest> _synchronous(List<Quest> catalog, Quest completed, int rating, int maxMinutes) =>
    const SimilarQuestRecommender().recommend(completed, catalog, _attempts, rating, maxMinutes);

Future<SimilarQuestAnswer> _ask(
  SimilarQuestRunner runner,
  int requestId,
  List<Quest> catalog,
  Quest completed, {
  required int rating,
  int maxMinutes = 60,
}) => runner.recommend(
  requestId: requestId,
  catalog: catalog,
  query: SimilarQuestQuery(
    completed: completed,
    rating: rating,
    maxMinutes: maxMinutes,
    unavailableQuestIds: SimilarQuestRecommender.unavailableQuestIds(_attempts),
  ),
);

/// Answers the handshake, then crashes on the first request.
void _crashingWorker(SendPort replies) {
  final requests = ReceivePort();
  replies.send(requests.sendPort);
  requests.listen((message) {
    if ((message as Map)['type'] == 'recommend') throw StateError('boom');
  });
}

/// Answers the handshake, then never answers anything.
void _silentWorker(SendPort replies) {
  final requests = ReceivePort();
  replies.send(requests.sendPort);
  requests.listen((_) {});
}

/// Completes when [isolate] exits. Must be listening before it's killed.
Future<void> _exitOf(Isolate isolate) {
  final exit = ReceivePort();
  isolate.addOnExitListener(exit.sendPort);
  return exit.first.timeout(const Duration(seconds: 5)).whenComplete(exit.close);
}

/// The worker hears about an exit through its own port: waits until it did.
Future<void> _untilStopped(SimilarQuestWorker worker) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (worker.isRunning) {
    if (DateTime.now().isAfter(deadline)) fail('the worker never noticed its isolate exited');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

class _SignedOutRemote implements SupabaseRemoteDataSource {
  @override
  Future<void> signOut() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ClearableLocal implements LocalDataSource {
  @override
  Future<void> clear() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late SimilarQuestWorker worker;

  SimilarQuestWorker newWorker({
    void Function(SendPort replies) entryPoint = similarQuestWorkerMain,
    Duration timeout = kSimilarQuestWorkerTimeout,
  }) => worker = SimilarQuestWorker(
    useIsolate: true,
    timeout: timeout,
    log: (_) {},
    entryPoint: entryPoint,
  );

  setUp(newWorker);
  tearDown(() => worker.close());

  group('same answer as the synchronous ranking', () {
    final catalog = _catalog(300);
    final completed = catalog.first;

    Future<void> expectSameAsSynchronous(int rating) async {
      var requestId = 0;
      // Without tags, with three tags, and another category.
      for (final source in [catalog[0], catalog[13], catalog[42]]) {
        for (final maxMinutes in const [10, 30, 60, 95]) {
          final answer = await _ask(
            worker,
            ++requestId,
            catalog,
            source,
            rating: rating,
            maxMinutes: maxMinutes,
          );

          expect(answer.rankedOn, SimilarQuestThread.worker);
          expect(answer.requestId, requestId);
          // orderedEquals compares with ==, which for Quest is identity: the
          // very objects of the UI thread's catalog, in the same order.
          expect(
            answer.quests,
            orderedEquals(_synchronous(catalog, source, rating, maxMinutes)),
            reason: '${source.id}, $rating★, $maxMinutes min',
          );
        }
      }
    }

    test('rating alto (5 y 4)', () async {
      await expectSameAsSynchronous(5);
      await expectSameAsSynchronous(4);
    });

    test('rating bajo (2 y 1)', () async {
      await expectSameAsSynchronous(2);
      await expectSameAsSynchronous(1);
    });

    test('sin estrellas (0)', () async {
      await expectSameAsSynchronous(0);
    });

    test('the rating really changes the answer (the cases above are not trivial)', () async {
      final liked = await _ask(worker, 1, catalog, completed, rating: 5);
      final disliked = await _ask(worker, 2, catalog, completed, rating: 1);

      expect(liked.quests.map((q) => q.id), isNot(disliked.quests.map((q) => q.id)));
      expect(liked.quests.first.category, completed.category);
      expect(disliked.quests.map((q) => q.category), isNot(contains(completed.category)));
    });

    test('catálogo vacío: an empty answer, from the worker', () async {
      final answer = await _ask(worker, 1, const [], completed, rating: 5);

      expect(answer.rankedOn, SimilarQuestThread.worker);
      expect(answer.quests, isEmpty);
    });

    test('a completed quest that is not in the catalog travels with the request', () async {
      final outside = Quest(
        id: 'outside',
        title: 'Fuera del catálogo',
        category: 'art',
        durationMinutes: 40,
        difficulty: 'medium',
        locationMode: 'anywhere',
        socialLevel: 'solo',
        tags: const ['indoor', 'calm'],
      );

      for (final rating in const [5, 2, 0]) {
        final answer = await _ask(worker, rating + 1, catalog, outside, rating: rating);

        expect(answer.rankedOn, SimilarQuestThread.worker);
        expect(answer.quests, orderedEquals(_synchronous(catalog, outside, rating, 60)));
      }
    });
  });

  group('protocol', () {
    test('the catalog is copied to the worker only when it changes', () async {
      final catalog = _catalog(200);
      for (var i = 1; i <= 5; i++) {
        await _ask(worker, i, catalog, catalog.first, rating: i % 6);
      }
      expect(worker.catalogMessagesSent, 1);

      // A reload that brings the same content (new objects): not copied, and
      // the answer is made of the new objects.
      final reloaded = _catalog(200);
      final answer = await _ask(worker, 6, reloaded, reloaded.first, rating: 5);
      expect(worker.catalogMessagesSent, 1);
      expect(answer.quests, orderedEquals(_synchronous(reloaded, reloaded.first, 5, 60)));

      // Different content: copied once more, and ranked over it.
      final changed = _catalog(200, durationShift: 3);
      final changedAnswer = await _ask(worker, 7, changed, changed.first, rating: 5);
      expect(worker.catalogMessagesSent, 2);
      expect(changedAnswer.quests, orderedEquals(_synchronous(changed, changed.first, 5, 60)));

      expect(worker.spawnCount, 1);
      expect(worker.fallbackCount, 0);
    });

    test('quick taps: every answer comes back with its own requestId', () async {
      final catalog = _catalog(300);
      const ratings = [1, 3, 5, 2, 4, 0];

      // All out at once, before the worker even started.
      final answers = await Future.wait([
        for (final (index, rating) in ratings.indexed)
          _ask(worker, index + 1, catalog, catalog.first, rating: rating),
      ]);

      for (final (index, rating) in ratings.indexed) {
        expect(answers[index].requestId, index + 1);
        expect(answers[index].rankedOn, SimilarQuestThread.worker);
        expect(
          answers[index].quests,
          orderedEquals(_synchronous(catalog, catalog.first, rating, 60)),
        );
      }
      expect(worker.spawnCount, 1);
      expect(worker.catalogMessagesSent, 1);
    });

    test('every field of a quest survives the trip (Quest.fromJson on the other side)', () {
      const quest = Quest(
        id: 'q',
        title: 'Título',
        description: 'Descripción',
        category: 'food',
        emoji: '🍜',
        durationMinutes: 25,
        estimatedCost: 12.5,
        difficulty: 'hard',
        locationMode: 'gps',
        socialLevel: 'group',
        locationName: 'Usaquén',
        latitude: 4.7,
        longitude: -74.03,
        tags: ['outdoor', 'cheap'],
        isNew: true,
        isSponsored: true,
        sponsorName: 'Café',
        sponsorBusinessCategory: 'food_and_drink',
        isGroup: true,
      );

      final copy = Quest.fromJson(questToWorkerMessage(quest));

      expect(
        [
          copy.id,
          copy.title,
          copy.description,
          copy.category,
          copy.emoji,
          copy.durationMinutes,
          copy.estimatedCost,
          copy.difficulty,
          copy.locationMode,
          copy.socialLevel,
          copy.locationName,
          copy.latitude,
          copy.longitude,
          copy.tags,
          copy.isNew,
          copy.isSponsored,
          copy.sponsorName,
          copy.sponsorBusinessCategory,
          copy.isGroup,
        ],
        [
          quest.id,
          quest.title,
          quest.description,
          quest.category,
          quest.emoji,
          quest.durationMinutes,
          quest.estimatedCost,
          quest.difficulty,
          quest.locationMode,
          quest.socialLevel,
          quest.locationName,
          quest.latitude,
          quest.longitude,
          quest.tags,
          quest.isNew,
          quest.isSponsored,
          quest.sponsorName,
          quest.sponsorBusinessCategory,
          quest.isGroup,
        ],
      );
    });
  });

  group('fallback to the UI thread', () {
    test('a worker that crashes: same answer from the UI thread, a new worker next time', () async {
      newWorker(entryPoint: _crashingWorker);
      final catalog = _catalog(100);

      final first = await _ask(worker, 1, catalog, catalog.first, rating: 5);

      expect(first.rankedOn, SimilarQuestThread.uiThread);
      expect(first.fallbackReason, contains('crashed'));
      expect(first.quests, orderedEquals(_synchronous(catalog, catalog.first, 5, 60)));
      expect(worker.isRunning, isFalse);

      final second = await _ask(worker, 2, catalog, catalog.first, rating: 1);

      expect(worker.spawnCount, 2); // spawned again on the next request
      expect(second.quests, orderedEquals(_synchronous(catalog, catalog.first, 1, 60)));
      expect(worker.fallbackCount, 2);
    });

    test('a worker slower than the time limit: answered from the UI thread and replaced', () async {
      newWorker(entryPoint: _silentWorker, timeout: const Duration(milliseconds: 300));
      final catalog = _catalog(100);

      final answer = await _ask(worker, 1, catalog, catalog.first, rating: 4);

      expect(answer.rankedOn, SimilarQuestThread.uiThread);
      expect(answer.fallbackReason, contains('no answer within 300 ms'));
      expect(answer.quests, orderedEquals(_synchronous(catalog, catalog.first, 4, 60)));
      expect(worker.isRunning, isFalse);

      await _ask(worker, 2, catalog, catalog.first, rating: 4);
      expect(worker.spawnCount, 2);
    });

    test('a worker killed from outside: the next request starts a new one, and copies the catalog again', () async {
      final catalog = _catalog(100);
      await _ask(worker, 1, catalog, catalog.first, rating: 5);
      final exited = _exitOf(worker.debugIsolate!);

      worker.debugIsolate!.kill(priority: Isolate.immediate);
      await exited;
      await _untilStopped(worker);
      final answer = await _ask(worker, 2, catalog, catalog.first, rating: 2);

      expect(answer.rankedOn, SimilarQuestThread.worker);
      expect(answer.quests, orderedEquals(_synchronous(catalog, catalog.first, 2, 60)));
      expect(worker.spawnCount, 2);
      expect(worker.catalogMessagesSent, 2);
    });

    test('web (no isolates): ranks directly, and never spawns', () async {
      worker = SimilarQuestWorker(useIsolate: false, log: (_) {});
      final catalog = _catalog(100);

      final answer = await _ask(worker, 1, catalog, catalog.first, rating: 5);

      expect(answer.rankedOn, SimilarQuestThread.uiThread);
      expect(answer.fallbackReason, isNull);
      expect(answer.quests, orderedEquals(_synchronous(catalog, catalog.first, 5, 60)));
      expect(worker.spawnCount, 0);
    });
  });

  group('lifecycle', () {
    test('it only spawns on the first request', () async {
      expect(worker.spawnCount, 0);
      expect(worker.isRunning, isFalse);

      await _ask(worker, 1, _catalog(10), _catalog(10).first, rating: 3);

      expect(worker.spawnCount, 1);
      expect(worker.isRunning, isTrue);
      expect(worker.lastSpawnTime, isNotNull);
    });

    test(
      'close() (dispose) kills the isolate; a request still out is answered on the UI thread',
      () async {
        final catalog = _catalog(100);
        await _ask(worker, 1, catalog, catalog.first, rating: 5);
        final exited = _exitOf(worker.debugIsolate!);
        final stillOut = _ask(worker, 2, catalog, catalog.first, rating: 1);

        worker.close();

        await expectLater(exited, completes);
        expect(worker.isRunning, isFalse);
        expect(worker.debugIsolate, isNull);
        final answer = await stillOut;
        expect(answer.rankedOn, SimilarQuestThread.uiThread);
        expect(answer.fallbackReason, 'worker closed');
        expect(answer.quests, orderedEquals(_synchronous(catalog, catalog.first, 1, 60)));
      },
    );

    test(
      'signing out (AuthRepository.signOut) kills it too; the next request starts a new one',
      () async {
        final catalog = _catalog(100);
        await _ask(worker, 1, catalog, catalog.first, rating: 5);
        final exited = _exitOf(worker.debugIsolate!);
        final auth = AuthRepository(_SignedOutRemote(), _ClearableLocal(), sessionCaches: [worker]);

        await auth.signOut();

        await expectLater(exited, completes);
        expect(worker.isRunning, isFalse);

        final answer = await _ask(worker, 2, catalog, catalog.first, rating: 5);
        expect(answer.rankedOn, SimilarQuestThread.worker);
        expect(worker.spawnCount, 2);
        expect(worker.catalogMessagesSent, 2); // the new worker has no catalog yet
      },
    );

    test('close() before anything started is harmless', () {
      worker.close();
      worker.close();

      expect(worker.isRunning, isFalse);
      expect(worker.spawnCount, 0);
    });
  });
}
