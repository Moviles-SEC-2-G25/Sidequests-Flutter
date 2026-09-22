/// Mirrors `public.user_preferences`.
class UserPreferences {
  final List<String> interests;
  final String preferredDifficulty; // easy | medium | hard
  final int typicalTimeMinutes;
  final double budgetMax;
  final String socialLevel; // solo | social | group
  final String locationMode; // all | gps | anywhere

  const UserPreferences({
    this.interests = const [],
    this.preferredDifficulty = 'easy',
    this.typicalTimeMinutes = 30,
    this.budgetMax = 20,
    this.socialLevel = 'solo',
    this.locationMode = 'all',
  });

  factory UserPreferences.fromJson(Map<String, dynamic> json) =>
      UserPreferences(
        interests: List<String>.from(json['interests'] as List? ?? const []),
        preferredDifficulty: json['preferred_difficulty'] as String? ?? 'easy',
        typicalTimeMinutes: (json['typical_time_minutes'] as num?)?.toInt() ?? 30,
        budgetMax: (json['budget_max'] as num?)?.toDouble() ?? 20,
        socialLevel: json['social_level'] as String? ?? 'solo',
        locationMode: json['location_mode'] as String? ?? 'all',
      );

  Map<String, dynamic> toJson() => {
    'interests': interests,
    'preferred_difficulty': preferredDifficulty,
    'typical_time_minutes': typicalTimeMinutes,
    'budget_max': budgetMax,
    'social_level': socialLevel,
    'location_mode': locationMode,
  };

  UserPreferences copyWith({
    List<String>? interests,
    String? preferredDifficulty,
    int? typicalTimeMinutes,
    double? budgetMax,
    String? socialLevel,
    String? locationMode,
  }) => UserPreferences(
    interests: interests ?? this.interests,
    preferredDifficulty: preferredDifficulty ?? this.preferredDifficulty,
    typicalTimeMinutes: typicalTimeMinutes ?? this.typicalTimeMinutes,
    budgetMax: budgetMax ?? this.budgetMax,
    socialLevel: socialLevel ?? this.socialLevel,
    locationMode: locationMode ?? this.locationMode,
  );
}
