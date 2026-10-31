import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';

import '../../analytics/analytics_event_type.dart';
import '../../analytics/analytics_tracker.dart';
import '../../analytics/onboarding_step.dart';
import '../../core/app_exception.dart';
import '../../data/services/biometric_service.dart';
import '../../repository/auth_repository.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show AuthChangeEvent, AuthState, SignOutReason;

enum AuthStatus { unknown, unauthenticated, authenticating, authenticated }

/// Session state and login/sign-up intents for the auth & onboarding views.
///
/// Biometric lock is local-only: [isLocked], [unlock], [enableBiometric] and
/// [disableBiometric] read the persisted session and flag and the device's
/// sensor, and never touch the network.
class AuthViewModel extends ChangeNotifier {
  final AuthRepository _authRepository;
  final BiometricService _biometricService;
  final AnalyticsTracker _analyticsTracker;
  final Future<bool> Function() _isOffline;

  AuthStatus status = AuthStatus.unknown;
  String? errorMessage;

  /// True while a restored session must be confirmed with biometrics before
  /// the app shell is shown. Only set at startup — signing in (password or
  /// emailed code) never locks: the code IS the identity check.
  bool isLocked = false;
  bool biometricEnabled = false;
  bool isBiometricAvailable = false;

  AuthViewModel(
    this._authRepository,
    this._biometricService,
    this._analyticsTracker, {
    Future<bool> Function()? isOffline,
  }) : _isOffline = isOffline ?? _connectivityIsOffline {
    status = _authRepository.isAuthenticated
        ? AuthStatus.authenticated
        : AuthStatus.unauthenticated;
    biometricEnabled = _authRepository.isBiometricEnabled;
    isLocked = status == AuthStatus.authenticated && biometricEnabled;
    _authRepository.authStateChanges.listen(
      (state) {
        status = _authRepository.isAuthenticated
            ? AuthStatus.authenticated
            : AuthStatus.unauthenticated;
        if (status == AuthStatus.unauthenticated) isLocked = false;
        notifyListeners();
        if (_isForcedSignOut(state)) _clearAfterForcedSignOut();
      },
      // A token refresh that fails without a connection arrives here, not as
      // `signedOut`: gotrue keeps the session and refreshes it once back
      // online, so it changes nothing. (`signedOut` with sessionExpired does
      // need the server to reject the token, and the session is gone by then.)
      onError: (Object _) {},
    );
  }

  /// Explicit sign-outs clean up in [signOut]. A null reason is a sign-out
  /// relayed from another tab (web), which cleans up on its own.
  static bool _isForcedSignOut(AuthState state) =>
      state.event == AuthChangeEvent.signedOut &&
      state.signOutReason != null &&
      state.signOutReason != SignOutReason.userInitiated;

  /// Clears the cache and the pending queues, so analytics waiting to be sent
  /// don't go out under the next account (the user id is stamped at insert).
  /// Not when the device is offline: that isn't a verdict on the account.
  Future<void> _clearAfterForcedSignOut() async {
    try {
      if (await isOffline()) return;
      await _authRepository.clearLocalData();
      biometricEnabled = false;
      notifyListeners();
    } catch (_) {
      // Storage failed too: nothing else to do from a listener.
    }
  }

  static Future<bool> _connectivityIsOffline() async =>
      (await Connectivity().checkConnectivity()).contains(ConnectivityResult.none);

  /// Asked here because ContextStatusViewModel lives inside HomeShell, below
  /// the lock screen. Unknown connectivity counts as online.
  Future<bool> isOffline() async {
    try {
      return await _isOffline();
    } catch (_) {
      return false;
    }
  }

  // --- Passwordless sign-in with an emailed code (feature e). Kept apart
  // from [errorMessage], which LoginView shows. ---
  bool isSendingCode = false;
  String? otpErrorMessage;

  String? get userId => _authRepository.currentUser?.id;

  /// Step 1. Doesn't touch [status]: emailing a code isn't signing in.
  Future<bool> sendLoginCode(String email) async {
    isSendingCode = true;
    otpErrorMessage = null;
    notifyListeners();
    try {
      await _authRepository.sendLoginCode(email);
      return true;
    } on AppException catch (e) {
      otpErrorMessage = e.message;
      return false;
    } finally {
      isSendingCode = false;
      notifyListeners();
    }
  }

  /// Step 2. On success the session's `signedIn` event moves AuthGate on;
  /// the caller pops the code screen pushed on top of it.
  Future<bool> verifyLoginCode({required String email, required String code}) async {
    otpErrorMessage = null;
    final success = await _run(() => _authRepository.verifyLoginCode(email: email, code: code));
    if (!success) {
      otpErrorMessage = errorMessage;
      errorMessage = null; // not LoginView's error
      notifyListeners();
    }
    return success;
  }

  void clearOtpError() {
    if (otpErrorMessage == null) return;
    otpErrorMessage = null;
    notifyListeners();
  }

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
  /// Returns null on success, or the error message to show.
  Future<String?> changePassword(String newPassword) async {
    try {
      await _authRepository.changePassword(newPassword);
      return null;
    } on AppException catch (e) {
      return e.message;
    }
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
