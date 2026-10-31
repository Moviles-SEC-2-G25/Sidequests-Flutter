/// One write waiting for a connection (Queue & Sync). Generic so other
/// operations can join the queue: QuestRepository decides what each [type]
/// sends, and [payload] must be replayable — same payload, same result.
class PendingWrite {
  /// `payload` is a new `user_quests` row with a client-generated id.
  static const acceptQuest = 'accept_quest';

  final String type;
  final Map<String, dynamic> payload;
  final DateTime createdAt;

  const PendingWrite({required this.type, required this.payload, required this.createdAt});

  factory PendingWrite.fromJson(Map<String, dynamic> json) => PendingWrite(
    type: json['type'] as String,
    payload: (json['payload'] as Map).cast<String, dynamic>(),
    createdAt: DateTime.parse(json['created_at'] as String),
  );

  Map<String, dynamic> toJson() => {
    'type': type,
    'payload': payload,
    'created_at': createdAt.toUtc().toIso8601String(),
  };
}
