import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../analytics/analytics_event_type.dart';
import '../core/app_version.dart';
import 'app_module.dart';
import 'resume_session_tracker.dart';
import 'telemetry_store.dart';

/// Sends a batch of queued events; throws when it couldn't (they stay queued).
typedef TelemetrySender = Future<void> Function(List<PendingTelemetryEvent> events);

/// BQ1 (Type 1, app telemetry; mirror of the Kotlin app's Bq1Telemetry):
/// "At what specific software module does the app most frequently crash when
/// a user brings the app back to the foreground after tracking a
/// location-based quest in the background for more than 10 minutes?"
///
/// - [onAppBackground]/[onAppForeground] detect the qualifying resumes and
///   record a `bq1_resume_after_background` event (the denominator).
/// - Uncaught errors ([recordUncaught], wired in main.dart) and non-fatal
///   failures reported by the modules ([report]) are recorded as
///   `module_failure` events, tagged with the module and with whether they
///   happened within 5 minutes of such a resume.
///
/// Every event goes to the SQLite queue first ([TelemetryStore]) and is
/// uploaded in batches when there's a connection, retrying with exponential
/// backoff, so nothing is lost offline.
///
/// Same design decisions as Kotlin: "tracking a location-based quest in the
/// background" = an accepted, unfinished Nearby (`gps`) quest while the app is
/// in the background; every failure records `online` and `app_version`.
/// In Flutter an uncaught error doesn't kill the app, so `fatal` means
/// "uncaught" here.
class Bq1Telemetry implements FailureReporter {
  static const _keyBackgroundSince = 'bq1_background_since';
  static const _keyBackgroundQuest = 'bq1_background_quest';
  static const _batchSize = 50;
  static const _maxAttempts = 8;
  static const _baseBackoff = Duration(seconds: 30);

  final TelemetryStore _store;
  final TelemetrySender _send;
  final Future<bool?> Function() _isOnline;
  final DateTime Function() _now;
  final ResumeSessionTracker _tracker;
  SharedPreferences? _prefs;

  /// One id per app run, shared by all the events of this run.
  final String sessionId = const Uuid().v4();

  /// Id of the active Nearby (GPS) quest, or null. Set by HomeShell.
  String? Function() activeNearbyQuestId = () => null;

  /// Events waiting in the queue (shown in the debug card).
  final ValueNotifier<int> pendingCount = ValueNotifier(0);

  /// The last qualifying resume (shown in the debug card).
  final ValueNotifier<ResumeInfo?> lastResume = ValueNotifier(null);

  /// Writes to the queue, one after another, so events keep their order.
  Future<void> _writes = Future.value();
  Future<void>? _uploadInFlight;
  bool _uploading = false;
  bool _uploadAgain = false;
  int _failedAttempts = 0;
  Timer? _retryTimer;
  AppLifecycleListener? _lifecycleListener;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;

  Bq1Telemetry({
    required TelemetryStore store,
    required TelemetrySender sender,
    Future<bool?> Function()? isOnline,
    DateTime Function()? now,
    ResumeSessionTracker? tracker,
  }) : _store = store,
       _send = sender,
       _isOnline = isOnline ?? _connectivityOnline,
       _now = now ?? DateTime.now,
       _tracker = tracker ?? ResumeSessionTracker();

  static Future<bool?> _connectivityOnline() async {
    try {
      final results = await Connectivity().checkConnectivity();
      return !results.contains(ConnectivityResult.none);
    } catch (_) {
      return null;
    }
  }

  /// Restores a background period saved before the app was killed, listens
  /// to the app lifecycle and to reconnections, and uploads anything left by
  /// a previous run.
  Future<void> init({bool listenToLifecycle = true}) async {
    try {
      final prefs = _prefs = await SharedPreferences.getInstance();
      final since = prefs.getInt(_keyBackgroundSince);
      _tracker.restore(
        since == null ? null : DateTime.fromMillisecondsSinceEpoch(since),
        prefs.getString(_keyBackgroundQuest),
      );
    } catch (_) {
      // No saved period: nothing to restore.
    }
    if (listenToLifecycle) {
      _lifecycleListener = AppLifecycleListener(onPause: onAppBackground, onResume: onAppForeground);
      try {
        _connectivitySubscription = Connectivity().onConnectivityChanged.listen((results) {
          if (!results.contains(ConnectivityResult.none)) scheduleUpload();
        });
      } catch (_) {}
    }
    await refreshPendingCount();
    scheduleUpload();
  }

  void onAppBackground() {
    final now = _now();
    String? questId;
    try {
      questId = activeNearbyQuestId();
    } catch (_) {}
    _tracker.onBackground(now, questId);
    final prefs = _prefs;
    if (prefs == null) return;
    unawaited(() async {
      try {
        await prefs.setInt(_keyBackgroundSince, now.millisecondsSinceEpoch);
        if (questId == null) {
          await prefs.remove(_keyBackgroundQuest);
        } else {
          await prefs.setString(_keyBackgroundQuest, questId);
        }
      } catch (_) {}
    }());
  }

  void onAppForeground() {
    final resume = _tracker.onForeground(_now());
    final prefs = _prefs;
    if (prefs != null) {
      unawaited(() async {
        try {
          await prefs.remove(_keyBackgroundSince);
          await prefs.remove(_keyBackgroundQuest);
        } catch (_) {}
      }());
    }
    if (resume != null) _recordResume(resume);
    scheduleUpload();
  }

  /// Non-fatal failure reported by a module (network error, timeout,
  /// unavailable service...).
  @override
  void report(AppModule module, Object? error, {String? message}) {
    final now = _now();
    _write(() async {
      final metadata = await _failureMetadata(module, false, error, message, now);
      await _enqueue(AnalyticsEventType.moduleFailure, metadata, now);
    });
  }

  /// An error nobody caught (FlutterError.onError / PlatformDispatcher.onError).
  void recordUncaught(Object error, StackTrace? stackTrace) {
    final now = _now();
    final module = ModuleClassifier.fromStackTrace(stackTrace);
    _write(() async {
      final metadata = await _failureMetadata(module, true, error, null, now);
      await _enqueue(AnalyticsEventType.moduleFailure, metadata, now);
    });
  }

  /// Debug/demo: records a qualifying resume without waiting 10 minutes.
  void simulateLongResume() {
    String? questId;
    try {
      questId = activeNearbyQuestId();
    } catch (_) {}
    _recordResume(
      _tracker.simulateResume(_now(), const Duration(minutes: 11), questId ?? 'debug-no-active-quest'),
    );
  }

  /// Every pending write and upload has finished (for tests).
  @visibleForTesting
  Future<void> settle() async {
    await _writes;
    while (_uploadInFlight != null) {
      await _uploadInFlight;
    }
  }

  void _write(Future<void> Function() body) {
    _writes = _writes.then((_) => body()).catchError((Object _) {});
  }

  Future<void> refreshPendingCount() async {
    try {
      pendingCount.value = await _store.count();
    } catch (_) {}
  }

  /// Uploads the queue in batches, oldest first. A failure retries with
  /// exponential backoff (30 s, 1 min, 2 min...) up to [_maxAttempts] times;
  /// after that, the next event, resume or reconnection tries again.
  void scheduleUpload() {
    _retryTimer?.cancel();
    _retryTimer = null;
    if (_uploading) {
      _uploadAgain = true;
      return;
    }
    final upload = _uploadInFlight = _upload();
    unawaited(upload.whenComplete(() {
      if (identical(_uploadInFlight, upload)) _uploadInFlight = null;
    }));
  }

  Future<void> _upload() async {
    _uploading = true;
    try {
      while (true) {
        final batch = await _store.oldest(_batchSize);
        if (batch.isEmpty) break;
        await _send(batch);
        await _store.delete([for (final event in batch) event.id]);
      }
      _failedAttempts = 0;
    } catch (_) {
      _failedAttempts++;
      if (_failedAttempts < _maxAttempts) {
        final backoff = _baseBackoff * pow(2, _failedAttempts - 1).toInt();
        _retryTimer = Timer(backoff, scheduleUpload);
      } else {
        _failedAttempts = 0;
      }
    } finally {
      _uploading = false;
      await refreshPendingCount();
    }
    if (_uploadAgain) {
      _uploadAgain = false;
      if (_retryTimer == null) scheduleUpload();
    }
  }

  void _recordResume(ResumeInfo resume) {
    lastResume.value = resume;
    _write(() async {
      final online = await _isOnline();
      await _enqueue(AnalyticsEventType.bq1ResumeAfterBackground, {
        'bq': 'BQ1',
        'app_version': appVersion,
        if (online != null) 'online': online,
        'background_minutes': resume.background.inMinutes,
        'quest_id': resume.questId,
        // Links failures to this resume.
        'resume_at_millis': resume.resumedAt.millisecondsSinceEpoch,
      }, resume.resumedAt);
    });
  }

  Future<Map<String, dynamic>> _failureMetadata(
    AppModule module,
    bool fatal,
    Object? error,
    String? message,
    DateTime now,
  ) async {
    final resume = _tracker.activeResume(now);
    final online = await _isOnline();
    final text = message ?? error?.toString() ?? '';
    return {
      'bq': 'BQ1',
      'app_version': appVersion,
      if (online != null) 'online': online,
      'module': module.code,
      'fatal': fatal,
      'exception': error?.runtimeType.toString() ?? 'none',
      'message': text.length > 200 ? text.substring(0, 200) : text,
      'after_long_resume': resume != null,
      if (resume != null) ...{
        'background_minutes': resume.background.inMinutes,
        'seconds_since_resume': now.difference(resume.resumedAt).inSeconds,
        'resume_at_millis': resume.resumedAt.millisecondsSinceEpoch,
        'quest_id': resume.questId,
      },
    };
  }

  Future<void> _enqueue(String eventType, Map<String, dynamic> metadata, DateTime createdAt) async {
    try {
      await _store.insert(
        eventType: eventType,
        sessionId: sessionId,
        metadataJson: jsonEncode(metadata),
        createdAtMillis: createdAt.millisecondsSinceEpoch,
      );
    } catch (_) {
      // Telemetry must never break the app.
      return;
    }
    await refreshPendingCount();
    scheduleUpload();
  }

  void dispose() {
    _retryTimer?.cancel();
    _lifecycleListener?.dispose();
    _connectivitySubscription?.cancel();
    pendingCount.dispose();
    lastResume.dispose();
  }
}

/// Sends queued events to the shared `analytics_events` table used by the
/// analytics pipeline. Needs a signed-in user (RLS): without one it throws and
/// the events stay queued.
TelemetrySender supabaseTelemetrySender(SupabaseClient client) => (events) async {
  final userId = client.auth.currentUser?.id;
  if (userId == null) throw StateError('No signed-in user yet; the events stay queued.');
  await client.from('analytics_events').insert([
    for (final event in events)
      {
        'user_id': userId,
        'session_id': event.sessionId,
        'event_type': event.eventType,
        'occurred_at': DateTime.fromMillisecondsSinceEpoch(event.createdAtMillis).toUtc().toIso8601String(),
        'metadata': {
          ..._decode(event.metadataJson),
          'occurred_at_millis': event.createdAtMillis,
        },
      },
  ]);
};

Map<String, dynamic> _decode(String json) {
  try {
    return (jsonDecode(json) as Map).cast<String, dynamic>();
  } catch (_) {
    return const {};
  }
}
