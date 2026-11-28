import 'package:flutter/foundation.dart';

import '../../analytics/analytics_event_type.dart';
import '../../analytics/analytics_tracker.dart';
import '../../core/bq10_context.dart';
import '../../core/smart/smart_difficulty_advisor.dart';
import '../../core/smart/smart_history_codec.dart';
import '../../core/smart/smart_time_advisor.dart';
import '../../data/local/local_data_source.dart';
import '../../models/abandonment_reason.dart';

/// Smart features (mirror of the Kotlin app's Sprint 2/3 work):
/// - Smart available time: learns the "Tengo..." choice per part of the day
///   and preselects it when Explore opens.
/// - Smart difficulty (BQ13): suggests an easier/harder preferred difficulty
///   from streaks of abandons/completions, with analytics events to compare
///   acceptance and completion with and without adaptation.
///
/// Everything runs on the device and is persisted per user id, so it works
/// offline and survives restarts and sign-out/sign-in.
class SmartFeaturesViewModel extends ChangeNotifier {
  final LocalDataSource _localDataSource;
  final AnalyticsTracker? _analyticsTracker;
  final String _userId;
  final String Function() _preferredDifficulty;
  final DateTime Function() _now;

  List<TimeChoice> _timeChoices = const [];
  List<DifficultyOutcome> _difficultyOutcomes = const [];
  int? _dismissedAt;

  /// Part of the day for which the smart time was already applied this
  /// session: applied at most once per part of the day, so it never fights a
  /// choice the user just made.
  String? _smartTimeAppliedFor;

  /// "⚡ Elección inteligente: ..." under the time chips; cleared by an
  /// explicit choice.
  String? smartTimeHint;

  SmartFeaturesViewModel(
    this._localDataSource,
    this._userId, {
    required String Function() preferredDifficulty,
    AnalyticsTracker? analyticsTracker,
    DateTime Function()? now,
  }) : _preferredDifficulty = preferredDifficulty,
       _analyticsTracker = analyticsTracker,
       _now = now ?? DateTime.now {
    try {
      final history = _localDataSource.loadSmartHistory(_userId);
      _timeChoices = history.timeChoices;
      _difficultyOutcomes = history.difficultyOutcomes;
      _dismissedAt = history.difficultySuggestionDismissedAt;
    } catch (_) {
      // Unreadable storage: start with an empty history.
    }
  }

  List<TimeChoice> get timeChoices => List.unmodifiable(_timeChoices);
  List<DifficultyOutcome> get difficultyOutcomes => List.unmodifiable(_difficultyOutcomes);

  // --- Smart available time ---

  /// An explicit "Tengo X" tap on Explore.
  void recordTimeChoice(int minutes) {
    final choice = TimeChoice(timeOfDay: timeOfDayFor(_now()), minutes: minutes);
    final updated = [..._timeChoices, choice];
    _timeChoices = updated.length > SmartTimeAdvisor.historySize
        ? updated.sublist(updated.length - SmartTimeAdvisor.historySize)
        : updated;
    smartTimeHint = null;
    _persist();
    notifyListeners();
  }

  /// When Explore opens: the minutes to preselect, or null when there's
  /// nothing to change. Sets [smartTimeHint] and logs `smart_time_applied`.
  int? smartMinutesToApply(int currentMinutes) {
    final timeOfDay = timeOfDayFor(_now());
    if (_smartTimeAppliedFor == timeOfDay) return null;
    final preferred = SmartTimeAdvisor.preferredMinutes(_timeChoices, timeOfDay);
    if (preferred == null) return null;
    _smartTimeAppliedFor = timeOfDay;
    if (preferred == currentMinutes) return null;

    final label = preferred >= 60 ? '1 h+' : '$preferred min';
    smartTimeHint =
        '⚡ Elección inteligente: sueles tener $label en ${timeOfDayLabelEs(timeOfDay)}';
    notifyListeners();
    _analyticsTracker?.track(
      AnalyticsEventType.smartTimeApplied,
      availableMinutes: preferred,
      metadata: {'minutes': preferred, 'time_of_day': timeOfDay},
    );
    return preferred;
  }

  // --- Smart difficulty (BQ13) ---

  /// A finished attempt: completed, or abandoned with [reason].
  void recordOutcome({required String difficulty, required bool completed, AbandonmentReason? reason}) {
    if (!kDifficultyLevels.contains(difficulty)) return;
    final before = difficultySuggestion;
    final updated = [
      ..._difficultyOutcomes,
      DifficultyOutcome(difficulty: difficulty, completed: completed, reason: reason),
    ];
    _difficultyOutcomes = updated.length > SmartDifficultyAdvisor.historySize
        ? updated.sublist(updated.length - SmartDifficultyAdvisor.historySize)
        : updated;
    _persist();
    notifyListeners();
    // BQ13 instrumentation: a new adaptive suggestion was shown to the user.
    final after = difficultySuggestion;
    if (after != null && after.suggested != before?.suggested) {
      _trackDifficultyEvent(AnalyticsEventType.smartDifficultySuggested, after);
    }
  }

  /// Current suggestion, or null when there's nothing to suggest (or the
  /// user dismissed it and nothing happened since).
  DifficultySuggestion? get difficultySuggestion {
    if (_dismissedAt == _difficultyOutcomes.length) return null;
    return SmartDifficultyAdvisor.suggest(_difficultyOutcomes, _preferredDifficulty());
  }

  /// Current streaks at the preferred difficulty (shown in Perfil).
  DifficultyStreaks get difficultyStreaks =>
      SmartDifficultyAdvisor.streaks(_difficultyOutcomes, _preferredDifficulty());

  DifficultyOutcome? get lastOutcome =>
      _difficultyOutcomes.isEmpty ? null : _difficultyOutcomes.last;

  /// The caller saves the new preferred difficulty (ProfileViewModel); this
  /// logs the acceptance.
  void trackSuggestionAccepted(DifficultySuggestion suggestion) =>
      _trackDifficultyEvent(AnalyticsEventType.smartDifficultyAccepted, suggestion);

  void dismissDifficultySuggestion() {
    final suggestion = difficultySuggestion;
    if (suggestion != null) {
      _trackDifficultyEvent(AnalyticsEventType.smartDifficultyDismissed, suggestion);
    }
    _dismissedAt = _difficultyOutcomes.length;
    _persist();
    notifyListeners();
  }

  void _trackDifficultyEvent(String eventType, DifficultySuggestion suggestion) {
    final streaks = difficultyStreaks;
    _analyticsTracker?.track(
      eventType,
      questDifficulty: suggestion.current,
      metadata: {
        'bq': 'BQ13',
        'from_difficulty': suggestion.current,
        'to_difficulty': suggestion.suggested,
        'abandon_streak': streaks.abandons,
        'completion_streak': streaks.completions,
      },
    );
  }

  void _persist() {
    _localDataSource
        .saveSmartHistory(
          _userId,
          SmartHistory(
            timeChoices: _timeChoices,
            difficultyOutcomes: _difficultyOutcomes,
            difficultySuggestionDismissedAt: _dismissedAt,
          ),
        )
        .catchError((Object _) {});
  }
}
