import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/app_exception.dart';
import '../../core/workers/evidence_workers.dart';
import '../../models/photo_proof.dart';
import '../../models/quest_step.dart';
import '../../repository/evidence_repository.dart';
import '../context/connectivity_view_model.dart';

/// The attempt the screen is about, as Mi bitácora knows it.
class EvidenceAttempt {
  final String attemptId;
  final String questId;
  final String questTitle;

  /// When it happened, in local time (Mi bitácora's date of the attempt).
  final DateTime date;

  const EvidenceAttempt({
    required this.attemptId,
    required this.questId,
    required this.questTitle,
    required this.date,
  });
}

enum EvidenceStatus { loading, empty, error, data }

/// Where a photo can be seen from right now.
enum EvidenceAvailability {
  /// Saved on the phone (EvidenceStore): works offline.
  onPhone,

  /// On the server, not saved yet, and there's a connection: it downloads
  /// (and is saved) when shown.
  inCloud,

  /// On the server, not saved, and no connection: shown as such, no spinner.
  availableOnReconnect,

  /// Taken but not uploaded yet; shown from its file on the phone.
  pendingUpload,

  /// The download failed with a connection (server error, timeout): retried
  /// when tapped.
  failed,
}

/// One photo of the attempt: an uploaded proof or one still waiting to be.
class EvidenceItem {
  final String id;
  final int stepOrder;
  final QuestPhotoProof? proof;
  final PendingPhotoProof? pending;
  final DateTime takenAt;

  EvidenceItem.uploaded(QuestPhotoProof this.proof)
    : id = proof.id,
      stepOrder = proof.stepOrder,
      pending = null,
      takenAt = proof.uploadedAt;

  EvidenceItem.pending(PendingPhotoProof this.pending)
    : id = 'pending:${pending.storagePath}',
      stepOrder = pending.stepOrder,
      proof = null,
      takenAt = pending.capturedAt;

  bool get isPending => pending != null;
}

/// The photos of one step, under "Paso N: título del paso".
class EvidenceStepGroup {
  final int stepOrder;
  final String label;
  final List<EvidenceItem> items;

  const EvidenceStepGroup({required this.stepOrder, required this.label, required this.items});
}

/// How long a connection that came back must hold before the screen reloads
/// and downloads what's missing: the same wait as Mi bitácora's.
const kEvidenceReconnectDelay = Duration(seconds: 3);

/// Full photos the viewer keeps in this ViewModel: the one on screen and its
/// neighbours. The rest stay in the repository's byte-bounded cache.
const _viewerPhotosKept = 3;

/// "Evidencias de un intento" (Alejandro, Sprint 4), opened from Mi bitácora:
/// the photos taken in one attempt, grouped by step, with their state and a
/// "Guardar todas en el teléfono". Screen-scoped (AttemptEvidenceView.route):
/// leaving the screen cancels the downloads still waiting for their turn.
///
/// Eventual connectivity (Alejandro, Sprint 4): the screen works with
/// whatever the phone has, says what's missing, and completes itself when the
/// connection comes back — without the user doing anything.
/// - The list of photos is QuestRepository.getPhotoProofs: from the server,
///   or its Hive copy without a connection (every list seen online once is
///   there). Steps come from getSteps, also cached.
/// - The images come from memory or disk (EvidenceStore) offline. A photo
///   that isn't saved shows "Disponible al reconectar" at once: no request is
///   made and there's no spinner waiting on a network that isn't there.
/// - Photos taken but not uploaded yet (PendingPhotoProof of this attempt)
///   are shown from their file on the phone, marked "Pendiente de subir" —
///   even when the list of uploaded ones was never loaded.
/// - Offline, the team's OfflineNotice says so and "Guardar todas" is
///   disabled. Offline and no list saved for this attempt (nor pending
///   photos): a clear message instead of an error, and it loads by itself.
/// - Reconnecting: it follows the app-wide ConnectivityViewModel (the same
///   one every screen uses for its offline state). Once the connection is
///   back and holds for [kEvidenceReconnectDelay] (a flapping one cancels
///   it), the open screen reloads the list and downloads whatever isn't on the
///   phone yet, through the same pool of 3.
/// - Every network call goes through NetworkGuard (5 s timeout); each photo
///   is loaded and saved on its own, so one failure marks only that photo
///   ("Toca para reintentar") and never stops the others.
/// Kotlin: a ConnectivityManager callback as a Flow, collectLatest {
/// delay(3 s); reload() }.
class AttemptEvidenceViewModel extends ChangeNotifier {
  static const _neverLoadedOfflineMessage =
      'Offline: the photos for this attempt had not been loaded on this phone yet. '
      'They will appear automatically when you are back online.';
  static const _serverUnreachableMessage =
      'Could not reach the server to fetch the photos for this attempt. Try again in a moment.';
  static const _loadFailedMessage = 'The photos for this attempt could not be loaded.';
  static const _imageFailedMessage = 'Could not load this photo. Tap to retry.';

  final EvidenceRepository _repository;
  final ConnectivityViewModel? _connectivity;
  final EvidenceAttempt attempt;
  final DownloadPool _pool;
  final Duration _reconnectDelay;
  final void Function(String message) _log;

  /// Starts as loading, so the first frame already shows the spinner.
  EvidenceStatus status = EvidenceStatus.loading;
  String? errorMessage;

  /// The device has no network (ConnectivityViewModel; unknown = online).
  bool isOffline;

  /// A reload is out while photos are on screen (after reconnecting, or a
  /// retry).
  bool isRefreshing = false;

  /// The uploaded photos' list couldn't be read (offline, never loaded on
  /// this phone), but there are pending ones to show.
  bool uploadedListMissing = false;

  List<EvidenceStepGroup> groups = const [];

  /// Every photo, in the order of [groups]: the viewer's pages.
  List<EvidenceItem> items = const [];

  bool isSaving = false;
  int saveDone = 0;
  int saveTotal = 0;
  int saveFailed = 0;

  final _itemsById = <String, EvidenceItem>{};
  final _availability = <String, EvidenceAvailability>{};
  final _errors = <String, String>{};
  final _thumbnails = <String, Uint8List>{};
  final _loadingThumbnails = <String>{};
  final _photos = <String, Uint8List>{};
  final _loadingPhotos = <String>{};

  Future<void>? _loadInFlight;
  Timer? _reconnectTimer;
  bool _disposed = false;

  AttemptEvidenceViewModel(
    this._repository, {
    required this.attempt,
    ConnectivityViewModel? connectivity,
    int downloadConcurrency = kEvidenceMaxConcurrentDownloads,
    Duration? reconnectDelay,
    void Function(String message)? log,
  }) : _connectivity = connectivity,
       _pool = DownloadPool(maxConcurrent: downloadConcurrency, log: log),
       _reconnectDelay = reconnectDelay ?? kEvidenceReconnectDelay,
       _log = log ?? debugPrint,
       isOffline = connectivity?.isOffline ?? false {
    _repository.openAttempt(attempt.attemptId);
    _connectivity?.addListener(_onConnectivityChanged);
  }

  @visibleForTesting
  DownloadPool get downloadPool => _pool;

  EvidenceAvailability availabilityOf(String id) => _availability[id] ?? EvidenceAvailability.inCloud;

  /// Why this photo failed to load, when it did.
  String? errorOf(String id) => _errors[id];

  Uint8List? thumbnailOf(String id) => _thumbnails[id];
  bool isThumbnailLoading(String id) => _loadingThumbnails.contains(id);

  Uint8List? photoOf(String id) => _photos[id];
  bool isPhotoLoading(String id) => _loadingPhotos.contains(id);

  /// False on the web build: there's no disk to save to.
  bool get canSavePhotos => _repository.canSavePhotos;

  int get uploadedCount => items.where((item) => !item.isPending).length;
  int get pendingCount => items.where((item) => item.isPending).length;
  int get savedCount =>
      items.where((item) => !item.isPending && _availability[item.id] == EvidenceAvailability.onPhone).length;

  bool get allSaved => uploadedCount > 0 && savedCount == uploadedCount;

  bool get canSaveAll =>
      canSavePhotos && !isOffline && !isSaving && status == EvidenceStatus.data && savedCount < uploadedCount;

  /// The connection came back and the screen is about to refresh, or is.
  bool get isSyncing => !isOffline && (_reconnectTimer != null || isRefreshing);

  /// "Paso N: título" of the step [item] belongs to.
  String stepLabelOf(EvidenceItem item) =>
      groups.where((group) => group.stepOrder == item.stepOrder).firstOrNull?.label ?? 'Step ${item.stepOrder + 1}';

  /// Calls made while one is out share it.
  Future<void> load() => _loadInFlight ??= _load().whenComplete(() => _loadInFlight = null);

  Future<void> _load() async {
    final hadData = status == EvidenceStatus.data;
    isRefreshing = hadData;
    if (!hadData) {
      status = EvidenceStatus.loading;
      errorMessage = null;
    }
    notifyListeners();

    final pending = _repository.getPendingPhotoProofs(attempt.attemptId);
    final stepsFuture = _stepsOrNull();
    List<QuestPhotoProof>? proofs;
    AppException? listError;
    try {
      proofs = await _repository.getPhotoProofs(attempt.attemptId);
    } on AppException catch (error) {
      listError = error;
    } catch (_) {
      listError = const AppException(_serverUnreachableMessage, isRetryable: true);
    }
    final steps = await stepsFuture;
    final saved = proofs == null ? const <String>{} : await _repository.savedProofIds(proofs);
    final deviceOffline = isOffline || await _repository.isOffline;
    if (_disposed) return;
    isRefreshing = false;

    if (proofs == null && pending.isEmpty) {
      // A refresh that failed leaves what's on screen as it was.
      if (!hadData) {
        status = EvidenceStatus.error;
        errorMessage = deviceOffline
            ? _neverLoadedOfflineMessage
            : (listError?.isRetryable ?? true)
            ? _serverUnreachableMessage
            : _loadFailedMessage;
      }
      notifyListeners();
      return;
    }

    _show(proofs, pending, steps, saved, offline: deviceOffline);
    notifyListeners();
  }

  Future<List<QuestStep>?> _stepsOrNull() async {
    try {
      return await _repository.getSteps(attempt.questId);
    } catch (_) {
      // Offline and never opened: the groups say "Paso N" without a title.
      return null;
    }
  }

  void _show(
    List<QuestPhotoProof>? proofs,
    List<PendingPhotoProof> pending,
    List<QuestStep>? steps,
    Set<String> saved, {
    required bool offline,
  }) {
    final uploaded = proofs ?? const <QuestPhotoProof>[];
    final uploadedPaths = {for (final proof in uploaded) proof.storagePath};
    final all = [
      // Uploaded meanwhile: the registered proof is the one shown.
      for (final photo in pending)
        if (!uploadedPaths.contains(photo.storagePath)) EvidenceItem.pending(photo),
      for (final proof in uploaded) EvidenceItem.uploaded(proof),
    ];

    // Numbered like the Misión tab: by position in the steps, which are in
    // step_order (it may start at 0 or at 1).
    final orderedSteps = steps ?? const <QuestStep>[];
    final positionOf = {for (var i = 0; i < orderedSteps.length; i++) orderedSteps[i].stepOrder: i};
    final titleOf = {for (final step in orderedSteps) step.stepOrder: step.title};
    final byStep = <int, List<EvidenceItem>>{};
    for (final item in all) {
      byStep.putIfAbsent(item.stepOrder, () => []).add(item);
    }
    final stepOrders = byStep.keys.toList()..sort();
    groups = [
      for (final stepOrder in stepOrders)
        EvidenceStepGroup(
          stepOrder: stepOrder,
          label: positionOf[stepOrder] == null
              ? 'Step ${stepOrder + 1}'
              : 'Step ${positionOf[stepOrder]! + 1}: ${titleOf[stepOrder]}',
          items: byStep[stepOrder]!
            // Pending first (the newest), then newest first.
            ..sort((a, b) {
              if (a.isPending != b.isPending) return a.isPending ? -1 : 1;
              return b.takenAt.compareTo(a.takenAt);
            }),
        ),
    ];
    items = [for (final group in groups) ...group.items];

    _itemsById
      ..clear()
      ..addEntries(items.map((item) => MapEntry(item.id, item)));
    _thumbnails.removeWhere((id, _) => !_itemsById.containsKey(id));
    _photos.removeWhere((id, _) => !_itemsById.containsKey(id));
    _errors.clear();
    for (final item in items) {
      _availability[item.id] = item.isPending
          ? EvidenceAvailability.pendingUpload
          : saved.contains(item.id)
          ? EvidenceAvailability.onPhone
          : offline
          ? EvidenceAvailability.availableOnReconnect
          : EvidenceAvailability.inCloud;
    }
    uploadedListMissing = proofs == null;
    status = items.isEmpty ? EvidenceStatus.empty : EvidenceStatus.data;
  }

  /// Asked by each tile when it's built, so only what's on screen downloads.
  /// Idempotent, and never notifies synchronously (safe from build). Doesn't
  /// try what is known to be unavailable offline or failed: that's [retry].
  void ensureThumbnail(String id) {
    final item = _itemsById[id];
    if (_disposed || item == null || _thumbnails.containsKey(id) || _loadingThumbnails.contains(id)) return;
    if (!_worthTrying(id)) return;
    _loadingThumbnails.add(id);
    unawaited(_loadThumbnail(item));
  }

  /// Asked by the viewer's page on screen (and its neighbours).
  void ensurePhoto(String id) {
    final item = _itemsById[id];
    if (_disposed || item == null || _loadingPhotos.contains(id)) return;
    final kept = _photos.remove(id);
    if (kept != null) {
      _photos[id] = kept; // most recently used
      return;
    }
    if (!_worthTrying(id)) return;
    _loadingPhotos.add(id);
    unawaited(_loadPhoto(item));
  }

  /// Tries a failed photo again (or one unavailable, if the connection is
  /// back).
  void retry(String id) {
    final item = _itemsById[id];
    if (_disposed || item == null) return;
    _errors.remove(id);
    if (!item.isPending) {
      _availability[id] = isOffline ? EvidenceAvailability.availableOnReconnect : EvidenceAvailability.inCloud;
    }
    notifyListeners();
    ensureThumbnail(id);
  }

  /// "Guardar todas en el teléfono": every uploaded photo not saved yet,
  /// through the pool (at most 3 at a time), with its progress.
  Future<void> saveAll() => _saveMissing(trigger: 'Guardar todas');

  bool _worthTrying(String id) => switch (availabilityOf(id)) {
    EvidenceAvailability.availableOnReconnect || EvidenceAvailability.failed => false,
    _ => true,
  };

  Future<void> _loadThumbnail(EvidenceItem item) async {
    try {
      final image = item.isPending
          ? await _repository.pendingThumbnail(item.pending!)
          : await _repository.thumbnail(item.proof!, pool: _pool);
      if (_disposed) return;
      _thumbnails[item.id] = image.bytes;
      _markLoaded(item, image);
    } on DownloadCancelledException {
      return;
    } catch (error) {
      _markFailed(item, error);
    } finally {
      _loadingThumbnails.remove(item.id);
      notifyListeners();
    }
  }

  Future<void> _loadPhoto(EvidenceItem item) async {
    try {
      final image = item.isPending
          ? await _repository.pendingPhoto(item.pending!)
          : await _repository.photo(item.proof!, pool: _pool);
      if (_disposed) return;
      _photos[item.id] = image.bytes;
      while (_photos.length > _viewerPhotosKept) {
        _photos.remove(_photos.keys.first);
      }
      _markLoaded(item, image);
    } on DownloadCancelledException {
      return;
    } catch (error) {
      _markFailed(item, error);
    } finally {
      _loadingPhotos.remove(item.id);
      notifyListeners();
    }
  }

  Future<void> _saveMissing({required String trigger}) async {
    if (_disposed || !canSavePhotos || isSaving || isOffline) return;
    final targets = [
      for (final item in items)
        if (!item.isPending && _availability[item.id] != EvidenceAvailability.onPhone) item,
    ];
    if (targets.isEmpty) return;
    isSaving = true;
    saveTotal = targets.length;
    saveDone = 0;
    saveFailed = 0;
    for (final item in targets) {
      _errors.remove(item.id);
      _availability[item.id] = EvidenceAvailability.inCloud;
    }
    notifyListeners();

    final stopwatch = Stopwatch()..start();
    await Future.wait(targets.map(_saveOne));
    if (_disposed) return;
    _log(
      '[Evidencias] $trigger: ${targets.length} fotos en ${stopwatch.elapsedMilliseconds} ms '
      '(concurrencia ${_pool.maxConcurrent}, ${targets.length - saveFailed} guardadas)',
    );
    isSaving = false;
    notifyListeners();
  }

  Future<void> _saveOne(EvidenceItem item) async {
    var counted = true;
    try {
      final image = await _repository.save(item.proof!, pool: _pool);
      if (_disposed) return;
      _thumbnails[item.id] = image.bytes;
      _markLoaded(item, image);
      if (!image.onPhone) saveFailed++;
    } on DownloadCancelledException {
      counted = false;
    } catch (error) {
      _markFailed(item, error);
      saveFailed++;
    } finally {
      if (!_disposed && counted) {
        saveDone++;
        notifyListeners();
      }
    }
  }

  void _markLoaded(EvidenceItem item, EvidenceImage image) {
    if (item.isPending) return;
    _errors.remove(item.id);
    _availability[item.id] = image.onPhone ? EvidenceAvailability.onPhone : EvidenceAvailability.inCloud;
  }

  /// One photo's failure, kept to that photo.
  void _markFailed(EvidenceItem item, Object error) {
    if (_disposed) return;
    final retryable = error is! AppException || error.isRetryable;
    if (error is EvidenceUnavailableException || (retryable && isOffline)) {
      if (!item.isPending) _availability[item.id] = EvidenceAvailability.availableOnReconnect;
      return;
    }
    _availability[item.id] = EvidenceAvailability.failed;
    _errors[item.id] = error is AppException && error.message.isNotEmpty ? error.message : _imageFailedMessage;
  }

  void _onConnectivityChanged() {
    final offline = _connectivity?.isOffline ?? false;
    if (_disposed || offline == isOffline) return;
    isOffline = offline;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    if (offline) {
      // What hadn't started can't now: say so instead of a spinner.
      for (final item in items) {
        final waiting = _availability[item.id] == EvidenceAvailability.inCloud &&
            !_thumbnails.containsKey(item.id) &&
            !_loadingThumbnails.contains(item.id);
        if (waiting) _availability[item.id] = EvidenceAvailability.availableOnReconnect;
      }
    } else {
      // Only if the connection holds: one that drops again cancels this.
      _reconnectTimer = Timer(_reconnectDelay, () {
        _reconnectTimer = null;
        unawaited(_refreshAfterReconnect());
      });
    }
    notifyListeners();
  }

  /// Reloads the list (fresh from the server now) and downloads what's
  /// missing, at most 3 at a time.
  Future<void> _refreshAfterReconnect() async {
    await _loadInFlight;
    if (_disposed || isOffline) return;
    await load();
    if (_disposed || isOffline || status != EvidenceStatus.data) return;
    await _saveMissing(trigger: 'Reconexión');
  }

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _reconnectTimer?.cancel();
    _connectivity?.removeListener(_onConnectivityChanged);
    // Leaving the screen: what's still waiting for its turn never starts.
    _pool.close();
    _repository.closeAttempt(attempt.attemptId);
    super.dispose();
  }
}
