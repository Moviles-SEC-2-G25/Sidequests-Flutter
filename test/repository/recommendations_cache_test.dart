import 'package:flutter_test/flutter_test.dart';
import 'package:sidequests/data/cache/memory_cache.dart';
import 'package:sidequests/data/local/local_data_source.dart';
import 'package:sidequests/data/remote/network_guard.dart';
import 'package:sidequests/data/remote/supabase_remote_data_source.dart';
import 'package:sidequests/models/app_context.dart';
import 'package:sidequests/models/quest_recommendation.dart';
import 'package:sidequests/models/user_preferences.dart';
import 'package:sidequests/repository/quest_repository.dart';

class _FakeRemote implements SupabaseRemoteDataSource {
  int calls = 0;
  bool offline = false;

  @override
  Future<List<Map<String, dynamic>>> recommendQuests({
    required int availableMinutes,
    required String socialLevel,
    List<String> interests = const [],
    String locationMode = 'all',
    List<String> excludedQuestIds = const [],
    int limit = 3,
  }) async {
    calls++;
    if (offline) throw Exception('Failed host lookup');
    return [
      for (final id in ['a', 'b'])
        if (!excludedQuestIds.contains(id)) {'quest_id': id, 'score': 1.0},
    ];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeLocal implements LocalDataSource {
  List<Map<String, dynamic>> attempts = [];

  @override
  Future<void> saveRecommendations(String batchId, List<Map<String, dynamic>> rows) async {}

  @override
  ({String batchId, List<Map<String, dynamic>> rows})? getSavedRecommendations() => null;

  @override
  List<Map<String, dynamic>> getUserQuests() => attempts;

  // Steps already cached: no prefetch requests.
  @override
  List<Map<String, dynamic>>? getQuestSteps(String questId) => const [];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _context = AppContext(timeOfDay: 'afternoon', dayOfWeek: 'friday', isConnected: true, availableMinutes: 30);

/// Smart Picks' LRU with TTL (mirror of the Kotlin app's
/// CachedRecommendationRepositoryTest).
void main() {
  late _FakeRemote remote;
  late _FakeLocal local;
  late DateTime now;
  late MemoryCache<String, RecommendationBatch> cache;
  late QuestRepository repository;
  var nextId = 0;

  setUp(() {
    remote = _FakeRemote();
    local = _FakeLocal();
    now = DateTime(2026, 11, 27, 15);
    cache = MemoryCache(
      ttl: QuestRepository.recommendationsCacheTtl,
      maxEntries: 2,
      now: () => now,
    );
    repository = QuestRepository(
      remote,
      local,
      newId: () => 'batch-${++nextId}',
      network: const NetworkGuard(),
      recommendationsCache: cache,
    );
  });

  Future<RecommendationBatch> recommend({int minutes = 30, String social = 'solo'}) =>
      repository.getRecommendations(
        context: AppContext(
          timeOfDay: 'afternoon',
          dayOfWeek: 'friday',
          isConnected: true,
          availableMinutes: minutes,
        ),
        preferences: UserPreferences(socialLevel: social, interests: const ['food', 'art']),
      );

  test('the same request within the TTL is served from memory, with no network call', () async {
    final first = await recommend();
    final second = await recommend();

    expect(remote.calls, 1);
    expect(first.source, RecommendationSource.network);
    expect(second.source, RecommendationSource.memory);
    expect(second.batchId, first.batchId);
    expect(second.alreadyShown, isTrue);
    expect(second.fromCache, isFalse);
  });

  test('past the TTL the server is asked again', () async {
    await recommend();
    now = now.add(const Duration(minutes: 11));

    final again = await recommend();

    expect(remote.calls, 2);
    expect(again.source, RecommendationSource.network);
  });

  test('another request (other time or social level) is a miss', () async {
    await recommend();
    await recommend(minutes: 60);
    await recommend(social: 'group');

    expect(remote.calls, 3);
  });

  test('past the size limit the least recently used request is evicted', () async {
    await recommend(minutes: 10);
    await recommend(minutes: 20);
    await recommend(minutes: 10); // hit: 10 becomes the most recent
    await recommend(minutes: 30); // evicts 20

    await recommend(minutes: 10);
    expect(remote.calls, 3);
    await recommend(minutes: 20);
    expect(remote.calls, 4);
  });

  test('offline, an expired answer to the same request comes back (stale-if-error)', () async {
    final first = await recommend();
    now = now.add(const Duration(minutes: 30));
    remote.offline = true;

    final stale = await recommend();

    expect(stale.source, RecommendationSource.staleMemory);
    expect(stale.fromCache, isTrue);
    expect(stale.batchId, first.batchId);
    expect(stale.recommendations.map((r) => r.questId), ['a', 'b']);
  });

  test('a quest started since the answer was cached is left out', () async {
    await recommend();
    local.attempts = [
      {'quest_id': 'a', 'status': 'accepted'},
    ];

    final cached = await recommend();

    expect(cached.source, RecommendationSource.memory);
    expect(cached.recommendations.map((r) => r.questId), ['b']);
  });

  test('sign-out empties it: the next account asks the server', () async {
    await recommend();
    cache.clear();

    await recommend();

    expect(remote.calls, 2);
  });

  test('the context availableMinutes is what keys the request', () async {
    await repository.getRecommendations(context: _context, preferences: const UserPreferences());
    await repository.getRecommendations(context: _context, preferences: const UserPreferences());

    expect(remote.calls, 1);
  });
}
