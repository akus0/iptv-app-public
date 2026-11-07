import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:nox_iptv/models/channel.dart';
import 'package:nox_iptv/models/epg_program.dart';
import 'package:nox_iptv/models/sports.dart';
import 'package:nox_iptv/services/sports_channel_text_cache.dart';
import 'package:nox_iptv/services/sports_channel_matcher.dart';
import 'package:nox_iptv/services/sports_match_inputs.dart';

class _Guide implements SportsMatchGuide {
  @override
  int get changeRevision => 0;
  @override
  DateTime? get lastUpdated => null;
  @override
  EpgProgram? getCurrentProgram(String id) => null;
  @override
  EpgProgram? getNextProgram(String id) => null;
  @override
  Future<List<EpgProgram>> findProgrammesByTitle(
          DateTime from, DateTime to, List<String> terms) async =>
      [];
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
  late Directory dir;
  late File file;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('sports-text-test-');
    file = File('${dir.path}/names.json');
  });
  tearDown(() async => dir.delete(recursive: true));

  test(
      'versioned text survives restart; edits miss and departed names are removed',
      () async {
    final cache = SportsChannelTextCache(file);
    await cache.load();
    cache.remember(
        'Sky Sports Tennis HD', ' sky sports tennis hd ', 'skysportstennis');
    await cache.flush();
    final restored = SportsChannelTextCache(file);
    await restored.load();
    expect(restored['Sky Sports Tennis HD'],
        (' sky sports tennis hd ', 'skysportstennis'));
    expect(restored['Sky Sports Golf HD'], isNull);
    restored.retainNames({'Sky Sports Golf HD'});
    restored.remember(
        'Sky Sports Golf HD', ' sky sports golf hd ', 'skysportsgolf');
    await restored.flush();
    final replaced = SportsChannelTextCache(file);
    await replaced.load();
    expect(replaced['Sky Sports Tennis HD'], isNull);
    expect(replaced['Sky Sports Golf HD'], isNotNull);
  });

  test('damaged and old cache data falls back to recomputation', () async {
    final cache = SportsChannelTextCache(file);
    cache.remember('ESPN', ' espn ', 'espn');
    await cache.flush();
    final valid = await file.readAsString();
    for (final value in [
      '{broken',
      valid.replaceFirst(
          '"version":${SportsChannelTextCache.version}', '"version":0'),
      valid.replaceFirst(' espn ', ' incorrect '),
      jsonEncode({'version': 1, 'entries': 'incorrect type'}),
    ]) {
      await file.writeAsString(value);
      final restored = SportsChannelTextCache(file);
      await restored.load();
      expect(restored['ESPN'], isNull);
      restored.remember('ESPN', ' espn ', 'espn');
      await restored.flush();
      final recovered = SportsChannelTextCache(file);
      await recovered.load();
      expect(recovered['ESPN'], (' espn ', 'espn'));
    }
  });

  for (final previousVersion in [1, 2]) {
    test(
        'v$previousVersion migration retains unaffected names and invalidates native derived names',
        () async {
      final old = SportsChannelTextCache(file);
      old.remember('ESPN', ' espn ', 'espn');
      old.remember('🇦🇺 Sports HD ᴿᴬᵂ', ' sports hd raw ', 'sportshd');
      old.remember('São Paulo', ' sao paulo ', 'saopaulo');
      old.remember('鹿島アントラーズ', ' stale ', 'old');
      old.remember('삼성 라이온즈', ' stale ', 'old');
      old.remember('阪神タイガース', ' stale ', 'old');
      await old.flush();
      final data =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      data['version'] = previousVersion;
      await file.writeAsString(jsonEncode(data));
      final migrated = SportsChannelTextCache(file);
      await migrated.load();
      expect(migrated['ESPN'], (' espn ', 'espn'));
      expect(migrated['🇦🇺 Sports HD ᴿᴬᵂ'], (' sports hd raw ', 'sportshd'));
      expect(migrated['São Paulo'], (' sao paulo ', 'saopaulo'));
      expect(migrated['鹿島アントラーズ'], isNull);
      expect(migrated['삼성 라이온즈'], isNull);
      expect(migrated['阪神タイガース'], isNull);
      migrated.remember('鹿島アントラーズ', ' kashima antlers ', 'new');
      await migrated.flush();
      final restored = SportsChannelTextCache(file);
      await restored.load();
      expect(restored['ESPN'], (' espn ', 'espn'));
      expect(restored['鹿島アントラーズ'], (' kashima antlers ', 'new'));
    });
  }

  test('oversized names and unavailable storage cannot prevent matching',
      () async {
    final cache =
        SportsChannelTextCache(File('${dir.path}/missing/names.json'));
    await cache.load();
    final oversized = 'x' * 513;
    cache.remember(oversized, ' x ', 'x');
    expect(cache[oversized], isNull);
    cache.remember('ESPN', ' espn ', 'espn');
    await cache.flush();
    expect(cache['ESPN'], (' espn ', 'espn'));
  });

  test(
      'warm name cache preserves rankings and rebuilds IDs, order, links and exclusions',
      () async {
    final now = DateTime.utc(2026, 10, 31, 12);
    Channel channel(String id, String name,
            {String group = 'UK Sports', String? epg}) =>
        Channel(
            id: id,
            rawId: id,
            playlistId: 'test',
            name: name,
            group: group,
            epgIdOverride: epg,
            url: 'https://example.invalid/unused');
    final channels = [
      for (var i = 0; i < 20000; i++)
        channel('$i', 'UK: Entertainment Channel $i HD'),
      channel('tennis', 'UK: Sky Sports Tennis 576p25'),
      channel('event', 'Jannik Sinner vs Carlos Alcaraz'),
    ];
    final cache = SportsChannelTextCache(file);
    final watch = Stopwatch()..start();
    final cold = SportsChannelMatcher(_Guide(),
        clock: () => now, channelTextCache: cache);
    await cold.prepare(channels);
    final coldMs = watch.elapsedMilliseconds;
    await cache.flush();
    cold.dispose();
    final changed = [
      channel('new-event', 'Jannik Sinner vs Carlos Alcaraz',
          epg: 'fresh-guide'),
      channel('excluded', '### Sky Sports Tennis'),
      channel('new-tennis', 'UK: Sky Sports Tennis 576p25'),
      ...channels.take(20000).toList().reversed,
    ];
    final warmCache = SportsChannelTextCache(file);
    final warm = SportsChannelMatcher(_Guide(),
        clock: () => now, channelTextCache: warmCache);
    watch.reset();
    await warm.prepare(changed);
    final warmMs = watch.elapsedMilliseconds;
    final ordinary = SportsChannelMatcher(_Guide(), clock: () => now);
    await ordinary.prepare(changed);
    final game = SportsGame(
        id: 'tennis',
        league: sportsLeagueById('tennis.atp')!,
        start: now,
        state: GameState.live,
        statusText: 'Live',
        home: const SportsTeam(
            id: 'h',
            name: 'Jannik Sinner',
            shortName: 'Sinner',
            abbreviation: ''),
        away: const SportsTeam(
            id: 'a',
            name: 'Carlos Alcaraz',
            shortName: 'Alcaraz',
            abbreviation: ''),
        event: const SportsEventInfo(title: 'Paris Masters'));
    final actual = await warm.matchDay([game], _Picks(), includePossible: true);
    final expected =
        await ordinary.matchDay([game], _Picks(), includePossible: true);
    final key = SportsChannelPicks.eventKey(game);
    expect(actual[key]!.map((m) => (m.channel.id, m.reason, m.score)),
        expected[key]!.map((m) => (m.channel.id, m.reason, m.score)));
    expect(warm.channelById('event'), isNull);
    expect(warm.channelById('new-event')!.epgId, 'fresh-guide');
    expect(actual[key]!.any((m) => m.channel.id == 'excluded'), isFalse);
    await warmCache.flush();
    warm.dispose();
    ordinary.dispose();
    // Diagnostic only: timing thresholds vary across build hosts.
    // ignore: avoid_print
    print(
        '20k channel names: cold ${coldMs}ms, restored ${warmMs}ms, cache ${await file.length()} bytes');
  });
}
