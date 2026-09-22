import 'package:battery_plus/battery_plus.dart';

/// Wraps the battery sensor. The Location Service consults this before
/// requesting a GPS fix so a low battery falls back to coarser accuracy
/// instead of aggressive polling (QS5).
class BatteryMonitor {
  static const _lowBatteryThreshold = 20;

  final Battery _battery = Battery();

  Future<bool> isLow() async {
    final level = await _battery.batteryLevel;
    return level <= _lowBatteryThreshold;
  }
}
