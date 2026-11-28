import 'package:flutter_test/flutter_test.dart';
import 'package:sidequests/core/smart/smart_difficulty_advisor.dart';
import 'package:sidequests/models/abandonment_reason.dart';

DifficultyOutcome _done(String difficulty) => DifficultyOutcome(difficulty: difficulty, completed: true);

DifficultyOutcome _left(String difficulty, AbandonmentReason reason) =>
    DifficultyOutcome(difficulty: difficulty, completed: false, reason: reason);

/// Same cases as the Kotlin app's SmartDifficultyAdvisorTest.
void main() {
  test('two difficulty-related abandons suggest an easier level', () {
    final history = [
      _done('medium'),
      _left('medium', AbandonmentReason.tooDifficult),
      _left('medium', AbandonmentReason.ranOutOfTime),
    ];

    expect(SmartDifficultyAdvisor.suggest(history, 'medium')?.suggested, 'easy');
  });

  test('abandoning easier quests as too hard also lowers the level', () {
    final history = List.generate(2, (_) => _left('easy', AbandonmentReason.tooDifficult));

    expect(SmartDifficultyAdvisor.suggest(history, 'medium')?.suggested, 'easy');
  });

  test('abandons for weather or distance do not lower the level', () {
    final history = [
      _left('medium', AbandonmentReason.weatherOrMoodChanged),
      _left('medium', AbandonmentReason.tooFar),
    ];

    expect(SmartDifficultyAdvisor.suggest(history, 'medium'), isNull);
  });

  test('three completions in a row suggest a harder level', () {
    final history = List.generate(3, (_) => _done('easy'));

    expect(SmartDifficultyAdvisor.suggest(history, 'easy')?.suggested, 'medium');
  });

  test('no suggestion beyond the limits or for other levels', () {
    expect(SmartDifficultyAdvisor.suggest(List.generate(3, (_) => _done('hard')), 'hard'), isNull);
    expect(SmartDifficultyAdvisor.suggest(List.generate(3, (_) => _done('easy')), 'medium'), isNull);
  });

  test('a completion breaks the abandon streak', () {
    final history = [
      _left('medium', AbandonmentReason.tooDifficult),
      _done('medium'),
      _left('medium', AbandonmentReason.tooDifficult),
    ];

    final streaks = SmartDifficultyAdvisor.streaks(history, 'medium');
    expect(streaks.abandons, 1);
    expect(streaks.completions, 0);
    expect(SmartDifficultyAdvisor.suggest(history, 'medium'), isNull);
  });

  test('the explanation names both levels in Spanish', () {
    final suggestion = SmartDifficultyAdvisor.suggest(List.generate(3, (_) => _done('medium')), 'medium')!;

    expect(suggestion.explanation, contains('Media'));
    expect(suggestion.explanation, contains('Difícil'));
  });
}
