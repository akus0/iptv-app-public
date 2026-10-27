import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nox_iptv/models/sports.dart';
import 'package:nox_iptv/models/sports_progress.dart';
import 'package:nox_iptv/services/sports_service.dart';

final day = DateTime(2026, 10, 27, 12);
final leagues = [sportsLeagueById('nfl')!, sportsLeagueById('nhl')!];
String eventBody() => jsonEncode({
      'events': [
        {
          'id': 'saved',
          'date': day.toUtc().toIso8601String(),
          'competitions': [
            {
              'status': {
                'type': {'state': 'in'}
              },
              'competitors': [
                {
                  'homeAway': 'home',
                  'team': {'id': 'a', 'displayName': 'Home'}
                },
                {
                  'homeAway': 'away',
                  'team': {'id': 'b', 'displayName': 'Away'}
                },
              ]
            }
          ]
        }
      ]
    });

class _StalledClient extends http.BaseClient {
  int active = 0, peak = 0, aborted = 0;
  bool stalled = true;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (!stalled) {
      return http.StreamedResponse(
          Stream.value(utf8.encode('{"events":[]}')), 200);
    }
    active++;
    if (active > peak) peak = active;
    final abort = request as http.Abortable;
    await abort.abortTrigger;
    active--;
    aborted++;
    throw http.RequestAbortedException(request.url);
  }
}

void main() {
  test('HTTP-date retry window blocks forced refresh until it expires',
      () async {
    var now = DateTime.utc(2026, 10, 27, 12);
    var calls = 0;
    var limited = true;
    final service = SportsService.withClient(MockClient((_) async {
      calls++;
      return limited
          ? http.Response('Rate limited', 429,
              headers: {'retry-after': 'Tue, 27 Oct 2026 12:02:00 GMT'})
          : http.Response('{"events":[]}', 200);
    }), clock: () => now);
    await service.gamesForDay([leagues.first], day);
    final before = calls;
    now = now.add(const Duration(minutes: 1));
    limited = false;
    await service.gamesForDay([leagues.first], day, forceRefresh: true);
    expect(calls, before);
    expect(service.issuesForDay([leagues.first], day).first.responseBody,
        'Rate limited');
    now = now.add(const Duration(minutes: 1, seconds: 1));
    await service.gamesForDay([leagues.first], day);
    expect(service.lastError, isNull);
  });

  test('timeouts abort transport, drain offline queues, then recover',
      () async {
    final client = _StalledClient();
    final service = SportsService.withClient(client,
        requestTimeout: const Duration(milliseconds: 25));
    final many = kSportsLeagues.take(12).toList();
    await service.gamesForDay(many, day);
    await Future<void>.delayed(Duration.zero);
    expect(client.peak, lessThanOrEqualTo(6));
    expect(client.active, 0);
    expect(client.aborted, inInclusiveRange(6, 11));
    expect(service.lastError, contains('timeout'));
    client.stalled = false;
    await service.gamesForDay(many, day, forceRefresh: true);
    expect(service.lastError, isNull);
  });

  test(
      'diagnostics retain bounded response evidence and stay scoped to each route',
      () async {
    var bad = true;
    var requests = 0;
    final service = SportsService.withClient(MockClient((r) async {
      requests++;
      return bad && r.url.path.contains('/nfl/')
          ? http.Response(
              'Access denied: ${List.filled(5000, 'x').join()}', 403,
              headers: {'content-type': 'text/plain'})
          : http.Response('{"events":[]}', 200);
    }), clock: () => day);
    await service.gamesForDay([leagues.first], day);
    await service.gamesForDay([leagues.last], day);
    expect(service.lastError, isNull);
    expect(service.errorForDay([leagues.first], day), contains('HTTP 403'));
    expect(service.errorForDay([leagues.last], day), isNull);
    final calls = requests;
    final issues = service.issuesForDay(leagues, day);
    expect(issues, hasLength(3));
    expect(issues.first.statusCode, 403);
    expect(issues.first.contentType, startsWith('text/plain'));
    expect(issues.first.responseBody, startsWith('Access denied:'));
    expect(issues.first.responseBody!.length, lessThan(2100));
    expect(issues.first.endpoint, contains('/football/nfl/scoreboard?dates='));
    expect(requests, calls);
    bad = false;
    await service.gamesForDay([leagues.first], day, forceRefresh: true);
    expect(service.issuesForDay(leagues, day), isEmpty);
  });

  test('partial failures report progress before slow healthy feeds finish',
      () async {
    final gate = Completer<void>();
    final progressed = Completer<void>();
    final service = SportsService.withClient(MockClient((r) async {
      if (r.url.path.contains('/nfl/')) return http.Response('denied', 403);
      await gate.future;
      return http.Response(eventBody(), 200);
    }), clock: () => day);
    final statuses = <SportsWorkProgress>[];
    final pending = service.gamesForDay(leagues, day, onStatus: (s) {
      statuses.add(s);
      if (s.failed == 3 && !progressed.isCompleted) progressed.complete();
    });
    await progressed.future.timeout(const Duration(seconds: 2));
    expect(statuses.last.completed, 3);
    gate.complete();
    expect(await pending, hasLength(1));
    expect(statuses.last.completed, 6);
    expect(statuses.length, lessThan(5));
  });

  test(
      'failed feeds cool down across repeated visits while healthy feeds refresh',
      () async {
    var now = day;
    var fail = false;
    var badCalls = 0, goodCalls = 0;
    final service = SportsService.withClient(MockClient((r) async {
      final bad = r.url.path.contains('/nfl/');
      if (bad) {
        badCalls++;
      } else {
        goodCalls++;
      }
      return http.Response(
          fail && bad ? 'denied' : eventBody(), fail && bad ? 403 : 200);
    }), clock: () => now);
    final original = await service.gamesForDay(leagues, day);
    expect(original, hasLength(2));
    fail = true;
    now = now.add(const Duration(minutes: 1));
    expect(await service.gamesForDay(leagues, day), hasLength(2));
    final failedCalls = badCalls;
    for (var i = 0; i < 100; i++) {
      expect(await service.gamesForDay(leagues, day), hasLength(2));
    }
    expect(badCalls, failedCalls,
        reason: 'Reopening Sports must not hammer failed feeds');
    now = now.add(const Duration(seconds: 31));
    await service.gamesForDay(
        leagues, day); // second failure -> longer cooldown
    final secondFailure = badCalls;
    now = now.add(const Duration(seconds: 21));
    await service.gamesForDay(leagues, day);
    expect(badCalls, secondFailure);
    expect(goodCalls, 9,
        reason: 'Healthy live scores still refresh independently');
    fail = false;
    await service.gamesForDay(leagues, day, forceRefresh: true);
    expect(service.lastError, isNull);
  });

  for (final body in [
    '{}',
    '{"error":"unavailable"}',
    '[]',
    '{"events":null}'
  ]) {
    test('invalid success envelope retains saved games: $body', () async {
      var response = eventBody();
      final service = SportsService.withClient(
          MockClient((_) async => http.Response(response, 200)),
          clock: () => day);
      final saved = await service.gamesForDay([leagues.first], day);
      response = body;
      final after =
          await service.gamesForDay([leagues.first], day, forceRefresh: true);
      expect(after.single, same(saved.single));
      expect(service.lastError, isNotNull);
      response = '{"events":[]}';
      expect(
          await service.gamesForDay([leagues.first], day, forceRefresh: true),
          isEmpty,
          reason:
              'A genuinely empty successful response must clear old fixtures');
      expect(service.lastError, isNull);
    });
  }

  test(
      'rate limit stops queued downloads and respects Retry-After even on refresh',
      () async {
    var now = day;
    var limited = true;
    var calls = 0;
    final service = SportsService.withClient(MockClient((_) async {
      calls++;
      return limited
          ? http.Response('Slow down', 429, headers: {'retry-after': '120'})
          : http.Response('{"events":[]}', 200);
    }), clock: () => now);
    final many = kSportsLeagues.take(12).toList();
    final statuses = <SportsWorkProgress>[];
    await service.gamesForDay(many, day, onStatus: statuses.add);
    expect(calls, lessThanOrEqualTo(6));
    final initial = calls;
    expect(statuses.last.completed, statuses.last.total);
    expect(statuses.last.failed, statuses.last.total);
    limited = false;
    now = now.add(const Duration(seconds: 30));
    await service.gamesForDay(many, day, forceRefresh: true);
    expect(calls, initial);
    expect(
        service
            .issuesForDay(many, day)
            .where((issue) => issue.statusCode == 429)
            .first
            .responseBody,
        'Slow down');
    now = now.add(const Duration(seconds: 91));
    await service.gamesForDay(many, day);
    expect(calls, greaterThan(initial));
    expect(service.lastError, isNull);
  });
}
