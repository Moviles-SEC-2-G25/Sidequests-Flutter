import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/app_exception.dart';
import '../data/local/local_data_source.dart';
import '../data/remote/supabase_remote_data_source.dart';

/// Single source of truth for the current session.
class AuthRepository {
  final SupabaseRemoteDataSource _remoteDataSource;
  final LocalDataSource _localDataSource;

  AuthRepository(this._remoteDataSource, this._localDataSource);

  User? get currentUser => _remoteDataSource.currentSession?.user;

  String? get currentUserEmail => _remoteDataSource.currentUserEmail;

  bool get isAuthenticated => currentUser != null;

  Stream<AuthState> get authStateChanges => _remoteDataSource.authStateChanges;

  bool get isBiometricEnabled => _localDataSource.isBiometricEnabled();

  Future<void> setBiometricEnabled(bool value) =>
      _localDataSource.setBiometricEnabled(value);

  Future<void> signUp({required String email, required String password}) async {
    try {
      await _remoteDataSource.signUp(email: email, password: password);
    } on AuthException catch (e) {
      throw AppException(e.message);
    }
  }

  Future<void> signIn({required String email, required String password}) async {
    try {
      await _remoteDataSource.signIn(email: email, password: password);
    } on AuthException catch (e) {
      throw AppException(e.message);
    }
  }

  /// Passwordless sign-in, step 1: email a 6-digit code.
  Future<void> sendLoginCode(String email) async {
    try {
      await _remoteDataSource.sendEmailOtp(email);
    } on AuthException catch (e) {
      throw AppException(_loginCodeMessage(e), isRetryable: e is AuthRetryableFetchException);
    }
  }

  /// Step 2: exchange the code for a session.
  Future<void> verifyLoginCode({required String email, required String code}) async {
    try {
      await _remoteDataSource.verifyEmailOtp(email: email, token: code);
    } on AuthException catch (e) {
      throw AppException(_loginCodeMessage(e), isRetryable: e is AuthRetryableFetchException);
    }
  }

  /// Supabase's messages are English and don't say what to do next.
  String _loginCodeMessage(AuthException e) {
    if (e is AuthRetryableFetchException) return 'Sin conexión. Inténtalo de nuevo.';
    return switch (e.code) {
      // Supabase answers otp_expired for a wrong code too.
      'otp_expired' => 'El código no es correcto o ya venció. Pide uno nuevo.',
      // shouldCreateUser: false + an email without an account. Saying so
      // reveals which emails are registered; chosen for clarity here.
      'otp_disabled' || 'user_not_found' => 'No hay una cuenta con ese correo. Regístrate primero.',
      'over_email_send_rate_limit' ||
      'over_request_rate_limit' => 'Ya te enviamos un código hace poco. Espera un momento.',
      'email_address_invalid' || 'validation_failed' => 'Ese correo no es válido.',
      _ => e.message,
    };
  }

  Future<void> changePassword(String newPassword) async {
    try {
      await _remoteDataSource.updatePassword(newPassword);
    } on AuthException catch (e) {
      throw AppException(e.message);
    }
  }

  Future<void> signOut() async {
    await _remoteDataSource.signOut();
    await _localDataSource.clear();
  }
}
