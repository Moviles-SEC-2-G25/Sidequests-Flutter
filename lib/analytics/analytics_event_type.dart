/// Event names from Sidequests-Analytics/docs/EVENT_SCHEMA.md.
/// Both Kotlin and Flutter must emit the same event names and dimensions.
abstract final class AnalyticsEventType {
  static const onboardingStepCompleted = 'onboarding_step_completed';
  static const recommendationShown = 'recommendation_shown';
  static const recommendationAccepted = 'recommendation_accepted';
  static const recommendationSkipped = 'recommendation_skipped';
  static const questStarted = 'quest_started';
  static const questAbandoned = 'quest_abandoned';
  static const questCompleted = 'quest_completed';
  static const questRated = 'quest_rated';
  static const locationModeSelected = 'location_mode_selected';
}
