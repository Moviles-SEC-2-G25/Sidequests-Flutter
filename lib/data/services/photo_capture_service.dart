import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';

/// Wraps the camera (image_picker) for photo proofs. Camera only — a
/// gallery picture could be from any time, so it isn't proof of doing the
/// step (and needs no photo-library permission).
///
/// Resized to at most 1600 px and JPEG-compressed at quality 70: a few
/// hundred KB, far below the bucket's 25 MiB, quick on mobile data. The
/// repository still checks the bytes really are JPEG before uploading.
class PhotoCaptureService {
  static const _maxDimension = 1600.0;
  static const _jpegQuality = 70;

  final ImagePicker _picker;

  PhotoCaptureService({ImagePicker? picker}) : _picker = picker ?? ImagePicker();

  /// Null when the user backs out of the camera.
  Future<Uint8List?> capture() async {
    final file = await _picker.pickImage(
      source: ImageSource.camera,
      preferredCameraDevice: CameraDevice.rear,
      maxWidth: _maxDimension,
      maxHeight: _maxDimension,
      imageQuality: _jpegQuality,
    );
    return file?.readAsBytes();
  }

  /// Android may destroy the app's Activity while the camera is open (low
  /// memory); the photo is then handed back on the next launch instead of
  /// to [capture]. Null when there's nothing to recover.
  Future<Uint8List?> retrieveLost() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return null;
    final response = await _picker.retrieveLostData();
    if (response.isEmpty || response.file == null) return null;
    return response.file!.readAsBytes();
  }
}
