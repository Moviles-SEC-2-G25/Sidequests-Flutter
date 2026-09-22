/// Mirrors `public.quests` — the shared catalogue used by Kotlin and Flutter.
class Quest {
  final String id;
  final String title;
  final String description;
  final String category;
  final String? emoji;
  final int durationMinutes;
  final double estimatedCost;
  final String difficulty; // easy | medium | hard
  final String locationMode; // gps | anywhere
  final String socialLevel; // solo | social | group
  final String? locationName;
  final double? latitude;
  final double? longitude;
  final List<String> tags;
  final bool isNew;
  final bool isSponsored;
  final String? sponsorName;
  final bool isGroup;

  const Quest({
    required this.id,
    required this.title,
    this.description = '',
    required this.category,
    this.emoji,
    required this.durationMinutes,
    this.estimatedCost = 0,
    required this.difficulty,
    required this.locationMode,
    required this.socialLevel,
    this.locationName,
    this.latitude,
    this.longitude,
    this.tags = const [],
    this.isNew = false,
    this.isSponsored = false,
    this.sponsorName,
    this.isGroup = false,
  });

  factory Quest.fromJson(Map<String, dynamic> json) => Quest(
    id: json['id'] as String,
    title: json['title'] as String,
    description: json['description'] as String? ?? '',
    category: json['category'] as String,
    emoji: json['emoji'] as String?,
    durationMinutes: (json['duration_minutes'] as num).toInt(),
    estimatedCost: (json['estimated_cost'] as num?)?.toDouble() ?? 0,
    difficulty: json['difficulty'] as String,
    locationMode: json['location_mode'] as String,
    socialLevel: json['social_level'] as String,
    locationName: json['location_name'] as String?,
    latitude: (json['latitude'] as num?)?.toDouble(),
    longitude: (json['longitude'] as num?)?.toDouble(),
    tags: List<String>.from(json['tags'] as List? ?? const []),
    isNew: json['is_new'] as bool? ?? false,
    isSponsored: json['is_sponsored'] as bool? ?? false,
    sponsorName: json['sponsor_name'] as String?,
    isGroup: json['is_group'] as bool? ?? false,
  );
}
