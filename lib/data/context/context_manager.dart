import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:geolocator/geolocator.dart';

import '../../models/app_context.dart';
import '../services/battery_monitor.dart';
import '../services/location_service.dart';

/// Context Manager (CAS): builds one [AppContext] snapshot per request —
/// location, time of day, day of week and connectivity — for the
/// Repository/ViewModel layers to attach to recommendation requests and
/// analytics events.
class ContextManager {
  final LocationService _locationService;
  final BatteryMonitor _batteryMonitor;
  final Connectivity _connectivity;

  ContextManager({
    LocationService? locationService,
    BatteryMonitor? batteryMonitor,
    Connectivity? connectivity,
  }) : _locationService = locationService ?? LocationService(),
       _batteryMonitor = batteryMonitor ?? BatteryMonitor(),
       _connectivity = connectivity ?? Connectivity();

  Future<AppContext> snapshot({int? availableMinutes}) async {
    final isLowBattery = await _isLowBattery();
    final position = await _locationService.getCurrentPosition(
      accuracy: isLowBattery ? LocationAccuracy.low : LocationAccuracy.medium,
    );
    final isConnected = await _isConnected();
    final now = DateTime.now();

    return AppContext(
      latitude: position?.latitude,
      longitude: position?.longitude,
      timeOfDay: _timeOfDay(now),
      dayOfWeek: _dayOfWeek(now),
      isConnected: isConnected,
      availableMinutes: availableMinutes,
    );
  }

  // A missing sensor (e.g. no battery API on this platform) must never stop
  // a context snapshot from being produced.
  Future<bool> _isLowBattery() async {
    try {
      return await _batteryMonitor.isLow();
    } catch (_) {
      return false;
    }
  }

  Future<bool> _isConnected() async {
    try {
      final results = await _connectivity.checkConnectivity();
      return !results.contains(ConnectivityResult.none);
    } catch (_) {
      return true;
    }
  }

  String _timeOfDay(DateTime now) {
    final hour = now.hour;
    if (hour < 6) return 'night';
    if (hour < 12) return 'morning';
    if (hour < 18) return 'afternoon';
    if (hour < 22) return 'evening';
    return 'night';
  }

  String _dayOfWeek(DateTime now) => const [
    'monday',
    'tuesday',
    'wednesday',
    'thursday',
    'friday',
    'saturday',
    'sunday',
  ][now.weekday - 1];
}
