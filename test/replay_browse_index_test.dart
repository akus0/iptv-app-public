import 'package:flutter_test/flutter_test.dart';
import 'package:nox_iptv/models/channel.dart';
import 'package:nox_iptv/models/epg_program.dart';
import 'package:nox_iptv/services/sports_replay_service.dart';
import 'package:nox_iptv/utils/replay_browse_index.dart';

SportsReplay event(String id, String sport, DateTime start, DateTime stop) =>
    SportsReplay(sport: sport, title: id, broadcasts: [
      ReplayBroadcast(
          Channel(
              id: id,
              rawId: id,
              playlistId: 'test',
              name: id,
              group: sport,
              url: 'https://example.invalid/never-play'),
          EpgProgram(channelId: id, title: id, start: start, stop: stop))
    ]);

void main() {
  test(
      'progress updates reuse ordering; real filters and programme boundaries refresh it',
      () {
    final now = DateTime(2026, 10, 24, 12);
    final boundary = now.add(const Duration(minutes: 5));
    final events = [
      event('b', 'tennis', now, boundary),
      event('a', 'golf', now, now.add(const Duration(hours: 1))),
      event('c', 'tennis', boundary, now.add(const Duration(hours: 1))),
    ];
    final cache = ReplayBrowseIndex();
    var checks = 0, comparisons = 0;
    ReplayBrowseView view(DateTime at, {String sport = ''}) => cache.resolve(
        events: events,
        configuration: sport,
        now: at,
        matches: (event, _) {
          checks++;
          return sport.isEmpty || event.sport == sport;
        },
        compare: (a, b) {
          comparisons++;
          return a.sport.compareTo(b.sport);
        });
    final first = view(now);
    expect(first.events.map((e) => e.title), ['a', 'b']);
    expect(first.ranges, [(0, 1), (1, 2)]);
    expect(first.positions[first.events[1].id], 1);
    final sorting = comparisons;
    for (var i = 0; i < 100; i++) {
      expect(identical(view(now.add(Duration(seconds: i))), first), isTrue);
    }
    expect(checks, 3);
    expect(comparisons, sorting);
    expect(view(boundary).events.map((e) => e.title), ['a', 'c']);
    expect(view(boundary, sport: 'tennis').events.map((e) => e.title), ['c']);
    expect(view(now, sport: 'tennis').events.map((e) => e.title), ['b']);
  });

  test('midnight and new guide snapshots invalidate cached dates and contents',
      () {
    final now = DateTime(2026, 10, 24, 23, 59);
    final tomorrow = DateTime(2026, 10, 25);
    final rows = [
      event('a', 'tennis', now, tomorrow.add(const Duration(hours: 2)))
    ];
    final cache = ReplayBrowseIndex();
    var checks = 0;
    ReplayBrowseView view(List<SportsReplay> source, DateTime at) =>
        cache.resolve(
            events: source,
            configuration: 'recent',
            now: at,
            matches: (_, time) {
              checks++;
              return time.day == 24;
            },
            compare: (a, b) => 0);
    expect(view(rows, now).events, hasLength(1));
    expect(view(rows, tomorrow).events, isEmpty);
    expect(checks, 2);
    expect(view([...rows], tomorrow).events, isEmpty);
    expect(checks, 3);
  });
}
