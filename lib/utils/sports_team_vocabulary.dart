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
];
final _soccerClubAliases = <String, List<String>>{
  for (final group in _soccerClubAliasGroups)
    for (final name in group)
      ' $name ': [for (final alias in group) ' $alias '],
};

/// Lookup once per fixture name, never per channel or guide row.
List<String> sportsSoccerClubAliases(String normalizedName) =>
    _soccerClubAliases[normalizedName] ?? const [];
