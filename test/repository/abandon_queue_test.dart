import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sidequests/core/app_exception.dart';
import 'package:sidequests/data/local/local_data_source.dart';
import 'package:sidequests/data/remote/supabase_remote_data_source.dart';
import 'package:sidequests/models/pending_write.dart';
import 'package:sidequests/models/user_quest.dart';
import 'package:sidequests/repository/quest_repository.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show PostgrestException;

const _userId = 'user-1';
const _rejected = PostgrestException(message: 'rejected', code: '23514');
const _serverDown = PostgrestException(message: 'down', code: '503');

Map<String, dynamic> _row(String id, {String status = 'in_progress', String questId = 'a'}) => {
  'id': id,
  'user_id': _userId,
  'quest_id': questId,
  'status': status,
  'current_step': 1,
  'completed_steps': [0],
  'accepted_at': '2026-10-01T10:00:00Z',
};

UserQuest _attempt(String id, {String status = 'in_progress'}) =>
    UserQuest.fromJson(_row(id, status: status));

class _FakeRemote implements SupabaseRemoteDataSource {
  bool offline = false;
  Object? Function(Map<String, dynamic> row)? failUpsert;
  PostgrestException? insertError;
  final List<Map<String, dynamic>> serverRows = [];

  /// Every write that arrived, in order.
  final List<({String kind, Map<String, dynamic> row})> writes = [];

  void _failIfDown() {
    if (offline) throw const SocketException('offline');
  }

  void _store(Map<String, dynamic> row) {
    final existing = serverRows.where((r) => r['id'] == row['id']).firstOrNull;
    final merged = {'accepted_at': '2026-10-01T10:00:00Z', ...?existing, ...row};
    serverRows
      ..removeWhere((r) => r['id'] == row['id'])
      ..insert(0, merged);
  }

  @override
  Future<Map<String, dynamic>> upsertUserQuest(Map<String, dynamic> userQuest) async {
    _failIfDown();
    final error = failUpsert?.call(userQuest);
    if (error != null) throw error;
    writes.add((kind: 'upsert', row: userQuest));
    _store(userQuest);
    return serverRows.first;
  }

  @override
  Future<void> insertUserQuestIfAbsent(Map<String, dynamic> userQuest) async {
    _failIfDown();
    if (insertError != null) throw insertError!;
    writes.add((kind: 'insert', row: userQuest));
    _store(userQuest);
  }

  @override
  Future<List<Map<String, dynamic>>> getUserQuests(String userId) async {
    _failIfDown();
    return [...serverRows];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeLocal implements LocalDataSource {
  List<Map<String, dynamic>> userQuests = [];
  List<Map<String, dynamic>> pending = [];
  String? activeQuestId = 'a';
  bool failOnSavingQueue = false;
  final Map<String, List<Map<String, dynamic>>> steps = {
    'a': [
      {'id': 1, 'quest_id': 'a', 'step_order': 0, 'title': 'Paso'},
    ],
  };

  @override
  List<Map<String, dynamic>> getUserQuests() => userQuests;

  @override
  Future<void> cacheUserQuests(List<Map<String, dynamic>> rows) async => userQuests = rows;

  @override
  List<Map<String, dynamic>> getPendingWrites() => pending;

  @override
  Future<void> savePendingWrites(List<Map<String, dynamic>> writes) async {
    if (failOnSavingQueue) throw const FileSystemException('full');
    pending = writes;
  }

  @override
  Future<void> cacheActiveQuestId(String? questId) async => activeQuestId = questId;

  @override
  List<Map<String, dynamic>>? getQuestSteps(String questId) => steps[questId];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late _FakeRemote remote;
  late _FakeLocal local;
  late QuestRepository repository;

  Future<AppException> expectAppException(Future<Object?> future) async {
    try {
      await future;
    } on AppException catch (error) {
      return error;
    }
    fail('Expected an AppException');
  }

  setUp(() {
    remote = _FakeRemote();
    local = _FakeLocal()..userQuests = [_row('uq-1')];
    repository = QuestRepository(remote, local, newId: () => 'uq-new');
  });

  group('abandoning', () {
    test('online: goes straight to the server, nothing queued', () async {
      remote.serverRows.add(_row('uq-1'));

      final result = await repository.abandonQuestOrQueue(_attempt('uq-1'), reason: 'too_far');

      expect(result.queued, isFalse);
      expect(result.userQuest.status, 'abandoned');
      expect(result.userQuest.abandonReason, 'too_far');
      expect(local.pending, isEmpty);
      expect(remote.writes, hasLength(1));
    });

    test('offline: queued with the moment it happened, and closed on the device', () async {
      remote.offline = true;
      final before = DateTime.now().toUtc();

      final result = await repository.abandonQuestOrQueue(_attempt('uq-1'), reason: 'too_far');

      expect(result.queued, isTrue);
      expect(result.userQuest.status, 'abandoned');
      expect(result.userQuest.abandonReason, 'too_far');
      expect(result.userQuest.currentStep, 1); // the rest of the row is kept
      expect(local.activeQuestId, isNull);
      expect(local.userQuests.single['status'], 'abandoned');

      final write = PendingWrite.fromJson(local.pending.single);
      expect(write.type, PendingWrite.abandonQuest);
      expect(write.payload.keys, {
        'id',
        'user_id',
        'quest_id',
        'status',
        'abandon_reason',
        'abandoned_at',
      });
      expect(write.payload['abandon_reason'], 'too_far');
      final abandonedAt = DateTime.parse(write.payload['abandoned_at'] as String);
      expect(abandonedAt.isBefore(before), isFalse);
      expect(abandonedAt.isUtc, isTrue);
    });

    test('a server rejection is not queued: the mission stays active', () async {
      remote.failUpsert = (_) => _rejected;

      final error = await expectAppException(
        repository.abandonQuestOrQueue(_attempt('uq-1'), reason: 'too_far'),
      );

      expect(error.isRetryable, isFalse);
      expect(local.pending, isEmpty);
      expect(local.userQuests.single['status'], 'in_progress');
    });

    test('offline and not on the device: fails instead of faking it', () async {
      remote.offline = true;
      local.userQuests = [];

      final error = await expectAppException(
        repository.abandonQuestOrQueue(_attempt('uq-1'), reason: 'too_far'),
      );

      expect(error.isRetryable, isTrue);
      expect(local.pending, isEmpty);
    });

    test('offline and the queue cannot be saved: the mission stays active', () async {
      remote.offline = true;
      local.failOnSavingQueue = true;

      await expectAppException(repository.abandonQuestOrQueue(_attempt('uq-1'), reason: 'too_far'));

      expect(local.userQuests.single['status'], 'in_progress');
      expect(local.activeQuestId, 'a');
    });
  });

  group('syncing', () {
    Future<void> abandonOffline() async {
      remote.offline = true;
      await repository.abandonQuestOrQueue(_attempt('uq-1'), reason: 'too_far');
      remote.offline = false;
    }

    test('sends the queued abandonment as it was and empties the queue', () async {
      await abandonOffline();
      final payload = PendingWrite.fromJson(local.pending.single).payload;

      await repository.syncPendingWrites();

      expect(remote.writes.single.row, payload);
      expect(local.pending, isEmpty);
    });

    test('a read while it can\'t be sent still shows it abandoned, and keeps it queued', () async {
      await abandonOffline();
      remote.serverRows.add(_row('uq-1'));
      remote.failUpsert = (_) => _serverDown;

      final attempts = await repository.getUserQuests(_userId);

      expect(attempts.single.status, 'abandoned');
      expect(attempts.single.abandonReason, 'too_far');
      expect(attempts.single.abandonedAt, isNotNull);
      expect(local.pending, hasLength(1));
      expect(local.userQuests.single['status'], 'abandoned');
    });

    test('the read after syncing shows the server\'s row', () async {
      await abandonOffline();
      remote.serverRows.add(_row('uq-1'));

      final attempts = await repository.getUserQuests(_userId);

      expect(attempts.single.status, 'abandoned');
      expect(local.pending, isEmpty);
      expect(remote.serverRows.single['abandon_reason'], 'too_far');
    });

    test('a rejected abandonment is discarded: the next read restores the mission', () async {
      await abandonOffline();
      remote.serverRows.add(_row('uq-1'));
      remote.failUpsert = (_) => _rejected;

      final attempts = await repository.getUserQuests(_userId);

      expect(local.pending, isEmpty);
      expect(attempts.single.status, 'in_progress');
    });

    test('a mission started and abandoned offline reaches the server in that order', () async {
      remote.offline = true;
      local.userQuests = [];
      final started = await repository.acceptQuestOrQueue(userId: _userId, questId: 'a');
      await repository.abandonQuestOrQueue(started.userQuest, reason: 'other');
      remote.offline = false;

      await repository.syncPendingWrites();

      expect(remote.writes.map((w) => w.kind), ['insert', 'upsert']);
      expect(remote.serverRows.single['status'], 'abandoned');
      expect(local.pending, isEmpty);
    });

    test('a rejected acceptance takes the abandonment with it, without recreating the row', () async {
      remote.offline = true;
      local.userQuests = [];
      final started = await repository.acceptQuestOrQueue(userId: _userId, questId: 'a');
      await repository.abandonQuestOrQueue(started.userQuest, reason: 'other');
      remote.offline = false;
      remote.insertError = _rejected;

      await repository.syncPendingWrites();

      expect(remote.writes, isEmpty);
      expect(remote.serverRows, isEmpty);
      expect(local.pending, isEmpty);
      expect(local.userQuests, isEmpty);
    });

    test('abandoning a mission whose acceptance is queued, back online: accept goes first', () async {
      remote.offline = true;
      local.userQuests = [];
      final started = await repository.acceptQuestOrQueue(userId: _userId, questId: 'a');
      remote.offline = false;

      final result = await repository.abandonQuestOrQueue(started.userQuest, reason: 'other');

      expect(result.queued, isFalse);
      expect(remote.writes.map((w) => w.kind), ['insert', 'upsert']);
    });
  });

  group('a progress write waits for the queue', () {
    Future<void> abandonOffline() async {
      remote.offline = true;
      await repository.abandonQuestOrQueue(_attempt('uq-1'), reason: 'too_far');
      remote.offline = false;
    }

    test('updateProgress of another mission: the older abandonment goes first', () async {
      await abandonOffline();

      await repository.updateProgress(_attempt('uq-2'));

      expect(remote.writes.map((w) => w.row['id']), ['uq-1', 'uq-2']);
      expect(remote.writes.first.row['status'], 'abandoned');
      expect(local.pending, isEmpty);
    });

    test('completeQuest of another mission: same', () async {
      await abandonOffline();

      await repository.completeQuest(_attempt('uq-2'));

      expect(remote.writes.map((w) => w.row['id']), ['uq-1', 'uq-2']);
    });

    test('the same attempt can\'t move forward while its abandonment is queued', () async {
      await abandonOffline();
      remote.failUpsert = (row) => row['status'] == 'abandoned' ? _serverDown : null;

      final progress = await expectAppException(repository.updateProgress(_attempt('uq-1')));
      final completion = await expectAppException(repository.completeQuest(_attempt('uq-1')));

      expect(progress.isRetryable, isTrue);
      expect(completion.isRetryable, isTrue);
      expect(remote.writes, isEmpty);
      expect(local.userQuests.single['status'], 'abandoned');
      expect(local.pending, hasLength(1));
    });

    test('with an empty queue it writes as always', () async {
      await repository.updateProgress(_attempt('uq-1'));

      expect(remote.writes.single.row['status'], 'in_progress');
    });
  });

  group('with the real Hive', () {
    late Directory documents;
    const pathProvider = MethodChannel('plugins.flutter.io/path_provider');

    setUp(() async {
      TestWidgetsFlutterBinding.ensureInitialized();
      documents = await Directory.systemTemp.createTemp('abandon_queue_test');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        pathProvider,
        (_) async => documents.path,
      );
      SharedPreferences.setMockInitialValues({});
    });

    tearDown(() async {
      await Hive.close();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        pathProvider,
        null,
      );
      await documents.delete(recursive: true);
    });

    test('the queued abandonment survives an app restart and syncs afterwards', () async {
      var hive = LocalDataSource();
      await hive.init();
      await hive.cacheUserQuests([_row('uq-1')]);
      remote.offline = true;
      await QuestRepository(remote, hive).abandonQuestOrQueue(_attempt('uq-1'), reason: 'too_far');

      await Hive.close();
      hive = LocalDataSource();
      await hive.init();
      final restarted = QuestRepository(remote, hive);

      final offline = await restarted.getUserQuests(_userId);
      expect(offline.single.status, 'abandoned');
      expect(offline.single.abandonedAt, isNotNull);
      expect(hive.getPendingWrites(), hasLength(1));

      remote.offline = false;
      await restarted.syncPendingWrites();

      expect(hive.getPendingWrites(), isEmpty);
      expect(remote.writes.single.row['status'], 'abandoned');
      expect(remote.writes.single.row['abandoned_at'], isNotNull);
    });
  });
}
