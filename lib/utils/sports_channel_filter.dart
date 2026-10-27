import '../models/channel.dart';
import '../services/sports_channel_matcher.dart';

/// Confidence is independent of loading state. Pending/failed checks must never
/// admit possible matches into the confirmed-channel view.
enum SportsChannelFilter {
  matched,
  possible,
  all;

  String get label => switch (this) {
        matched => 'With channel',
        possible => 'Possible channels',
        all => 'All events',
      };
  String get description => switch (this) {
        matched => 'Event-specific evidence or your saved choice',
        possible => 'Possible coverage and events still being checked',
        all => 'Include events with no channel found',
      };
  ChannelMatch? preferred(Iterable<ChannelMatch> matches) =>
      (this == matched ? matches.where((m) => m.isConfident) : matches)
          .firstOrNull;
  bool accepts(List<ChannelMatch> matches, {required bool pending}) =>
      switch (this) {
        matched => matches.any((m) => m.isConfident),
        possible => matches.isNotEmpty || pending,
        all => true,
      };
}

/// Display playback identity without changing matching confidence or filter
/// admission. Guide refreshes must not label an already playing tile with a
/// different recommendation while its new saved choice is being checked.
ChannelMatch? displayedSportsChannel(
    List<ChannelMatch> matches, SportsChannelFilter filter,
    {Channel? playing, String? savedId}) {
  if (playing == null) return filter.preferred(matches);
  final evidence = matches.where((m) => m.channel.id == playing.id).firstOrNull;
  if (savedId == playing.id) {
    return ChannelMatch(playing, MatchReason.pick, 1000,
        programme: evidence?.programme);
  }
  return evidence ??
      ChannelMatch(playing, MatchReason.sport, 0,
          detail: 'Playing channel · current match unverified');
}
