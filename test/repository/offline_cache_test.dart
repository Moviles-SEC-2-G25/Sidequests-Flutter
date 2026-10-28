import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sidequests/core/app_exception.dart';
import 'package:sidequests/data/local/local_data_source.dart';
import 'package:sidequests/data/remote/supabase_remote_data_source.dart';
import 'package:sidequests/models/user_quest.dart';
import 'package:sidequests/repository/profile_repository.dart';
import 'package:sidequests/repository/quest_repository.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Supabase tables in memory. [offline] makes every call fail like a
/// dropped connection; [serverError] like a PostgREST rejection.
class _FakeRemote implements SupabaseRemoteDataSource {
  bool offline = false;
  PostgrestException? serverError;

  Map<String, dynamic> profile = {
    'id': 'user-1',
    'display_name': 'Ana',
    'avatar_url': null,
    'created_at': '2026-01-01T00:00:00Z',
  };
  final Map<String, List<Map<String, dynamic>>> steps = {
    'ramen-spot': [
      {'id': 1, 'quest_id': 'ramen-spot', 'step_order': 0, 'title': 'Llega'},
      {'id': 2, 'quest_id': 'ramen-spot', 'step_order': 1, 'title': 'Pide'},
    ],
    'mural-walk': [
      {'id': 3, 'quest_id': 'mural-walk', 'step_order': 0, 'title': 'Camina'},
    ],
  };
  final Map<String, List<Map<String, dynamic>>> proofs = {
    'attempt-1': [
      {
        'id': 'proof-1',
        'attempt_id': 'attempt-1',
        'step_order': 0,
        'storage_path': 'user-1/attempt-1/ramen-spot/0/a.jpg',
        'uploaded_at': '2026-10-01T12:00:00Z',
      },
    ],
  };
  final List<Map<String, dynamic>> userQuests = [];

  void _failIfDown() {
    if (offline) throw const SocketException('offline');
    if (serverError != null) throw serverError!;
  }

  @override
  Future<Map<String, dynamic>> getProfile(String userId) async {
    _failIfDown();
    return profile;
  }

  @override
  Future<void> upsertProfile(Map<String, dynamic> profile) async {
    _failIfDown();
    this.profile = {...this.profile, ...profile};
  }

  @override
  Future<List<Map<String, dynamic>>> getQuestSteps(String questId) async {
    _failIfDown();
    return steps[questId] ?? [];
  }

  @override
  Future<List<Map<String, dynamic>>> getQuestPhotoProofs(String attemptId) async {
    _failIfDown();
    return proofs[attemptId] ?? [];
  }

  @override
  Future<List<Map<String, dynamic>>> getUserQuests(String userId) async {
    _failIfDown();
    return [...userQuests];
  }

  @override
  Future<Map<String, dynamic>> upsertUserQuest(Map<String, dynamic> userQuest) async {
    _failIfDown();
    final id = userQuest['id'] ?? 'attempt-${userQuests.length + 1}';
    final existing = userQuests.where((row) => row['id'] == id).firstOrNull;
    final row = {
      'accepted_at': '2026-10-01T10:00:00Z',
      ...?existing,
      ...userQuest,
      'id': id,
    };
    userQuests
      ..removeWhere((r) => r['id'] == id)
      ..insert(0, row);
    return row;
  }

  @override
  Future<Map<String, dynamic>> rateUserQuest({
    required String id,
    required String userId,
    required String questId,
    required int rating,
    required List<String> feedbackTags,
  }) => upsertUserQuest({
    'id': id,
    'user_id': userId,
    'quest_id': questId,
    'rating': rating,
    'feedback_tags': feedbackTags,
  });

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// The Hive box, in memory.
class _FakeLocal implements LocalDataSource {
  Map<String, dynamic>? profile;
  final Map<String, List<Map<String, dynamic>>> steps = {};
  final Map<String, List<Map<String, dynamic>>> proofs = {};
  List<Map<String, dynamic>> userQuests = [];

  @override
  Map<String, dynamic>? getProfile() => profile;

  @override
  Future<void> cacheProfile(Map<String, dynamic> profile) async => this.profile = profile;

  @override
  List<Map<String, dynamic>>? getQuestSteps(String questId) => steps[questId];

  @override
  Future<void> cacheQuestSteps(String questId, List<Map<String, dynamic>> steps) async =>
      this.steps[questId] = steps;

  @override
  List<Map<String, dynamic>>? getPhotoProofs(String attemptId) => proofs[attemptId];

  @override
  Future<void> cachePhotoProofs(String attemptId, List<Map<String, dynamic>> proofs) async =>
      this.proofs[attemptId] = proofs;

  @override
  List<Map<String, dynamic>> getUserQuests() => [...userQuests];

  @override
  Future<void> cacheUserQuests(List<Map<String, dynamic>> userQuests) async =>
      this.userQuests = userQuests;

  @override
  Future<void> cacheActiveQuestId(String? questId) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<AppException> _expectAppException(Future<Object?> call) async {
  try {
    await call;
  } on AppException catch (e) {
    return e;
  }
  fail('expected an AppException');
}

void main() {
  late _FakeRemote remote;
  late _FakeLocal local;

  setUp(() {
    remote = _FakeRemote();
    local = _FakeLocal();
  });

  group('ProfileRepository.getProfile (network-first, cache fallback)', () {
    late ProfileRepository repository;

    setUp(() => repository = ProfileRepository(remote, local));

    test('online: returns the remote profile and writes it to the cache', () async {
      final profile = await repository.getProfile('user-1');

      expect(profile.displayName, 'Ana');
      expect(local.profile, remote.profile);
    });

    test('offline after one online load: returns the cached profile', () async {
      await repository.getProfile('user-1');
      remote.offline = true;

      final profile = await repository.getProfile('user-1');

      expect(profile.displayName, 'Ana');
      expect(profile.createdAt, DateTime.utc(2026));
    });

    test('offline with nothing cached: retryable "Sin conexión" error', () async {
      remote.offline = true;

      final error = await _expectAppException(repository.getProfile('user-1'));

      expect(error.isRetryable, isTrue);
      expect(error.message, contains('Sin conexión'));
    });

    test('server rejection with nothing cached: its message, not retryable', () async {
      remote.serverError = const PostgrestException(message: 'permission denied');

      final error = await _expectAppException(repository.getProfile('user-1'));

      expect(error.message, 'permission denied');
      expect(error.isRetryable, isFalse);
    });

    test('updateProfile writes through, keeping the cached created_at', () async {
      await repository.getProfile('user-1');
      final loaded = await repository.getProfile('user-1');

      await repository.updateProfile(loaded.copyWith(displayName: 'Ana M.'));
      remote.offline = true;
      final cached = await repository.getProfile('user-1');

      expect(cached.displayName, 'Ana M.');
      expect(cached.createdAt, DateTime.utc(2026));
    });
  });

  group('QuestRepository reads (network-first, cache fallback)', () {
    late QuestRepository repository;

    setUp(() => repository = QuestRepository(remote, local));

    test('getSteps: offline returns the steps cached for that quest', () async {
      await repository.getSteps('ramen-spot');
      remote.offline = true;

      final steps = await repository.getSteps('ramen-spot');

      expect(steps.map((s) => s.title), ['Llega', 'Pide']);
    });

    test('getSteps: offline, a quest never opened online is a retryable error', () async {
      await repository.getSteps('ramen-spot');
      remote.offline = true;

      final error = await _expectAppException(repository.getSteps('mural-walk'));

      expect(error.isRetryable, isTrue);
      expect(error.message, contains('Sin conexión'));
    });

    test('getSteps: always in step_order, even if the server answers in reverse', () async {
      // postgrest's order() defaults to DESCENDING; current_step is a
      // position in this list, so reversed steps break every mission.
      remote.steps['ramen-spot'] = remote.steps['ramen-spot']!.reversed.toList();

      final steps = await repository.getSteps('ramen-spot');

      expect(steps.map((s) => s.stepOrder), [0, 1]);
    });

    test('getSteps: a cache saved in the old reversed order is sorted too', () async {
      local.steps['ramen-spot'] = remote.steps['ramen-spot']!.reversed.toList();
      remote.offline = true;

      final steps = await repository.getSteps('ramen-spot');

      expect(steps.map((s) => s.title), ['Llega', 'Pide']);
    });

    test('getSteps: a cached empty list is still a cache hit', () async {
      await repository.getSteps('no-steps-quest');
      remote.offline = true;

      expect(await repository.getSteps('no-steps-quest'), isEmpty);
    });

    test('getPhotoProofs: offline returns the cached evidence', () async {
      await repository.getPhotoProofs('attempt-1');
      remote.offline = true;

      final proofs = await repository.getPhotoProofs('attempt-1');

      expect(proofs.single.id, 'proof-1');
    });

    test('getPhotoProofs: offline with nothing cached is a retryable error', () async {
      remote.offline = true;

      final error = await _expectAppException(repository.getPhotoProofs('attempt-1'));

      expect(error.isRetryable, isTrue);
    });
  });

  group('QuestRepository writes (write-through to the attempts cache)', () {
    late QuestRepository repository;

    setUp(() => repository = QuestRepository(remote, local));

    Future<List<UserQuest>> readOffline() async {
      remote.offline = true;
      final (:userQuests, :fromCache) = await repository.getUserQuestsWithSource('user-1');
      expect(fromCache, isTrue);
      return userQuests;
    }

    test('an accepted quest is in the offline fallback, newest first', () async {
      await repository.acceptQuest(userId: 'user-1', questId: 'mural-walk');
      await repository.getUserQuests('user-1'); // caches [mural-walk]

      await repository.acceptQuest(userId: 'user-1', questId: 'ramen-spot');

      final cached = await readOffline();
      expect(cached.map((uq) => uq.questId), ['ramen-spot', 'mural-walk']);
    });

    test('progress, completion and rating replace the cached attempt, never duplicate it', () async {
      final accepted = await repository.acceptQuest(userId: 'user-1', questId: 'ramen-spot');

      final progressed = await repository.updateProgress(
        accepted.copyWithProgress(status: 'in_progress', currentStep: 1, completedSteps: [0]),
      );
      final completed = await repository.completeQuest(progressed);
      await repository.rateQuest(completed, 5, ['divertida']);

      final cached = (await readOffline()).single;
      expect(cached.status, 'completed');
      expect(cached.completedSteps, [0]);
      expect(cached.rating, 5);
    });

    test('an abandoned attempt is cached as abandoned', () async {
      final accepted = await repository.acceptQuest(userId: 'user-1', questId: 'ramen-spot');

      await repository.abandonQuest(accepted, reason: 'lluvia');

      expect((await readOffline()).single.status, 'abandoned');
    });

    test('a write the server rejects leaves the cache untouched', () async {
      final accepted = await repository.acceptQuest(userId: 'user-1', questId: 'ramen-spot');
      remote.serverError = const PostgrestException(message: 'permission denied');

      await _expectAppException(repository.completeQuest(accepted));

      remote.serverError = null;
      expect((await readOffline()).single.status, 'accepted');
    });

    test('offline, every mission write is a retryable AppException, not a raw SocketException',
        () async {
      final accepted = await repository.acceptQuest(userId: 'user-1', questId: 'ramen-spot');
      remote.offline = true;

      final writes = <Future<Object?>>[
        repository.acceptQuest(userId: 'user-1', questId: 'mural-walk'),
        repository.updateProgress(accepted.copyWithProgress(currentStep: 1, completedSteps: [0])),
        repository.abandonQuest(accepted, reason: 'too_far'),
        repository.completeQuest(accepted),
        repository.rateQuest(accepted, 4, const []),
      ];
      for (final write in writes) {
        final error = await _expectAppException(write);
        expect(error.isRetryable, isTrue);
        expect(error.message, startsWith('Sin conexión'));
      }
      expect((await readOffline()).single.status, 'accepted');
    });

    test('a server rejection keeps its message and is not retryable', () async {
      final accepted = await repository.acceptQuest(userId: 'user-1', questId: 'ramen-spot');
      remote.serverError = const PostgrestException(message: 'permission denied');

      final error = await _expectAppException(repository.abandonQuest(accepted, reason: 'too_far'));

      expect(error.message, 'permission denied');
      expect(error.isRetryable, isFalse);
    });
  });
}
