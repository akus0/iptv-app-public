import 'package:flutter_test/flutter_test.dart';
import 'package:nox_iptv/models/sports.dart';
import 'package:nox_iptv/services/sports_match_batch_plan.dart';

void main() {
  final now = DateTime.utc(2026, 10, 30, 12);
  SportsGame game(String id,
          {int hour = 8, bool live = false, String league = 'eng.1'}) =>
      SportsGame(
          id: id,
          league: sportsLeagueById(league)!,
          start: now.add(Duration(hours: hour)),
          state: live ? GameState.live : GameState.pre,
          statusText: '',
          home: const SportsTeam(
              id: 'a', name: 'Arsenal', shortName: 'Arsenal', abbreviation: ''),
          away: const SportsTeam(
              id: 'b',
              name: 'Chelsea',
              shortName: 'Chelsea',
              abbreviation: ''));
  Map<String, String> ids(List<SportsGame> games) => {
        for (final g in games)
          '${g.league.id}:${g.id}': '${g.id}:${g.start}:${g.state}'
      };

  test('all live/soon owners stay together even beyond the later batch limit',
      () {
    final plan = SportsMatchBatchPlan(maxLaterEvents: 3);
    final ready = [for (var i = 0; i < 60; i++) game('live$i', live: true)];
    final games = [...ready, game('later')];
    final expected = ids(games);
    expect(plan.next(games, expected, now).map((g) => g.id).toSet(),
        ready.map((g) => g.id).toSet());
    plan.complete(ready, expected);
    expect(plan.next(games, expected, now).map((g) => g.id), ['later']);
  });

  test('a newly arriving live fixture overtakes remaining later batches', () {
    final plan = SportsMatchBatchPlan(maxLaterEvents: 2);
    var games = [
      game('live', live: true),
      for (var i = 0; i < 7; i++) game('later$i')
    ];
    var expected = ids(games);
    plan.complete(plan.next(games, expected, now), expected);
    final firstLater = plan.next(games, expected, now);
    expect(firstLater, hasLength(2));
    games = [...games, game('new-live', live: true)];
    final previous = expected;
    expected = ids(games);
    plan.complete(firstLater, previous);
    final urgent = plan.next(games, expected, now);
    expect(urgent.map((g) => g.id).toSet(), {'live', 'new-live'});
    plan.complete(urgent, expected);
    expect(
        plan.next(games, expected, now).map((g) => g.id), ['later2', 'later3']);
  });

  test('changed evidence and removed competing owners require a fresh check',
      () {
    final plan = SportsMatchBatchPlan();
    final first = [game('a', live: true), game('b', live: true)];
    final original = ids(first);
    final batch = plan.next(first, original, now);
    final corrected = {...original, 'eng.1:a': 'corrected evidence'};
    plan.complete(batch, original);
    expect(plan.next(first, corrected, now), first);
    plan.complete(first, corrected);
    final remaining = [first.first];
    expect(plan.next(remaining, {'eng.1:a': 'corrected evidence'}, now),
        remaining);
  });

  test('later queries have bounded count and time span and eventually finish',
      () {
    final plan = SportsMatchBatchPlan(
        maxLaterEvents: 4, maxLaterSpan: const Duration(hours: 3));
    final games = [for (var i = 0; i < 20; i++) game('$i', hour: 8 + i)];
    final expected = ids(games), seen = <String>{};
    while (true) {
      final batch = plan.next(games, expected, now);
      if (batch.isEmpty) break;
      expect(batch.length, lessThanOrEqualTo(4));
      expect(batch.last.start.difference(batch.first.start),
          lessThanOrEqualTo(const Duration(hours: 3)));
      for (final g in batch) {
        expect(seen.add(g.id), isTrue);
      }
      plan.complete(batch, expected);
    }
    expect(seen.length, games.length);
  });

  test(
      'a previously checked upcoming fixture joins the live cohort at its boundary',
      () {
    final plan = SportsMatchBatchPlan();
    final games = [game('live', live: true), game('soon', hour: 1)];
    final expected = ids(games);
    plan.complete(plan.next(games, expected, now), expected);
    plan.complete(plan.next(games, expected, now), expected);
    expect(plan.next(games, expected, now), isEmpty);
    expect(
        plan
            .next(games, expected, now.add(const Duration(minutes: 16)))
            .map((g) => g.id)
            .toSet(),
        games.map((g) => g.id).toSet());
  });
}
