import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:nox_iptv/models/channel.dart';
import 'package:nox_iptv/models/epg_program.dart';
import 'package:nox_iptv/models/sports.dart';
import 'package:nox_iptv/services/sports_channel_matcher.dart';
import 'package:nox_iptv/services/sports_match_inputs.dart';

final _now = DateTime.utc(2026, 10, 30, 18);

class _Guide implements SportsMatchGuide {
  final rows = <EpgProgram>[];
  final windows = <(DateTime, DateTime)>[];
  Completer<void>? later;
  @override
  int changeRevision = 1;
  @override
  DateTime get lastUpdated => _now;
  @override
  EpgProgram? getCurrentProgram(String id) =>
      rows.where((p) => p.channelId == id && p.isNowPlaying(_now)).firstOrNull;
  @override
  EpgProgram? getNextProgram(String id) => null;
  @override
  Future<List<EpgProgram>> findProgrammesByTitle(
      DateTime from, DateTime to, List<String> terms) async {
    windows.add((from, to));
    if (from.isAfter(_now.add(const Duration(hours: 2)))) await later?.future;
    return rows
        .where((p) => p.start.isBefore(to) && p.stop.isAfter(from))
        .toList();
  }

  @override
  Future<List<EpgProgram>> findSportsProgrammesForChannels(
          List<String> ids, DateTime from, DateTime to) async =>
      [];
}

class _Picks implements SportsMatchPicks {
  @override
  String? channelIdFor(SportsGame game) => null;
}

void main() {
  SportsTeam team(String name) =>
      SportsTeam(id: name, name: name, shortName: name, abbreviation: '');
  SportsGame fixture(String id,
          {bool later = false,
          List<SportsBroadcast> broadcasts = const [],
          List<SportsBroadcast> online = const []}) =>
      SportsGame(
          id: id,
          league: sportsLeagueById('eng.1')!,
          start: later
              ? _now.add(const Duration(hours: 8))
              : _now.subtract(const Duration(minutes: 10)),
          state: later ? GameState.pre : GameState.live,
          statusText: '',
          home: team('Arsenal'),
          away: team('Chelsea'),
          broadcasts: broadcasts.map((b) => b.name).toList(),
          scoreboardBroadcasts: broadcasts,
          onlineBroadcasts: online);
  Channel channel(String id, String name, String group) => Channel(
      id: id,
      rawId: id,
      playlistId: 'fixture',
      name: name,
      group: group,
      url: 'https://example.invalid/unused');

  test(
      'live fixtures finish before a blocked later schedule without changing final matches',
      () async {
    final guide = _Guide()..later = Completer<void>();
    guide.rows.add(EpgProgram(
        channelId: 'event',
        title: 'Arsenal vs Chelsea',
        start: _now.subtract(const Duration(minutes: 20)),
        stop: _now.add(const Duration(hours: 2))));
    final matcher = SportsChannelMatcher(guide, clock: () => _now);
    addTearDown(matcher.dispose);
    final channels = [channel('event', 'Event channel', 'UK Sports')];
    await matcher.prepare(channels);
    final games = [fixture('later', later: true), fixture('live')];
    final ready = Completer<List<ChannelMatch>>();
    var finished = false;
    final task = matcher.matchDay(games, _Picks(), includePossible: true,
        onProgress: (partial) {
      final live = partial[SportsChannelPicks.eventKey(games.last)];
      if (live?.any((m) => m.isConfident) == true && !ready.isCompleted) {
        ready.complete(live);
      }
    }).then((value) {
      finished = true;
      return value;
    });
    final first = await ready.future.timeout(const Duration(seconds: 3));
    expect(first.first.channel.id, 'event');
    expect(finished, isFalse);
    expect(guide.windows.first.$2.isBefore(_now.add(const Duration(hours: 4))),
        isTrue);
    guide.later!.complete();
    final actual = await task;
    final baseline = SportsChannelMatcher(_Guide()..rows.addAll(guide.rows),
        clock: () => _now);
    addTearDown(baseline.dispose);
    await baseline.prepare(channels);
    final expected =
        await baseline.matchDay(games, _Picks(), includePossible: true);
    for (final key in expected.keys) {
      expect(actual[key]!.map((m) => (m.channel.id, m.reason, m.score)),
          expected[key]!.map((m) => (m.channel.id, m.reason, m.score)));
    }
  });

  test('scoreboard country and streaming metadata restrict network hints',
      () async {
    final matcher = SportsChannelMatcher(_Guide(), clock: () => _now);
    addTearDown(matcher.dispose);
    await matcher.prepare([
      channel('us', 'ESPN', 'US Sports'),
      channel('au', 'ESPN', 'Australia Sports'),
      channel('stream', 'ESPN+', 'US Sports')
    ]);
    final game = fixture('one', broadcasts: [
      const SportsBroadcast('ESPN',
          source: 'ESPN', country: 'United States', medium: 'TV'),
      const SportsBroadcast('ESPN+',
          source: 'ESPN', country: 'United States', medium: 'Streaming')
    ]);
    final result = (await matcher.matchDay([game], _Picks(),
        includeGuide: false))[SportsChannelPicks.eventKey(game)]!;
    expect(
        result
            .where((m) => m.reason == MatchReason.network)
            .map((m) => m.channel.id),
        ['us']);
  });

  test(
      'unknown-market official listings remain possible without local guide evidence',
      () async {
    final matcher = SportsChannelMatcher(_Guide(), clock: () => _now);
    addTearDown(matcher.dispose);
    await matcher.prepare([channel('espn', 'ESPN', 'US Sports')]);
    final game = fixture('hint', online: [
      const SportsBroadcast('ESPN', source: 'MLB', requiresGuide: true)
    ]);
    final result = (await matcher.matchDay([game], _Picks(),
        includeGuide: false,
        includePossible: true))[SportsChannelPicks.eventKey(game)]!;
    expect(result, isNotEmpty);
    expect(result.any((m) => m.isConfident), isFalse);
  });
  test(
      'time postings retain imminent programme boundaries for cached decisions',
      () async {
    var clock = _now;
    final guide = _Guide();
    guide.rows.add(EpgProgram(
        channelId: 'coverage',
        title: 'Live English Premier League Football',
        start: _now.add(const Duration(minutes: 31)),
        stop: _now.add(const Duration(hours: 3))));
    final matcher = SportsChannelMatcher(guide, clock: () => clock);
    addTearDown(matcher.dispose);
    await matcher.prepare([channel('coverage', 'Event Feed', 'UK Sports')]);
    final game = fixture('boundary');
    final key = SportsChannelPicks.eventKey(game);
    expect(
        (await matcher.matchDay([game], _Picks(), includePossible: true))[key],
        isEmpty);
    clock = clock.add(const Duration(minutes: 2));
    final next =
        (await matcher.matchDay([game], _Picks(), includePossible: true))[key]!;
    expect(next.map((m) => m.channel.id), contains('coverage'));
    expect(next.any((m) => m.isConfident), isFalse);
  });
  test(
      'reference overlap keeps long broadcasts and future slots but skips ended rows',
      () async {
    final guide = _Guide();
    for (final (id, start, stop) in [
      (
        'long',
        _now.subtract(const Duration(hours: 6)),
        _now.add(const Duration(hours: 2))
      ),
      (
        'ended',
        _now.subtract(const Duration(hours: 1)),
        _now.subtract(const Duration(minutes: 1))
      ),
      (
        'next',
        _now.add(const Duration(minutes: 20)),
        _now.add(const Duration(hours: 2))
      ),
    ]) {
      guide.rows.add(EpgProgram(
          channelId: id,
          title: 'Arsenal vs Chelsea',
          start: start,
          stop: stop));
    }
    final matcher = SportsChannelMatcher(guide, clock: () => _now);
    addTearDown(matcher.dispose);
    await matcher.prepare([
      for (final id in ['long', 'ended', 'next'])
        channel(id, 'Event Feed $id', 'UK Sports')
    ]);
    final game = fixture('overlap');
    final rows = (await matcher.matchDay([game], _Picks(),
        includePossible: true))[SportsChannelPicks.eventKey(game)]!;
    expect(guide.windows.single.$1, _now);
    expect(rows.first.channel.id, 'long');
    expect(rows.first.isConfident, isTrue);
    expect(rows.map((m) => m.channel.id), contains('next'));
    expect(rows.map((m) => m.channel.id), isNot(contains('ended')));
  });
}
