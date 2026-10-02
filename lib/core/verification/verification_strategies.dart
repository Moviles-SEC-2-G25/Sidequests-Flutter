import '../../models/quest.dart';
import '../distance.dart';
import 'step_verification_strategy.dart';

/// Picks the strategy for a `quest_steps.verification_type` (DB check:
/// none | photo | location | photo_and_location). Unknown values degrade
/// to NoVerification rather than breaking the mission.
StepVerificationStrategy strategyFor(String verificationType) => switch (verificationType) {
  'location' => const LocationVerification(),
  'photo' => const PhotoVerification(),
  'photo_and_location' => const CompositeVerification([
    LocationVerification(),
    PhotoVerification(),
  ]),
  _ => const NoVerification(),
};

/// 'none': nothing to check; the step is completed with the button.
class NoVerification implements StepVerificationStrategy {
  const NoVerification();

  @override
  bool get needsLocation => false;
  @override
  bool get needsPhoto => false;
  @override
  bool get requiresEvidence => false;
  @override
  List<StepVerificationStrategy> get parts => const [];

  @override
  VerificationResult verify(Quest quest, VerificationEvidence evidence) => const Verified();

  @override
  bool allowsManualCompletion(Quest quest, VerificationEvidence evidence) => true;
}

/// Automatic check-in: verified once the device is within [radiusMeters]
/// of the quest's coordinates (Haversine, lib/core/distance.dart).
///
/// The fix's own error must also be small enough ([maxAccuracyMeters]) —
/// "40 m away ± 300 m" is not proof of being there.
class LocationVerification implements StepVerificationStrategy {
  final double radiusMeters;
  final double maxAccuracyMeters;

  const LocationVerification({this.radiusMeters = 50, this.maxAccuracyMeters = 75});

  @override
  bool get needsLocation => true;
  @override
  bool get needsPhoto => false;
  @override
  bool get requiresEvidence => true;
  @override
  List<StepVerificationStrategy> get parts => [this];

  @override
  VerificationResult verify(Quest quest, VerificationEvidence evidence) {
    // Migration 003 allows quests without coordinates.
    if (quest.latitude == null || quest.longitude == null) {
      return const Unavailable('Esta misión no tiene ubicación: complétalo manualmente.');
    }
    switch (evidence.locationAccess) {
      case LocationAccess.denied:
        return const Unavailable('Permite el acceso a tu ubicación para verificarlo solo.');
      case LocationAccess.serviceDisabled:
        return const Unavailable('Activa el GPS para verificarlo solo.');
      case LocationAccess.approximateOnly:
        return const Unavailable('Activa la ubicación precisa para verificarlo solo.');
      case LocationAccess.unknown:
      case LocationAccess.granted:
        break;
    }
    if (!evidence.hasFix) return const Pending();

    final distance = haversineMeters(
      evidence.latitude!,
      evidence.longitude!,
      quest.latitude!,
      quest.longitude!,
    );
    final isAccurate = (evidence.accuracyMeters ?? double.infinity) <= maxAccuracyMeters;
    return distance <= radiusMeters && isAccurate ? const Verified() : Pending(distance);
  }

  @override
  bool allowsManualCompletion(Quest quest, VerificationEvidence evidence) => true;
}

/// Photo proof — feature (f): verified only once the photo is uploaded to
/// the private bucket AND registered in quest_photo_proofs. A photo still
/// waiting on the device (no connection) doesn't count.
class PhotoVerification implements StepVerificationStrategy {
  const PhotoVerification();

  @override
  bool get needsLocation => false;
  @override
  bool get needsPhoto => true;
  @override
  bool get requiresEvidence => true;
  @override
  List<StepVerificationStrategy> get parts => [this];

  @override
  VerificationResult verify(Quest quest, VerificationEvidence evidence) =>
      evidence.photoPath == null ? const Pending() : const Verified();

  @override
  bool allowsManualCompletion(Quest quest, VerificationEvidence evidence) =>
      verify(quest, evidence) is Verified;
}

/// 'photo_and_location': verified only when every part is (Strategy +
/// Composite). Not verified yet if any part is pending; unavailable if any
/// part can't be checked at all.
class CompositeVerification implements StepVerificationStrategy {
  final List<StepVerificationStrategy> strategies;

  const CompositeVerification(this.strategies);

  @override
  bool get needsLocation => strategies.any((s) => s.needsLocation);
  @override
  bool get needsPhoto => strategies.any((s) => s.needsPhoto);
  @override
  bool get requiresEvidence => strategies.any((s) => s.requiresEvidence);
  @override
  List<StepVerificationStrategy> get parts => [for (final s in strategies) ...s.parts];

  @override
  VerificationResult verify(Quest quest, VerificationEvidence evidence) {
    final results = strategies.map((s) => s.verify(quest, evidence)).toList();
    final unavailable = results.whereType<Unavailable>();
    if (unavailable.isNotEmpty) return unavailable.first;
    final pending = results.whereType<Pending>();
    if (pending.isNotEmpty) return pending.first;
    return const Verified();
  }

  @override
  bool allowsManualCompletion(Quest quest, VerificationEvidence evidence) =>
      strategies.every((s) => s.allowsManualCompletion(quest, evidence));
}
