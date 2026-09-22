/// The one operation [AnalyticsTracker] needs from a remote data source.
/// Kept separate from `SupabaseRemoteDataSource`'s full surface so tests can
/// fake the analytics write path without stubbing unrelated auth/REST calls.
abstract interface class AnalyticsEventSink {
  Future<void> insertAnalyticsEvent(Map<String, dynamic> event);
}
