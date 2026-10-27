import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nox_iptv/models/sports.dart';
import 'package:nox_iptv/services/league_broadcast_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final start = DateTime.utc(2026, 10, 23, 0, 30);
  SportsGame game(
          {String home = 'Boston Bruins',
          String away = 'Nashville Predators',
          DateTime? at,
          String league = 'nhl'}) =>
      SportsGame(
          id: 'primary',
          league: sportsLeagueById(league)!,
          start: at ?? start,
          state: GameState.live,
          statusText: 'Live',
          home: SportsTeam(
              id: '1', name: home, shortName: home, abbreviation: 'BOS'),
          away: SportsTeam(
              id: '2', name: away, shortName: away, abbreviation: 'NSH'));
  Map<String, Object?> row(
          {int id = 2026020154,
          String state = 'LIVE',
          String scheduled = 'OK',
          String country = 'US'}) =>
      {
        'id': id,
        'startTimeUTC': start.toIso8601String(),
        'gameState': state,
        'gameScheduleState': scheduled,
        'homeTeam': {
          'placeName': {'default': 'Boston'},
          'commonName': {'default': 'Bruins'}
        },
        'awayTeam': {
          'placeName': {'default': 'Nashville'},
          'commonName': {'default': 'Predators'}
        },
        'tvBroadcasts': [
          {'network': 'NESN', 'countryCode': country},
          {'network': 'NESN', 'countryCode': country}
        ],
      };
  String payload(List<Map<String, Object?>> rows) => jsonEncode({
        'gameWeek': [
          {'games': rows}
        ]
      });

  const saved = String.fromEnvironment('NHL_SCHEDULE_FILE');
  test(
      'actual public NHL response parses with no stream or additional network access',
      () async {
    final rows =
        parseLeagueBroadcasts(('nhl', await File(saved).readAsString()));
    expect(rows, isNotEmpty);
    final boston = rows.firstWhere(
        (r) => r.home == 'Boston Bruins' && r.away == 'Nashville Predators');
    expect(
        boston.broadcasts
            .any((b) => b.name == 'NESN' && b.country == 'United States'),
        true);
    expect(boston.matches(game(at: boston.start)), true);
    // ignore: avoid_print
    print(
        'Official saved NHL feed: ${rows.length} scheduled fixtures with TV listings.');
  }, skip: saved.isEmpty ? 'Optional saved public NHL schedule' : false);
  test(
      'league schedule shares one request across fixtures and never changes scores',
      () async {
    final requests = <Uri>[];
    final service = LeagueBroadcastService(MockClient((r) async {
      requests.add(r.url);
      return http.Response(payload([row()]), 200);
    }), spacing: Duration.zero);
    final result = await Future.wait(
        [service.broadcastsFor(game()), service.broadcastsFor(game())]);
    expect(requests, hasLength(1));
    expect(requests.single.toString(),
        'https://api-web.nhle.com/v1/schedule/2026-10-22');
    expect(result.first.single.name, 'NESN');
    expect(result.first.single.source, 'NHL');
    expect(result.first.single.country, 'United States');
    expect(service.cachedFor(game()), hasLength(1));
    expect(await service.broadcastsFor(game(home: 'Boston')), isEmpty);
    expect(
        await service.broadcastsFor(game(away: 'New York Rangers')), isEmpty);
    expect(
        await service
            .broadcastsFor(game(at: start.add(const Duration(hours: 2)))),
        isEmpty);
    expect(await service.broadcastsFor(game(league: 'nba')), isEmpty);
    expect(requests, hasLength(1));
  });
  test(
      'ambiguous, postponed, finished and regionless schedules are not evidence',
      () async {
    for (final rows in [
      [row(), row(id: 2026020155)],
      [row(state: 'OFF')],
      [row(scheduled: 'PPD')],
      [row(country: '')],
    ]) {
      final service = LeagueBroadcastService(
          MockClient((_) async => http.Response(payload(rows), 200)),
          spacing: Duration.zero);
      expect(await service.broadcastsFor(game()), isEmpty);
    }
    expect(
        parseLeagueBroadcasts(('nhl', payload([row(), row()]))), hasLength(1));
  });
  test('background work is bounded to four requests per ten minutes', () async {
    var now = start, calls = 0;
    final service = LeagueBroadcastService(MockClient((_) async {
      calls++;
      return http.Response(payload([row()]), 200);
    }), spacing: Duration.zero, clock: () => now);
    for (var i = 0; i < 8; i++) {
      await service.broadcastsFor(game(at: start.add(Duration(days: i))));
    }
    expect(calls, 4);
    now = now.add(const Duration(minutes: 11));
    await service.broadcastsFor(game(at: start.add(const Duration(days: 7))));
    expect(calls, 5);
  });
  test('cancellation skips queued requests without poisoning their cache',
      () async {
    final gate = Completer<http.Response>();
    var calls = 0, cancelled = false;
    final service = LeagueBroadcastService(MockClient((_) async {
      calls++;
      if (calls == 1) return await gate.future;
      return http.Response(payload([row()]), 200);
    }), spacing: Duration.zero);
    final first = service.broadcastsFor(game());
    await Future<void>.delayed(Duration.zero);
    final secondGame = game(at: start.add(const Duration(days: 1)));
    final second =
        service.broadcastsFor(secondGame, cancelled: () => cancelled);
    cancelled = true;
    gate.complete(http.Response(payload([row()]), 200));
    await first;
    expect(await second, isEmpty);
    expect(calls, 1);
    await service.broadcastsFor(secondGame);
    expect(calls, 2);
  });
  test('failures are cached and rate limits stop different-day requests too',
      () async {
    var now = start, calls = 0;
    final service = LeagueBroadcastService(MockClient((_) async {
      calls++;
      return http.Response('', 429);
    }), spacing: Duration.zero, clock: () => now);
    expect(await service.broadcastsFor(game()), isEmpty);
    expect(await service.broadcastsFor(game()), isEmpty);
    expect(
        await service
            .broadcastsFor(game(at: start.add(const Duration(days: 1)))),
        isEmpty);
    expect(calls, 1);
    now = now.add(const Duration(minutes: 31));
    await service.broadcastsFor(game());
    expect(calls, 2);
  });
  test('expired broadcasts are refreshed and malformed responses fail quietly',
      () async {
    var now = start, calls = 0;
    final service = LeagueBroadcastService(MockClient((_) async {
      calls++;
      return http.Response(calls == 1 ? payload([row()]) : '{broken', 200);
    }), spacing: Duration.zero, clock: () => now);
    expect(await service.broadcastsFor(game()), hasLength(1));
    now = now.add(const Duration(minutes: 31));
    expect(service.cachedFor(game()), isEmpty);
    expect(await service.broadcastsFor(game()), isEmpty);
    expect(calls, 2);
  });
}
