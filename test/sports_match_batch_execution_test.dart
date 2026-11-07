import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:nox_iptv/models/channel.dart';
import 'package:nox_iptv/models/epg_program.dart';
import 'package:nox_iptv/models/sports.dart';
import 'package:nox_iptv/services/epg_service.dart';
import 'package:nox_iptv/services/storage_service.dart';
import 'package:nox_iptv/services/sports_channel_matcher.dart';
import 'package:nox_iptv/services/sports_match_inputs.dart';
import 'package:nox_iptv/services/sports_match_batch_plan.dart';

final _now = DateTime.utc(2026, 10, 30, 12);

class _Guide extends EpgService {
  _Guide(super.storage);
  final rows = <EpgProgram>[];
  @override
  EpgProgram? getCurrentProgram(String id) =>
      rows.where((p) => p.channelId == id && p.isNowPlaying(_now)).firstOrNull;
  @override
  EpgProgram? getNextProgram(String id) => null;
  @override
  Future<List<EpgProgram>> findProgrammesByTitle(
          DateTime from, DateTime to, List<String> terms,
          {List<String>? channelIds}) async =>
      rows.where((p) => p.start.isBefore(to) && p.stop.isAfter(from)).toList();
  @override
  Future<List<EpgProgram>> findSportsProgrammesForChannels(
          List<String> ids, DateTime from, DateTime to) async =>
      rows
          .where((p) =>
              ids.contains(p.channelId) &&
              p.start.isBefore(to) &&
              p.stop.isAfter(from))
          .toList();
}

class _Picks implements SportsMatchPicks {
  @override
  String? channelIdFor(SportsGame game) => null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final background in [false, true]) {
    test(
        'bounded batches retain rankings and revisit live conflicts ($background)',
        () async {
      SharedPreferences.setMockInitialValues({});
      final storage = StorageService();
      await storage.init();
      final guide = _Guide(storage)..lastUpdated = _now;
      addTearDown(guide.dispose);
      SportsGame
          game(String id, {int hour = 0, bool tennis = false}) =>
              SportsGame(
                  id: id,
                  league: sportsLeagueById(tennis ? 'tennis.atp' : 'eng.1')!,
                  start: _now.add(Duration(hours: hour)),
                  state: hour == 0 ? GameState.live : GameState.pre,
                  statusText: '',
                  home: SportsTeam(
                      id: 'a',
                      name: tennis ? 'Jannik Sinner' : 'Arsenal',
                      shortName: tennis ? 'Sinner' : 'Arsenal',
                      abbreviation: ''),
                  away: SportsTeam(
                      id: 'b',
                      name: tennis ? 'Carlos Alcaraz' : 'Chelsea',
                      shortName: tennis ? 'Alcaraz' : 'Chelsea',
                      abbreviation: ''),
                  event: tennis
                      ? const SportsEventInfo(title: 'Paris Masters')
                      : null);
      var games = [
        game('live'),
        game('tennis', tennis: true),
        for (var i = 0; i < 60; i++) game('later$i', hour: 4 + (i % 3) * 8),
        game('later-tennis', hour: 10, tennis: true)
      ];
      final channels = [
        for (var i = 0; i < 4; i++)
          Channel(
              id: 'p::$i',
              rawId: '$i',
              playlistId: 'p',
              name: i == 3 ? 'Sky Sports Tennis' : 'Sports feed $i',
              group: 'UK Sports',
              url: 'https://example.invalid/unused',
              epgIdOverride: '$i')
      ];
      for (var hour = 0; hour < 24; hour += 4) {
        guide.rows.add(EpgProgram(
            channelId: '${hour % 3}',
            title: 'Arsenal vs Chelsea LIVE',
            start: _now.add(Duration(hours: hour)),
            stop: _now.add(Duration(hours: hour + 2)),
            isLive: true));
      }
      guide.rows.add(EpgProgram(
          channelId: '3',
          title: 'ATP Paris Masters: Jannik Sinner vs Carlos Alcaraz',
          start: _now,
          stop: _now.add(const Duration(hours: 2)),
          isLive: true));
      SportsChannelMatcher make() => background
          ? SportsChannelMatcher.background(guide, clock: () => _now)
          : SportsChannelMatcher(guide, clock: () => _now);
      final worker = make();
      addTearDown(worker.dispose);
      await worker.prepare(channels);
      final plan = SportsMatchBatchPlan(maxLaterEvents: 12);
      final output = <String, List<ChannelMatch>>{};
      var injected = false, rounds = 0;
      Map<String, String>? identities;
      while (true) {
        identities ??= {
          for (final g in games)
            SportsChannelPicks.eventKey(g):
                SportsChannelMatcher.matchingIdentity(g, _Picks())
        };
        if (await worker.rememberMatchContext(games)) plan.invalidateTennis();
        final batch = plan.next(games, identities, _now);
        if (batch.isEmpty) break;
        expect(++rounds, lessThan(20));
        if (injected && rounds == 3) {
          expect(
              batch.map((g) => g.id).toSet(), {'live', 'tennis', 'late-live'});
        }
        final result = await worker.matchDay(batch, _Picks(),
            includePossible: true, onProgress: (_) {});
        output.addAll(result);
        plan.complete(batch, identities);
        if (!injected && batch.every((g) => g.state != GameState.live)) {
          games = [...games, game('late-live')];
          identities = null;
          injected = true;
        }
      }
      expect(injected, true);
      final fresh = make();
      addTearDown(fresh.dispose);
      await fresh.prepare(channels);
      final expected = await fresh.matchDay(games, _Picks(),
          includePossible: true, onProgress: (_) {});
      List<Object?> signature(List<ChannelMatch> rows) => [
            for (final m in rows)
              [
                m.channel.id,
                m.reason,
                m.score,
                m.isConfident,
                m.programme?.title,
                m.programme?.start
              ]
          ];
      expect(output.keys.toSet(), expected.keys.toSet());
      for (final entry in expected.entries) {
        expect(signature(output[entry.key]!), signature(entry.value),
            reason: entry.key);
      }
      expect(output['eng.1:live'], isNotEmpty);
      expect(output['eng.1:live']!.any((m) => m.isConfident), isFalse,
          reason:
              'A newly arrived competing fixture must invalidate the earlier confidence');
    });
  }
}
