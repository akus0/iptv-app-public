/// Verified full club identities used only by the native-language fallback.
/// Do not add bare cities, mascots, sponsor names or automatic transliterations.
/// Sources and scope are documented in docs/development.md.
const sportsNativeClubNames = <String, List<String>>{
  // J.LEAGUE's bilingual club directory. Preserve qualifiers after the name.
  'kashima antlers': ['鹿島アントラーズ'],
  'mito hollyhock': ['水戸ホーリーホック'],
  'urawa red diamonds': ['浦和レッズ'],
  'jef united chiba': ['ジェフユナイテッド千葉'],
  'kashiwa reysol': ['柏レイソル'],
  'women tokyo verdy': ['日テレ東京ヴェルディベレーザ'],
  'women sanfrecce hiroshima': ['サンフレッチェ広島レジーナ'],
  'fc tokyo': ['ＦＣ東京', 'FC東京'],
  'tokyo verdy': ['東京ヴェルディ'],
  'machida zelvia': ['ＦＣ町田ゼルビア', 'FC町田ゼルビア', '町田ゼルビア'],
  'kawasaki frontale': ['川崎フロンターレ'],
  'yokohama f marinos': ['横浜Ｆ・マリノス', '横浜F・マリノス'],
  'shimizu s pulse': ['清水エスパルス'],
  'nagoya grampus': ['名古屋グランパス'],
  'kyoto sanga': ['京都サンガF.C.', '京都サンガＦ.Ｃ.', '京都サンガ'],
  'gamba osaka': ['ガンバ大阪'],
  'cerezo osaka': ['セレッソ大阪'],
  'vissel kobe': ['ヴィッセル神戸'],
  'fagiano okayama': ['ファジアーノ岡山'],
  'sanfrecce hiroshima': ['サンフレッチェ広島'],
  'avispa fukuoka': ['アビスパ福岡'],
  'v varen nagasaki': ['Ｖ・ファーレン長崎', 'V・ファーレン長崎'],
  // Full K League club names; spaced and unspaced official renderings.
  'jeonbuk hyundai motors': ['전북 현대 모터스', '전북현대모터스', '전북 현대', '전북현대'],
  'daejeon hana citizen': ['대전 하나 시티즌', '대전하나시티즌'],
  'gwangju fc': ['광주FC', '광주 FC'],
  'gimcheon sangmu': ['김천상무프로축구단', '김천 상무', '김천상무'],
  'gyeongnam fc': ['경남FC', '경남 FC'],
  'hwaseong fc': ['화성FC', '화성 FC'],
  'gimpo fc': ['김포FC', '김포 FC'],
  'chungnam asan': ['충남아산프로축구단', '충남 아산', '충남아산'],
  // Complete baseball club identities from the NPB/KBO directories. Shared
  // sponsors, cities and mascots alone must never become global aliases.
  'yomiuri giants': ['読売ジャイアンツ'],
  'hanshin tigers': ['阪神タイガース'],
  'yokohama dena baystars': ['横浜DeNAベイスターズ'],
  'hiroshima toyo carp': ['広島東洋カープ'],
  'tokyo yakult swallows': ['東京ヤクルトスワローズ'],
  'chunichi dragons': ['中日ドラゴンズ'],
  'fukuoka softbank hawks': ['福岡ソフトバンクホークス'],
  'hokkaido nippon ham fighters': ['北海道日本ハムファイターズ'],
  'chiba lotte marines': ['千葉ロッテマリーンズ'],
  'tohoku rakuten golden eagles': ['東北楽天ゴールデンイーグルス'],
  'orix buffaloes': ['オリックス・バファローズ'],
  'saitama seibu lions': ['埼玉西武ライオンズ'],
  'samsung lions': ['삼성 라이온즈', '삼성라이온즈'],
  'kt wiz': ['KT 위즈', 'KT위즈'],
  'kia tigers': ['KIA 타이거즈', 'KIA타이거즈'],
  'lg twins': ['LG 트윈스', 'LG트윈스'],
  'doosan bears': ['두산 베어스', '두산베어스'],
  'ssg landers': ['SSG 랜더스', 'SSG랜더스'],
  'lotte giants': ['롯데 자이언츠', '롯데자이언츠'],
  'hanwha eagles': ['한화 이글스', '한화이글스'],
  'nc dinos': ['NC 다이노스', 'NC다이노스'],
  'kiwoom heroes': ['키움 히어로즈', '키움히어로즈'],
  // EASL's Japanese directory and the teams' official Chinese identities.
  'alvark tokyo': ['アルバルク東京'],
  'ryukyu golden kings': ['琉球ゴールデンキングス'],
  'busan kcc egis': ['釜山KCCイージス'],
  'hong kong eastern': ['香港イースタン'],
  'taipei fubon braves': ['台北富邦ブレーブス', '臺北富邦勇士', '台北富邦勇士'],
  'taoyuan pauian pilots': ['桃園パウイアン・パイロッツ', '桃園璞園領航猿'],
};

// Full club identities only. ESPN uses Ichihara-Chiba while J.LEAGUE's
// bilingual directory uses Chiba. Do not expand a bare city or "United".
const _soccerClubAliasGroups = [
  ['jef united ichihara chiba', 'jef united chiba', 'jef utd chiba'],
  // The club uses both names; never shorten this to the shared 'Red Star'.
  ['crvena zvezda', 'red star belgrade'],
];
final _soccerClubAliases = <String, List<String>>{
  for (final group in _soccerClubAliasGroups)
    for (final name in group)
      ' $name ': [for (final alias in group) ' $alias '],
};

/// Lookup once per fixture name, never per channel or guide row.
List<String> sportsSoccerClubAliases(String normalizedName) =>
    _soccerClubAliases[normalizedName] ?? const [];

// Regional spellings of complete identities. These use the contextual path:
// require a competition and explicit opponents, and reject extra squad words.
const _soccerFeedAliasGroups = [
  [
    'bayern munich',
    'fc bayern munich',
    'bayern munchen',
    'fc bayern munchen',
    'bayern muenchen',
    'fc bayern muenchen',
    'bayern monachium',
    'fc bayern monachium',
  ],
  [
    'internazionale',
    'internazionale milano',
    'fc internazionale milano',
    'inter milan',
    'inter milano',
  ],
  [
    '1 fc koln',
    '1 fc koeln',
    '1 fc cologne',
    'fc cologne',
  ],
];
final _soccerFeedAliases = <String, List<String>>{
  for (final group in _soccerFeedAliasGroups)
    for (final name in group)
      ' $name ': [for (final alias in group) ' $alias '],
};

List<String> sportsSoccerClubFeedAliases(String normalizedName) =>
    _soccerFeedAliases[normalizedName] ?? const [];
