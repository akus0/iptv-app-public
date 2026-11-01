import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:nox_iptv/models/channel.dart';
import 'package:nox_iptv/models/epg_program.dart';
import 'package:nox_iptv/models/sports.dart';
import 'package:nox_iptv/models/sports_progress.dart';
import 'package:nox_iptv/services/epg_service.dart';
import 'package:nox_iptv/services/storage_service.dart';
import 'package:nox_iptv/services/sports_channel_matcher.dart';

final now = DateTime.utc(2026, 10, 31, 12);

class Guide extends EpgService {
  Guide(super.storage);
  final rows = <EpgProgram>[];
  @override
  EpgProgram? getCurrentProgram(String id) => null;
  @override
  EpgProgram? getNextProgram(String id) => null;
  @override
  Future<List<EpgProgram>> findProgrammesByTitle(
          DateTime from, DateTime to, List<String> terms,
          {List<String>? channelIds}) async =>
      rows.where((p) => p.start.isBefore(to) && p.stop.isAfter(from)).toList();
}

SportsGame game(String id, int hour) => SportsGame(
    id: id,
    league: sportsLeagueById('nhl')!,
    start: now.add(Duration(hours: hour)),
    state: GameState.pre,
    statusText: '',
    home: const SportsTeam(
        id: 'h',
        name: 'Boston Bruins',
        shortName: 'Bruins',
        abbreviation: 'BOS'),
    away: const SportsTeam(
        id: 'a',
        name: 'Toronto Maple Leafs',
        shortName: 'Maple Leafs',
        abbreviation: 'TOR'));
Object signature(dynamic result) => [
      for (final entry in (result as Map).entries)
        [
          entry.key,
          for (final m in entry.value)
            [
              m.channel.id,
              m.reason.toString(),
              m.score,
              m.isConfident,
              m.detail,
              m.programme?.title,
              m.programme?.description,
              m.programme?.start,
              m.programme?.stop
            ]
        ]
    ];
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('catalogue replacement during programme preparation retries scoring',
      () async {
    SharedPreferences.setMockInitialValues({});
    final storage = StorageService();
    await storage.init();
    final guide = Guide(storage)..lastUpdated = now;
    addTearDown(guide.dispose);
    guide.rows.add(EpgProgram(
        channelId: 'feed',
        title: 'NHL: Boston Bruins vs Toronto Maple Leafs',
        start: now,
        stop: now.add(const Duration(hours: 2))));
    Channel feed(String id) => Channel(
        id: 'p::$id',
        rawId: id,
        playlistId: 'p',
        name: 'Sports Feed $id',
        group: 'Sports',
        url: 'https://example.invalid/$id',
        epgIdOverride: 'feed');
    final matcher = SportsChannelMatcher(guide, clock: () => now);
    addTearDown(matcher.dispose);
    await matcher.prepare([feed('old')]);
    Future<void>? replacement;
    final picks = SportsChannelPicks.load(storage);
    final games = [game('changing-catalogue', 0)];
    final result = await matcher.matchDay(games, picks, onStatus: (status) {
      if (status.stage == SportsWorkStage.programmes && replacement == null) {
        replacement = matcher.prepare([feed('new')]);
      }
    });
    expect(replacement, isNotNull);
    await replacement;
    final matches = result.values.single;
    expect(matches, isNotEmpty);
    expect(matches.every((m) => m.channel.id == 'p::new'), isTrue);
    final fresh = SportsChannelMatcher(guide, clock: () => now);
    addTearDown(fresh.dispose);
    await fresh.prepare([feed('new')]);
    expect(signature(result), signature(await fresh.matchDay(games, picks)));
  });

  test(
      'large index survives small tails without changing matches or corrections',
      () async {
    SharedPreferences.setMockInitialValues({});
    final storage = StorageService();
    await storage.init();
    final guide = Guide(storage)..lastUpdated = now;
    addTearDown(guide.dispose);
    final channels = [
      for (var i = 0; i < 2000; i++)
        Channel(
            id: 'p::$i',
            rawId: '$i',
            playlistId: 'p',
            name: 'Sports Feed $i',
            group: 'Sports',
            url: 'https://example.invalid/$i',
            epgIdOverride: '$i')
    ];
    for (final hour in [0, 12, 20]) {
      for (var i = 0; i < (hour == 0 ? 2000 : 50); i++) {
        guide.rows.add(EpgProgram(
            channelId: '$i',
            title: i == 0
                ? 'NHL: Boston Bruins vs Toronto Maple Leafs'
                : 'Sports programme $i',
            description: 'Sports coverage bulletin $i',
            start: now.add(Duration(hours: hour)),
            stop: now.add(Duration(hours: hour + 2))));
      }
    }
    final matcher = SportsChannelMatcher(guide, clock: () => now);
    addTearDown(matcher.dispose);
    await matcher.prepare(channels);
    final picks = SportsChannelPicks.load(storage);
    for (var round = 0; round < 7; round++) {
      final hour = [0, 12, 20, 0, 12, 20, 0][round];
      if (round == 6) {
        guide.lastUpdated = now.add(const Duration(seconds: 1));
        guide.rows[0] = EpgProgram(
            channelId: '0',
            title: 'NHL: Montreal Canadiens vs Vancouver Canucks',
            start: now,
            stop: now.add(const Duration(hours: 2)));
      }
      final games = [game('game-$round', hour)];
      final timer = Stopwatch()..start();
      final fresh = SportsChannelMatcher(guide, clock: () => now);
      addTearDown(fresh.dispose);
      await fresh.prepare(channels);
      final expected =
          await fresh.matchDay(games, picks, includePossible: true);
      timer.reset();
      final current =
          await matcher.matchDay(games, picks, includePossible: true);
      final elapsedUs = timer.elapsedMicroseconds;
      expect(signature(current), signature(expected), reason: 'round $round');
      if (round == 6) {
        expect(current.values.single.any((m) => m.isConfident), isFalse);
      }
      // Timing is diagnostic; correctness must not depend on host speed.
      // ignore: avoid_print
      print('PROGRAMME_INDEX round=$round match_us=$elapsedUs');
    }
  });
}
