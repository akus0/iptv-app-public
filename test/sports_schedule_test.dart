import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nox_iptv/models/sports.dart';
import 'package:nox_iptv/services/sports_service.dart';

Map<String, Object> event(String id, DateTime at) => {
      'id': id,
      'date': at.toUtc().toIso8601String(),
      'status': {
        'type': {'state': 'pre', 'shortDetail': 'Scheduled'}
      },
      'competitions': [
        {
          'competitors': [
            {
              'homeAway': 'home',
              'team': {'id': 'h', 'displayName': 'Home Club'}
            },
            {
              'homeAway': 'away',
              'team': {'id': 'a', 'displayName': 'Away Club'}
            }
          ]
        }
      ]
    };
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
      'schedule windows share monthly requests and exclude dates outside local boundaries',
      () async {
    final requests = <String>[];
    final first = DateTime(2026, 11, 10);
    final service = SportsService.withClient(MockClient((r) async {
      requests.add(r.url.queryParameters['dates']!);
      expect(r.url.queryParameters['limit'], '1000');
      return http.Response(
          jsonEncode({
            'events': [
              event('before', first.subtract(const Duration(minutes: 1))),
              event('start', first),
              event('late', DateTime(2026, 11, 16, 23, 59)),
              event('after', DateTime(2026, 11, 17)),
            ]
          }),
          200);
    }));
    final league = sportsLeagueById('eng.1')!;
    final results = await Future.wait([
      service.scheduleGames(league, first, DateTime(2026, 11, 16)),
      service.scheduleGames(league, first, DateTime(2026, 11, 16))
    ]);
    expect(requests, ['202611']);
    expect(results.first.games.map((g) => g.id), ['start', 'late']);
    expect(results.first.incomplete, isFalse);
    await service.scheduleGames(
        league, DateTime(2026, 11, 17), DateTime(2026, 11, 23));
    expect(requests.length, 1);
  });
  test('failed refresh retains cached fixtures and marks the window incomplete',
      () async {
    var now = DateTime(2026, 11, 10), failed = false;
    final service = SportsService.withClient(
        MockClient((_) async => failed
            ? http.Response('unavailable', 503)
            : http.Response(
                jsonEncode({
                  'events': [event('one', DateTime(2026, 11, 12))]
                }),
                200)),
        clock: () => now);
    final league = sportsLeagueById('eng.1')!;
    expect(
        (await service.scheduleGames(league, now, DateTime(2026, 11, 16)))
            .games,
        hasLength(1));
    failed = true;
    now = now.add(const Duration(minutes: 11));
    final result =
        await service.scheduleGames(league, now, DateTime(2026, 11, 16));
    expect(result.games, hasLength(1));
    expect(result.incomplete, isTrue);
    expect(service.lastError, isNull,
        reason: 'Optional browsing must not change Events status');
  });
  test('closing the schedule does not queue subsequent months', () async {
    final response = Completer<http.Response>();
    var calls = 0, active = true;
    final service = SportsService.withClient(MockClient((_) {
      calls++;
      return response.future;
    }));
    final pending = service.scheduleGames(sportsLeagueById('eng.1')!,
        DateTime(2026, 11, 20), DateTime(2026, 12, 19),
        shouldContinue: () => active);
    await Future<void>.delayed(Duration.zero);
    active = false;
    response.complete(http.Response('{"events":[]}', 200));
    await pending;
    expect(calls, 1);
  });
  test('unsupported guide leagues and excessive date windows never download',
      () async {
    var calls = 0;
    final service = SportsService.withClient(MockClient((_) async {
      calls++;
      return http.Response('{}', 200);
    }));
    final result = await service.scheduleGames(sportsLeagueById('guide.npb')!,
        DateTime(2026, 11, 1), DateTime(2026, 11, 7));
    expect(result.incomplete, isTrue);
    await expectLater(
        service.scheduleGames(sportsLeagueById('eng.1')!, DateTime(2026, 11, 1),
            DateTime(2027, 1, 1)),
        throwsArgumentError);
    expect(calls, 0);
  });
  test('day overview shares caches, keeps rugby fixtures and local boundaries',
      () async {
    final day = DateTime(2026, 11, 10);
    final calls = <Uri>[];
    final service = SportsService.withClient(MockClient((request) async {
      calls.add(request.url);
      return http.Response(
          jsonEncode({
            'events': [
              event('before', day.subtract(const Duration(seconds: 1))),
              event('today', day.add(const Duration(hours: 12))),
              event('tomorrow', DateTime(2026, 11, 11)),
            ]
          }),
          200);
    }), clock: () => day);
    final leagues = [
      kLiveRugbyLeague,
      sportsLeagueById('nba')!,
      sportsLeagueById('rugby.267979') ??
          const SportsLeague(
              id: 'test.rugby',
              espnPath: 'rugby/267979',
              name: 'Rugby',
              shortName: 'Rugby',
              logoUrl: '')
    ];
    final first = await service.scheduleDay(leagues, day);
    expect(first.incomplete, isFalse);
    expect(first.games, hasLength(2));
    expect(first.games.every((g) => g.id == 'today'), isTrue);
    expect(calls.every((u) => u.queryParameters['dates']!.length == 8), isTrue,
        reason: 'An all-league day must not download whole monthly boards');
    final count = calls.length;
    await service.scheduleDay(leagues, day);
    expect(calls.length, count);
    expect(service.lastError, isNull);
  });

  test('day overview bounds concurrency and cancels unstarted requests',
      () async {
    var active = true, calls = 0, running = 0, peak = 0;
    final release = Completer<void>();
    final service = SportsService.withClient(MockClient((_) async {
      calls++;
      running++;
      if (running > peak) peak = running;
      await release.future;
      running--;
      return http.Response('{"events":[]}', 200);
    }));
    final pending = service.scheduleDay([
      sportsLeagueById('nba')!,
      sportsLeagueById('nhl')!,
      sportsLeagueById('eng.1')!
    ], DateTime(2026, 11, 10), shouldContinue: () => active);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(calls, 2);
    active = false;
    release.complete();
    final result = await pending;
    expect(peak, 2);
    expect(calls, 2);
    expect(result.incomplete, isTrue);
    expect(service.lastError, isNull);
  });

  test(
      'day overview marks failed feeds incomplete without changing Events status',
      () async {
    final service = SportsService.withClient(
        MockClient((_) async => http.Response('unavailable', 503)));
    final result = await service
        .scheduleDay([sportsLeagueById('nba')!], DateTime(2026, 11, 10));
    expect(result.incomplete, isTrue);
    expect(service.lastError, isNull);
  });
  test('empty day replies do not publish redundant list updates', () async {
    var published = 0;
    final service = SportsService.withClient(MockClient((_) async {
      await Future<void>.delayed(const Duration(milliseconds: 450));
      return http.Response('{"events":[]}', 200);
    }));
    await service.scheduleDay(
        [sportsLeagueById('nba')!], DateTime(2026, 11, 10),
        onProgress: (_) => published++);
    expect(published, 0);
  });
}
