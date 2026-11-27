import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sidequests/analytics/analytics_event_type.dart';
import 'package:sidequests/data/remote/network_guard.dart';
import 'package:sidequests/models/group_challenge.dart';
import 'package:sidequests/repository/group_challenge_repository.dart';
import 'package:sidequests/viewmodel/context/connectivity_view_model.dart';
import 'package:sidequests/viewmodel/social/group_challenges_view_model.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'group_challenge_fakes.dart';

const _unconfirmedText = 'No sabemos si se guardó. Reconecta y reintenta: es seguro.';

void main() {
  late FakeGroupServer server;
  late FakeLocal local;
  late FakeConnectivity connectivity;
  late ConnectivityViewModel connectivityViewModel;
  late FakeAnalyticsSink sink;
  late FakeQuestRepository questRepository;
  late List<String> requestIds;

  setUp(() async {
    server = FakeGroupServer();
    local = FakeLocal();
    connectivity = FakeConnectivity();
    connectivityViewModel = ConnectivityViewModel(connectivity: connectivity);
    sink = FakeAnalyticsSink();
    questRepository = FakeQuestRepository();
    requestIds = [];
    await pumpEventQueue();
  });

  tearDown(() => connectivityViewModel.dispose());

  GroupChallengesViewModel newViewModel() {
    var next = 0;
    final repository = GroupChallengeRepository(
      server,
      local,
      network: NetworkGuard(isOffline: () async => connectivity.isOffline),
    );
    final viewModel = GroupChallengesViewModel(
      repository,
      questRepository,
      realTracker(sink, local, connectivity),
      connectivity: connectivityViewModel,
      catalog: () => catalog,
      newRequestId: () {
        final id = 'request-${++next}';
        requestIds.add(id);
        return id;
      },
      reconnectDelay: Duration.zero,
    );
    addTearDown(viewModel.dispose);
    return viewModel;
  }

  Future<void> setOffline(bool offline) async {
    connectivity.setOffline(offline);
    await pumpEventQueue();
  }

  /// Unconfirmed-request events, wherever they are: sent or queued offline.
  List<Map<String, dynamic>> unconfirmedEvents() => [
    ...sink.inserted,
    ...local.pendingAnalytics,
  ].where((e) => e['event_type'] == AnalyticsEventType.groupChallengeClientUnconfirmed).toList();

  group('requests', () {
    test('create, join and progress each send a new request id with their arguments', () async {
      final joinable = server.seedChallenge('park-picnic', owner: userB);
      final viewModel = newViewModel();
      await viewModel.load();

      await viewModel.createChallenge(groupPhotoWalk);
      expect(viewModel.message, 'Reto creado: ya está en Mis retos.');
      final created = viewModel.mine.single;

      await viewModel.joinChallenge(viewModel.available.single);
      expect(viewModel.message, 'Te uniste al reto.');

      await viewModel.markNextStep(viewModel.mine.firstWhere((c) => c.challengeId == created.challengeId));
      expect(viewModel.message, 'Paso marcado. ¡Sigue así!');

      expect(server.actCalls, [
        {
          'p_action': 'create',
          'p_request_id': 'request-1',
          'p_challenge_id': null,
          'p_quest_id': 'group-photo-walk',
          'p_progress': null,
        },
        {
          'p_action': 'join',
          'p_request_id': 'request-2',
          'p_challenge_id': joinable,
          'p_quest_id': null,
          'p_progress': null,
        },
        {
          'p_action': 'progress',
          'p_request_id': 'request-3',
          'p_challenge_id': created.challengeId,
          'p_quest_id': null,
          'p_progress': 1,
        },
      ]);
      expect(viewModel.mine, hasLength(2));
      expect(viewModel.available, isEmpty);
      expect(viewModel.completedSteps, 1);
      expect(viewModel.joinedCount, 2);
      // Server answers are never tracked by the client.
      expect(sink.inserted, isEmpty);
    });

    test('each answer reloads both lists', () async {
      final viewModel = newViewModel();
      await viewModel.load();
      expect(server.listCalls, hasLength(2));

      await viewModel.createChallenge(groupPhotoWalk);

      expect(server.listCalls, hasLength(4));
      expect(viewModel.mine.single.questId, 'group-photo-walk');
    });

    test('one request at a time: the buttons are off while one is in flight', () async {
      final viewModel = newViewModel();
      await viewModel.load();
      server.actGate = Completer<void>();

      final first = viewModel.createChallenge(groupPhotoWalk);
      await pumpEventQueue();
      expect(viewModel.isSubmitting, isTrue);
      expect(viewModel.canWrite, isFalse);
      await viewModel.createChallenge(parkPicnic);
      server.actGate!.complete();
      await first;

      expect(server.actCalls.map((c) => c['p_quest_id']), ['group-photo-walk']);
      expect(viewModel.canWrite, isTrue);
    });

    test('"Marcar siguiente paso" shows the quest step it marks and stops at the last one', () async {
      final id = server.seedChallenge('group-photo-walk', owner: userA, ownerProgress: 3);
      final viewModel = newViewModel();
      await viewModel.load();
      await pumpEventQueue();

      final challenge = viewModel.mine.single;
      expect(viewModel.nextStepFor(challenge)!.title, 'Foto 3');
      await viewModel.markNextStep(challenge);

      final done = viewModel.mine.single;
      expect(server.progressOf(id, userA), 4);
      expect(done.isCompleted, isTrue);
      expect(viewModel.nextStepFor(done), isNull);
      await viewModel.markNextStep(done);
      expect(server.actCalls, hasLength(1));
    });
  });

  group('BQ2: unknown results', () {
    test('a dropped answer keeps the request pending and tracks it with operation and request id', () async {
      final viewModel = newViewModel();
      await viewModel.load();
      server.actTransport = Transport.dropAfterServer;

      await viewModel.createChallenge(groupPhotoWalk);
      await pumpEventQueue();

      expect(viewModel.pending!.requestId, 'request-1');
      expect(local.pendingGroupAction!['request_id'], 'request-1');
      expect(local.pendingGroupAction!['operation'], 'create');
      expect(viewModel.canWrite, isFalse);
      expect(viewModel.canRetryPending, isTrue);
      final event = unconfirmedEvents().single;
      expect(event['metadata'], {'operation': 'create', 'request_id': 'request-1'});
      expect(event.containsKey('latitude'), isFalse);
      expect(const GroupActionUnconfirmedException().message, _unconfirmedText);
    });

    test('the retry sends exactly the same request id; already applied, it is not applied twice', () async {
      final id = server.seedChallenge('group-photo-walk', owner: userA, ownerProgress: 1);
      final viewModel = newViewModel();
      await viewModel.load();
      server.actTransport = Transport.dropAfterServer;

      await viewModel.markNextStep(viewModel.mine.single);
      expect(server.progressOf(id, userA), 2); // the server did apply it

      server.actTransport = Transport.ok;
      await viewModel.retryPending();

      expect(server.actCalls, hasLength(2));
      expect(server.actCalls.last, server.actCalls.first);
      expect(server.actCalls.last['p_request_id'], 'request-1');
      expect(server.actCalls.last['p_progress'], 2);
      expect(requestIds, ['request-1']); // no new id for the retry
      expect(server.operations, hasLength(1));
      expect(server.progressOf(id, userA), 2);
      expect(viewModel.pending, isNull);
      expect(local.pendingGroupAction, isNull);
      expect(viewModel.message, 'Paso marcado. ¡Sigue así!');
      expect(viewModel.mine.single.myProgress, 2);
      await pumpEventQueue();
      expect(unconfirmedEvents(), hasLength(1));
    });

    test('a retry that never reached the server the first time applies it now, once', () async {
      final viewModel = newViewModel();
      await viewModel.load();
      server.actTransport = Transport.dropBeforeServer;

      await viewModel.createChallenge(groupPhotoWalk);
      expect(server.operations, isEmpty);

      server.actTransport = Transport.ok;
      await viewModel.retryPending();

      expect(server.actCalls.map((c) => c['p_request_id']), ['request-1', 'request-1']);
      expect(server.operations, hasLength(1));
      expect(viewModel.mine.single.questId, 'group-photo-walk');
      expect(viewModel.pending, isNull);
    });

    test('offline, the event waits in the analytics queue', () async {
      final viewModel = newViewModel();
      await viewModel.load();
      sink.offline = true;
      server.actTransport = Transport.dropBeforeServer;

      await viewModel.createChallenge(groupPhotoWalk);
      await pumpEventQueue();

      expect(sink.inserted, isEmpty);
      expect(local.pendingAnalytics.single['event_type'], 'group_challenge_client_unconfirmed');
      expect(local.pendingAnalytics.single['metadata'], {'operation': 'create', 'request_id': 'request-1'});
    });

    test('a refusal (ok false) is an answer: no event, nothing pending, its message in Spanish', () async {
      final viewModel = newViewModel();
      await viewModel.load();
      // Created by someone else and gone before this user joins.
      final ghost = GroupChallenge.fromJson({
        'challenge_id': 'gone',
        'quest_id': 'park-picnic',
        'title': 'Park Picnic',
        'participants': 1,
        'my_progress': null,
        'total_steps': 2,
        'completed_participants': 0,
      });

      await viewModel.joinChallenge(ghost);
      await pumpEventQueue();

      expect(server.operations.values.single['ok'], isFalse);
      expect(viewModel.message, 'Este reto ya no existe o venció.');
      expect(viewModel.pending, isNull);
      expect(unconfirmedEvents(), isEmpty);
      expect(server.listCalls, hasLength(4)); // reloaded after the answer
    });

    test('a PostgREST error is an answer too: no event, nothing pending', () async {
      final viewModel = newViewModel();
      await viewModel.load();
      server.actRejection = const PostgrestException(message: 'boom', code: '500');

      await viewModel.createChallenge(groupPhotoWalk);
      await pumpEventQueue();

      expect(viewModel.message, 'El servidor no pudo completar la solicitud.');
      expect(viewModel.pending, isNull);
      expect(unconfirmedEvents(), isEmpty);
    });

    test('a request that never left the phone is not unconfirmed: no event, nothing pending', () async {
      final viewModel = newViewModel();
      await viewModel.load();
      // The connectivity check right before sending finds no network (the
      // screen hadn't heard about it yet).
      connectivity.current = [ConnectivityResult.none];
      expect(viewModel.canWrite, isTrue);

      await viewModel.createChallenge(groupPhotoWalk);
      await pumpEventQueue();

      expect(server.actCalls, isEmpty);
      expect(viewModel.message, const GroupActionNotSentException().message);
      expect(viewModel.pending, isNull);
      expect(unconfirmedEvents(), isEmpty);
    });

    test('the pending request survives a restart and is retried with its request id', () async {
      final first = newViewModel();
      await first.load();
      server.actTransport = Transport.dropAfterServer;
      await first.createChallenge(groupPhotoWalk);
      server.actTransport = Transport.ok;

      final restarted = newViewModel();
      expect(restarted.pending!.requestId, 'request-1');
      expect(restarted.pending!.operation, GroupAction.create);
      await restarted.load();
      expect(restarted.canWrite, isFalse); // writes wait for the pending one
      await restarted.retryPending();

      expect(server.actCalls.map((c) => c['p_request_id']), ['request-1', 'request-1']);
      expect(restarted.pending, isNull);
      expect(restarted.mine, hasLength(1));
    });
  });

  group('parallel lists', () {
    test('one list failing: the other one still updates and the screen says so', () async {
      server.seedChallenge('group-photo-walk', owner: userA);
      server.seedChallenge('park-picnic', owner: userB);
      local.groupLists[false] = [
        {
          'challenge_id': 'old',
          'quest_id': 'park-picnic',
          'title': 'Saved earlier',
          'participants': 4,
          'my_progress': null,
          'total_steps': 2,
          'completed_participants': 0,
        },
      ];
      server.listError = (mine) => mine ? null : const SocketException('reset');
      final viewModel = newViewModel();

      await viewModel.load();

      expect(viewModel.mine.single.questId, 'group-photo-walk');
      expect(viewModel.available.single.title, 'Saved earlier');
      expect(viewModel.someListsFailed, isTrue);
      expect(viewModel.listsFresh, isFalse);
      expect(viewModel.canWrite, isFalse);

      server.listError = (_) => null;
      await viewModel.refresh();
      expect(viewModel.someListsFailed, isFalse);
      expect(viewModel.available.single.questId, 'park-picnic');
      expect(viewModel.canWrite, isTrue);
    });

    test('both lists are requested before either answers', () async {
      server.listGate = Completer<void>();
      final viewModel = newViewModel();

      final loading = viewModel.load();
      await pumpEventQueue();

      expect(viewModel.isFirstLoad, isTrue);
      expect(server.listCalls, unorderedEquals([true, false]));
      server.listGate!.complete();
      await loading;
      expect(viewModel.isFirstLoad, isFalse);
      expect(viewModel.hasMine && viewModel.hasAvailable, isTrue);
    });
  });

  group('offline and reconnecting', () {
    test('offline: the saved lists show, nothing is requested and every write is off', () async {
      server.seedChallenge('group-photo-walk', owner: userA, ownerProgress: 2);
      server.seedChallenge('park-picnic', owner: userB);
      await newViewModel().load(); // saved in "Hive"
      server.listCalls.clear();
      await setOffline(true);

      final viewModel = newViewModel();
      await viewModel.load();
      await viewModel.createChallenge(parkPicnic);
      await viewModel.joinChallenge(viewModel.available.single);
      await viewModel.markNextStep(viewModel.mine.single);

      expect(viewModel.isOffline, isTrue);
      expect(viewModel.mine.single.myProgress, 2);
      expect(viewModel.available.single.questId, 'park-picnic');
      expect(viewModel.hasSavedLists, isTrue);
      expect(viewModel.canWrite, isFalse);
      expect(viewModel.canRefresh, isFalse);
      expect(server.listCalls, isEmpty);
      expect(server.actCalls, isEmpty);
    });

    test('reconnecting reloads the lists but never resends the pending request', () async {
      final viewModel = newViewModel();
      await viewModel.load();
      server.actTransport = Transport.dropBeforeServer;
      await viewModel.createChallenge(groupPhotoWalk);
      server.actTransport = Transport.ok;
      server.seedChallenge('park-picnic', owner: userB);

      await setOffline(true);
      expect(viewModel.canRetryPending, isFalse);
      final listCallsBefore = server.listCalls.length;
      await setOffline(false);
      await pumpEventQueue();

      expect(server.listCalls.length, listCallsBefore + 2);
      expect(viewModel.available.single.questId, 'park-picnic');
      expect(server.actCalls, hasLength(1)); // only the original try
      expect(viewModel.pending!.requestId, 'request-1');
      expect(viewModel.canRetryPending, isTrue);
    });

    test('going offline mid-screen turns the writes off right away', () async {
      final viewModel = newViewModel();
      await viewModel.load();
      expect(viewModel.canWrite, isTrue);

      await setOffline(true);

      expect(viewModel.canWrite, isFalse);
    });
  });

  group('Crear un reto', () {
    test('lists the group quests of the catalogue the user is not already in', () {
      final mine = [
        GroupChallenge.fromJson({
          'challenge_id': 'c-1',
          'quest_id': 'group-photo-walk',
          'title': 'Group Photo Walk Challenge',
          'participants': 2,
          'my_progress': 0,
          'total_steps': 4,
          'completed_participants': 0,
        }),
      ];

      expect(creatableGroupQuests(catalog, mine).map((q) => q.id), ['park-picnic']);
      expect(creatableGroupQuests(catalog, const []).map((q) => q.id), [
        'group-photo-walk',
        'park-picnic',
      ]);
    });

    test('the ViewModel drops a quest from Create once its challenge is in Mis retos', () async {
      final viewModel = newViewModel();
      await viewModel.load();
      expect(viewModel.creatableQuests.map((q) => q.id), ['group-photo-walk', 'park-picnic']);

      await viewModel.createChallenge(groupPhotoWalk);

      expect(viewModel.creatableQuests.map((q) => q.id), ['park-picnic']);
    });
  });

  test('two accounts: one creates, the other sees it available, joins and both count', () async {
    final creator = newViewModel();
    await creator.load();
    await creator.createChallenge(groupPhotoWalk);

    server.userId = userB;
    local.groupLists.clear(); // the other phone
    final joiner = newViewModel();
    await joiner.load();
    expect(joiner.mine, isEmpty);
    expect(joiner.available.single.participants, 1);
    await joiner.joinChallenge(joiner.available.single);

    expect(joiner.mine.single.participants, 2);
    expect(joiner.available, isEmpty);
  });
}
