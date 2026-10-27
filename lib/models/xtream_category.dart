/// A live/VOD/series category from the Xtream Codes API — pairs the
/// numeric `category_id` the API needs for lazy per-category fetches with
/// the human-readable `category_name` shown in the UI.
class XtreamCategory {
  XtreamCategory({required this.id, required this.name});

  final String id;
  final String name;

  Map<String, dynamic> toJson() => {'id': id, 'name': name};

  factory XtreamCategory.fromJson(Map<String, dynamic> json) => XtreamCategory(
        id: json['id'] as String,
        name: json['name'] as String,
      );
}
