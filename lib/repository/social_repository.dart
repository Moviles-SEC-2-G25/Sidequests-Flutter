import '../core/app_exception.dart';

/// Single source of truth for the social feed: friends, friend requests and
/// group challenges. {planned} on the backend — Sidequests-Backend has no
/// `friends`/`group_challenges` tables yet and Realtime is not enabled
/// (see Sidequests-Backend/supabase/migrations). This stub keeps the
/// Repository/ViewModel/View slots wired the same way as the other domains
/// so the feature can be filled in without touching the layers above it.
class SocialRepository {
  Future<List<Never>> getFriends() async {
    throw const AppException('Social feed is not available yet.');
  }

  Future<List<Never>> getGroupChallenges() async {
    throw const AppException('Group challenges are not available yet.');
  }
}
