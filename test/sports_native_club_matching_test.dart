import 'package:flutter_test/flutter_test.dart';
import 'package:nox_iptv/models/channel.dart';
import 'package:nox_iptv/models/epg_program.dart';
import 'package:nox_iptv/models/sports.dart';
import 'package:nox_iptv/services/sports_channel_matcher.dart';
import 'package:nox_iptv/services/sports_match_inputs.dart';
import 'package:nox_iptv/utils/sports_language.dart';
import 'package:nox_iptv/utils/sports_team_vocabulary.dart';
import 'package:nox_iptv/utils/sports_title_matcher.dart';

final _now = DateTime.utc(2026, 10, 31, 6);

class _Guide implements SportsMatchGuide {
  final rows = <EpgProgram>[];
  final queries = <List<String>>[];
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
  @override
  String? channelIdFor(SportsGame game) => null;
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
  test(
      'verified native names produce the same canonical identity in title filtering',
      () {
    for (final entry in sportsNativeClubNames.entries) {
      for (final alias in entry.value) {
        expect(normalizeSportsName(sportsLanguageText(alias)).trim(), entry.key,
            reason: alias);
        expect(SportsTitleMatcher([entry.key]).matches(alias), isTrue,
            reason: alias);
      }
    }
    for (final name in ['東京', '大阪', '전북', '대전', '台北', '勇士']) {
      expect(sportsLanguageText(name), name,
          reason: 'No city/mascot inference: $name');
    }
  });
  for (final (league, home, away, title, wrong) in [
    (
      'jpn.1',
      'Kashima Antlers',
      'Cerezo Osaka',
      'サッカー 鹿島アントラーズ対セレッソ大阪',
      'サッカー 鹿島アントラーズ対ガンバ大阪'
    ),
    (
      'jpn.1',
      'Kashiwa Reysol',
      'Urawa Red Diamonds',
      'サッカー 柏レイソル対浦和レッズ',
      'サッカー 鹿島アントラーズ対浦和レッズ'
    ),
    (
      'kor.1',
      'JEONBUK',
      'DAEJEON HANA',
      '축구 전북 현대 모터스 vs 대전 하나 시티즌',
      '축구 전북 현대 모터스 vs 광주FC'
    ),
    ('kor.1', 'GWANGJU', 'GIMCHEON', '축구 광주FC vs 김천상무', '축구 광주FC vs 김포FC'),
    ('kor.2', 'GYEONGNAM', 'HWASEONG', '축구 경남FC vs 화성FC', '축구 경남FC vs 김포FC'),
    ('kor.2', 'CHUNGNAM ASAN', 'GIMPO', '축구 충남아산 vs 김포FC', '축구 충남아산 vs 화성FC'),
    (
      'basketball.easl',
      'Alvark Tokyo',
      'Ryukyu Golden Kings',
      'バスケットボール アルバルク東京対琉球ゴールデンキングス',
      'バスケットボール アルバルク東京対釜山KCCイージス'
    ),
    (
      'basketball.easl',
      'Taipei Fubon Braves',
      'Taoyuan Pauian Pilots',
      '籃球 台北富邦勇士對桃園璞園領航猿',
      '籃球 台北富邦勇士 vs アルバルク東京'
    ),
  ]) {
    test(
        '$league $home finds native names and queried guide, rejects unrelated/expired evidence',
        () async {
      final guide = _Guide();
      final fixture = _game(league, home, away);
      guide.rows.addAll([
        EpgProgram(
            channelId: 'guide',
            title: title,
            start: _now,
            stop: _now.add(const Duration(hours: 2))),
        EpgProgram(
            channelId: 'wrong-guide',
            title: wrong,
            start: _now,
            stop: _now.add(const Duration(hours: 2))),
        EpgProgram(
            channelId: 'expired',
            title: title,
            start: _now.subtract(const Duration(hours: 3)),
            stop: _now.subtract(const Duration(hours: 1))),
      ]);
      final matcher = SportsChannelMatcher(guide, clock: () => _now);
      addTearDown(matcher.dispose);
      await matcher.prepare([
        _channel('name', title),
        _channel('guide', 'Event Feed 1'),
        _channel('wrong-guide', 'Event Feed 2'),
        _channel('expired', 'Event Feed 3'),
        _channel('wrong', wrong),
        _channel('replay', '再放送 $title'),
        _channel('women', '女子 $title'),
        if (fixture.league.soccer) ...[
          _channel('age', 'U18 $title'),
          _channel('youth', '$title ユース')
        ],
      ]);
      final matches =
          (await matcher.matchDay([fixture], _Picks())).values.single;
      expect(matches.map((m) => m.channel.id).toSet(), {'name', 'guide'});
      expect(matches.every((m) => m.isConfident), isTrue);
      expect(guide.queries.length, 1);
      expect(
          guide.queries.single
              .every((t) => !RegExp(r'[^\x00-\x7f]').hasMatch(t)),
          isTrue,
          reason: 'Native names must not enlarge fixture queries');
    });
  }
  test(
      'native women club suffixes cannot identify the corresponding mens fixture',
      () async {
    final guide = _Guide();
    final matcher = SportsChannelMatcher(guide, clock: () => _now);
    addTearDown(matcher.dispose);
    await matcher.prepare([
      _channel('women', '日テレ東京ヴェルディベレーザ対サンフレッチェ広島レジーナ'),
      _channel('men', '東京ヴェルディ対サンフレッチェ広島'),
    ]);
    final result = (await matcher.matchDay(
            [_game('jpn.1', 'Tokyo Verdy', 'Sanfrecce Hiroshima')], _Picks()))
        .values
        .single;
    expect(result.map((m) => m.channel.id), ['men']);
  });
  test('FC Tokyo short name does not select Tokyo Verdy in either script',
      () async {
    final fixture = SportsGame(
        id: 'tokyo',
        league: sportsLeagueById('jpn.1')!,
        start: _now,
        state: GameState.live,
        statusText: '',
        home: const SportsTeam(
            id: 'tokyo',
            name: 'FC Tokyo',
            shortName: 'Tokyo',
            abbreviation: 'TOK'),
        away: const SportsTeam(
            id: 'kashima',
            name: 'Kashima Antlers',
            shortName: 'Kashima',
            abbreviation: 'KAN'));
    final matcher = SportsChannelMatcher(_Guide(), clock: () => _now);
    addTearDown(matcher.dispose);
    await matcher.prepare([
      _channel('native', 'ＦＣ東京対鹿島アントラーズ'),
      _channel('english', 'FC Tokyo vs Kashima Antlers'),
      _channel('other-native', '東京ヴェルディ対鹿島アントラーズ'),
      _channel('other-english', 'Tokyo Verdy vs Kashima Antlers'),
    ]);
    final matches = (await matcher.matchDay([fixture], _Picks())).values.single;
    expect(matches.map((m) => m.channel.id).toSet(), {'native', 'english'});
  });
  for (final (school, other) in [
    ('Alabama', 'Alabama at Birmingham'),
    ('Maryland', 'Maryland Baltimore County'),
    ('Illinois', 'Illinois Chicago'),
    ('UNC', 'UNC Greensboro'),
    ('UNC', 'UNC Wilmington'),
  ]) {
    test('$school cannot borrow the identity of $other', () async {
      final matcher = SportsChannelMatcher(_Guide(), clock: () => _now);
      addTearDown(matcher.dispose);
      await matcher.prepare([
        _channel('correct', 'Basketball (M): $school vs Wisconsin'),
        _channel('other', 'Basketball (M): $other vs Wisconsin'),
      ]);
      final matches = (await matcher.matchDay([
        _game('basketball.mens-college-basketball', school, 'Wisconsin')
      ], _Picks()))
          .values
          .single;
      expect(matches.map((m) => m.channel.id), ['correct']);
    });
  }
  for (final (school, alias, wrong) in [
    ('UNC Greensboro', 'UNCG', 'UNC Wilmington'),
    ('UNC Wilmington', 'UNCW', 'UNC Greensboro'),
    ('UAB', 'Alabama at Birmingham', 'Alabama'),
    ('UMBC', 'Maryland Baltimore County', 'Maryland'),
    ('UIC', 'Illinois Chicago', 'Illinois'),
  ]) {
    test('college $school resolves $alias without accepting $wrong', () async {
      final guide = _Guide();
      final matcher = SportsChannelMatcher(guide, clock: () => _now);
      addTearDown(matcher.dispose);
      final fixture =
          _game('basketball.mens-college-basketball', school, 'Wisconsin');
      await matcher.prepare([
        _channel('name', 'Basketball (M): $alias vs Wisconsin'),
        _channel('wrong', 'Basketball (M): $wrong vs Wisconsin'),
        _channel('women', 'Basketball (W): $alias vs Wisconsin'),
        _channel('sport', 'Soccer (M): $alias vs Wisconsin'),
        _channel('opponent', 'Basketball (M): $alias vs Minnesota'),
        _channel('guide', 'Event Feed'),
      ]);
      guide.rows.add(EpgProgram(
          channelId: 'guide',
          title: 'Basketball (M): $alias vs Wisconsin',
          start: _now,
          stop: _now.add(const Duration(hours: 2))));
      final result =
          (await matcher.matchDay([fixture], _Picks())).values.single;
      expect(result.map((m) => m.channel.id).toSet(), {'name', 'guide'});
    });
  }
}
