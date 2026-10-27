import '../models/sports.dart';
import '../utils/replay_event_date.dart';
import 'sports_replay_service.dart';
import 'sports_service.dart';

/// Optional, bounded enrichment. The local replay list never waits for this.
/// Schedule identity alone cannot establish which repeat a channel is airing,
/// so all online dates remain explicitly possible, without scores/spoilers.
class ReplayScheduleService {
  ReplayScheduleService(
      {required this.fetch, required this.cached, DateTime Function()? clock})
      : clock = clock ?? DateTime.now;
  static final instance = ReplayScheduleService(
      fetch: SportsService.instance.replayGames,
      cached: () => SportsService.instance.cachedReplayGames);
  final Future<List<SportsGame>> Function(SportsLeague, DateTime) fetch;
  final List<SportsGame> Function() cached;
  final DateTime Function() clock;
  final _days = <String, (DateTime, List<SportsGame>)>{};
  final _resolved = <String, (DateTime, ReplayEventDate?)>{};
  Future<void> _queue = Future.value();
  DateTime? _budgetAt;
  int _requests = 0;

  static String key(SportsReplay event) => '${event.sport}|${event.title}|'
      '${event.broadcasts.first.programme.description}|'
      '${event.broadcasts.first.programme.start.toUtc().toIso8601String().substring(0, 10)}';

  ReplayEventDate? known(SportsReplay event) {
    final hit = _resolved[key(event)];
    return hit != null && clock().difference(hit.$1) < const Duration(hours: 6)
        ? hit.$2
        : null;
  }

  Future<void> enrich(List<SportsReplay> events,
      {required bool Function() cancelled, required void Function() onUpdate}) {
    final job = _queue.then((_) => _enrich(events, cancelled, onUpdate));
    _queue = job.catchError((Object _) {});
    return job;
  }

  Future<void> _enrich(List<SportsReplay> events, bool Function() cancelled,
      void Function() onUpdate) async {
    if (cancelled()) return;
    final now = clock();
    if (_budgetAt == null ||
        now.difference(_budgetAt!) >= const Duration(minutes: 10)) {
      _budgetAt = now;
      _requests = 0;
    }
    final initial = cached();
    final groups = <SportsLeague, List<SportsReplay>>{};
    var cachedUpdates = false;
    for (final event in events) {
      if (event.eventDate != null ||
          !event.broadcasts.first.programme.isNowPlaying(now)) {
        continue;
      }
      final league = replayScheduleLeague(event);
      if (league == null) continue;
      final hit = _resolved[key(event)];
      final matches = replayScheduleMatches(event, initial);
      if (matches.length > 1) {
        _resolved[key(event)] = (now, null);
        cachedUpdates = cachedUpdates || hit?.$2 != null;
        continue;
      }
      final existing = possibleReplayDate(event, initial);
      if (existing != null) {
        _resolved[key(event)] = (now, existing);
        cachedUpdates = cachedUpdates || hit?.$2?.label != existing.label;
        continue;
      }
      if (hit != null &&
          now.difference(hit.$1) <
              (hit.$2 == null
                  ? const Duration(minutes: 30)
                  : const Duration(hours: 6))) {
        continue;
      }
      (groups[league] ??= []).add(event);
    }
    while (_resolved.length > 256) {
      _resolved.remove(_resolved.keys.first);
    }
    if (cachedUpdates && !cancelled()) onUpdate();
    // One request at a time; four requests per ten minutes across the entire
    // app session, including repeated tab visits and pull-to-refresh.
    for (final entry in groups.entries) {
      if (cancelled()) return;
      final games = <SportsGame>[...initial];
      var complete = true;
      for (final offset in [1, 7]) {
        if (cancelled()) return;
        final day = DateTime.utc(now.year, now.month, now.day)
            .subtract(Duration(days: offset));
        final dayKey = '${entry.key.id}|${day.toIso8601String()}';
        var hit = _days[dayKey];
        if (hit == null ||
            now.difference(hit.$1) >= const Duration(minutes: 30)) {
          if (_requests >= 4) {
            complete = false;
            continue;
          }
          _requests++;
          try {
            final rows = await fetch(entry.key, day);
            hit = (now, rows);
          } catch (_) {
            hit = (now, <SportsGame>[]);
          }
          _days[dayKey] = hit;
          while (_days.length > 32) {
            _days.remove(_days.keys.first);
          }
        }
        games.addAll(hit.$2);
      }
      if (cancelled()) return;
      var changed = false;
      for (final event in entry.value) {
        final result = possibleReplayDate(event, games);
        if (result != null || complete) {
          _resolved[key(event)] = (now, result);
          changed = changed || result != null;
        }
      }
      while (_resolved.length > 256) {
        _resolved.remove(_resolved.keys.first);
      }
      if (changed) onUpdate();
      await Future<void>.delayed(Duration.zero);
    }
  }
}

final _leagues = <String, (String, RegExp)>{
  'nfl': ('football', RegExp(r'\bnfl\b', caseSensitive: false)),
  'college-football': (
    'football',
    RegExp(r'\b(?:college football|ncaaf)\b', caseSensitive: false)
  ),
  'nba': ('basketball', RegExp(r'\bnba\b', caseSensitive: false)),
  'wnba': ('basketball', RegExp(r'\bwnba\b', caseSensitive: false)),
  'mlb': ('baseball', RegExp(r'\bmlb\b', caseSensitive: false)),
  'nhl': ('hockey', RegExp(r'\bnhl\b', caseSensitive: false)),
  'eng.1': (
    'soccer',
    RegExp(r'\b(?:premier league|epl|pl)\b', caseSensitive: false)
  ),
  'esp.1': ('soccer', RegExp(r'\blaliga\b', caseSensitive: false)),
  'uefa.champions': (
    'soccer',
    RegExp(r'\b(?:uefa champions league|ucl)\b', caseSensitive: false)
  ),
  'ita.1': ('soccer', RegExp(r'\bserie a\b', caseSensitive: false)),
  'aus.1': (
    'soccer',
    RegExp(r'\ba-league(?: men|: men)\b', caseSensitive: false)
  ),
};
final _versus = RegExp(r'\s(?:vs?\.?|versus|at|faces?|hosts?|meets?)\s|\s@\s',
    caseSensitive: false);
final _excluded = RegExp(
    r'\b(?:u[ -]?\d{2}|under[ -]?\d{2}|youth|reserve|academy|classics?|greatest|highlights?|game\s*\d|week\s*\d|round\s*\d|if necessary)\b',
    caseSensitive: false);

SportsLeague? replayScheduleLeague(SportsReplay event) {
  final text =
      '${event.title} ${event.broadcasts.first.programme.description ?? ''}';
  // No youth/senior substitutions, classic guesses, series-game ambiguity or
  // speculative fixtures. Explicit years/seasons are already kept locally.
  if (_excluded.hasMatch(text) || !_versus.hasMatch(event.title)) return null;
  final matches = _leagues.entries
      .where((e) => e.value.$1 == event.sport && e.value.$2.hasMatch(text))
      .toList();
  if (matches.length != 1) return null;
  final id = matches.single.key;
  if (id != 'wnba' &&
      RegExp(r'\bwomen|\bwomens|\bladies\b', caseSensitive: false)
          .hasMatch(text)) {
    return null;
  }
  return sportsLeagueById(id);
}

String _normal(String s) =>
    s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim();
bool _sideMatches(String title, SportsTeam team, SportsLeague league) {
  // Exact API team names only; never abbreviations, city-only pro matches,
  // edit-distance guesses, or a shared nickname such as Tigers/United.
  final aliases = <String>{team.name};
  if (league.id == 'college-football' && team.location != null) {
    aliases.add(team.location!);
  }
  if (league.soccer && team.shortName.contains(' ')) {
    aliases.add(team.shortName);
  }
  return aliases.any((a) {
    final name = _normal(a);
    return name.length >= 5 && title == name;
  });
}

List<SportsGame> replayScheduleMatches(
    SportsReplay event, Iterable<SportsGame> games) {
  if (event.eventDate != null) return [];
  final league = replayScheduleLeague(event);
  if (league == null) return [];
  final separator = _versus.firstMatch(event.title);
  if (separator == null) return [];
  var left = event.title.substring(0, separator.start);
  final right = event.title.substring(separator.end).replaceAll(
      RegExp(r'\s*[\[(](?:replay|repeat|r|rpt)[\])]\s*', caseSensitive: false),
      '');
  left = left.split(RegExp(r':|\s[-–—]\s')).last;
  left = left.replaceFirst(_leagues[league.id]!.$2, '').replaceFirst(
      RegExp(r'^\s*(?:baseball|basketball|football)\s+', caseSensitive: false),
      '');
  final sides = [_normal(left), _normal(right)];
  final airing = event.broadcasts.first.programme.start.toUtc();
  final candidates = <String, SportsGame>{};
  for (final game in games) {
    if (game.league.id != league.id ||
        game.state != GameState.post ||
        !RegExp(r'^(?:final|full time|ft\b)', caseSensitive: false)
            .hasMatch(game.statusText) ||
        airing.difference(game.start) < const Duration(hours: 4) ||
        airing.difference(game.start).inDays > 14 ||
        !((_sideMatches(sides[0], game.home, league) &&
                _sideMatches(sides[1], game.away, league)) ||
            (_sideMatches(sides[1], game.home, league) &&
                _sideMatches(sides[0], game.away, league)))) {
      continue;
    }
    candidates[game.id] = game;
  }
  return candidates.values.toList();
}

ReplayEventDate? possibleReplayDate(
    SportsReplay event, Iterable<SportsGame> games) {
  final candidates = replayScheduleMatches(event, games);
  if (candidates.length != 1) return null;
  final g = candidates.single;
  final league = g.league;
  final day = g.start.toUtc();
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec'
  ];
  return ReplayEventDate(
      ReplayDatePrecision.day,
      '${day.day} ${months[day.month - 1]} ${day.year}',
      'Possible ESPN schedule match: ${g.home.name} vs ${g.away.name}, ${league.name}. '
          'Both teams and competition match a completed game. This limited schedule search '
          'does not prove this is the same replay. Date is the scheduled start in UTC.',
      day: DateTime.utc(day.year, day.month, day.day),
      year: day.year,
      isPossible: true);
}
