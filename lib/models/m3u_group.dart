import 'channel.dart';

/// A `group-title` from the M3U playlist together with the channels that
/// belong to it. Computed on demand from the flat channel list — never
/// persisted directly, so it carries no JSON serialization.
class M3uGroup {
  M3uGroup({
    required this.title,
    required this.playlistId,
    required this.channels,
    this.isHidden = false,
  });

  final String title;

  /// Which playlist this group belongs to — see `Channel.playlistId`'s
  /// doc comment. Group identity (hidden/favorited-group prefs, Group
  /// Management's own lookups) is now `(playlistId, title)`, not just
  /// `title` alone, since two different providers can easily have a
  /// same-named category (e.g. both have "Sports").
  final String playlistId;
  final List<Channel> channels;
  final bool isHidden;
}
