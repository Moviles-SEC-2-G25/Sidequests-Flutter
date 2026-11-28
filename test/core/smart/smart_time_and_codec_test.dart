import 'package:flutter_test/flutter_test.dart';
import 'package:sidequests/core/smart/smart_difficulty_advisor.dart';
import 'package:sidequests/core/smart/smart_history_codec.dart';
import 'package:sidequests/core/smart/smart_time_advisor.dart';
import 'package:sidequests/models/abandonment_reason.dart';

/// Same cases as the Kotlin app's SmartTimeAdvisorTest and SettingsCodecTest.
void main() {
  group('SmartTimeAdvisor', () {
    test('needs at least two choices in that part of the day', () {
      final history = [const TimeChoice(timeOfDay: 'morning', minutes: 15)];

      expect(SmartTimeAdvisor.preferredMinutes(history, 'morning'), isNull);
    });

    test('picks the most frequent choice of that part of the day', () {
      final history = [
        const TimeChoice(timeOfDay: 'evening', minutes: 45),
        const TimeChoice(timeOfDay: 'evening', minutes: 45),
        const TimeChoice(timeOfDay: 'evening', minutes: 20),
        const TimeChoice(timeOfDay: 'morning', minutes: 10),
        const TimeChoice(timeOfDay: 'morning', minutes: 10),
      ];

      expect(SmartTimeAdvisor.preferredMinutes(history, 'evening'), 45);
      expect(SmartTimeAdvisor.preferredMinutes(history, 'morning'), 10);
      expect(SmartTimeAdvisor.preferredMinutes(history, 'afternoon'), isNull);
    });

    test('a tie goes to the most recent choice', () {
      final history = [
        const TimeChoice(timeOfDay: 'afternoon', minutes: 30),
        const TimeChoice(timeOfDay: 'afternoon', minutes: 60),
      ];

      expect(SmartTimeAdvisor.preferredMinutes(history, 'afternoon'), 60);
    });
  });

  group('SmartHistoryCodec', () {
    test('round-trips both histories', () {
      final choices = [
        const TimeChoice(timeOfDay: 'morning', minutes: 15),
        const TimeChoice(timeOfDay: 'night', minutes: 60),
      ];
      final outcomes = [
        const DifficultyOutcome(difficulty: 'medium', completed: true),
        const DifficultyOutcome(
          difficulty: 'easy',
          completed: false,
          reason: AbandonmentReason.tooDifficult,
        ),
      ];

      expect(SmartHistoryCodec.decodeTimeChoices(SmartHistoryCodec.encodeTimeChoices(choices)), choices);
      expect(SmartHistoryCodec.decodeOutcomes(SmartHistoryCodec.encodeOutcomes(outcomes)), outcomes);
    });

    test('skips corrupted entries instead of failing the whole load', () {
      expect(
        SmartHistoryCodec.decodeTimeChoices('morning:15;garbage;brunch:10;evening:x;night:60'),
        [
          const TimeChoice(timeOfDay: 'morning', minutes: 15),
          const TimeChoice(timeOfDay: 'night', minutes: 60),
        ],
      );
      expect(
        SmartHistoryCodec.decodeOutcomes('medium:1:-;extreme:1:-;easy:2:-;hard:0:too_far'),
        [
          const DifficultyOutcome(difficulty: 'medium', completed: true),
          const DifficultyOutcome(difficulty: 'hard', completed: false, reason: AbandonmentReason.tooFar),
        ],
      );
      expect(SmartHistoryCodec.decodeOutcomes(null), isEmpty);
      expect(SmartHistoryCodec.decodeTimeChoices(''), isEmpty);
    });
  });
}
