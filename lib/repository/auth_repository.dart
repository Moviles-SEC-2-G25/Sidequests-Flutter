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

  bool get isAuthenticated => currentUser != null;

  Stream<AuthState> get authStateChanges => _remoteDataSource.authStateChanges;

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

  Future<void> signOut() async {
    await _remoteDataSource.signOut();
    await _localDataSource.clear();
  }
}
