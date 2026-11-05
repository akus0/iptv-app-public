import 'package:flutter_test/flutter_test.dart';
import 'package:nox_iptv/models/channel.dart';
import 'package:nox_iptv/models/epg_program.dart';
import 'package:nox_iptv/models/sports.dart';
import 'package:nox_iptv/services/sports_channel_matcher.dart';
import 'package:nox_iptv/services/sports_match_inputs.dart';

final _now = DateTime.utc(2026, 10, 31, 12);
const _fixtures = [
  ('basketball.mens-college-basketball', "Men's Basketball"),
  ('basketball.womens-college-basketball', "Women's Basketball"),
  ('hockey.mens-college-hockey', 'Ice Hockey (M)'),
  ('hockey.womens-college-hockey', 'W Ice Hockey'),
  ('volleyball.womens-college-volleyball', "Women's Volleyball"),
  ('college-football', 'College Football'),
];

SportsGame _game(String league) => SportsGame(
      id: league,
      league: sportsLeagueById(league)!,
      start: _now,
      state: GameState.live,
      statusText: 'Live',
      home: const SportsTeam(
          id: 'mich',
          name: 'Michigan Wolverines',
          shortName: 'Michigan',
          abbreviation: 'MICH',
          location: 'Michigan'),
      away: const SportsTeam(
          id: 'osu',
          name: 'Ohio State Buckeyes',
          shortName: 'Ohio State',
          abbreviation: 'OSU',
          location: 'Ohio State'),
    );

String _title(String sport) =>
    '$sport: Michigan at Ohio State | US: SOCCER PPV 4';

Channel _channel(String id, String title) => Channel(
      id: 'test::$id',
      rawId: id,
      playlistId: 'test',
      name: title,
      group: 'Sports',
      url: 'https://example.invalid/$id',
      epgIdOverride: id,
    );

class _Guide implements SportsMatchGuide {
  final rows = <EpgProgram>[];
  @override
  int changeRevision = 0;
  @override
  DateTime get lastUpdated => _now.add(Duration(seconds: changeRevision));
  @override
  EpgProgram? getCurrentProgram(String id) =>
      rows.where((p) => p.channelId == id).firstOrNull;
  @override
  EpgProgram? getNextProgram(String id) => null;
  @override
  Future<List<EpgProgram>> findProgrammesByTitle(
          DateTime from, DateTime to, List<String> terms) async =>
      List.of(rows);
  @override
  Future<List<EpgProgram>> findSportsProgrammesForChannels(
          List<String> ids, DateTime from, DateTime to) async =>
      rows.where((p) => ids.contains(p.channelId)).toList();
}

class _Picks implements SportsMatchPicks {
  @override
  String? channelIdFor(SportsGame game) => null;
}

EpgProgram _programme(String id, String title) => EpgProgram(
      channelId: id,
      title: title,
      start: _now,
      stop: _now.add(const Duration(hours: 2)),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('shared text facts keep sport and gender decisions fixture-specific',
      () async {
    final guide = _Guide();
    final channels = <Channel>[];
    for (final (league, sport) in _fixtures) {
      channels.add(_channel('name-$league', _title(sport)));
      channels.add(_channel('guide-$league', 'Sports event feed'));
      guide.rows.add(_programme('guide-$league', _title(sport)));
    }
    final games = [for (final (league, _) in _fixtures) _game(league)];
    // Reversing the fixtures and using a new matcher also exercises text
    // evidence shared across matcher instances, not just per-game decisions.
    for (final order in [games, games.reversed.toList()]) {
      final matcher = SportsChannelMatcher(guide, clock: () => _now);
      addTearDown(matcher.dispose);
      await matcher.prepare(channels);
      final results = await matcher.matchDay(order, _Picks());
      for (final game in games) {
        final matches = results[SportsChannelPicks.eventKey(game)]!;
        expect(matches.map((m) => m.channel.rawId).toSet(),
            {'name-${game.league.id}', 'guide-${game.league.id}'},
            reason: game.league.id);
        expect(matches.every((m) => m.isConfident), isTrue);
      }
    }
  });

  test('corrected guide text cannot retain an old sport or gender decision',
      () async {
    final guide = _Guide();
    final matcher = SportsChannelMatcher(guide, clock: () => _now);
    addTearDown(matcher.dispose);
    await matcher.prepare([_channel('rotating', 'Sports event feed')]);
    final games = [for (final (league, _) in _fixtures) _game(league)];
    for (final (league, sport) in [..._fixtures, _fixtures.first]) {
      guide.rows
        ..clear()
        ..add(_programme('rotating', _title(sport)));
      guide.changeRevision++;
      final results = await matcher.matchDay(games, _Picks());
      for (final game in games) {
        final matches = results[SportsChannelPicks.eventKey(game)]!;
        expect(matches.map((m) => m.channel.rawId).toList(),
            game.league.id == league ? ['rotating'] : <String>[],
            reason: '$league must not supply ${game.league.id}');
      }
    }
  });
}
