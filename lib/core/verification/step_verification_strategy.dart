import '../../models/quest.dart';

/// Whether the app may read a precise location right now.
enum LocationAccess { unknown, granted, denied, serviceDisabled, approximateOnly }

/// What the environment (and, later, the user) has provided so far for the
/// current step. Plain values — no geolocator types — so every strategy
/// stays pure Dart and unit-testable.
class VerificationEvidence {
  final LocationAccess locationAccess;
  final double? latitude;
  final double? longitude;
  final double? accuracyMeters;

  /// Feature (f): storage path of this step's registered photo proof
  /// (uploaded AND recorded in quest_photo_proofs) — never a local file.
  final String? photoPath;

  const VerificationEvidence({
    this.locationAccess = LocationAccess.unknown,
    this.latitude,
    this.longitude,
    this.accuracyMeters,
    this.photoPath,
  });

  bool get hasFix => latitude != null && longitude != null;

  VerificationEvidence withPhoto(String? photoPath) => VerificationEvidence(
    locationAccess: locationAccess,
    latitude: latitude,
    longitude: longitude,
    accuracyMeters: accuracyMeters,
    photoPath: photoPath,
  );
}

sealed class VerificationResult {
  const VerificationResult();
}

class Verified extends VerificationResult {
  const Verified();
}

/// Not satisfied yet. [distanceMeters] lets the UI say "estás a 120 m".
class Pending extends VerificationResult {
  final double? distanceMeters;
  const Pending([this.distanceMeters]);
}

/// Can't be checked automatically (no coordinates, no permission...).
/// The step falls back to the manual "Completar" button — never blocked.
class Unavailable extends VerificationResult {
  final String reason;
  const Unavailable(this.reason);
}

/// Strategy pattern: one way of verifying a quest step per
/// `quest_steps.verification_type`. QuestViewModel is the context: it
/// applies the current step's strategy to each new piece of evidence
/// without ever asking which type it is, and the view renders
/// [parts] instead of switching on the type string.
abstract interface class StepVerificationStrategy {
  /// The VM only turns the GPS on when the current step needs it.
  bool get needsLocation;
  bool get needsPhoto;

  /// False only for NoVerification: a step without evidence is completed
  /// with the button, never automatically.
  bool get requiresEvidence;

  /// The individual checks to show, one row each (a composite's children).
  List<StepVerificationStrategy> get parts;

  VerificationResult verify(Quest quest, VerificationEvidence evidence);

  /// Whether the "Completar" button may complete the step right now.
  /// Location never blocks it (the check-in is a convenience: GPS fails
  /// indoors); a photo step does until its proof is uploaded.
  bool allowsManualCompletion(Quest quest, VerificationEvidence evidence);
}
