import 'package:flutter_test/flutter_test.dart';
import 'package:nox_iptv/models/channel.dart';
import 'package:nox_iptv/models/epg_program.dart';
import 'package:nox_iptv/models/sports.dart';
import 'package:nox_iptv/services/sports_channel_matcher.dart';
import 'package:nox_iptv/services/sports_match_inputs.dart';
import 'package:nox_iptv/utils/sports_title_matcher.dart';

final _now = DateTime.utc(2026, 11, 1, 5, 30);

class _Guide implements SportsMatchGuide {
  final rows = <EpgProgram>[];
  final queries = <List<String>>[];
  @override
  int get changeRevision => 0;
  @override
  DateTime? get lastUpdated => _now;
  @override
  EpgProgram? getCurrentProgram(String id) =>
      rows.where((p) => p.channelId == id && p.isNowPlaying(_now)).firstOrNull;
  @override
  EpgProgram? getNextProgram(String id) => null;
  @override
  Future<List<EpgProgram>> findProgrammesByTitle(
      DateTime from, DateTime to, List<String> terms) async {
    queries.add(terms);
    final titles = SportsTitleMatcher(terms, precomputeTransitions: true);
    return rows
        .where((p) =>
            p.stop.isAfter(from) &&
            p.start.isBefore(to) &&
            titles.matches(p.title))
        .toList();
  }

  @override
  Future<List<EpgProgram>> findSportsProgrammesForChannels(
          List<String> ids, DateTime from, DateTime to) async =>
      [];
}

class _Picks implements SportsMatchPicks {
  _Picks([this.selected]);
  final String? selected;
  @override
  String? channelIdFor(SportsGame game) => selected;
}

Channel _channel(String id, String name) => Channel(
    id: id,
    rawId: id,
    playlistId: 'test',
    name: name,
    group: 'Sports',
    url: 'https://example.invalid/feed');
SportsGame _game(String league, String home, String away) => SportsGame(
    id: '$league:$home:$away',
    league: sportsLeagueById(league)!,
    start: _now,
    state: GameState.live,
    statusText: '',
    home: SportsTeam(id: 'h', name: home, shortName: home, abbreviation: ''),
    away: SportsTeam(id: 'a', name: away, shortName: away, abbreviation: ''));
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final id in ['jpn.1', 'kor.1', 'kor.2']) {
    test('$id does not send generic football programmes to every fixture',
        () async {
      final guide = _Guide();
      final matcher = SportsChannelMatcher(guide, clock: () => _now);
      addTearDown(matcher.dispose);
      final game = _game(id, 'Aster United', 'Birch Athletic');
      await matcher.prepare([
        _channel('generic', 'Football Channel'),
        _channel('foreign', 'Premier League'),
        _channel('league', game.league.name),
        _channel('exact', 'Aster United v Birch Athletic'),
        _channel('broadcaster', 'Fixture Sports')
      ]);
      guide.rows.add(EpgProgram(
          channelId: 'foreign',
          title: 'Live Football',
          start: _now.subtract(const Duration(minutes: 30)),
          stop: _now.add(const Duration(hours: 2))));
      final result = (await matcher
              .matchDay([game], _Picks(), includePossible: true, limit: 30))
          .values
          .single;
      expect(result.map((m) => m.channel.id), containsAll(['league', 'exact']));
      expect(result.map((m) => m.channel.id), isNot(contains('generic')));
      expect(result.map((m) => m.channel.id), isNot(contains('foreign')));
      expect(result.singleWhere((m) => m.channel.id == 'exact').isConfident,
          isTrue);
      expect(result.singleWhere((m) => m.channel.id == 'league').isConfident,
          isFalse);
    });
  }
  for (final native in [false, true]) {
    test(
        'JEF scoreboard identity matches ${native ? 'Japanese' : 'English'} full club guide',
        () async {
      final guide = _Guide();
      final matcher = SportsChannelMatcher(guide, clock: () => _now);
      addTearDown(matcher.dispose);
      final game = SportsGame(
          id: 'jef',
          league: sportsLeagueById('jpn.1')!,
          start: _now,
          state: GameState.live,
          statusText: '',
          home: const SportsTeam(
              id: 'jef',
              name: 'JEF United Ichihara-Chiba',
              shortName: 'JEF Utd Chiba',
              abbreviation: 'JEF'),
          away: const SportsTeam(
              id: 'avf',
              name: 'Avispa Fukuoka',
              shortName: 'A Fukuoka',
              abbreviation: 'AVF'));
      final title =
          native ? 'ジェフユナイテッド千葉 対 アビスパ福岡' : 'JEF United Chiba v Avispa Fukuoka';
      await matcher.prepare([
        _channel('named', title),
        _channel('guide', 'Event 1'),
        _channel('wrong', 'JEF United Chiba v Gamba Osaka'),
        _channel('women', 'JEF United Chiba Ladies v Avispa Fukuoka Ladies'),
        _channel('youth', 'JEF United Chiba U18 v Avispa Fukuoka U18'),
        _channel('stale', '$title (2026-10-30)'),
        _channel('replay', 'Replay $title'),
        _channel('city', 'Chiba v Fukuoka')
      ]);
      guide.rows.add(EpgProgram(
          channelId: 'guide',
          title: title,
          start: _now.subtract(const Duration(minutes: 30)),
          stop: _now.add(const Duration(hours: 2))));
      final result = (await matcher
              .matchDay([game], _Picks(), includePossible: true, limit: 30))
          .values
          .single;
      expect(result.where((m) => m.isConfident).map((m) => m.channel.id),
          unorderedEquals(['named', 'guide']));
      expect(guide.queries.length, 1);
    });
  }
  test('listed Korean broadcaster and saved picks survive stricter fallback',
      () async {
    final guide = _Guide();
    final matcher = SportsChannelMatcher(guide, clock: () => _now);
    addTearDown(matcher.dispose);
    final game = SportsGame(
        id: 'official',
        league: sportsLeagueById('kor.1')!,
        start: _now,
        state: GameState.live,
        statusText: '',
        home: const SportsTeam(
            id: 'home', name: 'ULSAN', shortName: 'ULSAN', abbreviation: ''),
        away: const SportsTeam(
            id: 'away',
            name: 'GANGWON',
            shortName: 'GANGWON',
            abbreviation: ''),
        broadcasts: const ['JTBC SPORTS', 'COUPANGPLAY']);
    await matcher.prepare([
      _channel('linear', 'KR: JTBC SPORTS'),
      _channel('stream', 'KR: COUPANG PLAY PPV 1'),
      _channel('picked', 'Football Channel')
    ]);
    var result = (await matcher
            .matchDay([game], _Picks('picked'), includePossible: true))
        .values
        .single;
    expect(result.singleWhere((m) => m.channel.id == 'linear').reason,
        MatchReason.network);
    expect(result.singleWhere((m) => m.channel.id == 'picked').reason,
        MatchReason.pick);
    expect(result.map((m) => m.channel.id), isNot(contains('stream')));
    guide.rows.add(EpgProgram(
        channelId: 'linear',
        title: 'Live baseball: Aster v Birch',
        start: _now.subtract(const Duration(minutes: 10)),
        stop: _now.add(const Duration(hours: 2))));
    // A new instance avoids relying on a synthetic guide revision change.
    final changed = SportsChannelMatcher(guide, clock: () => _now);
    addTearDown(changed.dispose);
    await changed.prepare([_channel('linear', 'KR: JTBC SPORTS')]);
    result = (await changed.matchDay([game], _Picks(), includePossible: true))
        .values
        .single;
    expect(result, isEmpty);
  });
  test('unrelated league keeps its existing optional sport suggestions',
      () async {
    final matcher = SportsChannelMatcher(_Guide(), clock: () => _now);
    addTearDown(matcher.dispose);
    await matcher.prepare([_channel('generic', 'Football Channel')]);
    final result = (await matcher.matchDay(
            [_game('eng.1', 'Aster United', 'Birch Athletic')], _Picks(),
            includePossible: true))
        .values
        .single;
    expect(result.single.reason, MatchReason.sport);
  });
  test('expired provider slots cannot override a current named event',
      () async {
    final guide = _Guide();
    final matcher = SportsChannelMatcher(guide, clock: () => _now);
    addTearDown(matcher.dispose);
    final game = _game('jpn.1', 'Yokohama F. Marinos', 'Kawasaki Frontale');
    await matcher.prepare([
      _channel('old', 'Event 20 | Tokyo tennis (2026-10-29)'),
      _channel('current',
          'Event 50 | Yokohama F. Marinos v Kawasaki Frontale (2026-11-01)')
    ]);
    guide.rows.add(EpgProgram(
        channelId: 'old',
        title: 'Yokohama F. Marinos v Kawasaki Frontale (2026-11-01)',
        start: DateTime.utc(2026, 10, 31, 22),
        stop: DateTime.utc(2026, 11, 1)));
    final result =
        (await matcher.matchDay([game], _Picks(), includePossible: true))
            .values
            .single;
    expect(result.map((m) => m.channel.id), ['current']);
  });
}
