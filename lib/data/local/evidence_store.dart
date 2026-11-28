import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:path_provider/path_provider.dart';

/// Disk space all saved evidence may take, photos and thumbnails together.
const kEvidenceStoreBudgetBytes = 50 * 1024 * 1024;

/// Writes [bytes] to [file]. Injectable so a test can make a write fail
/// halfway, as if the app had been killed in the middle of it.
typedef EvidenceFileWriter = Future<void> Function(File file, Uint8List bytes);

Future<void> _writeAndFlush(File file, Uint8List bytes) => file.writeAsBytes(bytes, flush: true);

/// One saved proof, as the index in Hive keeps it.
class EvidenceEntry {
  final String proofId;
  final String attemptId;

  /// Relative to the store's folder (`<attemptId>/<proofId>.jpg`), not
  /// absolute: iOS moves the app's container on updates, which would break
  /// every absolute path saved before.
  final String photoPath;
  final String thumbnailPath;

  /// Photo + thumbnail, what counts against the budget.
  final int bytes;
  final DateTime savedAt;

  /// Last read from disk (the grid or the viewer): eviction goes by this.
  final DateTime lastOpenedAt;

  const EvidenceEntry({
    required this.proofId,
    required this.attemptId,
    required this.photoPath,
    required this.thumbnailPath,
    required this.bytes,
    required this.savedAt,
    required this.lastOpenedAt,
  });

  EvidenceEntry openedAt(DateTime at) => EvidenceEntry(
    proofId: proofId,
    attemptId: attemptId,
    photoPath: photoPath,
    thumbnailPath: thumbnailPath,
    bytes: bytes,
    savedAt: savedAt,
    lastOpenedAt: at,
  );

  Map<String, dynamic> toJson() => {
    'attempt_id': attemptId,
    'photo_path': photoPath,
    'thumbnail_path': thumbnailPath,
    'bytes': bytes,
    'saved_at': savedAt.toUtc().toIso8601String(),
    'last_opened_at': lastOpenedAt.toUtc().toIso8601String(),
  };

  /// Null for a row this version can't read: it's dropped, never a crash.
  static EvidenceEntry? tryParse(String proofId, Object? row) {
    if (row is! Map) return null;
    try {
      return EvidenceEntry(
        proofId: proofId,
        attemptId: row['attempt_id'] as String,
        photoPath: row['photo_path'] as String,
        thumbnailPath: row['thumbnail_path'] as String,
        bytes: (row['bytes'] as num).toInt(),
        savedAt: DateTime.parse(row['saved_at'] as String),
        lastOpenedAt: DateTime.parse(row['last_opened_at'] as String),
      );
    } catch (_) {
      return null;
    }
  }
}

/// Local storage strategy (Alejandro, Sprint 4): the photos of "Evidencias de
/// un intento" are kept on the phone as files, so they can be looked at
/// without internet.
///
/// - What: each photo as a JPEG file in the app's private documents folder,
///   `<documents>/evidence/<attemptId>/<proofId>.jpg`, plus its thumbnail
///   `<proofId>_thumb.jpg`. Files, not Hive or SQLite: a photo is an opaque
///   blob of hundreds of KB that is only ever read whole, which is what a file
///   does best (and Flutter can decode it straight from bytes); a database
///   would just add a copy. Private folder: no storage permission, invisible
///   to the gallery and other apps, and the OS doesn't clear it like a cache.
/// - Index: a Hive box (`evidence_index`), proofId -> relative photo path,
///   thumbnail path, bytes, savedAt, lastOpenedAt. It answers "is it saved?"
///   and "how much space is used?" without touching the files, and is the
///   commit point of a save (below).
/// - Budget: [budgetBytes] (50 MB) in total. A save that doesn't fit first
///   deletes the photos opened longest ago (lastOpenedAt, updated on every
///   read), and never those of the attempt being looked at: the one being
///   saved and any marked with [markAttemptOpen]. If it can't fit even then,
///   nothing is deleted and that photo isn't saved (it's still shown).
/// - Safe writes: each file is written to `<name>.tmp`, flushed, and renamed
///   over its final name (atomic within one filesystem), and the index entry
///   is written only after both files are complete. A save cut short (app
///   killed, disk full) leaves at most a .tmp or a file without an entry, and
///   both are deleted the next time the store opens: a half-written photo can
///   never be read back as a saved one.
/// - Account data: [clear] deletes the folder and the index, called from
///   LocalDataSource.clear() on sign-out. Writes are serialized, so a save
///   that was still running finishes first and is deleted with the rest.
///
/// Opened lazily, on first use, so app startup doesn't pay for it. Not
/// available on the web build (no dart:io files): every read is a miss there
/// and nothing is saved. Kotlin: File(context.filesDir, "evidence/...") with
/// a Room/DataStore index, AtomicFile for the writes.
class EvidenceStore {
  static const _indexBoxName = 'evidence_index';
  static const _folderName = 'evidence';
  static const _tempSuffix = '.tmp';

  /// Ids become folder and file names: only what a UUID can contain, so a
  /// crafted id can never point outside the store's folder.
  static final _safeId = RegExp(r'^[A-Za-z0-9_-]+$');

  final int budgetBytes;
  final Future<Directory> Function() _folder;
  final Future<Box<dynamic>> Function() _openIndex;
  final DateTime Function() _now;
  final EvidenceFileWriter _writeBytes;
  final void Function(String message) _log;
  final bool isSupported;

  Future<({Directory folder, Box<dynamic> index})>? _opening;
  Future<void> _lastWrite = Future.value();
  final _openAttempts = <String>{};

  EvidenceStore({
    this.budgetBytes = kEvidenceStoreBudgetBytes,
    Future<Directory> Function()? folder,
    Future<Box<dynamic>> Function()? openIndex,
    DateTime Function()? now,
    EvidenceFileWriter? writeBytes,
    void Function(String message)? log,
    bool? isSupported,
  }) : _folder = folder ?? _defaultFolder,
       _openIndex = openIndex ?? (() => Hive.openBox<dynamic>(_indexBoxName)),
       _now = now ?? DateTime.now,
       _writeBytes = writeBytes ?? _writeAndFlush,
       _log = log ?? debugPrint,
       isSupported = isSupported ?? !kIsWeb;

  static Future<Directory> _defaultFolder() async {
    final documents = await getApplicationDocumentsDirectory();
    return Directory('${documents.path}/$_folderName');
  }

  /// The attempt on screen: its photos are never evicted to make room until
  /// [markAttemptClosed].
  void markAttemptOpen(String attemptId) => _openAttempts.add(attemptId);

  void markAttemptClosed(String attemptId) => _openAttempts.remove(attemptId);

  /// Which of [proofIds] are saved.
  Future<Set<String>> savedProofIds(Iterable<String> proofIds) async {
    if (!isSupported) return const {};
    final (:folder, :index) = await _ready();
    return {for (final id in proofIds) if (index.containsKey(id)) id};
  }

  Future<bool> isSaved(String proofId) async =>
      (await savedProofIds([proofId])).isNotEmpty;

  /// The saved entry of [proofId], after any write still in progress.
  Future<EvidenceEntry?> entryFor(String proofId) async {
    if (!isSupported) return null;
    await _lastWrite;
    final (:folder, :index) = await _ready();
    return EvidenceEntry.tryParse(proofId, index.get(proofId));
  }

  /// Bytes of every saved photo and thumbnail, after any write in progress.
  Future<int> usedBytes() async {
    if (!isSupported) return 0;
    await _lastWrite;
    final (:folder, :index) = await _ready();
    return _entries(index).fold<int>(0, (sum, entry) => sum + entry.bytes);
  }

  /// The saved thumbnail of [proofId], or null. A read counts as opening it.
  Future<Uint8List?> readThumbnail(String proofId) => _read(proofId, thumbnail: true);

  /// The saved photo of [proofId], or null. A read counts as opening it.
  Future<Uint8List?> readPhoto(String proofId) => _read(proofId, thumbnail: false);

  /// Saves [photo] and [thumbnail] of [proofId] (of [attemptId]) within the
  /// budget. True once both files and the index entry are written; false when
  /// it can't fit without evicting the open attempt, or the write failed —
  /// then nothing of it is left on disk.
  Future<bool> save({
    required String attemptId,
    required String proofId,
    required Uint8List photo,
    required Uint8List thumbnail,
  }) {
    if (!isSupported) return Future.value(false);
    _checkId(attemptId);
    _checkId(proofId);
    return _serially(() async {
      final (:folder, :index) = await _ready();
      final size = photo.lengthInBytes + thumbnail.lengthInBytes;
      final entries = _entries(index);
      final previous = entries.where((entry) => entry.proofId == proofId).firstOrNull;
      final protected = {..._openAttempts, attemptId};
      var used = entries.fold<int>(0, (sum, entry) => sum + entry.bytes) - (previous?.bytes ?? 0);

      // Opened longest ago first; the attempt on screen is never a candidate.
      final candidates =
          entries
              .where((entry) => entry.proofId != proofId && !protected.contains(entry.attemptId))
              .toList()
            ..sort((a, b) => a.lastOpenedAt.compareTo(b.lastOpenedAt));
      final evictable = candidates.fold<int>(0, (sum, entry) => sum + entry.bytes);
      if (used - evictable + size > budgetBytes) {
        _log(
          '[Evidencias] disco: $proofId no cabe en ${_mb(budgetBytes)} sin borrar fotos del intento '
          'abierto (${_mb(used)} usados); no se guarda',
        );
        return false;
      }
      for (final victim in candidates) {
        if (used + size <= budgetBytes) break;
        await _delete(folder, index, victim);
        used -= victim.bytes;
        _log(
          '[Evidencias] disco: expulsada ${victim.proofId} (abierta por última vez '
          '${victim.lastOpenedAt.toIso8601String()}) para liberar ${_mb(victim.bytes)}',
        );
      }

      final photoPath = '$attemptId/$proofId.jpg';
      final thumbnailPath = '$attemptId/${proofId}_thumb.jpg';
      try {
        await Directory('${folder.path}/$attemptId').create(recursive: true);
        await _writeAtomically(_file(folder, photoPath), photo);
        await _writeAtomically(_file(folder, thumbnailPath), thumbnail);
        final now = _now();
        // The commit point: only from here on does the photo count as saved.
        await index.put(
          proofId,
          EvidenceEntry(
            proofId: proofId,
            attemptId: attemptId,
            photoPath: photoPath,
            thumbnailPath: thumbnailPath,
            bytes: size,
            savedAt: previous?.savedAt ?? now,
            lastOpenedAt: now,
          ).toJson(),
        );
      } catch (error) {
        _log('[Evidencias] disco: no se pudo guardar $proofId ($error)');
        if (previous == null) {
          await _deleteQuietly(_file(folder, photoPath));
          await _deleteQuietly(_file(folder, thumbnailPath));
        }
        return false;
      }
      _log('[Evidencias] disco: guardada $proofId (${_mb(used + size)} de ${_mb(budgetBytes)})');
      return true;
    });
  }

  /// Deletes every saved photo and the index: they belong to the account
  /// signing out. Never throws, so it can't keep anyone signed in.
  Future<void> clear() {
    if (!isSupported) return Future.value();
    return _serially(() async {
      try {
        final (:folder, :index) = await _ready();
        // Index first: if the app dies in between, the files left without an
        // entry are deleted when the store opens again.
        await index.clear();
        if (await folder.exists()) await folder.delete(recursive: true);
      } catch (error) {
        _log('[Evidencias] disco: no se pudo borrar ($error)');
      }
      // The folder is gone: the next use creates it again.
      _opening = null;
    });
  }

  Future<Uint8List?> _read(String proofId, {required bool thumbnail}) async {
    if (!isSupported || !_safeId.hasMatch(proofId)) return null;
    final (:folder, :index) = await _ready();
    final entry = EvidenceEntry.tryParse(proofId, index.get(proofId));
    if (entry == null) return null;
    try {
      final bytes = await _file(folder, thumbnail ? entry.thumbnailPath : entry.photoPath).readAsBytes();
      unawaited(_markOpened(index, proofId));
      return bytes;
    } on FileSystemException {
      // Deleted from outside the app (storage cleared from Settings): forget it.
      unawaited(_serially(() => _deleteIfStillThere(folder, index, proofId)));
      return null;
    }
  }

  /// Through the write queue, and only if the entry still exists: an eviction
  /// that ran in between must not be undone by a late "opened" write.
  Future<void> _markOpened(Box<dynamic> index, String proofId) => _serially(() async {
    try {
      final current = EvidenceEntry.tryParse(proofId, index.get(proofId));
      if (current != null) await index.put(proofId, current.openedAt(_now()).toJson());
    } catch (_) {
      // Only the eviction order suffers.
    }
  });

  /// Runs unawaited: it must never throw.
  Future<void> _deleteIfStillThere(Directory folder, Box<dynamic> index, String proofId) async {
    try {
      final entry = EvidenceEntry.tryParse(proofId, index.get(proofId));
      if (entry != null) await _delete(folder, index, entry);
    } catch (_) {
      // Retried by the reconciliation the next time the store opens.
    }
  }

  /// Opens the index and drops what a crash or an outside cleanup left
  /// behind. A failure isn't kept: the next call tries again.
  Future<({Directory folder, Box<dynamic> index})> _ready() async {
    final opening = _opening ??= _openAndReconcile();
    try {
      return await opening;
    } catch (_) {
      if (identical(_opening, opening)) _opening = null;
      rethrow;
    }
  }

  Future<({Directory folder, Box<dynamic> index})> _openAndReconcile() async {
    final index = await _openIndex();
    final folder = await (await _folder()).create(recursive: true);

    final referenced = <String>{};
    for (final key in index.keys.toList()) {
      final entry = key is String ? EvidenceEntry.tryParse(key, index.get(key)) : null;
      final complete =
          entry != null &&
          await _file(folder, entry.photoPath).exists() &&
          await _file(folder, entry.thumbnailPath).exists();
      if (!complete) {
        await index.delete(key);
        continue;
      }
      referenced
        ..add(entry.photoPath)
        ..add(entry.thumbnailPath);
    }

    // A .tmp from a write the app didn't finish, or files written right
    // before the app died, ahead of their index entry: never valid photos.
    var removed = 0;
    await for (final entity in folder.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final relative = _relativePath(folder, entity);
      if (relative.endsWith(_tempSuffix) || !referenced.contains(relative)) {
        await _deleteQuietly(entity);
        removed++;
      }
    }
    if (removed > 0) _log('[Evidencias] disco: $removed archivos incompletos o huérfanos borrados');
    return (folder: folder, index: index);
  }

  Future<void> _writeAtomically(File target, Uint8List bytes) async {
    final temp = File('${target.path}$_tempSuffix');
    try {
      await _writeBytes(temp, bytes);
      await temp.rename(target.path);
    } catch (_) {
      await _deleteQuietly(temp);
      rethrow;
    }
  }

  /// Index entry first, then the files (see [clear] for why that order).
  Future<void> _delete(Directory folder, Box<dynamic> index, EvidenceEntry entry) async {
    await index.delete(entry.proofId);
    await _deleteQuietly(_file(folder, entry.photoPath));
    await _deleteQuietly(_file(folder, entry.thumbnailPath));
    try {
      final attemptFolder = Directory('${folder.path}/${entry.attemptId}');
      if (await attemptFolder.list().isEmpty) await attemptFolder.delete();
    } catch (_) {}
  }

  Future<void> _deleteQuietly(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  /// One write at a time: two saves can't both decide there's room for them,
  /// and [clear] waits for the save in progress.
  Future<T> _serially<T>(Future<T> Function() action) {
    final result = _lastWrite.then((_) => action());
    _lastWrite = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  List<EvidenceEntry> _entries(Box<dynamic> index) => [
    for (final key in index.keys)
      if (key is String) ?EvidenceEntry.tryParse(key, index.get(key)),
  ];

  File _file(Directory folder, String relativePath) => File('${folder.path}/$relativePath');

  String _relativePath(Directory folder, File file) =>
      file.path.substring(folder.path.length + 1).replaceAll(r'\', '/');

  void _checkId(String id) {
    if (!_safeId.hasMatch(id)) throw ArgumentError.value(id, 'id', 'not a safe file name');
  }

  static String _mb(int bytes) => '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
}
