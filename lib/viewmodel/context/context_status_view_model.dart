import 'dart:async';

import 'package:battery_plus/battery_plus.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';

/// Live device context (connectivity + battery) the UI adapts to: an offline
/// or low-battery banner. Sensor failures are swallowed — a missing API must
/// never break the app shell.
class ContextStatusViewModel extends ChangeNotifier {
  static const _lowBatteryThreshold = 20;

  final Connectivity _connectivity = Connectivity();
  final Battery _battery = Battery();
  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;
  StreamSubscription<BatteryState>? _batterySub;

  bool isOffline = false;
  bool isLowBattery = false;

  ContextStatusViewModel() {
    _init();
  }

  Future<void> _init() async {
    try {
      _setOffline(await _connectivity.checkConnectivity());
      _connectivitySub = _connectivity.onConnectivityChanged.listen(
        _setOffline,
      );
    } catch (_) {}
    try {
      await _refreshBattery();
      _batterySub = _battery.onBatteryStateChanged.listen(
        (_) => _refreshBattery(),
      );
    } catch (_) {}
  }

  void _setOffline(List<ConnectivityResult> results) {
    final offline = results.contains(ConnectivityResult.none);
    if (offline == isOffline) return;
    isOffline = offline;
    notifyListeners();
  }

  Future<void> _refreshBattery() async {
    try {
      final low = await _battery.batteryLevel <= _lowBatteryThreshold;
      if (low == isLowBattery) return;
      isLowBattery = low;
      notifyListeners();
    } catch (_) {}
  }

  @override
  void dispose() {
    _connectivitySub?.cancel();
    _batterySub?.cancel();
    super.dispose();
  }
}
