import 'package:flutter_test/flutter_test.dart';
import 'package:nox_iptv/models/channel.dart';
import 'package:nox_iptv/models/epg_program.dart';
import 'package:nox_iptv/models/sports.dart';
import 'package:nox_iptv/services/sports_channel_matcher.dart';
import 'package:nox_iptv/services/sports_match_inputs.dart';

class _Guide implements SportsMatchGuide {
  final rows = <String, EpgProgram>{};
  int reads = 0;
  @override
  int get changeRevision => 0;
  @override
  DateTime? get lastUpdated => null;
  @override
  EpgProgram? getCurrentProgram(String id) => rows[id];
  @override
  EpgProgram? getNextProgram(String id) => null;
  @override
  Future<List<EpgProgram>> findProgrammesByTitle(
      DateTime from, DateTime to, List<String> terms) async {
    reads++;
    return [];
  }

  @override
  Future<List<EpgProgram>> findSportsProgrammesForChannels(
      List<String> ids, DateTime from, DateTime to) async {
    reads++;
    return [];
  }
}

class _Picks implements SportsMatchPicks {
  @override
  String? channelIdFor(SportsGame game) => null;
}

final now = DateTime.utc(2026, 10, 31, 6);
SportsGame game(String network,
        {SportsLeague? league,
        bool online = false,
        String country = '',
        String medium = 'TV'}) =>
    SportsGame(
      id: '${league?.id}:$network:$online:$country:$medium',
      league: league ?? sportsLeagueById('college-football')!,
      start: now,
      state: GameState.live,
      statusText: '',
      home: const SportsTeam(
          id: 'h',
          name: 'Aster Athletic',
          shortName: 'Aster',
          abbreviation: 'AST'),
      away: const SportsTeam(
          id: 'a',
          name: 'Birch United',
          shortName: 'Birch',
          abbreviation: 'BIR'),
      scoreboardBroadcasts: online
          ? []
          : [
              SportsBroadcast(network,
                  source: 'fixture', country: country, medium: medium)
            ],
      onlineBroadcasts: online
          ? [
              SportsBroadcast(network,
                  source: 'fixture', country: country, medium: medium)
            ]
          : [],
    );
Channel channel(String name) => Channel(
    id: name,
    rawId: name,
    playlistId: 'test',
    name: name,
    group: 'US| Sports',
    url: 'https://example.invalid/feed');
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Guide guide;
  late SportsChannelMatcher matcher;
  setUp(() {
    guide = _Guide();
    matcher = SportsChannelMatcher(guide, clock: () => now);
  });
  tearDown(() => matcher.dispose());
  Future<List<ChannelMatch>> match(SportsGame fixture) async =>
      (await matcher.matchDay([fixture], _Picks())).values.single;
  for (final pair in [
    ('ACCN', 'ACC Network'),
    ('SECN', 'SEC Network'),
    ('CBSSN', 'CBS Sports Network'),
    ('BTN', 'Big Ten Network'),
    ('FS1', 'Fox Sports 1'),
    ('FS2', 'Fox Sports 2'),
    ('ESPNU', 'ESPN U'),
    ('Golf Chnl', 'Golf Channel'),
    ('USA Net', 'USA Network'),
    ('NBA TV', 'NBATV'),
  ]) {
    test('${pair.$1} preserves both exact broadcaster spellings and metadata',
        () async {
      await matcher.prepare([channel(pair.$1), channel('US: ${pair.$2} HD')]);
      for (final name in [pair.$1, pair.$2]) {
        final rows = await match(game(name));
        expect(rows.map((m) => m.channel.name).toSet(),
            {pair.$1, 'US: ${pair.$2} HD'});
        expect(
            rows.every(
                (m) => m.reason == MatchReason.network && m.detail == name),
            isTrue);
      }
    });
  }
  test(
      'every configured league retains its broadcaster confidence policy without guide reads',
      () async {
    await matcher.prepare([channel('ACC Network')]);
    final leagues = {
      for (final l in [
        ...kSportsLeagues,
        ...kSportsLeagueBank,
        ...kGuideSportsLeagues
      ])
        l.id: l
    };
    for (final league in leagues.values) {
      final g = game('ACCN', league: league);
      // This pass checks name/listing evidence only, as used for early suggestions.
      final rows = (await matcher.matchDay([g], _Picks(), includeGuide: false))
          .values
          .single;
      expect(rows.map((m) => m.channel.name), ['ACC Network'],
          reason: league.id);
      expect(
          rows.single.reason,
          league.kind == SportsKind.tennis
              ? MatchReason.league
              : MatchReason.network,
          reason: league.id);
    }
    expect(guide.reads, 0);
  });
  for (final (id, sport, own, other) in [
    ('hockey.mens-college-hockey', 'Ice Hockey', 'M', 'W'),
    ('hockey.womens-college-hockey', 'Ice Hockey', 'W', 'M'),
    ('rugby.289234', 'Rugby', 'M', 'W'),
    ('rugby.289237', 'Rugby', 'W', 'M'),
  ]) {
    test('$id respects compact gender labels in channel names and the guide',
        () async {
      await matcher.prepare([
        channel('$sport ($own): Aster Athletic vs Birch United'),
        channel('$own $sport: Aster Athletic vs Birch United'),
        channel('$sport ($other): Aster Athletic vs Birch United'),
        channel('$other $sport: Aster Athletic vs Birch United'),
        channel('Sports Event Feed'),
      ]);
      guide.rows['Sports Event Feed'] = EpgProgram(
          channelId: 'Sports Event Feed',
          title: '$sport ($other): Aster Athletic vs Birch United',
          start: now,
          stop: now.add(const Duration(hours: 2)));
      final matches = await match(game('', league: sportsLeagueById(id)!));
      expect(matches.map((m) => m.channel.name).toSet(), {
        '$sport ($own): Aster Athletic vs Birch United',
        '$own $sport: Aster Athletic vs Birch United',
      });
    });
  }

  test(
      'listed aliases do not conflate parent, alternate, foreign or streaming feeds',
      () async {
    await matcher.prepare([
      for (final name in [
        'Big Ten Network',
        'Big Ten Network Alternate',
        'Big Ten Network Overflow 2',
        'BTN+',
        'SEC Network',
        'SEC Network+',
        'ACC Network',
        'ACC Network Extra',
        'ACCNX',
        'CBS',
        'CBS Sports Network',
        'CBS Sports Golazo Network',
        'ESPN',
        'ESPN+',
        'ESPN U',
        'Fox Sports 1',
        'Fox Sports 2',
        'FOX',
        'AU: Fox Sports 1',
      ])
        channel(name)
    ]);
    for (final entry in {
      'BTN': 'Big Ten Network',
      'SECN': 'SEC Network',
      'ACCN': 'ACC Network',
      'CBSSN': 'CBS Sports Network',
      'ESPNU': 'ESPN U',
      'FS1': 'Fox Sports 1'
    }.entries) {
      expect(
          (await match(game(entry.key, country: 'United States')))
              .map((m) => m.channel.name),
          [entry.value]);
    }
  });
  test('an unscoped US shorthand cannot add a different regional service',
      () async {
    await matcher.prepare([
      channel('FS1'),
      channel('US: Fox Sports 1'),
      channel('AU: Fox Sports 1'),
      Channel(
          id: 'unknown',
          rawId: 'unknown',
          playlistId: 'test',
          name: 'Fox Sports 1',
          group: 'Sports',
          url: 'https://example.invalid/unknown'),
    ]);
    expect((await match(game('FS1'))).map((m) => m.channel.name).toSet(),
        {'FS1', 'US: Fox Sports 1'});
  });

  test('Japanese listings retain exact service, region and guide checks',
      () async {
    final league = sportsLeagueById('basketball.bleague')!;
    await matcher.prepare([
      for (final name in [
        'JP: J SPORTS 3',
        'JP: J SPORTS 4',
        'JP: NHK BS',
        'JP: NHK',
        'JP: NHK World',
        'US: J SPORTS 3'
      ])
        Channel(
            id: name,
            rawId: name,
            playlistId: 'test',
            name: name,
            group: 'Sports',
            url: 'https://example.invalid/feed'),
    ]);
    expect(
        (await match(game('J SPORTS 3', league: league, country: 'Japan')))
            .map((m) => m.channel.name),
        ['JP: J SPORTS 3']);
    expect(
        (await match(game('NHK(BS)', league: league, country: 'Japan')))
            .map((m) => m.channel.name),
        ['JP: NHK BS']);
    guide.rows['JP: J SPORTS 3'] = EpgProgram(
        channelId: 'JP: J SPORTS 3',
        title: 'Soccer: Cedar vs Elm',
        start: now.subtract(const Duration(minutes: 5)),
        stop: now.add(const Duration(hours: 1)));
    expect(
        await match(
            game('J SPORTS 3', league: league, country: 'Japan', online: true)),
        isEmpty);
  });
  test('stream-only NCAA and K League brands require fixture evidence',
      () async {
    for (final brand in [
      'ACCNX',
      'ACC Network Extra',
      'SECN+',
      'SEC Network+',
      'SEC Network +',
      'ESPN3',
      'B1G+',
      'BTN+',
      'Big Ten Plus',
      'COUPANGPLAY',
      'COUPANG PLAY',
      'K LEAGUE TV',
      'KLEAGUE TV'
    ]) {
      await matcher.prepare([channel(brand), channel('$brand PPV 1')]);
      expect(await match(game(brand)), isEmpty, reason: brand);
      expect(await match(game(brand, online: true)), isEmpty, reason: brand);
    }
    final league = sportsLeagueById('kor.1')!;
    await matcher.prepare(
        [channel('COUPANG PLAY PPV 1 | Aster Athletic vs Birch United')]);
    expect((await match(game('COUPANGPLAY', league: league))).single.reason,
        MatchReason.name);
  });
  test('current contradictory guide still vetoes a listed network alias',
      () async {
    await matcher.prepare([channel('SEC Network')]);
    guide.rows['SEC Network'] = EpgProgram(
        channelId: 'SEC Network',
        title: 'College Football: Cedar vs Elm',
        start: now.subtract(const Duration(minutes: 15)),
        stop: now.add(const Duration(hours: 2)));
    expect(await match(game('SECN')), isEmpty);
  });
  test('web listings share the aliases and country checks', () async {
    await matcher
        .prepare([channel('US: ACC Network'), channel('AU: ACC Network')]);
    expect(
        (await match(game('ACCN', online: true, country: 'United States')))
            .map((m) => m.channel.name),
        ['US: ACC Network']);
  });
}
