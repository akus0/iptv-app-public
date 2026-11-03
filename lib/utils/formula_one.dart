import '../models/channel.dart';
import '../models/sports.dart';

bool isFormulaOne(SportsGame game) => game.league.id == 'racing.f1';

String f1SessionKind(String? value) {
  final s =
      (value ?? '').toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim();
  if (s.contains('sprint') && (s.contains('qual') || s.contains('shootout'))) {
    return 'sprint qualifying';
  }
  if (s == 'ss' || s == 'sq') return 'sprint qualifying';
  if (s.contains('sprint') || s == 'sr') return 'sprint';
  for (var i = 1; i <= 3; i++) {
    if (s.contains('practice $i') || s == 'fp$i' || s == 'fp $i') {
      return 'practice $i';
    }
  }
  if (s.contains('qual')) return 'qualifying';
  if (s == 'race' || s == 'grand prix') return 'race';
  return s;
}

Duration f1BuildUpLead(SportsGame game) =>
    Duration(minutes: f1SessionKind(game.event?.session) == 'race' ? 90 : 30);
Duration f1SessionDuration(String? session) => switch (f1SessionKind(session)) {
      'race' => const Duration(hours: 3),
      'qualifying' => const Duration(minutes: 90),
      _ => const Duration(hours: 1),
    };
bool isF1BuildUp(SportsGame game, DateTime now) =>
    isFormulaOne(game) &&
    game.state == GameState.pre &&
    now.isBefore(game.start) &&
    !now.isBefore(game.start.subtract(f1BuildUpLead(game)));
bool isF1CoverageWindow(SportsGame game, DateTime now) =>
    isFormulaOne(game) &&
    game.state != GameState.post &&
    !now.isBefore(game.start.subtract(f1BuildUpLead(game))) &&
    now.isBefore(
        game.end ?? game.start.add(f1SessionDuration(game.event?.session)));

enum F1Feed { main, onboard, tracker, data, pitLane, other }

String f1FeedLabel(F1Feed feed) => switch (feed) {
      F1Feed.main => 'Main coverage',
      F1Feed.onboard => 'Driver onboard',
      F1Feed.tracker => 'Driver tracker',
      F1Feed.data => 'Timing & data',
      F1Feed.pitLane => 'Pit lane',
      F1Feed.other => 'Other F1 feeds',
    };
final _f1 = RegExp(r'\bf1\b|\bformula\s*(?:1|one)\b', caseSensitive: false);
final _inactiveF1 = RegExp(
    r'no event|offline|not streaming|replay|highlights|classic|^end\b|^ended\b',
    caseSensitive: false);

/// Narrow roles from explicit feed names. Never infer F1 merely from a group:
/// the user's F1 PPV group also contains a MotoGP channel.
F1Feed? f1FeedKind(Channel channel) {
  final name = channel.name.toLowerCase();
  if (name.trimLeft().startsWith('#') || !_f1.hasMatch(name)) return null;
  if (RegExp(r'on.?board|driver cam|cockpit').hasMatch(name) ||
      (name.startsWith('f1:') && name.split('|').length >= 3)) {
    return F1Feed.onboard;
  }
  if (name.contains('tracker')) return F1Feed.tracker;
  if (name.contains('timing') || name.contains('f1-data')) return F1Feed.data;
  if (name.contains('pit lane') || name.contains('pitlane')) {
    return F1Feed.pitLane;
  }
  // FAST channels called "F1 Channel" and dated Apple PPV placeholders aren't
  // evidence of a live broadcaster. Keep them in Other, never auto-promote.
  if (!_inactiveF1.hasMatch(name) &&
      (RegExp(r'\bsky sports f1\b').hasMatch(name) ||
          (name.startsWith('f1: f1-tv') && _f1.hasMatch(channel.group)))) {
    return F1Feed.main;
  }
  return F1Feed.other;
}

// Only explicit place names count as a conflicting Grand Prix. Unknown guide
// wording stays unknown instead of rejecting a potentially useful feed.
const _f1Places = <List<String>>[
  ['australia', 'australian', 'melbourne'],
  ['china', 'chinese', 'shanghai'],
  ['japan', 'japanese', 'suzuka'],
  ['bahrain', 'sakhir'],
  ['saudi', 'jeddah'],
  ['miami'],
  ['canada', 'canadian', 'montreal'],
  ['monaco', 'monte carlo'],
  ['barcelona', 'catalunya'],
  ['austria', 'austrian', 'spielberg'],
  ['britain', 'british', 'silverstone'],
  ['belgium', 'belgian', 'spa'],
  ['hungary', 'hungarian', 'hungaroring'],
  ['netherlands', 'dutch', 'zandvoort'],
  ['italy', 'italian', 'monza'],
  ['madrid', 'madring'],
  ['azerbaijan', 'baku'],
  ['singapore', 'marina bay'],
  ['united states', 'austin', 'americas', 'cota'],
  ['mexico', 'mexican', 'hermanos rodriguez'],
  ['brazil', 'brazilian', 'sao paulo', 'interlagos'],
  ['las vegas'],
  ['qatar', 'lusail', 'losail'],
  ['abu dhabi', 'yas marina'],
];
final _f1Words = RegExp(r'[^a-z0-9]+');
String _placeText(String text) =>
    ' ${text.toLowerCase().replaceAll(_f1Words, ' ')} ';
bool f1ProgrammeConflicts(SportsGame game, String text) {
  if (!isFormulaOne(game)) return false;
  final guide = _placeText(text);
  if (RegExp(r' (?:f2|f3|formula 2|formula 3|motogp|moto2|moto3) ')
          .hasMatch(guide) &&
      !_f1.hasMatch(guide)) {
    return true;
  }
  if (!guide.contains(' grand prix ') && !guide.contains(' gp ')) return false;
  final event = _placeText([
    game.event?.title ?? '',
    game.event?.venue ?? '',
    ...?game.event?.matchingNames
  ].join(' '));
  final ours = <int>{}, theirs = <int>{};
  for (var i = 0; i < _f1Places.length; i++) {
    if (_f1Places[i].any((p) => event.contains(' $p '))) ours.add(i);
    if (_f1Places[i].any((p) => guide.contains(' $p '))) theirs.add(i);
  }
  return ours.isNotEmpty &&
      theirs.isNotEmpty &&
      ours.intersection(theirs).isEmpty;
}
