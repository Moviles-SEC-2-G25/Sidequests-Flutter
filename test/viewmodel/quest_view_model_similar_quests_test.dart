import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:sidequests/analytics/analytics_event_sink.dart';
import 'package:sidequests/analytics/analytics_tracker.dart';
import 'package:sidequests/core/similar_quest_recommender.dart';
import 'package:sidequests/core/workers/similar_quest_worker.dart';
import 'package:sidequests/data/context/context_manager.dart';
import 'package:sidequests/data/services/battery_monitor.dart';
import 'package:sidequests/data/services/location_service.dart';
import 'package:sidequests/data/services/step_counter_service.dart';
import 'package:sidequests/models/quest.dart';
import 'package:sidequests/models/user_quest.dart';
import 'package:sidequests/repository/quest_repository.dart';
import 'package:sidequests/viewmodel/quests/quest_view_model.dart';

/// QuestViewModel's side of the "You might also like" worker: which requests it
/// sends, which answers it applies, and that it releases the worker.

class _NoLocation extends LocationService {
  @override
  Future<Position?> getCurrentPosition({
    LocationAccuracy accuracy = LocationAccuracy.medium,
  }) async => null;
}

class _FullBattery extends BatteryMonitor {
  @override
  Future<bool> isLow() async => false;
}

class _NullSink implements AnalyticsEventSink {
  @override
  Future<void> insertAnalyticsEvent(Map<String, dynamic> event) async {}
}

ContextManager _contextManager() =>
    ContextManager(locationService: _NoLocation(), batteryMonitor: _FullBattery());

class _SilentTracker extends AnalyticsTracker {
  _SilentTracker()
    : super(eventSink: _NullSink(), contextManager: _contextManager(), sessionId: 'unused');
}

/// Never reached: the catalog and attempts are set directly.
class _NoRepository implements QuestRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Holds every request until the test answers it, in any order.
class _ManualRunner implements SimilarQuestRunner {
  final requests =
      <
        ({
          int requestId,
          List<Quest> catalog,
          SimilarQuestQuery query,
          Completer<SimilarQuestAnswer> answer,
        })
      >[];
  int closeCount = 0;

  @override
  Future<SimilarQuestAnswer> recommend({
    required int requestId,
    required List<Quest> catalog,
    required SimilarQuestQuery query,
  }) {
    final answer = Completer<SimilarQuestAnswer>();
    requests.add((requestId: requestId, catalog: catalog, query: query, answer: answer));
    return answer.future;
  }

  /// Answers the [index]-th request with [quests].
  void answer(int index, List<Quest> quests) {
    final request = requests[index];
    request.answer.complete(
      SimilarQuestAnswer(
        requestId: request.requestId,
        quests: quests,
        rankedOn: SimilarQuestThread.worker,
        uiThreadTime: Duration.zero,
      ),
    );
  }

  @override
  void close() => closeCount++;
}

Quest _quest(String id, {String category = 'food', int minutes = 20}) => Quest(
  id: id,
  title: 'Quest $id',
  category: category,
  durationMinutes: minutes,
  difficulty: 'easy',
  locationMode: 'anywhere',
  socialLevel: 'solo',
);

UserQuest _attempt(String questId, String status) => UserQuest(
  id: 'uq-$questId',
  userId: 'user-1',
  questId: questId,
  status: status,
  acceptedAt: DateTime(2026, 1, 1),
);

void main() {
  final completed = _quest('ramen');
  final catalog = [
    completed,
    _quest('sushi'),
    _quest('museo', category: 'art'),
    _quest('tacos'),
    _quest('pizza'),
    _quest('largo', minutes: 500),
  ];
  final attempts = [_attempt('tacos', 'in_progress'), _attempt('pizza', 'completed')];

  QuestViewModel newViewModel(SimilarQuestRunner runner) =>
      QuestViewModel(
          _NoRepository(),
          _contextManager(),
          _SilentTracker(),
          'user-1',
          similarQuestRunner: runner,
          stepCounter: StepCounterService(requestAccess: () async => StepCounterStatus.unavailable),
        )
        ..catalog = catalog
        ..userQuests = attempts;

  group('stale answers', () {
    test('quick taps: only the answer to the latest requestId is applied', () async {
      final runner = _ManualRunner();
      final viewModel = newViewModel(runner);
      var notifications = 0;
      viewModel.addListener(() => notifications++);

      final oneStar = viewModel.requestSimilarQuests(completed: completed, rating: 1);
      final threeStars = viewModel.requestSimilarQuests(completed: completed, rating: 3);
      final fiveStars = viewModel.requestSimilarQuests(completed: completed, rating: 5);
      expect(runner.requests.map((r) => r.requestId), [1, 2, 3]);

      // The answers come back out of order: 5★ first, then the older ones.
      runner.answer(2, [catalog[1]]);
      runner.answer(0, [catalog[2]]);
      runner.answer(1, [catalog[3]]);

      expect(await fiveStars, [catalog[1]]);
      expect(await oneStar, isNull);
      expect(await threeStars, isNull);
      expect(viewModel.similarQuestsFor(completed: completed, rating: 5), [catalog[1]]);
      expect(notifications, 1); // the old answers didn't repaint anything
      expect(runner.requests, hasLength(3)); // reading it with the same rating sent nothing
    });

    test('an old answer arriving after the latest one does not overwrite it', () async {
      final runner = _ManualRunner();
      final viewModel = newViewModel(runner);

      final older = viewModel.requestSimilarQuests(completed: completed, rating: 2);
      final latest = viewModel.requestSimilarQuests(completed: completed, rating: 4);
      runner.answer(1, [catalog[1]]);
      await latest;
      runner.answer(0, [catalog[2]]);
      await older;

      expect(viewModel.similarQuestsFor(completed: completed, rating: 4), [catalog[1]]);
    });
  });

  group('similarQuestsFor (read on every build)', () {
    test('asks again only when its inputs change', () {
      final runner = _ManualRunner();
      final viewModel = newViewModel(runner);

      for (var i = 0; i < 3; i++) {
        viewModel.similarQuestsFor(completed: completed, rating: 0);
      }
      expect(runner.requests, hasLength(1));

      viewModel.similarQuestsFor(completed: completed, rating: 4); // another star
      viewModel.similarQuestsFor(completed: completed, rating: 4);
      expect(runner.requests, hasLength(2));

      viewModel.catalog = [...catalog]; // a reload
      viewModel.similarQuestsFor(completed: completed, rating: 4);
      viewModel.userQuests = [...attempts]; // an attempt changed
      viewModel.similarQuestsFor(completed: completed, rating: 4);
      viewModel.selectedMinutes = viewModel.selectedMinutes == 45 ? 60 : 45; // another filter
      viewModel.similarQuestsFor(completed: completed, rating: 4);
      expect(runner.requests, hasLength(5));
    });

    test('the request carries only small values; the catalog goes as the same list', () {
      final runner = _ManualRunner();
      final viewModel = newViewModel(runner)..selectedMinutes = 45;

      viewModel.similarQuestsFor(completed: completed, rating: 2);

      final request = runner.requests.single;
      expect(identical(request.catalog, viewModel.catalog), isTrue);
      expect(request.query.completed, same(completed));
      expect(request.query.rating, 2);
      expect(request.query.maxMinutes, 45);
      expect(request.query.unavailableQuestIds, {'tacos', 'pizza'});
    });

    test('empty until the first answer; keeps the last one while a new rating is out', () async {
      final runner = _ManualRunner();
      final viewModel = newViewModel(runner);

      expect(viewModel.similarQuestsFor(completed: completed, rating: 0), isEmpty);
      runner.answer(0, [catalog[1], catalog[2]]);
      await pumpEventQueue();

      expect(viewModel.similarQuestsFor(completed: completed, rating: 5), [catalog[1], catalog[2]]);
      expect(runner.requests, hasLength(2)); // 5★ is out, the 0★ list stays meanwhile
      // Another completed quest doesn't show this one's list.
      expect(viewModel.similarQuestsFor(completed: catalog[1], rating: 5), isEmpty);
    });
  });

  group('same answer as before the worker', () {
    test('with the synchronous runner (widget tests, web)', () async {
      final viewModel = newViewModel(const SynchronousSimilarQuestRunner());

      for (final rating in const [5, 2, 0]) {
        final shown = await viewModel.requestSimilarQuests(completed: completed, rating: rating);
        expect(
          shown,
          orderedEquals(
            const SimilarQuestRecommender().recommend(
              completed,
              catalog,
              attempts,
              rating,
              viewModel.selectedMinutes,
            ),
          ),
        );
      }
    });

    test('with the real worker isolate, which dispose then kills', () async {
      final worker = SimilarQuestWorker(useIsolate: true, log: (_) {});
      final viewModel = newViewModel(worker);

      for (final rating in const [5, 1, 0]) {
        final shown = await viewModel.requestSimilarQuests(completed: completed, rating: rating);
        expect(
          shown,
          orderedEquals(
            const SimilarQuestRecommender().recommend(
              completed,
              catalog,
              attempts,
              rating,
              viewModel.selectedMinutes,
            ),
          ),
        );
      }
      expect(worker.isRunning, isTrue);
      expect(worker.spawnCount, 1);
      expect(worker.catalogMessagesSent, 1);

      viewModel.dispose();

      expect(worker.isRunning, isFalse);
    });
  });

  test('dispose closes the runner, and an answer arriving later is ignored', () async {
    final runner = _ManualRunner();
    final viewModel = newViewModel(runner);
    final pending = viewModel.requestSimilarQuests(completed: completed, rating: 5);

    viewModel.dispose();
    runner.answer(0, [catalog[1]]);

    expect(runner.closeCount, 1);
    expect(await pending, isNull); // no notifyListeners on a disposed ViewModel
  });
}
