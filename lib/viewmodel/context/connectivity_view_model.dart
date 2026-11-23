import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';

/// App-wide "is the device offline", for every screen — including the ones
/// pushed above HomeShell (quest detail, a pushed Misión, preferences) and the
/// login screens, which can't see HomeShell's ContextStatusViewModel. Screens
/// use it to block what needs the internet before the user tries it, and to
/// say why. Unknown connectivity counts as online: requests still have their
/// own timeouts and messages.
class ConnectivityViewModel extends ChangeNotifier {
  final Connectivity _connectivity;
  StreamSubscription<List<ConnectivityResult>>? _subscription;
  bool _disposed = false;

  bool isOffline = false;

  ConnectivityViewModel({Connectivity? connectivity})
    : _connectivity = connectivity ?? Connectivity() {
    _init();
  }

  Future<void> _init() async {
    try {
      // A change heard while the first read is on its way is newer than it.
      var heardChange = false;
      _subscription = _connectivity.onConnectivityChanged.listen((results) {
        heardChange = true;
        _set(results);
      }, onError: (Object _) {});
      final initial = await _connectivity.checkConnectivity();
      if (!heardChange) _set(initial);
    } catch (_) {
      // No connectivity API on this platform: stay "online".
    }
  }

  void _set(List<ConnectivityResult> results) {
    final offline = results.contains(ConnectivityResult.none);
    if (_disposed || offline == isOffline) return;
    isOffline = offline;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _subscription?.cancel();
    super.dispose();
  }
}
