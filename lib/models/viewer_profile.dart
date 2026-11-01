import '../l10n/l10n.dart';

/// One of several viewers sharing this device's playlists — the same
/// catalog/credentials, but each with their own favorites, hidden groups/
/// channels, and watch history. Deliberately a distinct name from
/// `PlaylistProfile` (a playlist/provider login, a completely different
/// concept this app already uses "Profile" for) to avoid confusing the two
/// in code or in conversation.
///
/// [ViewerProfile.mainId] is special: an upgrading install with no viewer
/// profiles yet is given exactly one, "Main", whose data is every existing
/// unsuffixed storage key as-is — see `AppConstants`'s "Viewer profiles"
/// section for why that means zero data movement on upgrade. Main can never
/// be restricted or deleted (enforced by callers, not this class).
class ViewerProfile {
  ViewerProfile({
    required this.id,
    required this.name,
    required this.colorIndex,
    required this.isRestricted,
    required this.createdAt,
  });

  static const String mainId = 'main';

  final String id;
  String name;
  int colorIndex;

  /// A restricted (“kid”) viewer uses an *allowlist* for group visibility
  /// (`PlaylistManager`'s shown-groups set) instead of the blocklist every
  /// other viewer uses — so a category a provider adds tomorrow, or a whole
  /// playlist added later, defaults to hidden for them instead of visible.
  /// Fixed at creation time for now; toggling it on an existing profile
  /// would need to convert between an allowlist and a blocklist, which this
  /// first version doesn't support.
  final bool isRestricted;
  final DateTime createdAt;

  bool get isMain => id == mainId;

  /// The stored default name 'Main' is shown translated; a name the user
  /// typed is shown as-is. Never write this back to storage.
  String get displayName => isMain && name == 'Main' ? tr('Main') : name;

  factory ViewerProfile.main() => ViewerProfile(
        id: mainId,
        name: 'Main',
        colorIndex: 0,
        isRestricted: false,
        createdAt: DateTime.now(),
      );

  ViewerProfile copyWith({String? name, int? colorIndex}) => ViewerProfile(
        id: id,
        name: name ?? this.name,
        colorIndex: colorIndex ?? this.colorIndex,
        isRestricted: isRestricted,
        createdAt: createdAt,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'colorIndex': colorIndex,
        'isRestricted': isRestricted,
        'createdAt': createdAt.millisecondsSinceEpoch,
      };

  factory ViewerProfile.fromJson(Map<String, dynamic> json) => ViewerProfile(
        id: json['id'] as String,
        name: json['name'] as String,
        colorIndex: json['colorIndex'] as int? ?? 0,
        isRestricted: json['isRestricted'] as bool? ?? false,
        createdAt:
            DateTime.fromMillisecondsSinceEpoch(json['createdAt'] as int? ?? 0),
      );
}
