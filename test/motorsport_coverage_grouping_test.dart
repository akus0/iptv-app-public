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
