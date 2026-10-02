import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:sidequests/core/app_exception.dart';
import 'package:sidequests/core/completion_likelihood.dart';
import 'package:sidequests/models/quest.dart';
import 'package:sidequests/models/user_quest.dart';
import 'package:sidequests/repository/quest_repository.dart';
import 'package:sidequests/view/profile/stats_view.dart';
import 'package:sidequests/viewmodel/profile/stats_view_model.dart';

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
    viewModel = StatsViewModel(repository, 'user-1');
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
}
