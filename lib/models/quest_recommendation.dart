/// One row returned by the shared `public.recommend_quests` RPC (BQ5).
/// Ranking logic lives in the backend so it is not duplicated per client.
class QuestRecommendation {
  final String questId;
  final double score;
  final bool timeMatch;
  final bool interestMatch;
  final bool socialMatch;
  final bool locationMatch;

  /// BQ8 A/B arm assigned by the server: 'control' | 'diverse'.
  final String variant;

  /// 1-based position of this row in the returned list.
  final int rankPosition;
  final String? category;

  const QuestRecommendation({
    required this.questId,
    required this.score,
    required this.timeMatch,
    required this.interestMatch,
    required this.socialMatch,
    required this.locationMatch,
    this.variant = 'control',
    this.rankPosition = 0,
    this.category,
  });

  factory QuestRecommendation.fromJson(Map<String, dynamic> json) =>
      QuestRecommendation(
        questId: json['quest_id'] as String,
        score: (json['score'] as num).toDouble(),
        timeMatch: json['time_match'] as bool? ?? false,
        interestMatch: json['interest_match'] as bool? ?? false,
        socialMatch: json['social_match'] as bool? ?? false,
        locationMatch: json['location_match'] as bool? ?? false,
        variant: json['variant'] as String? ?? 'control',
        rankPosition: (json['rank_position'] as num?)?.toInt() ?? 0,
        category: json['category'] as String?,
      );
}

/// Where a [RecommendationBatch] came from (shown on the Smart Picks section,
/// as in the Kotlin app).
enum RecommendationSource {
  /// A new answer from `recommend_quests`.
  network,

  /// The same request answered by the server less than 10 minutes ago, from
  /// the in-memory LRU: no network call.
  memory,

  /// The network failed: an older answer to the same request, from memory.
  staleMemory,

  /// The network failed: the last list saved on the device.
  saved,
}

/// One list from `recommend_quests`, or the last one saved on the device.
class RecommendationBatch {
  final List<QuestRecommendation> recommendations;

  /// Groups the BQ8 events of this list; a saved list keeps its original one.
  final String batchId;

  final RecommendationSource source;

  const RecommendationBatch({
    required this.recommendations,
    required this.batchId,
    bool fromCache = false,
    RecommendationSource? source,
  }) : source = source ?? (fromCache ? RecommendationSource.saved : RecommendationSource.network);

  /// True when the network failed and this list was already shown (and its
  /// `recommendation_shown` events logged) when it was first answered.
  bool get fromCache =>
      source == RecommendationSource.saved || source == RecommendationSource.staleMemory;

  /// This list's `recommendation_shown` events were already logged: only a
  /// new answer from the server logs them (BQ8 impressions).
  bool get alreadyShown => source != RecommendationSource.network;
}
