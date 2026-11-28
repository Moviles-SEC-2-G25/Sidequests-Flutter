import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/app_exception.dart';
import '../core/memo.dart';
import '../data/local/local_data_source.dart';
import '../data/local/step_log_database.dart';
import '../data/offline/offline_pack_manager.dart';
import '../data/remote/network_guard.dart';
import '../data/remote/supabase_remote_data_source.dart';

/// Single source of truth for the current session.
class AuthRepository {
  /// gotrue has no timeout of its own: on a network that doesn't answer, a
  /// sign-in would spin forever. Longer than NetworkGuard.timeout, since a
  /// sign-in on a slow connection is worth waiting a little more for.
  static const requestTimeout = Duration(seconds: 15);

  static const _connectionMessage =
      'Could not connect. Check your internet connection and try again.';

  final SupabaseRemoteDataSource _remoteDataSource;
  final LocalDataSource _localDataSource;
  final StepLogDatabase? _stepLog;

  /// In-memory caches of this account's data, emptied with the rest.
  final List<SessionCache> _sessionCaches;

  /// The offline pack's manifest is this account's choice too.
  final OfflinePackManager? _offlinePack;

  AuthRepository(
    this._remoteDataSource,
    this._localDataSource, {
    StepLogDatabase? stepLog,
    List<SessionCache> sessionCaches = const [],
    OfflinePackManager? offlinePack,
  }) : _stepLog = stepLog,
       _sessionCaches = sessionCaches,
       _offlinePack = offlinePack;

  User? get currentUser => _remoteDataSource.currentSession?.user;

  String? get currentUserEmail => _remoteDataSource.currentUserEmail;

  /// Local: the session supabase_flutter restored from disk at startup, even
  /// if its token expired. Refreshing it happens apart and can fail offline.
  bool get isAuthenticated => currentUser != null;

  Stream<AuthState> get authStateChanges => _remoteDataSource.authStateChanges;

  bool get isBiometricEnabled => _localDataSource.isBiometricEnabled();

  Future<void> setBiometricEnabled(bool value) =>
      _localDataSource.setBiometricEnabled(value);

  Future<void> signUp({required String email, required String password}) =>
      _authCall(() => _remoteDataSource.signUp(email: email, password: password));

  Future<void> signIn({required String email, required String password}) =>
      _authCall(() => _remoteDataSource.signIn(email: email, password: password));

  /// Passwordless sign-in, step 1: email a 6-digit code.
  Future<void> sendLoginCode(String email) async {
    try {
      await _remoteDataSource.sendEmailOtp(email).timeout(requestTimeout);
    } on AuthException catch (e) {
      throw AppException(_loginCodeMessage(e), isRetryable: e is AuthRetryableFetchException);
    } on TimeoutException {
      throw const AppException('Offline. Try again.', isRetryable: true);
    }
  }

  /// Step 2: exchange the code for a session.
  Future<void> verifyLoginCode({required String email, required String code}) async {
    try {
      await _remoteDataSource.verifyEmailOtp(email: email, token: code).timeout(requestTimeout);
    } on AuthException catch (e) {
      throw AppException(_loginCodeMessage(e), isRetryable: e is AuthRetryableFetchException);
    } on TimeoutException {
      throw const AppException('Offline. Try again.', isRetryable: true);
    }
  }

  /// Supabase's messages are English and don't say what to do next.
  String _loginCodeMessage(AuthException e) {
    if (e is AuthRetryableFetchException) return 'Offline. Try again.';
    return switch (e.code) {
      // Supabase answers otp_expired for a wrong code too.
      'otp_expired' => 'The code is incorrect or has expired. Request a new one.',
      // shouldCreateUser: false + an email without an account. Saying so
      // reveals which emails are registered; chosen for clarity here.
      'otp_disabled' || 'user_not_found' => 'There is no account with that email. Sign up first.',
      'over_email_send_rate_limit' ||
      'over_request_rate_limit' => 'We just sent you a code. Please wait a moment.',
      'email_address_invalid' || 'validation_failed' => 'That email is not valid.',
      _ => e.message,
    };
  }

  Future<void> changePassword(String newPassword) =>
      _authCall(() => _remoteDataSource.updatePassword(newPassword));

  /// A gotrue call with a time limit. No answer (offline, timeout) becomes a
  /// retryable AppException with a message the user can act on, instead of
  /// gotrue's raw "ClientException with SocketException…".
  Future<void> _authCall(Future<Object?> Function() call) async {
    try {
      await call().timeout(requestTimeout);
    } on AuthRetryableFetchException {
      throw const AppException(_connectionMessage, isRetryable: true);
    } on AuthException catch (e) {
      throw AppException(e.message);
    } on TimeoutException {
      throw const AppException(_connectionMessage, isRetryable: true);
    }
  }

  /// The session ended without [signOut] (token rejected by the server): same
  /// cleanup, so the next account doesn't inherit this one's data or queues.
  Future<void> clearLocalData() async {
    await _localDataSource.clear();
    await _clearOfflinePack();
    _clearSessionCaches();
    await _clearStepLog();
  }

  /// Never keeps anyone signed in: the store already swallows file errors.
  Future<void> _clearOfflinePack() async {
    try {
      await _offlinePack?.clear();
    } catch (error) {
      debugPrint('Offline pack: not cleared ($error)');
    }
  }

  void _clearSessionCaches() {
    for (final cache in _sessionCaches) {
      cache.clear();
    }
  }

  /// The walks are this account's too. A failure must not keep anyone signed
  /// in, so it's only logged.
  Future<void> _clearStepLog() async {
    try {
      await _stepLog?.clear();
    } catch (error) {
      debugPrint('Step log: not cleared ($error)');
    }
  }

  /// gotrue drops the local session first and only then tells the server, so
  /// a failure there (no connection) means the user is already out: the cache
  /// must still go, or the next account would inherit it. The server call is
  /// time-limited so signing out never hangs on a network that doesn't answer.
  Future<void> signOut() async {
    try {
      await _remoteDataSource.signOut().timeout(NetworkGuard.timeout);
    } catch (_) {
      // The token isn't revoked on the server; it just expires on its own.
    }
    await _localDataSource.clear();
    await _clearOfflinePack();
    _clearSessionCaches();
    await _clearStepLog();
  }
}
