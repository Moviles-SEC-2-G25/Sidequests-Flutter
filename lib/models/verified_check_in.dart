/// One step of one attempt (`user_quests.id`) whose location was verified on
/// the device while its completion couldn't reach the server. It only proves
/// the user was there: completing the step, later, is what gets saved.
///
/// Persisted locally only. [stepIndex] is `user_quests.current_step`.
class VerifiedCheckIn {
  final String userQuestId;
  final int stepIndex;
  final DateTime verifiedAt;

  const VerifiedCheckIn({
    required this.userQuestId,
    required this.stepIndex,
    required this.verifiedAt,
  });

  factory VerifiedCheckIn.fromJson(Map<String, dynamic> json) => VerifiedCheckIn(
    userQuestId: json['user_quest_id'] as String,
    stepIndex: (json['step_index'] as num).toInt(),
    verifiedAt: DateTime.parse(json['verified_at'] as String),
  );

  Map<String, dynamic> toJson() => {
    'user_quest_id': userQuestId,
    'step_index': stepIndex,
    'verified_at': verifiedAt.toUtc().toIso8601String(),
  };
}
