import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nox_iptv/models/channel.dart';
import 'package:nox_iptv/models/epg_program.dart';
import 'package:nox_iptv/models/sports.dart';
import 'package:nox_iptv/services/sports_channel_matcher.dart';
import 'package:nox_iptv/services/sports_match_inputs.dart';
import 'package:nox_iptv/utils/sports_title_matcher.dart';

final _now = DateTime.utc(2026, 11, 6, 8);

class _Guide implements SportsMatchGuide {
  _Guide(this.rows);
  final List<EpgProgram> rows;
  int queries = 0;
  @override
  int get changeRevision => 0;
  @override
  DateTime? get lastUpdated => _now;
  @override
  EpgProgram? getCurrentProgram(String id) => null;
  @override
  EpgProgram? getNextProgram(String id) => null;
  @override
  Future<List<EpgProgram>> findProgrammesByTitle(
      DateTime from, DateTime to, List<String> terms) async {
    queries++;
    final titles = SportsTitleMatcher(terms, precomputeTransitions: true);
    return rows.where((p) => titles.matches(p.title)).toList();
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

const _fixtures = [
  ('ger.1', 'Bayern Munich', 'Borussia Dortmund'),
  ('ger.1', 'FC Cologne', 'Union Berlin'),
  ('ita.1', 'Internazionale', 'Lazio'),
  ('aus.1', 'Wellington Phoenix', 'Brisbane Roar'),
  ('aus.1', 'Central Coast Mariners', 'Perth Glory'),
  ('aus.1', 'Melbourne City', 'Melbourne Victory'),
  ('aus.1', 'Sydney FC', 'Western Sydney Wanderers'),
  ('aus.1', 'Newcastle Jets', 'Adelaide United'),
  ('jpn.1', 'Kashima Antlers', 'Kashiwa Reysol'),
  ('jpn.1', 'Cerezo Osaka', 'Gamba Osaka'),
  ('jpn.1', 'Machida Zelvia', 'Kawasaki Frontale'),
  ('jpn.1', 'Shimizu S Pulse', 'Nagoya Grampus'),
  ('jpn.1', 'Fagiano Okayama', 'Avispa Fukuoka'),
  ('australian-football.afl', 'Adelaide Crows', 'Brisbane Lions'),
  ('australian-football.afl', 'Carlton Blues', 'Collingwood Magpies'),
  ('australian-football.afl', 'Essendon Bombers', 'Fremantle Dockers'),
  ('australian-football.afl', 'Geelong Cats', 'Gold Coast Suns'),
  ('australian-football.afl', 'Hawthorn Hawks', 'Melbourne Demons'),
  ('baseball.npb', 'Yomiuri Giants', 'Hanshin Tigers'),
  ('baseball.npb', 'Chunichi Dragons', 'Orix Buffaloes'),
  ('baseball.npb', 'Fukuoka SoftBank Hawks', 'Hokkaido Nippon Ham Fighters'),
  ('baseball.npb', 'Chiba Lotte Marines', 'Saitama Seibu Lions'),
  ('baseball.npb', 'Hiroshima Toyo Carp', 'Tokyo Yakult Swallows'),
  ('baseball.kbo', 'KIA Tigers', 'Samsung Lions'),
  ('baseball.kbo', 'LG Twins', 'Doosan Bears'),
  ('baseball.kbo', 'SSG Landers', 'Lotte Giants'),
  ('baseball.kbo', 'Hanwha Eagles', 'Kiwoom Heroes'),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('mixed team leagues retain exact matches and bounded guide work',
      () async {
    SportsTeam team(String name) =>
        SportsTeam(id: name, name: name, shortName: name, abbreviation: '');
    final indexUs = <int>[], matchUs = <int>[], cachedUs = <int>[];
    for (var run = 0; run < 7; run++) {
      // New objects and matcher each pass include fixture-vocabulary setup.
      final games = [
        for (final f in _fixtures.indexed)
          SportsGame(
              id: '${f.$1}',
              league: sportsLeagueById(f.$2.$1)!,
              start: _now,
              state: GameState.live,
              statusText: '',
              home: team(f.$2.$2),
              away: team(f.$2.$3))
      ];
      final channels = [
        for (var i = 0; i < 20000; i++)
          Channel(
              id: '$i',
              rawId: '$i',
              playlistId: 'test',
              name: 'Entertainment feed $i',
              group: 'Live',
              url: 'https://example.invalid/$i')
      ];
      final guide = _Guide([
        for (var i = 0; i < 5000; i++)
          EpgProgram(
              channelId: '$i',
              title: i < games.length
                  ? '${games[i].league.name}: ${games[i].home.name} vs ${games[i].away.name}'
                  : 'Daily News Episode $i',
              start: _now,
              stop: _now.add(const Duration(hours: 2)))
      ]);
      final matcher = SportsChannelMatcher(guide, clock: () => _now);
      try {
        final watch = Stopwatch()..start();
        await matcher.prepare(channels);
        final index = watch.elapsedMicroseconds;
        watch.reset();
        final result = await matcher.matchDay(games, _Picks());
        final match = watch.elapsedMicroseconds;
        for (final g in games) {
          expect(
              result[SportsChannelPicks.eventKey(g)]!.first.channel.id, g.id);
          expect(result[SportsChannelPicks.eventKey(g)]!.first.reason,
              MatchReason.guide);
        }
        expect(guide.queries, 1);
        watch.reset();
        final cached = await matcher.matchDay(games, _Picks());
        final warm = watch.elapsedMicroseconds;
        expect(identical(result, cached), true);
        expect(guide.queries, 1);
        if (run > 0) {
          indexUs.add(index);
          matchUs.add(match);
          cachedUs.add(warm);
        }
      } finally {
        matcher.dispose();
      }
    }
    int median(List<int> values) => (values..sort())[values.length ~/ 2];
    debugPrint(
        'TEAM_MATCH_BENCH channels=20000 guide_rows=5000 fixtures=${_fixtures.length} '
        'index_median_us=${median(indexUs)} match_median_us=${median(matchUs)} '
        'cached_median_us=${median(cachedUs)} match_samples_us=$matchUs');
  });
}
