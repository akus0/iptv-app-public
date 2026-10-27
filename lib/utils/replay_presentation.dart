import '../models/sports.dart';
import 'sports_presentation.dart';

final _leagues = {
  for (final league in [...kSportsLeagues, ...kSportsLeagueBank])
    league.id: league,
};
final _women = RegExp(
    r'\b(?:women|womens|women’s|women\x27s|ladies|wnba|nwsl|wta|lpga|wbbl|aflw)\b',
    caseSensitive: false);
final _youth = RegExp(
    r'\b(?:u[ -]?\d{2}|under[ -]?\d{2}|youth|academy|high school|junior)\b',
    caseSensitive: false);
final _college = RegExp(r'\b(?:college|ncaa)\b', caseSensitive: false);
final _rules = <String, List<(RegExp, String)>>{
  'soccer': [
    (_rx(r'fifa.*world cup|football world cup'), 'fifa.world'),
    (_rx(r'uefa champions league|champions league|ucl'), 'uefa.champions'),
    (_rx(r'premier league|epl|^pl\b'), 'eng.1'),
    (_rx(r'la ?liga'), 'esp.1'),
    (_rx(r'serie ?a'), 'ita.1'),
    (_rx(r'bundesliga'), 'ger.1'),
    (_rx(r'ligue 1'), 'fra.1'),
    (_rx(r'europa league'), 'uefa.europa'),
    (_rx(r'fa cup'), 'eng.fa'),
    (_rx(r'libertadores'), 'conmebol.libertadores'),
    (_rx(r's[uü]per lig'), 'tur.1'),
    (_rx(r'mls|major league soccer'), 'usa.1'),
    (_rx(r'spfl|scottish premiership'), 'sco.1'),
    (_rx(r'a-league|\balm\b'), 'aus.1'),
  ],
  'football': [
    (_rx(r'nfl'), 'nfl'),
    (_rx(r'college|ncaa'), 'college-football')
  ],
  'basketball': [
    (_rx(r'nba'), 'nba'),
    (_rx(r'college|ncaa'), 'basketball.mens-college-basketball')
  ],
  'baseball': [(_rx(r'mlb|cubs classics'), 'mlb')],
  'hockey': [(_rx(r'nhl'), 'nhl')],
  'tennis': [(_rx(r'atp|wimbledon|grand slam|davis cup'), 'tennis.atp')],
  'golf': [
    (_rx(r'pga|masters|ryder cup'), 'golf.pga'),
    (_rx(r'dp world'), 'golf.eur'),
    (_rx(r'liv golf'), 'golf.liv')
  ],
  'racing': [
    (_rx(r'formula (?:1|one)|f1'), 'racing.f1'),
    (_rx(r'nascar'), 'racing.nascar-premier'),
    (_rx(r'indycar'), 'racing.irl')
  ],
  'mma': [(_rx(r'ufc'), 'mma.ufc'), (_rx(r'pfl'), 'mma.pfl')],
  'australian-football': [(_rx(r'afl'), 'australian-football.afl')],
};
RegExp _rx(String value) => RegExp('\\b(?:$value)\\b', caseSensitive: false);

// Badges require an explicit competition in the programme title. These are
// deliberately narrower than editorial ranking (e.g. Wimbledon is not ATP,
// and the PGA Championship is not a PGA Tour programme).
final _badgeLeagues = <String, List<(RegExp, String)>>{
  'soccer': [
    (_rx('uefa champions league|ucl'), 'uefa.champions'),
    (_rx('uefa europa league|europa league'), 'uefa.europa'),
    (_rx('english premier league|epl|^pl'), 'eng.1'),
    (_rx('la ?liga'), 'esp.1'),
    (_rx('serie ?a'), 'ita.1'),
    (_rx('bundesliga'), 'ger.1'),
    (_rx('ligue 1'), 'fra.1'),
    (_rx('mls|major league soccer'), 'usa.1'),
    (_rx('spfl|scottish premiership'), 'sco.1'),
    (_rx('a-league'), 'aus.1'),
  ],
  'football': [(_rx('nfl'), 'nfl')],
  'basketball': [(_rx('nba'), 'nba')],
  'baseball': [(_rx('mlb'), 'mlb')],
  'hockey': [(_rx('nhl'), 'nhl')],
  'racing': [(_rx('formula (?:1|one)|f1'), 'racing.f1')],
  'golf': [(_rx('pga tour'), 'golf.pga')],
  'mma': [(_rx('ufc'), 'mma.ufc')],
};
final _wnbaBadge = _rx('wnba');
final _lpgaBadge = _rx('lpga');
const _leagueInitials = {
  'uefa.champions': 'UCL',
  'uefa.europa': 'UEL',
  'eng.1': 'PL',
  'esp.1': 'LAL',
  'ita.1': 'SA',
  'ger.1': 'BUN',
  'fra.1': 'L1',
  'usa.1': 'MLS',
  'sco.1': 'SPL',
  'aus.1': 'AL',
  'nfl': 'NFL',
  'nba': 'NBA',
  'wnba': 'WNBA',
  'mlb': 'MLB',
  'nhl': 'NHL',
  'racing.f1': 'F1',
  'golf.pga': 'PGA',
  'golf.lpga': 'LPGA',
  'mma.ufc': 'UFC',
};

/// Text-only identity: no artwork lookup or inference from opponents or
/// incidental synopsis references. Resolve once per replay snapshot, not scroll.
String? replayLeagueInitials(String sport, String title) {
  final text = title.substring(0, title.length.clamp(0, 180));
  if (_youth.hasMatch(text) || _college.hasMatch(text)) return null;
  String? id;
  if (_women.hasMatch(text)) {
    if (sport == 'basketball' && _wnbaBadge.hasMatch(text)) id = 'wnba';
    if (sport == 'golf' && _lpgaBadge.hasMatch(text)) id = 'golf.lpga';
  } else {
    for (final entry in _badgeLeagues[sport] ?? const <(RegExp, String)>[]) {
      if (entry.$1.hasMatch(text)) {
        id = entry.$2;
        break;
      }
    }
  }
  return _leagueInitials[id];
}

final _condensed = RegExp(
    r'\b(?:condensed|cut[ -]down|shortened (?:game|match)|(?:raptors|fight sports|world series|nba|nfl|nhl|mlb|football|soccer|rugby|fifa world cup qualifiers)[^.!?]{0,25}in (?:30|60))\b',
    caseSensitive: false);

bool isCondensedReplay(String title, String? description) =>
    _condensed.hasMatch('$title ${description ?? ''}');

final _synopsisFooter = RegExp(
    r'\s*\(([^()]*)\)(?:\s*[-–]\s*(?:19|20)\d{2}(?:-\d{2}-\d{2})?)?\s*$');

/// Remove provider genre/premiere footers from reading copy, never from the
/// original guide evidence. Explicit event dates in prose remain visible.
String replaySynopsisForDisplay(String description) {
  final footer = _synopsisFooter.firstMatch(description);
  const genres = {
    'sport',
    'sports',
    'football',
    'soccer',
    'basketball',
    'baseball',
    'boxing',
    'tennis',
    'golf',
    'hockey',
    'rugby',
    'cricket',
    'softball',
    'volleyball',
    'billiards',
    'wrestling',
    'martial arts',
    'auto racing',
    'motorsports',
    'australian rules football',
    'documentary',
    'classic sport event',
    'playoff sports',
    'show',
    'episode',
    'series'
  };
  if (footer == null ||
      !footer[1]!
          .split(',')
          .every((s) => genres.contains(s.trim().toLowerCase()))) {
    return description.trim();
  }
  return description.substring(0, footer.start).trim();
}

/// Small replay-result search only; no scanning the playlist or guide on
/// each keypress. Normalise accents and punctuation so team names are easy
/// to enter from a phone keyboard or a TV remote.
String replaySearchText(String value) {
  const accents = 'àáâãäåèéêëìíîïòóôõöùúûüñçýÿ';
  const plain = 'aaaaaaeeeeiiiiooooouuuuncyy';
  return value
      .toLowerCase()
      .replaceAllMapped(
          RegExp('[$accents]'), (m) => plain[accents.indexOf(m[0]!)])
      .replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), ' ')
      .trim();
}

/// Editorial browsing order only: bounded guide text, no catalogue scan or
/// requests. Division/gender checks precede parent-league names.
int replayLeaguePriority(String sport, String title, String? description) {
  final synopsis = description ?? '';
  final text = '$title ${synopsis.substring(0, synopsis.length.clamp(0, 450))}';
  if (_youth.hasMatch(text)) return 60;
  final women = _women.hasMatch(text);
  if (_college.hasMatch(text)) {
    if (sport == 'football') return 3;
    if (sport == 'basketball') return women ? 5 : 3;
    return women ? 41 : 40;
  }
  if (women) {
    final id = switch (sport) {
      'basketball' when _rx('wnba').hasMatch(text) => 'wnba',
      'tennis' => 'tennis.wta',
      'golf' => 'golf.lpga',
      'soccer' when _rx('world cup').hasMatch(text) => 'fifa.wwc',
      'soccer' when _rx('champions league').hasMatch(text) => 'uefa.wchampions',
      'soccer' when _rx('super league|nwsl').hasMatch(text) => 'eng.w.1',
      _ => null,
    };
    return id == null ? 30 : leagueDisplayPriority(_leagues[id]!);
  }
  for (final rule in _rules[sport] ?? const <(RegExp, String)>[]) {
    if (rule.$1.hasMatch(text)) {
      return leagueDisplayPriority(_leagues[rule.$2]!);
    }
  }
  if (sport == 'cricket') {
    if (_rx('world cup|ashes|test match').hasMatch(text)) return 1;
    if (_rx('ipl|indian premier league').hasMatch(text)) return 2;
    if (_rx('bbl|big bash').hasMatch(text)) return 4;
  }
  if (sport == 'rugby') {
    if (_rx('world cup|six nations|state of origin').hasMatch(text)) return 1;
    if (_rx('nrl|super rugby|champions cup').hasMatch(text)) return 3;
    if (_rx('united rugby championship|urc').hasMatch(text)) return 4;
    if (_rx('epcr challenge cup|rugby challenge cup').hasMatch(text)) return 6;
  }
  return 30;
}

/// Read a structured event subtitle without treating narrative prose as a title.
String? replayEventSubtitle(String? description) {
  if (description == null) return null;
  final text = description.trim();
  final end = text.indexOf('\n');
  final line = end < 0 ? text : text.substring(0, end).trim();
  // Explicit episode/year prefixes identify a subtitle rather than prose.
  final prefix = RegExp(r'^(?:(?:19|20)\d{2}:\s*|S\d{1,4}\s+E\d+\s*[—–-]\s*)',
          caseSensitive: false)
      .firstMatch(line);
  final value = prefix == null ? line : line.substring(prefix.end).trim();
  if (value.isEmpty ||
      value.length > 110 ||
      RegExp(r'\b(?:previous|last meeting|next|upcoming|off air)\b',
              caseSensitive: false)
          .hasMatch(value)) {
    return null;
  }
  if (prefix != null ||
      (end >= 0 &&
          RegExp(r'\bPart \d+\b', caseSensitive: false).hasMatch(value))) {
    return value;
  }
  return null;
}

/// Preserve the guide identity; use only the opening fixture sentence.
String? replaySynopsisMatch(String title, String? description) {
  if (description == null ||
      description.trim().isEmpty ||
      RegExp(r'\s(?:v\.?|vs\.?|versus|at|@)\s', caseSensitive: false)
          .hasMatch(title)) {
    return null;
  }
  var text = description.trim();
  text = text.substring(0, text.length.clamp(0, 400));
  // Protect common abbreviations before finding the first sentence.
  final sentences = text
      .replaceAllMapped(RegExp(r'\b(vs|v|St|U\.S)\.', caseSensitive: false),
          (m) => '${m[1]}∯')
      .split(RegExp(r'[.!?]\s'));
  var first = sentences.first.replaceAll('∯', '.');
  // Observed EFL guide format: a generic archive introduction followed by
  // "Here, Leyton Orient face Rotherham United ...". Only that explicit
  // introduction permits looking beyond the opening sentence.
  if (sentences.length > 1 &&
      RegExp(r'^a look back at some classic\b', caseSensitive: false)
          .hasMatch(first) &&
      RegExp(r'^here,?\s', caseSensitive: false).hasMatch(sentences[1])) {
    first = sentences[1]
        .replaceFirst(RegExp(r'^here,?\s+', caseSensitive: false), '')
        .replaceAll('∯', '.');
  }
  if (RegExp(
          r'\b(?:previous|last meeting|last met|highlights|preview|could|may face|if necessary)\b',
          caseSensitive: false)
      .hasMatch(first)) {
    return null;
  }
  var candidate = first.replaceFirst(
      RegExp(r'^(?:full (?:match|game) replay (?:of )?|replay of |final:\s*)',
          caseSensitive: false),
      '');
  final between = RegExp(
          r'\bbetween (?:the )?(.{2,65}?) and (.{2,65}?)(?= at | from |\. |$)',
          caseSensitive: false)
      .firstMatch(first);
  if (between != null &&
      _rx(r'match|game|round\s+\d+|final|semifinal|fixture')
          .hasMatch(first.substring(0, between.start))) {
    candidate = '${between[1]} v ${between[2]}';
  }
  // A common tennis guide construction names both players around an aside.
  final tennis = RegExp(
          r'^([A-Z][a-zÀ-ž-]+ [A-Z][a-zÀ-ž-]+) returns\b.{0,160}\bas (?:he|she) meets (?:an? in-form )?([A-Z][a-zÀ-ž-]+ [A-Z][a-zÀ-ž-]+)\.?$')
      .firstMatch(first);
  if (tennis != null && _rx('atp|wta|tennis').hasMatch(title)) {
    candidate = '${tennis[1]} v ${tennis[2]}';
  }
  candidate = candidate
      .replaceFirst(
          RegExp(r'\s+(?:from|at the|at Wembley|in the|in a|as part of)\s+.*$',
              caseSensitive: false),
          '')
      .replaceFirst(RegExp(r'\s*\([^()]*\)\s*$'), '')
      .replaceFirst(RegExp(r'\.$'), '')
      .trim();
  if (candidate.length < 7 ||
      candidate.length > 110 ||
      !RegExp(r'\s(?:v\.?|vs\.?|versus|face|faces|host|hosts|meets|take on|takes on)\s',
              caseSensitive: false)
          .hasMatch(candidate)) {
    return null;
  }
  // Do not elevate a long narrative into a supposed match identity.
  if (candidate.split(RegExp(r'\s+')).length > 16) return null;
  return candidate;
}
