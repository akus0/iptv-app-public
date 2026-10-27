import 'dart:convert';
import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nox_iptv/models/sports.dart';
import 'package:nox_iptv/services/sports_supplement_service.dart';
import 'package:nox_iptv/services/league_broadcast_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // Keep the +2h fixture on the same local day, including late-night runs.
  final today = DateTime.now();
  final start = DateTime(today.year, today.month, today.day + 1, 12).toUtc();
  final day = start.toLocal();
  final league = sportsLeagueById('eng.1')!;
  SportsGame primary() => SportsGame(
      id: 'espn-1',
      league: league,
      start: start,
      state: GameState.pre,
      statusText: 'Scheduled',
      home: const SportsTeam(
          id: 'a',
          name: 'Arsenal',
          shortName: 'Arsenal',
          abbreviation: 'ARS',
          score: '2'),
      away: const SportsTeam(
          id: 'c',
          name: 'Chelsea',
          shortName: 'Chelsea',
          abbreviation: 'CHE',
          score: '1'));
  Map<String, dynamic> row(
          {String id = '101',
          String home = 'Arsenal',
          String away = 'Chelsea',
          String competition = 'English Premier League',
          String status = 'NS',
          DateTime? time}) =>
      {
        'idEvent': id,
        'idLeague': '4328',
        'strLeague': competition,
        'strSport': 'Soccer',
        'strHomeTeam': home,
        'strAwayTeam': away,
        'idHomeTeam': '1',
        'idAwayTeam': '2',
        'strStatus': status,
        'strTimestamp': (time ?? start).toIso8601String().replaceAll('Z', ''),
        'intHomeScore': null,
        'intAwayScore': null,
      };

  test(
      'official broadcast hints arrive independently and failures leave the original event intact',
      () async {
    final calls = <Uri>[];
    final official = LeagueBroadcastService(MockClient((r) async {
      calls.add(r.url);
      return http.Response(
          jsonEncode({
            'gameWeek': [
              {
                'games': [
                  {
                    'id': 1,
                    'startTimeUTC': start.toIso8601String(),
                    'gameState': 'FUT',
                    'gameScheduleState': 'OK',
                    'homeTeam': {
                      'placeName': {'default': 'Boston'},
                      'commonName': {'default': 'Bruins'}
                    },
                    'awayTeam': {
                      'placeName': {'default': 'Nashville'},
                      'commonName': {'default': 'Predators'}
                    },
                    'tvBroadcasts': [
                      {'network': 'NESN', 'countryCode': 'US'}
                    ],
                  }
                ]
              }
            ]
          }),
          200);
    }), spacing: Duration.zero);
    final supplement = SportsSupplementService.withClient(
        MockClient((_) async => throw StateError('No per-event search needed')),
        official: official);
    final g = SportsGame(
        id: 'espn-nhl',
        league: sportsLeagueById('nhl')!,
        start: start,
        state: GameState.live,
        statusText: '2nd period',
        home: const SportsTeam(
            id: '1',
            name: 'Boston Bruins',
            shortName: 'Bruins',
            abbreviation: 'BOS',
            score: '2'),
        away: const SportsTeam(
            id: '2',
            name: 'Nashville Predators',
            shortName: 'Predators',
            abbreviation: 'NSH',
            score: '1'));
    await supplement.warmBroadcasts([g, g], cancelled: () => false);
    final enriched = supplement.enrichCached(g);
    expect(calls, hasLength(1));
    expect(enriched.id, g.id);
    expect(enriched.home.score, '2');
    expect(enriched.state, GameState.live);
    expect(enriched.start, start);
    expect(enriched.onlineBroadcasts.single.source, 'NHL');
    expect((await supplement.broadcastsFor(g)).single.name, 'NESN');
    expect(calls, hasLength(1));
    expect(await supplement.broadcastsFor(g, cancelled: () => true), isEmpty);
  });
  test(
      'extra schedules preserve primary identity, score and state, and add missing fixtures',
      () {
    final first = primary();
    final extras = parseSupplementGames((
      [
        row(),
        row(id: '102', home: 'Liverpool', away: 'Everton'),
        row(id: '102', home: 'Liverpool', away: 'Everton'),
        row(id: 'bad', competition: '', home: ''),
      ],
      [league],
      day
    ));
    expect(extras.length, 2);
    final merged = mergeSupplementGames([first], extras);
    expect(merged.length, 2);
    expect(merged.first, same(first));
    expect(merged.first.home.score, '2');
    expect(merged.last.id, 'tsdb:102');
    expect(merged.last.source, 'TheSportsDB');
    expect(merged.last.state, GameState.pre);
    expect(extras.first.start.isAtSameMomentAs(start), true);
  });
  test(
      'same names in women/youth competitions or different kickoffs are not merged',
      () {
    final extras = parseSupplementGames((
      [
        row(id: '102', competition: 'Women’s Super League'),
        row(id: '103', competition: 'Premier League U21'),
        row(id: '104', time: start.add(const Duration(hours: 2))),
      ],
      [league],
      day
    ));
    expect(mergeSupplementGames([primary()], extras).length, 4);
    expect(extras.first.league.source, 'TheSportsDB');
    expect(extras.first.league.hasStandings, false);
  });
  test('start time alone never marks a supplemental event live', () {
    final time = DateTime.now().toUtc().subtract(const Duration(minutes: 20));
    final games = parseSupplementGames((
      [
        row(time: time),
        row(id: '102', time: time, status: '1H'),
        row(id: '103', time: time, status: 'FT'),
        row(id: '104', time: time, status: 'PST'),
      ],
      [league],
      time.toLocal()
    ));
    expect(games.map((g) => g.state),
        [GameState.pre, GameState.live, GameState.post]);
  });
  test(
      'online TV lookup validates event identity, coalesces and caches requests',
      () async {
    final requests = <Uri>[];
    final service =
        SportsSupplementService.withClient(MockClient((request) async {
      requests.add(request.url);
      expect(request.url.host, 'www.thesportsdb.com');
      return http.Response(
          jsonEncode(request.url.path.endsWith('searchevents.php')
              ? {
                  'event': [row()]
                }
              : {
                  'tvevent': [
                    {
                      'idEvent': '101',
                      'strChannel': 'Sky Sports Premier League',
                      'strCountry': 'United Kingdom'
                    },
                    {'idEvent': 'wrong', 'strChannel': 'Incorrect feed'},
                  ]
                }),
          200);
    }), requestSpacing: Duration.zero);
    final replies = await Future.wait(
        [service.broadcastsFor(primary()), service.broadcastsFor(primary())]);
    expect(requests.length, 2);
    expect(replies.first.single.country, 'United Kingdom');
    expect(replies.first.single.source, 'TheSportsDB');
    await service.broadcastsFor(primary());
    expect(requests.length, 2);
    final enriched = service.enrichCached(primary());
    expect(enriched.onlineBroadcasts.single.name, 'Sky Sports Premier League');
    expect(enriched.id, 'espn-1');
    expect(enriched.home.score, '2');
    expect(requests.first.queryParameters.keys.toSet(), {'e', 'd'});
  });
  test('wrong event returned by free search cannot supply TV evidence',
      () async {
    var requests = 0;
    final service =
        SportsSupplementService.withClient(MockClient((request) async {
      requests++;
      return http.Response(
          jsonEncode({
            'event': [row(away: 'Liverpool')]
          }),
          200);
    }), requestSpacing: Duration.zero);
    expect(await service.broadcastsFor(primary()), isEmpty);
    expect(requests, 1); // No lookup for an unrelated event.
  });
  test(
      'secondary failures, cancellation and 429 cooldown cannot stall primary scores',
      () async {
    var requests = 0;
    final service =
        SportsSupplementService.withClient(MockClient((request) async {
      requests++;
      return http.Response('Rate limited', 429);
    }), requestSpacing: Duration.zero);
    expect(await service.gamesForDay([league], day, cancelled: () => true),
        isEmpty);
    expect(requests, 0);
    expect(await service.gamesForDay([league], day), isEmpty);
    expect(requests, 1);
    expect(await service.broadcastsFor(primary()), isEmpty);
    expect(requests, 1);
    final original = primary();
    expect(mergeSupplementGames([original], []).single, same(original));
  });
  test('day requests are serial, cached and scoped to selected sports',
      () async {
    var active = 0, peak = 0, requests = 0;
    final service =
        SportsSupplementService.withClient(MockClient((request) async {
      requests++;
      active++;
      if (active > peak) peak = active;
      expect(request.url.queryParameters['s'], 'Soccer');
      await Future<void>.delayed(const Duration(milliseconds: 2));
      active--;
      return http.Response(
          jsonEncode({
            'events': [row()]
          }),
          200);
    }), requestSpacing: Duration.zero);
    final results = await service.gamesForDay([league], day);
    expect(results.length, 1);
    final originalRequests = requests;
    expect(peak, 1);
    expect(service.cachedGamesForDay([league], day).length, 1);
    expect(identical(await service.gamesForDay([league], day), results), true);
    expect(await service.gamesForDay([league], day, cancelled: () => true),
        isEmpty);
    expect(requests, originalRequests);
  });
  test(
      'leaving a day cancels queued requests and does not cache partial results',
      () async {
    final response = Completer<http.Response>();
    final started = Completer<void>();
    var cancelled = false, requests = 0;
    final service =
        SportsSupplementService.withClient(MockClient((request) async {
      requests++;
      started.complete();
      return response.future;
    }), requestSpacing: Duration.zero);
    final pending =
        service.gamesForDay([league], day, cancelled: () => cancelled);
    await started.future;
    cancelled = true;
    response.complete(http.Response(
        jsonEncode({
          'events': [row()]
        }),
        200));
    expect(await pending, isEmpty);
    expect(requests, 1);
    expect(service.cachedGamesForDay([league], day), isEmpty);
  });
}
