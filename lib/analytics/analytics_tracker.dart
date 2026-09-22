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
    Map<String, dynamic> metadata = const {},
  }) async {
    try {
      final context = await _contextManager.snapshot();
      final event = AnalyticsEvent(
        eventType: eventType,
        sessionId: sessionId,
        questId: questId,
        category: category,
        availableMinutes: context.availableMinutes,
        latitude: context.latitude,
        longitude: context.longitude,
        timeOfDay: context.timeOfDay,
        metadata: metadata,
      );
      await _eventSink.insertAnalyticsEvent(event.toJson());
    } catch (_) {
      // Analytics failures must never surface to the user.
    }
  }
}
