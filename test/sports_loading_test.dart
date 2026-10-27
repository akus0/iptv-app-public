import 'dart:async';
import 'dart:math';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nox_iptv/models/sports.dart';
import 'package:nox_iptv/models/sports_progress.dart';
import 'package:nox_iptv/services/sports_service.dart';

void main() {
  test('healthy queued leagues survive a slow all-league load', () async {
    var requests = 0;
    final service = SportsService.withClient(MockClient((_) async {
      final batch = requests++ ~/ 6;
      if (batch < 2) {
        await Future<void>.delayed(const Duration(seconds: 13));
      }
      return http.Response('{"events":[]}', 200);
    }));
    final leagues = kSportsLeagues.take(6).toList();
    await service.gamesForDay(leagues, DateTime(2026, 10, 26));
    expect(requests, 18);
    expect(service.lastError, isNull);
  }, timeout: const Timeout(Duration(seconds: 40)));

  test('offline all-league load drains without hundreds of retries', () async {
    var requests = 0;
    var offline = true;
    final service = SportsService.withClient(MockClient((_) async {
      requests++;
      if (offline) throw http.ClientException('offline');
      return http.Response('{"events":[]}', 200);
    }));
    final leagues = kSportsLeagues.take(12).toList();
    await service.gamesForDay(leagues, DateTime(2026, 10, 26));
    expect(requests, lessThanOrEqualTo(11));
    expect(service.lastError, isNotNull);
    final failedRequests = requests;
    offline = false;
    await service.gamesForDay(leagues, DateTime(2026, 10, 26),
        forceRefresh: true);
    expect(requests - failedRequests, leagues.length * 3);
    expect(service.lastError, isNull);
  });

  test('warm visits stay cached, live expiry and forced refresh still fetch',
      () async {
    var now = DateTime(2026, 10, 26, 12);
    final day = now;
    var requests = 0;
    Completer<void>? gate;
    final service = SportsService.withClient(MockClient((request) async {
      requests++;
      if (gate != null) await gate.future;
      return http.Response(
          jsonEncode({
            'events': [
              {
                'id': 'live',
                'date': day.toUtc().toIso8601String(),
                'status': {
                  'type': {'state': 'in'}
                },
                'competitions': [
                  {
                    'status': {
                      'type': {'state': 'in'}
                    },
                    'competitors': [
                      {
                        'homeAway': 'home',
                        'team': {'id': 'h', 'displayName': 'Home'}
                      },
                      {
                        'homeAway': 'away',
                        'team': {'id': 'a', 'displayName': 'Away'}
                      }
                    ]
                  }
                ]
              }
            ]
          }),
          200);
    }), clock: () => now);
    final leagues = [kSportsLeagues.first];
    final cold = await service.gamesForDay(leagues, day);
    expect(cold.single.state, GameState.live);
    expect(requests, 3);
    final statuses = <SportsWorkProgress>[];
    expect(
        (await service.gamesForDay(leagues, day, onStatus: statuses.add))
            .single,
        same(cold.single));
    expect(statuses, isEmpty);
    expect(requests, 3);
    now = now.add(const Duration(seconds: 51));
    await service.gamesForDay(leagues, day);
    expect(requests, 6);
    gate = Completer<void>();
    final forced = service.gamesForDay(leagues, day, forceRefresh: true);
    var warmFinished = false;
    final warm = service.gamesForDay(leagues, day).then((value) {
      warmFinished = true;
      return value;
    });
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(warmFinished, false,
        reason:
            'A new route joins an active refresh instead of returning old scores');
    expect(requests, 9);
    gate.complete();
    await Future.wait([forced, warm]);
    expect(requests, 9);
  });

  test(
      'score progress advances for empty and failed feeds without more requests',
      () async {
    var requests = 0;
    final slow = Completer<void>();
    final service = SportsService.withClient(MockClient((request) async {
      requests++;
      if (request.url.path.contains('/nfl/')) await slow.future;
      return http.Response(
          request.url.path.contains('/nhl/') ? '{broken' : '{"events":[]}',
          200);
    }));
    final updates = <SportsWorkProgress>[];
    final eventUpdates = <List<SportsGame>>[];
    final partial = Completer<void>();
    final leagues = kSportsLeagues.take(2).toList();
    final loading = service.gamesForDay(leagues, DateTime(2026, 10, 21),
        onProgress: eventUpdates.add, onStatus: (status) {
      updates.add(status);
      if (status.completed == 3 && !partial.isCompleted) partial.complete();
    });
    await partial.future.timeout(const Duration(seconds: 5));
    expect(updates.last.completed, 3);
    expect(updates.last.failed, 3);
    expect(updates.last.total, 6);
    slow.complete();
    expect(await loading, isEmpty);
    expect(updates.last.completed, 6);
    expect(updates.last.failed, 3);
    expect(requests, 6);
    expect(updates.length, lessThanOrEqualTo(4));
    expect(eventUpdates, isEmpty);
  });
  test('batched parsers isolate malformed replies and keep successful scores',
      () async {
    final service = SportsService.withClient(MockClient((request) async =>
        http.Response(
            request.url.path.contains('/nhl/') ? '{broken' : '{"events":[]}',
            200)));
    final leagues = kSportsLeagues.take(2).toList();
    await service.gamesForDay(leagues, DateTime(2026, 10, 21));
    expect(service.lastError, isNotNull);
    await service.gamesForDay([leagues.last], DateTime(2026, 10, 21));
    expect(service.lastError, isNull);
  });

  test(
      'manual refresh bypasses fresh cache, coalesces callers and retains scores on failure',
      () async {
    var requests = 0;
    var fail = false;
    Completer<void>? gate;
    final day = DateTime(2026, 10, 21);
    final service = SportsService.withClient(MockClient((request) async {
      requests++;
      if (gate != null) await gate.future;
      if (fail) return http.Response('offline', 503);
      return http.Response(
          jsonEncode({
            'events': [
              {
                'id': 'game',
                'date': day
                    .add(const Duration(hours: 12))
                    .toUtc()
                    .toIso8601String(),
                'competitions': [
                  {
                    'competitors': [
                      {
                        'homeAway': 'home',
                        'team': {'id': 'h', 'displayName': 'Home'}
                      },
                      {
                        'homeAway': 'away',
                        'team': {'id': 'a', 'displayName': 'Away'}
                      },
                    ]
                  }
                ],
              }
            ]
          }),
          200);
    }));
    final leagues = [kSportsLeagues.first];
    expect(await service.gamesForDay(leagues, day), hasLength(1));
    expect(requests, 3);
    await service.gamesForDay(leagues, day);
    expect(requests, 3);
    gate = Completer<void>();
    final first = service.gamesForDay(leagues, day, forceRefresh: true);
    final second = service.gamesForDay(leagues, day, forceRefresh: true);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(requests, 6);
    expect(service.cachedGamesForDay(leagues, day), hasLength(1));
    gate.complete();
    await Future.wait([first, second]);
    gate = null;
    fail = true;
    expect(await service.gamesForDay(leagues, day, forceRefresh: true),
        hasLength(1));
    expect(requests, 9);
    expect(service.lastError, isNotNull);
  });

  test(
      'fast leagues appear before a slow league and reopening reads the cache immediately',
      () async {
    final delayed = Completer<void>();
    final progressed = Completer<List<SportsGame>>();
    final day = DateTime(2026, 10, 21);
    final service = SportsService.withClient(MockClient((request) async {
      if (request.url.path.contains('/nfl/')) await delayed.future;
      return http.Response(
          jsonEncode({
            'events': [
              {
                'id': 'one',
                'date': day
                    .add(const Duration(hours: 12))
                    .toUtc()
                    .toIso8601String(),
                'competitions': [
                  {
                    'competitors': [
                      {
                        'homeAway': 'home',
                        'team': {'id': 'h', 'displayName': 'Home'}
                      },
                      {
                        'homeAway': 'away',
                        'team': {'id': 'a', 'displayName': 'Away'}
                      },
                    ]
                  }
                ],
              }
            ]
          }),
          200);
    }));
    final leagues = kSportsLeagues.take(2).toList();
    var completed = false;
    final loading = service.gamesForDay(leagues, day, onProgress: (games) {
      if (games.isNotEmpty && !progressed.isCompleted) {
        progressed.complete(games);
      }
    }).then((games) {
      completed = true;
      return games;
    });
    final first = await progressed.future.timeout(const Duration(seconds: 3));
    expect(completed, false);
    expect(first.map((g) => g.league.id).toSet(), {'nhl'});
    expect(service.cachedGamesForDay(leagues, day).length, 1);
    expect(service.cachedGamesForDay(leagues, day.add(const Duration(days: 2))),
        isEmpty);
    delayed.complete();
    expect((await loading).length, 2);
  });
  test('all leagues limit network concurrency and coalesce duplicate loads',
      () async {
    var active = 0, peak = 0, requests = 0;
    final service = SportsService.withClient(MockClient((request) async {
      requests++;
      active++;
      peak = max(peak, active);
      await Future<void>.delayed(const Duration(milliseconds: 2));
      active--;
      return http.Response('{"events":[]}', 200);
    }));
    final leagues = [...kSportsLeagues, ...kSportsLeagueBank];
    final date = DateTime(2026, 10, 21);
    await Future.wait([
      service.gamesForDay(leagues, date),
      service.gamesForDay(leagues, date)
    ]);
    expect(peak, lessThanOrEqualTo(6));
    expect(
        requests,
        leagues
                .where((l) =>
                    l.source == 'ESPN' &&
                    (!l.espnPath.startsWith('rugby/') || l.id == 'rugby.live'))
                .length *
            3);
    expect(service.lastError, isNull);
    await service.gamesForDay(leagues, date);
    expect(
        requests,
        leagues
                .where((l) =>
                    l.source == 'ESPN' &&
                    (!l.espnPath.startsWith('rugby/') || l.id == 'rugby.live'))
                .length *
            3);
  });
  test(
      'partial failure remains reported even if a successful request finishes last',
      () async {
    var fail = true;
    final service = SportsService.withClient(MockClient((request) async {
      if (fail && request.url.queryParameters['dates'] == '20261020') {
        return http.Response('unavailable', 503);
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
      return http.Response('{"events":[]}', 200);
    }));
    await service.gamesForDay([kSportsLeagues.first], DateTime(2026, 10, 21));
    expect(service.lastError, isNotNull);
    fail = false;
    await service.gamesForDay([kSportsLeagues.first], DateTime(2026, 10, 21),
        forceRefresh: true);
    expect(service.lastError, isNull);
  });
  test('failed requests release every slot for subsequent loads', () async {
    var fail = true;
    final service = SportsService.withClient(MockClient((request) async {
      if (fail) throw http.ClientException('offline');
      return http.Response('{"events":[]}', 200);
    }));
    final leagues = kSportsLeagues.take(5).toList();
    await service.gamesForDay(leagues, DateTime(2026, 10, 21));
    expect(service.lastError, isNotNull);
    fail = false;
    await service.gamesForDay(leagues, DateTime(2026, 10, 21),
        forceRefresh: true);
    expect(service.lastError, isNull);
  });
}
