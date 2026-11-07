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
  for (final fixture in [
    (
      'basketball.bleague',
      'LEVANGA HOKKAIDO',
      'SENDAI 89ERS',
      'レバンガ北海道',
      '仙台89ERS'
    ),
    (
      'basketball.bleague',
      'SENDAI 89ERS',
      'AKITA NORTHERN HAPPINETS',
      '仙台89ERS',
      '秋田ノーザンハピネッツ'
    ),
    (
      'basketball.bleague',
      'AKITA NORTHERN HAPPINETS',
      'IBARAKI ROBOTS',
      '秋田ノーザンハピネッツ',
      '茨城ロボッツ'
    ),
    (
      'basketball.bleague',
      'IBARAKI ROBOTS',
      'UTSUNOMIYA BREX',
      '茨城ロボッツ',
      '宇都宮ブレックス'
    ),
    (
      'basketball.bleague',
      'UTSUNOMIYA BREX',
      'GUNMA CRANE THUNDERS',
      '宇都宮ブレックス',
      '群馬クレインサンダーズ'
    ),
    (
      'basketball.bleague',
      'GUNMA CRANE THUNDERS',
      'ALTIRI CHIBA',
      '群馬クレインサンダーズ',
      'アルティーリ千葉'
    ),
    ('basketball.bleague', 'ALTIRI CHIBA', 'CHIBA JETS', 'アルティーリ千葉', '千葉ジェッツ'),
    ('basketball.bleague', 'CHIBA JETS', 'ALVARK TOKYO', '千葉ジェッツ', 'アルバルク東京'),
    (
      'basketball.bleague',
      'ALVARK TOKYO',
      'TOKYO SUNROCKERS',
      'アルバルク東京',
      '東京サンロッカーズ'
    ),
    (
      'basketball.bleague',
      'TOKYO SUNROCKERS',
      'KAWASAKI BRAVE THUNDERS',
      '東京サンロッカーズ',
      '川崎ブレイブサンダース'
    ),
    (
      'basketball.bleague',
      'KAWASAKI BRAVE THUNDERS',
      'YOKOHAMA B-CORSAIRS',
      '川崎ブレイブサンダース',
      '横浜ビー・コルセアーズ'
    ),
    (
      'basketball.bleague',
      'YOKOHAMA B-CORSAIRS',
      'TOYAMA GROUSES',
      '横浜ビー・コルセアーズ',
      '富山グラウジーズ'
    ),
    (
      'basketball.bleague',
      'TOYAMA GROUSES',
      'SHINSHU BRAVE WARRIORS',
      '富山グラウジーズ',
      '信州ブレイブウォリアーズ'
    ),
    (
      'basketball.bleague',
      'SHINSHU BRAVE WARRIORS',
      'SAN-EN NEOPHOENIX',
      '信州ブレイブウォリアーズ',
      '三遠ネオフェニックス'
    ),
    (
      'basketball.bleague',
      'SAN-EN NEOPHOENIX',
      'SEAHORSES MIKAWA',
      '三遠ネオフェニックス',
      'シーホース三河'
    ),
    (
      'basketball.bleague',
      'SEAHORSES MIKAWA',
      'NAGOYA DIAMOND DOLPHINS',
      'シーホース三河',
      '名古屋ダイヤモンドドルフィンズ'
    ),
    (
      'basketball.bleague',
      'NAGOYA DIAMOND DOLPHINS',
      'SHIGA LAKES',
      '名古屋ダイヤモンドドルフィンズ',
      '滋賀レイクス'
    ),
    (
      'basketball.bleague',
      'SHIGA LAKES',
      'KYOTO HANNARYZ',
      '滋賀レイクス',
      '京都ハンナリーズ'
    ),
    (
      'basketball.bleague',
      'KYOTO HANNARYZ',
      'OSAKA EVESSA',
      '京都ハンナリーズ',
      '大阪エヴェッサ'
    ),
    ('basketball.bleague', 'OSAKA EVESSA', 'KOBE STORKS', '大阪エヴェッサ', '神戸ストークス'),
    (
      'basketball.bleague',
      'KOBE STORKS',
      'SHIMANE SUSANOO MAGIC',
      '神戸ストークス',
      '島根スサノオマジック'
    ),
    (
      'basketball.bleague',
      'SHIMANE SUSANOO MAGIC',
      'HIROSHIMA DRAGONFLIES',
      '島根スサノオマジック',
      '広島ドラゴンフライズ'
    ),
    (
      'basketball.bleague',
      'HIROSHIMA DRAGONFLIES',
      'SAGA BALLOONERS',
      '広島ドラゴンフライズ',
      '佐賀バルーナーズ'
    ),
    (
      'basketball.bleague',
      'SAGA BALLOONERS',
      'NAGASAKI VELCA',
      '佐賀バルーナーズ',
      '長崎ヴェルカ'
    ),
    (
      'basketball.bleague',
      'NAGASAKI VELCA',
      'RYUKYU GOLDEN KINGS',
      '長崎ヴェルカ',
      '琉球ゴールデンキングス'
    ),
    (
      'basketball.bleague',
      'RYUKYU GOLDEN KINGS',
      'LEVANGA HOKKAIDO',
      '琉球ゴールデンキングス',
      'レバンガ北海道'
    ),
    ('kor.1', 'JEJU', 'GWANGJU', '제주SK FC', '광주FC'),
    ('kor.1', 'GIMCHEON', 'ANYANG', '김천상무', 'FC안양'),
    ('kor.2', 'SEONGNAM', 'DAEGU', '성남FC', '대구FC'),
    ('kor.2', 'SUWON FC', 'GYEONGNAM', '수원FC', '경남FC'),
    ('kor.2', 'GIMPO', 'ANSAN', '김포FC', '안산 그리너스 FC'),
    ('kor.2', 'GIMHAE', 'HWASEONG', '김해FC2008', '화성FC'),
    ('kor.2', 'SEOUL E-LAND', 'JEONNAM', '서울 이랜드 FC', '전남 드래곤즈'),
  ]) {
    test('official native club identities: ${fixture.$2} / ${fixture.$3}',
        () async {
      final guide = _Guide();
      final matcher = SportsChannelMatcher(guide, clock: () => _now);
      addTearDown(matcher.dispose);
      final game = _game(fixture.$1, fixture.$2, fixture.$3);
      final basketball = fixture.$1 == 'basketball.bleague';
      final title = '${game.league.name}: ${fixture.$4} vs ${fixture.$5}';
      final titles = {
        'right': title,
        'reverse': '${game.league.name}: ${fixture.$5} vs ${fixture.$4}',
        if (basketball)
          'nativeConnector': 'バスケットボール ${fixture.$4}対${fixture.$5}',
        'wrong': '${game.league.name}: ${fixture.$4} vs Unrelated FC',
        if (fixture.$2 == 'SUWON FC')
          'otherSuwon': 'K League 2: 수원 삼성 블루윙즈 vs ${fixture.$5}',
        if (fixture.$2 == 'SEOUL E-LAND')
          'otherSeoul': 'K League 2: FC서울 vs ${fixture.$5}',
        'youth': '${game.league.name}: ${fixture.$4} U18 vs ${fixture.$5} U18',
        'women':
            'Women ${basketball ? 'Basketball' : 'Soccer'}: ${fixture.$4} vs ${fixture.$5}',
        'replay': 'Replay $title',
        'otherSport':
            '${basketball ? 'Soccer' : 'Basketball'}: ${fixture.$4} vs ${fixture.$5}',
      };
      await matcher.prepare([
        for (final e in titles.entries) ...[
          _channel(e.key, 'Event feed'),
          _channel('name-${e.key}', e.value),
        ],
      ]);
      guide.rows.addAll([
        for (final e in titles.entries)
          EpgProgram(
              channelId: e.key,
              title: e.value,
              start: _now.subtract(const Duration(minutes: 10)),
              stop: _now.add(const Duration(hours: 2))),
      ]);
      final result = (await matcher
              .matchDay([game], _Picks(), includePossible: true, limit: 30))
          .values
          .single;
      expect(
          result.where((m) => m.isConfident).map((m) => m.channel.id).toSet(), {
        'right',
        'reverse',
        'name-right',
        'name-reverse',
        if (basketball) ...['nativeConnector', 'name-nativeConnector']
      });
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
