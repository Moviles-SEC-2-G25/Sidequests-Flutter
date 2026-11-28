/// The states of Kotlin's OfflinePackStatus, one to one.
enum OfflinePackStatus { ready, pendingDownload, downloading, failed }

/// One quest of the offline pack and how ready it is (Kotlin's OfflinePackEntry).
class OfflinePackEntry {
  final String questId;
  final OfflinePackStatus status;

  /// Why it failed; null otherwise.
  final String? message;

  const OfflinePackEntry(this.questId, this.status, {this.message});

  @override
  bool operator ==(Object other) =>
      other is OfflinePackEntry &&
      other.questId == questId &&
      other.status == status &&
      other.message == message;

  @override
  int get hashCode => Object.hash(questId, status, message);

  @override
  String toString() => 'OfflinePackEntry($questId, ${status.name}${message == null ? '' : ', $message'})';
}
