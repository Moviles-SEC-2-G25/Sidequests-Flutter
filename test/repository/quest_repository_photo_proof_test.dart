import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sidequests/core/app_exception.dart';
import 'package:sidequests/data/local/local_data_source.dart';
import 'package:sidequests/data/remote/supabase_remote_data_source.dart';
import 'package:sidequests/models/user_quest.dart';
import 'package:sidequests/repository/quest_repository.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

final _jpeg = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3]);

final _attempt = UserQuest(
  id: 'attempt-1',
  userId: 'user-1',
  questId: 'ramen-spot',
  status: 'in_progress',
  acceptedAt: DateTime(2026, 1, 1),
);

/// Supabase Storage + quest_photo_proofs, in memory. Objects persist
/// across calls, so a second upload of the same path answers 409 exactly
/// like the real bucket with `upsert: false`.
class _FakeRemote implements SupabaseRemoteDataSource {
  final List<String> calls = [];
  final Set<String> objects = {};
  final List<Map<String, dynamic>> rows = [];
  Object? uploadError;
  Object? insertError;
  Object? removeError;

  @override
  Future<void> uploadQuestProof(String storagePath, Uint8List jpeg) async {
    calls.add('upload');
    if (uploadError != null) throw uploadError!;
    if (objects.contains(storagePath)) {
      throw const StorageException('The resource already exists', statusCode: '409', error: 'Duplicate');
    }
    objects.add(storagePath);
  }

  @override
  Future<Map<String, dynamic>> insertQuestPhotoProof({
    required String attemptId,
    required int stepOrder,
    required String storagePath,
  }) async {
    calls.add('insert');
    if (insertError != null) throw insertError!;
    final row = {
      'id': 'proof-${rows.length + 1}',
      'attempt_id': attemptId,
      'step_order': stepOrder,
      'storage_path': storagePath,
      'uploaded_at': '2026-10-01T12:00:00Z',
    };
    rows.add(row);
    return row;
  }

  @override
  Future<void> removeQuestProof(String storagePath) async {
    calls.add('remove');
    if (removeError != null) throw removeError!;
    objects.remove(storagePath);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Hive metadata + the documents folder, in memory.
class _FakeLocal implements LocalDataSource {
  List<Map<String, dynamic>> pending = [];
  final Map<String, Uint8List> files = {};

  @override
  List<Map<String, dynamic>> getPendingPhotoProofs() => [...pending];

  @override
  Future<void> savePendingPhotoProofs(List<Map<String, dynamic>> proofs) async => pending = proofs;

  @override
  Future<String> writePendingProofFile(String fileName, Uint8List bytes) async {
    final path = '/documents/pending_proofs/$fileName';
    files[path] = bytes;
    return path;
  }

  @override
  Future<Uint8List?> readPendingProofFile(String path) async => files[path];

  @override
  Future<void> deletePendingProofFile(String path) async => files.remove(path);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late _FakeRemote remote;
  late _FakeLocal local;
  late QuestRepository repository;
  late int nextId;

  setUp(() {
    remote = _FakeRemote();
    local = _FakeLocal();
    nextId = 0;
    repository = QuestRepository(remote, local, newId: () => 'uuid-${++nextId}');
  });

  Future<AppException> uploadExpectingFailure() async {
    try {
      await repository.uploadPendingPhotoProof(repository.getPendingPhotoProofs().single);
    } on AppException catch (e) {
      return e;
    }
    fail('expected an AppException');
  }

  group('savePendingPhotoProof (kept on the device before any network call)', () {
    test('writes the file and the metadata with the contract path', () async {
      final pending = await repository.savePendingPhotoProof(attempt: _attempt, stepOrder: 0, jpeg: _jpeg);

      expect(pending.storagePath, 'user-1/attempt-1/ramen-spot/step-1-uuid-1.jpg');
      expect(local.files[pending.localPath], _jpeg);
      expect(repository.getPendingPhotoProofs().single.storagePath, pending.storagePath);
      expect(remote.calls, isEmpty);
    });

    test('rejects bytes that are not JPEG, storing nothing', () async {
      await expectLater(
        repository.savePendingPhotoProof(
          attempt: _attempt,
          stepOrder: 0,
          jpeg: Uint8List.fromList([0x89, 0x50, 0x4E, 0x47]),
        ),
        throwsA(isA<AppException>().having((e) => e.isRetryable, 'retryable', isFalse)),
      );
      expect(local.files, isEmpty);
    });

    test('a new photo for the same step replaces the previous pending one', () async {
      final first = await repository.savePendingPhotoProof(attempt: _attempt, stepOrder: 0, jpeg: _jpeg);
      final second = await repository.savePendingPhotoProof(attempt: _attempt, stepOrder: 0, jpeg: _jpeg);

      expect(repository.getPendingPhotoProofs().single.storagePath, second.storagePath);
      expect(local.files.containsKey(first.localPath), isFalse);
    });
  });

  group('uploadPendingPhotoProof', () {
    test('upload, then insert (zero-based step_order); only then the local copy is removed', () async {
      final pending = await repository.savePendingPhotoProof(attempt: _attempt, stepOrder: 0, jpeg: _jpeg);

      final proof = await repository.uploadPendingPhotoProof(pending);

      expect(remote.calls, ['upload', 'insert']);
      expect(remote.rows.single['step_order'], 0);
      expect(remote.rows.single['storage_path'], pending.storagePath);
      expect(proof.attemptId, 'attempt-1');
      expect(repository.getPendingPhotoProofs(), isEmpty);
      expect(local.files, isEmpty);
    });

    test('no connection: retryable, the photo is kept with the error and attempt count', () async {
      await repository.savePendingPhotoProof(attempt: _attempt, stepOrder: 0, jpeg: _jpeg);
      // storage_client wraps network failures with the error type as statusCode.
      remote.uploadError = const StorageException('Connection failed', statusCode: 'ClientException');

      final error = await uploadExpectingFailure();

      expect(error.isRetryable, isTrue);
      expect(error.message, contains('Sin conexión'));
      final kept = repository.getPendingPhotoProofs().single;
      expect(kept.attempts, 1);
      expect(kept.lastError, error.message);
      expect(remote.calls, ['upload']); // never inserted
    });

    test('a server error (5xx) is retryable too', () async {
      await repository.savePendingPhotoProof(attempt: _attempt, stepOrder: 0, jpeg: _jpeg);
      remote.uploadError = const StorageException('Internal', statusCode: '500');

      expect((await uploadExpectingFailure()).isRetryable, isTrue);
      expect(repository.getPendingPhotoProofs(), hasLength(1));
    });

    test('rejected by RLS when inserting: the upload is removed and the photo discarded', () async {
      await repository.savePendingPhotoProof(attempt: _attempt, stepOrder: 0, jpeg: _jpeg);
      remote.insertError = const PostgrestException(message: 'new row violates row-level security', code: '42501');

      final error = await uploadExpectingFailure();

      expect(error.isRetryable, isFalse);
      expect(remote.calls, ['upload', 'insert', 'remove']);
      expect(remote.objects, isEmpty); // no orphan in the bucket
      expect(repository.getPendingPhotoProofs(), isEmpty);
    });

    test('a too-large file (413) is not retried', () async {
      await repository.savePendingPhotoProof(attempt: _attempt, stepOrder: 0, jpeg: _jpeg);
      remote.uploadError = const StorageException('Payload too large', statusCode: '413');

      expect((await uploadExpectingFailure()).isRetryable, isFalse);
      expect(repository.getPendingPhotoProofs(), isEmpty);
    });

    test('upload landed but the insert and the cleanup failed offline: the retry finishes it (409 → insert)', () async {
      await repository.savePendingPhotoProof(attempt: _attempt, stepOrder: 0, jpeg: _jpeg);
      remote.insertError = const SocketException('offline');
      remote.removeError = const SocketException('offline');

      final error = await uploadExpectingFailure();
      expect(error.isRetryable, isTrue);
      expect(remote.objects, hasLength(1)); // the object is still there

      remote.insertError = null;
      remote.removeError = null;
      final proof = await repository.uploadPendingPhotoProof(repository.getPendingPhotoProofs().single);

      expect(proof.storagePath, remote.objects.single); // same path, reused
      expect(remote.rows, hasLength(1));
      expect(repository.getPendingPhotoProofs(), isEmpty);
    });

    test('the saved file is gone: discarded, asks for a new photo', () async {
      final pending = await repository.savePendingPhotoProof(attempt: _attempt, stepOrder: 0, jpeg: _jpeg);
      local.files.clear();

      await expectLater(repository.uploadPendingPhotoProof(pending), throwsA(isA<AppException>()));
      expect(repository.getPendingPhotoProofs(), isEmpty);
      expect(remote.calls, isEmpty);
    });
  });
}
