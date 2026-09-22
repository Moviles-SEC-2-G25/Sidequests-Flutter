/// One row returned by the shared `public.recommend_quests` RPC (BQ5).
/// Ranking logic lives in the backend so it is not duplicated per client.
class QuestRecommendation {
  final String questId;
  final double score;
  final bool timeMatch;
  final bool interestMatch;
  final bool socialMatch;
  final bool locationMatch;

  const QuestRecommendation({
    required this.questId,
    required this.score,
    required this.timeMatch,
    required this.interestMatch,
    required this.socialMatch,
    required this.locationMatch,
  });

  factory QuestRecommendation.fromJson(Map<String, dynamic> json) =>
      QuestRecommendation(
        questId: json['quest_id'] as String,
        score: (json['score'] as num).toDouble(),
        timeMatch: json['time_match'] as bool? ?? false,
        interestMatch: json['interest_match'] as bool? ?? false,
        socialMatch: json['social_match'] as bool? ?? false,
        locationMatch: json['location_match'] as bool? ?? false,
      );
}
