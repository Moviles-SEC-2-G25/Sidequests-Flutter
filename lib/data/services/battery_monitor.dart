import 'package:battery_plus/battery_plus.dart';

/// Wraps the battery sensor. The Location Service consults this before
/// requesting a GPS fix so a low battery falls back to coarser accuracy
/// instead of aggressive polling (QS5), and the Context Manager reuses its
/// last reading for a while (battery saver).
///
/// "Low" means at or below [lowBatteryThreshold] and not charging, as in the
/// Kotlin app's DeviceStatus: plugged in, there's no energy to save.
class BatteryMonitor {
  static const lowBatteryThreshold = 20;

  final Battery _battery = Battery();

  Future<bool> isLow() async {
    final level = await _battery.batteryLevel;
    if (level > lowBatteryThreshold) return false;
    try {
      final state = await _battery.batteryState;
      return state != BatteryState.charging && state != BatteryState.full;
    } catch (_) {
      return true;
    }
  }
}
