import 'package:flutter/foundation.dart';

import '../../data/offline/offline_pack_entry.dart';
import '../../data/offline/offline_pack_manager.dart';

/// The "Paquete offline" screen's state, from [OfflinePackManager]. Lives for
/// the whole app (app.dart), like the manager: HomeShell restores it when the
/// app opens and retries it on reconnection.
class OfflinePackViewModel extends ChangeNotifier {
  static const saveErrorMessage = 'Could not save the offline pack on the phone.';

  final OfflinePackManager _manager;

  /// The manifest couldn't be written (e.g. no space left); null otherwise.
  String? errorMessage;

  OfflinePackViewModel(this._manager) {
    _manager.entries.addListener(notifyListeners);
  }

  List<OfflinePackEntry> get entries => _manager.entries.value;

  int get readyCount => entries.where((e) => e.status == OfflinePackStatus.ready).length;

  /// Something "Reintentar" can do: pending or failed downloads.
  bool get hasPendingWork => entries.any(
    (e) => e.status == OfflinePackStatus.pendingDownload || e.status == OfflinePackStatus.failed,
  );

  bool contains(String questId) => entries.any((e) => e.questId == questId);

  Future<void> start({required bool isOnline}) => _guard(() => _manager.restore(isOnline: isOnline));

  Future<void> add(String questId, {required bool isOnline}) =>
      _guard(() => _manager.addQuest(questId, isOnline: isOnline));

  Future<void> remove(String questId) => _guard(() => _manager.removeQuest(questId));

  Future<void> retry({required bool isOnline}) => _guard(() => _manager.retryPending(isOnline: isOnline));

  Future<void> _guard(Future<void> Function() action) async {
    if (errorMessage != null) {
      errorMessage = null;
      notifyListeners();
    }
    try {
      await action();
    } catch (_) {
      errorMessage = saveErrorMessage;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _manager.entries.removeListener(notifyListeners);
    super.dispose();
  }
}
