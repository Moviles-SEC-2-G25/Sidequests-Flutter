/// The onboarding funnel's step taxonomy (Sidequests-Analytics BQ3).
///
/// `order` is the canonical, stable position of each step in the funnel and
/// must never be derived from a widget/page index: reordering screens in
/// code must not silently renumber events already recorded for existing
/// users. Add new steps by giving them their own case with an explicit,
/// never-reused `order`.
enum OnboardingStep {
  welcome(1, 'welcome'),
  preferences(2, 'preferences');

  final int order;
  final String stepName;

  const OnboardingStep(this.order, this.stepName);
}
