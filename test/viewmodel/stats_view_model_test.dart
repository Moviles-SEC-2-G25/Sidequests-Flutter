import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:sidequests/core/app_exception.dart';
import 'package:sidequests/core/completion_likelihood.dart';
import 'package:sidequests/data/local/local_data_source.dart';
import 'package:sidequests/data/local/step_log_database.dart';
import 'package:sidequests/data/remote/supabase_remote_data_source.dart';
import 'package:sidequests/models/quest.dart';
import 'package:sidequests/models/step_log_entry.dart';
import 'package:sidequests/models/user_quest.dart';
import 'package:sidequests/repository/quest_repository.dart';
import 'package:sidequests/view/profile/stats_view.dart';
import 'package:sidequests/viewmodel/profile/stats_view_model.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Quest _quest(String id, String category) => Quest(
  id: id,
  title: 'Quest $id',
  category: category,
  durationMinutes: 20,
  difficulty: 'easy',
  locationMode: 'anywhere',
  socialLevel: 'solo',
);

UserQuest _attempt(String id, String questId, String status) => UserQuest(
  id: id,
  userId: 'user-1',
  questId: questId,
  status: status,
  acceptedAt: DateTime(2026, 1, 1),
);

/// Only what StatsViewModel reads: the catalogue, the user's attempts (with
/// whether they came from the Hive cache) and the local step totals.
class _FakeQuestRepository implements QuestRepository {
  List<Quest> catalog = [];
  List<UserQuest> userQuests = [];
  bool fromCache = false;
  Map<String, int> stepTotals = {};
  Completer<void>? gate;
  bool throwAppException = false;

  /// What the step log (SQLite) answers, and the date it was asked from.
  WalkStats walks = (recentSteps: 0, stepsByCategory: const [], longestWalk: null);
  DateTime? walksSince;

  /// When set, the walks come from a real repository over SQLite.
  QuestRepository? walkSource;
  Completer<void>? walksGate;

  @override
  Future<WalkStats> getWalkStats({required DateTime since}) async {
    walksSince = since;
    await walksGate?.future;
    return walkSource?.getWalkStats(since: since) ?? walks;
  }

  @override
  Future<List<Quest>> getCatalog() async => catalog;

  @override
  Future<({List<UserQuest> userQuests, bool fromCache})> getUserQuestsWithSource(
    String userId,
  ) async {
    await gate?.future;
    if (throwAppException) throw AppException('Algo salió mal');
    return (userQuests: userQuests, fromCache: fromCache);
  }

  @override
  Map<String, int> getStepTotals() => stepTotals;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// compute() replaced: a real isolate never finishes inside testWidgets.
Future<StatsSummary> _inline(StatsInput input) async => summarizeStats(input);

void main() {
  late _FakeQuestRepository repository;
  late StatsViewModel viewModel;

  void seedHistory() {
    repository.catalog = [
      _quest('f1', 'Food'),
      _quest('f2', 'Food'),
      _quest('f3', 'Food'),
      _quest('a1', 'Art'),
    ];
    repository.userQuests = [
      _attempt('uq-1', 'f1', 'completed'),
      _attempt('uq-2', 'f2', 'completed'),
      _attempt('uq-3', 'f3', 'abandoned'),
      _attempt('uq-4', 'a1', 'completed'),
      _attempt('uq-5', 'a1', 'skipped'), // never an attempt
    ];
  }

  setUp(() {
    repository = _FakeQuestRepository();
    viewModel = StatsViewModel(repository, 'user-1', runner: _inline);
  });

  group('summarizeStats', () {
    test('counts attempts without skipped, sorts categories and sums only known attempts', () {
      seedHistory();

      final summary = summarizeStats(
        StatsInput(
          catalog: repository.catalog,
          userQuests: repository.userQuests,
          stepTotals: const {'uq-1': 1200, 'uq-3': 34, 'someone-else': 9999},
        ),
      );

      expect(summary.attemptCount, 4);
      expect(summary.completedCount, 3);
      expect(summary.categoryStats.map((s) => s.category), ['food', 'art']);
      expect(summary.totalSteps, 1234);
    });

    test('ties in attempts sort by category; no step data is null, not 0', () {
      final summary = summarizeStats(
        StatsInput(
          catalog: [_quest('m1', 'Music'), _quest('a1', 'Art')],
          userQuests: [_attempt('uq-1', 'm1', 'completed'), _attempt('uq-2', 'a1', 'abandoned')],
          stepTotals: const {},
        ),
      );

      expect(summary.categoryStats.map((s) => s.category), ['art', 'music']);
      expect(summary.totalSteps, isNull);
    });
  });

  group('runner', () {
    test('load() hands the runner what it read, step totals included', () async {
      seedHistory();
      repository.stepTotals = {'uq-1': 50};
      StatsInput? received;
      final recording = StatsViewModel(
        repository,
        'user-1',
        runner: (input) async {
          received = input;
          return summarizeStats(input);
        },
      );

      await recording.load();

      expect(received!.catalog, repository.catalog);
      expect(received!.userQuests, repository.userQuests);
      expect(received!.stepTotals, {'uq-1': 50});
      expect(recording.totalSteps, 50);
    });

    // Not inline on purpose: only a real isolate proves that StatsInput and
    // StatsSummary can cross to it and back.
    test('the default runner gives the same result through a real isolate', () async {
      seedHistory();
      repository.stepTotals = {'uq-1': 1200, 'uq-3': 34};
      final background = StatsViewModel(repository, 'user-1');

      await background.load();

      expect(background.status, StatsStatus.data);
      expect(background.completedCount, 3);
      expect(background.attemptCount, 4);
      expect(background.categoryStats.map((s) => s.category), ['food', 'art']);
      expect(background.categoryStats.first.level, CompletionLevel.medium);
      expect(background.totalSteps, 1234);
    });
  });

  group('StatsViewModel', () {
    test('starts in loading so the first frame already shows the spinner', () {
      expect(viewModel.status, StatsStatus.loading);
    });

    test('data: completed/attempted counts, rates per category (most attempted first) and levels', () async {
      seedHistory();

      await viewModel.load();

      expect(viewModel.status, StatsStatus.data);
      expect(viewModel.isFromCache, isFalse);
      expect(viewModel.completedCount, 3);
      expect(viewModel.attemptCount, 4);
      expect(viewModel.overallRate, 0.75);

      expect(viewModel.categoryStats.map((s) => s.category), ['food', 'art']);
      final food = viewModel.categoryStats.first;
      expect((food.completed, food.attempts), (2, 3));
      expect(food.level, CompletionLevel.medium); // 0.67
      expect(viewModel.categoryStats.last.level, CompletionLevel.newForYou); // 1 attempt
    });

    test('totalSteps sums only this user\'s attempts; null without step data (≠ 0)', () async {
      seedHistory();
      repository.stepTotals = {'uq-1': 1200, 'uq-3': 34, 'someone-else': 9999};

      await viewModel.load();
      expect(viewModel.totalSteps, 1234);

      repository.stepTotals = {};
      await viewModel.load();
      expect(viewModel.totalSteps, isNull);
    });

    test('empty: online and no attempts yet', () async {
      await viewModel.load();

      expect(viewModel.status, StatsStatus.empty);
      expect(viewModel.errorMessage, isNull);
    });

    test('offline with cached data: shows it and flags it as cached', () async {
      seedHistory();
      repository.fromCache = true;

      await viewModel.load();

      expect(viewModel.status, StatsStatus.data);
      expect(viewModel.isFromCache, isTrue);
    });

    test('offline with nothing cached is an error, not "you have no missions"', () async {
      repository.fromCache = true;

      await viewModel.load();

      expect(viewModel.status, StatsStatus.error);
      expect(viewModel.errorMessage, contains('Sin conexión'));
    });

    test('offline with attempts cached but no catalogue: summary works, categories are empty', () async {
      seedHistory();
      repository.catalog = [];
      repository.fromCache = true;

      await viewModel.load();

      expect(viewModel.status, StatsStatus.data);
      expect(viewModel.completedCount, 3);
      expect(viewModel.categoryStats, isEmpty);
    });

    test('a refresh keeps the current data on screen instead of going back to loading', () async {
      seedHistory();
      await viewModel.load();

      repository.gate = Completer<void>();
      final refresh = viewModel.load();
      expect(viewModel.status, StatsStatus.data);

      repository.gate!.complete();
      await refresh;
      expect(viewModel.status, StatsStatus.data);
    });

    test('an AppException ends in the error state with its message', () async {
      repository.throwAppException = true;

      await viewModel.load();

      expect(viewModel.status, StatsStatus.error);
      expect(viewModel.errorMessage, 'Algo salió mal');
    });
  });

  group('StatsView', () {
    Future<void> pumpStats(WidgetTester tester) async {
      // A small phone, so any overflow fails the test.
      tester.view.physicalSize = const Size(360, 690);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: viewModel,
          child: const MaterialApp(home: StatsView()),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('data: summary, per-category rows and total steps', (tester) async {
      seedHistory();
      repository.stepTotals = {'uq-1': 1234};

      await pumpStats(tester);

      expect(find.text('Mis estadísticas'), findsOneWidget);
      expect(find.text('3'), findsOneWidget); // completadas
      expect(find.text('75 %'), findsOneWidget);
      expect(find.text('Gastronomía'), findsOneWidget);
      expect(find.text('2/3 · 67 %'), findsOneWidget);
      expect(find.text('Prob. media'), findsOneWidget);
      expect(find.text('Nueva para ti'), findsOneWidget); // Arte, 1 attempt

      await tester.scrollUntilVisible(find.text('1.234'), 100);
      expect(find.text('1.234'), findsOneWidget);
    });

    testWidgets('offline with cache: shows the offline banner', (tester) async {
      seedHistory();
      repository.fromCache = true;

      await pumpStats(tester);

      expect(find.textContaining('Sin conexión'), findsOneWidget);
    });

    testWidgets('no step data: shows "—", never 0', (tester) async {
      seedHistory();

      await pumpStats(tester);
      await tester.scrollUntilVisible(find.text('Pasos caminados en misiones'), 100);

      expect(find.text('—'), findsOneWidget);
    });

    testWidgets('empty and error states each show their message and action', (tester) async {
      await pumpStats(tester);
      expect(find.textContaining('Aún no has intentado'), findsOneWidget);

      repository.fromCache = true;
      await viewModel.load();
      await tester.pumpAndSettle();
      expect(find.textContaining('Sin conexión y sin datos guardados'), findsOneWidget);
      expect(find.text('Reintentar'), findsOneWidget);
    });
  });

  group('Tus caminatas (SQLite)', () {
    final now = DateTime.utc(2026, 11, 26, 18);
    late StepLogDatabase database;

    setUpAll(sqfliteFfiInit);

    setUp(() {
      database = StepLogDatabase(factory: databaseFactoryFfiNoIsolate, path: inMemoryDatabasePath);
      repository.walkSource = QuestRepository(_NoRemote(), _NoLocal(), stepLog: database);
      viewModel = StatsViewModel(repository, 'user-1', runner: _inline, now: () => now);
      seedHistory();
    });

    tearDown(() => database.close());

    Future<void> logWalk(String attemptId, String questId, String category, int steps, DateTime at) =>
        database.insertOrReplace(
          StepLogEntry(
            attemptId: attemptId,
            questId: questId,
            category: category,
            steps: steps,
            outcome: StepLogEntry.completed,
            finishedAt: at,
          ),
        );

    Future<void> logSomeWalks() async {
      await logWalk('uq-1', 'f1', 'food', 900, now.subtract(const Duration(days: 10)));
      await logWalk('uq-2', 'f2', 'food', 300, now.subtract(const Duration(days: 2)));
      await logWalk('uq-4', 'a1', 'art', 200, now.subtract(const Duration(hours: 1)));
    }

    test('reads the last 7 days, the steps per category and the longest walk', () async {
      await logSomeWalks();

      await viewModel.load();

      expect(repository.walksSince, now.subtract(const Duration(days: 7)));
      expect(viewModel.walkStepsLast7Days, 500);
      expect(viewModel.walkStepsByCategory, [
        (category: 'food', steps: 1200),
        (category: 'art', steps: 200),
      ]);
      expect(viewModel.longestWalk!.steps, 900);
      expect(viewModel.longestWalkTitle, 'Quest f1');
      expect(viewModel.hasWalks, isTrue);
    });

    test('no walks yet: nothing to show, and the rest of the screen still loads', () async {
      await viewModel.load();

      expect(viewModel.hasWalks, isFalse);
      expect(viewModel.walkStepsLast7Days, 0);
      expect(viewModel.walkStepsByCategory, isEmpty);
      expect(viewModel.status, StatsStatus.data);
    });

    test('offline (attempts from the cache): the walks are there all the same', () async {
      await logSomeWalks();
      repository.fromCache = true;

      await viewModel.load();

      expect(viewModel.isFromCache, isTrue);
      expect(viewModel.walkStepsLast7Days, 500);
    });

    test('the walks are read before the summary is computed', () async {
      repository.walksGate = Completer<void>();
      var computed = false;
      viewModel = StatsViewModel(
        repository,
        'user-1',
        runner: (input) async {
          computed = true;
          return summarizeStats(input);
        },
        now: () => now,
      );

      final load = viewModel.load();
      await pumpEventQueue();
      expect(computed, isFalse);

      repository.walksGate!.complete();
      await load;
      expect(computed, isTrue);
    });

    test('a quest that left the catalogue: the longest walk is still shown, untitled', () async {
      await logWalk('uq-9', 'gone', 'food', 4000, now);

      await viewModel.load();

      expect(viewModel.longestWalk!.steps, 4000);
      expect(viewModel.longestWalkTitle, isNull);
    });

    // The view gets the walks from the fake, not SQLite: FFI queries don't
    // advance under testWidgets' fake clock. The tests above read SQLite.
    Future<void> pumpStats(WidgetTester tester, {WalkStats? walks}) async {
      repository.walkSource = null;
      if (walks != null) repository.walks = walks;
      tester.view.physicalSize = const Size(360, 690);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ChangeNotifierProvider.value(value: viewModel, child: const MaterialApp(home: StatsView())),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('Tus caminatas'), 200);
      await tester.pumpAndSettle();
    }

    testWidgets('StatsView shows the section with its numbers', (tester) async {
      await pumpStats(
        tester,
        walks: (
          recentSteps: 500,
          stepsByCategory: const [(category: 'food', steps: 1200), (category: 'art', steps: 200)],
          longestWalk: StepLogEntry(
            attemptId: 'uq-1',
            questId: 'f1',
            category: 'food',
            steps: 900,
            outcome: StepLogEntry.completed,
            finishedAt: now.subtract(const Duration(days: 10)),
          ),
        ),
      );
      await tester.scrollUntilVisible(find.text('Pasos por categoría'), 200);

      expect(find.text('Tus caminatas'), findsOneWidget);
      expect(find.text('500'), findsOneWidget); // last 7 days
      expect(find.text('900'), findsOneWidget); // longest
      expect(find.text('Últimos 7 días'), findsOneWidget);
      expect(find.text('Caminata más larga'), findsOneWidget);
      expect(find.textContaining('Quest f1 · '), findsOneWidget);
      expect(find.text('1.200 pasos'), findsOneWidget);
      expect(find.text('200 pasos'), findsOneWidget);
    });

    testWidgets('StatsView: the empty state', (tester) async {
      await pumpStats(tester);

      expect(find.text('Tus caminatas'), findsOneWidget);
      expect(find.textContaining('Aún no hay caminatas guardadas'), findsOneWidget);
      expect(find.text('Últimos 7 días'), findsNothing);
    });
  });
}

/// The walks only touch the SQLite part of the repository.
class _NoRemote implements SupabaseRemoteDataSource {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _NoLocal implements LocalDataSource {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
