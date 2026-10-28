import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/distance.dart';
import 'analytics_event_sink.dart';
import '../data/context/context_manager.dart';
import '../data/local/local_data_source.dart';
import '../models/analytics_event.dart';

/// Cross-cutting instrumentation. ViewModels call [track] at the interaction
/// points defined in Sidequests-Analytics/docs/EVENT_SCHEMA.md; this class
/// attaches the current context snapshot and session id and writes straight
/// to `public.analytics_events`.
///
/// Store-and-forward: an event whose insert fails for lack of connection is
/// queued in [LocalDataSource] exactly as it was built — context, distance
/// and the moment it happened — and sent after the next insert that
/// succeeds (or on [flushPending]). Without a local data source (tests) a
/// failed write is dropped. Analytics must never crash or block the user's
/// action, so every failure here is swallowed.
class AnalyticsTracker {
  /// Bound on the offline queue; past it the oldest events are dropped.
  static const maxPendingEvents = 200;

  final AnalyticsEventSink _eventSink;
  final ContextManager _contextManager;
  final LocalDataSource? _localDataSource;
  final String sessionId;
  bool _isFlushing = false;

  AnalyticsTracker({
    required AnalyticsEventSink eventSink,
    required ContextManager contextManager,
    required this.sessionId,
    LocalDataSource? localDataSource,
  }) : _eventSink = eventSink,
       _contextManager = contextManager,
       _localDataSource = localDataSource;

  Future<void> track(
    String eventType, {
    String? questId,
    String? category,
    int? availableMinutes,
    String? socialLevel,
    String? locationMode,
    int? questDurationMinutes,
    String? questDifficulty,
    double? estimatedCost,
    double? questLatitude,
    double? questLongitude,
    Map<String, dynamic> metadata = const {},
  }) async {
    // occurred_at defaults to now() in the backend, which is only right for
    // an event sent immediately; a queued one carries this instead.
    final occurredAt = DateTime.now().toUtc();
    final Map<String, dynamic> event;
    try {
      final context = await _contextManager.snapshot(
        availableMinutes: availableMinutes,
      );
      // Distance user -> quest (BQ6 distance segmentation); only when both
      // the device fix and the quest coordinates are known. Computed here,
      // at the moment of the event — a queued event is never recomputed.
      final int? distanceMeters =
          context.hasLocation && questLatitude != null && questLongitude != null
          ? (haversineKm(
                      context.latitude!,
                      context.longitude!,
                      questLatitude,
                      questLongitude,
                    ) *
                    1000)
                .round()
          : null;
      event = AnalyticsEvent(
        eventType: eventType,
        sessionId: sessionId,
        questId: questId,
        category: category,
        availableMinutes: context.availableMinutes,
        socialLevel: socialLevel,
        locationMode: locationMode,
        latitude: context.latitude,
        longitude: context.longitude,
        weatherCode: context.weatherCode,
        timeOfDay: context.timeOfDay,
        questDurationMinutes: questDurationMinutes,
        questDifficulty: questDifficulty,
        estimatedCost: estimatedCost,
        distanceMeters: distanceMeters,
        metadata: metadata,
      ).toJson();
    } catch (_) {
      // Analytics failures must never surface to the user.
      return;
    }

    try {
      await _eventSink.insertAnalyticsEvent(event);
    } on PostgrestException {
      // The server answered and rejected it: retrying won't help.
      return;
    } catch (_) {
      // No connection (SocketException, ClientException, timeout).
      await _enqueue({...event, 'occurred_at': occurredAt.toIso8601String()});
      return;
    }
    // Connected again: send whatever waited offline.
    unawaited(flushPending());
  }

  /// Sends the events queued offline, oldest first. Stops at the first
  /// connection failure and keeps the rest for the next attempt.
  Future<void> flushPending() async {
    final localDataSource = _localDataSource;
    if (localDataSource == null || _isFlushing) return;
    _isFlushing = true;
    try {
      while (true) {
        final pending = localDataSource.getPendingAnalyticsEvents();
        if (pending.isEmpty) return;
        try {
          await _eventSink.insertAnalyticsEvent(pending.first);
        } on PostgrestException {
          // Rejected by the server: dropped, as a direct insert would be.
        }
        // Re-read: events queued while that insert was in flight stay
        // behind it.
        await localDataSource.savePendingAnalyticsEvents(
          localDataSource.getPendingAnalyticsEvents().skip(1).toList(),
        );
      }
    } catch (_) {
      // Still offline: the rest waits for the next flush.
    } finally {
      _isFlushing = false;
    }
  }

  Future<void> _enqueue(Map<String, dynamic> event) async {
    final localDataSource = _localDataSource;
    if (localDataSource == null) return;
    try {
      final pending = [...localDataSource.getPendingAnalyticsEvents(), event];
      await localDataSource.savePendingAnalyticsEvents(
        pending.length > maxPendingEvents
            ? pending.sublist(pending.length - maxPendingEvents)
            : pending,
      );
    } catch (_) {
      // Storage failed too: the event is lost, as before the queue existed.
    }
  }
}
