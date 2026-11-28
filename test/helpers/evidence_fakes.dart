import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:sidequests/core/app_exception.dart';
import 'package:sidequests/data/local/evidence_store.dart';
import 'package:sidequests/data/local/local_data_source.dart';
import 'package:sidequests/data/remote/supabase_remote_data_source.dart';
import 'package:sidequests/models/photo_proof.dart';
import 'package:sidequests/models/quest_step.dart';
import 'package:sidequests/repository/quest_repository.dart';
import 'package:sidequests/viewmodel/context/connectivity_view_model.dart';

/// Shared fakes for "Evidencias de un intento": network (remote), disk
/// (store, pending files) and isolate (thumbnail maker), all injectable.

/// A real JPEG of [width] x [height]: gradients plus some grain, at the
/// quality PhotoCaptureService uses (70), so a 1600 x 1200 one weighs about
/// what a captured photo does (a few hundred KB).
Uint8List testJpeg(int width, int height, {int seed = 1}) {
  final image = img.Image(width: width, height: height);
  final random = math.Random(seed);
  for (final pixel in image) {
    pixel
      ..r = (pixel.x * 255 ~/ width + random.nextInt(16)) % 256
      ..g = (pixel.y * 255 ~/ height + random.nextInt(16)) % 256
      ..b = ((pixel.x + pixel.y) * 128 ~/ (width + height) + 64 + random.nextInt(16)) % 256;
  }
  return img.encodeJpg(image, quality: 70);
}

/// Bytes that pass for a JPEG (FF D8 FF) for tests that never decode them.
Uint8List fakeJpeg(int id, {int size = 64}) =>
    Uint8List.fromList([0xFF, 0xD8, 0xFF, id % 256, ...List.filled(size - 4, id % 256)]);

/// The isolate, replaced: a "thumbnail" is the photo's first 8 bytes. Counts
/// its calls.
class FakeThumbnailMaker {
  int calls = 0;

  Future<Uint8List> call(Uint8List jpeg) async {
    calls++;
    return Uint8List.fromList(jpeg.take(8).toList());
  }
}

QuestPhotoProof proofOf(String id, {String attemptId = 'attempt-1', int stepOrder = 0, DateTime? uploadedAt}) =>
    QuestPhotoProof(
      id: id,
      attemptId: attemptId,
      stepOrder: stepOrder,
      storagePath: 'user-1/$attemptId/quest-1/step-${stepOrder + 1}-$id.jpg',
      uploadedAt: uploadedAt ?? DateTime(2026, 11, 20, 10),
    );

PendingPhotoProof pendingOf(String id, {String attemptId = 'attempt-1', int stepOrder = 0}) => PendingPhotoProof(
  localPath: '/pending/$id.jpg',
  storagePath: 'user-1/$attemptId/quest-1/step-${stepOrder + 1}-$id.jpg',
  attemptId: attemptId,
  questId: 'quest-1',
  stepOrder: stepOrder,
  sizeBytes: 64,
  capturedAt: DateTime(2026, 11, 21, 9),
);

/// The private bucket. Every download can be held ([gates]) or made to fail
/// ([failing]); tracks how many run at once.
class FakeEvidenceRemote implements SupabaseRemoteDataSource {
  final Map<String, Uint8List> objects = {};
  final Map<String, Completer<void>> gates = {};
  final Map<String, Object> failing = {};
  final List<String> downloads = [];
  Duration latency = Duration.zero;

  /// Holds every download until released, when set.
  bool holdAll = false;
  final List<Completer<void>> held = [];

  int active = 0;
  int peak = 0;

  void addProof(QuestPhotoProof proof, Uint8List bytes) => objects[proof.storagePath] = bytes;

  /// Lets every held download finish.
  void releaseAll() {
    for (final completer in held) {
      if (!completer.isCompleted) completer.complete();
    }
    held.clear();
  }

  @override
  Future<Uint8List> downloadQuestProof(String storagePath) async {
    downloads.add(storagePath);
    active++;
    peak = math.max(peak, active);
    try {
      if (holdAll) {
        final completer = Completer<void>();
        held.add(completer);
        await completer.future;
      }
      await gates[storagePath]?.future;
      if (latency > Duration.zero) await Future<void>.delayed(latency);
      final error = failing[storagePath];
      if (error != null) throw error;
      final bytes = objects[storagePath];
      if (bytes == null) throw StateError('no object at $storagePath');
      return bytes;
    } finally {
      active--;
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// QuestRepository's list, pending photos and steps — only what
/// EvidenceRepository reuses. [listOffline]: the server doesn't answer, and
/// [cachedProofs] (the Hive copy) is the fallback; null there = never loaded.
class FakeEvidenceQuestRepository implements QuestRepository {
  final Map<String, List<QuestPhotoProof>> serverProofs = {};
  final Map<String, List<QuestPhotoProof>> cachedProofs = {};
  List<PendingPhotoProof> pending = [];
  List<QuestStep>? steps;
  bool listOffline = false;
  int listReads = 0;

  @override
  Future<List<QuestPhotoProof>> getPhotoProofs(String attemptId) async {
    listReads++;
    if (!listOffline) {
      final rows = serverProofs[attemptId] ?? const [];
      cachedProofs[attemptId] = rows;
      return rows;
    }
    final cached = cachedProofs[attemptId];
    if (cached != null) return cached;
    // What QuestRepository._photoProofException says offline: a message for
    // another screen, which the evidence view must not show.
    throw const AppException('Sin conexión: tu foto quedó guardada en el teléfono.', isRetryable: true);
  }

  @override
  List<PendingPhotoProof> getPendingPhotoProofs() => pending;

  @override
  Future<List<QuestStep>> getSteps(String questId) async {
    final known = steps;
    if (known == null) throw const AppException('Sin conexión y sin datos guardados', isRetryable: true);
    return known;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// The files of the pending photos.
class FakeEvidenceLocal implements LocalDataSource {
  final Map<String, Uint8List> pendingFiles = {};

  @override
  Future<Uint8List?> readPendingProofFile(String path) async => pendingFiles[path];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// EvidenceStore in memory (the fake disk): same contract, no files.
class MemoryEvidenceStore implements EvidenceStore {
  final Map<String, ({String attemptId, Uint8List photo, Uint8List thumbnail})> saved = {};
  final Set<String> openAttempts = {};
  bool refuseSaves = false;
  int saves = 0;

  @override
  bool get isSupported => true;

  @override
  void markAttemptOpen(String attemptId) => openAttempts.add(attemptId);

  @override
  void markAttemptClosed(String attemptId) => openAttempts.remove(attemptId);

  @override
  Future<Set<String>> savedProofIds(Iterable<String> proofIds) async =>
      {for (final id in proofIds) if (saved.containsKey(id)) id};

  @override
  Future<bool> isSaved(String proofId) async => saved.containsKey(proofId);

  @override
  Future<Uint8List?> readThumbnail(String proofId) async => saved[proofId]?.thumbnail;

  @override
  Future<Uint8List?> readPhoto(String proofId) async => saved[proofId]?.photo;

  @override
  Future<bool> save({
    required String attemptId,
    required String proofId,
    required Uint8List photo,
    required Uint8List thumbnail,
  }) async {
    if (refuseSaves) return false;
    saves++;
    saved[proofId] = (attemptId: attemptId, photo: photo, thumbnail: thumbnail);
    return true;
  }

  @override
  Future<void> clear() async => saved.clear();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// The app-wide ConnectivityViewModel, driven by the test.
class FakeConnectivity extends ChangeNotifier implements ConnectivityViewModel {
  @override
  bool isOffline;

  FakeConnectivity({this.isOffline = false});

  void set({required bool offline}) {
    if (offline == isOffline) return;
    isOffline = offline;
    notifyListeners();
  }
}
