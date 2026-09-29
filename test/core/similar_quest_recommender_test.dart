import 'package:flutter_test/flutter_test.dart';
import 'package:sidequests/core/similar_quest_recommender.dart';
import 'package:sidequests/models/quest.dart';
import 'package:sidequests/models/user_quest.dart';

Quest _quest(
  String id, {
  String category = 'food',
  int durationMinutes = 30,
  String difficulty = 'easy',
  List<String> tags = const [],
}) => Quest(
  id: id,
  title: 'Quest $id',
  category: category,
  durationMinutes: durationMinutes,
  difficulty: difficulty,
  locationMode: 'anywhere',
  socialLevel: 'solo',
  tags: tags,
);

UserQuest _userQuest(String questId, String status) => UserQuest(
  id: 'uq-$questId',
  userId: 'user-1',
  questId: questId,
  status: status,
  acceptedAt: DateTime(2026, 1, 1),
);

void main() {
  const recommender = SimilarQuestRecommender();
  final completed = _quest(
    'completed',
    category: 'food',
    durationMinutes: 30,
    difficulty: 'easy',
    tags: ['outdoor', 'cheap'],
  );

  // Same category (+3 unless rating low), no shared tags, far duration
  // (diff 60 > 15), different difficulty.
  final sameCategoryOnly = _quest(
    'same-category',
    category: 'food',
    durationMinutes: 90,
    difficulty: 'hard',
  );
  // Different category, both tags shared (+2), close duration (+2), same
  // difficulty (+1) => the strongest match regardless of rating.
  final strongMatch = _quest(
    'strong-match',
    category: 'art',
    durationMinutes: 35,
    difficulty: 'easy',
    tags: ['outdoor', 'cheap'],
  );
  // Different category, no tags, close duration (+2), different difficulty.
  final weakMatch = _quest('weak-match', category: 'sport', durationMinutes: 25, difficulty: 'medium');

  test('rating alto (5): same-category candidate scores +3 and outranks a weaker match', () {
    final catalog = [sameCategoryOnly, strongMatch, weakMatch];

    // maxMinutes 100: sameCategoryOnly's own 90-minute duration must not be
    // hard-excluded — this test is about the score, not the minutes filter.
    final result = recommender.recommend(completed, catalog, [], 5, 100);

    // strongMatch: 0(cat) + 2(tags) + 2(duration) + 1(difficulty) = 5
    // sameCategoryOnly: 3(cat) + 0 + 0 + 0 = 3
    // weakMatch: 0 + 0 + 2(duration) + 0 = 2
    expect(result.map((q) => q.id), ['strong-match', 'same-category', 'weak-match']);
  });

  test(
    'rating bajo (2): same category flips to -3, dropping that candidate below weaker matches',
    () {
      final catalog = [sameCategoryOnly, strongMatch, weakMatch];

      final result = recommender.recommend(completed, catalog, [], 2, 100);

      // strongMatch: 5 (category doesn't match completed, unaffected)
      // weakMatch: 2
      // sameCategoryOnly: -3(cat) + 0 + 0 + 0 = -3
      expect(result.map((q) => q.id), ['strong-match', 'weak-match', 'same-category']);
    },
  );

  test('catálogo vacío: returns an empty list without throwing', () {
    expect(recommender.recommend(completed, [], [], 5, 60), isEmpty);
  });

  test('excludes the completed quest itself, completed quests and quests in progress', () {
    final inProgress = _quest('in-progress');
    final alreadyCompleted = _quest('already-completed');
    final catalog = [completed, inProgress, alreadyCompleted, weakMatch];
    final userQuests = [
      _userQuest('in-progress', 'in_progress'),
      _userQuest('already-completed', 'completed'),
    ];

    final result = recommender.recommend(completed, catalog, userQuests, 5, 60);

    expect(result.map((q) => q.id), ['weak-match']);
  });

  test('an accepted-but-not-started quest is also excluded', () {
    final accepted = _quest('accepted-quest');
    final result = recommender.recommend(completed, [
      accepted,
    ], [_userQuest('accepted-quest', 'accepted')], 5, 60);

    expect(result, isEmpty);
  });

  test('an abandoned quest is not excluded — it can be suggested again', () {
    final abandoned = _quest('abandoned-quest', category: 'food');
    final result = recommender.recommend(completed, [
      abandoned,
    ], [_userQuest('abandoned-quest', 'abandoned')], 5, 60);

    expect(result.map((q) => q.id), ['abandoned-quest']);
  });

  test('hard-excludes quests longer than maxMinutes', () {
    final tooLong = _quest('too-long', durationMinutes: 90);
    final fits = _quest('fits', durationMinutes: 20);

    final result = recommender.recommend(completed, [tooLong, fits], [], 5, 30);

    expect(result.map((q) => q.id), ['fits']);
  });

  test('returns only the top 3, ties broken by shorter duration', () {
    // None share completed's category/tags/difficulty, and all four
    // durations are >15 min away from completed's 30, so every candidate
    // scores exactly 0 — the only thing left to sort by is duration.
    final catalog = [
      _quest('d-300', category: 'x', durationMinutes: 300, difficulty: 'z'),
      _quest('d-100', category: 'x', durationMinutes: 100, difficulty: 'z'),
      _quest('d-200', category: 'x', durationMinutes: 200, difficulty: 'z'),
      _quest('d-150', category: 'x', durationMinutes: 150, difficulty: 'z'),
    ];

    final result = recommender.recommend(completed, catalog, [], 5, 400);

    expect(result.map((q) => q.id), ['d-100', 'd-150', 'd-200']);
  });
}
