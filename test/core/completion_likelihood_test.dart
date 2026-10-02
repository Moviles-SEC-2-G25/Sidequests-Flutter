import 'package:flutter_test/flutter_test.dart';
import 'package:sidequests/core/completion_likelihood.dart';
import 'package:sidequests/models/quest.dart';
import 'package:sidequests/models/user_quest.dart';

Quest _quest(String id, {String category = 'food'}) => Quest(
  id: id,
  title: 'Quest $id',
  category: category,
  durationMinutes: 30,
  difficulty: 'easy',
  locationMode: 'anywhere',
  socialLevel: 'solo',
);

var _userQuestCounter = 0;

UserQuest _userQuest(String questId, String status) => UserQuest(
  id: 'uq-${_userQuestCounter++}',
  userId: 'user-1',
  questId: questId,
  status: status,
  acceptedAt: DateTime(2026, 1, 1),
);

/// [statuses.length] attempts on distinct 'food' quests, one per status.
/// Returns the catalog and history together so each test reads as
/// "this is my food history".
(List<Quest>, List<UserQuest>) _history(List<String> statuses, {String category = 'food'}) {
  final catalog = <Quest>[];
  final userQuests = <UserQuest>[];
  for (var i = 0; i < statuses.length; i++) {
    final quest = _quest('$category-$i', category: category);
    catalog.add(quest);
    userQuests.add(_userQuest(quest.id, statuses[i]));
  }
  return (catalog, userQuests);
}

void main() {
  const likelihood = CompletionLikelihood();
  final foodQuest = _quest('food-target', category: 'food');

  CompletionLevel levelOf(List<String> statuses) {
    final (catalog, userQuests) = _history(statuses);
    return likelihood.levelFor(foodQuest, likelihood.byCategory(catalog, userQuests));
  }

  test('historial vacío: empty map and every quest is "Nueva para ti"', () {
    final byCategory = likelihood.byCategory([foodQuest], []);

    expect(byCategory, isEmpty);
    expect(likelihood.levelFor(foodQuest, byCategory), CompletionLevel.newForYou);
  });

  test('2 de 2 completadas (100%) is still "Nueva para ti" — fewer than 3 attempts', () {
    expect(levelOf(['completed', 'completed']), CompletionLevel.newForYou);
  });

  test('exactly 3 attempts is enough to get a level', () {
    expect(levelOf(['completed', 'completed', 'completed']), CompletionLevel.high);
  });

  test('7 de 10 (exactly 0.7) is Alta', () {
    expect(levelOf([...List.filled(7, 'completed'), ...List.filled(3, 'abandoned')]), CompletionLevel.high);
  });

  test('2 de 3 (0.67) is Media', () {
    expect(levelOf(['completed', 'completed', 'abandoned']), CompletionLevel.medium);
  });

  test('2 de 5 (exactly 0.4) is Media', () {
    expect(levelOf(['completed', 'completed', 'abandoned', 'abandoned', 'abandoned']), CompletionLevel.medium);
  });

  test('1 de 3 and 0 de 3 are Baja', () {
    expect(levelOf(['completed', 'abandoned', 'abandoned']), CompletionLevel.low);
    expect(levelOf(['abandoned', 'abandoned', 'abandoned']), CompletionLevel.low);
  });

  test('skipped rows are not attempts', () {
    // 2 real attempts + 1 skipped => still below the 3-attempt minimum.
    expect(levelOf(['completed', 'completed', 'skipped']), CompletionLevel.newForYou);
    // 3/3 completed; the 5 skips don't drag the rate down to 3/8.
    expect(
      levelOf([...List.filled(3, 'completed'), ...List.filled(5, 'skipped')]),
      CompletionLevel.high,
    );
  });

  test('accepted and in_progress quests count as attempts (BQ9 formula)', () {
    // 2 completed / 3 attempts = 0.67 while the third is still open.
    expect(levelOf(['completed', 'completed', 'in_progress']), CompletionLevel.medium);
    expect(levelOf(['completed', 'completed', 'accepted']), CompletionLevel.medium);
  });

  test('categories are independent: a strong food history says nothing about art', () {
    final (catalog, userQuests) = _history(['completed', 'completed', 'completed']);
    final artQuest = _quest('art-target', category: 'art');

    final byCategory = likelihood.byCategory([...catalog, artQuest], userQuests);

    expect(likelihood.levelFor(foodQuest, byCategory), CompletionLevel.high);
    expect(likelihood.levelFor(artQuest, byCategory), CompletionLevel.newForYou);
  });

  test('category matching is case-insensitive', () {
    final catalog = [
      _quest('a', category: 'Food'),
      _quest('b', category: 'food'),
      _quest('c', category: 'FOOD'),
    ];
    final userQuests = [
      _userQuest('a', 'completed'),
      _userQuest('b', 'completed'),
      _userQuest('c', 'completed'),
    ];

    final byCategory = likelihood.byCategory(catalog, userQuests);

    expect(byCategory, {'food': CompletionLevel.high});
    expect(likelihood.levelFor(_quest('d', category: 'FoOd'), byCategory), CompletionLevel.high);
  });

  test('user_quests whose quest is not in the catalog are ignored without throwing', () {
    final (catalog, userQuests) = _history(['completed', 'completed']);
    final withOrphan = [...userQuests, _userQuest('deleted-quest', 'abandoned')];

    // The orphan doesn't become the 3rd food attempt.
    expect(
      likelihood.levelFor(foodQuest, likelihood.byCategory(catalog, withOrphan)),
      CompletionLevel.newForYou,
    );
  });

  test('empty catalog with history: empty map without throwing', () {
    final (_, userQuests) = _history(['completed', 'completed', 'completed']);

    expect(likelihood.byCategory([], userQuests), isEmpty);
  });

  test('statsByCategory keeps the raw counts, including categories below 3 attempts', () {
    final (food, foodHistory) = _history(['completed', 'completed', 'abandoned', 'skipped']);
    final (art, artHistory) = _history(['completed'], category: 'art');

    final stats = likelihood.statsByCategory([...food, ...art], [...foodHistory, ...artHistory]);

    expect(stats.keys.toSet(), {'food', 'art'});
    expect(stats['food']!.attempts, 3); // the skip doesn't count
    expect(stats['food']!.completed, 2);
    expect(stats['food']!.rate, closeTo(0.667, 0.001));
    expect(stats['art']!.attempts, 1);
    // byCategory still hides the under-3 category (Explore shows "Nueva para ti").
    expect(likelihood.byCategory([...food, ...art], [...foodHistory, ...artHistory]).keys, ['food']);
  });

  test('levelOf: "Nueva para ti" below 3 attempts, otherwise the same thresholds', () {
    const fewAttempts = CategoryCompletion(category: 'art', attempts: 2, completed: 2);
    const enough = CategoryCompletion(category: 'art', attempts: 10, completed: 7);

    expect(likelihood.levelOf(fewAttempts), CompletionLevel.newForYou);
    expect(likelihood.levelOf(enough), CompletionLevel.high);
  });
}
