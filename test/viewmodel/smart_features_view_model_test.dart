import 'package:flutter_test/flutter_test.dart';
import 'package:sidequests/core/smart/smart_history_codec.dart';
import 'package:sidequests/data/local/local_data_source.dart';
import 'package:sidequests/models/abandonment_reason.dart';
import 'package:sidequests/viewmodel/smart/smart_features_view_model.dart';

class _FakeLocal implements LocalDataSource {
  final Map<String, SmartHistory> histories = {};

  @override
  SmartHistory loadSmartHistory(String userId) => histories[userId] ?? const SmartHistory();

  @override
  Future<void> saveSmartHistory(String userId, SmartHistory history) async =>
      histories[userId] = history;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late _FakeLocal local;
  late DateTime now;
  late String preferred;

  SmartFeaturesViewModel viewModel({String userId = 'u1'}) => SmartFeaturesViewModel(
    local,
    userId,
    preferredDifficulty: () => preferred,
    now: () => now,
  );

  setUp(() {
    local = _FakeLocal();
    now = DateTime(2026, 11, 27, 16); // afternoon
    preferred = 'medium';
  });

  group('smart available time', () {
    test('learns the usual choice of this part of the day and applies it once', () {
      final smart = viewModel()
        ..recordTimeChoice(45)
        ..recordTimeChoice(45);

      expect(smart.smartMinutesToApply(30), 45);
      expect(smart.smartTimeHint, contains('45 min'));
      expect(smart.smartTimeHint, contains('la tarde'));
      // Once per part of the day: it never fights the user's next choice.
      expect(smart.smartMinutesToApply(30), isNull);
    });

    test('nothing to apply in another part of the day, or when already selected', () {
      final smart = viewModel()
        ..recordTimeChoice(20)
        ..recordTimeChoice(20);

      now = DateTime(2026, 11, 27, 9); // morning
      expect(viewModel().smartMinutesToApply(30), isNull);

      now = DateTime(2026, 11, 27, 16);
      expect(smart.smartMinutesToApply(20), isNull);
      expect(smart.smartTimeHint, isNull);
    });

    test('an explicit choice clears the hint', () {
      final smart = viewModel()
        ..recordTimeChoice(60)
        ..recordTimeChoice(60);
      smart.smartMinutesToApply(30);

      smart.recordTimeChoice(10);

      expect(smart.smartTimeHint, isNull);
    });
  });

  group('smart difficulty (BQ13)', () {
    test('two abandons for difficulty suggest an easier level; dismissing hides it', () {
      final smart = viewModel()
        ..recordOutcome(difficulty: 'medium', completed: false, reason: AbandonmentReason.tooDifficult)
        ..recordOutcome(difficulty: 'medium', completed: false, reason: AbandonmentReason.ranOutOfTime);

      expect(smart.difficultySuggestion?.suggested, 'easy');

      smart.dismissDifficultySuggestion();
      expect(smart.difficultySuggestion, isNull);

      // Something new happened: it may suggest again.
      smart.recordOutcome(difficulty: 'medium', completed: false, reason: AbandonmentReason.tooDifficult);
      expect(smart.difficultySuggestion?.suggested, 'easy');
    });

    test('the suggestion follows the preferred difficulty once it changes', () {
      final smart = viewModel();
      for (var i = 0; i < 3; i++) {
        smart.recordOutcome(difficulty: 'medium', completed: true);
      }
      expect(smart.difficultySuggestion?.suggested, 'hard');

      preferred = 'hard';
      expect(smart.difficultySuggestion, isNull);
    });

    test('history is kept per user and survives a new view model (restart)', () {
      viewModel()
        ..recordTimeChoice(45)
        ..recordOutcome(difficulty: 'easy', completed: true);

      final restored = viewModel();
      expect(restored.timeChoices, hasLength(1));
      expect(restored.difficultyOutcomes.single.difficulty, 'easy');
      expect(viewModel(userId: 'u2').difficultyOutcomes, isEmpty);
    });

    test('history is bounded', () {
      final smart = viewModel();
      for (var i = 0; i < 15; i++) {
        smart.recordOutcome(difficulty: 'easy', completed: true);
      }

      expect(smart.difficultyOutcomes, hasLength(10));
    });
  });
}
