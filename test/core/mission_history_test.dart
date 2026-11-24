import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sidequests/core/mission_history.dart';
import 'package:sidequests/models/quest.dart';
import 'package:sidequests/models/user_quest.dart';

/// The bitácora's rules (docs/BITACORA.md): Kotlin must give the same
/// answer to these same cases.

Quest _quest(String id, {String title = '', String category = 'food', int minutes = 30, String? place}) => Quest(
  id: id,
  title: title.isEmpty ? 'Quest $id' : title,
  category: category,
  durationMinutes: minutes,
  difficulty: 'easy',
  locationMode: 'anywhere',
  socialLevel: 'solo',
  locationName: place,
);

UserQuest _attempt(
  String id,
  String questId,
  String status, {
  required DateTime acceptedAt,
  DateTime? startedAt,
  DateTime? completedAt,
  DateTime? abandonedAt,
  int? rating,
  String? reason,
}) => UserQuest(
  id: id,
  userId: 'user-1',
  questId: questId,
  status: status,
  acceptedAt: acceptedAt,
  startedAt: startedAt,
  completedAt: completedAt,
  abandonedAt: abandonedAt,
  rating: rating,
  abandonReason: reason,
);

final _catalog = [
  _quest('cafe', title: 'Café de especialidad', category: 'food', minutes: 45, place: 'Usaquén'),
  _quest('mural', title: 'Murales del centro', category: 'art', minutes: 60, place: 'La Candelaria'),
  _quest('yoga', title: 'Yoga al amanecer', category: 'mindfulness', minutes: 20),
];

/// November: two completed, one abandoned, one in progress; October: one
/// completed; plus a skip (never an attempt) and a quest gone from the catalogue.
final _attempts = [
  _attempt('uq-1', 'cafe', 'completed',
      acceptedAt: DateTime(2026, 11, 1, 9), completedAt: DateTime(2026, 11, 2, 10), rating: 5),
  _attempt('uq-2', 'mural', 'completed', acceptedAt: DateTime(2026, 11, 3), completedAt: DateTime(2026, 11, 20)),
  _attempt('uq-3', 'yoga', 'abandoned',
      acceptedAt: DateTime(2026, 11, 5), abandonedAt: DateTime(2026, 11, 6), reason: 'too_far'),
  _attempt('uq-4', 'cafe', 'in_progress', acceptedAt: DateTime(2026, 11, 21), startedAt: DateTime(2026, 11, 22)),
  _attempt('uq-5', 'yoga', 'completed', acceptedAt: DateTime(2026, 10, 30), completedAt: DateTime(2026, 10, 31)),
  _attempt('uq-6', 'mural', 'skipped', acceptedAt: DateTime(2026, 11, 23)),
  _attempt('uq-7', 'deleted-quest', 'completed',
      acceptedAt: DateTime(2026, 9, 1), completedAt: DateTime(2026, 9, 2)),
];

MissionHistory _build({
  HistoryFilter filter = HistoryFilter.all,
  String query = '',
  Map<String, int> stepTotals = const {},
}) => buildMissionHistory(
  MissionHistoryInput(
    catalog: _catalog,
    userQuests: _attempts,
    stepTotals: stepTotals,
    filter: filter,
    query: query,
  ),
);

List<String> _ids(MissionHistory history) => [
  for (final month in history.months)
    for (final entry in month.entries) entry.attemptId,
];

/// Every field of the answer, to compare one built on another isolate.
String _describe(MissionHistory history) => [
  '${history.totalAttempts}/${history.matchCount}/${history.pendingSyncCount}',
  for (final month in history.months)
    '${month.year}-${month.month}:${month.completedCount},${month.abandonedCount},${month.inProgressCount},'
        '${month.completedMinutes},${month.steps}'
        '[${month.entries.map((e) => '${e.attemptId}@${e.date.toIso8601String()}:${e.title}:${e.rating}:${e.abandonReason}:${e.steps}:${e.isPendingSync}').join(';')}]',
].join(' | ');

void main() {
  group('buildMissionHistory', () {
    test('every attempt but skipped, newest first, grouped by month', () {
      final history = _build();

      expect(history.totalAttempts, 6);
      expect(history.matchCount, 6);
      expect(history.months.map((m) => (m.year, m.month)), [(2026, 11), (2026, 10), (2026, 9)]);
      // in progress (22) > completed (20) > abandoned (6) > completed (2)
      expect(_ids(history), ['uq-4', 'uq-2', 'uq-3', 'uq-1', 'uq-5', 'uq-7']);
    });

    test('the date is completed_at / abandoned_at / started_at, accepted_at when missing', () {
      final history = buildMissionHistory(
        MissionHistoryInput(
          catalog: _catalog,
          userQuests: [
            _attempt('done', 'cafe', 'completed', acceptedAt: DateTime(2026, 1, 1), completedAt: DateTime(2026, 3, 1)),
            _attempt('gone', 'cafe', 'abandoned', acceptedAt: DateTime(2026, 1, 2), abandonedAt: DateTime(2026, 4, 1)),
            _attempt('going', 'cafe', 'in_progress', acceptedAt: DateTime(2026, 1, 3), startedAt: DateTime(2026, 5, 1)),
            _attempt('accepted', 'cafe', 'accepted', acceptedAt: DateTime(2026, 1, 4)),
            _attempt('no-stamp', 'cafe', 'completed', acceptedAt: DateTime(2026, 1, 5)),
          ],
          stepTotals: const {},
        ),
      );

      final dates = {
        for (final month in history.months)
          for (final entry in month.entries) entry.attemptId: entry.date,
      };
      expect(dates, {
        'done': DateTime(2026, 3, 1),
        'gone': DateTime(2026, 4, 1),
        'going': DateTime(2026, 5, 1),
        'accepted': DateTime(2026, 1, 4),
        'no-stamp': DateTime(2026, 1, 5),
      });
    });

    test('server timestamps (UTC) are filed under the local month', () {
      final utc = DateTime.utc(2026, 11, 1, 2, 30);
      final history = buildMissionHistory(
        MissionHistoryInput(
          catalog: _catalog,
          userQuests: [_attempt('uq', 'cafe', 'completed', acceptedAt: utc, completedAt: utc)],
          stepTotals: const {},
        ),
      );

      final local = utc.toLocal();
      expect((history.months.single.year, history.months.single.month), (local.year, local.month));
      expect(history.months.single.entries.single.date.isUtc, isFalse);
    });

    test('same date: the attempt id decides, whatever order the list came in', () {
      final sameDay = DateTime(2026, 6, 1);
      MissionHistory build(List<String> ids) => buildMissionHistory(
        MissionHistoryInput(
          catalog: _catalog,
          userQuests: [for (final id in ids) _attempt(id, 'cafe', 'accepted', acceptedAt: sameDay)],
          stepTotals: const {},
        ),
      );

      expect(_ids(build(['b', 'c', 'a'])), ['a', 'b', 'c']);
      expect(_ids(build(['c', 'a', 'b'])), ['a', 'b', 'c']);
    });

    test('month totals: counts per status, minutes of completed only, steps null when none', () {
      final history = _build(stepTotals: const {'uq-1': 1200, 'uq-3': 300, 'someone-else': 9999});

      final november = history.months.first;
      expect(november.completedCount, 2);
      expect(november.abandonedCount, 1);
      expect(november.inProgressCount, 1);
      expect(november.completedMinutes, 45 + 60); // not the abandoned or in-progress ones
      expect(november.steps, 1500);

      final october = history.months[1];
      expect(october.completedMinutes, 20);
      expect(october.steps, isNull); // no step data ≠ 0 steps
    });

    test('each entry carries its rating, abandonment reason and steps', () {
      final history = _build(stepTotals: const {'uq-3': 300});
      final byId = {
        for (final month in history.months)
          for (final entry in month.entries) entry.attemptId: entry,
      };

      expect(byId['uq-1']!.rating, 5);
      expect(byId['uq-1']!.isCompleted, isTrue);
      expect(byId['uq-3']!.abandonReason, 'too_far');
      expect(byId['uq-3']!.steps, 300);
      expect(byId['uq-3']!.isAbandoned, isTrue);
      expect(byId['uq-4']!.isInProgress, isTrue);
      expect(byId['uq-4']!.steps, isNull);
    });

    test('a quest gone from the catalogue shows its id, no quest, no minutes', () {
      final september = _build().months.last;

      final entry = september.entries.single;
      expect(entry.quest, isNull);
      expect(entry.title, 'deleted-quest');
      expect(september.completedCount, 1);
      expect(september.completedMinutes, 0);
    });

    test('filters: completed and abandoned; the total stays the whole history', () {
      final completed = _build(filter: HistoryFilter.completed);
      expect(_ids(completed), ['uq-2', 'uq-1', 'uq-5', 'uq-7']);
      expect(completed.totalAttempts, 6);
      expect(completed.matchCount, 4);

      final abandoned = _build(filter: HistoryFilter.abandoned);
      expect(_ids(abandoned), ['uq-3']);
      expect(abandoned.months.single.completedCount, 0);
    });

    test('search ignores case and accents, in the title, place and category label', () {
      expect(_ids(_build(query: 'CAFE')), ['uq-4', 'uq-1']); // "Café de especialidad"
      expect(_ids(_build(query: 'candelaria')), ['uq-2']); // place
      expect(_ids(_build(query: 'gastronomía')), ['uq-4', 'uq-1']); // label of "food"
      expect(_ids(_build(query: 'mindfulness')), ['uq-3', 'uq-5']); // stored category
      expect(_ids(_build(query: 'bienestar')), ['uq-3', 'uq-5']); // its label
    });

    test('search: every word must appear, in any order and field', () {
      expect(_ids(_build(query: 'especialidad usaquen')), ['uq-4', 'uq-1']);
      expect(_ids(_build(query: 'usaquen murales')), isEmpty);
    });

    test('search and filter combine; an empty or blank query searches nothing', () {
      expect(_ids(_build(query: 'cafe', filter: HistoryFilter.completed)), ['uq-1']);
      expect(_build(query: '   ').matchCount, 6);
    });

    test('a quest gone from the catalogue is found by its id only', () {
      expect(_ids(_build(query: 'deleted')), ['uq-7']);
    });

    test('changes made offline: marked per entry, counted over the whole history', () {
      final history = buildMissionHistory(
        MissionHistoryInput(
          catalog: _catalog,
          userQuests: _attempts,
          stepTotals: const {},
          // uq-6 is a skip (not shown, not counted); someone-else isn't here.
          pendingSyncIds: const {'uq-3', 'uq-1', 'uq-6', 'someone-else'},
          filter: HistoryFilter.abandoned,
        ),
      );

      expect(history.months.single.entries.single.isPendingSync, isTrue); // uq-3
      expect(history.pendingSyncCount, 2); // uq-1 too, though filtered out
      expect(_build().months.expand((m) => m.entries).any((e) => e.isPendingSync), isFalse);
      expect(_build().pendingSyncCount, 0);
    });

    test('no history at all: no months, total 0', () {
      final history = buildMissionHistory(
        const MissionHistoryInput(catalog: [], userQuests: [], stepTotals: {}),
      );

      expect(history.months, isEmpty);
      expect(history.totalAttempts, 0);
    });
  });

  group('normalizeForSearch', () {
    test('lowercase, no accents, one space between words', () {
      expect(normalizeForSearch('  Café   CON  Ñandú '), 'cafe con nandu');
      expect(normalizeForSearch('ÁÉÍÓÚ àèìòù äëïöü âêîôû'), 'aeiou aeiou aeiou aeiou');
      expect(normalizeForSearch(''), '');
    });
  });

  // Multithreading strategy: these run a real isolate (plain test(), not
  // testWidgets) to prove the input crosses to it and back unchanged.
  group('on a background isolate', () {
    test('compute() gives exactly the same history as the UI isolate', () async {
      for (final filter in HistoryFilter.values) {
        for (final query in const ['', 'cafe', 'gastronomia usaquen', 'nada']) {
          final input = MissionHistoryInput(
            catalog: _catalog,
            userQuests: _attempts,
            stepTotals: const {'uq-1': 1200, 'uq-3': 300},
            pendingSyncIds: const {'uq-3'},
            filter: filter,
            query: query,
          );

          final inBackground = await compute(buildMissionHistory, input);

          expect(_describe(inBackground), _describe(buildMissionHistory(input)), reason: '$filter "$query"');
        }
      }
    });

    test('a long history (5.000 attempts) comes back whole', () async {
      final attempts = [
        for (var i = 0; i < 5000; i++)
          _attempt(
            'uq-$i',
            _catalog[i % _catalog.length].id,
            i.isEven ? 'completed' : 'abandoned',
            acceptedAt: DateTime(2020, 1, 1).add(Duration(hours: i * 7)),
            completedAt: i.isEven ? DateTime(2020, 1, 1).add(Duration(hours: i * 7 + 1)) : null,
            abandonedAt: i.isOdd ? DateTime(2020, 1, 1).add(Duration(hours: i * 7 + 1)) : null,
          ),
      ];
      final input = MissionHistoryInput(catalog: _catalog, userQuests: attempts, stepTotals: const {});

      final history = await compute(buildMissionHistory, input);

      expect(history.matchCount, 5000);
      expect(history.months.fold<int>(0, (sum, m) => sum + m.entries.length), 5000);
      expect(history.months.first.entries.first.attemptId, 'uq-4999');
    });
  });
}
