import '../models/channel.dart';
import '../models/sports.dart';
import 'epg_service.dart';
import 'playlist_manager.dart';
import 'sports_channel_matcher.dart';
import 'sports_follows.dart';
import 'sports_service.dart';
import 'storage_service.dart';

/// A game being played right now and every channel found for it, best
/// first (your pick, then event channels, the guide, the network).
typedef LiveGameChannel = ({SportsGame game, List<ChannelMatch> matches});

extension LiveGameChannelBest on LiveGameChannel {
  Channel get channel => matches.first.channel;
}

/// The Multiview channel picker's two sports shortcuts:
/// - "Live now": games playing right now in the viewer's Sports
///   leagues (+ followed teams' leagues), each with every matched channel
///   — the same matching as Sports and the player side panel (the
///   first suggestion isn't always the best, so the
///   picker lets the viewer choose, and remembers it via [rememberPick]);
/// - "Sports": every channel whose group or name looks like sports.
class MultiviewSports {
  MultiviewSports._();

  /// Whole-word sports terms in a group or channel name ("NHL | Events",
  /// "USA | SPORTS", "ESPN 2", "TSN 1", "DAZN 1"…). Words only: "f1" must
  /// not match "HDF1".
  static final _sportsWords = RegExp(
      r'\b(sports?|deportes?|esportes?|espn\w*|tsn\d*|sportsnet|dazn|bein|'
      r'eurosport|supersport|nfl|nba|nhl|mlb|mls|ncaa|ufc|wwe|pfl|ppv|f1|'
      r'formula 1|nascar|indycar|motogp|golf|tennis|boxing|hockey|soccer|'
      r'football|futbol|basketball|baseball|cricket|rugby|racing|redzone)\b',
      caseSensitive: false);

  static bool isSports(Channel c) =>
      _sportsWords.hasMatch(c.group) || _sportsWords.hasMatch(c.name);

  /// Live games with at least one matched channel, earliest start first.
  /// Games with no channel in the viewer's playlists are left out.
  static Future<List<LiveGameChannel>> liveGames({
    required StorageService storage,
    required PlaylistManager playlist,
    required EpgService epg,
  }) async {
    final follows = SportsFollows.load(storage);
    final leagues = <String, SportsLeague>{
      for (final l in savedSportsLeagues(storage)) l.id: l,
      for (final t in follows.teams)
        if (sportsLeagueById(t.leagueId) case final l?) l.id: l,
    };
    if (leagues.isEmpty) return const [];
    final games = (await SportsService.instance
            .gamesForDay(leagues.values.toList(), DateTime.now()))
        .where((g) => g.state == GameState.live)
        .toList()
      ..sort((a, b) => a.start.compareTo(b.start));
    if (games.isEmpty) return const [];
    final matcher = SportsChannelMatcher.shared(epg);
    await playlist.ensureLiveChannelsLoaded();
    await matcher.prepare(playlist.visibleChannels(category: 'tv'));
    final matches =
        await matcher.matchDay(games, SportsChannelPicks.load(storage));
    return [
      for (final g in games)
        if (matches[SportsChannelPicks.eventKey(g)] case final m?
            when m.isNotEmpty)
          (game: g, matches: m),
    ];
  }

  /// The viewer chose [channel] for [game]: saved as that game's pick, so
  /// Sports, the player side panel and this picker list it first.
  static Future<void> rememberPick(
      StorageService storage, SportsGame game, Channel channel) async {
    final picks = SportsChannelPicks.load(storage);
    if (picks.channelIdFor(game) == channel.id) return;
    await picks.pickForGame(game, channel.id);
  }

  /// [live] narrowed to [query] (game title or any of its channels' names).
  static List<LiveGameChannel> search(
      List<LiveGameChannel> live, String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return live;
    return [
      for (final l in live)
        if (l.game.title.toLowerCase().contains(q) ||
            l.matches.any((m) => m.channel.name.toLowerCase().contains(q)))
          l,
    ];
  }

  /// "Avalanche at Flyers · 2nd 12:10" (golf/racing: the event's title) —
  /// no score, so Sports's hide-scores setting is never crossed.
  static String label(SportsGame g) {
    final status = g.statusText.trim();
    return status.isEmpty ? g.title : '${g.title} · $status';
  }
}
