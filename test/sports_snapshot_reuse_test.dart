import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:nox_iptv/models/channel.dart';
import 'package:nox_iptv/models/epg_program.dart';
import 'package:nox_iptv/models/sports.dart';
import 'package:nox_iptv/models/sports_progress.dart';
import 'package:nox_iptv/services/epg_service.dart';
import 'package:nox_iptv/services/sports_channel_matcher.dart';
import 'package:nox_iptv/services/storage_service.dart';

class _Guide extends EpgService {
  _Guide(super.storage);
  final current = <String, EpgProgram>{}, next = <String, EpgProgram>{};
  final schedule = <EpgProgram>[];
  int queries = 0;
  @override
  int get currentGuideRevision => guideRowsLoaded.value;
  @override
  EpgProgram? getCurrentProgram(String id) => current[id];
  @override
  EpgProgram? getNextProgram(String id) => next[id];
  @override
  Future<List<EpgProgram>> findProgrammesByTitle(
      DateTime from, DateTime to, List<String> terms,
      {List<String>? channelIds}) async {
    queries++;
    return schedule
        .where((p) =>
            p.start.isBefore(to) &&
            p.stop.isAfter(from) &&
            terms.any(p.title.toLowerCase().contains))
        .toList();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late StorageService storage;
  late _Guide guide;
  late SportsChannelMatcher worker;
  late SportsChannelPicks picks;
  late DateTime now;
  late SportsGame game;
  late List<Channel> channels;
  final stages = <SportsWorkStage>[];
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    storage = StorageService();
    await storage.init();
    now = DateTime.utc(2026, 10, 31, 12, 10);
    guide = _Guide(storage)..lastUpdated = now;
    worker = SportsChannelMatcher.background(guide, clock: () => now);
    picks = SportsChannelPicks.load(storage);
    channels = [
      for (final id in ['1', '2', '3'])
        Channel(
            id: 'p::$id',
            rawId: id,
            playlistId: 'p',
            name: 'Local Channel $id',
            group: 'General',
            url: 'https://example.invalid/$id',
            epgIdOverride: id)
    ];
    game = SportsGame(
        id: 'fixture',
        league: sportsLeagueById('nhl')!,
        start: now.subtract(const Duration(minutes: 10)),
        state: GameState.live,
        statusText: 'Live',
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
    await worker.prepare(channels);
    stages.clear();
  });
  tearDown(() {
    worker.dispose();
    guide.dispose();
  });
  EpgProgram programme(String id, String title, {String? description}) =>
      EpgProgram(
          channelId: id,
          title: title,
          description: description,
          start: game.start,
          stop: game.start.add(const Duration(hours: 2)));
  Future<Map<String, List<ChannelMatch>>> match() async {
    stages.clear();
    return worker.matchDay([game], picks,
        includePossible: true, onStatus: (s) => stages.add(s.stage));
  }

  Object signature(Map<String, List<ChannelMatch>> rows) => {
        for (final e in rows.entries)
          e.key: [
            for (final m in e.value)
              [
                m.channel.id,
                m.reason,
                m.score,
                m.isConfident,
                m.detail,
                m.programme?.title,
                m.programme?.description,
                m.programme?.start,
                m.programme?.stop
              ]
          ]
      };
  Future<void> equalsFresh(Map<String, List<ChannelMatch>> result) async {
    final fresh = SportsChannelMatcher(guide, clock: () => now);
    addTearDown(fresh.dispose);
    await fresh.prepare(channels);
    expect(signature(result),
        signature(await fresh.matchDay([game], picks, includePossible: true)));
  }

  void seed() {
    final p = programme('1', 'NHL: Boston Bruins vs Toronto Maple Leafs');
    guide.current['1'] = p;
    guide.schedule.add(p);
    guide.current['2'] =
        programme('2', 'Evening News', description: 'Headlines and weather.');
  }

  test(
      'unrelated snapshot turnover preserves completed matching and original expiry',
      () async {
    seed();
    final first = await match();
    expect(first.values.single.first.channel.id, 'p::1');
    guide.current['2'] =
        programme('2', 'Local Weather', description: 'Forecast for tomorrow.');
    guide.guideRowsLoaded.value++;
    final retained = await match();
    expect(signature(retained), signature(first));
    expect(stages, isNot(contains(SportsWorkStage.programmes)),
        reason: 'No programme index or rescoring for unrelated evidence');
    await equalsFresh(retained);
    now = now.add(const Duration(minutes: 5, seconds: 1));
    await match();
    expect(stages, contains(SportsWorkStage.programmes),
        reason: 'Reuse must not renew the original five-minute expiry');
  });
  for (final change in ['current', 'next', 'removed']) {
    test('consulted channel $change change is rechecked', () async {
      seed();
      await match();
      if (change == 'current') {
        guide.current['1'] = programme('1', 'WTA Tennis');
      } else if (change == 'next') {
        guide.next['1'] = programme('1', 'WTA Tennis');
      } else {
        guide.current.remove('1');
      }
      guide.guideRowsLoaded.value++;
      final result = await match();
      expect(stages, contains(SportsWorkStage.programmes));
      await equalsFresh(result);
      if (change == 'current') {
        expect(result.values.single, isEmpty);
      }
    });
  }
  test('new synopsis match on a previously unrelated channel is not missed',
      () async {
    guide.current['3'] = programme('3', 'Live NHL');
    expect((await match()).values.single, isEmpty);
    guide.current['3'] = programme('3', 'Live NHL',
        description: 'Boston Bruins vs Toronto Maple Leafs. Live ice hockey.');
    guide.guideRowsLoaded.value++;
    final result = await match();
    expect(stages, contains(SportsWorkStage.programmes));
    expect(result.values.single.first.channel.id, 'p::3');
    expect(result.values.single.first.isConfident, true);
    await equalsFresh(result);
  });
  test('underlying guide refresh invalidates queries and dependencies together',
      () async {
    seed();
    await match();
    final queries = guide.queries;
    guide.current.clear();
    guide.schedule.clear();
    guide.notifyListeners();
    final result = await match();
    expect(guide.queries, greaterThan(queries));
    expect(result.values.single, isEmpty);
    await equalsFresh(result);
  });
  test('a changed tennis feed does not rescore an independent hockey batch',
      () async {
    seed();
    final tennis = SportsGame(
        id: 'tennis',
        league: sportsLeagueById('tennis.atp')!,
        start: game.start,
        state: GameState.live,
        statusText: 'Live',
        home: const SportsTeam(
            id: 's',
            name: 'Jannik Sinner',
            shortName: 'Sinner',
            abbreviation: ''),
        away: const SportsTeam(
            id: 'a',
            name: 'Carlos Alcaraz',
            shortName: 'Alcaraz',
            abbreviation: ''),
        event: const SportsEventInfo(title: 'Paris Masters'));
    final p =
        programme('3', 'ATP Paris Masters: Jannik Sinner vs Carlos Alcaraz');
    guide.current['3'] = p;
    guide.schedule.add(p);
    final hockey = await match();
    final first = await worker.matchDay([tennis], picks, includePossible: true);
    expect(first.values.single.first.channel.id, 'p::3');
    guide.current['3'] = programme('3', 'NHL Hockey');
    guide.guideRowsLoaded.value++;
    expect(signature(await match()), signature(hockey));
    expect(stages, isNot(contains(SportsWorkStage.programmes)));
    final result =
        await worker.matchDay([tennis], picks, includePossible: true);
    expect(result.values.single, isEmpty);
  });
}
