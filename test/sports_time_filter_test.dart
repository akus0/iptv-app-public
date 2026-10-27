import 'package:flutter_test/flutter_test.dart';
import 'package:nox_iptv/models/sports.dart';
import 'package:nox_iptv/utils/sports_time_filter.dart';

void main() {
  final now = DateTime.utc(2026, 10, 24, 12);
  SportsGame game(int minutes, GameState state) => SportsGame(
      id: '$minutes',
      league: kSportsLeagues.first,
      start: now.add(Duration(minutes: minutes)),
      state: state,
      statusText: '',
      home: const SportsTeam(
          id: 'a', name: 'A', shortName: 'A', abbreviation: 'A'),
      away: const SportsTeam(
          id: 'b', name: 'B', shortName: 'B', abbreviation: 'B'));
  test('soon window includes warmup times and a bounded late-start grace', () {
    for (final minutes in [-15, 0, 15, 45]) {
      expect(SportsTimeFilter.soon.accepts(game(minutes, GameState.pre), now),
          true);
    }
    for (final minutes in [-16, -240, 46, 1440]) {
      expect(SportsTimeFilter.soon.accepts(game(minutes, GameState.pre), now),
          false);
    }
  });
  test('soon never admits finished events or relabels scheduled events live',
      () {
    expect(SportsTimeFilter.soon.accepts(game(0, GameState.post), now), false);
    expect(SportsTimeFilter.live.accepts(game(0, GameState.pre), now), false);
    expect(SportsTimeFilter.soon.accepts(game(0, GameState.live), now), false);
  });
  test('combined mode includes live regardless of elapsed time', () {
    expect(
        SportsTimeFilter.liveAndSoon.accepts(game(-180, GameState.live), now),
        true);
    expect(SportsTimeFilter.liveAndSoon.accepts(game(30, GameState.pre), now),
        true);
    expect(SportsTimeFilter.liveAndSoon.accepts(game(60, GameState.pre), now),
        false);
  });
  test('time advances into the window, across midnight and UTC offsets', () {
    final event = game(46, GameState.pre);
    expect(SportsTimeFilter.soon.accepts(event, now), false);
    expect(
        SportsTimeFilter.soon
            .accepts(event, now.add(const Duration(minutes: 1))),
        true);
    final sameInstant = DateTime.parse('2026-10-25T00:00:00+12:00');
    expect(SportsTimeFilter.soon.accepts(game(20, GameState.pre), sameInstant),
        true);
  });
  test('all events retains the selected day independently of time window', () {
    for (final state in GameState.values) {
      expect(SportsTimeFilter.all.accepts(game(1440, state), now), true);
    }
  });
}
