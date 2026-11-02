import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:nox_iptv/models/channel.dart';
import 'package:nox_iptv/models/epg_program.dart';
import 'package:nox_iptv/models/sports.dart';
import 'package:nox_iptv/services/epg_service.dart';
import 'package:nox_iptv/services/storage_service.dart';
import 'package:nox_iptv/services/sports_channel_matcher.dart';

class _Guide extends EpgService {
  _Guide(super.storage);
  final current = <String, EpgProgram>{}, next = <String, EpgProgram>{};
  int reads = 0;
  @override
  EpgProgram? getCurrentProgram(String id) {
    reads++;
    return current[id];
  }

  @override
  EpgProgram? getNextProgram(String id) => next[id];
  @override
  Future<List<EpgProgram>> findProgrammesByTitle(
          DateTime a, DateTime b, List<String> terms, {List<String>? channelIds}) =>
      throw StateError('Picker must not start another guide query');
  @override
  Future<List<EpgProgram>> findSportsProgrammesForChannels(
          List<String> ids, DateTime a, DateTime b) =>
      throw StateError('Picker must use the current/next snapshot');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late StorageService storage;
  late _Guide guide;
  late SportsChannelMatcher matcher;
  late DateTime now;
  final start = DateTime.utc(2026, 10, 23, 9);
  final game = SportsGame(
      id: 'almaty',
      league: sportsLeagueById('tennis.atp')!,
      start: start,
      state: GameState.live,
      statusText: 'Live',
      home: const SportsTeam(
          id: 'a',
          name: 'Stefanos Tsitsipas',
          shortName: 'Tsitsipas',
          abbreviation: 'TSI'),
      away: const SportsTeam(
          id: 'b',
          name: 'James Duckworth',
          shortName: 'Duckworth',
          abbreviation: 'DUC'),
      event: const SportsEventInfo(title: 'Almaty Open'));
  Channel channel(String id, String name,
          {String group = 'Sport', String? rawId}) =>
      Channel(
          id: id,
          rawId: rawId ?? id,
          playlistId: 'test',
          name: name,
          group: group,
          epgIdOverride: id,
          url: 'https://example.invalid/never-play');
  EpgProgram programme(String id, String title,
          {String? desc, DateTime? from, DateTime? to}) =>
      EpgProgram(
          channelId: id,
          title: title,
          description: desc,
          start: from ?? start,
          stop: to ?? start.add(const Duration(hours: 2)));
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    storage = StorageService();
    await storage.init();
    guide = _Guide(storage);
    now = start.add(const Duration(minutes: 5));
    matcher = SportsChannelMatcher(guide, clock: () => now);
  });
  tearDown(() {
    matcher.dispose();
    guide.dispose();
  });

  test(
      'all tennis names, categories and current/next guide suggestions survive beyond eight',
      () async {
    final channels = [
      for (var i = 0; i < 35; i++) channel('$i', 'Tennis Channel Plus $i'),
      channel('women', 'WTA 1'),
      channel('category', 'Court feed', group: 'Tennis'),
      channel('guide', 'General Sports 1'),
      channel('next', 'General Sports 2'),
      channel('specific', 'Tsitsipas vs Duckworth'),
      channel('table', 'Table Tennis'),
      channel('unrelated', 'Comedy'),
      channel('header', '### Tennis'),
    ];
    guide.current['guide'] = programme('guide', 'Live sport',
        desc: 'ATP Almaty quarterfinal coverage.');
    guide.next['next'] = programme('next', 'WTA tennis',
        from: now.add(const Duration(minutes: 10)));
    await matcher.prepare(channels);
    final evidence = [
      ChannelMatch(channels[0], MatchReason.guide, 500),
      ChannelMatch(channels[1], MatchReason.pick, 1000)
    ];
    final rows = await matcher.alternativesFor(game, matches: evidence);
    expect(rows.length, 40);
    expect(rows.take(2).map((m) => m.channel.id), ['1', '0']);
    expect(rows.map((m) => m.channel.id),
        containsAll(['women', 'category', 'guide', 'next', 'specific']));
    expect(rows.where((m) => m.isConfident).length, 2);
    expect(rows.indexWhere((m) => m.channel.id == 'guide'),
        lessThan(rows.indexWhere((m) => m.channel.id == 'next')));
    final reads = guide.reads;
    final changed = await matcher.alternativesFor(game,
        matches: [ChannelMatch(channels[4], MatchReason.pick, 1000)]);
    expect(changed.first.channel.id, '4');
    expect(changed.map((m) => m.channel.id).toSet(),
        rows.map((m) => m.channel.id).toSet());
    expect(changed.where((m) => m.isConfident).map((m) => m.channel.id), ['4']);
    expect(guide.reads - reads, lessThanOrEqualTo(channels.length));
  });

  test(
      'other fixtures and inactive slots stay below dedicated tournament coverage',
      () async {
    final channels = [
      channel('event', 'Tennis 1'),
      channel('other', 'Tennis 2'),
      channel('ended', 'ENDED Tennis PPV'),
      channel('replay', 'Tennis Classics')
    ];
    guide.current['event'] = programme('event', 'ATP Almaty Quarterfinals');
    guide.current['other'] =
        programme('other', 'ATP Tennis: Bublik vs Khachanov');
    guide.current['replay'] = programme('replay', 'Tennis highlights');
    await matcher.prepare(channels);
    final rows = await matcher.alternativesFor(game);
    expect(rows.first.channel.id, 'event');
    expect(rows.last.channel.id, 'ended');
    expect(rows.every((m) => !m.isConfident), true);
  });

  test('a programme boundary invalidates related-channel discovery', () async {
    final c = channel('one', 'General Sports');
    final boundary = now.add(const Duration(seconds: 10));
    guide.current['one'] = programme('one', 'Football', to: boundary);
    await matcher.prepare([c]);
    expect(await matcher.alternativesFor(game), isEmpty);
    now = boundary;
    guide.current['one'] = programme('one', 'ATP Almaty', from: boundary);
    expect((await matcher.alternativesFor(game)).single.channel.id, 'one');
    expect(
        await matcher.alternativesFor(game, isCancelled: () => true), isEmpty);
  });

  test(
      'background expansion returns every related entry from 80k without rescanning the host guide',
      () async {
    final channels = [
      for (var i = 0; i < 80000; i++)
        channel('$i', i < 2000 ? 'Tennis Channel $i' : 'Entertainment $i')
    ];
    final worker = SportsChannelMatcher.background(guide, clock: () => now);
    addTearDown(worker.dispose);
    await worker.prepare(channels);
    final timer = Stopwatch()..start();
    final gaps = <int>[];
    var previous = 0;
    final heartbeat = Timer.periodic(const Duration(milliseconds: 2), (_) {
      final at = timer.elapsedMicroseconds;
      gaps.add(at - previous);
      previous = at;
    });
    final rows = await worker.alternativesFor(game);
    final cold = timer.elapsedMilliseconds;
    expect(rows.length, 2000);
    expect(rows.map((m) => m.channel.id).toSet().length, 2000);
    expect(
        identical(
            rows.first.channel, channels[int.parse(rows.first.channel.id)]),
        true);
    final reads = guide.reads;
    timer.reset();
    previous = 0;
    final repeated = await worker.alternativesFor(game,
        matches: [ChannelMatch(channels[1999], MatchReason.pick, 1000)]);
    heartbeat.cancel();
    expect(repeated.length, 2000);
    expect(repeated.first.channel.id, '1999');
    expect(guide.reads, reads);
    gaps.sort();
    expect(gaps.length, greaterThan(1));
    // ignore: avoid_print
    print(
        '80k channels / 2k alternatives: cold ${cold}ms; cached ${timer.elapsedMilliseconds}ms; heartbeat p95 ${gaps[(gaps.length * .95).floor()]}us; max ${gaps.last}us');
  });
}
