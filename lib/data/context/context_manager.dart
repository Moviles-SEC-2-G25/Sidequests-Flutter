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
  /// Rain is short-lived: past this, a last known reading no longer counts as
  /// rain. Stricter than WeatherService.fallbackMaxAge on purpose — the code
  /// itself is still reported (analytics' weather_code), it just stops
  /// reordering Explore.
  static const rainFallbackMaxAge = Duration(hours: 3);

  /// Battery saver (mirror of the Kotlin app's battery-aware context): with
  /// low battery and no charger, GPS + weather aren't read again while the
  /// last reading is younger than this.
  static const batterySaverReuse = Duration(minutes: 15);

  final LocationService _locationService;
  final BatteryMonitor _batteryMonitor;
  final Connectivity _connectivity;
  final WeatherService _weatherService;
  final DateTime Function() _now;
  Future<_DeviceReading>? _readingInFlight;

  ({Position? position, WeatherSnapshot? weather, DateTime readAt})? _lastReading;
  bool _forceNextReading = false;

  /// The last snapshot reused the previous GPS/weather reading to save battery.
  bool batterySaverActive = false;

  ContextManager({
    LocationService? locationService,
    BatteryMonitor? batteryMonitor,
    Connectivity? connectivity,
    WeatherService? weatherService,
    DateTime Function()? now,
  }) : _locationService = locationService ?? LocationService(),
       _batteryMonitor = batteryMonitor ?? BatteryMonitor(),
       _connectivity = connectivity ?? Connectivity(),
       _weatherService = weatherService ?? WeatherService(),
       _now = now ?? DateTime.now;

  /// Single-flight, not a cache: callers arriving during a reading share it
  /// (one recommendation list tracks several events at once), and the next
  /// call after it finishes reads the device again. Each caller still gets
  /// its own [AppContext], since availableMinutes differs per caller.
  Future<AppContext> snapshot({int? availableMinutes}) async {
    final reading = await (_readingInFlight ??= _readDevice().whenComplete(
      () => _readingInFlight = null,
    ));
    final now = _now();
    final weather = reading.weather;
    final weatherAge = weather != null && weather.isStale ? now.difference(weather.fetchedAt) : null;

    return AppContext(
      latitude: reading.position?.latitude,
      longitude: reading.position?.longitude,
      timeOfDay: timeOfDayFor(now),
      dayOfWeek: _dayOfWeek(now),
      isConnected: reading.isConnected,
      availableMinutes: availableMinutes,
      weatherCode: weather?.weatherCode,
      isRainy: (weather?.isRainy ?? false) && (weatherAge == null || weatherAge < rainFallbackMaxAge),
      weatherIsStale: weather?.isStale ?? false,
      weatherAge: weatherAge,
    );
  }

  /// What needs no sensor or network: the clock. For callers that can't wait
  /// for [snapshot]; no location or weather, and assumed connected.
  AppContext localSnapshot({int? availableMinutes}) {
    final now = _now();
    return AppContext(
      timeOfDay: timeOfDayFor(now),
      dayOfWeek: _dayOfWeek(now),
      isConnected: true,
      availableMinutes: availableMinutes,
    );
  }

  /// The next [snapshot] reads GPS and weather again even on low battery:
  /// a manual refresh or a reconnection.
  void forceNextReading() => _forceNextReading = true;

  /// Connectivity depends on nothing else, so it runs alongside the
  /// battery -> GPS -> weather chain, whose order each link needs. It never
  /// throws, so awaiting it last can't leave an error unhandled.
  Future<_DeviceReading> _readDevice() async {
    final isConnected = _isConnected();
    final isLowBattery = await _isLowBattery();
    final force = _forceNextReading;
    _forceNextReading = false;

    // Battery saver: reuse the last GPS + weather while it's recent enough.
    final last = _lastReading;
    if (!force &&
        isLowBattery &&
        last != null &&
        _now().difference(last.readAt) < batterySaverReuse) {
      batterySaverActive = true;
      return (position: last.position, weather: last.weather, isConnected: await isConnected);
    }

    final position = await _locationService.getCurrentPosition(
      accuracy: isLowBattery ? LocationAccuracy.low : LocationAccuracy.medium,
    );
    // Only when there's a fix — and free on repeated snapshots at the same
    // spot, since WeatherService caches by rounded coordinates with its own
    // TTL, so this doesn't fire a new request per snapshot.
    final weather = position == null
        ? null
        : await _weatherService.fetch(position.latitude, position.longitude);
    batterySaverActive = false;
    // Only a reading with a fix is worth reusing.
    if (position != null) _lastReading = (position: position, weather: weather, readAt: _now());

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
