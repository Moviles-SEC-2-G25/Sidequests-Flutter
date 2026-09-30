import 'package:local_auth/local_auth.dart';

/// Wraps the device's biometric sensor (fingerprint / Face ID). Never throws:
/// unsupported devices and platform errors degrade to "not available" /
/// "not authenticated".
class BiometricService {
  final LocalAuthentication _auth;

  BiometricService({LocalAuthentication? auth}) : _auth = auth ?? LocalAuthentication();

  /// True if the device has biometric hardware with at least one enrolled
  /// biometric.
  Future<bool> isAvailable() async {
    try {
      if (!await _auth.isDeviceSupported() || !await _auth.canCheckBiometrics) {
        return false;
      }
      return (await _auth.getAvailableBiometrics()).isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  /// Prompts for a biometric. False on failure, cancellation or error.
  Future<bool> authenticate(String reason) async {
    try {
      return await _auth.authenticate(
        localizedReason: reason,
        options: const AuthenticationOptions(biometricOnly: true, stickyAuth: true),
      );
    } catch (_) {
      return false;
    }
  }
}
