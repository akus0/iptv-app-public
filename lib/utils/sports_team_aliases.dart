import 'sports_language.dart';

/// Full club identities and feed abbreviations are separate from nicknames.
/// A nickname needs an explicit fixture and corroborating league/opponent.
/// Keep clubs scoped to their competition; never globally replace a mascot.
class SportsClubAliases {
  const SportsClubAliases(this.names, this.nicknames,
      {this.feedNames = const []});
  final List<String> names;
  final List<String> nicknames;
  final List<String> feedNames;
}

// Official directories and maintenance rules: docs/development.md.
const _aLeague = [
  SportsClubAliases(
      ['Wellington Phoenix', 'Wellington Phoenix FC'], ['Phoenix'],
      feedNames: ['Wellington']),
  SportsClubAliases(['Brisbane Roar', 'Brisbane Roar FC'], ['Roar'],
      feedNames: ['Brisbane']),
  SportsClubAliases(
      ['Central Coast Mariners', 'Central Coast Mariners FC'], ['Mariners'],
      feedNames: ['Central Coast', 'CC Mariners']),
  SportsClubAliases(['Newcastle Jets'], ['Jets']),
  SportsClubAliases(['Perth Glory', 'Perth Glory FC'], ['Glory'],
      feedNames: ['Perth']),
  SportsClubAliases(['Melbourne Victory'], ['Victory'],
      feedNames: ['Melbourne V']),
  SportsClubAliases(['Melbourne City', 'Melbourne City FC'], [],
      feedNames: ['Melbourne C']),
  SportsClubAliases(['Western Sydney Wanderers', 'Western Sydney Wanderers FC'],
      ['Wanderers'],
      feedNames: ['Western Sydney']),
  SportsClubAliases(['Adelaide United', 'Adelaide United FC'], [],
      feedNames: ['Adelaide Utd']),
  SportsClubAliases(['Canberra United'], [], feedNames: ['Canberra Utd']),
  SportsClubAliases(['Sydney FC'], []),
  SportsClubAliases(['Auckland FC'], [], feedNames: ['Auckland']),
  SportsClubAliases(['Macarthur FC'], [], feedNames: ['Macarthur']),
  SportsClubAliases(['Western United', 'Western United FC'], []),
];

const _jLeague = [
  SportsClubAliases(['Kashima Antlers'], ['Antlers'], feedNames: ['Kashima']),
  SportsClubAliases(['Mito Hollyhock'], ['Hollyhock'], feedNames: ['Mito']),
  SportsClubAliases(['Urawa Red Diamonds', 'Urawa Reds'], ['Red Diamonds'],
      feedNames: ['Urawa']),
  SportsClubAliases(['JEF United Chiba', 'JEF United Ichihara Chiba'], [],
      feedNames: ['JEF Utd Chiba']),
  SportsClubAliases(['Kashiwa Reysol'], ['Reysol'], feedNames: ['Kashiwa']),
  SportsClubAliases(['FC Tokyo'], []),
  SportsClubAliases(['Tokyo Verdy'], ['Verdy']),
  SportsClubAliases(['Machida Zelvia', 'FC Machida Zelvia'], ['Zelvia'],
      feedNames: ['Machida']),
  SportsClubAliases(['Kawasaki Frontale'], ['Frontale'],
      feedNames: ['Kawasaki']),
  SportsClubAliases(['Yokohama F Marinos'], ['Marinos']),
  SportsClubAliases(['Shimizu S Pulse'], ['S Pulse'], feedNames: ['Shimizu']),
  SportsClubAliases(['Nagoya Grampus'], ['Grampus'], feedNames: ['Nagoya']),
  SportsClubAliases(['Kyoto Sanga', 'Kyoto Sanga FC'], ['Sanga'],
      feedNames: ['Kyoto']),
  SportsClubAliases(['Gamba Osaka'], ['Gamba']),
  SportsClubAliases(['Cerezo Osaka'], ['Cerezo']),
  SportsClubAliases(['Vissel Kobe'], ['Vissel']),
  SportsClubAliases(['Fagiano Okayama'], ['Fagiano'], feedNames: ['Okayama']),
  SportsClubAliases(['Sanfrecce Hiroshima'], ['Sanfrecce']),
  SportsClubAliases(['Avispa Fukuoka'], ['Avispa'], feedNames: ['A Fukuoka']),
  SportsClubAliases(['V Varen Nagasaki'], ['V Varen']),
];

// Official K League directory and native club names: docs/sports-matching-coverage.md.
// The scoreboard supplies compact English names; keep full native identities
// league-scoped so city names cannot become global aliases.
const _kLeague = [
  SportsClubAliases(['Jeju SK FC', '제주SK FC', '제주SKFC'], [],
      feedNames: ['JEJU']),
  SportsClubAliases(['FC Anyang', 'FC안양', 'FC 안양'], [], feedNames: ['ANYANG']),
  SportsClubAliases(['Seongnam FC', '성남FC', '성남 FC'], [],
      feedNames: ['SEONGNAM']),
  SportsClubAliases(['Daegu FC', '대구FC', '대구 FC'], [], feedNames: ['DAEGU']),
  SportsClubAliases(['Suwon FC', '수원FC', '수원 FC'], []),
  SportsClubAliases(
      ['Ansan Greeners FC', '안산 그리너스 FC', '안산그리너스FC', '안산 그리너스', '안산그리너스'], [],
      feedNames: ['ANSAN']),
  SportsClubAliases(['Gimhae FC2008', '김해FC2008', '김해 FC2008'], [],
      feedNames: ['GIMHAE']),
  SportsClubAliases(['Seoul E-Land FC', '서울 이랜드 FC', '서울이랜드FC'], [],
      feedNames: ['SEOUL E-LAND']),
  SportsClubAliases(
      ['Jeonnam Dragons FC', 'Jeonnam Dragons', '전남 드래곤즈', '전남드래곤즈'], [],
      feedNames: ['JEONNAM']),
];

// Full bilingual identities from B.LEAGUE's official club directory.
const _bLeague = [
  SportsClubAliases(['LEVANGA HOKKAIDO', 'レバンガ北海道'], []),
  SportsClubAliases(['SENDAI 89ERS', '仙台89ERS'], []),
  SportsClubAliases(['AKITA NORTHERN HAPPINETS', '秋田ノーザンハピネッツ'], []),
  SportsClubAliases(['IBARAKI ROBOTS', '茨城ロボッツ'], []),
  SportsClubAliases(['UTSUNOMIYA BREX', '宇都宮ブレックス'], []),
  SportsClubAliases(['GUNMA CRANE THUNDERS', '群馬クレインサンダーズ'], []),
  SportsClubAliases(['ALTIRI CHIBA', 'アルティーリ千葉'], []),
  SportsClubAliases(['CHIBA JETS', '千葉ジェッツ'], []),
  SportsClubAliases(['ALVARK TOKYO', 'アルバルク東京'], []),
  SportsClubAliases(['TOKYO SUNROCKERS', '東京サンロッカーズ'], []),
  SportsClubAliases(['KAWASAKI BRAVE THUNDERS', '川崎ブレイブサンダース'], []),
  SportsClubAliases(['YOKOHAMA B-CORSAIRS', '横浜ビー・コルセアーズ'], []),
  SportsClubAliases(['TOYAMA GROUSES', '富山グラウジーズ'], []),
  SportsClubAliases(['SHINSHU BRAVE WARRIORS', '信州ブレイブウォリアーズ'], []),
  SportsClubAliases(['SAN-EN NEOPHOENIX', '三遠ネオフェニックス'], []),
  SportsClubAliases(['SEAHORSES MIKAWA', 'シーホース三河'], []),
  SportsClubAliases(['NAGOYA DIAMOND DOLPHINS', '名古屋ダイヤモンドドルフィンズ'], []),
  SportsClubAliases(['SHIGA LAKES', '滋賀レイクス'], []),
  SportsClubAliases(['KYOTO HANNARYZ', '京都ハンナリーズ'], []),
  SportsClubAliases(['OSAKA EVESSA', '大阪エヴェッサ'], []),
  SportsClubAliases(['KOBE STORKS', '神戸ストークス'], []),
  SportsClubAliases(['SHIMANE SUSANOO MAGIC', '島根スサノオマジック'], []),
  SportsClubAliases(['HIROSHIMA DRAGONFLIES', '広島ドラゴンフライズ'], []),
  SportsClubAliases(['SAGA BALLOONERS', '佐賀バルーナーズ'], []),
  SportsClubAliases(['NAGASAKI VELCA', '長崎ヴェルカ'], []),
  SportsClubAliases(['RYUKYU GOLDEN KINGS', '琉球ゴールデンキングス'], []),
];

const _afl = [
  SportsClubAliases(['Adelaide Crows'], ['Crows'], feedNames: ['Adelaide']),
  SportsClubAliases(['Brisbane Lions'], ['Lions'], feedNames: ['Brisbane']),
  SportsClubAliases(['Carlton Blues'], ['Blues'], feedNames: ['Carlton']),
  SportsClubAliases(['Collingwood Magpies'], ['Magpies'],
      feedNames: ['Collingwood']),
  SportsClubAliases(['Essendon Bombers'], ['Bombers'], feedNames: ['Essendon']),
  SportsClubAliases(['Fremantle Dockers'], ['Dockers'],
      feedNames: ['Fremantle']),
  SportsClubAliases(['Geelong Cats'], ['Cats'], feedNames: ['Geelong']),
  SportsClubAliases(['Gold Coast Suns'], ['Suns'], feedNames: ['Gold Coast']),
  SportsClubAliases(['Greater Western Sydney Giants', 'GWS Giants'], ['Giants'],
      feedNames: ['Greater Western Sydney', 'GWS']),
  SportsClubAliases(['Hawthorn Hawks'], ['Hawks'], feedNames: ['Hawthorn']),
  SportsClubAliases(['Melbourne Demons'], ['Demons'], feedNames: ['Melbourne']),
  SportsClubAliases(['North Melbourne Kangaroos'], ['Kangaroos'],
      feedNames: ['North Melbourne']),
  SportsClubAliases(['Port Adelaide Power'], ['Power'],
      feedNames: ['Port Adelaide']),
  SportsClubAliases(['Richmond Tigers'], ['Tigers'], feedNames: ['Richmond']),
  SportsClubAliases(['St Kilda Saints'], ['Saints'], feedNames: ['St Kilda']),
  SportsClubAliases(['Sydney Swans'], ['Swans'], feedNames: ['Sydney']),
  SportsClubAliases(['West Coast Eagles'], ['Eagles'],
      feedNames: ['West Coast']),
  SportsClubAliases(['Western Bulldogs'], ['Bulldogs']),
];

const _npb = [
  SportsClubAliases(['Yomiuri Giants'], ['Giants'], feedNames: ['Yomiuri']),
  SportsClubAliases(['Hanshin Tigers'], ['Tigers'], feedNames: ['Hanshin']),
  SportsClubAliases(['Yokohama DeNA BayStars', 'DeNA BayStars'], ['BayStars'],
      feedNames: ['DeNA']),
  SportsClubAliases(['Hiroshima Toyo Carp', 'Hiroshima Carp'], ['Carp'],
      feedNames: ['Hiroshima']),
  SportsClubAliases(['Tokyo Yakult Swallows', 'Yakult Swallows'], ['Swallows'],
      feedNames: ['Yakult']),
  SportsClubAliases(['Chunichi Dragons'], ['Dragons'], feedNames: ['Chunichi']),
  SportsClubAliases(['Fukuoka SoftBank Hawks', 'SoftBank Hawks'], ['Hawks'],
      feedNames: ['SoftBank']),
  SportsClubAliases(
      ['Hokkaido Nippon Ham Fighters', 'Nippon Ham Fighters'], ['Fighters'],
      feedNames: ['Nippon Ham']),
  SportsClubAliases(['Chiba Lotte Marines', 'Lotte Marines'], ['Marines'],
      feedNames: ['Lotte']),
  SportsClubAliases(['Tohoku Rakuten Golden Eagles', 'Rakuten Golden Eagles'],
      ['Golden Eagles'],
      feedNames: ['Rakuten']),
  SportsClubAliases(['Orix Buffaloes'], ['Buffaloes'], feedNames: ['Orix']),
  SportsClubAliases(['Saitama Seibu Lions', 'Seibu Lions'], ['Lions'],
      feedNames: ['Seibu']),
];

const _kbo = [
  SportsClubAliases(['KIA Tigers'], ['Tigers'], feedNames: ['KIA']),
  SportsClubAliases(['Samsung Lions'], ['Lions'], feedNames: ['Samsung']),
  SportsClubAliases(['LG Twins'], ['Twins']),
  SportsClubAliases(['Doosan Bears'], ['Bears'], feedNames: ['Doosan']),
  SportsClubAliases(['KT Wiz'], [], feedNames: ['KT']),
  SportsClubAliases(['SSG Landers'], ['Landers'], feedNames: ['SSG']),
  SportsClubAliases(['Lotte Giants'], ['Giants'], feedNames: ['Lotte']),
  SportsClubAliases(['Hanwha Eagles'], ['Eagles'], feedNames: ['Hanwha']),
  SportsClubAliases(['NC Dinos'], ['Dinos']),
  SportsClubAliases(['Kiwoom Heroes'], ['Heroes'], feedNames: ['Kiwoom']),
];

const sportsLeagueClubAliases = <String, List<SportsClubAliases>>{
  'aus.1': _aLeague,
  'aus.w.1': _aLeague,
  'jpn.1': _jLeague,
  'kor.1': _kLeague,
  'kor.2': _kLeague,
  'australian-football.afl': _afl,
  'baseball.npb': _npb,
  'baseball.kbo': _kbo,
  'basketball.bleague': _bLeague,
};

final _indexes = <String, Map<String, SportsClubAliases>>{};

/// Lazy, exact lookups for the selected league, once per fixture. Ambiguous
/// feed names are excluded rather than choosing an arbitrary club.
SportsClubAliases? sportsClubAliases(String league, String normalizedName) {
  final clubs = sportsLeagueClubAliases[league];
  if (clubs == null) return null;
  final index = _indexes.putIfAbsent(league, () {
    final result = <String, SportsClubAliases>{};
    final ambiguous = <String>{};
    for (final club in clubs) {
      final normalized = SportsClubAliases(
        club.names.map(normalizeSportsName).toList(growable: false),
        club.nicknames.map(normalizeSportsName).toList(growable: false),
        feedNames: club.feedNames
            .map(normalizeSportsName)
            .where((name) => name.trim().length >= 3)
            .toList(growable: false),
      );
      for (final name in {...club.names, ...club.feedNames}) {
        final key = normalizeSportsName(name);
        if (result.containsKey(key) && !identical(result[key], normalized)) {
          ambiguous.add(key);
        } else {
          result[key] = normalized;
        }
      }
    }
    for (final key in ambiguous) {
      result.remove(key);
    }
    return result;
  });
  return index[normalizedName];
}
