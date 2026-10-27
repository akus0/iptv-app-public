import 'package:flutter_test/flutter_test.dart';
import 'package:nox_iptv/models/epg_program.dart';
import 'package:nox_iptv/models/sports.dart';
import 'package:nox_iptv/utils/sports_guide_coverage.dart';

final now = DateTime.utc(2026, 10, 26, 12);
const team = SportsTeam(id: '', name: '', shortName: '', abbreviation: '');
SportsGame guide(String id, String sport, String title,
        {String description = '',
        int start = -20,
        int stop = 100,
        String status = 'Live · guide'}) =>
    SportsGame(
        id: id,
        league: SportsLeague(
            id: 'guide.$sport',
            espnPath: '$sport/guide',
            name: sport,
            shortName: sport,
            logoUrl: '',
            kind: SportsKind.broadcast,
            source: 'Channel guide'),
        start: now.add(Duration(minutes: start)),
        end: now.add(Duration(minutes: stop)),
        state: GameState.live,
        statusText: status,
        home: team,
        away: team,
        source: 'Channel guide',
        event: SportsEventInfo(title: title),
        guideProgrammes: [
          EpgProgram(
              channelId: id,
              title: title,
              description: description,
              start: now.add(Duration(minutes: start)),
              stop: now.add(Duration(minutes: stop)),
              isLive: status == 'Live · guide')
        ]);
SportsGame card(
        {String id = 'score',
        String title = 'UFC 333',
        String? session,
        int start = 0,
        GameState state = GameState.live}) =>
    SportsGame(
        id: id,
        league: sportsLeagueById('mma.ufc')!,
        start: now.add(Duration(minutes: start)),
        state: state,
        statusText: 'Round 2',
        home: team,
        away: team,
        event: SportsEventInfo(title: title, session: session));

void main() {
  test('cosmetic copies across every guide sport retain exact slots', () {
    for (final sport in [
      'poker',
      'darts',
      'mma',
      'boxing',
      'billiards',
      'bowling',
      'badminton',
      'table-tennis',
      'baseball',
      'netball',
      'handball',
      'squash',
      'cycling',
      'field-hockey',
      'esports',
      'action-sports'
    ]) {
      final a = guide('a', sport, 'Live: Specific Competition HD',
          description: 'Session one.');
      final b = guide('b', sport, 'Specific Competition',
          description: 'Session one!', start: -15, stop: 105);
      final grouped = coalesceOtherGuideCoverage([a, b]);
      expect(grouped, hasLength(1), reason: sport);
      expect(grouped.single.guideProgrammes,
          [a.guideProgrammes.single, b.guideProgrammes.single]);
      expect(grouped.single.start, a.start);
      expect(grouped.single.end, b.end);
      expect(coalesceOtherGuideCoverage([b, a]).single.id, grouped.single.id);
      expect(coalesceOtherGuideCoverage([b]).single.id, grouped.single.id);
    }
  });
  test('poker season and episode identity can span title/synopsis formats', () {
    final grouped = coalesceOtherGuideCoverage([
      guide('a', 'poker', 'Live Poker After Dark S05E49',
          description: 'Top Guns cash game.', status: 'On air · replay'),
      guide('b', 'poker', 'Poker After Dark',
          description: 'Season 5 Episode 49. Cash game featuring six pros.',
          status: 'On air · replay'),
      guide('c', 'poker', 'Poker After Dark S05E50', status: 'On air · replay'),
      guide('d', 'poker', 'Poker After Dark S06E49', status: 'On air · replay'),
    ]);
    expect(grouped, hasLength(3));
    expect(
        grouped
            .singleWhere((g) => g.guideProgrammes.length == 2)
            .guideProgrammes
            .map((p) => p.channelId),
        ['a', 'b']);
  });
  test(
      'poker never groups generic tables, different stakes, flights or recorded years',
      () {
    final cases = [
      ('World Poker Tour', 'Table one', 'Table two'),
      ('Poker After Dark S5E49', 'Cash game \$100/\$200', 'Cash game \$5/\$10'),
      ('Live WSOP Vegas Main Event Day 2 Table 1', 'Flight A', 'Flight B'),
      ('Live WPT Choctaw Final Table', 'Table Alpha', 'Table Bravo'),
      ('Live WPT Choctaw Final Table', 'Table II', 'Table III'),
      ('Live WPT Choctaw Final Table', '2025 tournament', '2026 tournament'),
      (
        'World Poker Tour',
        'Bay 101 Shooting Star Part 1',
        'Bay 101 Shooting Star Part 2'
      ),
      (
        'Poker After Dark',
        'Top Guns featuring Phil Ivey.',
        'Cash game with Daniel Negreanu.'
      ),
    ];
    for (final c in cases) {
      expect(
          coalesceOtherGuideCoverage([
            guide('a', 'poker', c.$1, description: c.$2),
            guide('b', 'poker', c.$1, description: c.$3)
          ]),
          hasLength(2),
          reason: c.toString());
    }
  });
  test(
      'specific live poker final table joins aliases but missing details stay distinct',
      () {
    final grouped = coalesceOtherGuideCoverage([
      guide('a', 'poker', 'Live WPT Choctaw Final Table',
          description: 'Top players compete.'),
      guide('b', 'poker', 'World Poker Tour Choctaw Final Table HD',
          description: 'The tournament concludes.'),
      guide('c', 'poker', 'World Poker Tour', description: 'Final table.'),
      guide('d', 'poker', 'World Poker Tour Choctaw Final Table',
          status: 'On air · replay'),
    ]);
    expect(grouped, hasLength(3));
  });
  test(
      'named tournament stages combine without mixing rounds, sessions or opponents',
      () {
    for (final sport in [
      'darts',
      'billiards',
      'badminton',
      'table-tennis',
      'esports',
      'action-sports'
    ]) {
      final grouped = coalesceOtherGuideCoverage([
        guide('a', sport, 'Northern Ireland Open Semi-Final',
            description: 'Live action from the venue.'),
        guide('b', sport, 'Live Northern Ireland Open Semifinal HD',
            description: 'Championship coverage.'),
        guide('c', sport, 'Northern Ireland Open Quarterfinal'),
        guide('d', sport, 'Northern Ireland Open Semifinal',
            description: 'Session 2'),
        guide('e', sport, 'Northern Ireland Open Semifinal',
            description: 'Alice vs Betty'),
        guide('f', sport, 'Northern Ireland Open Semifinal',
            description: 'Clara vs Diane'),
      ]);
      expect(grouped, hasLength(5), reason: sport);
    }
  });
  test(
      'team/bout titles tolerate prose but preserve game, court and division qualifiers',
      () {
    for (final sport in [
      'boxing',
      'baseball',
      'netball',
      'handball',
      'squash',
      'field-hockey'
    ]) {
      final grouped = coalesceOtherGuideCoverage([
        guide('a', sport, 'Alpha versus Bravo',
            description: 'Championship action.'),
        guide('b', sport, 'Live Alpha v Bravo HD',
            description: 'Coverage from the stadium.'),
        guide('c', sport, 'Alpha vs Charlie'),
        guide('d', sport, 'Alpha vs Bravo', description: 'Game 2'),
        guide('e', sport, 'Alpha vs Bravo', description: 'Women'),
        guide('f', sport, 'Alpha vs Bravo', description: 'Court 2'),
      ]);
      expect(grouped, hasLength(5), reason: sport);
    }
  });
  test(
      'time-shifted channels, adjacent episodes and live/recorded states remain distinct',
      () {
    final a = guide('a', 'darts', 'European Championship Final',
        description: 'Final action.');
    expect(
        coalesceOtherGuideCoverage([
          a,
          guide('b', 'darts', a.title,
              description: 'Final action.', start: 40, stop: 160),
          guide('c', 'darts', a.title,
              description: 'Final action.', start: 100, stop: 220),
          guide('d', 'darts', a.title,
              description: 'Final action.', status: 'On air'),
        ]),
        hasLength(4));
    expect(
        coalesceOtherGuideCoverage([
          guide('a', 'poker', 'Poker'),
          guide('b', 'poker', 'Poker', start: -15)
        ]),
        hasLength(2));
  });
  test('non-Latin fixture names stay distinct', () {
    for (final labels in [
      ('U-21', 'U-23'),
      ('Boys', 'Girls'),
      ('Junior', 'Senior')
    ]) {
      expect(
          coalesceOtherGuideCoverage([
            guide('a', 'netball', 'Alpha vs Bravo', description: labels.$1),
            guide('b', 'netball', 'Alpha vs Bravo', description: labels.$2),
          ]),
          hasLength(2));
    }
    expect(
        coalesceOtherGuideCoverage([
          guide('a', 'baseball', '東京 vs 大阪'),
          guide('b', 'baseball', '京都 vs 千葉'),
        ]),
        hasLength(2));
    expect(
        coalesceOtherGuideCoverage([
          guide('a', 'boxing', 'TBD vs TBD', description: 'Tournament Alpha'),
          guide('b', 'boxing', 'TBD vs TBD', description: 'Tournament Bravo'),
        ]),
        hasLength(2));
  });
  test('numbered combat simulcasts combine, phases and different bouts do not',
      () {
    final grouped = coalesceOtherGuideCoverage([
      guide('a', 'mma', 'Live UFC 333 Prelims', description: 'Live coverage.'),
      guide('b', 'mma', 'UFC 333 Preliminary Fights HD',
          description: 'The preliminary bouts.'),
      guide('c', 'mma', 'UFC 333 Main Card'),
      guide('d', 'mma', 'UFC 333 Early Prelims'),
      guide('e', 'mma', 'UFC 334 Prelims'),
      guide('f', 'mma', 'UFC 333 Alpha vs Bravo'),
      guide('g', 'mma', 'UFC 333 Charlie vs Delta'),
    ]);
    expect(grouped, hasLength(6));
  });
  test(
      'scored combat card retains channels, score identity and idempotent enrichment',
      () {
    final main = card();
    final broadcast = coalesceOtherGuideCoverage([
      guide('a', 'mma', 'UFC 333 Prelims'),
      guide('b', 'mma', 'Live UFC 333 Prelims HD')
    ]).single;
    final merged = mergeSportsGuideCoverage([main], [broadcast]);
    expect(merged, hasLength(1));
    expect(merged.single.id, main.id);
    expect(merged.single.statusText, main.statusText);
    expect(merged.single.guideProgrammes, hasLength(2));
    expect(
        identical(mergeSportsGuideCoverage(merged, [broadcast]).single,
            merged.single),
        isTrue);
    expect(
        mergeSportsGuideCoverage(merged, []).single.guideProgrammes, isEmpty);
  });
  test(
      'combat merge checks time, phase, ambiguity and bout instead of hiding by number',
      () {
    final prelim = guide('a', 'mma', 'UFC 333 Prelims');
    for (final primary in [
      [card(session: 'Main card')],
      [card(start: 360)],
      [card(state: GameState.post)],
      [card(id: 'a'), card(id: 'b')],
    ]) {
      expect(mergeSportsGuideCoverage(primary, [prelim]),
          hasLength(primary.length + 1));
    }
    expect(
        mergeSportsGuideCoverage([card(title: 'UFC 333 Alpha vs Bravo')],
            [guide('b', 'mma', 'UFC 333 Charlie vs Delta')]),
        hasLength(2));
    expect(
        mergeSportsGuideCoverage(
            [card()], [guide('b', 'mma', 'UFC 333 Charlie vs Delta')]),
        hasLength(2));
  });
  test('many broadcasts use bucketed grouping; warm models stay cached', () {
    final games = [
      for (var event = 0; event < 100; event++)
        for (var feed = 0; feed < 12; feed++)
          guide('$event-$feed', 'darts', 'Regional Tournament $event Final',
              description: 'Broadcaster $feed coverage.')
    ];
    final watch = Stopwatch()..start();
    final grouped = coalesceOtherGuideCoverage(games);
    expect(grouped, hasLength(100));
    expect(grouped.every((g) => g.guideProgrammes.length == 12), isTrue);
    final cold = watch.elapsedMilliseconds;
    watch.reset();
    coalesceOtherGuideCoverage(games);
    // ignore: avoid_print
    print(
        '1200 guide broadcasts -> 100 cards: cold ${cold}ms; warm ${watch.elapsedMilliseconds}ms');
  });
}
