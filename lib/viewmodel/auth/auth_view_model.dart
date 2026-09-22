import 'package:flutter/foundation.dart';

import '../../analytics/analytics_event_type.dart';
import '../../analytics/analytics_tracker.dart';
import '../../analytics/onboarding_step.dart';
import '../../core/app_exception.dart';
import '../../repository/auth_repository.dart';

enum AuthStatus { unknown, unauthenticated, authenticating, authenticated }

/// Session state and login/sign-up intents for the auth & onboarding views.
class AuthViewModel extends ChangeNotifier {
  final AuthRepository _authRepository;
  final AnalyticsTracker _analyticsTracker;

  AuthStatus status = AuthStatus.unknown;
  String? errorMessage;

  AuthViewModel(this._authRepository, this._analyticsTracker) {
    status = _authRepository.isAuthenticated
        ? AuthStatus.authenticated
        : AuthStatus.unauthenticated;
    _authRepository.authStateChanges.listen((_) {
      status = _authRepository.isAuthenticated
          ? AuthStatus.authenticated
          : AuthStatus.unauthenticated;
      notifyListeners();
    });
  }

  String? get userId => _authRepository.currentUser?.id;

  Future<bool> signIn({required String email, required String password}) =>
      _run(() => _authRepository.signIn(email: email, password: password));

  Future<bool> signUp({required String email, required String password}) =>
      _run(() => _authRepository.signUp(email: email, password: password));

  Future<void> signOut() => _authRepository.signOut();

  Future<bool> _run(Future<void> Function() action) async {
    status = AuthStatus.authenticating;
    errorMessage = null;
    notifyListeners();
    try {
      await action();
      return true;
    } on AppException catch (e) {
      status = AuthStatus.unauthenticated;
      errorMessage = e.message;
      notifyListeners();
      return false;
    }
  }

  /// Fires the moment the user completes/advances past [step] — never on
  /// screen entry — so BQ3 can measure per-step drop-off within a session.
  void trackOnboardingStep(OnboardingStep step) {
    _analyticsTracker.track(
      AnalyticsEventType.onboardingStepCompleted,
      metadata: {'step_order': step.order, 'step_name': step.stepName},
    );
  }
}
