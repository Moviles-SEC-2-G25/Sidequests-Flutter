/// Spanish display labels for the real category/tag values seeded in
/// Sidequests-Backend/supabase/seed.sql (Outdoors, Food, Art, Learning,
/// Mindfulness, Movement, plus the "social" tag). The Figma reference's
/// copy is in Spanish while the actual backend catalogue is in English, so
/// this is presentation-only — filtering and recommendation matching still
/// use the real underlying value, never the label.
const Map<String, String> kCategoryLabelsEs = {
  'outdoors': 'Aire libre',
  'food': 'Gastronomía',
  'art': 'Arte',
  'learning': 'Aprendizaje',
  'mindfulness': 'Bienestar',
  'movement': 'Movimiento',
  'social': 'Social',
};

/// Interest options offered in the preferences editor. Each value is a real
/// category or tag the `recommend_quests` RPC actually matches against
/// (`lower(interest) = lower(category) or lower(interest) = any(tags)`), so
/// picking one has a real effect on recommendations rather than being
/// decorative.
const List<String> kInterestOptions = [
  'outdoors',
  'food',
  'art',
  'learning',
  'mindfulness',
  'movement',
  'social',
];

String categoryLabelEs(String value) =>
    kCategoryLabelsEs[value.toLowerCase()] ?? value;
