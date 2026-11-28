import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

import '../../models/quest_step.dart';
import '../../repository/quest_repository.dart';
import '../local/offline_pack_manifest_store.dart';
import 'offline_pack_entry.dart';

/// Mirror of Kotlin's OfflinePackManager: the quests the user picked to have
/// offline, and how ready each one is.
///
/// - Local storage: only the ids, in [OfflinePackManifestStore].
/// - Caching: "downloading" a quest is asking [QuestRepository.getSteps] for
///   its steps ahead of time, which keeps them in the existing Hive + memory
///   cache. No other cache, no other copy of the catalogue. A failed download
///   keeps whatever was already saved (getSteps never deletes it).
/// - Concurrency: one lock serializes the manifest operations (Kotlin's
///   Mutex), at most [maxConcurrentDownloads] downloads run at once (its
///   Semaphore(3)), and a quest already downloading is never asked for twice.
///   Everything is async; no isolate: the downloads are I/O, which doesn't
///   hold the UI thread, and the validation is checking a few strings per
///   step (microseconds), cheaper than spawning an isolate and copying the
///   steps to it.
class OfflinePackManager {
  static const maxConcurrentDownloads = 3;
  static const downloadFailedMessage =
      'No se pudo descargar el contenido. Reintenta cuando tengas conexión.';
  static const incompleteMessage = 'La misión no tiene todos sus pasos completos para usarla sin conexión.';

  final QuestRepository _repository;
  final OfflinePackManifestStore _store;
  final _manifestLock = _AsyncLock();
  final _downloadSlots = _AsyncSemaphore(maxConcurrentDownloads);

  /// Downloads running now, by quest id: asking again joins the same one.
  final _inFlight = <String, Future<void>>{};

  final _entries = ValueNotifier<List<OfflinePackEntry>>(const []);

  OfflinePackManager(this._repository, this._store);

  /// The pack, in the order the quests were added (Kotlin's StateFlow).
  ValueListenable<List<OfflinePackEntry>> get entries => _entries;

  /// Opening the app: the manifest back, each quest ready or pending by what
  /// the cache really has, and (online) the pending ones prepared.
  Future<void> restore({required bool isOnline}) async {
    await _manifestLock.run(() async => _show(await _store.read()));
    if (isOnline) await _downloadAll(_unresolved());
  }

  /// Adding twice is the same as once. Offline it stays [OfflinePackStatus.pendingDownload].
  Future<void> addQuest(String questId, {required bool isOnline}) async {
    if (questId.isEmpty) throw ArgumentError.value(questId, 'questId', 'empty');
    await _manifestLock.run(() async {
      final ids = await _store.read();
      final updated = ids.contains(questId) ? ids : [...ids, questId];
      if (!identical(updated, ids)) await _store.write(updated);
      _show(updated);
    });
    if (isOnline && _unresolved().contains(questId)) await _download(questId);
  }

  /// Only the manifest changes: the quest's catalogue entry and steps stay
  /// cached (other screens use them too).
  Future<void> removeQuest(String questId) => _manifestLock.run(() async {
    final updated = [for (final id in await _store.read()) if (id != questId) id];
    await _store.write(updated);
    _show(updated);
  });

  /// The pending and failed ones again: first what the cache already has
  /// (another screen may have saved it), then, online, a download.
  Future<void> retryPending({required bool isOnline}) async {
    final catalogIds = _savedCatalogIds();
    _entries.value = [
      for (final entry in _entries.value)
        if (entry.status != OfflinePackStatus.ready &&
            entry.status != OfflinePackStatus.downloading &&
            _isAvailableOffline(entry.questId, catalogIds))
          OfflinePackEntry(entry.questId, OfflinePackStatus.ready)
        else
          entry,
    ];
    if (isOnline) await _downloadAll(_unresolved());
  }

  /// Sign-out: the next account starts with an empty pack.
  Future<void> clear() => _manifestLock.run(() async {
    await _store.clear();
    _entries.value = const [];
  });

  /// Kotlin's hasCompleteOfflinePayload: there are steps, and every one has
  /// its title and description to follow it without a connection.
  static bool hasCompleteOfflinePayload(List<QuestStep> steps) =>
      steps.isNotEmpty &&
      steps.every((step) => step.title.trim().isNotEmpty && step.description.trim().isNotEmpty);

  /// [ids] on screen: what's already known stays, the rest by the cache.
  void _show(List<String> ids) {
    final known = {for (final entry in _entries.value) entry.questId: entry};
    final catalogIds = _savedCatalogIds();
    _entries.value = [for (final id in ids) known[id] ?? _localEntry(id, catalogIds)];
  }

  OfflinePackEntry _localEntry(String questId, Set<String> catalogIds) => OfflinePackEntry(
    questId,
    _isAvailableOffline(questId, catalogIds) ? OfflinePackStatus.ready : OfflinePackStatus.pendingDownload,
  );

  List<String> _unresolved() => [
    for (final entry in _entries.value)
      if (entry.status == OfflinePackStatus.pendingDownload || entry.status == OfflinePackStatus.failed)
        entry.questId,
  ];

  Future<void> _downloadAll(List<String> questIds) => Future.wait(questIds.map(_download));

  Future<void> _download(String questId) {
    final running = _inFlight[questId];
    if (running != null) {
      // E.g. removed and added again while it downloads: the same request.
      _update(OfflinePackEntry(questId, OfflinePackStatus.downloading));
      return running;
    }
    // A block, not `=> _inFlight.remove(...)`: that returns this same future,
    // and whenComplete would wait for it, i.e. for itself, forever.
    return _inFlight[questId] = _runDownload(questId).whenComplete(() {
      _inFlight.remove(questId);
    });
  }

  Future<void> _runDownload(String questId) async {
    _update(OfflinePackEntry(questId, OfflinePackStatus.downloading));
    final result = await _downloadSlots.withPermit(() async {
      try {
        if (!_savedCatalogIds().contains(questId)) {
          // Saves the catalogue in Hive when the server answers.
          await _repository.getCatalog();
          if (_repository.catalogFromCache) {
            return OfflinePackEntry(questId, OfflinePackStatus.failed, message: downloadFailedMessage);
          }
        }
        // Saves the steps in Hive + memory; a failure keeps what was saved.
        await _repository.getSteps(questId);
      } catch (_) {
        return OfflinePackEntry(questId, OfflinePackStatus.failed, message: downloadFailedMessage);
      }
      // Ready only by what's really saved now, never for being online.
      return _isAvailableOffline(questId, _savedCatalogIds())
          ? OfflinePackEntry(questId, OfflinePackStatus.ready)
          : OfflinePackEntry(questId, OfflinePackStatus.failed, message: incompleteMessage);
    });
    _update(result);
  }

  /// Replaces the entry of the same quest, if it's still in the pack (it may
  /// have been removed while downloading).
  void _update(OfflinePackEntry entry) {
    if (!_entries.value.any((e) => e.questId == entry.questId)) return;
    _entries.value = [
      for (final e in _entries.value) e.questId == entry.questId ? entry : e,
    ];
  }

  Set<String> _savedCatalogIds() => {for (final quest in _repository.getCachedCatalog()) quest.id};

  bool _isAvailableOffline(String questId, Set<String> catalogIds) {
    if (!catalogIds.contains(questId) || !_repository.hasCachedSteps(questId)) return false;
    return hasCompleteOfflinePayload(_repository.getCachedSteps(questId) ?? const []);
  }
}

/// One operation at a time, in order (Kotlin's Mutex.withLock).
class _AsyncLock {
  Future<void> _last = Future.value();

  Future<T> run<T>(Future<T> Function() action) {
    final previous = _last;
    final done = Completer<void>();
    _last = done.future;
    return previous.then((_) => action()).whenComplete(done.complete);
  }
}

/// At most [_permits] actions at once; the rest wait their turn in order
/// (Kotlin's Semaphore.withPermit).
class _AsyncSemaphore {
  final int _permits;
  int _inUse = 0;
  final _waiting = Queue<Completer<void>>();

  _AsyncSemaphore(this._permits);

  Future<T> withPermit<T>(Future<T> Function() action) async {
    if (_inUse < _permits) {
      _inUse++;
    } else {
      final turn = Completer<void>();
      _waiting.add(turn);
      await turn.future; // the permit is handed over, _inUse stays
    }
    try {
      return await action();
    } finally {
      if (_waiting.isNotEmpty) {
        _waiting.removeFirst().complete();
      } else {
        _inUse--;
      }
    }
  }
}
