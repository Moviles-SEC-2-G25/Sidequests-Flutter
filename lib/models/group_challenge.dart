/// One row of `public.group_challenge_list(p_mine)` (Backend migration 011).
/// Only counts are shared: who the other participants are never reaches the
/// client. Same fields as Kotlin's GroupChallenge.
class GroupChallenge {
  final String challengeId;
  final String questId;
  final String title;

  /// Includes the creator.
  final int participants;

  /// This user's completed steps; null in "available" (not a member).
  final int? myProgress;
  final int totalSteps;
  final int completedParticipants;

  const GroupChallenge({
    required this.challengeId,
    required this.questId,
    required this.title,
    required this.participants,
    this.myProgress,
    required this.totalSteps,
    required this.completedParticipants,
  });

  factory GroupChallenge.fromJson(Map<String, dynamic> json) => GroupChallenge(
    challengeId: json['challenge_id'] as String,
    questId: json['quest_id'] as String,
    title: json['title'] as String,
    participants: (json['participants'] as num).toInt(),
    myProgress: (json['my_progress'] as num?)?.toInt(),
    totalSteps: (json['total_steps'] as num).toInt(),
    completedParticipants: (json['completed_participants'] as num).toInt(),
  );

  /// Same shape as the RPC row, so the copy saved in Hive reads back with
  /// [GroupChallenge.fromJson].
  Map<String, dynamic> toJson() => {
    'challenge_id': challengeId,
    'quest_id': questId,
    'title': title,
    'participants': participants,
    'my_progress': myProgress,
    'total_steps': totalSteps,
    'completed_participants': completedParticipants,
  };

  /// 0 when not a member.
  int get progress => myProgress ?? 0;

  bool get isCompleted => totalSteps > 0 && progress >= totalSteps;

  /// 0.0–1.0, for the progress bar and the "%" label.
  double get progressFraction => totalSteps <= 0 ? 0 : (progress / totalSteps).clamp(0.0, 1.0);
}

/// The answer of `public.group_challenge_act`: `{ok, message, challenge_id}`.
/// A retry with a request id the server already saw gets the saved answer
/// back, whatever happened the first time.
class GroupActionResult {
  final bool ok;

  /// The server's own text ('Saved', 'Challenge not found or expired.'…).
  final String message;
  final String? challengeId;

  const GroupActionResult({required this.ok, required this.message, this.challengeId});

  factory GroupActionResult.fromJson(Map<String, dynamic> json) => GroupActionResult(
    ok: json['ok'] as bool,
    message: json['message'] as String? ?? '',
    challengeId: json['challenge_id'] as String?,
  );
}

/// One create / join / progress request. [requestId] is generated once, on
/// the device, and a retry sends this same object again: the server applies
/// it at most once per (user, request id). Saved in Hive while its result is
/// unknown, so the safe retry survives a restart.
class GroupAction {
  static const create = 'create';
  static const join = 'join';
  static const progress = 'progress';

  /// [create], [join] or [progress] (`p_action`).
  final String operation;
  final String requestId;
  final String? challengeId;
  final String? questId;

  /// The step count to save (`p_progress`); only for [progress].
  final int? progressValue;

  /// What the card was called, so the pending notice can say which one
  /// without the lists.
  final String? title;

  const GroupAction({
    required this.operation,
    required this.requestId,
    this.challengeId,
    this.questId,
    this.progressValue,
    this.title,
  });

  factory GroupAction.fromJson(Map<String, dynamic> json) => GroupAction(
    operation: json['operation'] as String,
    requestId: json['request_id'] as String,
    challengeId: json['challenge_id'] as String?,
    questId: json['quest_id'] as String?,
    progressValue: (json['progress'] as num?)?.toInt(),
    title: json['title'] as String?,
  );

  Map<String, dynamic> toJson() => {
    'operation': operation,
    'request_id': requestId,
    'challenge_id': challengeId,
    'quest_id': questId,
    'progress': progressValue,
    'title': title,
  };
}
