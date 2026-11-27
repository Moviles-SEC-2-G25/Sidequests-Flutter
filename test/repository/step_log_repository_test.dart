import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sidequests/core/memo.dart';
import 'package:sidequests/data/local/local_data_source.dart';
import 'package:sidequests/data/local/step_log_database.dart';
import 'package:sidequests/data/remote/supabase_remote_data_source.dart';
import 'package:sidequests/models/step_log_entry.dart';
import 'package:sidequests/repository/auth_repository.dart';
import 'package:sidequests/repository/quest_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Signing out: [signOutFails] like a dropped connection.
class _FakeRemote implements SupabaseRemoteDataSource {
  bool signOutFails = false;

  @override
  Future<void> signOut() async {
    if (signOutFails) throw const SocketException('offline');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Only clear() is used; Hive keeps everything else.
class _FakeLocal implements LocalDataSource {
  int clears = 0;

  @override
  Future<void> clear() async => clears++;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A database that can never open: its path is a directory.
Future<StepLogDatabase> _brokenDatabase() async {
  final dir = await Directory.systemTemp.createTemp('step_log_broken');
  addTearDown(() => dir.delete(recursive: true));
  return StepLogDatabase(factory: databaseFactoryFfiNoIsolate, path: dir.path);
}

StepLogEntry _walk(String attemptId, {int steps = 100, String? category = 'food', DateTime? at}) =>
    StepLogEntry(
      attemptId: attemptId,
      questId: 'q-$attemptId',
      category: category,
      steps: steps,
      outcome: StepLogEntry.completed,
      finishedAt: at ?? DateTime.utc(2026, 11, 26),
    );

void main() {
  final today = DateTime.utc(2026, 11, 26, 12);
  late StepLogDatabase database;
  late _FakeRemote remote;
  late _FakeLocal local;

  setUpAll(sqfliteFfiInit);

  setUp(() {
    database = StepLogDatabase(factory: databaseFactoryFfiNoIsolate, path: inMemoryDatabasePath);
    remote = _FakeRemote();
    local = _FakeLocal();
  });

  tearDown(() => database.close());

  QuestRepository questRepository(StepLogDatabase? stepLog) =>
      QuestRepository(remote, local, stepLog: stepLog);

  group('QuestRepository.logWalk', () {
    test('saves the walk in SQLite', () async {
      await questRepository(database).logWalk(_walk('uq-1', steps: 321));

      expect((await database.topWalk())!.steps, 321);
    });

    test('a walk without steps is not saved', () async {
      await questRepository(database).logWalk(_walk('uq-1', steps: 0));

      expect(await database.topWalk(), isNull);
    });

    test('without a database (web build) it does nothing', () async {
      await expectLater(questRepository(null).logWalk(_walk('uq-1')), completes);
    });

    test('a SQLite failure is swallowed, never thrown', () async {
      await expectLater(questRepository(await _brokenDatabase()).logWalk(_walk('uq-1')), completes);
    });
  });

  group('QuestRepository.getWalkStats', () {
    test('steps since the date, per category and the longest walk', () async {
      await database.insertOrReplace(_walk('old', steps: 5000, at: today.subtract(const Duration(days: 9))));
      await database.insertOrReplace(_walk('a', steps: 300, category: 'art', at: today));
      await database.insertOrReplace(_walk('b', steps: 200, at: today));

      final stats = await questRepository(database).getWalkStats(
        since: today.subtract(const Duration(days: 7)),
      );

      expect(stats.recentSteps, 500);
      expect(stats.stepsByCategory, [
        (category: 'food', steps: 5200),
        (category: 'art', steps: 300),
      ]);
      expect(stats.longestWalk!.attemptId, 'old');
    });

    test('without a database, or with a broken one, it is empty instead of failing', () async {
      for (final stepLog in [null, await _brokenDatabase()]) {
        final stats = await questRepository(stepLog).getWalkStats(since: today);

        expect(stats.recentSteps, 0);
        expect(stats.stepsByCategory, isEmpty);
        expect(stats.longestWalk, isNull);
      }
    });
  });

  group('AuthRepository clears the step log with the rest of the account', () {
    test('signing out', () async {
      await database.insertOrReplace(_walk('uq-1'));

      await AuthRepository(remote, local, stepLog: database).signOut();

      expect(local.clears, 1);
      expect(await database.topWalk(), isNull);
    });

    test('signing out offline still clears it', () async {
      remote.signOutFails = true;
      await database.insertOrReplace(_walk('uq-1'));

      await AuthRepository(remote, local, stepLog: database).signOut();

      expect(await database.topWalk(), isNull);
    });

    test('a session the server ended (clearLocalData)', () async {
      await database.insertOrReplace(_walk('uq-1'));

      await AuthRepository(remote, local, stepLog: database).clearLocalData();

      expect(local.clears, 1);
      expect(await database.topWalk(), isNull);
    });

    test('a step log that cannot be cleared never blocks signing out', () async {
      final auth = AuthRepository(remote, local, stepLog: await _brokenDatabase());

      await expectLater(auth.signOut(), completes);
      await expectLater(auth.clearLocalData(), completes);
      expect(local.clears, 2);
    });

    test('without a database (web build) signing out works as before', () async {
      await AuthRepository(remote, local).signOut();

      expect(local.clears, 1);
    });
  });

  group('AuthRepository empties the session caches with the rest of the account', () {
    late Memo<String, int> likelihood;
    late AsyncMemo<int, int> stats;
    late int computations;

    int compute() => ++computations;

    setUp(() {
      likelihood = Memo();
      stats = AsyncMemo();
      computations = 0;
    });

    Future<void> fillBoth() async {
      likelihood.get('k', compute);
      await stats.get(1, () async => compute());
      computations = 0;
    }

    Future<void> expectBothEmpty() async {
      likelihood.get('k', compute);
      await stats.get(1, () async => compute());
      expect(computations, 2, reason: 'both computed again');
    }

    test('signing out', () async {
      await fillBoth();

      await AuthRepository(remote, local, sessionCaches: [likelihood, stats]).signOut();

      await expectBothEmpty();
    });

    test('signing out offline', () async {
      remote.signOutFails = true;
      await fillBoth();

      await AuthRepository(remote, local, sessionCaches: [likelihood, stats]).signOut();

      await expectBothEmpty();
    });

    test('a session the server ended (clearLocalData)', () async {
      await fillBoth();

      await AuthRepository(remote, local, sessionCaches: [likelihood, stats]).clearLocalData();

      await expectBothEmpty();
    });

    test('even when the step log cannot be cleared', () async {
      await fillBoth();

      await AuthRepository(
        remote,
        local,
        stepLog: await _brokenDatabase(),
        sessionCaches: [likelihood, stats],
      ).signOut();

      await expectBothEmpty();
    });
  });
}
