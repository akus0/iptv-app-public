import 'package:flutter_test/flutter_test.dart';
import 'package:nox_iptv/models/channel.dart';
import 'package:nox_iptv/models/epg_program.dart';
import 'package:nox_iptv/models/sports.dart';
import 'package:nox_iptv/services/sports_channel_matcher.dart';
import 'package:nox_iptv/services/sports_match_inputs.dart';

class _Guide implements SportsMatchGuide {
  _Guide(this.clock);
  final DateTime Function() clock;
  final rows = <EpgProgram>[];
  final currentOverrides = <String, EpgProgram>{};
  @override
  int get changeRevision => 1;
  @override
  DateTime? get lastUpdated => null;
  @override
  EpgProgram? getCurrentProgram(String id) =>
      currentOverrides[id] ??
      rows
          .where((p) => p.channelId == id && p.isNowPlaying(clock()))
          .firstOrNull;
  @override
  EpgProgram? getNextProgram(String id) => rows
      .where((p) => p.channelId == id && p.start.isAfter(clock()))
      .firstOrNull;
  @override
  Future<List<EpgProgram>> findProgrammesByTitle(
          DateTime from, DateTime to, List<String> terms,
          {List<String>? channelIds}) async =>
      rows
          .where((p) =>
              p.stop.isAfter(from) &&
              p.start.isBefore(to) &&
              terms.any(p.title.toLowerCase().contains))
          .toList();
  @override
  Future<List<EpgProgram>> findSportsProgrammesForChannels(
          List<String> ids, DateTime from, DateTime to) async =>
      rows
          .where((p) =>
              ids.contains(p.channelId) &&
              p.stop.isAfter(from) &&
              p.start.isBefore(to))
          .toList();
}

class _Picks implements SportsMatchPicks {
  @override
  String? channelIdFor(SportsGame g) => null;
}

void main() {
  final start = DateTime.utc(2026, 10, 22, 22);
  late DateTime now;
  late _Guide guide;
  late SportsChannelMatcher matcher;
  setUp(() {
    now = start.add(const Duration(minutes: 10));
    guide = _Guide(() => now);
    matcher = SportsChannelMatcher(guide, clock: () => now);
  });
  tearDown(() => matcher.dispose());
  SportsTeam team(String s) =>
      SportsTeam(id: s, name: s, shortName: s, abbreviation: '');
  SportsGame game(
          {String league = 'nhl',
          String home = 'Boston Bruins',
          String away = 'Toronto Maple Leafs',
          String? event,
          String? session,
          String? court,
          String source = 'ESPN',
          List<String> matchingNames = const [],
          DateTime? at,
          DateTime? end,
          GameState state = GameState.live,
          List<String> broadcasts = const [],
          List<SportsBroadcast> online = const []}) =>
      SportsGame(
          id: '$league-$home-$away',
          league: sportsLeagueById(league)!,
          home: team(home),
          away: team(away),
          start: at ?? start,
          end: end,
          state: state,
          statusText: 'Live',
          source: source,
          broadcasts: broadcasts,
          onlineBroadcasts: online,
          event: event == null
              ? null
              : SportsEventInfo(
                  title: event,
                  session: session,
                  court: court,
                  matchingNames: matchingNames));
  Channel channel(String id, String name) => Channel(
      id: id,
      rawId: id,
      playlistId: 'test',
      name: name,
      group: 'UK Sports',
      url: 'https://example.invalid/never-opened');
  EpgProgram programme(String id, String title,
          {DateTime? from, DateTime? to, String? description}) =>
      EpgProgram(
          channelId: id,
          title: title,
          start: from ?? start,
          stop: to ?? start.add(const Duration(hours: 3)),
          description: description);
  Future<List<ChannelMatch>> match(SportsGame g, List<Channel> channels) async {
    await matcher.prepare(channels);
    return (await matcher.matchDay([g], _Picks(),
        includePossible: true))[SportsChannelPicks.eventKey(g)]!;
  }

  for (final series in ['motogp', 'moto2', 'moto3']) {
    test('$series Qatar venue aliases retain exact session and series checks',
        () async {
      final label =
          {'motogp': 'MotoGP', 'moto2': 'Moto2', 'moto3': 'Moto3'}[series]!;
      final other = series == 'motogp' ? 'Moto2' : 'MotoGP';
      final g = game(
          league: 'racing.$series',
          event: '$label · Qatar Grand Prix',
          session: 'Practice 3',
          source: 'RaceTV Guide',
          matchingNames: ['Qatar Grand Prix', 'Lusail International Circuit'],
          end: start.add(const Duration(minutes: 90)));
      final titles = {
        'qatar': '$label: Qatar Practice 3 Live',
        'lusail': '$label: Lusail Practice 3 Live',
        'losail': '$label: Losail Practice 3 Live',
        'full': '$label: Qatar Grand Prix Practice 3 Live',
        'otherSeries': '$other: Qatar Practice 3 Live',
        'otherVenue': '$label: Malaysian Grand Prix Practice 3 Live',
        'otherPractice': '$label: Qatar Practice 2 Live',
        'qualifying': '$label: Qatar Qualifying Live',
        'sprint': '$label: Qatar Sprint Live',
        'race': '$label: Qatar Race Live',
        'replay': '$label: Qatar Practice 3 Replay',
        'sportOnly': 'Qatar Practice 3 Live',
      };
      guide.rows.addAll([
        for (final entry in titles.entries) programme(entry.key, entry.value),
        programme('expired', '$label: Qatar Practice 3 Live',
            to: now.subtract(const Duration(minutes: 1))),
        programme('future', '$label: Qatar Practice 3 Live',
            from: start.add(const Duration(hours: 4)),
            to: start.add(const Duration(hours: 5))),
      ]);
      final channels = [
        for (final id in [...titles.keys, 'expired', 'future'])
          channel(id, 'Sports channel $id')
      ];
      final matches = await match(g, channels);
      expect(matches.where((m) => m.isConfident).map((m) => m.channel.id),
          unorderedEquals(['qatar', 'lusail', 'losail', 'full']));
      // A different round must not inherit these aliases just because it is
      // in the same series, nor may a generic country/channel label suffice.
      final otherRound = game(
          league: 'racing.$series',
          event: '$label · Malaysian Grand Prix',
          session: 'Practice 3',
          source: 'RaceTV Guide',
          matchingNames: [
            'Malaysian Grand Prix',
            'Sepang International Circuit'
          ],
          end: g.end);
      final otherMatches = await match(otherRound, channels);
      expect(otherMatches.where((m) => m.isConfident).map((m) => m.channel.id),
          ['otherVenue']);
    });
  }

  test('coordinated fixture synopses require both teams and a current game',
      () async {
    final g = game(
        league: 'basketball.mens-college-basketball',
        home: 'Michigan Wolverines',
        away: 'UConn Huskies');
    const sentence =
        'The UConn Huskies and the Michigan Wolverines meet at TD Garden for a regular-season NCAA game.';
    final descriptions = {
      'right': sentence,
      'reverse':
          'The Michigan Wolverines and UConn Huskies meet at TD Garden for a regular-season NCAA game.',
      'wrongOpponent':
          sentence.replaceAll('Michigan Wolverines', 'Iowa Hawkeyes'),
      'wrongCampus':
          sentence.replaceAll('Michigan Wolverines', 'Michigan State Spartans'),
      'incidental':
          'The UConn Huskies and the Michigan Wolverines visit TD Garden for a regular-season NCAA game.',
      'ceremony':
          'The UConn Huskies and the Michigan Wolverines meet at TD Garden for an awards ceremony.',
      'future': 'Tomorrow, $sentence',
      'past': 'Yesterday, $sentence',
      'replay': 'Replay. $sentence',
      'futureTail': sentence.replaceAll('for a', 'next week for a'),
      'unrelatedMeeting':
          'The UConn Huskies and the Michigan Wolverines watch as the Iowa Hawkeyes and the Kansas Jayhawks meet at TD Garden for a regular-season NCAA game.',
    };
    guide.rows.addAll([
      for (final e in descriptions.entries)
        programme(e.key, 'College Basketball', description: e.value),
      programme('wrongSport', 'College Hockey', description: sentence),
      programme('wrongGender', "Women's College Basketball",
          description: sentence),
      programme('wrongTitle', 'College Basketball: Iowa at Kansas',
          description: sentence),
      programme('expired', 'College Basketball',
          description: sentence, to: now.subtract(const Duration(minutes: 1))),
      programme('futureSlot', 'College Basketball',
          description: sentence, from: now.add(const Duration(minutes: 20))),
    ]);
    final found = await match(g, [
      for (final p in guide.rows) channel(p.channelId, 'Sports feed'),
      channel('narrativeChannel', 'College Basketball: $sentence'),
    ]);
    expect(found.where((m) => m.isConfident).map((m) => m.channel.id).toSet(),
        {'right', 'reverse'});
    expect(
        found
            .where((m) => m.isConfident)
            .every((m) => m.reason == MatchReason.guide),
        true);
  });

  test('ladies is a division, not a golf tournament identity', () async {
    final g = game(league: 'golf.lpga', event: 'BMW Ladies Championship');
    guide.rows.addAll([
      programme('comedy', 'Key & Peele: Ladies'),
      programme('right', 'Golf: BMW Ladies Championship - Round 1'),
    ]);
    final found = await match(g, [
      channel('comedy', 'Comedy Central'),
      channel('right', 'Golf Channel'),
      channel('generic', 'Ladies Championship'),
    ]);
    expect(found.map((m) => m.channel.id), ['right']);
    expect(found.single.reason, MatchReason.guide);
  });

  test('short golf aliases need golf context, full tournament titles survive',
      () async {
    final g =
        game(league: 'golf.pga', event: 'Butterfield Bermuda Championship');
    guide.rows.addAll([
      programme('travel', 'Bermuda'),
      programme('right', 'Golf: Bermuda'),
      programme('full', 'Butterfield Bermuda Championship'),
    ]);
    final found = await match(g, [
      channel('travel', 'Travel TV'),
      channel('right', 'Golf Channel'),
      channel('full', 'Event feed'),
    ]);
    expect(found.any((m) => m.channel.id == 'travel'), false);
    expect(found.any((m) => m.channel.id == 'right'), true);
    expect(found.first.channel.id, 'full');
    expect(found.first.reason, MatchReason.guide);
  });

  test('exact current fight guide overrides an obsolete dated event slot',
      () async {
    final g = game(
        league: 'mma.ufc',
        home: 'Brendan Allen',
        away: 'Chris Duncan',
        event: 'UFC Fight Night');
    guide.rows.add(programme('right', 'UFC: Allen vs Duncan Oct 22'));
    expect(
        (await match(g, [channel('right', 'Other vs Fighters Oct 10')]))
            .single
            .reason,
        MatchReason.guide);
  });
  test(
      'exact current race guide overrides obsolete labels but retains session checks',
      () async {
    final g = game(
        league: 'racing.f1',
        event: 'United States Grand Prix',
        session: 'Race');
    guide.rows.addAll([
      programme('right', 'Formula 1 United States Grand Prix - Race Oct 22'),
      programme(
          'wrong', 'Formula 1 United States Grand Prix - Qualifying Oct 22')
    ]);
    final found = await match(g, [
      channel('right', 'F1 Singapore Grand Prix Oct 10'),
      channel('wrong', 'F1 Singapore Grand Prix Oct 10')
    ]);
    expect(found.map((m) => m.channel.id), ['right']);
  });
  test('race session conflict applies to names and ordinary guide channels too',
      () async {
    final g = game(
        league: 'racing.f1',
        event: 'United States Grand Prix',
        session: 'Race');
    guide.rows
        .add(programme('guideWrong', 'United States Grand Prix - Practice 1'));
    final found = await match(g, [
      channel('guideWrong', 'Sky Sports F1'),
      channel('wrong', 'United States Grand Prix - Sprint Qualifying'),
      channel('right', 'United States Grand Prix - Race')
    ]);
    expect(found.map((m) => m.channel.id), ['right']);
  });
  test(
      'late golf rounds use current tournament day and reject a different round',
      () async {
    now = DateTime.utc(2026, 10, 25, 22, 10);
    final g = game(
        league: 'golf.pga',
        event: 'Zozo Championship',
        session: 'Round 4',
        at: start,
        end: DateTime.utc(2026, 10, 26));
    guide.rows.addAll([
      programme('right', 'PGA Zozo Championship - Round 4 Oct 25',
          from: now.subtract(const Duration(minutes: 10)),
          to: now.add(const Duration(hours: 2))),
      programme('wrong', 'PGA Zozo Championship - Round 1 Oct 25',
          from: now.subtract(const Duration(minutes: 10)),
          to: now.add(const Duration(hours: 2)))
    ]);
    final found = await match(g, [
      channel('right', 'PGA Zozo Championship Oct 25'),
      channel('wrong', 'Golf Channel')
    ]);
    expect(found.map((m) => m.channel.id), ['right']);
    expect(found.single.reason, MatchReason.guide);
  });
  test('named golf Classics keep live rounds and exclude recorded editions',
      () async {
    final g = game(
        league: 'golf.lpga', event: 'TOTO Japan Classic', session: 'Round 3');
    final titles = {
      'current': 'LPGA Tour Golf - TOTO Japan Classic, Third Round LIVE',
      'numeric': 'LPGA TOTO Japan Classic: Round 3',
      'day': 'LPGA TOTO Japan Classic: Day 3',
      'wrong-round': 'LPGA TOTO Japan Classic: Second Round LIVE',
      'wrong-day': 'LPGA TOTO Japan Classic: Day 2 LIVE',
      'highlight': 'TOTO Japan Classic Round 3 Highlights LIVE',
      'repeat': 'TOTO Japan Classic Round 3 Replay LIVE',
      'archive': '2025 TOTO Japan Classic Round 3 LIVE',
      'classic-label': 'Classic Golf: TOTO Japan Classic Round 3 LIVE',
      'other': 'LPGA Meijer Classic Round 3 LIVE',
    };
    guide.rows
        .addAll([for (final e in titles.entries) programme(e.key, e.value)]);
    guide.rows.add(programme('synopsis', 'TOTO Japan Classic Round 3 LIVE',
        description: 'Highlights from the third round.'));
    final found = await match(g, [
      for (final id in [...titles.keys, 'synopsis']) channel(id, 'Golf feed')
    ]);
    expect(found.where((m) => m.isConfident).map((m) => m.channel.id).toSet(),
        {'current', 'numeric', 'day'});
    // An exemption for one tournament must not leak into another event's cache.
    final other = game(
        league: 'golf.pga', event: 'Japan Championship', session: 'Round 3');
    final unrelated = await matcher.matchDay([other], _Picks());
    expect(
        unrelated.values.expand((m) => m).where((m) => m.isConfident), isEmpty);
  });
  test('upcoming Classic coverage stays a tournament suggestion until it airs',
      () async {
    final g = game(
        league: 'golf.lpga',
        event: 'TOTO Japan Classic',
        session: 'Round 3',
        end: now.add(const Duration(days: 2)));
    guide.rows.add(programme(
        'next', 'LPGA TOTO Japan Classic, Third Round LIVE',
        from: now.add(const Duration(hours: 1)),
        to: now.add(const Duration(hours: 4))));
    final found = await match(g, [channel('next', 'Golf feed')]);
    expect(found.single.reason, MatchReason.tournament);
    expect(found.single.programme?.title, contains('Third Round'));
  });
  test(
      'golf title suffix does not turn every World Championship into the same event',
      () async {
    final g = game(league: 'golf.pga', event: 'Cadillac World Championship');
    expect(
        (await match(g, [channel('wrong', 'DP World Championship Golf')]))
            .where((m) => m.isConfident),
        isEmpty);
  });
  test('future guide slot is not confirmed as a live team game', () async {
    guide.rows.add(programme('future', 'Boston Bruins vs Toronto Maple Leafs',
        from: now.add(const Duration(minutes: 10))));
    final found = await match(game(), [channel('future', 'Event 1')]);
    expect(found, isNotEmpty);
    expect(found.every((m) => !m.isConfident), true);
  });
  test('a scheduled pre-game fixture can still have a confident guide match',
      () async {
    final g =
        game(state: GameState.pre, at: now.add(const Duration(minutes: 10)));
    guide.rows.add(programme('right', 'Boston Bruins vs Toronto Maple Leafs',
        from: g.start));
    expect((await match(g, [channel('right', 'Event 1')])).single.isConfident,
        true);
  });
  test('male soccer fixture rejects explicitly female coverage', () async {
    final g = game(league: 'eng.1', home: 'Arsenal', away: 'Chelsea');
    final found = await match(g, [
      channel('wrong', "Women's Soccer: Arsenal vs Chelsea"),
      channel('right', 'Arsenal vs Chelsea')
    ]);
    expect(found.map((m) => m.channel.id), ['right']);
  });
  test(
      'same-surname player with a different initial is not an exact name match',
      () async {
    final g = game(
        league: 'tennis.atp',
        home: 'Mischa Zverev',
        away: 'Andrey Rublev',
        event: 'European Open');
    final found = await match(g, [
      channel('wrong', 'A. Zverev vs A. Rublev'),
      channel('right', 'M. Zverev vs A. Rublev')
    ]);
    expect(found.map((m) => m.channel.id), ['right']);
  });
  test(
      'strong event listing wins over a prior tournament-only listing, in either order',
      () async {
    const broad = SportsBroadcast('Sky Sports Tennis',
        source: 'Rights list', country: 'United Kingdom', tournamentOnly: true);
    const exact = SportsBroadcast('Sky Sports Tennis',
        source: 'Event schedule', country: 'United Kingdom');
    for (final rows in [
      [broad, exact],
      [exact, broad]
    ]) {
      final g = game(
          league: 'tennis.atp',
          home: 'Casper Ruud',
          away: 'Novak Djokovic',
          event: 'European Open',
          online: rows);
      final found = await match(g, [channel('sky', 'UK: Sky Sports Tennis')]);
      expect(found.single.reason, MatchReason.listing);
      expect(found.single.supportingBroadcasts, hasLength(2));
    }
  });
  test('corroborating lists do not stack unlimited score bonuses', () async {
    final g = game(online: [
      for (var i = 0; i < 8; i++)
        SportsBroadcast('Sky Sports Tennis',
            source: 'Source $i', country: 'United Kingdom')
    ]);
    guide.rows.add(programme('sky', 'Boston Bruins vs Toronto Maple Leafs'));
    final found = await match(g, [channel('sky', 'UK: Sky Sports Tennis')]);
    expect(found.single.reason, MatchReason.guide);
    expect(found.single.score, lessThanOrEqualTo(535));
  });
  test('one generic broadcaster cannot confirm two simultaneous team fixtures',
      () async {
    final games = [
      game(broadcasts: ['ESPN']),
      game(
          home: 'New York Rangers',
          away: 'Detroit Red Wings',
          broadcasts: ['ESPN'])
    ];
    await matcher.prepare([channel('espn', 'ESPN')]);
    final result =
        await matcher.matchDay(games, _Picks(), includePossible: true);
    expect(result.values.expand((m) => m).where((m) => m.isConfident), isEmpty);
  });
  test(
      'exact guide winner remains confident when another fixture only names its network',
      () async {
    final games = [
      game(broadcasts: ['ESPN']),
      game(
          home: 'New York Rangers',
          away: 'Detroit Red Wings',
          broadcasts: ['ESPN'])
    ];
    guide.rows.add(programme('espn', 'Boston Bruins vs Toronto Maple Leafs'));
    await matcher.prepare([channel('espn', 'ESPN')]);
    final result =
        await matcher.matchDay(games, _Picks(), includePossible: true);
    expect(result[SportsChannelPicks.eventKey(games.first)]!.single.isConfident,
        true);
    expect(
        result[SportsChannelPicks.eventKey(games.last)]!
            .where((m) => m.isConfident),
        isEmpty);
  });
  test(
      'current-guide rejection expires at its actual boundary inside a cache bucket',
      () async {
    now = DateTime.utc(2026, 10, 22, 22, 1);
    guide.rows.add(
        programme('espn', 'Tennis', to: DateTime.utc(2026, 10, 22, 22, 2)));
    final g = game(broadcasts: ['ESPN']);
    final channels = [channel('espn', 'ESPN')];
    await matcher.prepare(channels);
    expect(
        (await matcher.matchDay([g], _Picks()))[SportsChannelPicks.eventKey(g)],
        isEmpty);
    now = DateTime.utc(2026, 10, 22, 22, 3);
    final next = (await matcher
        .matchDay([g], _Picks()))[SportsChannelPicks.eventKey(g)]!;
    expect(next.single.reason, MatchReason.network);
  });
  test('an @ fixture title remains authoritative over an incidental synopsis',
      () async {
    guide.rows.add(programme(
        'right', 'Hockey: Boston Bruins @ Toronto Maple Leafs',
        description:
            'New York Rangers vs Detroit Red Wings follows tomorrow.'));
    final found = await match(game(), [channel('right', 'Event feed')]);
    expect(found.single.reason, MatchReason.guide);
  });
  test(
      'player @ player channel names work without treating @ dates as opponents',
      () async {
    final g = game(
        league: 'tennis.atp',
        home: 'Casper Ruud',
        away: 'Novak Djokovic',
        event: 'European Open');
    final found = await match(g, [
      channel('right', 'Ruud @ Djokovic'),
      channel('coverage', 'ATP European Open @ Oct 22')
    ]);
    expect(found.first.channel.id, 'right');
    expect(found.first.isConfident, true);
    expect(found.last.channel.id, 'coverage');
    expect(found.last.isConfident, false);
    final weekday = await match(g, [
      channel('dated', 'Ruud vs Djokovic @ Thu 22 Oct'),
      channel('coverage', 'ATP European Open @ Thursday Oct 22')
    ]);
    expect(weekday.first.channel.id, 'dated');
    expect(weekday.first.isConfident, true);
    expect(weekday.last.channel.id, 'coverage');
    expect(weekday.last.isConfident, false);
  });
  test('a live event cannot be confirmed by its press conference or preview',
      () async {
    guide.rows.addAll([
      programme('preview', 'Boston Bruins vs Toronto Maple Leafs - Preview'),
      programme(
          'press', 'Boston Bruins vs Toronto Maple Leafs - Press Conference')
    ]);
    expect(
        await match(game(),
            [channel('preview', 'Event 1'), channel('press', 'Event 2')]),
        isEmpty);
  });
  test(
      'authoritative cached current slot wins over an overlapping stale query row',
      () async {
    final current = programme('espn', 'Boston Bruins vs Toronto Maple Leafs');
    guide.rows.addAll([
      programme('espn', 'Hockey: New York Rangers vs Detroit Red Wings',
          from: start.subtract(const Duration(minutes: 5))),
      current
    ]);
    guide.currentOverrides['espn'] = current;
    final found = await match(game(), [channel('espn', 'ESPN')]);
    expect(found.single.reason, MatchReason.guide);
  });
  test('month-like player names are still opponents after @', () async {
    final g = game(
        league: 'tennis.atp',
        home: 'Harold Mayot',
        away: 'Casper Ruud',
        event: 'European Open');
    expect((await match(g, [channel('right', 'Ruud @ Mayot')])).single.reason,
        MatchReason.name);
  });
  test('generic Grand Prix Live does not assert a race-session conflict',
      () async {
    final g = game(
        league: 'racing.f1',
        event: 'United States Grand Prix',
        session: 'Qualifying');
    guide.rows.add(programme('right', 'United States Grand Prix Live'));
    expect((await match(g, [channel('right', 'Sky Sports F1')])).single.reason,
        MatchReason.guide);
  });
}
