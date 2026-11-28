import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show StorageException;

import '../core/app_exception.dart';
import '../core/workers/evidence_workers.dart';
import '../data/cache/byte_lru_cache.dart';
import '../data/local/evidence_store.dart';
import '../data/local/local_data_source.dart';
import '../data/remote/network_guard.dart';
import '../data/remote/supabase_remote_data_source.dart';
import '../models/photo_proof.dart';
import '../models/quest_step.dart';
import 'quest_repository.dart';

/// The level of the lookup that answered (see ByteLruCache, caching strategy).
enum EvidenceLevel { memory, disk, network }

/// Bytes of a thumbnail or photo, where they came from, and whether the photo
/// is saved on the phone now (it may not be: over the budget, or web build).
class EvidenceImage {
  final Uint8List bytes;
  final EvidenceLevel source;
  final bool onPhone;

  const EvidenceImage(this.bytes, {required this.source, required this.onPhone});
}

/// The photo isn't on the phone and there's no network to get it: it'll be
/// "Disponible al reconectar". Not an error to show.
class EvidenceUnavailableException implements Exception {
  const EvidenceUnavailableException();

  @override
  String toString() => 'EvidenceUnavailableException';
}

/// "Evidencias de un intento" (Alejandro, Sprint 4): the photos of one
/// attempt, wherever they are — memory, the phone, or the private bucket.
///
/// The list of proofs, the pending photos and the steps are QuestRepository's
/// (network-first with the Hive copy as fallback, by Lucas/Julián), reused as
/// they are. What this adds is the images themselves: the three-level lookup
/// (caching strategy, ByteLruCache), saving them on the phone (local storage
/// strategy, EvidenceStore), the bounded downloads and the thumbnails off the
/// UI thread (multithreading strategy, evidence_workers.dart).
///
/// Every network call goes through [NetworkGuard] (no call without network, 5 s
/// timeout). A download that fails throws for that photo only: callers handle
/// each photo on its own, so one failure never breaks the others.
class EvidenceRepository {
  static const _downloadFailedMessage = 'Could not download this photo. Tap to retry.';
  static const _goneMessage = 'This photo is no longer on the server.';
  static const _pendingMissingMessage = 'This photo is no longer on the phone.';

  final QuestRepository _questRepository;
  final SupabaseRemoteDataSource _remoteDataSource;
  final LocalDataSource _localDataSource;
  final EvidenceStore _store;
  final NetworkGuard _network;
  final ByteLruCache<String> _thumbnails;
  final ByteLruCache<String> _photos;
  final ThumbnailMaker _makeThumbnail;
  final void Function(String message) _log;

  /// One download per photo at a time: the grid and "Guardar todas" asking
  /// for the same one share it.
  final _downloads = <String, Future<_Downloaded>>{};

  int _memoryHits = 0;
  int _diskHits = 0;
  int _networkHits = 0;
  int _unavailable = 0;

  EvidenceRepository(
    this._questRepository,
    this._remoteDataSource,
    this._localDataSource, {
    EvidenceStore? store,
    NetworkGuard? network,
    ByteLruCache<String>? thumbnailCache,
    ByteLruCache<String>? photoCache,
    ThumbnailMaker? makeThumbnail,
    void Function(String message)? log,
  }) : _store = store ?? _localDataSource.evidenceStore,
       _network = network ?? const NetworkGuard(),
       _thumbnails = thumbnailCache ?? ByteLruCache(maxBytes: kEvidenceThumbnailCacheBytes),
       _photos = photoCache ?? ByteLruCache(maxBytes: kEvidencePhotoCacheBytes),
       _makeThumbnail = makeThumbnail ?? makeEvidenceThumbnailInBackground,
       _log = log ?? debugPrint;

  /// Lookups answered by each level, and those that found the photo nowhere
  /// while offline.
  int get memoryHits => _memoryHits;
  int get diskHits => _diskHits;
  int get networkHits => _networkHits;
  int get unavailable => _unavailable;

  /// False on the web build: there's no disk to save photos to.
  bool get canSavePhotos => _store.isSupported;

  Future<bool> get isOffline => _network.isOffline;

  // --- The list: QuestRepository's, as is. ---

  /// The attempt's uploaded proofs: server first, the Hive copy without a
  /// connection. Throws AppException only when there's no copy either.
  Future<List<QuestPhotoProof>> getPhotoProofs(String attemptId) =>
      _questRepository.getPhotoProofs(attemptId);

  /// Photos of this attempt taken but not uploaded yet (their files are on the
  /// phone until the upload succeeds).
  List<PendingPhotoProof> getPendingPhotoProofs(String attemptId) => _questRepository
      .getPendingPhotoProofs()
      .where((pending) => pending.attemptId == attemptId)
      .toList();

  /// In step_order; memory, server, then Hive (QuestRepository's cache).
  Future<List<QuestStep>> getSteps(String questId) => _questRepository.getSteps(questId);

  /// Which of [proofs] are saved on the phone. Empty if the store can't open.
  Future<Set<String>> savedProofIds(Iterable<QuestPhotoProof> proofs) async {
    try {
      return await _store.savedProofIds(proofs.map((proof) => proof.id));
    } catch (error) {
      _log('[Evidencias] disco no disponible ($error)');
      return const {};
    }
  }

  /// While an attempt is on screen its saved photos are never evicted.
  void openAttempt(String attemptId) => _store.markAttemptOpen(attemptId);

  void closeAttempt(String attemptId) => _store.markAttemptClosed(attemptId);

  // --- The images: memory -> disk -> network. ---

  /// The thumbnail of [proof]. Throws [EvidenceUnavailableException] when it
  /// isn't saved and there's no network, [AppException] when the download
  /// failed, [DownloadCancelledException] when [pool] closed first.
  Future<EvidenceImage> thumbnail(QuestPhotoProof proof, {required DownloadPool pool}) async {
    final inMemory = _thumbnails.get(proof.id);
    if (inMemory != null) {
      return _found(EvidenceLevel.memory, 'miniatura', proof.id, inMemory, onPhone: await _isSaved(proof.id));
    }
    final onDisk = await _readQuietly(() => _store.readThumbnail(proof.id));
    if (onDisk != null) {
      _thumbnails.put(proof.id, onDisk);
      return _found(EvidenceLevel.disk, 'miniatura', proof.id, onDisk, onPhone: true);
    }
    final downloaded = await _download(proof, pool, 'miniatura');
    return _found(EvidenceLevel.network, 'miniatura', proof.id, downloaded.thumbnail, onPhone: downloaded.saved);
  }

  /// The full photo of [proof], for the viewer. Same levels and errors as
  /// [thumbnail].
  Future<EvidenceImage> photo(QuestPhotoProof proof, {required DownloadPool pool}) async {
    final inMemory = _photos.get(proof.id);
    if (inMemory != null) {
      return _found(EvidenceLevel.memory, 'foto', proof.id, inMemory, onPhone: await _isSaved(proof.id));
    }
    final onDisk = await _readQuietly(() => _store.readPhoto(proof.id));
    if (onDisk != null) {
      _photos.put(proof.id, onDisk);
      return _found(EvidenceLevel.disk, 'foto', proof.id, onDisk, onPhone: true);
    }
    final downloaded = await _download(proof, pool, 'foto');
    return _found(EvidenceLevel.network, 'foto', proof.id, downloaded.photo, onPhone: downloaded.saved);
  }

  /// "Guardar todas": makes sure [proof] is saved on the phone, and returns
  /// its thumbnail. A photo already in memory (seen while it couldn't be
  /// saved) is saved from there, without downloading it again.
  Future<EvidenceImage> save(QuestPhotoProof proof, {required DownloadPool pool}) async {
    if (await _isSaved(proof.id)) return thumbnail(proof, pool: pool);
    final photoInMemory = _photos.get(proof.id);
    final thumbnailInMemory = _thumbnails.get(proof.id);
    if (photoInMemory != null && thumbnailInMemory != null) {
      final saved = await _saveQuietly(proof, photoInMemory, thumbnailInMemory);
      return _found(EvidenceLevel.memory, 'guardar', proof.id, thumbnailInMemory, onPhone: saved);
    }
    final downloaded = await _download(proof, pool, 'guardar');
    return _found(EvidenceLevel.network, 'guardar', proof.id, downloaded.thumbnail, onPhone: downloaded.saved);
  }

  /// Thumbnail of a photo still waiting to be uploaded, from its file on the
  /// phone. Kept in memory only: the file itself is the pending upload's.
  Future<EvidenceImage> pendingThumbnail(PendingPhotoProof pending) async {
    final key = _pendingKey(pending);
    final inMemory = _thumbnails.get(key);
    if (inMemory != null) return _found(EvidenceLevel.memory, 'pendiente', key, inMemory, onPhone: true);
    final bytes = await _readPending(pending);
    final thumbnail = await _thumbnailOf(bytes);
    _thumbnails.put(key, thumbnail);
    return _found(EvidenceLevel.disk, 'pendiente', key, thumbnail, onPhone: true);
  }

  /// The full pending photo, from its file.
  Future<EvidenceImage> pendingPhoto(PendingPhotoProof pending) async {
    final key = _pendingKey(pending);
    final inMemory = _photos.get(key);
    if (inMemory != null) return _found(EvidenceLevel.memory, 'pendiente', key, inMemory, onPhone: true);
    final bytes = await _readPending(pending);
    _photos.put(key, bytes);
    return _found(EvidenceLevel.disk, 'pendiente', key, bytes, onPhone: true);
  }

  Future<_Downloaded> _download(QuestPhotoProof proof, DownloadPool pool, String what) async {
    // Offline: not even a turn in the pool, and no spinner.
    if (await _network.isOffline) {
      _unavailable++;
      _logCounters(what, proof.id, 'no disponible sin conexión');
      throw const EvidenceUnavailableException();
    }
    final shared = _downloads[proof.id];
    if (shared != null) return shared;
    final download = _downloadAndKeep(proof, pool);
    _downloads[proof.id] = download;
    try {
      return await download;
    } finally {
      if (identical(_downloads[proof.id], download)) _downloads.remove(proof.id);
    }
  }

  /// One turn of the pool: download, thumbnail on an isolate, save. All
  /// three inside the turn, so at most [DownloadPool.maxConcurrent] photos are
  /// in memory (and being shrunk) at a time.
  Future<_Downloaded> _downloadAndKeep(QuestPhotoProof proof, DownloadPool pool) => pool.run(() async {
    final Uint8List photo;
    try {
      photo = await _network.run(() => _remoteDataSource.downloadQuestProof(proof.storagePath));
    } on NoNetworkException {
      _unavailable++;
      throw const EvidenceUnavailableException();
    } catch (error) {
      throw _downloadException(error);
    }
    final thumbnail = await _thumbnailOf(photo);
    final saved = await _saveQuietly(proof, photo, thumbnail);
    _photos.put(proof.id, photo);
    _thumbnails.put(proof.id, thumbnail);
    return (photo: photo, thumbnail: thumbnail, saved: saved);
  });

  /// A photo the thumbnailer can't decode is still shown: the photo itself
  /// stands in (the grid decodes it small anyway, with cacheWidth).
  Future<Uint8List> _thumbnailOf(Uint8List photo) async {
    try {
      return await _makeThumbnail(photo);
    } catch (error) {
      _log('[Evidencias] miniatura no generada ($error): se usa la foto');
      return photo;
    }
  }

  Future<bool> _saveQuietly(QuestPhotoProof proof, Uint8List photo, Uint8List thumbnail) async {
    try {
      return await _store.save(
        attemptId: proof.attemptId,
        proofId: proof.id,
        photo: photo,
        thumbnail: thumbnail,
      );
    } catch (error) {
      _log('[Evidencias] disco: no se guardó ${proof.id} ($error)');
      return false;
    }
  }

  Future<bool> _isSaved(String proofId) async {
    try {
      return await _store.isSaved(proofId);
    } catch (_) {
      return false;
    }
  }

  /// A disk that can't be read is a miss, not an error: the network is next.
  Future<Uint8List?> _readQuietly(Future<Uint8List?> Function() read) async {
    try {
      return await read();
    } catch (error) {
      _log('[Evidencias] disco: lectura fallida ($error)');
      return null;
    }
  }

  Future<Uint8List> _readPending(PendingPhotoProof pending) async {
    final bytes = await _localDataSource.readPendingProofFile(pending.localPath);
    if (bytes == null) throw const AppException(_pendingMissingMessage);
    return bytes;
  }

  EvidenceImage _found(EvidenceLevel level, String what, String id, Uint8List bytes, {required bool onPhone}) {
    switch (level) {
      case EvidenceLevel.memory:
        _memoryHits++;
      case EvidenceLevel.disk:
        _diskHits++;
      case EvidenceLevel.network:
        _networkHits++;
    }
    _logCounters(what, id, switch (level) {
      EvidenceLevel.memory => 'memoria',
      EvidenceLevel.disk => 'disco',
      EvidenceLevel.network => 'red',
    });
    return EvidenceImage(bytes, source: level, onPhone: onPhone);
  }

  void _logCounters(String what, String id, String outcome) => _log(
    '[Evidencias] $what ${id.length > 8 ? id.substring(0, 8) : id} <- $outcome | '
    'memoria $_memoryHits · disco $_diskHits · red $_networkHits · no disponibles $_unavailable | '
    'miniaturas en memoria ${(_thumbnails.sizeBytes / 1024).toStringAsFixed(0)} KB',
  );

  /// 400/404: the object is gone (Storage answers 400 "not found" for a
  /// missing object too). Anything else — no answer, timeout, 5xx — is worth
  /// retrying.
  AppException _downloadException(Object error) {
    if (error is AppException) return error;
    if (error is StorageException) {
      final status = int.tryParse(error.statusCode ?? '');
      final notFound = status == 404 || (status == 400 && error.message.toLowerCase().contains('not found'));
      if (notFound) return const AppException(_goneMessage);
    }
    return const AppException(_downloadFailedMessage, isRetryable: true);
  }

  static String _pendingKey(PendingPhotoProof pending) => 'pending:${pending.storagePath}';
}

typedef _Downloaded = ({Uint8List photo, Uint8List thumbnail, bool saved});
