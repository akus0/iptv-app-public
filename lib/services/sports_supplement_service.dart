import 'formula_one_schedule_service.dart';
import '../utils/formula_one.dart';
import '../utils/combat_sports.dart';
import 'dart:async';
import 'dart:convert';
import 'motorsport_schedule_service.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../models/sports.dart';
import '../models/channel.dart';
import 'league_broadcast_service.dart';
import 'tennis_broadcast_service.dart';
import 'sky_tennis_schedule_service.dart';
import 'sports_channel_matcher.dart' show sportsNormalize;

/// Optional, additive public schedules/TV listings. ESPN never waits for this.
/// Free v1 results are deliberately limited by TheSportsDB; do not treat these
/// as a complete scoreboard or infer live status from a scheduled start time.
class SportsSupplementService {
  SportsSupplementService._()
      : _client = http.Client(),
        _official = LeagueBroadcastService.instance,
        _tennis = TennisBroadcastService.instance,
        _motorsport = MotorsportScheduleService.instance,
        _formulaOne = FormulaOneScheduleService.instance;
  @visibleForTesting
  SportsSupplementService.withClient(this._client,
      {this.requestSpacing = const Duration(seconds: 3),
      LeagueBroadcastService? official,
      TennisBroadcastService? tennis,
      MotorsportScheduleService? motorsport,
      FormulaOneScheduleService? formulaOne})
      : _official = official,
        _tennis = tennis,
        _motorsport = motorsport,
        _formulaOne = formulaOne;
  static final instance = SportsSupplementService._();
  final http.Client _client;
  final LeagueBroadcastService? _official;
  final TennisBroadcastService? _tennis;
  final MotorsportScheduleService? _motorsport;
  final FormulaOneScheduleService? _formulaOne;
  final _combinedDays = <String,
      (
    List<SportsGame>,
    List<SportsGame>,
    List<SportsGame>,
    List<SportsGame>
  )>{};

  Future<void> warmMotorsport(List<SportsLeague> leagues,
      {required bool Function() cancelled}) async {
    if (leagues.any((l) => l.kind == SportsKind.racing)) {
      await Future.wait([
        if (_motorsport != null) _motorsport.warm(cancelled: cancelled),
        if (_formulaOne != null && leagues.any((l) => l.id == 'racing.f1'))
          _formulaOne.warm(cancelled: cancelled),
      ]);
    }
  }

  Future<void> warmBroadcasts(List<SportsGame> games,
      {required bool Function() cancelled}) async {
    await Future.wait([
      if (_official != null) _official.warm(games, cancelled: cancelled),
      if (_tennis != null) _tennis.warm(games, cancelled: cancelled),
    ]);
  }

  void configureTennisChannels(Iterable<Channel> channels) =>
      _tennis?.configureChannels(channels);

  Duration requestSpacing = const Duration(seconds: 3);
  final _cache = <String, (Map<String, dynamic>, DateTime)>{};
  final _inFlight = <String, Future<Map<String, dynamic>>>{};
  final _listings = <String, (List<SportsBroadcast>, DateTime)>{};
  final _lookingUp = <String, Future<List<SportsBroadcast>>>{};
  final _days = <String, List<SportsGame>>{};
  final _dayParsedAt = <String, DateTime>{};
  String _dayKey(List<SportsLeague> leagues, DateTime day) =>
      '${_date(day)}:${(leagues.map((l) => l.id).toList()..sort()).join(',')}';
  List<SportsGame> cachedGamesForDay(List<SportsLeague> leagues, DateTime day) {
    final key = _dayKey(leagues, day);
    final primary = _days[key] ?? const <SportsGame>[];
    final motor = leagues.any((l) => l.kind == SportsKind.racing)
        ? _motorsport?.gamesForDay(day) ?? const <SportsGame>[]
        : const <SportsGame>[];
    final f1 = leagues.any((l) => l.id == 'racing.f1')
        ? _formulaOne?.gamesForDay(day) ?? const <SportsGame>[]
        : const <SportsGame>[];
    if (motor.isEmpty && f1.isEmpty) return primary;
    final old = _combinedDays[key];
    if (old != null &&
        identical(old.$1, primary) &&
        identical(old.$2, motor) &&
        identical(old.$3, f1)) {
      return old.$4;
    }
    final enabled = leagues.map((l) => l.id).toSet();
    final combined =
        mergeSupplementGames(mergeSupplementGames(f1, motor), primary)
            .where((g) =>
                sportsLeagueById(g.league.id)?.source != 'RaceTV Guide' ||
                enabled.contains(g.league.id))
            .toList();
    _combinedDays[key] = (primary, motor, f1, combined);
    while (_combinedDays.length > 8) {
      _combinedDays.remove(_combinedDays.keys.first);
    }
    return combined;
  }

  Future<void> _queue = Future.value();
  DateTime _nextRequest = DateTime(2000), _cooldown = DateTime(2000);

  static const sports = {
    'soccer': 'Soccer',
    'football': 'American Football',
    'basketball': 'Basketball',
    'baseball': 'Baseball',
    'hockey': 'Ice Hockey',
    'tennis': 'Tennis',
    'golf': 'Golf',
    'mma': 'Fighting',
    'racing': 'Motorsport',
    'australian-football': 'Australian Football',
    'rugby': 'Rugby',
    'volleyball': 'Volleyball',
  };
  static String eventKey(SportsGame g) => '${g.league.id}:${g.id}';
  static String _date(DateTime d) => d.toIso8601String().substring(0, 10);
  static List<DateTime> _dates(DateTime day) {
    final start = DateTime(day.year, day.month, day.day).toUtc();
    final end = DateTime(day.year, day.month, day.day + 1)
        .subtract(const Duration(milliseconds: 1))
        .toUtc();
    return [start, if (_date(start) != _date(end)) end];
  }

  Future<Map<String, dynamic>> _get(String endpoint, Map<String, String> query,
      {bool Function()? cancelled}) {
    final uri = Uri.https(
        'www.thesportsdb.com', '/api/v1/json/123/$endpoint.php', query);
    final key = uri.toString();
    final old = _cache[key];
    if (old != null &&
        DateTime.now().difference(old.$2) < const Duration(minutes: 15)) {
      return Future.value(old.$1);
    }
    return _inFlight[key] ??= () async {
      final previous = _queue;
      final done = Completer<void>();
      _queue = done.future;
      try {
        await previous;
        if (cancelled?.call() == true || DateTime.now().isBefore(_cooldown)) {
          return <String, dynamic>{};
        }
        final delay = _nextRequest.difference(DateTime.now());
        if (delay > Duration.zero) await Future<void>.delayed(delay);
        if (cancelled?.call() == true) return <String, dynamic>{};
        _nextRequest = DateTime.now().add(requestSpacing);
        final response =
            await _client.get(uri).timeout(const Duration(seconds: 6));
        if (response.statusCode == 429) {
          _cooldown = DateTime.now().add(const Duration(minutes: 5));
          return <String, dynamic>{};
        }
        if (response.statusCode != 200 ||
            response.bodyBytes.length > 3 * 1024 * 1024) {
          throw const FormatException('Supplement unavailable');
        }
        final data = await compute(_decode, response.body);
        _cache[key] = (data, DateTime.now());
        while (_cache.length > 96) {
          _cache.remove(_cache.keys.first);
        }
        return data;
      } catch (_) {
        // Negative caching avoids repeated retries; never replace ESPN errors.
        _cache[key] = (<String, dynamic>{}, DateTime.now());
        return <String, dynamic>{};
      } finally {
        done.complete();
      }
    }()
        .whenComplete(() {
      _inFlight.remove(key);
    });
  }

  static Map<String, dynamic> _decode(String body) {
    final data = jsonDecode(body);
    return data is Map<String, dynamic> ? data : {};
  }

  Future<List<SportsGame>> gamesForDay(List<SportsLeague> leagues, DateTime day,
      {bool Function()? cancelled}) async {
    if (cancelled?.call() == true) return const [];
    final key = _dayKey(leagues, day);
    final parsedAt = _dayParsedAt[key];
    if (parsedAt != null &&
        DateTime.now().difference(parsedAt) < const Duration(minutes: 15)) {
      return _days[key] ?? const [];
    }
    final selected = leagues
        .where((l) => l.source != 'Channel guide' && l.id != 'rugby.live')
        .map((l) => l.espnPath.split('/').first)
        .toSet();
    final rows = <Map<String, dynamic>>[];
    for (final sport in selected) {
      final name = sports[sport];
      if (name == null) continue;
      for (final date in _dates(day)) {
        if (cancelled?.call() == true) return [];
        final data = await _get('eventsday', {'d': _date(date), 's': name},
            cancelled: cancelled);
        rows.addAll(_rows(data['events']));
      }
    }
    if (cancelled?.call() == true) return [];
    final games = await compute(parseSupplementGames, (rows, leagues, day));
    if (cancelled?.call() == true) return const [];
    _days[key] = games;
    _dayParsedAt[key] = DateTime.now();
    while (_days.length > 8) {
      final oldest = _days.keys.first;
      _days.remove(oldest);
      _dayParsedAt.remove(oldest);
    }
    return games;
  }

  SportsGame enrichCached(SportsGame game) {
    final cached = _listings[eventKey(game)];
    final listings = <String, SportsBroadcast>{
      for (final b in game.onlineBroadcasts)
        if (b.source != 'NHL' &&
            b.source != 'TheSportsDB' &&
            b.source != SkyTennisScheduleService.source &&
            b.source != TennisBroadcastService.source)
          b.evidenceKey: b,
      if (cached != null &&
          DateTime.now().difference(cached.$2) < const Duration(hours: 6))
        for (final b in cached.$1) b.evidenceKey: b,
      for (final b in _tennis?.cachedFor(game) ?? const <SportsBroadcast>[])
        b.evidenceKey: b,
      for (final b in _official?.cachedFor(game) ?? const <SportsBroadcast>[])
        b.evidenceKey: b,
    };
    final next = listings.values.toList();
    if (next.length == game.onlineBroadcasts.length &&
        next.indexed.every((e) =>
            e.$2.evidenceKey == game.onlineBroadcasts[e.$1].evidenceKey)) {
      return game;
    }
    return game.withOnlineBroadcasts(next);
  }

  Future<List<SportsBroadcast>> broadcastsFor(SportsGame game,
      {bool Function()? cancelled}) async {
    if (cancelled?.call() == true) return const [];
    final official =
        await _official?.broadcastsFor(game, cancelled: cancelled) ??
            const <SportsBroadcast>[];
    if (cancelled?.call() == true) return const [];
    if (official.isNotEmpty) return official;
    await _tennis?.warm([game], cancelled: cancelled ?? () => false);
    if (cancelled?.call() == true) return const [];
    final eventListings = await _eventBroadcastsFor(game, cancelled: cancelled);
    return [...eventListings, ...?_tennis?.cachedFor(game)];
  }

  Future<List<SportsBroadcast>> _eventBroadcastsFor(SportsGame game,
      {bool Function()? cancelled}) async {
    final key = eventKey(game);
    final old = _listings[key];
    if (old != null &&
        DateTime.now().difference(old.$2) <
            (old.$1.isEmpty
                ? const Duration(minutes: 15)
                : const Duration(hours: 6))) {
      return Future.value(old.$1);
    }
    if (game.league.isField) return Future.value([]);
    return _lookingUp[key] ??= () async {
      String? id;
      if (game.source == 'TheSportsDB') {
        id = game.id.replaceFirst('tsdb:', '');
      } else {
        final data = await _get(
            'searchevents',
            {
              'e': '${game.home.name}_vs_${game.away.name}',
              'd': _date(game.start.toUtc()),
            },
            cancelled: cancelled);
        for (final row in _rows(data['event'] ?? data['events'])) {
          final candidates = parseSupplementGames(
              ([row], [game.league], game.start.toLocal()));
          if (candidates.any((candidate) => sameSportsEvent(game, candidate))) {
            id = row['idEvent']?.toString();
            break;
          }
        }
      }
      final result = <SportsBroadcast>[];
      if (id != null && RegExp(r'^\d+$').hasMatch(id)) {
        if (cancelled?.call() == true) return <SportsBroadcast>[];
        final data = await _get('lookuptv', {'id': id}, cancelled: cancelled);
        final seen = <String>{};
        for (final row in _rows(data['tvevent'] ?? data['tvevents'])) {
          if (row['idEvent']?.toString() != id) continue;
          final name = (row['strChannel'] ?? '').toString().trim();
          final country = (row['strCountry'] ?? '').toString().trim();
          if (name.isNotEmpty && seen.add('$name|$country')) {
            result.add(
                SportsBroadcast(name, source: 'TheSportsDB', country: country));
          }
        }
      }
      if (cancelled?.call() == true) return <SportsBroadcast>[];
      _listings[key] = (result, DateTime.now());
      while (_listings.length > 128) {
        _listings.remove(_listings.keys.first);
      }
      return result;
    }()
        .whenComplete(() {
      _lookingUp.remove(key);
    });
  }
}

List<Map<String, dynamic>> _rows(Object? value) => value is List
    ? value.whereType<Map>().map((m) => Map<String, dynamic>.from(m)).toList()
    : [];

String _name(String value) => sportsNormalize(value)
    .split(' ')
    .where((w) => w.isNotEmpty && !const {'fc', 'cf', 'sc', 'afc'}.contains(w))
    .join(' ');

String _division(SportsLeague league) {
  final text = '${league.id} ${league.name} ${league.region}'.toLowerCase();
  final women = text.contains('women') ||
      text.contains('.w.') ||
      text.contains('wnba') ||
      text.contains('wta') ||
      text.contains('wwc') ||
      text.contains('wchampions');
  final youth = RegExp(r'\bu\s?-?\d{2}\b').firstMatch(text)?.group(0) ?? '';
  return '${women ? 'women' : 'open'}:$youth';
}

bool sameSportsEvent(SportsGame a, SportsGame b) {
  if (a.league.espnPath.startsWith('mma/') &&
      b.league.espnPath.startsWith('mma/')) {
    final card = combatCardIdentity(a.event?.title ?? '');
    if (card != null &&
        card == combatCardIdentity(b.event?.title ?? '') &&
        a.start.difference(b.start).abs() <= const Duration(hours: 8)) {
      return true;
    }
  }
  if (a.league.id != b.league.id &&
      _name(a.league.name) != _name(b.league.name)) {
    return false;
  }
  if (a.league.espnPath.split('/').first !=
          b.league.espnPath.split('/').first ||
      _division(a.league) != _division(b.league) ||
      a.start.difference(b.start).abs() > const Duration(minutes: 30)) {
    return false;
  }
  if (isFormulaOne(a) && isFormulaOne(b)) {
    // There is only one F1 session of a given kind in this time window.
    // Sponsor prefixes and "US GP" vs "United States Grand Prix" vary by feed.
    final kind = f1SessionKind(a.event?.session);
    if (kind.isNotEmpty && kind == f1SessionKind(b.event?.session)) return true;
  }
  if (a.league.isField || b.league.isField) {
    if (!a.league.isField || !b.league.isField) return false;
    final aSession = _name(a.event?.session ?? '');
    final bSession = _name(b.event?.session ?? '');
    if (aSession.isNotEmpty && bSession.isNotEmpty && aSession != bSession) {
      return false;
    }
    final aNames = [a.event?.title ?? a.home.name, ...?a.event?.matchingNames]
        .map(_name)
        .toSet();
    final bNames = [b.event?.title ?? b.home.name, ...?b.event?.matchingNames]
        .map(_name)
        .toSet();
    return aNames.intersection(bNames).any((n) => n.length >= 6);
  }
  bool side(SportsTeam x, SportsTeam y) {
    final names =
        [_name(x.name), _name(x.shortName)].where((s) => s.length >= 3).toSet();
    return names.contains(_name(y.name)) || names.contains(_name(y.shortName));
  }

  return side(a.home, b.home) && side(a.away, b.away) ||
      side(a.home, b.away) && side(a.away, b.home);
}

/// Preserve primary IDs, scores, follow/pick keys and timing. Never merge by
/// just one team or a sport keyword (including women's/youth fixtures).
List<SportsGame> mergeSupplementGames(
    List<SportsGame> primary, List<SportsGame> extra) {
  final result = [...primary];
  final buckets = <String, List<SportsGame>>{};
  String bucket(SportsGame g, int hour) =>
      '${g.league.espnPath.split('/').first}:$hour';
  for (final game in primary) {
    (buckets[bucket(game, game.start.millisecondsSinceEpoch ~/ 3600000)] ??= [])
        .add(game);
  }
  for (final game in extra) {
    final hour = game.start.millisecondsSinceEpoch ~/ 3600000;
    // Card schedules may name the main-card start while ESPN dates prelims.
    final hours = game.league.espnPath.startsWith('mma/') ? 8 : 1;
    final duplicate = [
      for (var h = hour - hours; h <= hour + hours; h++)
        ...?buckets[bucket(game, h)]
    ].any((g) => sameSportsEvent(g, game));
    if (duplicate) continue;
    result.add(game);
    (buckets[bucket(game, hour)] ??= []).add(game);
  }
  return result;
}

// Build once per isolate rather than scanning/normalising the catalogue for
// every event. Preserve the catalogue's first-match precedence for aliases.
final _motorsportLeaguesByName = () {
  final result = <String, SportsLeague>{};
  for (final league in [
    ...kMotorsportCalendarLeagues,
    ...kAdditionalEnduranceLeagues
  ]) {
    for (final name in [league.name, ...league.seriesPhrases]) {
      result.putIfAbsent(_name(name), () => league);
    }
  }
  return result;
}();

List<SportsGame> parseSupplementGames(
    (List<Map<String, dynamic>>, List<SportsLeague>, DateTime) input) {
  final (rows, leagues, day) = input;
  final result = <SportsGame>[];
  final byName = {for (final l in leagues) _name(l.name): l};
  final enabled = leagues.map((l) => l.id).toSet();
  const aliases = {
    'English League Championship': 'eng.2',
    'English Championship': 'eng.2',
    'UFC': 'mma.ufc',
    'Professional Fighters League': 'mma.pfl',
    'English Premier League': 'eng.1',
    'Spanish La Liga': 'esp.1',
    'Italian Serie A': 'ita.1',
    'German Bundesliga': 'ger.1',
    'French Ligue 1': 'fra.1',
    'UEFA Champions League': 'uefa.champions',
    'UEFA Europa League': 'uefa.europa',
    'ATP World Tour': 'tennis.atp',
    'WTA Tour': 'tennis.wta',
    'Australian AFL': 'australian-football.afl',
    'Formula 1': 'racing.f1',
    'NASCAR Cup Series': 'racing.nascar-premier',
    'IndyCar Series': 'racing.irl'
  };
  final seen = <String>{};
  for (final row in rows) {
    try {
      final id = row['idEvent']?.toString(),
          leagueId = row['idLeague']?.toString();
      final home = row['strHomeTeam']?.toString().trim() ?? '';
      final away = row['strAwayTeam']?.toString().trim() ?? '';
      final name = row['strLeague']?.toString().trim() ?? '';
      final sport = SportsSupplementService.sports.entries
          .where((e) =>
              e.value.toLowerCase() ==
              row['strSport']?.toString().toLowerCase())
          .firstOrNull
          ?.key;
      if (!leagues.any((l) => l.espnPath.split('/').first == sport)) continue;
      final field = sport == 'racing';
      final eventTitle = row['strEvent']?.toString().trim() ?? '';
      // Fighting feeds commonly publish a whole card without home/away teams.
      // Keep the actual event title, without inventing headline fighters.
      final cardOnly = sport == 'mma' && (home.isEmpty || away.isEmpty);
      if (id == null ||
          leagueId == null ||
          ((field || cardOnly)
              ? eventTitle.isEmpty
              : home.isEmpty || away.isEmpty) ||
          name.isEmpty ||
          sport == null) {
        continue;
      }
      var stamp = (row['strTimestamp'] ?? '').toString().trim();
      if (stamp.isEmpty) stamp = '${row['dateEvent']}T${row['strTime']}';
      // TheSportsDB timestamps are UTC, even when the trailing Z is omitted.
      if (!RegExp(r'(Z|[+-]\d\d:\d\d)$').hasMatch(stamp)) stamp += 'Z';
      final start = DateTime.parse(stamp).toUtc();
      final local = start.toLocal();
      if (local.year != day.year ||
          local.month != day.month ||
          local.day != day.day) {
        continue;
      }
      final status = (row['strStatus'] ?? '').toString().toUpperCase();
      final live = const {
        'LIVE',
        'IN PLAY',
        'INPLAY',
        '1H',
        '2H',
        'HT',
        'ET',
        'BT',
        'P',
        'Q1',
        'Q2',
        'Q3',
        'Q4',
        'OT'
      }.contains(status);
      final finished = const {'FT', 'AET', 'PEN', 'FINISHED', 'MATCH FINISHED'}
          .contains(status);
      if (const {'CANC', 'CANCELLED', 'PST', 'POSTPONED'}.contains(status) ||
          row['strPostponed'] == 'yes') {
        continue;
      }
      if (!live &&
          !finished &&
          start.isBefore(
              DateTime.now().toUtc().subtract(const Duration(hours: 6)))) {
        continue;
      }
      final normalizedName = _name(name);
      final catalogueLeague =
          sport == 'racing' ? _motorsportLeaguesByName[normalizedName] : null;
      if (catalogueLeague != null && !enabled.contains(catalogueLeague.id)) {
        continue;
      }
      final league = (cardOnly ? null : byName[normalizedName]) ??
          catalogueLeague ??
          (cardOnly
              ? null
              : leagues.where((l) => l.id == aliases[name]).firstOrNull) ??
          SportsLeague(
              id: 'tsdb:$leagueId',
              espnPath: '$sport/tsdb-$leagueId',
              name: name,
              shortName: name,
              logoUrl: '',
              soccer: sport == 'soccer',
              source: 'TheSportsDB',
              region: 'Extra schedules',
              hasStandings: false,
              seriesPhrases: sport == 'mma' ? [name.toLowerCase()] : const [],
              kind: cardOnly
                  ? SportsKind.broadcast
                  : field
                      ? SportsKind.racing
                      : sport == 'tennis'
                          ? SportsKind.tennis
                          : sport == 'mma'
                              ? SportsKind.fight
                              : SportsKind.team);
      SportsTeam team(String side, String title) => SportsTeam(
          id: 'tsdb:${row['id${side}Team'] ?? title}',
          name: title,
          shortName: title,
          abbreviation: '',
          score: row['int${side}Score']?.toString());
      if (!seen.add(id)) continue;
      result.add(SportsGame(
          id: 'tsdb:$id',
          league: league,
          start: start,
          state: live
              ? GameState.live
              : finished
                  ? GameState.post
                  : GameState.pre,
          statusText: live
              ? 'Live · TheSportsDB'
              : finished
                  ? 'Final'
                  : 'Scheduled',
          source: 'TheSportsDB',
          event: field || sport == 'mma'
              ? SportsEventInfo(
                  title: eventTitle, venue: row['strVenue']?.toString())
              : null,
          home: team('Home', field || cardOnly ? eventTitle : home),
          away: team('Away', field || cardOnly ? eventTitle : away)));
    } catch (_) {/* A malformed extra event cannot break the primary feed. */}
  }
  return result;
}
