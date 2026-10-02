import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:pedometer/pedometer.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../models/step_session.dart';

enum StepCounterStatus { idle, counting, permissionDenied, permissionPermanentlyDenied, unavailable }

/// Counts walked steps during a mission from the OS step counter
/// (Android TYPE_STEP_COUNTER / iOS CMPedometer via `pedometer`).
///
/// Both platforms report steps **since the last boot**, not since the
/// mission started, so this keeps a baseline (the first reading after
/// [start]) and reports `reading - baseline`. If the counter goes
/// backwards the phone rebooted mid-mission: what was counted so far moves
/// into `carried` and counting continues from the new boot's 0. All of
/// that math lives here, never in a view — like ShakeDetector.
///
/// Known limitation: a reboot followed by walking *more* than the last
/// reading before this app sees a new value is indistinguishable from no
/// reboot, and undercounts.
class StepCounterService {
  final Stream<int> Function() _cumulativeSteps;
  final Future<StepCounterStatus> Function() _requestAccess;
  final Future<bool> Function() _openSettings;

  final StreamController<void> _controller = StreamController<void>.broadcast();
  StreamSubscription<int>? _subscription;
  StepSession? _session;
  StepCounterStatus _status = StepCounterStatus.idle;

  StepCounterService({
    Stream<int> Function()? cumulativeSteps,
    Future<StepCounterStatus> Function()? requestAccess,
    Future<bool> Function()? openSettings,
  }) : _cumulativeSteps =
           cumulativeSteps ?? (() => Pedometer.stepCountStream.map((event) => event.steps)),
       _requestAccess = requestAccess ?? _defaultRequestAccess,
       _openSettings = openSettings ?? openAppSettings;

  StepCounterStatus get status => _status;

  /// The attempt being counted, or null when not counting.
  StepSession? get session => _session;

  /// Emits whenever [status] or [session] changes.
  Stream<void> get onChange => _controller.stream;

  /// Checks platform support and asks for ACTIVITY_RECOGNITION (Android
  /// 10+). Returns [StepCounterStatus.counting] when [start] may be called.
  /// iOS asks for Motion & Fitness itself the first time CMPedometer runs.
  Future<StepCounterStatus> requestAccess() async {
    final result = await _requestAccess();
    if (result != StepCounterStatus.counting) _setStatus(result);
    return result;
  }

  /// Starts counting [session] (a fresh attempt, a persisted one restored
  /// after an app restart, or a resumed abandon carrying its saved total).
  /// Call only after [requestAccess] returned counting.
  void start(StepSession session) {
    _subscription?.cancel();
    _session = session;
    _setStatus(StepCounterStatus.counting);
    _subscription = _cumulativeSteps().listen(_onReading, onError: _onError);
  }

  /// Stops counting and returns the final session (null if not counting).
  StepSession? stop() {
    _subscription?.cancel();
    _subscription = null;
    final finished = _session;
    _session = null;
    _setStatus(StepCounterStatus.idle);
    return finished;
  }

  Future<bool> openSettings() => _openSettings();

  void _onReading(int reading) {
    final session = _session;
    if (session == null) return;

    if (session.baseline == null) {
      // A restored session whose baseline came from a previous run already
      // has one; only a brand-new segment takes this reading as its zero.
      _session = session.copyWith(baseline: reading, lastReading: reading);
    } else if (reading < session.lastReading!) {
      // Counter reset => the phone rebooted. Keep what was counted and
      // restart from the new boot's zero.
      _session = StepSession(
        userQuestId: session.userQuestId,
        carried: session.steps,
        baseline: 0,
        lastReading: reading,
      );
    } else {
      _session = session.copyWith(lastReading: reading);
    }
    _controller.add(null);
  }

  /// "StepCount not available" (no sensor) or no native plugin at all.
  void _onError(Object _) {
    _subscription?.cancel();
    _subscription = null;
    _session = null;
    _setStatus(StepCounterStatus.unavailable);
  }

  void _setStatus(StepCounterStatus status) {
    _status = status;
    _controller.add(null);
  }

  static Future<StepCounterStatus> _defaultRequestAccess() async {
    final isMobile = !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS);
    if (!isMobile) return StepCounterStatus.unavailable;
    if (defaultTargetPlatform == TargetPlatform.iOS) return StepCounterStatus.counting;

    try {
      final status = await Permission.activityRecognition.request();
      if (status.isGranted || status.isLimited) return StepCounterStatus.counting;
      if (status.isPermanentlyDenied || status.isRestricted) {
        return StepCounterStatus.permissionPermanentlyDenied;
      }
      return StepCounterStatus.permissionDenied;
    } catch (_) {
      // No native plugin (unit tests, unsupported embedder).
      return StepCounterStatus.unavailable;
    }
  }

  void dispose() {
    _subscription?.cancel();
    _controller.close();
  }
}
