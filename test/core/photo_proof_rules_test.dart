import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sidequests/core/photo_proof_rules.dart';

void main() {
  test('storage path matches migration 009: 4 segments, 1-based step, lowercase .jpg', () {
    final path = questProofStoragePath(
      userId: 'user-uuid',
      attemptId: 'attempt-uuid',
      questId: 'ramen-spot',
      stepOrder: 0, // zero-based in quest_photo_proofs…
      uniqueId: 'f3c1',
    );

    expect(path, 'user-uuid/attempt-uuid/ramen-spot/step-1-f3c1.jpg'); // …one-based in the file name
    expect(path.split('/'), hasLength(4));
  });

  test('isJpeg checks the FF D8 FF signature, not the file name', () {
    expect(isJpeg(Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 0x00])), isTrue);
    expect(isJpeg(Uint8List.fromList([0x89, 0x50, 0x4E, 0x47])), isFalse); // PNG
    expect(isJpeg(Uint8List(0)), isFalse);
  });

  test('bucket and size limit are the shared contract values', () {
    expect(kQuestProofsBucket, 'quest-proofs');
    expect(kQuestProofMaxBytes, 25 * 1024 * 1024);
  });
}
