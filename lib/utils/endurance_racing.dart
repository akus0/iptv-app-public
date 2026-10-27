/// Specific race/series names shared by guide discovery and channel matching.
/// No bare circuit, manufacturer or 'endurance' words: those also describe
/// football teams, films, road cars and non-racing programmes.
final enduranceSeriesPatterns = <String, RegExp>{
  'racing.ewc': _rx(
      r'24[ -]*(?:hours?|h)[ -]*(?:of )?le mans[ -]*(?:motorcycles|motos)|fim ewc|endurance world championship|24\s*(?:h(?:eures?|ours?)?)[ -]*(?:du mans[ -]*)?motos?|bol d[\x27’ ]?or|(?:suzuka[ -]*8[ -]*(?:hours?|h)|8[ -]*(?:hours?|heures)[ -]*(?:of |de )?suzuka)|8[ -]*(?:hours?|heures)[ -]*(?:of |de )?spa[ -]*motos?'),
  'racing.asian-le-mans':
      _rx(r'asian le mans(?: series| cup)?|winter le mans series|aslms'),
  'racing.le-mans-cup': _rx(r'(?:michelin )?le mans cup|road to le mans'),
  'racing.elms': _rx(r'european le mans(?: series)?|elms'),
  'racing.imsa-pilot': _rx(r'(?:imsa )?michelin pilot challenge'),
  'racing.imsa': _rx(
      r'imsa|weathertech sportscar|rolex[ -]*24|(?:24[ -]*(?:hours?|h)|twenty[ -]four hours)[ -]*(?:of |at )?daytona|(?:12[ -]*(?:hours?|h)|twelve hours)[ -]*(?:of |at )?sebring|petit le mans|(?:6[ -]*(?:hours?|h)|six hours)[ -]*(?:of |at )?(?:the glen|watkins glen)|battle on the bricks'),
  'racing.24h-series': _rx(
      r'24[ -]*h[ -]*series|24[ -]*hour series|creventic|(?:24[ -]*(?:hours?|h))[ -]*(?:of |at )?(?:dubai|barcelona|portimao)|(?:12[ -]*(?:hours?|h))[ -]*(?:of |at )?(?:mugello|spa(?:[ -]francorchamps)?|paul ricard|n[uü]rburgring)|992 endurance cup'),
  'racing.nls': _rx(
      r'n[uü]rburgring (?:langstrecken[ -]serie|endurance series)|adac nls|nls[ -]*(?:race|round|[1-9])|vln(?: endurance|[ -]*[1-9])'),
  'racing.super-taikyu':
      _rx(r'super[ -]?taikyu|s[ -]taikyu|fuji[ -]*24[ -]*(?:hours?|h)'),
  'racing.igtc': _rx(
      r'intercontinental gt challenge|igtc|bathurst[ -]*12[ -]*(?:hours?|h)|12[ -]*(?:hours?|h)[ -]*(?:of |at )?bathurst|suzuka[ -]*1000[ -]*km|indianapolis[ -]*8[ -]*(?:hours?|h)|8[ -]*(?:hours?|h)[ -]*(?:of |at )?indianapolis|(?:24[ -]*(?:hours?|heures|h))[ -]*(?:of |at |de )?(?:spa|n[uü]rburgring)|n[uü]rburgring[ -]*24[ -]*(?:hours?|h)'),
  'racing.british-gt': _rx(r'british gt|silverstone[ -]*500'),
  'racing.gt-open': _rx(r'international gt open|gt open[ -]*(?:500|endurance)'),
  'racing.gtwc-america': _rx(r'gt world challenge america|gtwc america'),
  'racing.gtwc-asia': _rx(r'gt world challenge asia|gtwc asia'),
  'racing.gtwc-australia': _rx(r'gt world challenge australia|gtwc australia'),
  'racing.gtwc': _rx(
      r'gt world challenge europe|gtwc europe|(?:gt world challenge|blancpain gt)(?: europe)? endurance(?: cup)?'),
  'racing.wec': _rx(
      r'lone star le mans|qatar[ -]*1812[ -]*km|world endurance championship|wec|(?:24[ -]*(?:hours?|heures|h)|twenty[ -]four hours)[ -]*(?:of |du |de )?le? ?mans|24[ -]*(?:hours?|heures|h)[ -]*du mans'),
};

RegExp _rx(String value) =>
    RegExp(r'\b(?:' + value + r')\b', caseSensitive: false);

/// Title identity wins over incidental references to another series in a
/// synopsis. Ordering distinguishes Petit Le Mans and bike races from WEC.
String? enduranceLeagueId(String title, String description) {
  for (final text in [
    title,
    description.length > 640 ? description.substring(0, 640) : description
  ]) {
    if (text.isEmpty) continue;
    for (final entry in enduranceSeriesPatterns.entries) {
      if (entry.value.hasMatch(text)) return entry.key;
    }
  }
  return null;
}

final enduranceGuidePattern = RegExp(
    enduranceSeriesPatterns.values.map((r) => r.pattern).join('|'),
    caseSensitive: false);

/// Circuit names and broadcast race names often differ. These aliases are
/// series-specific so a shared track cannot turn an unrelated race into a match.
List<String> enduranceVenueAliases(String leagueId, String venue) {
  final text = venue.toLowerCase();
  if (leagueId == 'racing.wec' &&
      (text.contains('sarthe') ||
          text.contains('le mans') ||
          text.contains('du mans'))) {
    return const ['Le Mans', '24 Hours of Le Mans', '24 Heures du Mans'];
  }
  if (leagueId == 'racing.imsa') {
    if (text.contains('daytona')) return const ['Daytona', 'Rolex 24'];
    if (text.contains('sebring')) return const ['Sebring'];
    if (text.contains('road atlanta')) {
      return const ['Road Atlanta', 'Petit Le Mans'];
    }
    if (text.contains('watkins')) {
      return const ['Watkins Glen', 'Six Hours of the Glen'];
    }
    if (text.contains('indianapolis')) {
      return const ['Indianapolis', 'Battle on the Bricks'];
    }
  }
  if (leagueId == 'racing.igtc') {
    if (text.contains('panorama') || text.contains('bathurst')) {
      return const ['Bathurst', 'Bathurst 12 Hour'];
    }
    if (text.contains('spa')) {
      return const ['Spa Francorchamps', '24 Hours of Spa', 'Spa 24 Hours'];
    }
    if (text.contains('nürburgring') ||
        text.contains('nurburgring') ||
        text.contains('nordschleife')) {
      return const ['Nürburgring', 'Nurburgring', '24h Nürburgring'];
    }
    if (text.contains('suzuka')) return const ['Suzuka', 'Suzuka 1000km'];
    if (text.contains('indianapolis')) {
      return const ['Indianapolis', 'Indianapolis 8 Hour'];
    }
  }
  return const [];
}
