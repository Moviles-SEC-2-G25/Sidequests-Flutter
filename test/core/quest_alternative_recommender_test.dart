import 'package:flutter_test/flutter_test.dart';
import 'package:sidequests/core/quest_alternative_recommender.dart';
import 'package:sidequests/models/abandonment_reason.dart';
import 'package:sidequests/models/app_context.dart';
import 'package:sidequests/models/quest.dart';
import 'package:sidequests/models/user_preferences.dart';

const _rain = 61;
const _clear = 0;
const _userLatitude = 4.6;
const _userLongitude = -74.07;
const _degreesPerKm = 1 / 111.195;

Quest _quest(
  String id, {
  int minutes = 20,
  double cost = 0,
  String difficulty = 'easy',
  String location = 'gps',
  String social = 'solo',
  String category = 'test',
  double? kmNorth,
  List<String> tags = const [],
}) => Quest(
  id: id,
  title: id,
  category: category,
  durationMinutes: minutes,
  estimatedCost: cost,
  difficulty: difficulty,
  locationMode: location,
  socialLevel: social,
  latitude: kmNorth == null ? null : _userLatitude + kmNorth * _degreesPerKm,
  longitude: kmNorth == null ? null : _userLongitude,
  tags: tags,
);

AppContext _context({
  int? weather,
  String time = 'afternoon',
  bool hasLocation = false,
  Duration? weatherAge,
}) => AppContext(
  timeOfDay: time,
  dayOfWeek: 'monday',
  isConnected: true,
  weatherCode: weather,
  weatherAge: weatherAge,
  weatherIsStale: weatherAge != null,
  latitude: hasLocation ? _userLatitude : null,
  longitude: hasLocation ? _userLongitude : null,
);

final _source = _quest('source', minutes: 60, cost: 14, difficulty: 'hard', kmNorth: 2);

List<QuestAlternative> _recommend(
  List<Quest> candidates, {
  AbandonmentReason reason = AbandonmentReason.other,
  AppContext? context,
  Set<String> excluded = const {},
  int available = 30,
  Quest? previous,
  UserPreferences preferences = const UserPreferences(),
}) => const QuestAlternativeRecommender().recommend(
  catalog: candidates,
  abandonedQuest: previous ?? _source,
  reason: reason,
  context: context ?? _context(),
  availableMinutes: available,
  preferences: preferences,
  excludedIds: excluded,
);

List<String> _ids(List<QuestAlternative> alternatives) => [for (final a in alternatives) a.quest.id];

void main() {
  group('each reason requires a real improvement', () {
    test('ran_out_of_time excludes equal and longer durations instead of merely sorting them', () {
      final results = _recommend(
        [_quest('short', minutes: 15), _quest('same', minutes: 30), _quest('long', minutes: 60)],
        reason: AbandonmentReason.ranOutOfTime,
        previous: _quest('source', minutes: 30),
      );

      expect(_ids(results), ['short']);
      expect(results.single.ruleCodes, contains('shorter'));
      expect(results.single.explanations, contains('Es más corta que la misión que dejaste'));
    });

    test('too_expensive picks the cheaper one, ran_out_of_time the shorter one', () {
      final candidates = [_quest('short-paid', minutes: 15, cost: 5), _quest('long-free', minutes: 30)];
      final previous = _quest('source', minutes: 30, cost: 5);

      final byTime = _recommend(candidates, reason: AbandonmentReason.ranOutOfTime, previous: previous);
      final byCost = _recommend(candidates, reason: AbandonmentReason.tooExpensive, previous: previous);

      expect(_ids(byTime), ['short-paid']);
      expect(_ids(byCost), ['long-free']);
      expect(byCost.single.ruleCodes, contains('cheaper'));
    });

    test('too_far: anywhere always; a GPS quest only if it is closer to the user', () {
      final candidates = [
        _quest('anywhere', location: 'anywhere'),
        _quest('closer', kmNorth: 0.5),
        _quest('farther', kmNorth: 3),
        _quest('no-coordinates'),
      ];

      final results = _recommend(
        candidates,
        reason: AbandonmentReason.tooFar,
        context: _context(hasLocation: true),
      );

      expect(_ids(results), ['anywhere', 'closer']);
      expect(results.first.ruleCodes, contains('no_travel'));
      expect(results.last.ruleCodes, contains('shorter_gps_distance'));
    });

    test('too_far without a position does not invent proximity', () {
      final results = _recommend(
        [_quest('anywhere', location: 'anywhere'), _quest('closer', kmNorth: 0.5)],
        reason: AbandonmentReason.tooFar,
      );

      expect(_ids(results), ['anywhere']);
    });

    test('too_far when the abandoned quest has no coordinates: only anywhere', () {
      final results = _recommend(
        [_quest('anywhere', location: 'anywhere'), _quest('closer', kmNorth: 0.5)],
        reason: AbandonmentReason.tooFar,
        context: _context(hasLocation: true),
        previous: _quest('source'),
      );

      expect(_ids(results), ['anywhere']);
    });

    test('place_unavailable requires no venue', () {
      final results = _recommend([
        _quest('anywhere', location: 'anywhere'),
        _quest('venue'),
      ], reason: AbandonmentReason.placeUnavailable);

      expect(_ids(results), ['anywhere']);
      expect(results.single.ruleCodes, contains('no_venue'));
    });

    test('too_difficult requires an easier level', () {
      final results = _recommend([
        _quest('hard', difficulty: 'hard'),
        _quest('medium', difficulty: 'medium'),
        _quest('easy'),
      ], reason: AbandonmentReason.tooDifficult);

      expect(_ids(results), unorderedEquals(['easy', 'medium']));
      expect(results.first.ruleCodes, contains('easier'));
    });

    test('weather_or_mood_changed filters nothing and rewards calmer quests', () {
      final results = _recommend([
        _quest('plain'),
        _quest('calm', tags: const ['Chill']),
      ], reason: AbandonmentReason.weatherOrMoodChanged);

      expect(_ids(results), ['calm', 'plain']);
      expect(results.first.ruleCodes, contains('calmer'));
    });

    test('other filters nothing and adds no reason rule', () {
      final results = _recommend([_quest('plain')]);

      expect(_ids(results), ['plain']);
      expect(results.single.ruleCodes, isNot(contains('shorter')));
    });
  });

  group('the context changes the order', () {
    final outdoor = _quest('outdoor', tags: const ['outdoor', 'nature']);
    final indoor = _quest('indoor', tags: const ['indoor']);

    test('rain and clear weather change the first alternative for identical inputs', () {
      final clear = _recommend([indoor, outdoor], context: _context(weather: _clear));
      final wet = _recommend([indoor, outdoor], context: _context(weather: _rain));

      expect(clear.first.quest.id, 'outdoor');
      expect(wet.first.quest.id, 'indoor');
      expect(wet.first.ruleCodes, contains('wet_indoor'));
      expect(wet.last.ruleCodes, contains('wet_outdoor_penalty'));
    });

    test('night turns a clear-weather outdoor suggestion into an indoor one', () {
      final day = _recommend([indoor, outdoor], context: _context(weather: _clear));
      final night = _recommend([indoor, outdoor], context: _context(weather: _clear, time: 'night'));

      expect(day.first.quest.id, 'outdoor');
      expect(night.first.quest.id, 'indoor');
      expect(night.last.ruleCodes, contains('late_outdoor_penalty'));
    });

    test('unknown weather applies no weather rule', () {
      final result = _recommend([outdoor]).single;

      expect(result.ruleCodes.where((c) => c.startsWith('wet_') || c.startsWith('clear_')), isEmpty);
    });

    test('a last known weather 3 hours old counts as unknown', () {
      final old = _context(weather: _rain, weatherAge: const Duration(hours: 3));
      final recent = _context(weather: _rain, weatherAge: const Duration(hours: 2));

      expect(alternativesWeatherCondition(old), 'unknown');
      expect(alternativesWeatherCondition(recent), 'rain');
      expect(_recommend([outdoor], context: old).single.ruleCodes, isNot(contains('wet_outdoor_penalty')));
    });

    test('morning and evening reward their tags', () {
      final coffee = _quest('coffee', tags: const ['coffee']);
      final food = _quest('food', tags: const ['food']);

      expect(_recommend([coffee], context: _context(time: 'morning')).single.ruleCodes, contains('morning'));
      expect(_recommend([food], context: _context(time: 'evening')).single.ruleCodes, contains('evening'));
    });
  });

  test('scores with exactly the points of Kotlin', () {
    final result = _recommend(
      [
        _quest('q', location: 'anywhere', category: 'Art', tags: const ['calm']),
      ],
      reason: AbandonmentReason.tooFar,
      context: _context(weather: _rain, time: 'night'),
      preferences: const UserPreferences(interests: ['art']),
    ).single;

    // no_travel 5, wet_no_travel 4, late_local 4, interest 2, social 1, difficulty 1, free 1.
    expect(result.score, 18);
    expect(result.ruleCodes, [
      'no_travel',
      'wet_no_travel',
      'late_local',
      'interest',
      'social_preference',
      'difficulty_preference',
      'free',
    ]);
    expect(result.explanations.last, 'Se ajusta a tu tiempo y presupuesto');
    expect(result.explanations.toSet(), hasLength(result.explanations.length));
  });

  test('excludes the source, existing attempts and what is outside time, budget or mode', () {
    final results = _recommend(
      [
        _source,
        _quest('done'),
        _quest('too-long', minutes: 45),
        _quest('too-costly', cost: 25),
        _quest('gps'),
        _quest('local', location: 'anywhere'),
      ],
      excluded: const {'done'},
      preferences: const UserPreferences(locationMode: 'anywhere'),
    );

    expect(_ids(results), ['local']);
  });

  test('empty when nothing improves or there is no time', () {
    expect(
      _recommend(
        [_quest('same', minutes: 10)],
        reason: AbandonmentReason.ranOutOfTime,
        previous: _quest('source', minutes: 10),
      ),
      isEmpty,
    );
    expect(_recommend([_quest('candidate')], available: 0), isEmpty);
  });

  test('at most 3, no duplicates, and ties do not depend on the catalogue order', () {
    final candidates = [_quest('d'), _quest('c'), _quest('b'), _quest('a'), _quest('a')];

    expect(_ids(_recommend(candidates)), ['a', 'b', 'c']);
    expect(_ids(_recommend(candidates.reversed.toList())), ['a', 'b', 'c']);
  });

  test('ties go to the shorter, then the cheaper', () {
    final results = _recommend([
      _quest('long', minutes: 25, cost: 1),
      _quest('short-paid', minutes: 10, cost: 2),
      _quest('short-cheap', minutes: 10, cost: 1),
    ]);

    expect(_ids(results), ['short-cheap', 'short-paid', 'long']);
  });
}
