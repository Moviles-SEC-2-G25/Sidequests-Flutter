import 'dart:typed_data';

/// Shared contract with Kotlin (Sidequests-Backend migration 009 /
/// docs/API_CONTRACT.md): private bucket, JPEG only, up to 25 MiB.
const String kQuestProofsBucket = 'quest-proofs';
const int kQuestProofMaxBytes = 26214400;

/// `<user-id>/<attempt-id>/<quest-id>/step-<1-based step>-<uuid>.jpg`.
///
/// The storage and table RLS policies check every segment: exactly four,
/// the owner's id first, the attempt and quest it belongs to, and a
/// lowercase `.jpg` file named after the 1-based step number — while
/// `quest_photo_proofs.step_order` stays zero-based.
String questProofStoragePath({
  required String userId,
  required String attemptId,
  required String questId,
  required int stepOrder,
  required String uniqueId,
}) => '$userId/$attemptId/$questId/step-${stepOrder + 1}-$uniqueId.jpg';

/// JPEG files start with FF D8 FF. The bucket only checks the declared
/// content type, so this makes sure the bytes really are what we declare.
bool isJpeg(Uint8List bytes) =>
    bytes.length >= 3 && bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF;
