import 'package:flutter/foundation.dart';

import '../../analytics/analytics_event_type.dart';
import '../../analytics/analytics_tracker.dart';
import '../../analytics/onboarding_step.dart';
import '../../core/app_exception.dart';
import '../../data/services/biometric_service.dart';
import '../../repository/auth_repository.dart';

enum AuthStatus { unknown, unauthenticated, authenticating, authenticated }

/// Session state and login/sign-up intents for the auth & onboarding views.
class AuthViewModel extends ChangeNotifier {
  final AuthRepository _authRepository;
  final BiometricService _biometricService;
  final AnalyticsTracker _analyticsTracker;

  AuthStatus status = AuthStatus.unknown;
  String? errorMessage;

  /// True while a restored session must be confirmed with biometrics before
  /// the app shell is shown. Only set at startup — signing in with a
  /// password never locks.
  bool isLocked = false;
  bool biometricEnabled = false;
  bool isBiometricAvailable = false;

  AuthViewModel(this._authRepository, this._biometricService, this._analyticsTracker) {
    status = _authRepository.isAuthenticated
        ? AuthStatus.authenticated
        : AuthStatus.unauthenticated;
    biometricEnabled = _authRepository.isBiometricEnabled;
    isLocked = status == AuthStatus.authenticated && biometricEnabled;
    _authRepository.authStateChanges.listen((_) {
      status = _authRepository.isAuthenticated
          ? AuthStatus.authenticated
          : AuthStatus.unauthenticated;
      if (status == AuthStatus.unauthenticated) isLocked = false;
      notifyListeners();
    });
  }

  String? get userId => _authRepository.currentUser?.id;

  Future<bool> signIn({required String email, required String password}) =>
      _run(() => _authRepository.signIn(email: email, password: password));

  Future<bool> signUp({required String email, required String password}) =>
      _run(() => _authRepository.signUp(email: email, password: password));

  /// Repository sign-out also clears the biometric flag.
  Future<void> signOut() async {
    isLocked = false;
    biometricEnabled = false;
    await _authRepository.signOut();
    notifyListeners();
  }

  Future<void> loadBiometricAvailability() async {
    isBiometricAvailable = await _biometricService.isAvailable();
    notifyListeners();
  }

  /// Asks for the fingerprint once to confirm before persisting the flag.
  Future<bool> enableBiometric() async {
    if (!await _biometricService.authenticate('Confirma tu huella para activar el desbloqueo')) {
      return false;
    }
    await _authRepository.setBiometricEnabled(true);
    biometricEnabled = true;
    notifyListeners();
    return true;
  }

  Future<void> disableBiometric() async {
    await _authRepository.setBiometricEnabled(false);
    biometricEnabled = false;
    notifyListeners();
  }

  /// Lock screen: true (and unlocks) if the user authenticated.
  Future<bool> unlock() async {
    final success = await _biometricService.authenticate('Desbloquea Sidequests');
    if (success) {
      isLocked = false;
      notifyListeners();
    }
    return success;
  }

  Future<bool> _run(Future<void> Function() action) async {
    status = AuthStatus.authenticating;
    errorMessage = null;
    notifyListeners();
    try {
      await action();
      // signUp doesn't create a session when email confirmation is
      // required, so authStateChanges never fires to clear this status.
      status = _authRepository.isAuthenticated
          ? AuthStatus.authenticated
          : AuthStatus.unauthenticated;
      notifyListeners();
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
