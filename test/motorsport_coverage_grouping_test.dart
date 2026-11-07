import 'package:flutter_test/flutter_test.dart';
import 'package:nox_iptv/models/sports.dart';
import 'package:nox_iptv/models/epg_program.dart';
import 'package:nox_iptv/utils/motorsport_coverage.dart';

final now = DateTime.utc(2026, 10, 25, 20);
const team = SportsTeam(id: '', name: '', shortName: '', abbreviation: '');
SportsGame guide(String id, String title,
        {String? description, int start = -30, int stop = 120}) =>
    SportsGame(
        id: id,
        league: sportsLeagueById('guide.racing')!,
        start: now.add(Duration(minutes: start)),
        end: now.add(Duration(minutes: stop)),
        state: GameState.live,
        statusText: 'Live · guide',
        home: team,
        away: team,
        event: SportsEventInfo(title: title),
        source: 'Channel guide',
        guideProgrammes: [
          EpgProgram(
              channelId: id,
              title: title,
              description: description,
              start: now.add(Duration(minutes: start)),
              stop: now.add(Duration(minutes: stop)),
              isLive: true)
        ]);
SportsGame scheduled(String id,
        {String title = 'Mexico City Grand Prix',
        String session = 'Race',
        String league = 'racing.f1',
        int start = 0}) =>
    SportsGame(
        id: id,
        league: sportsLeagueById(league)!,
        start: now.add(Duration(minutes: start)),
        end: now.add(const Duration(hours: 3)),
        state: GameState.live,
        statusText: 'Lap 12',
        home: team,
        away: team,
        event: SportsEventInfo(title: title, session: session),
        broadcasts: const ['Sky Sports F1']);

void main() {
  test('Supercars session aliases retain qualifiers and every channel', () {
    final input = [
      guide('a', 'Supercars: Sandown Qualifying & Top 10 Shootout (KAYO) LIVE'),
      guide('b', 'Supercars: Quali & TTSO Race 33',
          description:
              'LIVE coverage from Sandown Motor Raceway, Melbourne. Super 2 Practice 2.'),
      guide('c', 'Supercars Sandown Qualifying and Top Ten Shootout Race33'),
    ];
    final result = coalesceMotorsportCoverage(input);
    expect(result, hasLength(1));
    expect(
        result.single.guideProgrammes.map((p) => p.channelId), ['a', 'b', 'c']);
    expect(result.single.guideProgrammes.map((p) => p.title),
        input.map((g) => g.title));
    expect(coalesceMotorsportCoverage(input.reversed.toList()).single.id,
        result.single.id);
    final ambiguous = coalesceMotorsportCoverage(
        [...input, guide('d', 'Supercars Sandown Quali & TTSO Race 34')]);
    expect(ambiguous, hasLength(3));
    expect(
        ambiguous
            .singleWhere((g) => g.guideProgrammes.length == 2)
            .guideProgrammes
            .map((p) => p.channelId),
        ['b', 'c']);
  });
  test('support packages merge only with an unambiguous matching support day',
      () {
    final input = [
      guide('a', 'Supercars: Sandown Supports (KAYO) LIVE', stop: 160),
      guide('b', 'Supercars: Saturday Supports',
          description: 'From Sandown Motor Raceway, Melbourne.'),
    ];
    final result = coalesceMotorsportCoverage(input);
    expect(result, hasLength(1));
    expect(result.single.guideProgrammes.map((p) => p.channelId), ['a', 'b']);
    expect(
        coalesceMotorsportCoverage(
            [...input, guide('c', 'Supercars Sandown Sunday Supports')]),
        hasLength(3));
    expect(
        coalesceMotorsportCoverage([
          ...input,
          guide('c', 'Supercars Sandown Race 33'),
          guide('d', 'Supercars Sandown')
        ]),
        hasLength(2));
    expect(
        coalesceMotorsportCoverage(
            [input.first, guide('d', 'Supercars Sandown')]),
        hasLength(2));
  });
  test(
      'support series and combined numbered races never become a headline race',
      () {
    final result = coalesceMotorsportCoverage([
      guide('a', 'Supercars Sandown Race 1'),
      guide('b', 'Supercars Sandown Super2 Race 1'),
      guide('c', 'Supercars Sandown Super 2 Race 1'),
      guide('d', 'Supercars Sandown Super3 Race 1'),
      guide('e', 'Supercars Sandown Race 33 and Race 34'),
      guide('f', 'Supercars Sandown Race 33'),
      guide('g', 'Supercars Sandown Race 34'),
    ]);
    expect(result, hasLength(6));
    expect(
        result
            .singleWhere((g) => g.guideProgrammes.length == 2)
            .guideProgrammes
            .map((p) => p.channelId),
        ['b', 'c']);
  });
  test('multi-digit races, shootouts and combined sessions stay distinct', () {
    final titles = [
      'Race 33',
      'Race 34',
      'Qualifying',
      'Top 10 Shootout',
      'Qualifying & Top 10 Shootout',
      'Qualifying & Top 10 Shootout Race 33',
      'Qualifying & Top 10 Shootout Race 34',
      'Pre Race',
      'Supports'
    ];
    final result = coalesceMotorsportCoverage([
      for (final (i, t) in titles.indexed) guide('$i', 'Supercars Sandown $t')
    ]);
    expect(result, hasLength(titles.length));
    expect(
        coalesceMotorsportCoverage([
          guide('a', 'Supercars Sandown and Bathurst Qualifying'),
          guide('b', 'Supercars Sandown Qualifying')
        ]),
        hasLength(2));
    expect(
        coalesceMotorsportCoverage([
          guide('a', 'Supercars Sandown Race 33'),
          guide('b', 'Supercars Sandown Race 33', start: 240, stop: 360)
        ]),
        hasLength(2));
  });
  test('accented F1 venues and explicit practice aliases share one session',
      () {
    final input = [
      guide('a', 'Live F1 São Paulo GP - Free Practice 1'),
      guide('b', 'Formula One: Sao Paulo Grand Prix - First Practice'),
      guide('c', 'Formula 1 Brazilian GP FP1'),
      guide('d', 'F1 Interlagos Practice One'),
      guide('e', 'F1 Sa\u0303o Paulo P1'),
    ];
    final combined = coalesceMotorsportCoverage(input);
    expect(combined, hasLength(1));
    expect(combined.single.guideProgrammes.map((p) => p.channelId),
        ['a', 'b', 'c', 'd', 'e']);
    expect(combined.single.guideProgrammes.map((p) => p.title),
        input.map((g) => g.title));
    expect(coalesceMotorsportCoverage(input.reversed.toList()).single.id,
        combined.single.id);
    expect(
        coalesceMotorsportCoverage([input.last]).single.id, combined.single.id);
    final merged = mergeMotorsportCoverage([
      scheduled('practice',
          title: 'São Paulo Grand Prix', session: 'Practice 1')
    ], combined);
    expect(merged, hasLength(1));
    expect(merged.single.id, 'practice');
    expect(merged.single.guideProgrammes, hasLength(5));
  });

  test('practice aliases never combine different sessions or circuits', () {
    final titles = [
      'F1 São Paulo First Practice',
      'F1 Sao Paulo Second Practice',
      'F1 São Paulo Practice Three',
      'F1 São Paulo Sprint Qualifying',
      'F1 São Paulo Sprint Race',
      'F1 São Paulo Qualifying',
      'F1 São Paulo Race',
      'F1 Mexico P1',
      'Formula 2 São Paulo First Practice',
    ];
    expect(
        coalesceMotorsportCoverage(
            [for (final (i, title) in titles.indexed) guide('$i', title)]),
        hasLength(titles.length));
  });

  test(
      'F1 aliases, descriptions and staggered coverage retain every exact slot',
      () {
    final input = [
      guide('a', 'Live F1: Mexico GP - Race', description: 'Main feed'),
      guide('b', 'Formula One: Mexican Grand Prix',
          description: 'Live from Mexico.', start: -60, stop: 150),
      guide('c', 'Formula 1 Mexico: Race HD', description: 'Different synopsis')
    ];
    final grouped = coalesceMotorsportCoverage(input);
    expect(grouped, hasLength(1));
    expect(grouped.single.guideProgrammes.map((p) => p.channelId),
        ['a', 'b', 'c']);
    expect(grouped.single.start, input[1].start);
    expect(grouped.single.end, input[1].end);
    expect(coalesceMotorsportCoverage(input.reversed.toList()).single.id,
        grouped.single.id);
    // Removing a simulcast does not change this event's identity.
    expect(coalesceMotorsportCoverage([input[0], input[2]]).single.id,
        grouped.single.id);
  });
  test(
      'NASCAR venue aliases combine Cup but keep Xfinity, Trucks and other tracks',
      () {
    final grouped = coalesceMotorsportCoverage([
      guide('a', 'Live NASCAR Cup Series: YellaWood 500'),
      guide('b', 'NASCAR Cup: Talladega', start: -45),
      guide('c', 'NASCAR Xfinity: Talladega'),
      guide('d', 'NASCAR Craftsman Truck Series: Talladega'),
      guide('e', 'NASCAR Cup: Martinsville'),
      guide('f', 'NASCAR Racing'),
    ]);
    expect(grouped, hasLength(5));
    expect(
        grouped
            .singleWhere((g) => g.guideProgrammes.length == 2)
            .guideProgrammes
            .map((p) => p.channelId),
        ['a', 'b']);
  });
  test(
      'sessions, support races, studio shows and different numbered races remain distinct',
      () {
    final titles = [
      'F1 Mexico Practice 1',
      'F1 Mexico Practice 2',
      'F1 Mexico Sprint Qualifying',
      'F1 Mexico Sprint',
      'F1 Mexico Qualifying',
      'F1 Mexico Race',
      'F1 Mexico Pre Race',
      'F1 Mexico Post Race',
      'F1 Mexico Supports',
      'Formula 2 Mexico Race 1',
      'Formula 2 Mexico Race 2'
    ];
    expect(
        coalesceMotorsportCoverage(
            [for (var i = 0; i < titles.length; i++) guide('$i', titles[i])]),
        hasLength(titles.length));
  });
  test('ambiguous, generic and non-overlapping listings do not collapse', () {
    final input = [
      guide('a', 'F1 Mexico Race'),
      guide('b', 'F1 Mexico Qualifying'),
      guide('c', 'F1 Mexico'),
      guide('d', 'Live F1'),
      guide('e', 'Formula 1 Live'),
      guide('f', 'F1 Mexico Race', start: 180, stop: 300)
    ];
    expect(coalesceMotorsportCoverage(input), hasLength(input.length));
    expect(
        coalesceMotorsportCoverage([
          guide('a', 'F1 Mexico and Brazil Race'),
          guide('b', 'F1 Mexico Race')
        ]),
        hasLength(2));
  });
  test(
      'score-backed card keeps identity, score metadata and every guide channel',
      () {
    final main = scheduled('score-id');
    final grouped = coalesceMotorsportCoverage([
      guide('a', 'Live F1 Mexico Race'),
      guide('b', 'Formula 1 Mexican GP')
    ]);
    final merged = mergeMotorsportCoverage([main], grouped);
    expect(merged, hasLength(1));
    expect(merged.single.id, main.id);
    expect(merged.single.start, main.start);
    expect(merged.single.statusText, main.statusText);
    expect(merged.single.source, main.source);
    expect(merged.single.broadcasts, main.broadcasts);
    expect(merged.single.guideProgrammes, hasLength(2));
    final again = mergeMotorsportCoverage(merged, grouped);
    expect(identical(again.single, merged.single), isTrue);
    expect(again.single.guideProgrammes, hasLength(2));
    expect(mergeMotorsportCoverage(again, []).single.guideProgrammes, isEmpty);
    expect(
        identical(
            mergeMotorsportCoverage([main], grouped).single, merged.single),
        isTrue);
  });
  test('ambiguous scheduled sessions never swallow unspecified coverage', () {
    final primary = [
      scheduled('race'),
      scheduled('qual', session: 'Qualifying')
    ];
    expect(mergeMotorsportCoverage(primary, [guide('a', 'F1 Mexico')]),
        hasLength(3));
    expect(
        mergeMotorsportCoverage([scheduled('race', title: 'Brazil Grand Prix')],
            [guide('a', 'F1 Mexico Race')]),
        hasLength(2));
    expect(
        mergeMotorsportCoverage(
            [scheduled('race', start: -120)], [guide('a', 'F1 Mexico Race')]),
        hasLength(2));
  });
  test(
      'other sports stay untouched; repeated warm merges reuse attached models',
      () {
    final poker = SportsGame(
        id: 'p',
        league: sportsLeagueById('guide.poker')!,
        start: now,
        state: GameState.live,
        statusText: 'On air',
        home: team,
        away: team,
        source: 'Channel guide',
        event: const SportsEventInfo(title: 'Poker'));
    expect(
        identical(coalesceMotorsportCoverage([poker]).single, poker), isTrue);
    final primary = [
      for (var i = 0; i < 100; i++) scheduled('$i', title: 'Event $i')
    ];
    final coverage = [
      for (var i = 0; i < 100; i++) guide('$i', 'F1 Event $i Race')
    ];
    final watch = Stopwatch()..start();
    for (var i = 0; i < 100; i++) {
      expect(mergeMotorsportCoverage(primary, coverage), hasLength(100));
    }
    // ignore: avoid_print
    print(
        '100 warm motorsport merges / 100 events: ${watch.elapsedMilliseconds}ms');
  });
}
