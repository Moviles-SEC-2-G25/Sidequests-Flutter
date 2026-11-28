/// Event names from Sidequests-Analytics/docs/EVENT_SCHEMA.md.
/// Both Kotlin and Flutter must emit the same event names and dimensions.
abstract final class AnalyticsEventType {
  static const onboardingStepCompleted = 'onboarding_step_completed';
  static const recommendationShown = 'recommendation_shown';
  static const recommendationAccepted = 'recommendation_accepted';
  static const recommendationSkipped = 'recommendation_skipped';
  static const questStarted = 'quest_started';
  static const questAbandoned = 'quest_abandoned';
  static const questAlternativeShown = 'quest_alternative_shown';
  static const questAlternativeSelected = 'quest_alternative_selected';
  static const questCompleted = 'quest_completed';
  static const questRated = 'quest_rated';
  static const locationModeSelected = 'location_mode_selected';
  static const locationIndependentModeSelected = 'location_independent_mode_selected';
  static const locationBasedModeSelected = 'location_based_mode_selected';
  static const shakeSurprise = 'shake_surprise';
  static const similarQuestOpened = 'similar_quest_opened';
  static const photoProofUploaded = 'photo_proof_uploaded';

  // Smart features, same names as the Kotlin app.
  static const smartTimeApplied = 'smart_time_applied';
  static const smartDifficultySuggested = 'smart_difficulty_suggested';
  static const smartDifficultyAccepted = 'smart_difficulty_accepted';
  static const smartDifficultyDismissed = 'smart_difficulty_dismissed';

  // BQ1 telemetry (queued in SQLite, see Bq1Telemetry).
  static const bq1ResumeAfterBackground = 'bq1_resume_after_background';
  static const moduleFailure = 'module_failure';
}
