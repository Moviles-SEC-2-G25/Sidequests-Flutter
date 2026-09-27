import '../core/distance.dart';
import 'analytics_event_sink.dart';
import '../data/context/context_manager.dart';
import '../models/analytics_event.dart';

/// Cross-cutting instrumentation. ViewModels call [track] at the interaction
/// points defined in Sidequests-Analytics/docs/EVENT_SCHEMA.md; this class
/// attaches the current context snapshot and session id and writes straight
/// to `public.analytics_events`.
///
/// The offline queue + batch upload described in the architecture is
/// {planned}: today a failed write is dropped rather than buffered, since
/// analytics must never crash or block the user's action.
class AnalyticsTracker {
  final AnalyticsEventSink _eventSink;
  final ContextManager _contextManager;
  final String sessionId;

  AnalyticsTracker({
    required AnalyticsEventSink eventSink,
    required ContextManager contextManager,
    required this.sessionId,
  }) : _eventSink = eventSink,
       _contextManager = contextManager;

  Future<void> track(
    String eventType, {
    String? questId,
    String? category,
    int? availableMinutes,
    String? locationMode,
    int? questDurationMinutes,
    String? questDifficulty,
    double? estimatedCost,
    double? questLatitude,
    double? questLongitude,
    Map<String, dynamic> metadata = const {},
  }) async {
    try {
      final context = await _contextManager.snapshot(
        availableMinutes: availableMinutes,
      );
      // Distance user -> quest (BQ6 distance segmentation); only when both
      // the device fix and the quest coordinates are known.
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
      final event = AnalyticsEvent(
        eventType: eventType,
        sessionId: sessionId,
        questId: questId,
        category: category,
        availableMinutes: context.availableMinutes,
        locationMode: locationMode,
        latitude: context.latitude,
        longitude: context.longitude,
        timeOfDay: context.timeOfDay,
        questDurationMinutes: questDurationMinutes,
        questDifficulty: questDifficulty,
        estimatedCost: estimatedCost,
        distanceMeters: distanceMeters,
        metadata: metadata,
      );
      await _eventSink.insertAnalyticsEvent(event.toJson());
    } catch (_) {
      // Analytics failures must never surface to the user.
    }
  }
}
