/// Why a mission was abandoned (BQ6). The codes and emojis are the ones in
/// Kotlin's AbandonmentReason: they end up in `user_quests.abandon_reason` and
/// in the `quest_abandoned` event, so both apps must write the same values.
enum AbandonmentReason {
  ranOutOfTime('ran_out_of_time', 'Se me acabó el tiempo', '⏰'),
  tooFar('too_far', 'Quedaba muy lejos', '📍'),
  tooExpensive('too_expensive', 'Era más costosa de lo esperado', '💸'),
  placeUnavailable('place_unavailable', 'El lugar estaba cerrado o no disponible', '🔒'),
  tooDifficult('too_difficult', 'Era muy difícil para hoy', '😅'),
  weatherOrMoodChanged('weather_or_mood_changed', 'Cambió el clima o mi ánimo', '🌧'),
  other('other', 'Otra razón', '💬');

  final String code;
  final String label;
  final String emoji;

  const AbandonmentReason(this.code, this.label, this.emoji);
}
