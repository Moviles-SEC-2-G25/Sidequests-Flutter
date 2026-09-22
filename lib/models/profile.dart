/// Mirrors `public.profiles` (Sidequests-Backend/supabase/migrations/001_foundation_schema_rls.sql).
class Profile {
  final String id;
  final String? displayName;
  final String? avatarUrl;

  const Profile({required this.id, this.displayName, this.avatarUrl});

  factory Profile.fromJson(Map<String, dynamic> json) => Profile(
    id: json['id'] as String,
    displayName: json['display_name'] as String?,
    avatarUrl: json['avatar_url'] as String?,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'display_name': displayName,
    'avatar_url': avatarUrl,
  };

  Profile copyWith({String? displayName, String? avatarUrl}) => Profile(
    id: id,
    displayName: displayName ?? this.displayName,
    avatarUrl: avatarUrl ?? this.avatarUrl,
  );
}
