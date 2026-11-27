import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sidequests/data/local/step_log_database.dart';
import 'package:sidequests/models/step_log_entry.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

StepLogEntry _walk(
  String attemptId, {
  String questId = 'q',
  String? category = 'food',
  int steps = 100,
  String outcome = StepLogEntry.completed,
  required DateTime finishedAt,
}) => StepLogEntry(
  attemptId: attemptId,
  questId: questId,
  category: category,
  steps: steps,
  outcome: outcome,
  finishedAt: finishedAt,
);

void main() {
  final day = DateTime.utc(2026, 11, 20, 12);
  late StepLogDatabase database;

  setUpAll(sqfliteFfiInit);

  setUp(() {
    database = StepLogDatabase(factory: databaseFactoryFfiNoIsolate, path: inMemoryDatabasePath);
  });

  tearDown(() => database.close());

  test('a walk comes back exactly as it was saved', () async {
    final walk = _walk(
      'uq-1',
      questId: 'ramen',
      steps: 1234,
      outcome: StepLogEntry.abandoned,
      finishedAt: day,
    );

    await database.insertOrReplace(walk);

    final top = (await database.topWalk())!;
    expect(top.toRow(), walk.toRow());
    expect(top.finishedAt, day);
  });

  test('the same attempt saved again replaces its row', () async {
    await database.insertOrReplace(_walk('uq-1', steps: 100, finishedAt: day));
    await database.insertOrReplace(_walk('uq-1', steps: 300, finishedAt: day));

    expect(await database.stepsSince(day), 300);
  });

  test('stepsSince sums from that moment on, inclusive, and is 0 with nothing', () async {
    expect(await database.stepsSince(day), 0);

    await database.insertOrReplace(_walk('old', steps: 900, finishedAt: day.subtract(const Duration(days: 8))));
    await database.insertOrReplace(_walk('edge', steps: 50, finishedAt: day));
    await database.insertOrReplace(_walk('new', steps: 70, finishedAt: day.add(const Duration(hours: 3))));

    expect(await database.stepsSince(day), 120);
    expect(await database.stepsSince(day.add(const Duration(milliseconds: 1))), 70);
  });

  test('stepsByCategory groups, most walked first, ties by name, unknown category out', () async {
    await database.insertOrReplace(_walk('1', category: 'food', steps: 100, finishedAt: day));
    await database.insertOrReplace(_walk('2', category: 'food', steps: 250, finishedAt: day));
    await database.insertOrReplace(_walk('3', category: 'art', steps: 350, finishedAt: day));
    await database.insertOrReplace(_walk('4', category: 'outdoors', steps: 350, finishedAt: day));
    await database.insertOrReplace(_walk('5', category: null, steps: 999, finishedAt: day));

    expect(await database.stepsByCategory(), [
      (category: 'art', steps: 350),
      (category: 'food', steps: 350),
      (category: 'outdoors', steps: 350),
    ]);
  });

  test('topWalk is the one with most steps; on a tie, the latest', () async {
    expect(await database.topWalk(), isNull);

    await database.insertOrReplace(_walk('short', steps: 10, finishedAt: day));
    await database.insertOrReplace(_walk('long-old', steps: 500, finishedAt: day));
    await database.insertOrReplace(
      _walk('long-new', steps: 500, finishedAt: day.add(const Duration(days: 1))),
    );

    expect((await database.topWalk())!.attemptId, 'long-new');
  });

  test('clear empties the table', () async {
    await database.insertOrReplace(_walk('1', finishedAt: day));

    await database.clear();

    expect(await database.topWalk(), isNull);
    expect(await database.stepsSince(DateTime.utc(2000)), 0);
    expect(await database.stepsByCategory(), isEmpty);
  });

  test('the table rejects what the app should never write', () async {
    await expectLater(
      database.insertOrReplace(_walk('zero', steps: 0, finishedAt: day)),
      throwsA(isA<DatabaseException>()),
    );
    await expectLater(
      database.insertOrReplace(_walk('odd', outcome: 'skipped', finishedAt: day)),
      throwsA(isA<DatabaseException>()),
    );
  });

  test('finished_at is indexed, and a file survives closing and reopening', () async {
    final dir = await Directory.systemTemp.createTemp('step_log_test');
    addTearDown(() => dir.delete(recursive: true));
    final path = '${dir.path}/step_log.db';
    final onDisk = StepLogDatabase(factory: databaseFactoryFfiNoIsolate, path: path);
    await onDisk.insertOrReplace(_walk('uq-1', steps: 42, finishedAt: day));
    await onDisk.close();

    final reopened = StepLogDatabase(factory: databaseFactoryFfiNoIsolate, path: path);
    expect((await reopened.topWalk())!.steps, 42);
    await reopened.close();

    final raw = await databaseFactoryFfiNoIsolate.openDatabase(path);
    final indexes = await raw.rawQuery("PRAGMA index_list('step_log')");
    expect(indexes.map((row) => row['name']), contains('step_log_finished_at_idx'));
    await raw.close();
  });
}
