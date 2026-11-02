import 'sports_language.dart';
import 'endurance_racing.dart';

/// Guide vocabulary for competitions absent from the scoreboard providers.
/// Shared by Events, Replays and Highlights. These patterns identify a sport,
/// never a live state, event date or a channel match.
final extendedSportsPatterns = <String, RegExp>{
  'racing': motorsportGuidePattern,
  'mma': RegExp(
      '${_rx(r'mma|mixed martial arts|ufc|pfl|bellator|cage warriors|lion fight|lfa|invicta fc|rizin|ksw|contender series').pattern}|${_onePromotion.pattern}|${_strikingPromotion.pattern}',
      caseSensitive: false),
  'boxing': _rx(
      r'boxing|bkfc|bare knuckle|top rank|premier boxing champions|matchroom boxing|queensberry'),
  'poker': _rx(
      r'poker|poker[ -]?go|wsop|wpt|world poker tour|world series of poker|triton poker|pokerstars|european poker tour|super high roller bowl'),
  'darts': _rx(r'darts|pdc|wdf|popdarts'),
  'esports': _rx(
      r'e[ -]?sports|counter[ -]?strike|dota ?2|league of legends|valorant|rocket league|intel extreme masters|blast premier'),
  'action-sports': _rx(
      r'x games|dew tour|street league skateboarding|red bull rampage|freeride world tour|snowboard(?:ing)?|skateboard(?:ing)?|bmx|world surf league|surfing'),
  'billiards': _rx(
      r'snooker|billiards?|ultimate pool|mosconi cup|world pool championship|professional cuesports'),
  'bowling': _rx(
      r'ten[ -]?pin bowling|pba (?:tour|bowling|championship)|world bowling'),
  'badminton': _rx(r'badminton|bwf'),
  'table-tennis': _rx(
      r'table tennis|world table tennis|ittf|wtt (?:champions|contender|star contender|grand smash|finals|feeder)'),
  'sumo':
      _rx(r'grand sumo|sumo (?:tournament|championship|basho)|honbasho|ozumo'),
  'skating': _rx(
      r'(?:figure|speed) skating|ice dance|isu grand prix|skate canada international|skate america'),
  'skiing': _rx(
      r'(?:alpine|cross[ -]country|freestyle) skiing|ski jumping|nordic combined|biathlon'),
  'basketball': _rx(
      r'fiba (?:men[’\x27]?s? |women[’\x27]?s? )?3\s*[x×]\s*3|3\s*[x×]\s*3 basketball|euroleague|eurocup'),
  'hockey': _rx(r'ahl|american hockey league'),
  'australian-football': _rx(r'aflw|afl women[’\x27]?s?'),
  'soccer': _rx(r'ekstraklasa|polish (?:premier league|football league)'),
  'wrestling': _rx(
      r'wwe|aew|all elite wrestling|tna (?:wrestling|impact)|total nonstop action'),
  'climbing':
      _rx(r'ifsc|sport climbing|climbing world (?:cup|series|championships?)'),
  'gymnastics': _rx(
      r'(?:artistic|rhythmic|trampoline) gymnastics|gymnastics (?:world|championships?|world cup)'),
  // Guide-only coverage: these are not ESPN scoreboard paths.
  'baseball': RegExp(
      asianBaseballPatterns.values.map((r) => r.pattern).join('|'),
      caseSensitive: false),
  'rugby': RegExp(
      [
        r'\b(?:rugby|wxv|black ferns)\b',
        ...rugbyCompetitionPatterns.values.map((r) => r.pattern)
      ].join('|'),
      caseSensitive: false),
  'cricket': _rx(r'cricket|indian premier league|big bash league|the ashes'),
  'netball': _rx(r'netball|suncorp super netball'),
  'handball': _rx(r'handball|liqui moly hbl'),
  'squash': _rx(r'squash|psa world tour'),
  'padel': _rx(r'padel|pádel'),
  'pickleball': _rx(r'pickleball|ppa tour|major league pickleball'),
  'taekwondo': _rx(
      r'world taekwondo|taekwondo (?:grand prix|world|championships?|tournament)'),
  'sailing':
      _rx(r'sailgp|america[’\x27]s cup|sailing (?:world|championship|regatta)'),
  'triathlon':
      _rx(r'triathlons?|ironman (?:world championship|70[.]3|triathlon)'),
  'cycling': _rx(
      r'cycling|cyclo[ -]?cross|tour de france|giro d.italia|vuelta a espa[nñ]a|uci (?:world|track|road|mountain)'),
  'field-hockey': _rx(r'field hockey|fih pro league|fih hockey'),
};

/// Named racing series; deliberately excludes bare 'racing' and 'Porsche'
/// so horse racing and road-car programmes cannot become motor race events.
final _standardMotorsportGuidePattern = _rx(
    r'formula (?:1|one|2|two|3|three|e)|f[123]|f1 academy|supercars|v8 supercars|super2|super3|aussie racing cars|superutes|super utes|touring car masters|carrera cup|porsche (?:supercup|sprint challenge)|gt[234]|gt world challenge|gtwc|intercontinental gt challenge|igtc|world endurance|wec|imsa|european le mans|asian le mans|elms|super gt|supergt|dtm|tcr world tour|british gt|super formula|indycar|indy nxt|nascar|arca menards|motogp|moto ?[23]|worldsbk|worldssp|world superbike|world supersport|british superbike|nhra|world rally|wrc|european rally|motorsport|motor racing');

final motorsportGuidePattern = RegExp(
    '${_standardMotorsportGuidePattern.pattern}|${enduranceGuidePattern.pattern}',
    caseSensitive: false);

RegExp _rx(String text) => RegExp('\\b(?:$text)\\b', caseSensitive: false);

// Scan words once to reject ordinary programmes before evaluating the more
// detailed sport expressions. This is only a fast gate, never classification.
const _sportSignalWords = {
  '24',
  '24h',
  '24hours',
  '24heures',
  '12',
  '12h',
  '8',
  '8h',
  '6',
  'lone',
  'qatar',
  'rolex',
  'petit',
  'twelve',
  'twenty',
  'six',
  'bathurst',
  'suzuka',
  'indianapolis',
  'adac',
  'nls',
  'vln',
  'creventic',
  '992',
  'endurance',
  'langstrecken',
  'taikyu',
  'fuji',
  's',
  'winter',
  'asian',
  'aslms',
  'le',
  'mans',
  'road',
  'michelin',
  'silverstone',
  'blancpain',
  'fim',
  'bol',
  'weathertech',
  'battle',
  'formula',
  'f1',
  'f2',
  'f3',
  'supercars',
  'v8',
  'super2',
  'super3',
  'aussie',
  'superutes',
  'touring',
  'carrera',
  'porsche',
  'gt2',
  'gt3',
  'gt4',
  'gt',
  'gtwc',
  'intercontinental',
  'igtc',
  'wec',
  'imsa',
  'elms',
  'dtm',
  'tcr',
  'indycar',
  'indy',
  'nascar',
  'arca',
  'motogp',
  'moto',
  'moto2',
  'moto3',
  'worldsbk',
  'worldssp',
  'nhra',
  'wrc',
  'motorsport',
  'motor',
  'supergt',
  'mma',
  'mixed',
  'ufc',
  'pfl',
  'bellator',
  'one',
  'cage',
  'lion',
  'lfa',
  'invicta',
  'rizin',
  'ksw',
  'contender',
  'muay',
  'muaythai',
  'thai',
  'suek',
  'kiatpetch',
  'kiatpecht',
  'petchyindee',
  'kp',
  'kickboxing',
  'rajadamnern',
  'rajadamnoen',
  'rajadamnon',
  'rws',
  'glory',
  'boxing',
  'bkfc',
  'bare',
  'matchroom',
  'queensberry',
  'poker',
  'pokerstars',
  'pokergo',
  'wsop',
  'wpt',
  'hold',
  'holdem',
  'nlh',
  'texas',
  'triton',
  'darts',
  'pdc',
  'wdf',
  'popdarts',
  'e',
  'esports',
  'counter',
  'dota',
  'dota2',
  'league',
  'valorant',
  'rocket',
  'intel',
  'blast',
  'x',
  'dew',
  'street',
  'red',
  'freeride',
  'snowboard',
  'snowboarding',
  'skateboard',
  'skateboarding',
  'bmx',
  'surf',
  'surfing',
  'snooker',
  'billiard',
  'billiards',
  'pool',
  'bowling',
  'rally',
  'superbike',
  'supersport',
  'ultimate',
  'mosconi',
  'professional',
  'ten',
  'pba',
  'badminton',
  'bwf',
  'table',
  'ittf',
  'wtt',
  'grand',
  'sumo',
  'honbasho',
  'ozumo',
  'figure',
  'speed',
  'ice',
  'isu',
  'skate',
  'alpine',
  'cross',
  'freestyle',
  'ski',
  'nordic',
  'biathlon',
  'fiba',
  'euroleague',
  'eurocup',
  'ahl',
  'aflw',
  'afl',
  'ekstraklasa',
  'polish',
  'wwe',
  'aew',
  'wrestling',
  'tna',
  'nonstop',
  'ifsc',
  'climbing',
  'gymnastics',
  'cyclocross',
  'cyclo',
  '3x3',
  '3',
  'npb',
  'nippon',
  'japan',
  'japanese',
  'kbo',
  'korea',
  'korean',
  'cpbl',
  'chinese',
  'taiwan',
  'taiwanese',
  'rugby',
  'nrl',
  'nrlw',
  'national',
  'state',
  'betfred',
  'super',
  'united',
  'gallagher',
  'premiership',
  'prem',
  'top',
  'top14',
  'urc',
  'european',
  'investec',
  'heineken',
  'epcr',
  'bunnings',
  'mitre',
  'npc',
  'currie',
  'major',
  'svns',
  'hsbc',
  'autumn',
  'british',
  'cricket',
  'ashes',
  'indian',
  'big',
  'netball',
  'suncorp',
  'handball',
  'liqui',
  'squash',
  'padel',
  'p',
  'pickleball',
  'ppa',
  'taekwondo',
  'sailgp',
  'america',
  'sailing',
  'triathlon',
  'triathlons',
  'ironman',
  'psa',
  'cycling',
  'tour',
  'giro',
  'vuelta',
  'uci',
  'field',
  'fih',
};
final _signalWord = RegExp(r'[a-z0-9]+|[^\x00-\x7F]+');
final _asianSignal = RegExp(
    r'野球|職棒|职棒|야구|มวย|ไทยไฟ|ลุมพินี|ราชดำเนิน|เพชรยินดี|ศึกจิตร|เกียรติเพชร');
bool _hasExtendedSignal(String text) {
  for (final word in _signalWord.allMatches(text.toLowerCase())) {
    final token = word[0]!;
    if (_sportSignalWords.contains(token) ||
        (token.codeUnitAt(0) > 127 && _asianSignal.hasMatch(token))) {
      return true;
    }
  }
  return false;
}

final _pokerCoverageTitle = _rx(
    r'world poker tour|world series of poker|wsop|wpt|poker[ -]?go|high stakes poker|poker after dark|friday night poker|triton poker|poker masters|poker superstars|poker night|u[.]?s[.]? poker open|pokerstars|european poker tour|super high roller bowl|million dollar cash game');
final _fiction = _rx(
    r'poker face|poker-faced|movie|film|thriller|crime drama|sitcom|western|horror|murders?|detective|robbers?|stolen money');
final _localNonCoverage =
    RegExp(r'สารคดี|ภาพยนตร์|ละคร|เบื้องหลัง|เรื่องราว|ข่าวกีฬา|ข่าวมวย');
final _nonCoverage = _rx(
    r'news|podcast|interviews?|press conference|agenda setter|the breakdown|rugby tonight|route presentation|routepresentatie|prezentacja trasy|streckenpräsentation|documentary|documentaries|review|tutorial|walkthrough|unboxing|talk show|behind the scenes|inside surfing|weekly|magazine|racing on the edge|one lumpinee heroes|beyond triathlon');
final _competition = _rx(
    r'tournament|championship|final table|round|session|compete|competition|players|coverage|sports|cards|match|fixture|race|races|racing|qualifying|practice|supports');
final _quizProgramme = _rx(r'game[ -]show|quiz[ -]show');
final _nonEventSynopsis = RegExp(
    r'^(?:(?:a|an|the|this)\s+)?(?:documentary|biography|portrait of|story of|story behind|look (?:at|into) (?:the )?(?:life|career))\b|\([^)]{0,100}\b(?:documentary|biography)\b',
    caseSensitive: false);

/// Require a named sport in the title, or a clearly competitive synopsis.
/// Incidental sport references in films, games reviews and channel placeholders
/// must not create sporting events.
bool isExtendedSportFiction(String title, String description) =>
    _fiction.hasMatch(title) || _fiction.hasMatch(description);

String? extendedGuideSport(String title, String description,
    {String channelName = ''}) {
  final rawSynopsis =
      description.length > 640 ? description.substring(0, 640) : description;
  title = sportsLanguageText(title);
  channelName = sportsLanguageText(channelName);
  final synopsis = sportsLanguageText(rawSynopsis);
  // Ordinary programmes leave early. Broader fast-gate words such as
  // "table" must not suppress dedicated-channel context later on.
  String? contextual;
  if (!_hasExtendedSignal(title) && !_hasExtendedSignal(synopsis)) {
    contextual = _contextualGuideSport(title, channelName, synopsis);
    if (contextual == null) return null;
  }
  if (_fiction.hasMatch(title) ||
      _nonCoverage.hasMatch(title) ||
      _localNonCoverage.hasMatch('$title $synopsis') ||
      _channelAdvert.hasMatch(title)) {
    return null;
  }
  // Some guides attach sport tags to quiz shows. An explicit programme type
  // outweighs those incidental tags, including on a sports-branded channel.
  if (_fiction.hasMatch(synopsis) ||
      _quizProgramme.hasMatch(title) ||
      _quizProgramme.hasMatch(synopsis) ||
      _nonEventSynopsis.hasMatch(synopsis.trim())) {
    return null;
  }
  if (contextual != null) return contextual;
  for (final entry in extendedSportsPatterns.entries) {
    if (!entry.value.hasMatch(title)) continue;
    if (entry.key == 'australian-football' &&
        _soccerCoverage.hasMatch(synopsis)) {
      return null;
    }
    if (entry.key == 'basketball' &&
        (_otherCourtSport.hasMatch(title) ||
            _otherCourtSport.hasMatch(synopsis))) {
      return null;
    }
    if (entry.key == 'wrestling' && _wrestlingStudio.hasMatch(title)) {
      return null;
    }
    if (entry.key == 'poker') {
      return _isPokerCoverage(title, synopsis, channelName) ? 'poker' : null;
    }
    if (entry.key == 'squash' &&
        !_squashCoverage.hasMatch('$title $synopsis')) {
      return null;
    }
    return entry.key;
  }
  if (_isPokerCoverage(title, synopsis, channelName)) return 'poker';
  // A matchup can be named in the title with its competition only in the
  // synopsis. Keep this narrow rather than treating every mention as coverage.
  if (_hockeyMatchup.hasMatch(title) &&
      extendedSportsPatterns['hockey']!.hasMatch(synopsis) &&
      !_nonCoverage.hasMatch(synopsis) &&
      !_otherCourtSport.hasMatch(title)) {
    return 'hockey';
  }
  if ((!_competition.hasMatch(synopsis) &&
          !_localCompetition.hasMatch(synopsis)) ||
      _nonCoverage.hasMatch(synopsis)) {
    return _contextualGuideSport(title, channelName, synopsis);
  }
  final found = extendedSportsPatterns.entries
      .where((entry) => entry.key != 'poker' && entry.value.hasMatch(synopsis))
      .map((entry) => entry.key)
      .toList();
  return found.length == 1
      ? found.single
      : found.isEmpty
          ? _contextualGuideSport(title, channelName, synopsis)
          : null;
}

// These identify programme content on any channel, not just poker services.
// Generic competition words alone also occur in sitcom plots about poker.
final _pokerGenre = RegExp(r'(?:\(|category\s*:)\s*[^)\n]{0,100}\bpoker\b',
    caseSensitive: false);
final _pokerFictionGenre = RegExp(
    r'(?:\(|category\s*:)\s*[^)\n]{0,120}\b(?:sitcom|comedy|drama|animated|animation|game show|documentary|entertainment)\b',
    caseSensitive: false);
final _pokerPlay = _rx(
    r'final table|cash games?|poker action|poker players|poker champions|poker professionals|poker pros|(?:pros|professionals) play poker|(?:coverage|action) (?:of|from)|live (?:poker|no[ -]?limit|texas hold)|tournament poker|poker tournament (?:from|at)|no[ -]?limit (?:texas )?hold.?em');
final _pokerGame = _rx(r'poker|wsop|wpt|hold.?em|nlh');
final _pokerSportsChannel = _rx(
    r'cbs sports|nbc sports|nbcsports|nbcsn|fox sports|fs[12]|espn[23u]?|masn2?|nesn|altitude(?: sports)?|fanduel sports|bally sports|msg|space city home network|sportsnet|fubo sports');

bool _isPokerCoverage(String title, String synopsis, String channelName) {
  if (_pokerFictionGenre.hasMatch('$title $synopsis')) return false;
  if (_otherSportTitle.hasMatch(title) && !_pokerGame.hasMatch(title)) {
    return false;
  }
  // "Poker Night" is also a film. Sparse listings on a known sports network
  // are useful evidence, but an unknown/general channel needs the synopsis.
  if (_pokerNight.hasMatch(title)) {
    return _pokerNightEvidence.hasMatch(synopsis) ||
        _pokerSportsChannel.hasMatch(channelName) ||
        _pokerChannel.hasMatch(channelName);
  }
  if (_pokerCoverageTitle.hasMatch(title) || _pokerGenre.hasMatch(synopsis)) {
    return true;
  }
  return _pokerGame.hasMatch(synopsis) && _pokerPlay.hasMatch(synopsis);
}

String? _contextualGuideSport(
    String title, String channelName, String description) {
  if (_pokerChannel.hasMatch(channelName) &&
      hasSpecificPokerProgramme(description)) {
    return 'poker';
  }
  if (_pokerFormat.hasMatch(title) && _pokerChannel.hasMatch(channelName)) {
    return 'poker';
  }
  if (!_guideMatchup.hasMatch(title)) return null;
  if (asianBaseballLeague(channelName, '') != null) return 'baseball';
  if (_rugbyChannel.hasMatch(channelName) &&
      channelName.length < 80 &&
      !_guideMatchup.hasMatch(channelName) &&
      !_otherSportTitle.hasMatch(title)) {
    return 'rugby';
  }
  return null;
}

/// Promotion-specific guide filters share the same exact-slot channel matching.
final _onePromotion = RegExp(
    '${_rx(r'one (?:championship|fc|fight night|friday fights|lumpin(?:ee|i)|samurai)').pattern}|'
    r'(?:one|วัน)\s*ลุมพินี',
    caseSensitive: false);
final _strikingPromotion = RegExp(
    '${_rx(r'muay[ -]?thai|muay man sanan muang|muay dee witeethai|thai fight|kiat(?:petch|pecht)|petchyindee|kp sunday fight|kickboxing|rajadamnern|rajadamn(?:o|oe)n|rws|glory \d+').pattern}|มวยไทย|มวยมันส์|ศึกจิตรเมืองนนท์|เกียรติเพชร|ไทยไฟ[ตท]์|ราชดำเนิน|เพชรยินดี',
    caseSensitive: false);
final _localCompetition = RegExp(r'การแข่งขัน|ถ่ายทอดสด|ชิงแชมป์|ชกมวย');
String? combatGuideLeague(String title, String description) {
  final text = '$title $description';
  if (_onePromotion.hasMatch(text)) return 'one';
  if (_strikingPromotion.hasMatch(text)) return 'muay-thai';
  return null;
}

final cyclocrossPattern = _rx(r'cyclo[ -]?cross');
final _euroleague = _rx(r'euroleague');
final _eurocup = _rx(r'eurocup');
final _threeByThree = _rx(r'3\s*[x×]\s*3');
final _wwe = _rx(r'wwe');
final _aew = _rx(r'aew|all elite wrestling');
final _tna = _rx(r'tna|total nonstop action');
final _soccerCoverage = _rx(r'a[ -]league|soccer|association football');
final _otherCourtSport = _rx(
    r'soccer|football|water polo|skiing|snowboarding|motorcycle|rally|handball|volleyball');
final _wrestlingStudio = _rx(
    r'kickoff|countdown|post[ -]?show|pre[ -]?show|radio|podcast|press conference');
final _hockeyMatchup =
    RegExp(r'\s(?:vs?\.?|versus|at|@)\s', caseSensitive: false);

/// Route only already-classified broadcasts. A title's competition wins over
/// parent organisations and other competitions mentioned in its synopsis.
String? additionalGuideCompetition(
    String sport, String title, String description) {
  if (sport == 'soccer') return 'ekstraklasa';
  if (sport == 'hockey') return 'ahl';
  if (sport == 'australian-football') return 'aflw';
  if (sport == 'basketball' && _threeByThree.hasMatch(title)) {
    return 'basketball';
  }
  if (sport == 'cycling') {
    return cyclocrossPattern.hasMatch(title) ||
            cyclocrossPattern.hasMatch(description)
        ? 'cyclocross'
        : null;
  }
  for (final text in [title, description]) {
    if (sport == 'basketball') {
      if (_eurocup.hasMatch(text)) return 'eurocup';
      if (_euroleague.hasMatch(text)) return 'euroleague';
    } else if (sport == 'wrestling') {
      if (_wwe.hasMatch(text)) return 'wwe';
      if (_aew.hasMatch(text)) return 'aew';
      if (_tna.hasMatch(text)) return 'tna';
    } else {
      return null;
    }
  }
  return null;
}

// Stable competition vocabulary, never team/country guesses or stream probes.
final asianBaseballPatterns = <String, RegExp>{
  'npb': RegExp(
      r'\b(?:npb|nippon professional baseball|japan(?:ese)? (?:pro(?:fessional)? )?baseball)\b|日本プロ野球|日本職棒|日本职棒|プロ野球',
      caseSensitive: false),
  'kbo': RegExp(
      r'\b(?:kbo|korea(?:n)? (?:pro(?:fessional)? )?baseball|korea baseball organi[sz]ation)\b|한국프로야구|한국 프로야구|韓国プロ野球|韓國職棒|韩国职棒',
      caseSensitive: false),
  'cpbl': RegExp(
      r'\b(?:cpbl|chinese professional baseball|taiwan(?:ese)? (?:pro(?:fessional)? )?baseball)\b|中華職棒|中华职棒',
      caseSensitive: false),
};
String? asianBaseballLeague(String title, String description) {
  // Prefer the more specific Korean phrase before its Japanese suffix.
  for (final id in const ['kbo', 'cpbl', 'npb']) {
    if (asianBaseballPatterns[id]!.hasMatch(title)) return id;
  }
  for (final id in const ['kbo', 'cpbl', 'npb']) {
    if (asianBaseballPatterns[id]!.hasMatch(description)) return id;
  }
  return null;
}

final _pokerChannel = _rx(r'poker|pokergo|wsop|wpt');
final _pokerFormat =
    _rx(r'nlh|no[ -]?limit hold.?em|hold.?em|short deck|cash game|final table');
final _pokerNightEvidence = RegExp(
    r'\b(sports|cards|tournament|players|final table)\b|\([^)]*\bpoker\b[^)]*\)',
    caseSensitive: false);
final _squashCoverage =
    _rx(r'psa|world tour|tournament|championship|open|final|sports');
final _guideMatchup =
    RegExp(r'\b(?:vs?\.?|versus|at)\b|対|대', caseSensitive: false);

final _pokerNight = RegExp(r'^poker night(?:\s|$)', caseSensitive: false);

/// Dedicated poker guides sometimes use the show/channel name as the title.
/// A finite slot with a substantive table/episode description is still useful;
/// an always-on advertisement is not a programme.
bool hasSpecificPokerProgramme(String description) =>
    description.trim().length >= 24 &&
    _pokerProgramme.hasMatch(description) &&
    !_pokerAdvert.hasMatch(description);
final _pokerProgramme = _rx(
    r'tournament|final table|cash game|players|event|part|round|episode|nlh|hold.?em|short deck|omaha');
final _pokerAdvert = _rx(
    r'24/7|all day|non[ -]?stop|channel|no (?:guide|epg|information)|coming soon');

/// Competition-specific rugby names. Avoid bare "Premiership", "Champions
/// Cup", "Super League" or "Origin": they also name other sports/programmes.
final rugbyCompetitionPatterns = <String, RegExp>{
  'nrlw': _rx(r'nrlw|nrl women(?:s|’s|\x27s)?'),
  'nrl': _rx(r'nrl|national rugby league'),
  'state-of-origin': _rx(r'state of origin'),
  'urc': _rx(r'united rugby championship|urc'),
  'super-league':
      _rx(r'(?:betfred |rugby league )super league|super league rugby'),
  'six-nations': _rx(r'(?:six|6) nations'),
  'rugby-championship': _rx(r'(?:the )?rugby championship'),
  'super-rugby': _rx(r'super rugby(?: pacific| aupiki)?'),
  'premiership': _rx(
      r'premiership rugby|(?:gallagher|gallagher prem|prem) rugby|gallagher premiership|gallagher prem'),
  'top14': _rx(r'top ?14'),
  'champions-cup': _rx(r'(?:european rugby|investec|heineken) champions cup'),
  'challenge-cup': _rx(r'(?:european rugby|epcr) challenge cup'),
  'npc': _rx(
      r'bunnings npc|mitre 10 cup|national provincial championship|npc rugby'),
  'currie-cup': _rx(r'currie cup'),
  'league-one': _rx(r'japan rugby league one|japan rugby top league'),
  'mlr': _rx(r'major league rugby'),
  'sevens':
      _rx(r'rugby sevens|rugby 7s|svns|hsbc (?:world )?(?:rugby )?sevens'),
  'internationals': _rx(
      r'rugby (?:league )?world cup|rugby international|international rugby|rugby test|autumn nations|rugby nations championship|british and irish lions'),
};
String? rugbyGuideCompetition(String title, String description) {
  for (final text in [title, description]) {
    for (final entry in rugbyCompetitionPatterns.entries) {
      if (entry.value.hasMatch(text)) return entry.key;
    }
  }
  return null;
}

final _rugbyChannel = _rx(r'rugby|nrl|nrlw');

final _channelAdvert =
    RegExp(r'^(?:this is |welcome to |coming up on )', caseSensitive: false);
final _otherSportTitle = _rx(
    r'uefa|fifa|soccer|football|tennis|atp|wta|cricket|nba|nfl|nhl|baseball|volleyball|basketball');
