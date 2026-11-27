/// Decides dark/light from ambient light readings (lux). Mirror of Kotlin's
/// AmbientLightClassifier.
///
/// Two thresholds (hysteresis) avoid flicker around a single value, and a new
/// decision is only applied after it has persisted for [minHold] (so briefly
/// passing a hand over the phone does not switch the theme). Pure Dart so it
/// can be unit tested without a device.
class AmbientLightClassifier {
  static const darkBelowLuxDefault = 15.0;
  static const lightAboveLuxDefault = 40.0;
  static const minHoldDefault = Duration(seconds: 2);

  final double darkBelowLux;
  final double lightAboveLux;
  final Duration minHold;

  bool? _isDark;
  bool? _pendingCandidate;
  DateTime? _pendingSince;

  AmbientLightClassifier({
    this.darkBelowLux = darkBelowLuxDefault,
    this.lightAboveLux = lightAboveLuxDefault,
    this.minHold = minHoldDefault,
  });

  bool? get isDark => _isDark;

  /// True while a change is waiting for the hold time to pass.
  bool get hasPendingChange => _pendingCandidate != null;

  /// Returns the new decision when it changes, or null when it stays the same
  /// (or is pending).
  bool? onReading(double lux, DateTime now) {
    final current = _isDark;
    final bool candidate;
    if (lux < darkBelowLux) {
      candidate = true;
    } else if (lux > lightAboveLux) {
      candidate = false;
    } else {
      candidate = current ?? false;
    }

    if (current == null) {
      _isDark = candidate;
      return candidate;
    }
    if (candidate == current) {
      _pendingCandidate = null;
      return null;
    }
    if (_pendingCandidate != candidate) {
      _pendingCandidate = candidate;
      _pendingSince = now;
      return null;
    }
    if (now.difference(_pendingSince!) < minHold) return null;

    _isDark = candidate;
    _pendingCandidate = null;
    return candidate;
  }
}
