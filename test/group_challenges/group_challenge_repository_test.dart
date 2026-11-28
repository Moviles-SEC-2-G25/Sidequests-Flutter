import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sidequests/core/app_exception.dart';
import 'package:sidequests/data/local/local_data_source.dart';
import 'package:sidequests/data/remote/network_guard.dart';
import 'package:sidequests/data/remote/supabase_remote_data_source.dart';
import 'package:sidequests/models/group_challenge.dart';
import 'package:sidequests/repository/auth_repository.dart';
import 'package:sidequests/repository/group_challenge_repository.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'group_challenge_fakes.dart';

const _mineRow = {
  'challenge_id': '6f1d0c4e-0000-4000-8000-000000000001',
  'quest_id': 'group-photo-walk',
  'title': 'Group Photo Walk Challenge',
  'participants': 3,
  'my_progress': 2,
  'total_steps': 4,
  'completed_participants': 1,
};

const _availableRow = {
  'challenge_id': '6f1d0c4e-0000-4000-8000-000000000002',
  'quest_id': 'park-picnic',
  'title': 'Park Picnic',
  'participants': 1,
  'my_progress': null,
  'total_steps': 2,
  'completed_participants': 0,
};

const _create = GroupAction(
  operation: GroupAction.create,
  requestId: '10000000-0000-4000-8000-000000000001',
  questId: 'group-photo-walk',
);

void main() {
  group('the real data source and the two RPCs', () {
    late List<http.Request> sent;
    late http.Response Function(http.Request request) answer;
    late SupabaseClient client;
    late SupabaseRemoteDataSource remote;

    setUp(() {
      sent = [];
      answer = (request) => http.Response('[]', 200, request: request);
      client = SupabaseClient(
        'https://example.supabase.co',
        'key',
        httpClient: MockClient((request) async {
          sent.add(request);
          return answer(request);
        }),
      );
      remote = SupabaseRemoteDataSource(client);
    });

    tearDown(() => client.dispose());

    test('group_challenge_list sends p_mine and its rows parse, my_progress null when not a member', () async {
      answer = (request) => http.Response(
        jsonEncode([_mineRow, _availableRow]),
        200,
        request: request,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );

      final rows = await remote.groupChallengeList(mine: true);
      final challenges = rows.map(GroupChallenge.fromJson).toList();

      expect(sent.single.method, 'POST');
      expect(sent.single.url.path, '/rest/v1/rpc/group_challenge_list');
      expect(jsonDecode(sent.single.body), {'p_mine': true});
      expect(challenges.first.challengeId, _mineRow['challenge_id']);
      expect(challenges.first.questId, 'group-photo-walk');
      expect(challenges.first.title, 'Group Photo Walk Challenge');
      expect(challenges.first.participants, 3);
      expect(challenges.first.myProgress, 2);
      expect(challenges.first.totalSteps, 4);
      expect(challenges.first.completedParticipants, 1);
      expect(challenges.first.progressFraction, 0.5);
      expect(challenges.last.myProgress, isNull);
      expect(challenges.last.progress, 0);
      // What Hive keeps reads back the same.
      expect(GroupChallenge.fromJson(challenges.first.toJson()).toJson(), _mineRow);
    });

    test('group_challenge_act sends the request id and only the arguments it has', () async {
      answer = (request) => http.Response(
        jsonEncode({'ok': true, 'message': 'Saved', 'challenge_id': 'c-1'}),
        200,
        request: request,
        headers: {'content-type': 'application/json'},
      );

      final created = GroupActionResult.fromJson(
        await remote.groupChallengeAct(action: 'create', requestId: 'r-1', questId: 'group-photo-walk'),
      );
      await remote.groupChallengeAct(action: 'progress', requestId: 'r-2', challengeId: 'c-1', progress: 3);

      expect(sent.first.url.path, '/rest/v1/rpc/group_challenge_act');
      expect(jsonDecode(sent.first.body), {
        'p_action': 'create',
        'p_request_id': 'r-1',
        'p_quest_id': 'group-photo-walk',
      });
      expect(jsonDecode(sent.last.body), {
        'p_action': 'progress',
        'p_request_id': 'r-2',
        'p_challenge_id': 'c-1',
        'p_progress': 3,
      });
      expect(created.ok, isTrue);
      expect(created.message, 'Saved');
      expect(created.challengeId, 'c-1');
    });

    test('a refusal parses with ok false and no challenge id', () {
      final refused = GroupActionResult.fromJson({
        'ok': false,
        'message': 'Challenge not found or expired.',
        'challenge_id': null,
      });

      expect(refused.ok, isFalse);
      expect(refused.message, 'Challenge not found or expired.');
      expect(refused.challengeId, isNull);
    });

    test('an HTTP error is an answer (AppException); a dropped socket is an unknown result', () async {
      final repository = GroupChallengeRepository(remote, FakeLocal());
      answer = (request) => http.Response(
        jsonEncode({'code': 'PGRST202', 'message': 'Could not find the function'}),
        404,
        request: request,
        headers: {'content-type': 'application/json'},
      );

      await expectLater(
        repository.act(_create),
        throwsA(
          isA<AppException>()
              .having((e) => e, 'type', isNot(isA<GroupActionUnconfirmedException>()))
              .having((e) => e.message, 'message', "The server doesn't support group challenges yet."),
        ),
      );

      answer = (_) => throw const SocketException('connection reset');
      await expectLater(repository.act(_create), throwsA(isA<GroupActionUnconfirmedException>()));
    });
  });

  group('GroupChallengeRepository', () {
    late FakeGroupServer server;
    late FakeLocal local;
    late bool offline;
    late GroupChallengeRepository repository;

    setUp(() {
      server = FakeGroupServer();
      local = FakeLocal();
      offline = false;
      repository = GroupChallengeRepository(
        server,
        local,
        network: NetworkGuard(isOffline: () async => offline),
      );
    });

    test('loads both lists at the same time (Future.wait), not one after the other', () async {
      server.seedChallenge('group-photo-walk', owner: userA);
      server.seedChallenge('park-picnic', owner: userB);
      server.listGate = Completer<void>();

      final loading = repository.loadLists();
      await pumpEventQueue();

      // Both requests are out before either has an answer.
      expect(server.listCalls, unorderedEquals([true, false]));
      server.listGate!.complete();
      final lists = await loading;

      expect(lists.mine.challenges!.single.questId, 'group-photo-walk');
      expect(lists.available.challenges!.single.questId, 'park-picnic');
    });

    test('a failed list does not erase the other one, on screen or in Hive', () async {
      server.seedChallenge('group-photo-walk', owner: userA);
      await repository.loadLists();
      final savedAvailable = local.groupLists[false];
      server.seedChallenge('park-picnic', owner: userA);
      server.listError = (mine) => mine ? null : const SocketException('reset');

      final lists = await repository.loadLists();

      expect(lists.mine.isSuccess, isTrue);
      expect(lists.mine.challenges, hasLength(2));
      expect(lists.available.isSuccess, isFalse);
      expect(lists.available.error!.isRetryable, isTrue);
      expect(local.groupLists[true], hasLength(2));
      expect(local.groupLists[false], same(savedAvailable));
      final saved = repository.savedLists();
      expect(saved.mine, hasLength(2));
      expect(saved.available, isEmpty);
    });

    test('nothing saved yet is null, not an empty list', () {
      final saved = repository.savedLists();
      expect(saved.mine, isNull);
      expect(saved.available, isNull);
    });

    test('no network: the request is not sent (not an unknown result)', () async {
      offline = true;

      await expectLater(repository.act(_create), throwsA(isA<GroupActionNotSentException>()));
      expect(server.actCalls, isEmpty);
    });

    test('a dropped connection, before or after the server applied it, is an unknown result', () async {
      server.actTransport = Transport.dropBeforeServer;
      await expectLater(repository.act(_create), throwsA(isA<GroupActionUnconfirmedException>()));
      expect(server.operations, isEmpty);

      server.actTransport = Transport.dropAfterServer;
      await expectLater(repository.act(_create), throwsA(isA<GroupActionUnconfirmedException>()));
      expect(server.operations, hasLength(1));
    });

    testWidgets('no answer within NetworkGuard.timeout is an unknown result', (tester) async {
      server.actGate = Completer<void>();
      Object? error;
      repository.act(_create).catchError((Object e) {
        error = e;
        return const GroupActionResult(ok: true, message: '');
      });

      await tester.pump(NetworkGuard.timeout - const Duration(milliseconds: 100));
      expect(error, isNull);
      await tester.pump(const Duration(milliseconds: 200));

      expect(error, isA<GroupActionUnconfirmedException>());
      expect(server.actCalls, hasLength(1));
    });

    test('a refusal comes back as a result (ok false), a PostgREST error as AppException', () async {
      final refused = await repository.act(
        const GroupAction(operation: GroupAction.join, requestId: 'r-1', challengeId: 'missing'),
      );
      expect(refused.ok, isFalse);
      expect(refused.message, 'Challenge not found or expired.');

      server.actRejection = const PostgrestException(message: 'JWT expired', code: 'PGRST301');
      await expectLater(
        repository.act(_create),
        throwsA(
          isA<AppException>()
              .having((e) => e, 'type', isNot(isA<GroupActionUnconfirmedException>()))
              .having((e) => e.message, 'message', contains('session')),
        ),
      );
    });

    test('the same request id twice is applied once and answers the same', () async {
      final first = await repository.act(_create);
      final again = await repository.act(_create);

      expect(first.ok, isTrue);
      expect(again.challengeId, first.challengeId);
      expect(server.membersOf(first.challengeId!), 1);
      expect((await repository.loadLists()).mine.challenges, hasLength(1));
    });

    test('the pending request is saved with its request id and read back', () async {
      await repository.savePendingAction(
        const GroupAction(
          operation: GroupAction.progress,
          requestId: 'r-9',
          challengeId: 'c-1',
          progressValue: 3,
          title: 'Group Photo Walk Challenge',
        ),
      );

      final pending = repository.pendingAction()!;
      expect(pending.operation, GroupAction.progress);
      expect(pending.requestId, 'r-9');
      expect(pending.challengeId, 'c-1');
      expect(pending.progressValue, 3);

      await repository.savePendingAction(null);
      expect(repository.pendingAction(), isNull);
    });
  });

  group('real Hive box on disk', () {
    late Directory documents;
    late LocalDataSource hive;
    late FakeGroupServer server;
    late GroupChallengeRepository repository;

    const pathProvider = MethodChannel('plugins.flutter.io/path_provider');

    Future<void> restart() async {
      await Hive.close();
      hive = LocalDataSource();
      await hive.init();
      repository = GroupChallengeRepository(server, hive);
    }

    setUp(() async {
      TestWidgetsFlutterBinding.ensureInitialized();
      documents = await Directory.systemTemp.createTemp('group_challenges_test');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        pathProvider,
        (_) async => documents.path,
      );
      SharedPreferences.setMockInitialValues({});
      server = FakeGroupServer();
      await restart();
    });

    tearDown(() async {
      await Hive.close();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        pathProvider,
        null,
      );
      await documents.delete(recursive: true);
    });

    const pending = GroupAction(
      operation: GroupAction.join,
      requestId: '20000000-0000-4000-8000-000000000002',
      challengeId: 'challenge-9',
      title: 'Park Picnic',
    );

    test('both lists and the pending request survive a restart', () async {
      server.seedChallenge('group-photo-walk', owner: userA, ownerProgress: 1);
      server.seedChallenge('park-picnic', owner: userB);
      await repository.loadLists();
      await repository.savePendingAction(pending);

      await restart();

      final saved = repository.savedLists();
      expect(saved.mine!.single.myProgress, 1);
      expect(saved.available!.single.questId, 'park-picnic');
      expect(repository.pendingAction()!.requestId, pending.requestId);
      expect(repository.pendingAction()!.challengeId, 'challenge-9');
    });

    test('signing out (LocalDataSource.clear) deletes the lists and the pending request', () async {
      server.seedChallenge('group-photo-walk', owner: userA);
      await repository.loadLists();
      await repository.savePendingAction(pending);

      await AuthRepository(server, hive).signOut();

      expect(hive.getGroupChallenges(mine: true), isNull);
      expect(hive.getGroupChallenges(mine: false), isNull);
      expect(hive.getPendingGroupAction(), isNull);
      await restart();
      expect(repository.savedLists().mine, isNull);
      expect(repository.pendingAction(), isNull);
    });
  });
}
