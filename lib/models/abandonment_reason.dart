/// Why a mission was abandoned (BQ6). The codes and emojis are the ones in
/// Kotlin's AbandonmentReason: they end up in `user_quests.abandon_reason` and
/// in the `quest_abandoned` event, so both apps must write the same values.
enum AbandonmentReason {
  ranOutOfTime('ran_out_of_time', 'I ran out of time', '⏰'),
  tooFar('too_far', 'It was too far away', '📍'),
  tooExpensive('too_expensive', 'It cost more than expected', '💸'),
  placeUnavailable('place_unavailable', 'The place was closed or unavailable', '🔒'),
  tooDifficult('too_difficult', 'It was too hard for today', '😅'),
  weatherOrMoodChanged('weather_or_mood_changed', 'The weather or my mood changed', '🌧'),
  other('other', 'Other reason', '💬');

  final String code;
  final String label;
  final String emoji;

  const AbandonmentReason(this.code, this.label, this.emoji);
}
