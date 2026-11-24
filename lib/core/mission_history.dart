import '../models/quest.dart';
import '../models/user_quest.dart';
import 'category_labels.dart';

/// "Mi bitácora": every attempt of the user, filtered, searched and grouped
/// by month. Pure, so it can run on a background isolate (see
/// MissionHistoryViewModel), and written rule by rule so Kotlin gives the
/// same answer: docs/BITACORA.md is the shared contract.

/// Which attempts the bitácora shows.
enum HistoryFilter {
  /// Everything but `skipped` ("Ahora no" is not an attempt).
  all,
  completed,
  abandoned,
}

/// Statuses of a mission still being done.
const _inProgressStatuses = {'accepted', 'in_progress'};

/// Everything [buildMissionHistory] needs, already read: it runs on another
/// isolate, where Hive and the repositories aren't available.
class MissionHistoryInput {
  final List<Quest> catalog;
  final List<UserQuest> userQuests;

  /// Walked steps per attempt (`user_quests.id`), from the podómetro.
  final Map<String, int> stepTotals;

  /// Attempts with a change made offline that hasn't reached the server yet
  /// (QuestRepository.pendingSyncAttemptIds).
  final Set<String> pendingSyncIds;
  final HistoryFilter filter;
  final String query;

  const MissionHistoryInput({
    required this.catalog,
    required this.userQuests,
    required this.stepTotals,
    this.pendingSyncIds = const {},
    this.filter = HistoryFilter.all,
    this.query = '',
  });
}

/// One attempt, ready to paint.
class HistoryEntry {
  final String attemptId;
  final String questId;

  /// Null when the quest left the catalogue (or it isn't cached offline).
  final Quest? quest;

  /// The quest's title, or its id when [quest] is null.
  final String title;
  final String status;

  /// When it happened, in local time (see [historyDateOf]).
  final DateTime date;
  final int? rating;

  /// `user_quests.abandon_reason` code, as both apps write it.
  final String? abandonReason;

  /// Null when this attempt has no step data (≠ 0 steps walked).
  final int? steps;

  /// What's shown here was changed offline and is still waiting to be sent.
  final bool isPendingSync;

  const HistoryEntry({
    required this.attemptId,
    required this.questId,
    required this.quest,
    required this.title,
    required this.status,
    required this.date,
    required this.rating,
    required this.abandonReason,
    required this.steps,
    this.isPendingSync = false,
  });

  bool get isCompleted => status == 'completed';
  bool get isAbandoned => status == 'abandoned';
  bool get isInProgress => _inProgressStatuses.contains(status);
}

/// One month of the bitácora, newest entry first. Its totals count only the
/// entries shown, so they follow the filter and the search.
class HistoryMonth {
  final int year;
  final int month;
  final List<HistoryEntry> entries;
  final int completedCount;
  final int abandonedCount;
  final int inProgressCount;

  /// Sum of `duration_minutes` of the completed missions still in the catalogue.
  final int completedMinutes;

  /// Null when no entry of the month has step data.
  final int? steps;

  const HistoryMonth({
    required this.year,
    required this.month,
    required this.entries,
    required this.completedCount,
    required this.abandonedCount,
    required this.inProgressCount,
    required this.completedMinutes,
    required this.steps,
  });
}

class MissionHistory {
  /// Newest month first.
  final List<HistoryMonth> months;

  /// Attempts before the filter and the search: 0 means "no history at all",
  /// not "nothing matches".
  final int totalAttempts;

  /// Entries shown, across every month.
  final int matchCount;

  /// Attempts waiting to sync, before the filter and the search: the view
  /// says how many changes go out when the connection is back.
  final int pendingSyncCount;

  const MissionHistory({
    required this.months,
    required this.totalAttempts,
    required this.matchCount,
    this.pendingSyncCount = 0,
  });

  static const empty = MissionHistory(months: [], totalAttempts: 0, matchCount: 0);
}

/// Pure and top-level so compute() can run it on another isolate: it must
/// not capture a ViewModel, whose repository can't be sent there.
MissionHistory buildMissionHistory(MissionHistoryInput input) {
  final questsById = {for (final quest in input.catalog) quest.id: quest};
  final attempts = input.userQuests.where((uq) => uq.status != 'skipped').toList();
  final queryTokens = normalizeForSearch(input.query).split(' ').where((token) => token.isNotEmpty).toList();

  final entries = <HistoryEntry>[];
  for (final attempt in attempts) {
    if (!_passesFilter(attempt.status, input.filter)) continue;
    final quest = questsById[attempt.questId];
    if (queryTokens.isNotEmpty) {
      final haystack = _searchableText(attempt, quest);
      if (!queryTokens.every(haystack.contains)) continue;
    }
    entries.add(
      HistoryEntry(
        attemptId: attempt.id,
        questId: attempt.questId,
        quest: quest,
        title: quest?.title ?? attempt.questId,
        status: attempt.status,
        date: historyDateOf(attempt),
        rating: attempt.rating,
        abandonReason: attempt.abandonReason,
        steps: input.stepTotals[attempt.id],
        isPendingSync: input.pendingSyncIds.contains(attempt.id),
      ),
    );
  }

  // Newest first; the attempt id breaks ties so the order never depends on
  // the order the server or the cache returned.
  entries.sort((a, b) {
    final byDate = b.date.compareTo(a.date);
    return byDate != 0 ? byDate : a.attemptId.compareTo(b.attemptId);
  });

  final months = <HistoryMonth>[];
  var monthStart = 0;
  for (var i = 1; i <= entries.length; i++) {
    final endsMonth =
        i == entries.length ||
        entries[i].date.year != entries[monthStart].date.year ||
        entries[i].date.month != entries[monthStart].date.month;
    if (endsMonth) {
      months.add(_summarizeMonth(entries.sublist(monthStart, i)));
      monthStart = i;
    }
  }

  return MissionHistory(
    months: months,
    totalAttempts: attempts.length,
    matchCount: entries.length,
    pendingSyncCount: attempts.where((attempt) => input.pendingSyncIds.contains(attempt.id)).length,
  );
}

/// The moment an attempt is filed under, in local time: when it was
/// completed, when it was abandoned, or when it started; `accepted_at` when
/// that timestamp is missing.
DateTime historyDateOf(UserQuest attempt) {
  final date = switch (attempt.status) {
    'completed' => attempt.completedAt,
    'abandoned' => attempt.abandonedAt,
    _ => attempt.startedAt,
  };
  return (date ?? attempt.acceptedAt).toLocal();
}

const _accents = {
  'á': 'a', 'à': 'a', 'ä': 'a', 'â': 'a',
  'é': 'e', 'è': 'e', 'ë': 'e', 'ê': 'e',
  'í': 'i', 'ì': 'i', 'ï': 'i', 'î': 'i',
  'ó': 'o', 'ò': 'o', 'ö': 'o', 'ô': 'o',
  'ú': 'u', 'ù': 'u', 'ü': 'u', 'û': 'u',
  'ñ': 'n',
};

/// Lowercase, without accents, trimmed, one space between words: "Café  Ñ"
/// -> "cafe n". A fixed table, not the platform's Unicode normalizer, so
/// Kotlin can copy it and match exactly the same.
String normalizeForSearch(String text) {
  final buffer = StringBuffer();
  for (final rune in text.toLowerCase().runes) {
    final char = String.fromCharCode(rune);
    buffer.write(_accents[char] ?? char);
  }
  return buffer.toString().trim().replaceAll(RegExp(r'\s+'), ' ');
}

bool _passesFilter(String status, HistoryFilter filter) => switch (filter) {
  HistoryFilter.all => true,
  HistoryFilter.completed => status == 'completed',
  HistoryFilter.abandoned => status == 'abandoned',
};

/// What a search looks in: the title, the place and the category, both the
/// stored value ("food") and the label on screen ("Gastronomía"). A quest
/// missing from the catalogue can only be found by its id.
String _searchableText(UserQuest attempt, Quest? quest) => normalizeForSearch(
  quest == null
      ? attempt.questId
      : [quest.title, quest.locationName ?? '', quest.category, categoryLabelEs(quest.category)].join(' '),
);

HistoryMonth _summarizeMonth(List<HistoryEntry> entries) {
  final completed = entries.where((entry) => entry.isCompleted);
  final stepCounts = entries.map((entry) => entry.steps).whereType<int>().toList();
  return HistoryMonth(
    year: entries.first.date.year,
    month: entries.first.date.month,
    entries: entries,
    completedCount: completed.length,
    abandonedCount: entries.where((entry) => entry.isAbandoned).length,
    inProgressCount: entries.where((entry) => entry.isInProgress).length,
    completedMinutes: completed.fold(0, (sum, entry) => sum + (entry.quest?.durationMinutes ?? 0)),
    steps: stepCounts.isEmpty ? null : stepCounts.reduce((a, b) => a + b),
  );
}
