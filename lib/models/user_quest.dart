/// Mirrors `public.user_quests` — per-user quest state and progress.
class UserQuest {
  final String id;
  final String userId;
  final String questId;
  final String status; // accepted | in_progress | completed | abandoned | skipped
  final int currentStep;
  final List<int> completedSteps;
  final String? abandonReason;
  final int? rating;
  final List<String> feedbackTags;
  final String? photoProofPath;
  final DateTime acceptedAt;
  final DateTime? startedAt;
  final DateTime? completedAt;
  final DateTime? abandonedAt;

  const UserQuest({
    required this.id,
    required this.userId,
    required this.questId,
    this.status = 'accepted',
    this.currentStep = 0,
    this.completedSteps = const [],
    this.abandonReason,
    this.rating,
    this.feedbackTags = const [],
    this.photoProofPath,
    required this.acceptedAt,
    this.startedAt,
    this.completedAt,
    this.abandonedAt,
  });

  factory UserQuest.fromJson(Map<String, dynamic> json) => UserQuest(
    id: json['id'] as String,
    userId: json['user_id'] as String,
    questId: json['quest_id'] as String,
    status: json['status'] as String? ?? 'accepted',
    currentStep: (json['current_step'] as num?)?.toInt() ?? 0,
    completedSteps: List<int>.from(json['completed_steps'] as List? ?? const []),
    abandonReason: json['abandon_reason'] as String?,
    rating: (json['rating'] as num?)?.toInt(),
    feedbackTags: List<String>.from(json['feedback_tags'] as List? ?? const []),
    photoProofPath: json['photo_proof_path'] as String?,
    acceptedAt: DateTime.parse(json['accepted_at'] as String),
    startedAt: json['started_at'] == null
        ? null
        : DateTime.parse(json['started_at'] as String),
    completedAt: json['completed_at'] == null
        ? null
        : DateTime.parse(json['completed_at'] as String),
    abandonedAt: json['abandoned_at'] == null
        ? null
        : DateTime.parse(json['abandoned_at'] as String),
  );

  /// For building the payload of a progress update — only the fields the
  /// backend lets a client write are overridable (see `updateProgress` in
  /// QuestRepository); lifecycle timestamps stay server-owned.
  UserQuest copyWithProgress({
    String? status,
    int? currentStep,
    List<int>? completedSteps,
  }) => UserQuest(
    id: id,
    userId: userId,
    questId: questId,
    status: status ?? this.status,
    currentStep: currentStep ?? this.currentStep,
    completedSteps: completedSteps ?? this.completedSteps,
    abandonReason: abandonReason,
    rating: rating,
    feedbackTags: feedbackTags,
    photoProofPath: photoProofPath,
    acceptedAt: acceptedAt,
    startedAt: startedAt,
    completedAt: completedAt,
    abandonedAt: abandonedAt,
  );
}
