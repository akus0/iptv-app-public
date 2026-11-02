import 'dart:typed_data';

import 'sports_team_vocabulary.dart';

/// Local broadcast vocabulary, not a general translation engine. Only evidence
/// text is canonicalised; programme titles shown to viewers stay unchanged.
/// Long phrases win so table tennis/field hockey keep their sport identity.
const _words = <String, List<String>>{
  'table tennis': [
    'tenis de mesa',
    'tênis de mesa',
    'tennis de table',
    'tennis da tavolo',
    'tischtennis',
    'tafeltennis',
    'tenis stołowy',
    'настольный теннис',
    '卓球',
    '乒乓球',
    '탁구',
    'เทเบิลเทนนิส'
  ],
  'american football': [
    'fútbol americano',
    'futbol americano',
    'futebol americano',
    'football américain',
    'американский футбол',
    'futbol amerykański',
    'アメリカンフットボール',
    '美式足球',
    '미식축구'
  ],
  'field hockey': [
    'hockey sur gazon',
    'hockey sobre hierba',
    'hockey su prato',
    'feldhockey',
    '曲棍球',
    '필드하키'
  ],
  'ice hockey': [
    'hockey sur glace',
    'hockey sobre hielo',
    'hockey su ghiaccio',
    'eishockey',
    'lední hokej',
    'アイスホッケー',
    '冰球',
    '아이스하키'
  ],
  'tennis': [
    'tenis',
    'tênis',
    'tenisz',
    'теннис',
    'テニス',
    '网球',
    '網球',
    '테니스',
    'เทนนิส'
  ],
  'soccer': [
    'fútbol',
    'futbol',
    'futebol',
    'fußball',
    'fussball',
    'voetbal',
    'piłka nożna',
    'футбол',
    'サッカー',
    '足球',
    '축구',
    'ฟุตบอล'
  ],
  'basketball': [
    'baloncesto',
    'basquetebol',
    'básquetbol',
    'basquetbol',
    'pallacanestro',
    'koszykówka',
    'košarka',
    'kosarka',
    'баскетбол',
    'バスケットボール',
    '篮球',
    '籃球',
    '농구',
    'บาสเกตบอล',
    'บาสเก็ตบอล'
  ],
  'volleyball': [
    'voleibol',
    'vôlei',
    'volei',
    'pallavolo',
    'siatkówka',
    'волейбол',
    'バレーボール',
    '排球',
    '배구',
    'วอลเลย์บอล'
  ],
  'kbo baseball': ['한국프로야구', '한국 프로야구', '韓国プロ野球', '韓國職棒', '韩国职棒'],
  'npb baseball': ['日本プロ野球', '日本職棒', '日本职棒', 'プロ野球'],
  'cpbl baseball': ['中華職棒', '中华职棒'],
  'baseball': [
    'béisbol',
    'beisbol',
    'beisebol',
    'бейсбол',
    '野球',
    '棒球',
    '야구',
    'เบสบอล'
  ],
  'badminton': ['bádminton', 'бадминтон', 'バドミントン', '羽毛球', '배드민턴', 'แบดมินตัน'],
  'rugby': ['râguebi', 'регби', 'ラグビー', '럭비', 'รักบี้'],
  'golf': ['гольф', 'ゴルフ', '高尔夫', '高爾夫', '골프', 'กอล์ฟ'],
  'boxing': [
    'boxeo',
    'boxe',
    'pugilato',
    'boks',
    'бокс',
    'ボクシング',
    '拳击',
    '拳擊',
    '복싱'
  ],
  'motorsport': [
    'automovilismo',
    'automobilismo',
    'автоспорт',
    'モータースポーツ',
    '赛车',
    '賽車'
  ],
  'cycling': [
    'ciclismo',
    'radsport',
    'wielrennen',
    'велоспорт',
    'サイクリング',
    '自行车',
    '自行車',
    '사이클'
  ],
  'handball': [
    'balonmano',
    'pallamano',
    'piłka ręczna',
    'гандбол',
    'ハンドボール',
    '手球',
    '핸드볼'
  ],
  'swimming': [
    'natación',
    'natacion',
    'natação',
    'natation',
    'nuoto',
    'schwimmen',
    'плавание',
    '水泳',
    '游泳',
    '수영'
  ],
  'australian open': [
    'open de australia',
    'abierto de australia',
    'open da austrália',
    '全豪オープン',
    '澳大利亚网球公开赛',
    '澳網',
    '澳网',
    '호주 오픈'
  ],
  'roland garros': [
    'french open',
    'internationaux de france',
    '全仏オープン',
    '法国网球公开赛',
    '法網',
    '法网',
    '프랑스 오픈'
  ],
  'wimbledon': ['ウィンブルドン', '温布尔登', '溫布頓', '윔블던'],
  'us open': [
    'abierto de estados unidos',
    '全米オープン',
    '美国网球公开赛',
    '美國網球公開賽',
    '미국 오픈'
  ],
  'doubles': [
    'dobles',
    'duplas',
    'doppio',
    'doppel',
    'парный разряд',
    'ダブルス',
    '双打',
    '雙打',
    '복식'
  ],
  'juniors': ['juniores', 'junioren', 'ジュニア', '주니어'],
  'futsal': [
    'fútbol sala',
    'futbol sala',
    'futebol de salão',
    'мини-футбол',
    'футзал',
    'フットサル',
    '풋살'
  ],
  'centre court': [
    'pista central',
    'cancha central',
    'court central',
    'センターコート',
    '센터 코트'
  ],
  'live': [
    'en directo',
    'en vivo',
    'ao vivo',
    'en direct',
    'in diretta',
    'ao direto',
    'na żywo',
    'na zywo',
    'canlı yayın',
    'canli yayin',
    'прямой эфир',
    'прямая трансляция',
    '生中継',
    '生放送',
    '现场直播',
    '現場直播',
    '直播',
    '생중계',
    '생방송',
    'ถ่ายทอดสด'
  ],
  'replay': [
    'repetición',
    'repeticion',
    'rediffusion',
    'wiederholung',
    'herhaling',
    'reapresentação',
    'reapresentacao',
    'reexibição',
    'reexibicao',
    'repetição',
    'repeticao',
    'replica',
    'powtórka',
    'powtorka',
    'tekrar',
    'повтор',
    'повторение',
    '再放送',
    '再放送版',
    '録画放送',
    '録画中継',
    '重播',
    '回放',
    '非直播',
    '재방송',
    '녹화중계',
    'ย้อนหลัง',
    'รีรัน',
    'เทปบันทึกการแข่งขัน',
    'บันทึกการแข่งขัน'
  ],
  'news': [
    'noticias',
    'actualités',
    'actualites',
    'notizie',
    'nachrichten',
    'nieuws',
    'wiadomości',
    'новости',
    'ニュース',
    '新闻',
    '新聞',
    '뉴스'
  ],
  'documentary': [
    'documental',
    'documentário',
    'documentario',
    'documentaire',
    'dokumentation',
    'документальный фильм',
    'ドキュメンタリー',
    '纪录片',
    '紀錄片',
    '다큐멘터리'
  ],
  'movie': ['película', 'pelicula', 'filme', '映画', '电影', '電影', '영화'],
  'interview': [
    'entrevista',
    'entrevistas',
    'intervista',
    'интервью',
    'インタビュー',
    '인터뷰'
  ],
  'press conference': [
    'rueda de prensa',
    'conférence de presse',
    'pressekonferenz',
    'conferenza stampa',
    'пресс-конференция',
    '記者会見',
    '新闻发布会',
    '기자회견'
  ],
  'preview': ['previa', 'prévia', 'vorschau', 'anteprima'],
  'highlights': [
    'resumen',
    'resúmenes',
    'resumos',
    'resumo',
    'résumé',
    'résumés',
    'melhores momentos',
    'meilleurs moments',
    'zusammenfassung',
    'samenvatting',
    'sintesi',
    'skrót meczu',
    'skrot meczu',
    'özet',
    'ozet',
    'обзор матча',
    'обзор',
    'ハイライト',
    '精彩集锦',
    '精彩集錦',
    '集锦',
    '集錦',
    '하이라이트',
    'ไฮไลท์',
    'ไฮไลต์'
  ],
  'women': [
    'femenino',
    'femenina',
    'femenil',
    'feminino',
    'feminina',
    'féminin',
    'féminine',
    'feminin',
    'feminine',
    'femminile',
    'frauen',
    'damen',
    'vrouwen',
    'kobiet',
    'женщины',
    'женский',
    '女子',
    'レディース',
    '여자'
  ],
  'youth': ['ユース', '유소년'],
  'men': [
    'masculino',
    'masculina',
    'masculin',
    'maschile',
    'herren',
    'männer',
    'mannen',
    'mężczyzn',
    'мужчины',
    'мужской',
    '男子',
    '남자'
  ],
  'vs': ['contra', 'contre', 'gegen', 'против', '対', '對', '对', '대결', '대'],
  'semifinal': [
    'semifinales',
    'semifinais',
    'demi-finale',
    'demi-finales',
    'semifinale',
    'halbfinale',
    'полуфинал',
    '準決勝',
    '半决赛',
    '半決賽',
    '준결승'
  ],
  'quarterfinal': [
    'cuartos de final',
    'quartas de final',
    'quart de finale',
    'quarts de finale',
    'quarti di finale',
    'viertelfinale',
    'четвертьфинал',
    '準々決勝',
    '四分之一决赛',
    '四分之一決賽',
    '준준결승'
  ],
  'final': ['finale', 'финал', '決勝', '决赛', '決賽', '결승'],
  'qualifying': [
    'clasificación',
    'clasificacion',
    'qualifiche',
    'qualifikation',
    'квалификация',
    '予選',
    '排位赛',
    '排位賽',
    '퀄리파잉'
  ],
  'practice': [
    'entrenamientos libres',
    'treinos livres',
    'essais libres',
    'prove libere',
    'freies training',
    'フリー走行',
    '自由练习',
    '自由練習'
  ],
  'court': ['корт', 'コート', '코트'],
  'yesterday': ['ayer', 'ontem', 'gestern', 'ieri', 'вчера', '昨日', '昨天', '어제'],
  'tomorrow': [
    'mañana',
    'amanhã',
    'demain',
    'morgen',
    'domani',
    'завтра',
    '明日',
    '明天',
    '내일'
  ],
};

final _aliases = <String, String>{
  for (final e in [..._words.entries, ...sportsNativeClubNames.entries])
    for (final alias in e.value) alias.toLowerCase(): e.key,
};
// These scripts do not consistently separate words with spaces in TV guides.
final _unspaced = RegExp(r'[\u0e00-\u0e7f\u3040-\u30ff\u3400-\u9fff]');
final _nonAscii = RegExp(r'[^\x00-\x7f]');
final _asciiAliases = _buildVocabulary(ascii: true);
final _nativeAliases = _buildVocabulary(ascii: false);
final _nativeTrigger = RegExp(
    '[${_aliases.keys.expand((p) => p.runes).where((r) => r > 127).toSet().map((r) => RegExp.escape(String.fromCharCode(r))).join()}]',
    caseSensitive: false,
    unicode: true);
RegExp _buildVocabulary({required bool ascii}) {
  final phrases = _aliases.keys
      .where((p) => _nonAscii.hasMatch(p) != ascii)
      .toList()
    ..sort((a, b) => b.length.compareTo(a.length));
  if (ascii) {
    return RegExp(r'\b(?:' + phrases.map(RegExp.escape).join('|') + r')\b',
        caseSensitive: false);
  }
  final spaced =
      phrases.where((p) => !_unspaced.hasMatch(p)).map(RegExp.escape).join('|');
  final unspaced =
      phrases.where(_unspaced.hasMatch).map(RegExp.escape).join('|');
  return RegExp(
      '(?<![\\p{L}\\p{N}])(?:$spaced)(?![\\p{L}\\p{N}])|(?:$unspaced)',
      caseSensitive: false,
      unicode: true);
}

final _numberedPista = RegExp(r'\bpista(?=\s+\d{1,2}\b)', caseSensitive: false);
final _cache = <String, String>{};
String sportsLanguageText(String text) {
  final cached = _cache[text];
  if (cached != null) return cached;
  // Decorative Unicode flags/quality suffixes are common in channel names.
  // They must not send every otherwise-English name through the native-script
  // expression. Check characters actually used by the vocabulary first.
  var result = text;
  if (_nativeTrigger.hasMatch(result)) {
    result = result.replaceAllMapped(
        _nativeAliases, (match) => ' ${_aliases[match[0]!.toLowerCase()]!} ');
  }
  final nativeResult = result;
  result = result.replaceAllMapped(_asciiAliases, (match) {
    // ASCII word boundaries alone split accented/native names. Reject those
    // partial-word matches without running Unicode checks on every character.
    if ((match.start > 0 &&
            _unicodeLetter.hasMatch(nativeResult[match.start - 1])) ||
        (match.end < nativeResult.length &&
            _unicodeLetter.hasMatch(nativeResult[match.end]))) {
      return match[0]!;
    }
    return ' ${_aliases[match[0]!.toLowerCase()]!} ';
  }).replaceAll(_numberedPista, 'court');
  // Neither long synopses nor a provider's full catalogue can grow this cache.
  if (text.length <= 2048) {
    if (_cache.length >= 2048) {
      for (final key in _cache.keys.take(512).toList(growable: false)) {
        _cache.remove(key);
      }
    }
    _cache[text] = result;
  }
  return result;
}

// Score feeds may themselves use local club names. Use the same verified
// identity on both sides, with one exact lookup and no per-fixture translation.
final _clubIdentities = <String, String>{
  for (final entry in sportsNativeClubNames.entries)
    for (final alias in entry.value)
      normalizeSportsName(alias): ' ${entry.key} ',
};
String sportsClubIdentity(String normalizedName) =>
    _clubIdentities[normalizedName] ?? normalizedName;

/// Existing literal hits remain the fast path. Only misses with translated or
/// non-ASCII evidence need another comparison during the same database scan.
bool sportsTitleMatches(RegExp pattern, String title) {
  if (pattern.hasMatch(title)) return true;
  final translated = sportsLanguageText(title);
  if (translated == title && !_nonAscii.hasMatch(title)) return false;
  return pattern.hasMatch(normalizeSportsName(translated));
}

/// Country-team aliases only. Never translate arbitrary player/club names or
/// infer a fixture from a country word on its own.
const sportsCountryTeamAliases = <String, List<String>>{
  'germany': [
    'Deutschland',
    'Alemania',
    'Allemagne',
    'Germania',
    'Alemanha',
    'Германия',
    'ドイツ',
    '德国',
    '德國',
    '독일'
  ],
  'spain': [
    'España',
    'Espanha',
    'Espagne',
    'Spanien',
    'Spagna',
    'Испания',
    'スペイン',
    '西班牙',
    '스페인'
  ],
  'france': [
    'Francia',
    'França',
    'Frankreich',
    'Франция',
    'フランス',
    '法国',
    '法國',
    '프랑스'
  ],
  'italy': [
    'Italia',
    'Itália',
    'Italie',
    'Italien',
    'Италия',
    'イタリア',
    '意大利',
    '이탈리아'
  ],
  'england': [
    'Inglaterra',
    'Angleterre',
    'Inghilterra',
    'Англия',
    'イングランド',
    '英格兰',
    '英格蘭',
    '잉글랜드'
  ],
  'brazil': [
    'Brasil',
    'Brésil',
    'Brasilien',
    'Brasile',
    'Бразилия',
    'ブラジル',
    '巴西',
    '브라질'
  ],
  'japan': ['Japón', 'Japão', 'Japon', 'Giappone', 'Япония', '日本', '일본'],
  'south korea': [
    'Korea Republic',
    'Corea del Sur',
    'Corée du Sud',
    'Südkorea',
    'Corea del Sud',
    'Южная Корея',
    '韓国',
    '韩国',
    '韓國',
    '대한민국',
    '한국'
  ],
  'netherlands': [
    'Nederland',
    'Países Bajos',
    'Pays-Bas',
    'Niederlande',
    'Paesi Bassi',
    'Нидерланды',
    'オランダ',
    '荷兰',
    '荷蘭',
    '네덜란드'
  ],
  'united states': [
    'USA',
    'Estados Unidos',
    'États-Unis',
    'Stati Uniti',
    'США',
    'アメリカ',
    '美国',
    '美國',
    '미국'
  ],
};

final _unicodeLetter = RegExp(r'[\p{L}\p{M}\p{N}]', unicode: true);

/// Canonical matchup connectors shared by synopsis indexing and verification.
const sportsFixtureConnectorPattern =
    r' (?:vs|v|versus|at|against|faces|meets|plays|takes on|take on|hosts?|visits) ';

// Fixture normalization joins an apostrophe after an initial letter (O'Connor,
// a't), but treats other ASCII apostrophes as punctuation. Rejection filters
// must defer whenever that same joining rule could create evidence.
const sportsJoiningApostrophePattern = r"(?<=\b[A-Za-zÀ-ž])['’](?=[A-Za-zÀ-ž])";
final _joiningApostrophe = RegExp(sportsJoiningApostrophePattern);
bool _hasJoiningApostrophe(String text) =>
    text.contains("'") && _joiningApostrophe.hasMatch(text);

/// Sport evidence required when neither the title nor a dedicated coverage
/// title establishes the sport. Keep rejection and full verification in sync.
const sportsExplicitSportPattern =
    r' (futsal|table tennis|field hockey|boxing|handball|badminton|volleyball|basketball|nba|wnba|baseball|mlb|npb|kbo|softball|soccer|tennis|atp|wta|ice hockey|hockey|nhl|rugby|golf|american football|college football|nfl|ncaaf) ';

// Translation can insert spaces around an alias beside a '+'; allow that
// boundary here even though name normalization itself preserves '+'.
RegExp _possibleAsciiEvidence(String canonicalPattern) {
  final canonical = RegExp(canonicalPattern);
  return RegExp(
      r'(?<![a-z0-9])(?:' +
          [
            canonicalPattern.trim().replaceAll(' ', r'[^a-z0-9+]+'),
            ..._words.entries
                .where((e) => canonical.hasMatch(' ${e.key} '))
                .expand((e) => e.value)
                .where((alias) => !_nonAscii.hasMatch(alias))
                .map(RegExp.escape),
          ].join('|') +
          r')(?![a-z0-9])',
      caseSensitive: false);
}

final _possibleAsciiFixtureConnector =
    _possibleAsciiEvidence(sportsFixtureConnectorPattern);
final _possibleAsciiSport = _possibleAsciiEvidence(sportsExplicitSportPattern);

/// Rejection only: no sport word here means normalization cannot supply the
/// missing sport evidence. Native text and joining apostrophes take the full
/// path; a positive result still needs the ordinary opponent/sport checks.
bool sportsSynopsisMayNameSport(String text) =>
    _hasJoiningApostrophe(text) ||
    _nonAscii.hasMatch(text) ||
    _possibleAsciiSport.hasMatch(text);

/// A rejection-only shortcut; a true result never establishes a fixture.
/// ASCII punctuation becomes spaces during normalization. Joining apostrophes
/// and Unicode folding/translation can create a match, so those inputs always
/// retain the full evidence analysis.
bool sportsSynopsisMayNameFixture(String text) =>
    text.contains('@') ||
    _hasJoiningApostrophe(text) ||
    _nonAscii.hasMatch(text) ||
    _possibleAsciiFixtureConnector.hasMatch(text);

/// Fold Latin diacritics while retaining names in other writing systems.
String normalizeSportsName(String s) {
  // Most guide/channel labels are short ASCII strings. Fill their normalized
  // bytes directly rather than allocating/writing a String for each character.
  // Bound the temporary buffer; longer and non-ASCII inputs keep the original
  // rune path, including whole-string Unicode lowercasing and accent folding.
  if (s.length <= 2048) {
    final output = Uint8List(s.length + 2);
    var length = 1;
    output[0] = 32;
    var lastSpace = true;
    for (var i = 0; i < s.length; i++) {
      var c = s.codeUnitAt(i);
      if (c > 127) return _normalizeSportsNameRunes(s);
      if (c >= 65 && c <= 90) c += 32;
      if ((c >= 97 && c <= 122) || (c >= 48 && c <= 57) || c == 43) {
        output[length++] = c;
        lastSpace = false;
      } else if (!lastSpace) {
        output[length++] = 32;
        lastSpace = true;
      }
    }
    if (!lastSpace) output[length++] = 32;
    return String.fromCharCodes(output, 0, length);
  }
  return _normalizeSportsNameRunes(s);
}

String _normalizeSportsNameRunes(String s) {
  final buffer = StringBuffer(' ');
  var lastSpace = true;
  // Keep ASCII and known accents on the cheap path. Unicode category checks
  // are only needed for the remaining non-ASCII name characters.
  for (var rune in s.toLowerCase().runes) {
    if (rune >= 0xff01 && rune <= 0xff5e) rune -= 0xfee0;
    // Decomposed accents must not split a player's name into two words.
    if (rune >= 0x300 && rune <= 0x36f) continue;
    final isAscii = (rune >= 0x61 && rune <= 0x7a) ||
        (rune >= 0x30 && rune <= 0x39) ||
        rune == 0x2b;
    String? ch = isAscii ? String.fromCharCode(rune) : null;
    if (ch == null && rune > 0x7f) ch = _foldAccents[String.fromCharCode(rune)];
    if (ch == null &&
        rune > 0x7f &&
        _unicodeLetter.hasMatch(String.fromCharCode(rune))) {
      ch = String.fromCharCode(rune);
    }
    if (ch != null) {
      buffer.write(ch);
      lastSpace = false;
    } else if (!lastSpace) {
      buffer.write(' ');
      lastSpace = true;
    }
  }
  if (!lastSpace) buffer.write(' ');
  return buffer.toString();
}

const Map<String, String> _foldAccents = {
  'à': 'a',
  'á': 'a',
  'â': 'a',
  'ã': 'a',
  'ä': 'a',
  'å': 'a',
  'ç': 'c',
  'è': 'e',
  'é': 'e',
  'ê': 'e',
  'ë': 'e',
  'ì': 'i',
  'í': 'i',
  'î': 'i',
  'ï': 'i',
  'ñ': 'n',
  'ò': 'o',
  'ó': 'o',
  'ô': 'o',
  'õ': 'o',
  'ö': 'o',
  'ø': 'o',
  'ù': 'u',
  'ú': 'u',
  'û': 'u',
  'ü': 'u',
  'ý': 'y',
  'ß': 'ss',
  'č': 'c',
  'ć': 'c',
  'ď': 'd',
  'đ': 'd',
  'ě': 'e',
  'ğ': 'g',
  'ı': 'i',
  'ł': 'l',
  'ń': 'n',
  'ň': 'n',
  'ř': 'r',
  'š': 's',
  'ś': 's',
  'ť': 't',
  'ů': 'u',
  'ž': 'z',
  'ź': 'z',
  'ż': 'z',
  'æ': 'ae',
  'œ': 'oe',
  // Remaining upstream Balkan/Turkish/Polish/Hungarian spellings. Retain
  // our existing single-pass normalizer and decomposed-accent handling.
  'ş': 's',
  'ą': 'a',
  'ę': 'e',
  'ő': 'o',
  'ű': 'u',
  'ț': 't',
  'ș': 's',
  'ă': 'a',
};
