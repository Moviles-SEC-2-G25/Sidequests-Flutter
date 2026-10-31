/// What the user last picked on Explore ("Tengo...", scope and category), so
/// the screen opens the way they left it. The defaults are what a first
/// launch shows.
///
/// Persisted locally only: it's how this phone gets used, not account data.
class ExploreFilters {
  final int minutes;
  final String locationScope; // all | gps | anywhere

  /// null = "Todo", 'sponsored', or a real category.
  final String? category;

  const ExploreFilters({this.minutes = 30, this.locationScope = 'all', this.category});

  factory ExploreFilters.fromJson(Map<String, dynamic> json) => ExploreFilters(
    minutes: (json['minutes'] as num?)?.toInt() ?? 30,
    locationScope: json['location_scope'] as String? ?? 'all',
    category: json['category'] as String?,
  );

  Map<String, dynamic> toJson() => {
    'minutes': minutes,
    'location_scope': locationScope,
    if (category != null) 'category': category,
  };
}
