/// Mirrors `public.quest_photo_proofs` (migration 009): one uploaded photo
/// for one zero-based step of one attempt (`user_quests.id`).
class QuestPhotoProof {
  final String id;
  final String attemptId;
  final int stepOrder;
  final String storagePath;
  final DateTime uploadedAt;

  const QuestPhotoProof({
    required this.id,
    required this.attemptId,
    required this.stepOrder,
    required this.storagePath,
    required this.uploadedAt,
  });

  factory QuestPhotoProof.fromJson(Map<String, dynamic> json) => QuestPhotoProof(
    id: json['id'] as String,
    attemptId: json['attempt_id'] as String,
    stepOrder: (json['step_order'] as num).toInt(),
    storagePath: json['storage_path'] as String,
    uploadedAt: DateTime.parse(json['uploaded_at'] as String),
  );
}

/// A captured photo kept on the device until its upload + table insert
/// succeed (Retry tactic). The bytes live in a file; this is the metadata
/// stored in Hive. [storagePath] is generated once at capture and reused
/// on every retry, so an upload that landed but whose insert didn't can be
/// finished instead of leaving an orphan object.
class PendingPhotoProof {
  final String localPath;
  final String storagePath;
  final String attemptId;
  final String questId;
  final int stepOrder;
  final int sizeBytes;
  final DateTime capturedAt;
  final int attempts;
  final String? lastError;

  const PendingPhotoProof({
    required this.localPath,
    required this.storagePath,
    required this.attemptId,
    required this.questId,
    required this.stepOrder,
    required this.sizeBytes,
    required this.capturedAt,
    this.attempts = 0,
    this.lastError,
  });

  PendingPhotoProof failedWith(String error) => PendingPhotoProof(
    localPath: localPath,
    storagePath: storagePath,
    attemptId: attemptId,
    questId: questId,
    stepOrder: stepOrder,
    sizeBytes: sizeBytes,
    capturedAt: capturedAt,
    attempts: attempts + 1,
    lastError: error,
  );

  factory PendingPhotoProof.fromJson(Map<String, dynamic> json) => PendingPhotoProof(
    localPath: json['local_path'] as String,
    storagePath: json['storage_path'] as String,
    attemptId: json['attempt_id'] as String,
    questId: json['quest_id'] as String,
    stepOrder: (json['step_order'] as num).toInt(),
    sizeBytes: (json['size_bytes'] as num?)?.toInt() ?? 0,
    capturedAt: DateTime.parse(json['captured_at'] as String),
    attempts: (json['attempts'] as num?)?.toInt() ?? 0,
    lastError: json['last_error'] as String?,
  );

  Map<String, dynamic> toJson() => {
    'local_path': localPath,
    'storage_path': storagePath,
    'attempt_id': attemptId,
    'quest_id': questId,
    'step_order': stepOrder,
    'size_bytes': sizeBytes,
    'captured_at': capturedAt.toIso8601String(),
    'attempts': attempts,
    if (lastError != null) 'last_error': lastError,
  };
}
