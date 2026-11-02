import 'dart:convert';
import 'package:crypto/crypto.dart';
import '../models/sports.dart';
import 'endurance_racing.dart';
import 'sports_coverage_models.dart';

final _spaces = RegExp(r'[^a-z0-9]+');
String _norm(String s) => s.toLowerCase().replaceAll(_spaces, ' ').trim();
bool _has(String text, String phrase) => ' $text '.contains(' $phrase ');
final _series = [
  for (final league in [...kSportsLeagues, ...kSportsLeagueBank])
    if (league.kind == SportsKind.racing)
      for (final phrase in league.seriesPhrases) (league.id, _norm(phrase)),
]..sort((a, b) => b.$2.length.compareTo(a.$2.length));

// These are event/venue aliases, never channel names or proof of a broadcast.
const _venues = {
  'mexico': ['mexico', 'mexican', 'hermanos rodriguez'],
  'brazil': ['brazil', 'brazilian', 'sao paulo', 'interlagos'],
  'austin': [
    'united states grand prix',
    'us grand prix',
    'austin',
    'circuit of the americas'
  ],
  'las vegas': ['las vegas'],
  'miami': ['miami'],
  'monaco': ['monaco', 'monte carlo'],
  'silverstone': ['british grand prix', 'silverstone'],
  'spa': ['belgian', 'belgium', 'spa francorchamps'],
  'monza': ['italian grand prix', 'monza'],
  'imola': ['emilia romagna', 'imola'],
  'suzuka': ['japanese grand prix', 'suzuka'],
  'melbourne': ['australian grand prix', 'albert park', 'melbourne'],
  'shanghai': ['chinese grand prix', 'shanghai'],
  'bahrain': ['bahrain', 'sakhir'],
  'jeddah': ['saudi arabian', 'jeddah'],
  'barcelona': ['spanish grand prix', 'barcelona', 'catalunya'],
  'madrid': ['madrid', 'madring'],
  'montreal': ['canadian grand prix', 'montreal', 'gilles villeneuve'],
  'austria': ['austrian', 'austria', 'red bull ring', 'spielberg'],
  'hungary': ['hungarian', 'hungary', 'hungaroring'],
  'zandvoort': ['dutch grand prix', 'zandvoort'],
  'baku': ['azerbaijan', 'baku'],
  'singapore': ['singapore', 'marina bay'],
  'qatar': ['qatar', 'lusail', 'losail'],
  'abu dhabi': ['abu dhabi', 'yas marina'],
  'talladega': ['talladega', 'yellawood 500'],
  'martinsville': ['martinsville', 'xfinity 500'],
  'daytona': ['daytona'],
  'phoenix': ['phoenix'],
  'charlotte': ['charlotte'],
  'darlington': ['darlington', 'southern 500'],
  'bristol': ['bristol'],
  'homestead': ['homestead'],
  'pocono': ['pocono'],
  'richmond': ['richmond'],
  'kansas': ['kansas'],
  'dover': ['dover'],
  'atlanta': ['atlanta'],
  'watkins glen': ['watkins glen'],
  'sonoma': ['sonoma'],
  'indianapolis': ['indianapolis', 'brickyard'],
  'gold coast': ['gold coast', 'surfers paradise'],
  'bathurst': ['bathurst', 'mount panorama'],
};
final _numbered = RegExp(r'\b(practice|fp|race|round|heat)\s*([1-9])\b');
final _phase = RegExp(
    r'\b(pre race|post race|build up|buildup|preview|review|grid walk|chequered flag|checkered flag|supports?|support races?)\b');
final _noise = RegExp(
    r'\b(live|hd|uhd|fhd|sd|4k|hdr|coverage|motor racing|motorsport|series|championship|grand prix|gp|race|racing|qualifying|qualification|practice|sprint|the|at|from|of|formula|one|cup|nascar|f1|[12][0-9]{3})\b');

class _Identity {
  const _Identity(this.series, this.event, this.session);
  final String series, event, session;
  String get eventKey => '$series|$event';
  String get key => '$series|$event|$session';
}

String _session(String value) {
  if (value.contains('sprint') &&
      (value.contains('qual') || value.contains('shootout'))) {
    return 'sprint qualifying';
  }
  final numbered = _numbered.firstMatch(value);
  if (numbered != null) {
    return '${numbered[1] == 'fp' ? 'practice' : numbered[1]} ${numbered[2]}';
  }
  if (value.contains('qualif')) return 'qualifying';
  if (_has(value, 'practice')) return 'practice';
  if (_has(value, 'sprint')) return 'sprint';
  if (_has(value, 'race')) return 'race';
  return '';
}

final _identities = Expando<(_Identity?,)>();
_Identity? _identity(SportsGame game) {
  if (!game.league.espnPath.startsWith('racing/')) return null;
  final cached = _identities[game];
  if (cached != null) return cached.$1;
  final result = _readIdentity(game);
  _identities[game] = (result,);
  return result;
}

_Identity? _readIdentity(SportsGame game) {
  if (!game.league.espnPath.startsWith('racing/')) return null;
  final title = _norm(game.title);
  // Keep studio shows and support packages distinct from the headline race.
  if (_phase.hasMatch(title)) return null;
  final description = game.isGuideEvent && game.guideProgrammes.isNotEmpty
      ? _norm(game.guideProgrammes.first.description ?? '')
      : '';
  String? series;
  // Title wins over incidental mentions of another series in the synopsis.
  for (final text in [title, description]) {
    for (final entry in _series) {
      if (_has(text, entry.$2)) {
        series = entry.$1;
        break;
      }
    }
    series ??= enduranceLeagueId(text, '');
    if (series != null) break;
  }
  if (!game.isGuideEvent) series = game.league.id;
  if (series == null) return null;
  // A bare NASCAR listing cannot distinguish Cup from Trucks/Xfinity.
  if (game.isGuideEvent &&
      series == 'racing.nascar-premier' &&
      !_has('$title $description', 'cup')) {
    return null;
  }
  String? venue;
  for (final text in [title, _norm(game.event?.venue ?? ''), description]) {
    final found = _venues.entries
        .where((e) => e.value.any((alias) => _has(text, alias)))
        .map((e) => e.key)
        .toSet();
    if (found.length > 1) return null;
    if (found.length == 1) {
      venue = found.single;
      break;
    }
  }
  var session = _session(_norm(game.event?.session ?? ''));
  if (session.isEmpty) session = _session(title);
  // Do not infer a session from prose mentioning other races/practices.
  var name = title;
  for (final entry in _series.where((e) => e.$1 == series)) {
    name = ' $name '.replaceAll(' ${entry.$2} ', ' ').trim();
  }
  name = name.replaceAll(_numbered, '').replaceAll(_noise, ' ');
  final words = name.split(RegExp(r'\s+')).where((s) => s.isNotEmpty).toList()
    ..sort();
  // Generic titles like "Live F1" are not enough to combine sessions.
  if (venue == null && words.join(' ').length < 6) return null;
  return _Identity(series, venue ?? words.join(' '), session);
}

bool _overlaps(SportsGame a, SportsGame b) {
  final endA = a.end, endB = b.end;
  if (endA == null || endB == null) return false;
  if (a.start.difference(b.start).abs() > const Duration(minutes: 90)) {
    return false;
  }
  final start = a.start.isAfter(b.start) ? a.start : b.start;
  final end = endA.isBefore(endB) ? endA : endB;
  final shortest = endA.difference(a.start) < endB.difference(b.start)
      ? endA.difference(a.start)
      : endB.difference(b.start);
  return shortest.inSeconds > 0 &&
      end.difference(start).inSeconds * 2 >= shortest.inSeconds;
}

/// Runs on the existing guide worker. Bucket by series/event/session first;
/// compare only overlapping broadcasts, never every channel against every one.
List<SportsGame> coalesceMotorsportCoverage(List<SportsGame> games) {
  final buckets = <String, List<List<SportsGame>>>{};
  final sessions = <String, Set<String>>{};
  final untouched = <SportsGame>[];
  final ordered = [...games]..sort((a, b) {
      final start = a.start.compareTo(b.start);
      return start != 0 ? start : a.id.compareTo(b.id);
    });
  for (final game in ordered) {
    final identity = game.isGuideEvent ? _identity(game) : null;
    if (identity == null) {
      untouched.add(game);
      continue;
    }
    final groups = buckets.putIfAbsent(identity.key, () => []);
    if (identity.session.isNotEmpty) {
      (sessions[identity.eventKey] ??= {}).add(identity.key);
    }
    // Compare to the original representative, not an ever-expanding window.
    final group = groups.where((g) => _overlaps(g.first, game)).firstOrNull;
    if (group == null) {
      groups.add([game]);
    } else {
      group.add(game);
    }
  }
  // A provider may omit "Race" from its title. Resolve that omission only
  // when exactly one overlapping explicit session exists for this event.
  for (final key in buckets.keys.where((k) => k.endsWith('|')).toList()) {
    final remaining = <List<SportsGame>>[];
    for (final group in buckets[key]!) {
      final candidates = [
        for (final session
            in sessions[key.substring(0, key.length - 1)] ?? <String>{})
          for (final candidate in buckets[session]!)
            if (group.every((g) => _overlaps(candidate.first, g))) candidate,
      ];
      if (candidates.length == 1) {
        candidates.single.addAll(group);
      } else {
        remaining.add(group);
      }
    }
    buckets[key] = remaining;
  }
  for (final entry in buckets.entries) {
    entry.value.sort((a, b) => a.first.start.compareTo(b.first.start));
    for (final (index, group) in entry.value.indexed) {
      group.sort((a, b) {
        if (a.state != b.state) return a.state == GameState.live ? -1 : 1;
        final title = a.title.length.compareTo(b.title.length);
        return title != 0 ? title : a.id.compareTo(b.id);
      });
      final first = group.first;
      final programmes = [for (final g in group) ...g.guideProgrammes]
        ..sort((a, b) => a.channelId.compareTo(b.channelId));
      final start =
          group.map((g) => g.start).reduce((a, b) => a.isBefore(b) ? a : b);
      final end =
          group.map((g) => g.end!).reduce((a, b) => a.isAfter(b) ? a : b);
      final key =
          '${entry.key}|${start.toUtc().toIso8601String().substring(0, 10)}|$index';
      untouched.add(copyGuideCoverage(first, programmes,
          id:
              'guide:motor:${sha256.convert(utf8.encode(key)).toString().substring(0, 24)}',
          event: SportsEventInfo(
              title: first.title,
              session: entry.key.split('|').last,
              venue: first.event?.venue),
          start: start,
          end: end));
    }
  }
  return untouched;
}

/// Prefer the scored/calendar card only on unambiguous event AND session
/// identity. Preserve its IDs/timing/scores and attach the exact guide slots.
/// Uncertain coverage stays visible instead of disappearing into a guess.
List<SportsGame> mergeMotorsportCoverage(
    List<SportsGame> scheduled, List<SportsGame> guide) {
  // Discovery can be reapplied to already enriched cards. Replace previous
  // attachments instead of accumulating slots or retaining removed evidence.
  scheduled = scheduled.map(withoutGuideCoverage).toList();
  final result = [...scheduled];
  final buckets = <String, List<int>>{};
  for (var i = 0; i < scheduled.length; i++) {
    final identity = _identity(scheduled[i]);
    if (identity == null || identity.session.isEmpty) continue;
    (buckets[identity.eventKey] ??= []).add(i);
  }
  for (final game in guide) {
    final identity = _identity(game);
    final hits = identity == null
        ? const <int>[]
        : (buckets[identity.eventKey] ?? const <int>[]).where((i) {
            final target = scheduled[i];
            return (identity.session.isEmpty ||
                    identity.session == _identity(target)!.session) &&
                target.state != GameState.post &&
                !target.start.isBefore(game.start) &&
                target.start.isBefore(game.end!) &&
                target.start.difference(game.start) <=
                    const Duration(minutes: 90);
          }).toList();
    if (hits.length != 1) {
      result.add(game);
      continue;
    }
    final i = hits.single;
    result[i] = attachGuideCoverage(result[i], game);
  }
  return result;
}
