import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:nox_iptv/models/channel.dart';
import 'package:nox_iptv/models/epg_program.dart';
import 'package:nox_iptv/models/sports.dart';
import 'package:nox_iptv/services/epg_service.dart';
import 'package:nox_iptv/services/sports_channel_matcher.dart';
import 'package:nox_iptv/services/sports_match_disk_cache.dart';
import 'package:nox_iptv/services/storage_service.dart';

class _Guide extends EpgService {
  _Guide(super.storage);
  final rows = <EpgProgram>[];
  int queries = 0, reads = 0;
  @override
  EpgProgram? getCurrentProgram(String id) {
    reads++;
    return rows.where((p) => p.channelId == id).firstOrNull;
  }

  @override
  EpgProgram? getNextProgram(String id) => null;
  @override
  Future<List<EpgProgram>> findProgrammesByTitle(
      DateTime from, DateTime to, List<String> terms,
      {List<String>? channelIds}) async {
    queries++;
    return rows
        .where((p) => terms.any((t) => p.title.toLowerCase().contains(t)))
        .toList();
  }

  @override
  Future<List<EpgProgram>> findSportsProgrammesForChannels(
          List<String> ids, DateTime from, DateTime to) async =>
      rows.where((p) => ids.contains(p.channelId)).toList();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late StorageService storage;
  late _Guide guide;
  late SportsChannelPicks picks;
  late DateTime now;
  late SportsGame game;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    storage = StorageService();
    await storage.init();
    guide = _Guide(storage);
    picks = SportsChannelPicks.load(storage);
    now = DateTime.now().toUtc();
    game = SportsGame(
        id: 'fixture',
        league: sportsLeagueById('nhl')!,
        start: now.subtract(const Duration(minutes: 10)),
        state: GameState.live,
        statusText: 'Live',
        home: const SportsTeam(
            id: 'bos',
            name: 'Boston Bruins',
            shortName: 'Bruins',
            abbreviation: 'BOS'),
        away: const SportsTeam(
            id: 'tor',
            name: 'Toronto Maple Leafs',
            shortName: 'Maple Leafs',
            abbreviation: 'TOR'));
  });
  tearDown(() => guide.dispose());
  Channel channel(String id, String name) => Channel(
      id: 'p::$id',
      rawId: id,
      playlistId: 'p',
      name: name,
      group: 'Sports',
      url: 'https://example.invalid/unused',
      epgIdOverride: id);
  EpgProgram programme(
          [String title = 'NHL: Boston Bruins vs Toronto Maple Leafs']) =>
      EpgProgram(
          channelId: '1',
          title: title,
          start: game.start,
          stop: now.add(const Duration(hours: 2)));

  for (final background in [false, true]) {
    test(
        'professional codes require matchup and league; background=$background',
        () async {
      final matcher = background
          ? SportsChannelMatcher.background(guide, clock: () => now)
          : SportsChannelMatcher(guide, clock: () => now);
      addTearDown(matcher.dispose);
      await matcher.prepare([
        channel('1', 'NHL: BOS vs TOR'),
        channel('2', 'NBA: BOS vs TOR'),
        channel('3', 'BOS vs TOR'),
        channel('4', 'NHL discussion BOS and TOR'),
      ]);
      final rows = (await matcher
          .matchDay([game], picks))[SportsChannelPicks.eventKey(game)]!;
      expect(
          rows.where((m) => m.isConfident).map((m) => m.channel.id), ['p::1']);
    });
  }

  test(
      'unchanged results survive clock bucket; real expiry and updates still recheck',
      () async {
    now = DateTime.utc(2026, 10, 28, 12, 4, 59);
    final matcher = SportsChannelMatcher(guide, clock: () => now);
    await matcher.prepare([channel('1', 'NHL: BOS vs TOR')]);
    final first = await matcher.matchDay([game], picks);
    now = now.add(const Duration(seconds: 2));
    expect(await matcher.matchDay([game], picks), same(first));
    guide.notifyListeners();
    expect(await matcher.matchDay([game], picks), isNot(same(first)));
    final refreshed = await matcher.matchDay([game], picks);
    now = now.add(const Duration(minutes: 5));
    expect(await matcher.matchDay([game], picks), isNot(same(refreshed)));
  });

  test('wrong-event decision persists, is programme-scoped and can be undone',
      () async {
    final c = channel('1', 'NHL: BOS vs TOR'), p = programme();
    guide.rows.add(p);
    final matcher = SportsChannelMatcher.background(guide, clock: () => now);
    addTearDown(matcher.dispose);
    await matcher.prepare([c]);
    expect((await matcher.matchDay([game], picks)).values.single, isNotEmpty);
    await picks.rejectForGame(game, c, p);
    picks = SportsChannelPicks.load(storage);
    expect((await matcher.matchDay([game], picks)).values.single, isEmpty);
    guide.rows[0] = programme('NHL: BOS vs TOR · live game');
    guide.notifyListeners();
    expect((await matcher.matchDay([game], picks)).values.single, isNotEmpty);
    guide.rows[0] = p;
    guide.notifyListeners();
    await picks.restoreForGame(game, c, p);
    expect((await matcher.matchDay([game], picks)).values.single, isNotEmpty);
  });

  test(
      'fresh disk matches survive worker restart; guide changes invalidate them',
      () async {
    final dir = await Directory.systemTemp.createTemp('sports-match-cache-');
    addTearDown(() => dir.delete(recursive: true));
    final path = '${dir.path}/matches.json';
    guide.lastUpdated = now;
    guide.rows.add(programme());
    final channels = [channel('1', 'Sports channel')];
    var matcher = SportsChannelMatcher.background(guide,
        clock: () => now, cachePath: path);
    await matcher.prepare(channels);
    final first = await matcher.matchDay([game], picks);
    expect(first.values.single, isNotEmpty);
    for (var i = 0; i < 40 && !await File(path).exists(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(await File(path).exists(), true);
    matcher.dispose();
    guide.queries = 0;
    matcher = SportsChannelMatcher.background(guide,
        clock: () => now, cachePath: path);
    addTearDown(matcher.dispose);
    await matcher.prepare(channels);
    final restored = await matcher.matchDay([game], picks);
    expect(restored.values.single.single.channel.id,
        first.values.single.single.channel.id);
    expect(guide.queries, 0,
        reason: 'Restored evidence needs no SQL matching pass');
    guide.rows[0] = programme('NHL: Montreal Canadiens vs Vancouver Canucks');
    guide.notifyListeners();
    expect((await matcher.matchDay([game], picks)).values.single, isEmpty);
    expect(guide.queries, greaterThan(0));
    await Future<void>.delayed(const Duration(milliseconds: 450));
  });

  test('disk cache bounds, expiry, rollback and corruption fail closed',
      () async {
    final dir = await Directory.systemTemp.createTemp('sports-cache-bounds-');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/matches.json');
    final cache = SportsMatchDiskCache(file);
    for (var i = 0; i < 600; i++) {
      cache.put('$i', [], now, now.add(const Duration(minutes: 1)));
    }
    expect(cache.read('0', now), isNull);
    expect(cache.read('599', now), isNotNull);
    await cache.flush();
    expect(await file.length(), lessThan(SportsMatchDiskCache.maxBytes));
    final restored = SportsMatchDiskCache(file);
    await restored.load(now);
    expect(restored.read('599', now), isNotNull);
    expect(restored.read('599', now.add(const Duration(minutes: 1))), isNull);
    expect(
        restored.read('598', now.subtract(const Duration(seconds: 1))), isNull);
    await file.writeAsString('{broken');
    final corrupt = SportsMatchDiskCache(file);
    await corrupt.load(now);
    expect(corrupt.read('599', now), isNull);
  });

  test('changing filter cohorts reuses event evidence without guide queries',
      () async {
    final second = SportsGame(
        id: 'basketball',
        league: sportsLeagueById('nba')!,
        start: game.start,
        state: GameState.live,
        statusText: 'Live',
        home: const SportsTeam(
            id: 'chi',
            name: 'Chicago Bulls',
            shortName: 'Bulls',
            abbreviation: 'CHI'),
        away: const SportsTeam(
            id: 'bos',
            name: 'Boston Celtics',
            shortName: 'Celtics',
            abbreviation: 'BOS'));
    guide.rows.addAll([
      programme(),
      EpgProgram(
          channelId: '2',
          title: 'NBA: Chicago Bulls vs Boston Celtics',
          start: game.start,
          stop: now.add(const Duration(hours: 2)))
    ]);
    final matcher = SportsChannelMatcher.background(guide, clock: () => now);
    addTearDown(matcher.dispose);
    await matcher.prepare(
        [channel('1', 'Hockey feed'), channel('2', 'Basketball feed')]);
    final first = await matcher.matchDay([game, second], picks);
    expect(first.values.every((rows) => rows.any((m) => m.isConfident)), true);
    final queries = guide.queries;
    final watch = Stopwatch()..start();
    for (var i = 0; i < 40; i++) {
      final cohort = switch (i % 4) {
        0 => [game],
        1 => [second],
        2 => [second, game],
        _ => [game, second],
      };
      final matches = await matcher.matchDay(cohort, picks);
      for (final fixture in cohort) {
        final key = SportsChannelPicks.eventKey(fixture);
        expect(matches[key]!.map((m) => (m.channel.id, m.reason)),
            first[key]!.map((m) => (m.channel.id, m.reason)));
      }
    }
    watch.stop();
    expect(guide.queries, queries);
    // Diagnostic only: wall-clock timings vary by host.
    // ignore: avoid_print
    print(
        'SPORTS_FILTER_MATCHES switches=40 extra_guide_queries=${guide.queries - queries} elapsed_us=${watch.elapsedMicroseconds}');
  });
}
