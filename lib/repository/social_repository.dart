import '../core/app_exception.dart';

/// Single source of truth for the friends feed (friends, friend requests,
/// their shared photos). {planned} on the backend — Sidequests-Backend has no
/// `friends` tables yet and Realtime is not enabled (see
/// Sidequests-Backend/supabase/migrations). This stub keeps the
/// Repository/ViewModel/View slots wired the same way as the other domains
/// so the feature can be filled in without touching the layers above it.
///
/// Group challenges do exist on the backend (migration 011) and live in
/// GroupChallengeRepository.
class SocialRepository {
  Future<List<Never>> getFriends() async {
    throw const AppException('Social feed is not available yet.');
  }
}
