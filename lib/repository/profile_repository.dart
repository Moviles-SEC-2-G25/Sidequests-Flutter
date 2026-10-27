import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/app_exception.dart';
import '../data/local/local_data_source.dart';
import '../data/remote/supabase_remote_data_source.dart';
import '../models/profile.dart';
import '../models/user_preferences.dart';

/// Single source of truth for the signed-in user's profile and preferences.
class ProfileRepository {
  final SupabaseRemoteDataSource _remoteDataSource;
  final LocalDataSource _localDataSource;

  static const _offlineMessage =
      'Sin conexión y sin datos guardados en el teléfono. Reintenta cuando tengas internet.';

  ProfileRepository(this._remoteDataSource, this._localDataSource);

  /// Falls back to the cache when the network is unavailable.
  Future<Profile> getProfile(String userId) async {
    try {
      final json = await _remoteDataSource.getProfile(userId);
      await _localDataSource.cacheProfile(json);
      return Profile.fromJson(json);
    } catch (error) {
      final cached = _localDataSource.getProfile();
      if (cached != null) return Profile.fromJson(cached);
      throw error is PostgrestException
          ? AppException(error.message)
          : const AppException(_offlineMessage, isRetryable: true);
    }
  }

  Future<void> updateProfile(Profile profile) async {
    try {
      await _remoteDataSource.upsertProfile(profile.toJson());
      // toJson() leaves out created_at: keep the cached one.
      await _localDataSource.cacheProfile({
        ...?_localDataSource.getProfile(),
        ...profile.toJson(),
      });
    } on PostgrestException catch (e) {
      throw AppException(e.message);
    }
  }

  /// Falls back to the cache when the network is unavailable.
  Future<UserPreferences> getPreferences(String userId) async {
    try {
      final json = await _remoteDataSource.getPreferences(userId);
      await _localDataSource.cachePreferences(json);
      return UserPreferences.fromJson(json);
    } catch (_) {
      final cached = _localDataSource.getPreferences();
      if (cached != null) return UserPreferences.fromJson(cached);
      return const UserPreferences();
    }
  }

  Future<void> updatePreferences(String userId, UserPreferences preferences) async {
    final json = {'user_id': userId, ...preferences.toJson()};
    try {
      await _remoteDataSource.upsertPreferences(json);
      await _localDataSource.cachePreferences(json);
    } on PostgrestException catch (e) {
      throw AppException(e.message);
    }
  }
}
