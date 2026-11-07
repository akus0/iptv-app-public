import 'package:flutter_test/flutter_test.dart';
import 'package:nox_iptv/models/epg_program.dart';
import 'package:nox_iptv/models/sports.dart';
import 'package:nox_iptv/utils/sports_guide_coverage.dart';

final now = DateTime.utc(2026, 10, 26, 12);
const team = SportsTeam(id: '', name: '', shortName: '', abbreviation: '');
SportsGame guide(String id, String sport, String title,
        {SportsLeague? league,
        String description = '',
        int start = -20,
        int stop = 100,
        String status = 'Live · guide'}) =>
    SportsGame(
        id: id,
        league: league ??
            SportsLeague(
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
  test(
      'live local guide copies keep alternatives and distinguish dated editions',
      () {
    for (final spec in [
      (
        'high-school-football',
        'football',
        'High School Football - Apple Valley at Villa Park',
        'Football'
      ),
      (
        'horse-racing',
        'horse-racing',
        'Horse Racing - Melbourne Cup Carnival - Champions Day',
        'Horse racing'
      ),
      (
        'rodeo',
        'rodeo',
        'Columbia River Circuit Finals - Performance 2',
        'Rodeo'
      ),
    ]) {
      final league = sportsLeagueById('guide.${spec.$1}')!;
      SportsGame row(String id, String description,
              {String status = 'Live · guide',
              int start = -20,
              int stop = 100,
              String? title}) =>
          guide(id, spec.$2, title ?? spec.$3,
              league: league,
              description: description,
              status: status,
              start: start,
              stop: stop);
      final plain = row('plain', 'Full coverage.');
      final local =
          row('local', 'Full coverage. (${spec.$4}, Sports) - 2026-10-25');
      final merged = coalesceOtherGuideCoverage([plain, local]);
      expect(merged, hasLength(1));
      expect(merged.single.guideProgrammes.map((p) => p.channelId).toSet(),
          {'plain', 'local'});
      for (final separate in [
        row('old', 'Full coverage. (${spec.$4}) - 2026-10-24'),
        row('future', 'Full coverage. (${spec.$4}) - 2026-10-28'),
        row('body', 'Full coverage from 2026-10-25.'),
        row('other', 'Full coverage.', title: '${spec.$3} - Other fixture'),
        row('later', 'Full coverage.', start: 200, stop: 320),
      ]) {
        expect(coalesceOtherGuideCoverage([plain, separate]), hasLength(2));
      }
      expect(
          coalesceOtherGuideCoverage([
            row('unmarked', 'Full coverage.', status: 'On air'),
            row('dated', 'Full coverage. (${spec.$4}) - 2026-10-25',
                status: 'On air'),
          ]),
          hasLength(2));
    }
  });

  test(
      'Australian Championship episode layouts merge only the same fixture and episode',
      () {
    final league = sportsLeagueById('guide.australian-championship')!;
    final generic = guide('generic', 'soccer', 'Australian Championship',
        league: league,
        description:
            'E27 — Marconi Stallions FC v Bayswater City SC: Round 4\nCoverage from Marconi Stadium.');
    SportsGame detailed(int episode, String pair) => guide(
        'detailed-$episode-$pair',
        'soccer',
        'Australian Championship : $pair: Round 4',
        league: league,
        description: 'E$episode Coverage from Marconi Stadium.');
    final specific = detailed(27, 'Marconi Stallions FC v Bayswater City SC');
    final merged = coalesceOtherGuideCoverage([generic, specific]);
    expect(merged, hasLength(1));
    expect(merged.single.title, contains('Marconi'));
    expect(merged.single.guideProgrammes, hasLength(2));
    expect(
        coalesceOtherGuideCoverage([
          generic,
          detailed(28, 'Marconi Stallions FC v Bayswater City SC')
        ]),
        hasLength(2));
    expect(
        coalesceOtherGuideCoverage(
            [generic, detailed(27, 'Marconi Stallions FC v Sydney Olympic')]),
        hasLength(2));
  });

  test(
      'Test cricket title/synopsis layouts share exact opponents, Test and day',
      () {
    final input = [
      guide('a', 'cricket', 'Test Cricket',
          description: 'Afghanistan vs. Zimbabwe\n1st Test, Day 2.'),
      guide('b', 'cricket', 'Test Cricket - Afghanistan vs. Zimbabwe',
          description: '1st Test, Day 2. (Cricket) - 2026-10-26'),
      guide('c', 'cricket', 'Test Cricket: Zimbabwe v Afghanistan',
          description: 'First Test, Day Two.'),
    ];
    final combined = coalesceOtherGuideCoverage(input);
    expect(combined, hasLength(1));
    expect(combined.single.guideProgrammes.map((p) => p.channelId),
        ['a', 'b', 'c']);
    expect(combined.single.title, isNot('Test Cricket'));
    for (final game in input) {
      expect(coalesceOtherGuideCoverage([game]).single.id, combined.single.id);
    }
    for (final detail in [
      '2nd Test, Day 2.',
      '1st Test, Day 3.',
      '1st Test.',
      '1th Test, Day 2.',
      '1st Test, Day 2. Morning session.',
      '1st Test, Day 2. First innings.',
      '1st Test, Day 2. Women.',
      '1st Test, Day 2. (Cricket) - 2025-10-26'
    ]) {
      expect(
          coalesceOtherGuideCoverage([
            input[1],
            guide('d', 'cricket', 'Test Cricket: Afghanistan vs. Zimbabwe',
                description: detail)
          ]),
          hasLength(2),
          reason: detail);
    }
    for (final opponents in [
      'Afghanistan vs. Ireland',
      'Australia vs. Zimbabwe'
    ]) {
      expect(
          coalesceOtherGuideCoverage([
            input[1],
            guide('d', 'cricket', 'Test Cricket: $opponents',
                description: '1st Test, Day 2.')
          ]),
          hasLength(2));
    }
    expect(
        coalesceOtherGuideCoverage([
          input[1],
          guide('d', 'cricket', 'Test Cricket: Afghanistan vs. Zimbabwe',
              description: '1st Test, Day 2.', start: 40, stop: 160)
        ]),
        hasLength(2));
  });

  test('category footers do not split identical coverage across guide sports',
      () {
    for (final sport in [
      'poker',
      'tennis',
      'golf',
      'billiards',
      'cricket',
      'mma',
      'badminton'
    ]) {
      final input = [
        guide('a', sport, 'Regional Competition',
            description: 'Coverage from the venue.'),
        guide('b', sport, 'Regional Competition',
            description: 'Coverage from the venue. (Sports)'),
        guide('c', sport, 'Regional Competition',
            description:
                'Coverage from the venue. (Sports, Sports event) - 2026-10-26'),
        guide('d', sport, 'Regional Competition',
            description: 'Coverage from the venue. (Sports) - 20261026'),
      ];
      final combined = coalesceOtherGuideCoverage(input);
      expect(combined, hasLength(1), reason: sport);
      expect(combined.single.guideProgrammes.map((p) => p.channelId),
          ['a', 'b', 'c', 'd']);
      expect(combined.single.guideProgrammes.map((p) => p.description),
          input.map((g) => g.guideProgrammes.single.description));
      expect(coalesceOtherGuideCoverage(input.reversed.toList()).single.id,
          combined.single.id);
    }
  });

  test(
      'recorded dates and meaningful parenthetical details are never discarded',
      () {
    for (final detail in [
      '(Women)',
      '(Court 2)',
      '(Session 2)',
      '(Sports, Singles)',
      '(Episode 12)',
      '(Poker) - 2025-10-26',
      '(Poker) - 2026-10-25',
      '(Poker) - 2026'
    ]) {
      expect(
          coalesceOtherGuideCoverage([
            guide('a', 'poker', 'World Poker Tour',
                description: 'Tournament coverage.'),
            guide('b', 'poker', 'World Poker Tour',
                description: 'Tournament coverage. $detail'),
          ]),
          hasLength(2),
          reason: detail);
    }
  });

  test('an exact event heading can be in the title or the first synopsis line',
      () {
    final a = guide('a', 'tennis',
        'Center Court Live - Paris ATP & Hong Kong WTA Quarterfinals',
        description:
            'Tennis action from around the world. (Tennis) - 2026-10-26');
    final b = guide('b', 'tennis', 'Center Court Live',
        description:
            'Paris ATP & Hong Kong WTA Quarterfinals\nTennis action from around the world.');
    final combined = coalesceOtherGuideCoverage([a, b]);
    expect(combined, hasLength(1));
    expect(combined.single.title, a.title);
    expect(combined.single.guideProgrammes,
        [a.guideProgrammes.single, b.guideProgrammes.single]);
    expect(coalesceOtherGuideCoverage([b]).single.id, combined.single.id);
    for (final subtitle in [
      'Paris ATP & Chennai WTA Quarterfinals',
      'Paris ATP & Hong Kong WTA Semifinals',
      'Paris ATP & Hong Kong WTA Quarterfinals Court 2'
    ]) {
      expect(
          coalesceOtherGuideCoverage([
            a,
            guide('c', 'tennis', 'Center Court Live',
                description: '$subtitle\nTennis action from around the world.')
          ]),
          hasLength(2));
    }
  });

  test(
      'named golf rounds tolerate prose but retain round and session boundaries',
      () {
    final a = guide('a', 'golf',
        'DP World Tour Golf: Abu Dhabi Aldar Championship, Second Round',
        description: 'From Yas Links. (Golf) - 2026-10-26');
    final b = guide('b', 'golf',
        'Live DP World Tour Golf: Abu Dhabi Aldar Championship, Round 2',
        description: 'Coverage from the course.');
    expect(coalesceOtherGuideCoverage([a, b]), hasLength(1));
    for (final detail in [
      'Third Round',
      'Round 2 Women',
      'Round 2 Morning Session',
      'Round 2 Featured Groups'
    ]) {
      expect(
          coalesceOtherGuideCoverage([
            a,
            guide('c', 'golf',
                'DP World Tour Golf: Abu Dhabi Aldar Championship, $detail')
          ]),
          hasLength(2));
    }
    expect(
        coalesceOtherGuideCoverage([
          guide('a', 'golf', 'PGA Tour Round 2', description: 'Northern Open'),
          guide('b', 'golf', 'PGA Tour Round 2', description: 'Southern Open'),
        ]),
        hasLength(2));
    expect(
        coalesceOtherGuideCoverage([
          a,
          guide('c', 'golf', a.title,
              description: 'Featured groups from the second round.'),
        ]),
        hasLength(2));
  });

  test('ONE Friday simulcasts ignore slots and the current season wrapper', () {
    final input = [
      guide('a', 'mma', 'ONE Friday Fights 177 ᴸᶦᵛᵉ',
          description: 'From the stadium. (Martial arts) - 2026-10-26'),
      guide('b', 'mma', 'ONE Friday Fights 2026: OFF 177',
          description: 'Weekly Muay Thai and MMA coverage.'),
      guide('c', 'mma', 'LIVE EVENT 02 - 8:30am ONE Friday Fights 177'),
      guide('d', 'mma', 'ONE Championship: Friday Fights 177'),
    ];
    final combined = coalesceOtherGuideCoverage(input);
    expect(combined, hasLength(1));
    expect(combined.single.guideProgrammes.map((p) => p.channelId),
        ['a', 'b', 'c', 'd']);
    expect(combined.single.guideProgrammes.map((p) => p.title),
        input.map((g) => g.title));
    expect(coalesceOtherGuideCoverage(input.reversed.toList()).single.id,
        combined.single.id);
    for (final game in input) {
      expect(coalesceOtherGuideCoverage([game]).single.id, combined.single.id);
    }
  });

  test('ONE Fight Night season wrappers group without erasing bout identity',
      () {
    final input = [
      guide('a', 'mma', 'ONE Fight Night 49: Alpha vs Bravo'),
      guide('b', 'mma', 'ONE Fight Night 2026: OFN 49: Alpha v Bravo'),
      guide('c', 'mma',
          'MMA ONE Championship Fight Night 49: Alpha versus Bravo'),
    ];
    final result = coalesceOtherGuideCoverage(input);
    expect(result, hasLength(1));
    expect(
        result.single.guideProgrammes.map((p) => p.channelId), ['a', 'b', 'c']);
    expect(coalesceOtherGuideCoverage(input.reversed.toList()).single.id,
        result.single.id);
    for (final title in [
      'ONE Fight Night 50: Alpha vs Bravo',
      'ONE Fight Night 2025: OFN 49: Alpha vs Bravo',
      'ONE Fight Night 49: Alpha vs Charlie',
      'ONE Friday Fights 49: Alpha vs Bravo',
      'ONE Fight Night 49: Alpha vs Bravo Prelims',
      'ONE Fight Night',
      'ONE Fight Night 49'
    ]) {
      expect(coalesceOtherGuideCoverage([...input, guide('d', 'mma', title)]),
          hasLength(2),
          reason: title);
    }
  });
  test('generic full-card broadcasts join exactly one numbered live card', () {
    final input = [
      guide('a', 'mma', 'Live MMA One Fight Night',
          stop: 220,
          description: 'The evening headline bout comes from the arena.'),
      guide('b', 'mma', 'Live: MMA One Fight Night - MMA One Fight Night',
          stop: 220,
          description:
              'Action from the MMA One Fight Night. (Episode, Series)'),
      guide('c', 'mma', 'LIVE: ONE Championship - ONE Fight Night 49',
          stop: 220,
          description:
              'ONE Fight Night 49. Started in 2011, live martial arts coverage.'),
    ];
    final grouped = coalesceOtherGuideCoverage(input);
    expect(grouped, hasLength(1));
    expect(grouped.single.title, contains('49'));
    expect(grouped.single.guideProgrammes.map((p) => p.channelId),
        ['a', 'b', 'c']);
    expect(coalesceOtherGuideCoverage(input.reversed.toList()).single.id,
        grouped.single.id);
    expect(
        coalesceOtherGuideCoverage([input.last]).single.id, grouped.single.id);
    expect(
        coalesceOtherGuideCoverage(
            [...input, guide('d', 'mma', 'ONE Fight Night 50', stop: 220)]),
        hasLength(4));
    for (final other in [
      guide('d', 'mma', 'ONE Fight Night', start: -15, stop: 220),
      guide('d', 'mma', 'ONE Fight Night', stop: 210),
      guide('d', 'mma', 'ONE Fight Night Prelims', stop: 220),
      guide('d', 'mma', 'ONE Friday Fights', stop: 220),
      guide('d', 'mma', 'ONE Fight Night',
          stop: 220, description: 'Alpha vs Bravo'),
      guide('d', 'mma', 'ONE Fight Night',
          stop: 220, description: 'Alpha vs Bravo; Charlie vs Delta'),
      guide('d', 'mma', 'ONE Fight Night',
          stop: 220, description: 'Round 2 on Court 1'),
      guide('d', 'mma', 'ONE Fight Night', stop: 220, status: 'On air'),
    ]) {
      expect(coalesceOtherGuideCoverage([input.last, other]), hasLength(2),
          reason: other.title);
    }
    expect(
        coalesceOtherGuideCoverage([
          input.first,
          guide('d', 'mma', 'ONE Fight Night 49',
              stop: 220, description: 'Prelims')
        ]),
        hasLength(2));
    expect(
        coalesceOtherGuideCoverage([
          ...input,
          guide('d', 'mma', 'ONE Fight Night 50 Alpha vs Bravo', stop: 220)
        ]),
        hasLength(4));
    // The same rule applies to other explicitly named numbered promotions.
    expect(
        coalesceOtherGuideCoverage([
          guide('a', 'mma', 'Bellator', stop: 220),
          guide('b', 'mma', 'Bellator 300', stop: 220)
        ]),
        hasLength(1));
  });
  test('ONE card grouping preserves bouts, phases, dates and uncertain titles',
      () {
    final base = guide('a', 'mma', 'ONE Friday Fights 177');
    final alternatives = [
      guide('b', 'mma', 'ONE Friday Fights 178'),
      guide('b', 'mma', 'ONE Fight Night 177'),
      guide('b', 'mma', 'ONE Friday Fights 177 Alpha vs Bravo'),
      guide('b', 'mma', 'ONE Friday Fights 177', description: 'Alpha vs Bravo'),
      guide('b', 'mma', 'ONE Friday Fights 177 Main Card'),
      guide('b', 'mma', 'ONE Friday Fights 177 Prelims'),
      guide('b', 'mma', 'ONE Friday Fights 2025: OFF 177'),
      guide('b', 'mma', 'ONE Friday Fights 177', description: '2025-10-26'),
      guide('b', 'mma', 'ONE Friday Fights 177', description: '2026-10-25'),
      guide('b', 'mma', 'ONE Friday Fights'),
      guide('b', 'mma', 'ONE Championship Friday Fight Night'),
      guide('b', 'mma', 'ONE Friday Fights 177', status: 'On air · replay'),
      guide('b', 'mma', 'ONE Friday Fights 177', start: 100, stop: 220),
    ];
    for (final other in alternatives) {
      expect(coalesceOtherGuideCoverage([base, other]), hasLength(2),
          reason: '${other.title} ${other.guideProgrammes.first.description}');
    }
  });

  test('provider slots do not split the same bout or combine different bouts',
      () {
    final combined = coalesceOtherGuideCoverage([
      guide(
          'a', 'mma', 'LIVE EVENT 02 - 8:30am ONE Friday Fights Alpha v Bravo'),
      guide('b', 'mma',
          'LIVE EVENT 15 - 1:30pm ONE Friday Fights Alpha vs Bravo'),
      guide('c', 'mma', 'ONE Friday Fights Alpha versus Bravo'),
      guide('d', 'mma', 'ONE Friday Fights Charlie vs Delta'),
    ]);
    expect(combined, hasLength(2));
    expect(
        combined
            .singleWhere((g) => g.guideProgrammes.length == 3)
            .guideProgrammes
            .map((p) => p.channelId),
        ['a', 'b', 'c']);
  });

  test('field hockey score card owns only unambiguous matching live coverage',
      () {
    SportsGame fixture(String id) => SportsGame(
        id: id,
        league: sportsLeagueById('field-hockey.womens-college-field-hockey')!,
        start: now,
        state: GameState.live,
        statusText: 'Q2',
        home: const SportsTeam(
            id: 'a',
            name: 'Liberty Flames',
            shortName: 'Liberty',
            abbreviation: 'LIB'),
        away: const SportsTeam(
            id: 'b',
            name: 'Villanova Wildcats',
            shortName: 'Villanova',
            abbreviation: 'VILL'));
    final broadcast = guide(
        'a', 'field-hockey', 'College Field Hockey: Liberty at Villanova');
    final merged = mergeSportsGuideCoverage([fixture('score')], [broadcast]);
    expect(merged, hasLength(1));
    expect(merged.single.id, 'score');
    expect(merged.single.guideProgrammes, broadcast.guideProgrammes);
    expect(
        mergeSportsGuideCoverage([fixture('one'), fixture('two')], [broadcast]),
        hasLength(3));
    for (final title in [
      'Field Hockey: Liberty at Rutgers',
      'Field Hockey Studio',
      'Mens Field Hockey: Liberty at Villanova'
    ]) {
      expect(
          mergeSportsGuideCoverage(
              [fixture('score')], [guide('b', 'field-hockey', title)]),
          hasLength(2));
    }
  });
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
