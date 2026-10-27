import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:nox_iptv/models/channel.dart';
import 'package:nox_iptv/models/epg_program.dart';
import 'package:nox_iptv/models/sports.dart';
import 'package:nox_iptv/services/replay_schedule_service.dart';
import 'package:nox_iptv/services/sports_replay_service.dart';

final now = DateTime.utc(2026, 10, 22, 12);
SportsReplay replay(String title,
        {String sport = 'football', String desc = ''}) =>
    SportsReplay(sport: sport, title: title, broadcasts: [
      ReplayBroadcast(
          Channel(
              id: 'p::a',
              rawId: 'a',
              playlistId: 'p',
              name: 'Test',
              group: 'Sports',
              url: 'https://example.test/no-stream'),
          EpgProgram(
              channelId: 'a',
              title: title,
              description: desc,
              start: now.subtract(const Duration(hours: 1)),
              stop: now.add(const Duration(hours: 1))))
    ]);
SportsGame game(
        {String id = '1',
        String league = 'college-football',
        GameState state = GameState.post,
        int days = 5,
        String status = 'Final',
        String home = 'Indiana Hoosiers',
        String away = 'Ohio State Buckeyes'}) =>
    SportsGame(
        id: id,
        league: sportsLeagueById(league)!,
        start: now.subtract(Duration(days: days)),
        state: state,
        statusText: status,
        home: SportsTeam(
            id: 'a',
            name: home,
            shortName: 'Hoosiers',
            abbreviation: 'IND',
            location: 'Indiana'),
        away: SportsTeam(
            id: 'b',
            name: away,
            shortName: 'Buckeyes',
            abbreviation: 'OSU',
            location: away == 'Ohio State Buckeyes' ? 'Ohio State' : 'Oregon'));

void main() {
  test(
      'new cached results fill negative cache and revoke ambiguous positive matches',
      () async {
    var rows = <SportsGame>[];
    var requests = 0, updates = 0;
    final event = replay('College Football - Ohio State at Indiana');
    final service = ReplayScheduleService(
        clock: () => now,
        cached: () => rows,
        fetch: (l, d) async {
          requests++;
          return [];
        });
    Future<void> refresh() => service
        .enrich([event], cancelled: () => false, onUpdate: () => updates++);
    await refresh();
    expect(service.known(event), isNull);
    rows = [game()];
    await refresh();
    expect(service.known(event), isNotNull);
    expect(requests, 2);
    rows = [game(), game(id: 'other', days: 6)];
    await refresh();
    expect(service.known(event), isNull);
    expect(updates, 2);
    expect(requests, 2);
  });
  test('a matching cached scoreboard costs no network requests', () async {
    var requests = 0, updates = 0;
    final event = replay('College Football - Ohio State at Indiana');
    final service = ReplayScheduleService(
        clock: () => now,
        cached: () => [game()],
        fetch: (l, d) async {
          requests++;
          return [];
        });
    await service
        .enrich([event], cancelled: () => false, onUpdate: () => updates++);
    expect(requests, 0);
    expect(updates, 1);
    expect(service.known(event)?.label, '17 Oct 2026');
  });
  test('exact teams and competition produce a possible date, never certainty',
      () {
    final value = possibleReplayDate(
        replay('College Football - Ohio State at Indiana'), [game()])!;
    expect(value.label, '17 Oct 2026');
    expect(value.isPossible, true);
    expect(value.sortKey, isNull);
    expect(value.source, contains('does not prove'));
  });
  test(
      'rejects ambiguity, youth, women, wrong league, abandoned and nonfinal games',
      () {
    final event = replay('College Football - Ohio State at Indiana');
    expect(possibleReplayDate(event, [game(), game(id: '2', days: 6)]), isNull);
    for (final g in [
      game(state: GameState.live),
      game(state: GameState.pre),
      game(status: 'Canceled'),
      game(days: 20),
      game(days: -1),
      game(league: 'nfl'),
      game(away: 'Oregon Ducks')
    ]) {
      expect(possibleReplayDate(event, [g]), isNull);
    }
    for (final title in [
      'College Football U19 - Ohio State at Indiana',
      'Women’s College Football - Ohio State at Indiana',
      'College Football Classics - Ohio State at Indiana',
      'College Football - Ohio State at Indiana Game 2',
      'College Football - Ohio State at Indiana State',
      'College Football - OSU at IND',
      'College Football - Buckeyes at Hoosiers'
    ]) {
      expect(possibleReplayDate(replay(title), [game()]), isNull,
          reason: title);
    }
  });
  test('same API event from multiple cached days is not ambiguous', () {
    expect(
        possibleReplayDate(replay('College Football - Ohio State at Indiana'),
            [game(), game()]),
        isNotNull);
  });
  test(
      'requests are serialized, bounded across revisits, cached and failures quiet',
      () async {
    var requests = 0, active = 0, maxActive = 0;
    final service = ReplayScheduleService(
        clock: () => now,
        cached: () => [],
        fetch: (league, day) async {
          requests++;
          active++;
          if (active > maxActive) maxActive = active;
          await Future<void>.delayed(Duration.zero);
          active--;
          if (league.id == 'college-football') return [game()];
          throw StateError('offline');
        });
    final events = [
      replay('College Football - Ohio State at Indiana'),
      replay('NFL - Pittsburgh Steelers at Tampa Bay Buccaneers'),
      replay('NBA - Boston Celtics at New York Knicks', sport: 'basketball')
    ];
    var updates = 0;
    await Future.wait([
      for (var i = 0; i < 3; i++)
        service.enrich(events,
            cancelled: () => false, onUpdate: () => updates++)
    ]);
    expect(requests, 4);
    expect(maxActive, 1);
    expect(updates, 1);
    expect(service.known(events.first)?.isPossible, true);
    await service.enrich(events, cancelled: () => false, onUpdate: () {});
    expect(requests, 4);
  });
  test(
      'inactive view stops subsequent requests and never publishes stale results',
      () async {
    var cancelled = false, requests = 0, updates = 0;
    final gate = Completer<List<SportsGame>>();
    final service = ReplayScheduleService(
        clock: () => now,
        cached: () => [],
        fetch: (l, d) {
          requests++;
          return gate.future;
        });
    final pending = service.enrich(
        [replay('College Football - Ohio State at Indiana')],
        cancelled: () => cancelled, onUpdate: () => updates++);
    await Future<void>.delayed(Duration.zero);
    expect(requests, 1);
    cancelled = true;
    gate.complete([game()]);
    await pending;
    expect(requests, 1);
    expect(updates, 0);
  });
}
