/// Conservative category parsing for uncurated M3U and Xtream playlists.
/// Only category names are inspected; the original categories are never edited.
class ProviderCategory {
  const ProviderCategory(this.name, this.region);
  final String name;
  final String? region;
}

const providerRegionNames = <String, String>{
  'uk': 'UK',
  'us': 'US',
  'au': 'Australia',
  'nz': 'New Zealand',
  'ca': 'Canada',
  'ie': 'Ireland',
  'fr': 'France',
  'de': 'Germany',
  'es': 'Spain',
  'it': 'Italy',
  'nl': 'Netherlands',
  'pt': 'Portugal',
  'be': 'Belgium',
  'at': 'Austria',
  'ch': 'Switzerland',
  'dk': 'Denmark',
  'se': 'Sweden',
  'no': 'Norway',
  'fi': 'Finland',
  'pl': 'Poland',
  'gr': 'Greece',
  'tr': 'Türkiye',
  'jp': 'Japan',
  'kr': 'South Korea',
  'br': 'Brazil',
  'mx': 'Mexico',
  'th': 'Thailand',
  'in': 'India',
  'id': 'Indonesia',
  'ph': 'Philippines',
  'za': 'South Africa',
  'ar': 'Arabic',
  'afr': 'Africa',
  'asia': 'Asia',
  'la': 'Latin America',
  'exyu': 'Balkans',
  'al': 'Albania',
  'ro': 'Romania',
  'cz': 'Czechia',
  'hu': 'Hungary',
  'hr': 'Croatia',
  'bg': 'Bulgaria',
  'ru': 'Russia',
  'ua': 'Ukraine',
  'rs': 'Serbia',
  'ba': 'Bosnia and Herzegovina',
  'si': 'Slovenia',
  'sk': 'Slovakia',
  'pk': 'Pakistan',
  'bd': 'Bangladesh',
  'lk': 'Sri Lanka',
  'vn': 'Vietnam',
  'sg': 'Singapore',
  'my': 'Malaysia',
  'hk': 'Hong Kong',
  'tw': 'Taiwan',
  'cn': 'China',
  'il': 'Israel',
  'ae': 'UAE',
  'sa': 'Saudi Arabia',
  'eg': 'Egypt',
  'ng': 'Nigeria',
  'ke': 'Kenya',
  'cl': 'Chile',
  'co': 'Colombia',
  'pe': 'Peru',
  'arg': 'Argentina',
};

final _regions = <String, String>{
  for (final entry in providerRegionNames.entries) entry.key: entry.key,
  for (final entry in providerRegionNames.entries)
    entry.value.toLowerCase(): entry.key,
  'usa': 'us',
  'u.s.a.': 'us',
  'united states': 'us',
  'united states of america': 'us',
  'gb': 'uk',
  'gbr': 'uk',
  'united kingdom': 'uk',
  'great britain': 'uk',
  'british': 'uk',
  'aus': 'au',
  'australian': 'au',
  'nzl': 'nz',
  'can': 'ca',
  'canadian': 'ca',
  'irl': 'ie',
  'irish': 'ie',
  'french': 'fr',
  'deutschland': 'de',
  'german': 'de',
  'germany': 'de',
  'deutsch': 'de',
  'espana': 'es',
  'españa': 'es',
  'spanish': 'es',
  'italia': 'it',
  'italian': 'it',
  'holland': 'nl',
  'dutch': 'nl',
  'portuguese': 'pt',
  'turkey': 'tr',
  'turkish': 'tr',
  'polska': 'pl',
  'polish': 'pl',
  'brasil': 'br',
  'brazilian': 'br',
  'korea': 'kr',
  'korean': 'kr',
  'japanese': 'jp',
  'thai': 'th',
  'arab': 'ar',
  'arabic': 'ar',
  'latino': 'la',
  'latam': 'la',
  'ex-yu': 'exyu',
  'ex yu': 'exyu',
};
final _regionWords = (_regions.keys.toList()
      ..sort((a, b) => b.length.compareTo(a.length)))
    .map(RegExp.escape)
    .join('|');
final _regionStart = RegExp('^($_regionWords)(?=\\s|[|:/–—_\\-]|\$)');
// Suffixes require a separator/bracket: "Made in" must not become India.
final _regionEnd = RegExp('\\s+[|:/–—_\\-]\\s*($_regionWords)\$');
final _bracketRegion = RegExp(r'[\[({]([^\])}]+)[\])}]');
final _edgeDecorations =
    RegExp(r'^[^\p{L}\p{N}]+|[^\p{L}\p{N}+]+$', unicode: true);
final _spacing = RegExp(r'\s+');
final _separatorStart = RegExp(r'^[\s|:/–—_\-]+');
final _explicitSeparator = RegExp(r'^\s*[|:/–—_\-]');
final _regionChainSeparator = RegExp(r'^\s*[|:/]');
final _quality = RegExp(
    r'(^|[\s|:/()\[\]_\-])(?:fhd|uhd|hd|sd|hevc|h[ .]?265|h[ .]?264|raw|vip|premium|50fps|60fps)(?=$|[\s|:/()\[\]_\-])');
final _raisedQuality = RegExp(r'[ᴴᴰᴿᴬᵂᵁᵸ³⁸⁴⁰ᴾ⁶ᶠᵖˢʰᵉᵛᶜⱽᴵᴾᴰᴼᴸᴮʸᴬᵁᴰᴵᴼ]+');
final _livePrefix = RegExp(r'^(?:live tv|live channels|iptv)\s*[|:/–—_\-]\s*');

ProviderCategory parseProviderCategory(String title) {
  var name = title
      .replaceAll(_raisedQuality, '')
      .toLowerCase()
      .replaceAll(_spacing, ' ')
      .trim();
  String? region;
  final original = name;
  var conflictingRegions = false;
  // Bracketed country tags can occur at either end; unknown tags stay intact.
  name = name.replaceAllMapped(_bracketRegion, (match) {
    final code = _regions[match.group(1)!.trim()];
    if (region != null && code != null && region != code) {
      conflictingRegions = true;
    }
    if (code == null || (region != null && region != code)) {
      return match.group(0)!;
    }
    region = code;
    return ' ';
  });
  if (conflictingRegions) return ProviderCategory(original, null);
  name = name
      .replaceAll(_quality, ' ')
      .replaceAll(_spacing, ' ')
      .replaceAll(_edgeDecorations, '')
      .trim();
  name = name.replaceFirst(_livePrefix, '');
  final prefix = _regionStart.firstMatch(name);
  final ambiguousWord =
      const {'in', 'no', 'it', 'at', 'be', 'la'}.contains(prefix?.group(1));
  final explicitPrefix = prefix != null &&
      (!ambiguousWord ||
          prefix.end == name.length ||
          _explicitSeparator.hasMatch(name.substring(prefix.end)));
  if (explicitPrefix &&
      (region == null || region == _regions[prefix.group(1)])) {
    final matched = prefix;
    region = _regions[matched.group(1)];
    final remainder =
        name.substring(matched.end).replaceFirst(_separatorStart, '');
    final second = _regionStart.firstMatch(remainder);
    if (second != null &&
        _regions[second.group(1)] != region &&
        (second.end == remainder.length ||
            _regionChainSeparator.hasMatch(remainder.substring(second.end)))) {
      return ProviderCategory(name, null);
    }
    name = remainder;
  } else {
    final suffix = _regionEnd.firstMatch(name);
    if (suffix != null &&
        (region == null || region == _regions[suffix.group(1)])) {
      region = _regions[suffix.group(1)];
      name = name.substring(0, suffix.start);
    }
  }
  return ProviderCategory(name.replaceAll(_edgeDecorations, '').trim(), region);
}

final _sportsPrefix = RegExp(r'^sports?\b[\s|:/–—_\-]+');
final _sportsSuffix = RegExp(r'\s+(?:channels?|feeds?|events?|ppv|live)$');
final _unknownSportTag = RegExp(r'^[a-z]{2,3}\s*\|\s*');
final _sportRules = <(RegExp, String, List<String>)>[
  (RegExp(r'^(?:f\s*1|formula\s*(?:1|one))\b'), 'Formula 1', ['Sports']),
  (RegExp(r'^(?:tennis|atp|wta|itf)\b'), 'Tennis', ['Sports']),
  (RegExp(r'^(?:golf|pga|lpga|liv golf)\b'), 'Golf', ['Sports']),
  (
    RegExp(r'^(?:rugby|nrl|florugby|super league rugby)\b'),
    'Rugby',
    ['Sports']
  ),
  (RegExp(r'^(?:cricket|ipl cricket|world cricket)\b'), 'Cricket', ['Sports']),
  (
    RegExp(r'^(?:horse racing|world horse racing)\b'),
    'Horse racing',
    ['Sports']
  ),
  (RegExp(r'^(?:darts|pdc)\b'), 'Darts · PDC', ['Sports']),
  (RegExp(r'^(?:volleyball|volley ball)\b'), 'Volleyball World', ['Sports']),
  (
    RegExp(r'^(?:ultimate pool|pool|billiards)\b'),
    'Pool · Ultimate Pool',
    ['Sports']
  ),
  (RegExp(r'^nba\b'), 'NBA League Pass', ['Sports', 'Basketball']),
  (RegExp(r'^nfl\b'), 'NFL Sunday Ticket', ['Sports', 'American football']),
  (RegExp(r'^mlb\b'), 'MLB.tv', ['Sports', 'Baseball']),
  (RegExp(r'^nhl\b'), 'NHL Center Ice', ['Sports', 'Ice hockey']),
  (
    RegExp(r'^(?:american football|college football|ncaa football)\b'),
    'American football',
    ['Sports']
  ),
  (
    RegExp(r'^(?:football|soccer)\b'),
    'Football channels',
    ['Sports', 'Football']
  ),
  (
    RegExp(r'^(?:epl|premier league)\b'),
    'Premier League',
    ['Sports', 'Football']
  ),
  (RegExp(r'^uefa\b'), 'UEFA', ['Sports', 'Football']),
  (RegExp(r'^la liga\b'), 'La Liga', ['Sports', 'Football']),
  (RegExp(r'^serie a\b'), 'Serie A', ['Sports', 'Football']),
  (RegExp(r'^ligue 1\b'), 'Ligue 1', ['Sports', 'Football']),
  (RegExp(r'^bundesliga\b'), 'Bundesliga', ['Sports', 'Football']),
  (RegExp(r'^(?:efl )?championship\b'), 'Championship', ['Sports', 'Football']),
  (
    RegExp(r'^(?:efl )?league (?:1|one)\b'),
    'League One',
    ['Sports', 'Football']
  ),
  (
    RegExp(r'^(?:efl )?league (?:2|two)\b'),
    'League Two',
    ['Sports', 'Football']
  ),
  (RegExp(r'^(?:basketball|wnba|ncaa basketball)\b'), 'Basketball', ['Sports']),
  (RegExp(r'^(?:baseball|npb|kbo|milb)\b'), 'Baseball', ['Sports']),
  (RegExp(r'^(?:ice hockey|hockey|ahl|khl)\b'), 'Ice hockey', ['Sports']),
  (RegExp(r'^ufc\b'), 'UFC', ['Sports']),
  (
    RegExp(r'^(?:boxing|mma|combat sports|one championship|muay thai)\b'),
    'Combat sports',
    ['Sports']
  ),
  (
    RegExp(
        r'^(?:motorsports?|moto\s?gp|nascar|indycar|v8 supercars|rally|mxgp)\b'),
    'Motorsport',
    ['Sports']
  ),
  (RegExp(r'^poker\b'), 'Poker', ['Sports']),
  (RegExp(r'^e[ -]?sports\b'), 'Esports', ['Sports']),
  (RegExp(r'^sky sports?\b'), 'Sky Sports', ['Sports', 'Sports channels']),
  (RegExp(r'^tnt sports?\b'), 'TNT Sports', ['Sports', 'Sports channels']),
  (RegExp(r'^dazn\b'), 'DAZN', ['Sports', 'Sports channels']),
  (RegExp(r'^espn\+'), 'ESPN+', ['Sports', 'Sports channels']),
  (RegExp(r'^flo sports?\b'), 'Flo Sports', ['Sports', 'Sports channels']),
];

final _generalSports = RegExp(
    r'^(?:sports?|sports? networks|sports? channels|bein sports?|espn|tsn|sportsnet|supersport)$');
final _ppv =
    RegExp(r'^(?:ppv|pay per view|live events)(?:\s+events?|\s+live)?$');

(String, List<String>)? providerSportCollection(String title) {
  final name = title
      .replaceFirst(_unknownSportTag, '')
      .replaceFirst(_sportsPrefix, '')
      .replaceFirst(_sportsSuffix, '');
  for (final (pattern, label, path) in _sportRules) {
    if (pattern.hasMatch(name)) return (label, path);
  }
  if (_generalSports.hasMatch(title)) {
    return ('Sports channels', const ['Sports']);
  }
  if (_ppv.hasMatch(title)) {
    return ('PPV events', const ['Live events & PPV']);
  }
  return null;
}
