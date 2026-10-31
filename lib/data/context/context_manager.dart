import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:geolocator/geolocator.dart';

import '../../core/bq10_context.dart';
import '../../models/app_context.dart';
import '../../models/weather_snapshot.dart';
import '../services/battery_monitor.dart';
import '../services/location_service.dart';
import '../services/weather_service.dart';

/// What the device reports, shared by simultaneous [ContextManager.snapshot]
/// callers. Nothing per-caller belongs here (see availableMinutes).
typedef _DeviceReading = ({Position? position, WeatherSnapshot? weather, bool isConnected});

/// Context Manager (CAS): builds one [AppContext] snapshot per request —
/// location, time of day, day of week, connectivity and weather — for the
/// Repository/ViewModel layers to attach to recommendation requests and
/// analytics events.
class ContextManager {
  final LocationService _locationService;
  final BatteryMonitor _batteryMonitor;
  final Connectivity _connectivity;
  final WeatherService _weatherService;
  Future<_DeviceReading>? _readingInFlight;

  ContextManager({
    LocationService? locationService,
    BatteryMonitor? batteryMonitor,
    Connectivity? connectivity,
    WeatherService? weatherService,
  }) : _locationService = locationService ?? LocationService(),
       _batteryMonitor = batteryMonitor ?? BatteryMonitor(),
       _connectivity = connectivity ?? Connectivity(),
       _weatherService = weatherService ?? WeatherService();

  /// Single-flight, not a cache: callers arriving during a reading share it
  /// (one recommendation list tracks several events at once), and the next
  /// call after it finishes reads the device again. Each caller still gets
  /// its own [AppContext], since availableMinutes differs per caller.
  Future<AppContext> snapshot({int? availableMinutes}) async {
    final reading = await (_readingInFlight ??= _readDevice().whenComplete(
      () => _readingInFlight = null,
    ));
    final now = DateTime.now();

    return AppContext(
      latitude: reading.position?.latitude,
      longitude: reading.position?.longitude,
      timeOfDay: timeOfDayFor(now),
      dayOfWeek: _dayOfWeek(now),
      isConnected: reading.isConnected,
      availableMinutes: availableMinutes,
      weatherCode: reading.weather?.weatherCode,
      isRainy: reading.weather?.isRainy ?? false,
    );
  }

  /// Connectivity depends on nothing else, so it runs alongside the
  /// battery -> GPS -> weather chain, whose order each link needs. It never
  /// throws, so awaiting it last can't leave an error unhandled.
  Future<_DeviceReading> _readDevice() async {
    final isConnected = _isConnected();
    final isLowBattery = await _isLowBattery();
    final position = await _locationService.getCurrentPosition(
      accuracy: isLowBattery ? LocationAccuracy.low : LocationAccuracy.medium,
    );
    // Only when there's a fix — and free on repeated snapshots at the same
    // spot, since WeatherService caches by rounded coordinates with its own
    // TTL, so this doesn't fire a new request per snapshot.
    final weather = position == null
        ? null
        : await _weatherService.fetch(position.latitude, position.longitude);

    return (position: position, weather: weather, isConnected: await isConnected);
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
