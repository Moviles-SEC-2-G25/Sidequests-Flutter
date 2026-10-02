/// Walked steps for one quest attempt (`user_quests.id`), derived from the
/// OS step counter — which is cumulative since the phone last booted, so
/// the attempt's steps are `lastReading - baseline` plus whatever was
/// [carried] over from earlier segments (a resumed abandon, or the part
/// counted before a reboot reset the counter).
///
/// Persisted locally only: there is no steps column in the backend.
class StepSession {
  final String userQuestId;
  final int carried;

  /// First reading after counting (re)started; null until it arrives.
  final int? baseline;
  final int? lastReading;

  const StepSession({
    required this.userQuestId,
    this.carried = 0,
    this.baseline,
    this.lastReading,
  });

  int get steps =>
      carried + (baseline == null || lastReading == null ? 0 : lastReading! - baseline!);

  /// False until there's something real to show — distinguishes "no data
  /// yet" from "0 steps walked".
  bool get hasData => baseline != null || carried > 0;

  StepSession copyWith({int? carried, int? baseline, int? lastReading}) => StepSession(
    userQuestId: userQuestId,
    carried: carried ?? this.carried,
    baseline: baseline ?? this.baseline,
    lastReading: lastReading ?? this.lastReading,
  );

  factory StepSession.fromJson(Map<String, dynamic> json) => StepSession(
    userQuestId: json['user_quest_id'] as String,
    carried: (json['carried'] as num?)?.toInt() ?? 0,
    baseline: (json['baseline'] as num?)?.toInt(),
    lastReading: (json['last_reading'] as num?)?.toInt(),
  );

  Map<String, dynamic> toJson() => {
    'user_quest_id': userQuestId,
    'carried': carried,
    if (baseline != null) 'baseline': baseline,
    if (lastReading != null) 'last_reading': lastReading,
  };
}
