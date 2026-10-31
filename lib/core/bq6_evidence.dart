import '../models/abandonment_reason.dart';

/// The BQ6 evidence of a `quest_abandoned` event: same keys, bands and
/// thresholds as Kotlin's Bq6Evidence (Sidequests-Analytics/docs/EVENT_SCHEMA.md).
/// Kotlin's distance comes from the catalogue; here it's the GPS distance from
/// the user to the quest when abandoning, and [_distanceSource] says so. Kotlin's
/// on_campus band doesn't apply to Flutter.
const _schemaVersion = 1;
const _distanceSource = 'gps';
const _platform = 'flutter';

String questDistanceBand({required int? meters, required bool isAnywhere}) {
  if (isAnywhere) return 'location_independent';
  if (meters == null) return 'unknown';
  if (meters < 500) return 'under_500_m';
  if (meters < 1500) return '500_m_to_1_5_km';
  return 'over_1_5_km';
}

/// "850 m", "1,2 km", "Donde sea" or "Desconocida".
String questDistanceLabel({required int? meters, required bool isAnywhere}) {
  if (isAnywhere) return 'Donde sea';
  if (meters == null) return 'Desconocida';
  if (meters < 1000) return '$meters m';
  return '${(meters / 1000).toStringAsFixed(1).replaceAll('.', ',')} km';
}

int questProgressPercent({required int completedSteps, required int totalSteps}) =>
    totalSteps == 0 ? 0 : (completedSteps * 100 / totalSteps).round();

/// [distanceMeters] is ignored for a quest done anywhere: there's nothing to
/// travel to, whatever coordinates it may have.
Map<String, dynamic> questAbandonedMetadata({
  required AbandonmentReason reason,
  required String attemptId,
  required bool isAnywhere,
  required int? distanceMeters,
  required int? durationMinutes,
  required double? estimatedCost,
  required int currentStepIndex,
  required int completedSteps,
  required int totalSteps,
  required bool hadPhotoProof,
  required int uploadedPhotoProofCount,
}) {
  final meters = isAnywhere ? null : distanceMeters;
  return {
    'schema_version': _schemaVersion,
    'platform': _platform,
    'attempt_id': attemptId,
    'reason': reason.code,
    'reason_code': reason.code,
    'reason_label': reason.label,
    'quest_duration_minutes': ?durationMinutes,
    'estimated_cost': ?estimatedCost,
    'quest_distance_label': questDistanceLabel(meters: meters, isAnywhere: isAnywhere),
    'quest_distance_meters': ?meters,
    'quest_distance_band': questDistanceBand(meters: meters, isAnywhere: isAnywhere),
    'quest_distance_source': _distanceSource,
    'current_step_index': currentStepIndex,
    'completed_step_count': completedSteps,
    'total_step_count': totalSteps,
    'progress_percent': questProgressPercent(completedSteps: completedSteps, totalSteps: totalSteps),
    'had_photo_proof': hadPhotoProof,
    'uploaded_photo_proof_count': uploadedPhotoProofCount,
  };
}
