import 'dart:async';

import 'package:battery_plus/battery_plus.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';

/// Live device context (connectivity + battery) the UI adapts to: an offline
/// or low-battery banner. Sensor failures are swallowed — a missing API must
/// never break the app shell.
///
/// Coming back online is announced right away ([justReconnected]); if the
/// connection still holds after the reconnect delay — a flapping one never
/// gets that far — `onReconnected` runs once, so the app can reload what
/// couldn't load offline.
class ContextStatusViewModel extends ChangeNotifier {
  static const _lowBatteryThreshold = 20;

  final Connectivity _connectivity;
  final Battery _battery;
  final VoidCallback? _onReconnected;
  final Duration _reconnectDelay;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;
  StreamSubscription<BatteryState>? _batterySub;
  Timer? _reconnectTimer;

  bool isOffline = false;
  bool isLowBattery = false;

  /// Back online, waiting out the reconnect delay before `onReconnected`.
  bool justReconnected = false;

  ContextStatusViewModel({
    VoidCallback? onReconnected,
    Duration reconnectDelay = const Duration(seconds: 3),
    Connectivity? connectivity,
    Battery? battery,
  }) : _onReconnected = onReconnected,
       _reconnectDelay = reconnectDelay,
       _connectivity = connectivity ?? Connectivity(),
       _battery = battery ?? Battery() {
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
    _reconnectTimer?.cancel();
    justReconnected = !offline;
    if (!offline) {
      _reconnectTimer = Timer(_reconnectDelay, () {
        justReconnected = false;
        notifyListeners();
        _onReconnected?.call();
      });
    }
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
    _reconnectTimer?.cancel();
    _connectivitySub?.cancel();
    _batterySub?.cancel();
    super.dispose();
  }
}
