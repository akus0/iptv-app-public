import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nox_iptv/models/sports.dart';
import 'package:nox_iptv/services/sports_service.dart';
import 'sports_schedule_test.dart' as fixtures;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('All uses the same results and warm cache as the normal score path',
      () async {
    final day = DateTime(2026, 11, 3, 12);
    final leagues =
        ['nhl', 'nba', 'eng.1'].map((id) => sportsLeagueById(id)!).toList();
    var allRequests = 0;
    http.Response response(http.Request request) => http.Response(
        jsonEncode({
          'events': [fixtures.event(request.url.path, day)],
        }),
        200);
    final normal = SportsService.withClient(
        MockClient((r) async => response(r)),
        clock: () => day);
    final all = SportsService.withClient(MockClient((r) async {
      allRequests++;
      return response(r);
    }), clock: () => day);
    final expected = await normal.gamesForDay(leagues, day);
    final actual = await all.gamesForDayWhileActive(leagues, day,
        shouldContinue: () => true);
    List<String> keys(List<SportsGame> games) => games
        .map((g) =>
            '${g.league.id}:${g.id}:${g.state}:${g.start.toIso8601String()}')
        .toList()
      ..sort();
    expect(actual, isNotEmpty);
    expect(keys(actual), keys(expected));
    final requests = allRequests;
    expect(
        keys(await all.gamesForDayWhileActive(leagues, day,
            shouldContinue: () => true)),
        keys(expected));
    expect(allRequests, requests,
        reason: 'Returning to a warm All view adds no HTTP requests.');
  });

  test('cancelled browsing keeps completed feeds and resumes full coverage',
      () async {
    final day = DateTime(2026, 11, 3, 12);
    final leagues =
        sportsBrowseLeagues.where((l) => l.source == 'ESPN').take(16).toList();
    final pending = <(http.Request, Completer<http.Response>)>[];
    final requests = <String, int>{};
    var hold = true, active = true;
    http.Response response(http.Request r) => http.Response(
        jsonEncode({
          'events': [fixtures.event(r.url.toString(), day)]
        }),
        200);
    final service = SportsService.withClient(MockClient((r) {
      requests.update(r.url.toString(), (count) => count + 1,
          ifAbsent: () => 1);
      if (!hold) return Future.value(response(r));
      final gate = Completer<http.Response>();
      pending.add((r, gate));
      return gate.future;
    }), clock: () => day);
    final first = service.gamesForDayWhileActive(leagues, day,
        shouldContinue: () => active);
    for (var i = 0; i < 100 && pending.length < 6; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(pending, hasLength(6));
    active = false;
    hold = false;
    for (final (request, gate) in pending) {
      gate.complete(response(request));
    }
    await first;
    expect(requests, hasLength(6));
    final resumed = await service.gamesForDayWhileActive(leagues, day,
        shouldContinue: () => true);
    final reference = SportsService.withClient(
        MockClient((r) async => response(r)),
        clock: () => day);
    final complete = await reference.gamesForDay(leagues, day);
    Set<String> identities(List<SportsGame> games) =>
        games.map((g) => '${g.league.id}:${g.id}').toSet();
    expect(identities(resumed), identities(complete));
    expect(resumed, isNotEmpty);
    expect(requests.length, greaterThan(6));
    expect(requests.values.every((count) => count == 1), isTrue,
        reason: 'Completed in-flight responses remain reusable after leaving.');
  });

  test('leaving All stops the queue after at most six active requests',
      () async {
    final pending = <Completer<http.Response>>[];
    var active = true, progress = 0, statuses = 0;
    final day = DateTime(2026, 11, 3, 12);
    final leagues =
        sportsBrowseLeagues.where((l) => l.source == 'ESPN').take(16).toList();
    final service = SportsService.withClient(MockClient((request) {
      final gate = Completer<http.Response>();
      pending.add(gate);
      return gate.future;
    }), clock: () => day);
    final work = service.gamesForDayWhileActive(leagues, day,
        shouldContinue: () => active,
        onProgress: (_) => progress++,
        onStatus: (_) => statuses++);
    for (var i = 0; i < 100 && pending.length < 6; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(pending, hasLength(6));
    active = false;
    final statusesAtExit = statuses;
    for (final gate in pending) {
      gate.complete(http.Response('{"events":[]}', 200));
    }
    await work;
    expect(pending, hasLength(6),
        reason: 'No remaining catalogue requests are queued.');
    expect(progress, 0);
    expect(statuses, statusesAtExit,
        reason: 'Hidden views receive no late progress updates.');
  });
}
