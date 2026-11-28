/// A return to the app after a long background period with an active Nearby
/// (GPS) quest.
class ResumeInfo {
  final DateTime resumedAt;
  final Duration background;
  final String questId;

  const ResumeInfo({required this.resumedAt, required this.background, required this.questId});
}

/// BQ1 (mirror of Kotlin's ResumeSessionTracker): detects "the user brings
/// the app back to the foreground after more than 10 minutes in the
/// background while a location-based (Nearby) quest is active".
///
/// Failures during the following [window] are attributed to that resume.
/// Pure Dart (times are passed in) so it can be unit tested; the background
/// start is persisted by Bq1Telemetry so a resume is also detected if the OS
/// killed the app meanwhile.
class ResumeSessionTracker {
  static const tenMinutes = Duration(minutes: 10);
  static const fiveMinutes = Duration(minutes: 5);

  final Duration threshold;
  final Duration window;

  DateTime? backgroundSince;
  String? backgroundQuestId;
  ResumeInfo? lastResume;

  ResumeSessionTracker({this.threshold = tenMinutes, this.window = fiveMinutes});

  void onBackground(DateTime now, String? activeNearbyQuestId) {
    backgroundSince = now;
    backgroundQuestId = activeNearbyQuestId;
  }

  /// Restores a background period saved before the app was killed.
  void restore(DateTime? since, String? questId) {
    backgroundSince = since;
    backgroundQuestId = questId;
  }

  /// The resume when it qualifies for BQ1, otherwise null.
  ResumeInfo? onForeground(DateTime now) {
    final since = backgroundSince;
    if (since == null) return null;
    final questId = backgroundQuestId;
    backgroundSince = null;
    backgroundQuestId = null;
    final elapsed = now.difference(since);
    if (questId == null || elapsed < threshold) return null;
    return lastResume = ResumeInfo(resumedAt: now, background: elapsed, questId: questId);
  }

  /// Debug/demo: behaves as if the app had just returned from [background].
  ResumeInfo simulateResume(DateTime now, Duration background, String questId) =>
      lastResume = ResumeInfo(resumedAt: now, background: background, questId: questId);

  /// The resume that is still "recent" at [now], used to tag failures.
  ResumeInfo? activeResume(DateTime now) {
    final resume = lastResume;
    if (resume == null) return null;
    final since = now.difference(resume.resumedAt);
    return !since.isNegative && since <= window ? resume : null;
  }
}
