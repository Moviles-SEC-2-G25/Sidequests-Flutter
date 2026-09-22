import 'package:supabase_flutter/supabase_flutter.dart';

import '../../analytics/analytics_event_sink.dart';

/// Single wrapper around the Supabase project: auth, REST (PostgREST) and
/// RPC today; realtime and edge functions are consumed here too once the
/// backend ships them (see Sidequests-Backend README — both are still
/// {planned} there).
class SupabaseRemoteDataSource implements AnalyticsEventSink {
  final SupabaseClient _client;

  SupabaseRemoteDataSource(this._client);

  GoTrueClient get auth => _client.auth;

  Session? get currentSession => _client.auth.currentSession;

  String? get currentUserEmail => _client.auth.currentUser?.email;

  Stream<AuthState> get authStateChanges => _client.auth.onAuthStateChange;

  Future<AuthResponse> signUp({
    required String email,
    required String password,
  }) => _client.auth.signUp(email: email, password: password);

  Future<AuthResponse> signIn({
    required String email,
    required String password,
  }) => _client.auth.signInWithPassword(email: email, password: password);

  Future<void> signOut() => _client.auth.signOut();

  Future<Map<String, dynamic>> getProfile(String userId) => _client
      .from('profiles')
      .select()
      .eq('id', userId)
      .single();

  Future<void> upsertProfile(Map<String, dynamic> profile) =>
      _client.from('profiles').upsert(profile);

  Future<Map<String, dynamic>> getPreferences(String userId) => _client
      .from('user_preferences')
      .select()
      .eq('user_id', userId)
      .single();

  Future<void> upsertPreferences(Map<String, dynamic> preferences) =>
      _client.from('user_preferences').upsert(preferences);

  Future<List<Map<String, dynamic>>> getActiveQuests() async {
    final rows = await _client.from('quests').select().eq('is_active', true);
    return (rows as List).cast<Map<String, dynamic>>();
  }

  Future<List<Map<String, dynamic>>> getQuestSteps(String questId) async {
    final rows = await _client
        .from('quest_steps')
        .select()
        .eq('quest_id', questId)
        .order('step_order');
    return (rows as List).cast<Map<String, dynamic>>();
  }

  /// `recommend_quests` (BQ5). `excludedQuestIds` implements the immediate
  /// session-level "not for me" exclusion added in migration 007 — quests
  /// the user just skipped shouldn't be re-recommended in the same session.
  Future<List<Map<String, dynamic>>> recommendQuests({
    required int availableMinutes,
    required String socialLevel,
    List<String> interests = const [],
    String locationMode = 'all',
    List<String> excludedQuestIds = const [],
    int limit = 3,
  }) async {
    final rows = await _client.rpc(
      'recommend_quests',
      params: {
        'p_available_minutes': availableMinutes,
        'p_social_level': socialLevel,
        'p_interests': interests,
        'p_location_mode': locationMode,
        'p_excluded_quest_ids': excludedQuestIds,
        'p_limit': limit,
      },
    );
    return (rows as List).cast<Map<String, dynamic>>();
  }

  Future<List<Map<String, dynamic>>> getUserQuests(String userId) async {
    final rows = await _client
        .from('user_quests')
        .select()
        .eq('user_id', userId)
        .order('updated_at', ascending: false);
    return (rows as List).cast<Map<String, dynamic>>();
  }

  Future<Map<String, dynamic>> upsertUserQuest(
    Map<String, dynamic> userQuest,
  ) => _client.from('user_quests').upsert(userQuest).select().single();

  /// `analytics_events.user_id` is NOT NULL and RLS requires it to equal
  /// `auth.uid()`, so it must be stamped from the active session here rather
  /// than trusted from the caller. Silently skips if there is no session —
  /// there's nothing to attribute the event to and the insert would be
  /// rejected by RLS anyway.
  @override
  Future<void> insertAnalyticsEvent(Map<String, dynamic> event) async {
    final userId = _client.auth.currentUser?.id;
    if (userId == null) return;
    await _client.from('analytics_events').insert({...event, 'user_id': userId});
  }
}
