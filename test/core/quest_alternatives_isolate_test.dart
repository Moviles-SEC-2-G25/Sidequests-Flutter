import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sidequests/core/quest_alternative_recommender.dart';
import 'package:sidequests/models/abandonment_reason.dart';
import 'package:sidequests/models/app_context.dart';
import 'package:sidequests/models/quest.dart';
import 'package:sidequests/models/user_preferences.dart';

/// Multithreading strategy: the alternatives after abandoning are computed on
/// a background isolate with compute(). These run a real isolate (plain
/// test(), not testWidgets) to prove the input crosses it and the answer is
/// the same as on the UI isolate.

Quest _quest(
  String id, {
  int minutes = 20,
  double cost = 0,
  String location = 'anywhere',
  List<String> tags = const [],
  double? latitude,
  double? longitude,
}) => Quest(
  id: id,
  title: id,
  category: 'test',
  durationMinutes: minutes,
  estimatedCost: cost,
  difficulty: 'easy',
  locationMode: location,
  socialLevel: 'solo',
  latitude: latitude,
  longitude: longitude,
  tags: tags,
);

QuestAlternativesInput _input({
  AbandonmentReason reason = AbandonmentReason.ranOutOfTime,
  Set<String> excluded = const {},
}) => QuestAlternativesInput(
  catalog: [
    for (var i = 0; i < 200; i++)
      _quest(
        'q$i',
        minutes: 5 + i % 50,
        cost: (i % 7).toDouble(),
        location: i.isEven ? 'anywhere' : 'gps',
        tags: i % 3 == 0 ? const ['indoor', 'calm'] : const ['outdoor'],
        latitude: i.isEven ? null : 4.6 + i / 10000,
        longitude: i.isEven ? null : -74.07,
      ),
  ],
  abandonedQuest: _quest('source', minutes: 60, cost: 14, location: 'gps', latitude: 4.7, longitude: -74.07),
  reason: reason,
  context: const AppContext(
    timeOfDay: 'evening',
    dayOfWeek: 'friday',
    isConnected: true,
    weatherCode: 61,
    isRainy: true,
    latitude: 4.6,
    longitude: -74.07,
  ),
  availableMinutes: 45,
  preferences: const UserPreferences(),
  excludedIds: excluded,
);

String _describe(List<QuestAlternative> alternatives) => [
  for (final alternative in alternatives)
    '${alternative.quest.id}:${alternative.score}:${alternative.ruleCodes.join(',')}',
].join(' | ');

void main() {
  test('compute() on a background isolate gives the same top 3 as the UI isolate', () async {
    for (final reason in AbandonmentReason.values) {
      final input = _input(reason: reason);

      final inBackground = await compute(computeQuestAlternatives, input);

      expect(_describe(inBackground), _describe(computeQuestAlternatives(input)), reason: reason.code);
      expect(inBackground.length, lessThanOrEqualTo(3));
    }
  });

  test('the excluded quests stay excluded across the isolate', () async {
    final first = await compute(computeQuestAlternatives, _input());
    final excluded = first.map((a) => a.quest.id).toSet();

    final next = await compute(computeQuestAlternatives, _input(excluded: excluded));

    expect(next, isNotEmpty);
    expect(next.map((a) => a.quest.id).toSet().intersection(excluded), isEmpty);
  });
}
