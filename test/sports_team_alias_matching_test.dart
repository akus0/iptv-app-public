import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:nox_iptv/models/channel.dart';
import 'package:nox_iptv/models/epg_program.dart';
import 'package:nox_iptv/models/sports.dart';
import 'package:nox_iptv/services/sports_channel_matcher.dart';
import 'package:nox_iptv/services/sports_match_inputs.dart';
import 'package:nox_iptv/services/sports_service.dart';
import 'package:nox_iptv/services/epg_service.dart';
import 'package:nox_iptv/services/storage_service.dart';
import 'package:nox_iptv/utils/sports_team_aliases.dart';
import 'package:nox_iptv/utils/sports_title_matcher.dart';

final _now = DateTime.utc(2026, 11, 6, 8);

class _Guide implements SportsMatchGuide {
  final rows = <EpgProgram>[];
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
    final matcher = SportsTitleMatcher(terms, precomputeTransitions: true);
    return rows
        .where((p) =>
            p.stop.isAfter(from) &&
            p.start.isBefore(to) &&
            matcher.matches(p.title))
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

class _WorkerGuide extends EpgService {
  _WorkerGuide(super.storage, this.delegate);
  final _Guide delegate;
  @override
  EpgProgram? getCurrentProgram(String id) => null;
  @override
  EpgProgram? getNextProgram(String id) => null;
  @override
  Future<List<EpgProgram>> findProgrammesByTitle(
          DateTime from, DateTime to, List<String> terms,
          {List<String>? channelIds}) =>
      delegate.findProgrammesByTitle(from, to, terms);
  @override
  Future<List<EpgProgram>> findSportsProgrammesForChannels(
          List<String> ids, DateTime from, DateTime to) async =>
      [];
}

SportsTeam _team(String name,
        {List<String> aliases = const [], String? location}) =>
    SportsTeam(
        id: name,
        name: name,
        shortName: name,
        abbreviation: '',
        matchingNames: aliases,
        location: location);
SportsGame _game(String league, SportsTeam home, SportsTeam away) => SportsGame(
    id: 'fixture',
    league: sportsLeagueById(league)!,
    start: _now,
    state: GameState.live,
    statusText: 'Live',
    home: home,
    away: away);
Channel _channel(String id, String name) => Channel(
    id: id,
    rawId: id,
    playlistId: 'test',
    name: name,
    group: 'Sports',
    url: 'https://example.invalid/$id');

Future<Set<String>> _matches(SportsGame game, Map<String, String> titles,
    {bool background = false}) async {
  final guide = _Guide();
  _WorkerGuide? workerGuide;
  if (background) {
    SharedPreferences.setMockInitialValues({});
    final storage = StorageService();
    await storage.init();
    workerGuide = _WorkerGuide(storage, guide);
  }
  final matcher = background
      ? SportsChannelMatcher.background(workerGuide!, clock: () => _now)
      : SportsChannelMatcher(guide, clock: () => _now);
  try {
    for (final e in titles.entries) {
      guide.rows.add(EpgProgram(
          channelId: e.key,
          title: e.value,
          start: _now,
          stop: _now.add(const Duration(hours: 2))));
    }
    await matcher.prepare([
      for (final e in titles.entries) ...[
        _channel(e.key, 'Event Feed ${e.key}'),
        _channel('name-${e.key}', e.value),
      ]
    ]);
    final result = await matcher.matchDay([game], _Picks(), limit: 100);
    final found = result.values
        .expand((m) => m)
        .where((m) =>
            m.reason == MatchReason.guide || m.reason == MatchReason.name)
        .map((m) => m.channel.id)
        .toSet();
    final queries = guide.queries;
    final again = await matcher.matchDay([game], _Picks(), limit: 100);
    if (!background) expect(identical(result, again), true);
    expect({
      for (final entry in again.entries)
        entry.key: [
          for (final m in entry.value)
            (m.channel.id, m.reason, m.score, m.programme?.title)
        ],
    }, {
      for (final entry in result.entries)
        entry.key: [
          for (final m in entry.value)
            (m.channel.id, m.reason, m.score, m.programme?.title)
        ],
    });
    expect(guide.queries, queries,
        reason: 'Aliases must not defeat match caching');
    return found;
  } finally {
    matcher.dispose();
    workerGuide?.dispose();
  }
}

void main() {
  for (final fixture in [
    ('baseball.kbo', 'Samsung Lions', '삼성 라이온즈', 'KT Wiz', 'KT 위즈'),
    ('baseball.kbo', 'Kia Tigers', 'KIA 타이거즈', 'LG Twins', 'LG 트윈스'),
    ('baseball.kbo', 'Doosan Bears', '두산 베어스', 'SSG Landers', 'SSG 랜더스'),
    ('baseball.kbo', 'Lotte Giants', '롯데 자이언츠', 'Hanwha Eagles', '한화 이글스'),
    ('baseball.kbo', 'NC Dinos', 'NC 다이노스', 'Kiwoom Heroes', '키움 히어로즈'),
    ('baseball.npb', 'Yomiuri Giants', '読売ジャイアンツ', 'Hanshin Tigers', '阪神タイガース'),
    (
      'baseball.npb',
      'Yokohama DeNA BayStars',
      '横浜DeNAベイスターズ',
      'Hiroshima Toyo Carp',
      '広島東洋カープ'
    ),
    (
      'baseball.npb',
      'Tokyo Yakult Swallows',
      '東京ヤクルトスワローズ',
      'Chunichi Dragons',
      '中日ドラゴンズ'
    ),
    (
      'baseball.npb',
      'Fukuoka SoftBank Hawks',
      '福岡ソフトバンクホークス',
      'Hokkaido Nippon-Ham Fighters',
      '北海道日本ハムファイターズ'
    ),
    (
      'baseball.npb',
      'Chiba Lotte Marines',
      '千葉ロッテマリーンズ',
      'Tohoku Rakuten Golden Eagles',
      '東北楽天ゴールデンイーグルス'
    ),
    (
      'baseball.npb',
      'Orix Buffaloes',
      'オリックス・バファローズ',
      'Saitama Seibu Lions',
      '埼玉西武ライオンズ'
    ),
  ]) {
    test('regional baseball native opponents: ${fixture.$2} / ${fixture.$4}',
        () async {
      final league = fixture.$1 == 'baseball.kbo' ? 'KBO' : 'NPB';
      final pair = '${fixture.$3} vs ${fixture.$5}';
      final game = _game(fixture.$1, _team(fixture.$2), _team(fixture.$4));
      expect(
          await _matches(game, {
            'native': '$league: $pair',
            'compact':
                '$league: ${fixture.$3.replaceAll(' ', '')} vs ${fixture.$5.replaceAll(' ', '')}',
            'mixed': '$league: ${fixture.$3} vs ${fixture.$4}',
            'connector': league == 'NPB'
                ? '日本プロ野球 ${fixture.$3}対${fixture.$5}'
                : '한국프로야구 ${fixture.$3} 대 ${fixture.$5}',
            'wrong': '$league: ${fixture.$3} vs Unknown Club',
            'one': '$league: ${fixture.$3}',
            'replay': 'Replay $league: $pair',
            'highlight': 'Highlights $league: $pair',
            'stale': '$league: $pair 2026-10-31',
            'youth': '$league U18: $pair',
            'reserve': '$league ${league == 'KBO' ? '퓨처스리그' : 'ファーム'}: $pair',
            'wrongSport': 'Basketball $pair',
            'localReplay': '${league == 'KBO' ? '재방송' : '再放送'} $pair',
            'secondTeam': '$league ${league == 'KBO' ? '2군' : '二軍'} $pair',
            'englishReserve': '$league Futures: ${fixture.$2} vs ${fixture.$4}',
          }),
          {
            'native',
            'name-native',
            'compact',
            'name-compact',
            'mixed',
            'name-mixed',
            'connector',
            'name-connector'
          });
    });
  }
  test('regional baseball native names survive worker and cached replay',
      () async {
    expect(
        await _matches(
            _game('baseball.kbo', _team('Samsung Lions'), _team('KT Wiz')),
            {
              'right': 'KBO: 삼성 라이온즈 vs KT 위즈',
              'wrong': 'KBO: 삼성 라이온즈 vs LG 트윈스'
            },
            background: true),
        {'right', 'name-right'});
    expect(
        await _matches(
            _game('baseball.npb', _team('Yomiuri Giants'),
                _team('Hanshin Tigers')),
            {
              'right': '日本プロ野球 読売ジャイアンツ対阪神タイガース',
              'wrong': '日本プロ野球 読売ジャイアンツ対中日ドラゴンズ',
              'farm': 'NPB ファーム 読売ジャイアンツ対阪神タイガース'
            },
            background: true),
        {'right', 'name-right'});
  });
  test('B League native identities survive worker transfer and reject youth',
      () async {
    final found = await _matches(
        _game('basketball.bleague', _team('YOKOHAMA B-CORSAIRS'),
            _team('KOBE STORKS')),
        {
          'native': 'バスケットボール 横浜ビー・コルセアーズ対神戸ストークス',
          'wrong': 'バスケットボール 横浜ビー・コルセアーズ対東京サンロッカーズ',
          'youth': 'B.LEAGUE: 横浜ビー・コルセアーズ U18 vs 神戸ストークス U18',
          'englishYouth':
              'B.LEAGUE: Yokohama B-Corsairs U18 vs Kobe Storks U18',
          'otherSport': 'Soccer: 横浜ビー・コルセアーズ vs 神戸ストークス',
          'replay': 'Replay: 横浜ビー・コルセアーズ vs 神戸ストークス',
        },
        background: true);
    expect(found, {'native', 'name-native'});
  });

  TestWidgetsFlutterBinding.ensureInitialized();
  for (final background in [false, true]) {
    test(
        'Northwestern State shortened guide spellings keep the school distinct: worker=$background',
        () async {
      final fixture = _game('basketball.mens-college-basketball',
          _team('Northwestern State'), _team('Mississippi State'));
      final titles = {
        'full':
            'NCAA Men’s Basketball: Northwestern State vs Mississippi State',
        'short': 'NCAA Men’s Basketball: N\'Western St vs Mississippi St',
        'joined': 'NCAA Men’s Basketball: NWestern St vs Mississippi St',
        'wildcats': 'NCAA Men’s Basketball: Northwestern vs Mississippi State',
        'wrong': 'NCAA Men’s Basketball: N\'Western St vs Michigan State',
        'women': 'NCAA Women’s Basketball: N\'Western St vs Mississippi St',
        'replay':
            'NCAA Men’s Basketball: N\'Western St vs Mississippi St Replay',
        'other-sport': 'NCAA Baseball: N\'Western St vs Mississippi St',
      };
      final found = await _matches(fixture, titles, background: background);
      expect(
          found,
          containsAll(
              ['full', 'short', 'joined', 'name-short', 'name-joined']));
      for (final key in [
        'wildcats',
        'wrong',
        'women',
        'replay',
        'other-sport'
      ]) {
        expect(found, isNot(contains(key)));
        expect(found, isNot(contains('name-$key')));
      }
      final other = await _matches(
          _game('basketball.mens-college-basketball', _team('Northwestern'),
              _team('Mississippi State')),
          titles,
          background: background);
      expect(other, contains('wildcats'));
      for (final key in ['full', 'short', 'joined']) {
        expect(other, isNot(contains(key)));
        expect(other, isNot(contains('name-$key')));
      }
    });
  }
  for (final sample in [
    ('ger.1', 'Bayern Munich', 'Bayern München', 'Borussia Dortmund'),
    ('ger.1', 'Bayern Munich', 'FC Bayern Monachium', 'Borussia Dortmund'),
    ('uefa.champions', 'FC Bayern München', 'Bayern Munich', 'Arsenal'),
    ('ger.dfb_pokal', 'Bayern Munich', 'Bayern Muenchen', 'Union Berlin'),
    ('ita.1', 'Internazionale', 'Inter Milan', 'Lazio'),
    ('uefa.champions', 'Inter Milan', 'FC Internazionale Milano', 'Arsenal'),
    ('ger.1', 'FC Cologne', '1. FC Köln', 'Union Berlin'),
    ('ger.1', '1. FC Köln', 'FC Cologne', 'Union Berlin'),
  ]) {
    for (final background in [false, true]) {
      test(
          'verified translated club identity ${sample.$1}: ${sample.$2} / ${sample.$3} worker=$background',
          () async {
        final league = sportsLeagueById(sample.$1)!;
        final found = await _matches(
            _game(sample.$1, _team(sample.$2), _team(sample.$4)),
            {
              'original': '${league.name}: ${sample.$2} vs ${sample.$4}',
              'translated': '${league.name}: ${sample.$3} vs ${sample.$4}',
              'reversed': '${league.name}: ${sample.$4} vs ${sample.$3}',
              'unlabelled': '${sample.$3} vs ${sample.$4}',
              'wrong-opponent': '${league.name}: ${sample.$3} vs Other Club',
              'reserve': '${league.name}: ${sample.$3} II vs ${sample.$4}',
              'youth': '${league.name}: ${sample.$3} U19 vs ${sample.$4} U19',
              'women': '${league.name} Women: ${sample.$3} vs ${sample.$4}',
              'basketball':
                  '${league.name} Basketball: ${sample.$3} vs ${sample.$4}',
              'replay': '${league.name} Replay: ${sample.$3} vs ${sample.$4}',
              'prose':
                  '${league.name}: discussion of ${sample.$3} and ${sample.$4}',
            },
            background: background);
        expect(
            found,
            containsAll([
              'original',
              'translated',
              'reversed',
              'name-translated',
              'name-reversed'
            ]));
        for (final key in [
          'wrong-opponent',
          'unlabelled',
          'reserve',
          'youth',
          'women',
          'basketball',
          'replay',
          'prose'
        ]) {
          expect(found, isNot(contains(key)), reason: key);
          expect(found, isNot(contains('name-$key')), reason: key);
        }
      });
    }
  }
  test('translated identities never broaden into nearby clubs or bare cities',
      () async {
    for (final sample in [
      (
        'ger.1',
        'Bayern Munich',
        'Borussia Dortmund',
        ['Bayer Leverkusen', '1860 Munich', 'Bayern', 'Munich']
      ),
      (
        'ita.1',
        'Internazionale',
        'Lazio',
        ['AC Milan', 'Inter Miami', 'Inter Turku', 'Inter', 'Milan']
      ),
      (
        'ger.1',
        'FC Cologne',
        'Union Berlin',
        ['Viktoria Köln', 'Fortuna Köln', 'Cologne', 'Köln']
      ),
    ]) {
      final label = sportsLeagueById(sample.$1)!.name;
      final found =
          await _matches(_game(sample.$1, _team(sample.$2), _team(sample.$3)), {
        for (final name in sample.$4) name: '$label: $name vs ${sample.$3}',
      });
      expect(found, isEmpty);
    }
    expect(
        await _matches(_game('nba', _team('Internazionale'), _team('Lazio')), {
          'other-sport': 'NBA: Inter Milan vs Lazio',
        }),
        isEmpty);
  });
  const campuses = {
    'UC Davis': 'California Davis',
    'UC Irvine': 'California Irvine',
    'UC Riverside': 'California Riverside',
    'UC San Diego': 'California San Diego',
    'UC Santa Barbara': 'California Santa Barbara',
    'UCLA': 'California Los Angeles',
  };
  for (final campus in campuses.entries) {
    test('college campus spelling ${campus.key} preserves identity', () async {
      for (final league in [
        'basketball.mens-college-basketball',
        'basketball.womens-college-basketball',
        'baseball.college-baseball',
        'usa.ncaa.m.1',
        'usa.ncaa.w.1',
        'volleyball.womens-college-volleyball',
      ]) {
        final label = sportsLeagueById(league)!.name;
        final titles = {
          'original': '$label: ${campus.key} vs Pepperdine',
          'expanded': '$label: ${campus.value} vs Pepperdine',
          'university': '$label: University of ${campus.value} vs Pepperdine',
          'wrong-opponent': '$label: ${campus.value} vs Gonzaga',
          'replay': '$label: ${campus.value} vs Pepperdine Highlights',
          'parent': '$label: California vs Pepperdine',
          for (final other in campuses.entries)
            if (other.key != campus.key)
              'other-${other.key}': '$label: ${other.value} vs Pepperdine',
        };
        for (final identity in [campus.key, campus.value]) {
          final found = await _matches(
              _game(league, _team(identity), _team('Pepperdine')), titles);
          expect(found, containsAll(['original', 'expanded', 'university']),
              reason: '$league / $identity');
          expect(
              found.where((id) => !{
                    'original',
                    'expanded',
                    'university',
                    'name-original',
                    'name-expanded',
                    'name-university',
                  }.contains(id)),
              isEmpty,
              reason: '$league / $identity');
        }
      }
    });
  }
  test('campus aliases preserve sport and gender conflicts', () async {
    final found = await _matches(
        _game('basketball.womens-college-basketball', _team('UC Irvine'),
            _team('UCLA')),
        {
          'correct':
              "NCAA Women's Basketball: California Irvine vs California Los Angeles",
          'men':
              "NCAA Men's Basketball: California Irvine vs California Los Angeles",
          'other-sport':
              "NCAA Women's Volleyball: California Irvine vs California Los Angeles",
          'same-campus':
              "NCAA Women's Basketball: California Irvine vs California Irvine",
        });
    expect(found, {'correct', 'name-correct'});
  });
  test('California parent identity excludes other campuses', () async {
    final found = await _matches(
        _game(
            'basketball.mens-college-basketball',
            _team('California Golden Bears', location: 'California'),
            _team('Pepperdine')),
        {
          'original': 'NCAA Basketball: California vs Pepperdine',
          for (final campus in campuses.entries)
            campus.key: 'NCAA Basketball: ${campus.value} vs Pepperdine',
        });
    expect(found, {'original', 'name-original'});
  });
  test('campus aliases do not extend outside college sports', () async {
    final found = await _matches(
        _game('usa.1', _team('UC Irvine'), _team('Pepperdine')), {
      'wrong': 'MLS: California Irvine vs Pepperdine',
    });
    expect(found, isEmpty);
  });
  test('dotted club suffix keeps FC distinct from SC', () async {
    final found =
        await _matches(_game('ecu.1', _team('Manta F.C.'), _team('Macará')), {
      'original': 'Ecuadorian LigaPro: Manta F.C. vs Macará',
      'compact': 'Ecuadorian LigaPro: Manta FC vs Macará',
      'other': 'Ecuadorian LigaPro: Manta SC vs Macará',
      'bare': 'Ecuadorian LigaPro: Manta vs Macará',
    });
    expect(found, containsAll(['original', 'compact']));
    expect(found, isNot(contains('other')));
    expect(found, isNot(contains('bare')));
  });

  for (final league in ['uefa.champions', 'uefa.europa', 'uefa.europa.conf']) {
    for (final name in ['Crvena Zvezda', 'Red Star Belgrade']) {
      test(
          '$league: $name uses its verified full identity, not the French Red Star club',
          () async {
        final found = await _matches(
            _game(league, _team(name), _team("Inter Club d'Escaldes")), {
          'serbian': "Crvena Zvezda vs Inter Club d'Escaldes",
          'english': "Red Star Belgrade vs Inter Club d'Escaldes",
          'guide-format':
              "UEFA | 24 - Red Star Belgrade vs Inter Club d'Escaldes 17:45pm",
          'french': "Red Star FC 93 vs Inter Club d'Escaldes",
          'bare': "Red Star vs Inter Club d'Escaldes",
          'wrong': 'Red Star Belgrade vs Partizan',
          'other-sport':
              "Basketball: Red Star Belgrade vs Inter Club d'Escaldes",
          'youth': "Red Star Belgrade U19 vs Inter Club d'Escaldes U19",
          'women': "Women Soccer: Red Star Belgrade vs Inter Club d'Escaldes",
          'replay': "Red Star Belgrade vs Inter Club d'Escaldes Replay",
        });
        expect(found, containsAll(['serbian', 'english', 'guide-format']));
        for (final key in [
          'french',
          'bare',
          'wrong',
          'other-sport',
          'youth',
          'women',
          'replay'
        ]) {
          expect(found, isNot(contains(key)));
          expect(found, isNot(contains('name-$key')));
        }
      });
    }
  }

  test('dotted club initials preserve the full name and both opponents',
      () async {
    final found = await _matches(
        _game('usa.1', _team('D.C. United'), _team('Columbus Crew')), {
      'original': 'MLS: D.C. United vs Columbus Crew',
      'compact': 'MLS: DC United vs Columbus Crew',
      'combined': 'MLS: DC Utd vs Columbus Crew',
      'unrelated': 'MLS: DC Comics vs Columbus Crew',
      'wrong-opponent': 'MLS: DC United vs New York Red Bulls',
      'wrong-sport': 'Basketball: DC United vs Columbus Crew',
      'women': 'Women soccer: DC United vs Columbus Crew',
      'youth': 'MLS: DC United U21 vs Columbus Crew U21',
      'replay': 'MLS: DC Utd vs Columbus Crew Replay',
      'generic': 'MLS: United vs Columbus Crew',
    });
    expect(found, containsAll(['original', 'compact', 'combined']));
    for (final name in [
      'unrelated',
      'wrong-opponent',
      'wrong-sport',
      'women',
      'youth',
      'replay',
      'generic'
    ]) {
      expect(found, isNot(contains(name)));
      expect(found, isNot(contains('name-$name')));
    }
  });

  for (final sample in [
    (
      'eng.1',
      'Manchester United',
      'Manchester City',
      'Manchester Utd',
      'Premier League'
    ),
    ('sco.1', 'Dundee United', 'Dundee', 'Dundee Utd', 'Scottish Premiership'),
    ('fra.1', 'Paris Saint-Germain', 'Paris FC', 'Paris St-Germain', 'Ligue 1'),
    (
      'fra.coupe_de_france',
      'Saint-Pryvé Saint Hilaire',
      'Saint-Renan',
      'St-Pryvé St Hilaire',
      'Coupe de France'
    ),
  ]) {
    test(
        '${sample.$2} accepts a complete shortened spelling, never a city alone',
        () async {
      final found =
          await _matches(_game(sample.$1, _team(sample.$2), _team(sample.$3)), {
        'original': '${sample.$5}: ${sample.$2} vs ${sample.$3}',
        'short': '${sample.$5}: ${sample.$4} vs ${sample.$3}',
        'reverse': '${sample.$5}: ${sample.$3} vs ${sample.$4}',
        'no-competition': '${sample.$4} vs ${sample.$3}',
        'other': '${sample.$5}: ${sample.$4} vs Another Club',
        'other-club': '${sample.$5}: ${sample.$4} Reserves vs ${sample.$3}',
        'recap': '${sample.$5}: ${sample.$4} vs ${sample.$3} Highlights',
        'prose': '${sample.$5}: ${sample.$4} and ${sample.$3}',
      });
      expect(found, containsAll(['original', 'short', 'reverse']));
      for (final name in [
        'no-competition',
        'other',
        'other-club',
        'recap',
        'prose'
      ]) {
        expect(found, isNot(contains(name)));
        expect(found, isNot(contains('name-$name')));
      }
    });
  }

  test('school initial compaction does not lose campus qualifiers', () async {
    final found = await _matches(
        _game('college-football', _team('N.C. State'), _team('Duke')), {
      'original': 'College Football: N.C. State vs Duke',
      'compact': 'College Football: NC State vs Duke',
      'parent': 'College Football: NC vs Duke',
      'other': 'College Football: NC Central vs Duke',
    });
    expect(found, containsAll(['original', 'compact']));
    expect(found, isNot(contains('parent')));
    expect(found, isNot(contains('other')));
  });

  test(
      'United countries and bare dotted initials are not club spelling aliases',
      () async {
    final country = await _matches(
        _game('fifa.friendly', _team('United States'), _team('Canada')), {
      'original': 'International friendlies: United States vs Canada',
      'short': 'International friendlies: Utd States vs Canada',
    });
    expect(country, contains('original'));
    expect(country, isNot(contains('short')));
    final initials = await _matches(
        _game('eng.fa', _team('A.B.C.'), _team('Example Town')), {
      'original': 'FA Cup: A.B.C. vs Example Town',
      'short': 'FA Cup: ABC vs Example Town',
    });
    expect(initials, isNot(contains('short')));
  });

  for (final sample in [
    ('ind.1', 'FC GOA', 'GOA', 'FC Goa', 'Inter Kashi'),
    ('mex.w.1', 'Pumas UNAM', 'UNAM', 'UNAM', 'Querétaro'),
  ]) {
    test('directory short identity ${sample.$3} retains its opponent',
        () async {
      final league = sportsLeagueById(sample.$1)!;
      final home = SportsTeam(
          id: 'home',
          name: sample.$2,
          shortName: sample.$3,
          abbreviation: sample.$4);
      final found = await _matches(_game(sample.$1, home, _team(sample.$5)), {
        'full': '${league.name}: ${sample.$2} vs ${sample.$5}',
        'short': '${league.name}: ${sample.$3} vs ${sample.$5}',
        'wrong': '${league.name}: ${sample.$3} vs Another Club',
      });
      expect(found, containsAll(['full', 'short']));
      expect(found, isNot(contains('wrong')));
    });
  }

  test('a sport word in the full club identity does not change its sport',
      () async {
    final found = await _matches(
        _game('eng.w.fa', _team('Rugby Borough'), _team('SJR Worksop')), {
      'club': 'Rugby Borough vs SJR Worksop',
      'wrong-sport': 'Rugby: Rugby Borough vs SJR Worksop',
      'wrong-team': 'Rugby Town vs SJR Worksop',
    });
    expect(found, contains('club'));
    expect(found, isNot(contains('wrong-sport')));
    expect(found, isNot(contains('wrong-team')));
  });
  for (final sample in [
    ('arg.1', 'Independiente', 'Independiente Rivadavia'),
    ('conmebol.libertadores', 'Nacional', 'Nacional Potosi'),
    ('esp.copa_del_rey', 'Ceuta', 'Ceuta 6 de Junio'),
    ('uru.1', 'Cerro', 'Cerro Largo'),
  ]) {
    test('distinct club ${sample.$3} cannot match ${sample.$2}', () async {
      for (final name in [sample.$2, sample.$3]) {
        final found = await _matches(
            _game(sample.$1, _team(name), _team('Example United')), {
          'short': '${sample.$2} vs Example United',
          'long': '${sample.$3} vs Example United',
        });
        expect(found, contains(name == sample.$2 ? 'short' : 'long'));
        expect(found, isNot(contains(name == sample.$2 ? 'long' : 'short')));
      }
    });
  }

  test('ALW and ALM guide labels preserve squad identity', () async {
    for (final league in ['aus.1', 'aus.w.1']) {
      final women = league == 'aus.w.1';
      final found = await _matches(
          _game(league, _team('Perth Glory'), _team('Wellington')), {
        'women': 'ALW: Perth Glory v Phoenix',
        'men': 'ALM: Perth Glory v Phoenix',
        'wrong': 'ALW: Adelaide United v Phoenix',
        'replay': '${women ? "ALW" : "ALM"}: Perth Glory v Phoenix Replay',
      });
      expect(found, contains(women ? 'women' : 'men'));
      expect(found, isNot(contains(women ? 'men' : 'women')));
      expect(found, isNot(contains('wrong')));
      expect(found, isNot(contains('replay')));
    }
  });

  test('joining apostrophes use the same spelling rules as guide titles',
      () async {
    final found =
        await _matches(_game('chi.1', _team('La Serena'), _team("O'Higgins")), {
      'straight': "Chilean Primera Division: La Serena vs O'Higgins",
      'curly': 'Chilean Primera Division: La Serena vs O’Higgins',
      'joined': 'Chilean Primera Division: La Serena vs OHiggins',
      'wrong': 'Chilean Primera Division: La Serena vs Universidad de Chile',
    });
    expect(found, containsAll(['straight', 'curly', 'joined']));
    expect(found, isNot(contains('wrong')));
  });

  test('short team words require a competition and explicit opponents',
      () async {
    const sky = SportsTeam(
        id: 'sky', name: 'Chicago Sky', shortName: 'Sky', abbreviation: 'CHI');
    const sun = SportsTeam(
        id: 'sun',
        name: 'Connecticut Sun',
        shortName: 'Sun',
        abbreviation: 'CONN');
    final found = await _matches(_game('wnba', sky, sun), {
      'short': 'WNBA: Sky vs Sun',
      'full': 'WNBA: Chicago Sky vs Connecticut Sun',
      'no-league': 'Sky vs Sun',
      'prose': 'WNBA Sky and Sun season preview',
      'wrong': 'WNBA Sky vs Seattle Storm',
    });
    expect(found, containsAll(['short', 'full']));
    for (final key in ['no-league', 'prose', 'wrong']) {
      expect(found, isNot(contains(key)));
    }
  });

  test('Top 14 is a competition, while countdowns and replays remain excluded',
      () async {
    final found = await _matches(
        _game('rugby.270559', _team('Toulouse'), _team('Toulon')), {
      'live': 'Top 14: Toulouse vs Toulon',
      'replay': 'Top 14: Toulouse vs Toulon Replay',
      'highlights': 'Top 14: Toulouse vs Toulon Highlights',
      'countdown': 'Top 14 tries Toulouse vs Toulon',
      'top-ten': 'Top 10 Toulouse vs Toulon',
      'wrong': 'Top 14: Toulouse vs Bordeaux',
    });
    expect(found, contains('live'));
    for (final key in [
      'replay',
      'highlights',
      'countdown',
      'top-ten',
      'wrong'
    ]) {
      expect(found, isNot(contains(key)));
    }
  });

  test('NCAA softball is not confused with baseball despite its API path',
      () async {
    final found = await _matches(
        _game('baseball.college-softball', _team('Oklahoma'), _team('Florida')),
        {
          'softball': 'NCAA Softball: Oklahoma vs Florida',
          'baseball': 'NCAA Baseball: Oklahoma vs Florida',
          'wrong': 'NCAA Softball: Oklahoma vs Texas',
        });
    expect(found, contains('softball'));
    expect(found, isNot(contains('baseball')));
    expect(found, isNot(contains('wrong')));
  });

  test('an opponent code inside the other club cannot confirm the pair',
      () async {
    const home = SportsTeam(
        id: 'home',
        name: 'ESA Linas-Montlhery',
        shortName: 'Linas-Montlhery',
        abbreviation: 'LIN');
    const away = SportsTeam(
        id: 'away', name: 'ESAP Metz', shortName: 'Metz', abbreviation: 'ESA');
    final found = await _matches(_game('fra.coupe_de_france', home, away), {
      'full': 'Coupe de France: ESA Linas-Montlhery vs ESAP Metz',
      'codes': 'Coupe de France: LIN vs ESA',
      'wrong': 'Coupe de France: ESA Linas-Montlhery vs Entente Crest-Aouste',
    });
    expect(found, containsAll(['full', 'codes']));
    expect(found, isNot(contains('wrong')));
  });

  for (final pair in [
    ('Austin', 'Austin Peay'),
    ('Florida', 'Florida Gulf Coast'),
    ('Georgia', 'Georgia Southern'),
    ('Rutgers', 'Rutgers Newark'),
    ('North Carolina', 'North Carolina Wesleyan'),
    ('Wisconsin', 'Wisconsin Eau Claire'),
    ('Cal Poly', 'Cal Poly Pomona'),
    ('Texas A&M', 'Texas A&M Kingsville'),
    ('Utah', 'Utah Valley'),
  ]) {
    test('college qualifier distinguishes ${pair.$1} from ${pair.$2}',
        () async {
      for (final name in [pair.$1, pair.$2]) {
        final found = await _matches(
            _game('basketball.mens-college-basketball', _team(name),
                _team('Duke')),
            {
              'parent': 'NCAA Basketball: ${pair.$1} vs Duke',
              'qualified': 'NCAA Basketball: ${pair.$2} vs Duke',
            });
        expect(found, contains(name == pair.$1 ? 'parent' : 'qualified'));
        expect(
            found, isNot(contains(name == pair.$1 ? 'qualified' : 'parent')));
      }
    });
  }

  test(
      'nickname fixtures accept explicit broadcast separators, not label boundaries',
      () async {
    final found =
        await _matches(_game('aus.1', _team('Wellington'), _team('Brisbane')), {
      'dash': 'A-League: Phoenix - Roar',
      'en-dash': 'A-League: Phoenix – Brisbane Roar',
      'em-dash': 'A-League: Brisbane Roar — Phoenix',
      'at': 'A-League: Phoenix @ Roar',
      'decorated': 'Live A-League - Phoenix vs Brisbane Roar - HD',
      'label': 'A-League: Phoenix | Roar',
      'prose': 'A-League: Phoenix and Roar',
      'rival': 'A-League: Roar - Phoenix Rising',
      'two': 'A-League: Phoenix - Roar - Glory vs Jets',
      'replay': 'A-League Replay: Phoenix - Roar',
      'women': 'A-League Women: Phoenix - Roar',
      'youth': 'A-League U18: Phoenix - Roar',
    });
    expect(found, {
      for (final id in ['dash', 'en-dash', 'em-dash', 'at', 'decorated']) ...[
        id,
        'name-$id'
      ]
    });
  });
  test('mixed nicknames and full club names consume the complete opponents',
      () async {
    expect(
        await _matches(_game('aus.1', _team('Wellington'), _team('Brisbane')), {
          'mixed': 'A-League: Phoenix vs Brisbane Roar',
          'reverse': 'A-League: Brisbane Roar vs Phoenix',
          'other-mixed': 'A-League: Roar vs Wellington Phoenix',
          'fc': 'A-League: Phoenix vs Brisbane Roar FC',
          'rival': 'A-League: Phoenix vs Brisbane City',
          'rising': 'A-League: Brisbane Roar vs Phoenix Rising',
          'prefix': 'A-League: Ballarat Phoenix vs Brisbane Roar',
        }),
        {
          'mixed',
          'name-mixed',
          'reverse',
          'name-reverse',
          'other-mixed',
          'name-other-mixed',
          'fc',
          'name-fc'
        });
  });

  test('verified short feed names also work in the guide', () async {
    for (final (league, home, away, title) in [
      (
        'aus.1',
        'Central Coast Mariners',
        'Melbourne City',
        'A-League: CC Mariners vs Melbourne C'
      ),
      (
        'aus.1',
        'Adelaide United',
        'Melbourne Victory',
        'A-League: Adelaide Utd vs Melbourne V'
      ),
      (
        'baseball.npb',
        'Yokohama DeNA BayStars',
        'Hokkaido Nippon-Ham Fighters',
        'NPB: DeNA vs Nippon-Ham'
      ),
      ('baseball.kbo', 'KIA Tigers', 'Samsung Lions', 'KBO: KIA vs Samsung'),
    ]) {
      expect(
          await _matches(
              _game(league, _team(home), _team(away)), {'right': title}),
          {'right', 'name-right'},
          reason: title);
    }
    expect(
        await _matches(
            _game('aus.1', _team('Melbourne City'), _team('Adelaide United')), {
          'rival': 'A-League: Melbourne V vs Adelaide Utd',
          'ambiguous': 'A-League: Melbourne vs Adelaide Utd',
          'unscoped': 'Melbourne C vs Adelaide Utd'
        }),
        isEmpty);
    expect(
        await _matches(
            _game('baseball.kbo', _team('LG Twins'), _team('KT Wiz')),
            {'ambiguous': 'KBO: LG vs KT'}),
        isEmpty);
  });
  test('worker transports aliases and invalidates only changed event evidence',
      () async {
    SharedPreferences.setMockInitialValues({});
    final storage = StorageService();
    await storage.init();
    final delegate = _Guide()
      ..rows.add(EpgProgram(
          channelId: 'one',
          title: 'NBA: Lakers vs Celtics',
          start: _now,
          stop: _now.add(const Duration(hours: 2))));
    final guide = _WorkerGuide(storage, delegate)..lastUpdated = _now;
    addTearDown(guide.dispose);
    final worker = SportsChannelMatcher.background(guide, clock: () => _now);
    addTearDown(worker.dispose);
    await worker.prepare([_channel('one', 'Event Feed 1')]);
    final original =
        _game('nba', _team('Los Angeles Lakers'), _team('Boston Celtics'));
    final enriched = _game(
        'nba',
        _team('Los Angeles Lakers', aliases: ['Lakers']),
        _team('Boston Celtics', aliases: ['Celtics']));
    for (var i = 0; i < 3; i++) {
      final missed = await worker.matchDay([original], _Picks());
      expect(
          missed.values.expand((m) => m).where((m) => m.isConfident), isEmpty);
      final found = await worker.matchDay([enriched], _Picks());
      expect(found.values.single.single.channel.id, 'one');
      expect(found.values.single.single.reason, MatchReason.guide);
    }
    expect(delegate.queries, lessThanOrEqualTo(2));
  });
  test('Wellington / Phoenix works in both EPG retrieval and channel names',
      () async {
    final found =
        await _matches(_game('aus.1', _team('Wellington'), _team('Brisbane')), {
      'right': 'A-League: Phoenix vs Roar',
      'reverse': 'A-League: Roar v Phoenix',
      'full': 'Wellington Phoenix vs Brisbane Roar',
      'other': 'A-League: Phoenix vs Glory',
      'unscoped': 'Phoenix vs Roar',
      'prose': 'A-League: Phoenix and Roar news',
      'other-club': 'A-League: Phoenix Rising vs Roar',
      'other-club-reverse': 'A-League: Roar vs Phoenix Rising',
      'other-prefix': 'A-League: Ballarat Phoenix vs Roar',
      'multiple-fixtures': 'A-League: Phoenix vs Roar and Glory vs Jets',
      'wrong-sport': 'NBA basketball: Phoenix vs Roar',
      'women': 'A-League Women: Phoenix vs Roar',
      'youth': 'A-League U18: Phoenix vs Roar',
      'replay': 'A-League replay: Phoenix vs Roar',
    });
    expect(found, {
      'right',
      'name-right',
      'reverse',
      'name-reverse',
      'full',
      'name-full'
    });
  });

  test('same-city rivals are not inferred from a city', () async {
    expect(
        await _matches(
            _game('aus.1', _team('Melbourne City'), _team('Sydney FC')), {
          'right': 'A-League: Melbourne City FC vs Sydney FC',
          'rival': 'A-League: Victory vs Sydney FC',
          'ambiguous': 'A-League: Melbourne vs Sydney FC'
        }),
        {'right', 'name-right'});
    expect(
        await _matches(
            _game('jpn.1', _team('Gamba Osaka'), _team('Kashima Antlers')), {
          'right': 'J1 League: Gamba vs Antlers',
          'rival': 'J1 League: Cerezo vs Antlers',
          'ambiguous': 'J1 League: Osaka vs Antlers'
        }),
        {'right', 'name-right'});
  });

  test('aliases do not cross competition scopes', () async {
    expect(
        await _matches(_game('eng.1', _team('Wellington'), _team('Brisbane')),
            {'wrong': 'Premier League: Phoenix vs Roar'}),
        isEmpty);
  });

  test('shared API mascots, cities and generic soccer nicknames stay excluded',
      () async {
    expect(
        await _matches(
            _game(
                'college-football',
                _team('Georgia Bulldogs', aliases: ['Bulldogs']),
                _team('Auburn Tigers', aliases: ['Tigers'])),
            {'wrong': 'NCAA Football: Bulldogs vs Tigers'}),
        isEmpty);
    expect(
        await _matches(
            _game('eng.1', _team('Liverpool', aliases: ['Reds']),
                _team('Arsenal', aliases: ['Gunners'])),
            {'wrong': 'Premier League: Reds vs Gunners'}),
        isEmpty);
    expect(
        await _matches(
            _game(
                'nba',
                _team('Los Angeles Lakers',
                    aliases: ['Los Angeles'], location: 'Los Angeles'),
                _team('Boston Celtics')),
            {'wrong': 'NBA: Los Angeles vs Boston Celtics'}),
        isEmpty);
  });

  test('professional scoreboard names need competition and an explicit pair',
      () async {
    final game = _game('nba', _team('Los Angeles Lakers', aliases: ['Lakers']),
        _team('Boston Celtics', aliases: ['Celtics']));
    expect(
        await _matches(game, {
          'right': 'NBA: Lakers vs Celtics',
          'prose': 'NBA: Lakers and Celtics news',
          'unscoped': 'Lakers vs Celtics',
          'other': 'NBA: Lakers vs Hawks',
        }),
        {'right', 'name-right'});
  });

  test('scoreboard retains bounded typed aliases without changing labels', () {
    Map<String, Object?> side(String which, Map<String, Object?> team) =>
        {'homeAway': which, 'team': team};
    final games = parseEspnScoreboard((
      jsonEncode({
        'events': [
          {
            'id': 'metadata',
            'date': _now.toIso8601String(),
            'competitions': [
              {
                'competitors': [
                  side('home', {
                    'id': 'h',
                    'displayName': 'Los Angeles Lakers',
                    'shortDisplayName': 'LA Lakers',
                    'name': 'Lakers',
                    'nickname': 'Los Angeles',
                    'location': 'Los Angeles'
                  }),
                  side('away', {
                    'id': 'a',
                    'displayName': 'Boston Celtics',
                    'name': ['invalid'],
                    'shortDisplayName': 'Celtics',
                    'nickname': 'x' * 121
                  }),
                ]
              }
            ],
          }
        ]
      }),
      sportsLeagueById('nba')!
    ));
    expect(games.single.home.name, 'Los Angeles Lakers');
    expect(games.single.home.shortName, 'LA Lakers');
    expect(games.single.home.matchingNames, ['Lakers']);
    expect(games.single.away.matchingNames, isEmpty);
    final original =
        _game('nba', _team('Los Angeles Lakers'), _team('Boston Celtics'));
    final enriched = _game(
        'nba',
        _team('Los Angeles Lakers', aliases: ['Lakers']),
        _team('Boston Celtics'));
    expect(SportsChannelMatcher.matchingIdentity(original, _Picks()),
        isNot(SportsChannelMatcher.matchingIdentity(enriched, _Picks())));
  });

  for (final entry in sportsLeagueClubAliases.entries) {
    final league = sportsLeagueById(entry.key);
    if (league == null) continue;
    for (final club in entry.value) {
      final shortNames = club.feedNames.where((name) => name.length >= 3);
      if (shortNames.isEmpty) continue;
      final opponent = entry.value.firstWhere((c) => !identical(c, club));
      test(
          '${entry.key}: ${club.names.first} short forms work in guide in both orders',
          () async {
        final titles = <String, String>{};
        for (final (i, shortName) in shortNames.indexed) {
          titles['forward-$i'] =
              '${league.name}: $shortName vs ${opponent.names.first}';
          titles['reverse-$i'] =
              '${league.name}: ${opponent.names.first} vs $shortName';
        }
        final found = await _matches(
            _game(entry.key, _team(club.names.first),
                _team(opponent.names.first)),
            titles);
        expect(found, {
          for (final key in titles.keys) ...[key, 'name-$key']
        });
      });
    }
    for (final club in entry.value.where((c) => c.nicknames.isNotEmpty)) {
      final opponent = entry.value.firstWhere((c) => !identical(c, club));
      test('${entry.key}: ${club.names.first} nickname retrieves exact guide',
          () async {
        final home = club.feedNames.where((s) => s.length >= 4).firstOrNull ??
            club.names.first;
        final found = await _matches(
            _game(entry.key, _team(home), _team(opponent.names.first)), {
          'right':
              '${league.name}: ${club.nicknames.first} vs ${opponent.names.first}',
          'wrong': '${league.name}: ${club.nicknames.first} vs Unrelated Club'
        });
        expect(found, {'right', 'name-right'});
      });
    }
  }
}
