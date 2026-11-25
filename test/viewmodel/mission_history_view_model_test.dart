import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:sidequests/core/app_exception.dart';
import 'package:sidequests/core/mission_history.dart';
import 'package:sidequests/models/quest.dart';
import 'package:sidequests/models/user_quest.dart';
import 'package:sidequests/repository/quest_repository.dart';
import 'package:sidequests/view/profile/mission_history_view.dart';
import 'package:sidequests/viewmodel/profile/mission_history_view_model.dart';

Quest _quest(String id, String title, String category) => Quest(
  id: id,
  title: title,
  category: category,
  durationMinutes: 30,
  difficulty: 'easy',
  locationMode: 'anywhere',
  socialLevel: 'solo',
);

/// When the fake server answers: what a fresh read saves as [syncedAt].
final _serverAnsweredAt = DateTime(2026, 11, 25, 9, 30);

/// Only what MissionHistoryViewModel reads, like StatsViewModel's fake.
/// [fromCache] stands for "the server didn't answer"; a read that reaches
/// it sends the queue first, as the real one does, so [pending] empties,
/// and saves when it happened in [syncedAt] (the device's Hive copy).
class _FakeQuestRepository implements QuestRepository {
  List<Quest> catalog = [];
  List<UserQuest> userQuests = [];
  bool fromCache = false;
  Map<String, int> stepTotals = {};
  Set<String> pending = {};
  DateTime? syncedAt;
  Completer<void>? gate;
  bool throwAppException = false;
  int reads = 0;

  @override
  Future<List<Quest>> getCatalog() async => catalog;

  @override
  Future<({List<UserQuest> userQuests, bool fromCache})> getUserQuestsWithSource(
    String userId,
  ) async {
    reads++;
    await gate?.future;
    if (throwAppException) throw AppException('Algo salió mal');
    if (!fromCache) {
      pending = {};
      syncedAt = _serverAnsweredAt;
    }
    return (userQuests: userQuests, fromCache: fromCache);
  }

  @override
  Set<String> pendingSyncAttemptIds() => pending;

  @override
  Map<String, int> getStepTotals() => stepTotals;

  @override
  DateTime? userQuestsSyncedAt() => syncedAt;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// compute() replaced: a real isolate never finishes inside testWidgets.
/// Records every input it gets.
class _InlineRunner {
  final inputs = <MissionHistoryInput>[];

  Future<MissionHistory> call(MissionHistoryInput input) async {
    inputs.add(input);
    return buildMissionHistory(input);
  }
}

/// Answers only when the test says so, to finish runs out of order.
class _GatedRunner {
  final calls = <(MissionHistoryInput, Completer<MissionHistory>)>[];

  Future<MissionHistory> call(MissionHistoryInput input) {
    final completer = Completer<MissionHistory>();
    calls.add((input, completer));
    return completer.future;
  }

  void finish(int index) {
    final (input, completer) = calls[index];
    completer.complete(buildMissionHistory(input));
  }
}

void main() {
  late _FakeQuestRepository repository;
  late _InlineRunner runner;
  late MissionHistoryViewModel viewModel;

  /// The device's connection: add(true) is "no network", add(false) "back".
  late StreamController<bool> connectivity;
  var startsOffline = false;

  /// Built inside a testWidgets body when the test moves time: timers started
  /// from a stream listener belong to the zone where it was built.
  MissionHistoryViewModel build({MissionHistoryRunner? withRunner}) => MissionHistoryViewModel(
    repository,
    'user-1',
    runner: withRunner ?? runner.call,
    isOffline: () async => startsOffline,
    offlineChanges: () => connectivity.stream,
  );

  void seedHistory() {
    repository.catalog = [
      _quest('cafe', 'Café de especialidad', 'food'),
      _quest('mural', 'Murales del centro', 'art'),
    ];
    repository.userQuests = [
      UserQuest(
        id: 'uq-1',
        userId: 'user-1',
        questId: 'cafe',
        status: 'completed',
        rating: 4,
        acceptedAt: DateTime(2026, 11, 1),
        completedAt: DateTime(2026, 11, 2),
      ),
      UserQuest(
        id: 'uq-2',
        userId: 'user-1',
        questId: 'mural',
        status: 'abandoned',
        abandonReason: 'too_far',
        acceptedAt: DateTime(2026, 10, 1),
        abandonedAt: DateTime(2026, 10, 3),
      ),
      UserQuest(
        id: 'uq-3',
        userId: 'user-1',
        questId: 'mural',
        status: 'skipped',
        acceptedAt: DateTime(2026, 11, 5),
      ),
    ];
  }

  setUp(() {
    repository = _FakeQuestRepository();
    runner = _InlineRunner();
    connectivity = StreamController<bool>.broadcast();
    startsOffline = false;
    viewModel = build();
  });

  group('MissionHistoryViewModel', () {
    test('starts in loading so the first frame already shows the spinner', () {
      expect(viewModel.status, HistoryStatus.loading);
    });

    test('data: hands the runner what it read and shows its history', () async {
      seedHistory();
      repository.stepTotals = {'uq-1': 800};

      await viewModel.load();

      expect(viewModel.status, HistoryStatus.data);
      expect(viewModel.isFromCache, isFalse);
      expect(viewModel.isUpdating, isFalse);
      final input = runner.inputs.single;
      expect(input.catalog, repository.catalog);
      expect(input.userQuests, repository.userQuests);
      expect(input.stepTotals, {'uq-1': 800});
      expect((input.filter, input.query), (HistoryFilter.all, ''));
      expect(viewModel.history.totalAttempts, 2);
      expect(viewModel.history.months.length, 2);
    });

    test('empty: online and no attempts yet (a skip alone is not one)', () async {
      repository.userQuests = [
        UserQuest(id: 'uq', userId: 'user-1', questId: 'q', status: 'skipped', acceptedAt: DateTime(2026)),
      ];

      await viewModel.load();

      expect(viewModel.status, HistoryStatus.empty);
      expect(viewModel.errorMessage, isNull);
    });

    test('offline with cached attempts: shows them and flags them as cached', () async {
      seedHistory();
      repository.fromCache = true;

      await viewModel.load();

      expect(viewModel.status, HistoryStatus.data);
      expect(viewModel.isFromCache, isTrue);
    });

    test('offline with nothing cached is an error, not "your bitácora is empty"', () async {
      repository.fromCache = true;

      await viewModel.load();

      expect(viewModel.status, HistoryStatus.error);
      expect(viewModel.errorMessage, contains('Sin conexión'));
    });

    test('an AppException ends in the error state with its message', () async {
      repository.throwAppException = true;

      await viewModel.load();

      expect(viewModel.status, HistoryStatus.error);
      expect(viewModel.errorMessage, 'Algo salió mal');
    });

    test('a refresh keeps the current list on screen instead of going back to loading', () async {
      seedHistory();
      await viewModel.load();

      repository.gate = Completer<void>();
      final refresh = viewModel.load();
      expect(viewModel.status, HistoryStatus.data);

      repository.gate!.complete();
      await refresh;
      expect(viewModel.status, HistoryStatus.data);
    });

    test('a filter runs right away, with the data already loaded', () async {
      seedHistory();
      await viewModel.load();

      viewModel.setFilter(HistoryFilter.abandoned);
      await pumpEventQueue();

      expect(runner.inputs.length, 2);
      expect(runner.inputs.last.filter, HistoryFilter.abandoned);
      expect(runner.inputs.last.userQuests, repository.userQuests);
      expect(viewModel.history.matchCount, 1);
      expect(viewModel.isNarrowed, isTrue);

      viewModel.setFilter(HistoryFilter.abandoned); // same one: nothing to do
      await pumpEventQueue();
      expect(runner.inputs.length, 2);
    });

    // testWidgets for its fake clock: tester.pump(duration) moves time.
    testWidgets('the search waits for a pause in the typing: one run, with the last text', (tester) async {
      seedHistory();
      await viewModel.load();

      viewModel.setQuery('c');
      await tester.pump(const Duration(milliseconds: 100));
      viewModel.setQuery('ca');
      await tester.pump(const Duration(milliseconds: 100));
      viewModel.setQuery('caf');
      await tester.pump(const Duration(milliseconds: 299));
      expect(runner.inputs.length, 1); // only load's

      await tester.pump(const Duration(milliseconds: 1));
      expect(runner.inputs.length, 2);
      expect(runner.inputs.last.query, 'caf');
      expect(viewModel.history.matchCount, 1);
    });

    testWidgets('a filter tap also runs the search still waiting for its pause', (tester) async {
      seedHistory();
      await viewModel.load();

      viewModel.setQuery('mural');
      viewModel.setFilter(HistoryFilter.completed);
      await tester.pump();
      expect(runner.inputs.length, 2);
      expect((runner.inputs.last.filter, runner.inputs.last.query), (HistoryFilter.completed, 'mural'));

      await tester.pump(const Duration(seconds: 1)); // the pending timer was cancelled
      expect(runner.inputs.length, 2);
    });

    test('an older run that answers last is dropped: the newest search wins', () async {
      seedHistory();
      final gated = _GatedRunner();
      final ordered = MissionHistoryViewModel(
        repository,
        'user-1',
        runner: gated.call,
        searchDebounce: Duration.zero,
        isOffline: () async => false,
        offlineChanges: () => const Stream.empty(),
      );
      final loading = ordered.load();
      await pumpEventQueue();
      gated.finish(0);
      await loading;

      ordered.setQuery('cafe');
      await pumpEventQueue();
      ordered.setFilter(HistoryFilter.abandoned); // overtakes the search
      await pumpEventQueue();
      expect(gated.calls.length, 3);

      gated.finish(2);
      await pumpEventQueue();
      expect(ordered.history.matchCount, 0); // abandoned + "cafe"
      expect(ordered.isUpdating, isFalse);

      gated.finish(1); // the stale "cafe" run, all filters
      await pumpEventQueue();
      expect(ordered.history.matchCount, 0);
    });

    test('isUpdating while a run is out, so the view can show it', () async {
      seedHistory();
      final gated = _GatedRunner();
      final slow = build(withRunner: gated.call);
      final loading = slow.load();
      await pumpEventQueue();
      gated.finish(0);
      await loading;

      slow.setFilter(HistoryFilter.completed);
      expect(slow.isUpdating, isTrue);

      gated.finish(1);
      await pumpEventQueue();
      expect(slow.isUpdating, isFalse);
    });

    test('closing the screen mid-run neither notifies nor throws', () async {
      seedHistory();
      final gated = _GatedRunner();
      final closing = build(withRunner: gated.call);
      var notified = 0;
      final loading = closing.load();
      await pumpEventQueue();
      closing.addListener(() => notified++);

      closing.dispose();
      gated.finish(0);
      await loading;

      expect(notified, 0);
    });

    // Not inline on purpose: only a real isolate proves the input and the
    // history can cross to it and back.
    test('the default runner gives the same result through a real isolate', () async {
      seedHistory();
      repository.stepTotals = {'uq-1': 800};
      final background = MissionHistoryViewModel(
        repository,
        'user-1',
        isOffline: () async => false,
        offlineChanges: () => const Stream.empty(),
      );

      await background.load();

      expect(background.status, HistoryStatus.data);
      expect(background.history.totalAttempts, 2);
      final november = background.history.months.first;
      expect((november.year, november.month), (2026, 11));
      expect(november.entries.single.title, 'Café de especialidad');
      expect(november.entries.single.rating, 4);
      expect(november.steps, 800);
    });
  });

  group('caching', () {
    test('a filter already computed comes back from the cache: no new background run', () async {
      seedHistory();
      await viewModel.load(); // computes Todas
      viewModel.setFilter(HistoryFilter.abandoned);
      await pumpEventQueue();
      expect(runner.inputs.length, 2);

      viewModel.setFilter(HistoryFilter.all);
      expect(viewModel.isUpdating, isFalse); // answered on the spot
      expect(viewModel.history.matchCount, 2);
      viewModel.setFilter(HistoryFilter.abandoned);
      expect(viewModel.history.matchCount, 1);

      await pumpEventQueue();
      expect(runner.inputs.length, 2);
    });

    testWidgets('the same search written differently is the same entry', (tester) async {
      seedHistory();
      await viewModel.load();

      viewModel.setQuery('cafe');
      await tester.pump(kHistorySearchDebounce);
      expect(runner.inputs.length, 2);

      viewModel.setQuery('  CAFÉ ');
      await tester.pump(kHistorySearchDebounce);
      expect(runner.inputs.length, 2);
      expect(viewModel.history.matchCount, 1);
    });

    test('a load empties it: a filter seen before is computed again over the new data', () async {
      seedHistory();
      await viewModel.load();
      viewModel.setFilter(HistoryFilter.abandoned);
      await pumpEventQueue();
      expect(viewModel.history.matchCount, 1);

      viewModel.setFilter(HistoryFilter.all);
      repository.userQuests = [
        ...repository.userQuests,
        UserQuest(
          id: 'uq-4',
          userId: 'user-1',
          questId: 'cafe',
          status: 'abandoned',
          acceptedAt: DateTime(2026, 11, 10),
          abandonedAt: DateTime(2026, 11, 11),
        ),
      ];
      await viewModel.load(); // pull to refresh, or the refresh after reconnecting
      viewModel.setFilter(HistoryFilter.abandoned);
      await pumpEventQueue();

      expect(runner.inputs.length, 4);
      expect(runner.inputs.last.userQuests, repository.userQuests);
      expect(viewModel.history.matchCount, 2);
    });

    test('a cached answer is not replaced by an older run that answers later', () async {
      seedHistory();
      final gated = _GatedRunner();
      final vm = build(withRunner: gated.call);
      final loading = vm.load();
      await pumpEventQueue();
      gated.finish(0); // Todas, now cached
      await loading;

      vm.setFilter(HistoryFilter.abandoned); // out in the background
      vm.setFilter(HistoryFilter.all); // from the cache
      expect(vm.history.matchCount, 2);
      expect(vm.isUpdating, isFalse);

      gated.finish(1);
      await pumpEventQueue();
      expect(vm.history.matchCount, 2);
      expect(gated.calls.length, 2);
    });
  });

  group('local storage: when the bitácora was last synced', () {
    test('a fresh read: the moment the server answered', () async {
      seedHistory();

      await viewModel.load();

      expect(viewModel.lastSyncedAt, _serverAnsweredAt);
    });

    test('offline: the date saved on the device by an earlier session', () async {
      seedHistory();
      repository.fromCache = true;
      repository.syncedAt = DateTime(2026, 11, 20, 8, 5);

      await viewModel.load();

      expect(viewModel.lastSyncedAt, DateTime(2026, 11, 20, 8, 5));
    });

    test('never synced on this device: null', () async {
      repository.fromCache = true;

      await viewModel.load();

      expect(viewModel.lastSyncedAt, isNull);
    });
  });

  // testWidgets where time moves: its fake clock runs the reconnect wait.
  group('eventual connectivity', () {
    test('offline from the first reading', () async {
      startsOffline = true;
      final offline = build();
      await pumpEventQueue();

      expect(offline.isOffline, isTrue);
      expect(offline.connectionNotice, HistoryConnectionNotice.offline);
    });

    testWidgets('losing the connection while open: says so, keeps the list, and the filters still work', (
      tester,
    ) async {
      seedHistory();
      final vm = build();
      await vm.load();
      expect(vm.connectionNotice, isNull);

      connectivity.add(true);
      await tester.pump();

      expect(vm.isOffline, isTrue);
      expect(vm.connectionNotice, HistoryConnectionNotice.offline);
      expect(vm.status, HistoryStatus.data);
      expect(repository.reads, 1); // nothing is asked of the server

      vm.setFilter(HistoryFilter.abandoned); // computed on the device
      await tester.pump();
      expect(vm.history.matchCount, 1);
      vm.dispose();
    });

    testWidgets('back online: waits for the connection to hold, then sends what was queued and reloads', (
      tester,
    ) async {
      seedHistory();
      repository.fromCache = true;
      repository.pending = {'uq-2'};
      startsOffline = true;
      final vm = build();
      await tester.pump(); // first connectivity reading
      await vm.load();
      expect(vm.connectionNotice, HistoryConnectionNotice.offline);
      expect(vm.history.pendingSyncCount, 1);

      repository.fromCache = false; // the server answers again
      connectivity.add(false);
      await tester.pump(kHistoryReconnectDelay - const Duration(milliseconds: 1));
      expect(vm.connectionNotice, HistoryConnectionNotice.syncing);
      expect(repository.reads, 1);

      await tester.pump(const Duration(milliseconds: 1));
      await tester.pump();
      expect(repository.reads, 2);
      expect(vm.isFromCache, isFalse);
      expect(vm.connectionNotice, isNull);
      expect(vm.history.pendingSyncCount, 0);
      expect(vm.history.months.expand((m) => m.entries).any((e) => e.isPendingSync), isFalse);
      vm.dispose();
    });

    testWidgets('a connection that drops again before holding never reloads', (tester) async {
      seedHistory();
      startsOffline = true;
      final vm = build();
      await tester.pump();
      await vm.load();

      connectivity.add(false);
      await tester.pump(const Duration(seconds: 1));
      connectivity.add(true);
      await tester.pump(const Duration(seconds: 5));

      expect(repository.reads, 1);
      expect(vm.connectionNotice, HistoryConnectionNotice.offline);
      vm.dispose();
    });

    testWidgets('opened offline with nothing saved: loads on its own when the connection is back', (tester) async {
      repository.fromCache = true; // and nothing in it
      startsOffline = true;
      final vm = build();
      await tester.pump();
      await vm.load();
      expect(vm.status, HistoryStatus.error);
      expect(vm.errorMessage, contains('se cargará sola'));

      seedHistory();
      repository.fromCache = false;
      connectivity.add(false);
      await tester.pump(kHistoryReconnectDelay);
      await tester.pump();

      expect(vm.status, HistoryStatus.data);
      expect(vm.errorMessage, isNull);
      expect(vm.history.totalAttempts, 2);
      vm.dispose();
    });

    testWidgets('a load that started offline is followed by one with the connection', (tester) async {
      seedHistory();
      repository.fromCache = true;
      startsOffline = true;
      final vm = build();
      await tester.pump();
      repository.gate = Completer<void>();
      final first = vm.load(); // still out when the connection comes back

      connectivity.add(false);
      await tester.pump(kHistoryReconnectDelay);
      expect(repository.reads, 1); // waits for it instead of taking its answer

      repository.fromCache = false;
      repository.gate!.complete();
      await first;
      await tester.pump();
      await tester.pump();
      expect(repository.reads, 2);
      expect(vm.isFromCache, isFalse);
      vm.dispose();
    });

    test('Wi-Fi without internet: online, but the server did not answer', () async {
      seedHistory();
      repository.fromCache = true;

      await viewModel.load();

      expect(viewModel.isOffline, isFalse);
      expect(viewModel.connectionNotice, HistoryConnectionNotice.serverUnreachable);
    });

    test('pull to refresh while a load is out shares it: one read', () async {
      seedHistory();
      repository.gate = Completer<void>();

      final first = viewModel.load();
      final second = viewModel.load();
      repository.gate!.complete();
      await Future.wait([first, second]);

      expect(repository.reads, 1);
    });

    testWidgets('closing the screen cancels the wait: nothing loads after it', (tester) async {
      seedHistory();
      startsOffline = true;
      final vm = build();
      await tester.pump();
      await vm.load();

      connectivity.add(false);
      await tester.pump();
      vm.dispose();
      await tester.pump(const Duration(seconds: 5));

      expect(repository.reads, 1);
    });
  });

  group('MissionHistoryView', () {
    Future<void> pumpHistory(WidgetTester tester) async {
      // A small phone, so any overflow fails the test.
      tester.view.physicalSize = const Size(360, 690);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: viewModel,
          child: const MaterialApp(home: MissionHistoryView()),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('data: months with their totals, each attempt and how it ended', (tester) async {
      seedHistory();
      repository.stepTotals = {'uq-1': 1234};

      await pumpHistory(tester);

      expect(find.text('Mi bitácora'), findsOneWidget);
      expect(find.text('2 misiones en tu bitácora'), findsOneWidget);
      expect(find.text('Noviembre 2026'), findsOneWidget);
      expect(find.text('1 completada · 30 min · 1.234 pasos'), findsOneWidget);
      expect(find.text('Café de especialidad'), findsOneWidget);
      expect(find.text('★★★★☆'), findsOneWidget);
      // Read out instead of the stars (merged into the card's own label).
      expect(
        find.byWidgetPredicate((w) => w is Semantics && w.properties.label == 'Calificación: 4 de 5'),
        findsOneWidget,
      );
      expect(find.text('🚶 1.234 pasos'), findsOneWidget);
      expect(find.text('Octubre 2026'), findsOneWidget);
      expect(find.text('Abandonada'), findsOneWidget);
      expect(find.text('📍 Quedaba muy lejos'), findsOneWidget);
    });

    testWidgets('search: the list follows after the pause, and says how many it shows', (tester) async {
      seedHistory();
      await pumpHistory(tester);

      await tester.enterText(find.byType(TextField), 'murales');
      await tester.pump();
      expect(find.text('Café de especialidad'), findsOneWidget); // still typing

      await tester.pump(kHistorySearchDebounce);
      await tester.pump();
      expect(find.text('Café de especialidad'), findsNothing);
      expect(find.text('Murales del centro'), findsOneWidget);
      expect(find.text('Mostrando 1 de 2 misiones'), findsOneWidget);

      await tester.tap(find.byTooltip('Borrar búsqueda'));
      await tester.pump(kHistorySearchDebounce);
      await tester.pump();
      expect(find.text('Café de especialidad'), findsOneWidget);
    });

    testWidgets('filter chips and the no-match message', (tester) async {
      seedHistory();
      await pumpHistory(tester);

      await tester.tap(find.widgetWithText(ChoiceChip, 'Completadas'));
      await tester.pump();
      expect(find.text('Murales del centro'), findsNothing);
      expect(find.text('Café de especialidad'), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'murales');
      await tester.pump(kHistorySearchDebounce);
      await tester.pump();
      expect(find.text('Ninguna misión coincide'), findsOneWidget);
    });

    testWidgets('server unreachable (Wi-Fi without internet): says so and how to retry', (tester) async {
      seedHistory();
      repository.fromCache = true;

      await pumpHistory(tester);

      expect(find.textContaining('No pudimos conectar con el servidor'), findsOneWidget);
      expect(find.textContaining('Sin conexión'), findsNothing);
    });

    testWidgets('the saved copy says when it was last updated; a fresh list has no banner', (tester) async {
      seedHistory();
      repository.fromCache = true;
      repository.syncedAt = DateTime(2026, 11, 20, 8, 5);

      await pumpHistory(tester);
      expect(find.text('Última actualización: Nov 20, 08:05'), findsOneWidget);

      repository.fromCache = false;
      await viewModel.load();
      await tester.pumpAndSettle();
      expect(find.textContaining('Última actualización'), findsNothing);
    });

    testWidgets('offline, then back: the banner and the pending marks follow the connection', (tester) async {
      seedHistory();
      repository.fromCache = true;
      repository.pending = {'uq-2'}; // abandoned offline
      startsOffline = true;
      viewModel = build(); // in this test's zone, for the reconnect timer

      await pumpHistory(tester);
      expect(find.textContaining('Sin conexión: estás viendo tu bitácora guardada'), findsOneWidget);
      expect(find.text('1 misión con cambios por sincronizar.'), findsOneWidget);
      // October's card, below the fold of a small phone. The list, not the
      // search field's own Scrollable.
      final list = find.byType(Scrollable).first;
      await tester.scrollUntilVisible(find.text('Pendiente de sincronizar'), 100, scrollable: list);
      expect(find.text('Pendiente de sincronizar'), findsOneWidget);
      await tester.scrollUntilVisible(find.byType(TextField), -100, scrollable: list); // back to the banner

      repository.fromCache = false;
      connectivity.add(false);
      await tester.pump();
      expect(find.text('Conectado: actualizando tu bitácora…'), findsOneWidget);

      await tester.pump(kHistoryReconnectDelay);
      await tester.pump();
      expect(find.textContaining('Sin conexión'), findsNothing);
      expect(find.text('Conectado: actualizando tu bitácora…'), findsNothing);
      // Its card is built (the title is there), without the mark now.
      await tester.scrollUntilVisible(find.text('Murales del centro'), 100, scrollable: list);
      expect(find.text('Pendiente de sincronizar'), findsNothing);
    });

    testWidgets('empty and error states each show their message and action', (tester) async {
      await pumpHistory(tester);
      expect(find.textContaining('Tu bitácora está vacía'), findsOneWidget);
      expect(find.text('Volver'), findsOneWidget);

      repository.fromCache = true;
      await viewModel.load();
      await tester.pumpAndSettle();
      expect(find.textContaining('Sin conexión y sin datos guardados'), findsOneWidget);
      expect(find.text('Reintentar'), findsOneWidget);
    });
  });
}
