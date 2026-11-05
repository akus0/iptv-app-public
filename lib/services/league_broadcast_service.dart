import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../models/sports.dart';
import 'sports_channel_matcher.dart' show sportsNormalize;

/// Optional public league schedules. Only dates leave the app, never playlist
/// names, guide text, subscription URLs or credentials. No scores are replaced.
class LeagueBroadcastService {
  LeagueBroadcastService(this.client,
      {DateTime Function()? clock,
      this.spacing = const Duration(seconds: 1),
      this.cacheFile})
      : clock = clock ?? DateTime.now;
  static final instance =
      LeagueBroadcastService(http.Client(), cacheFile: () async {
    final dir = await getApplicationCacheDirectory();
    return File('${dir.path}/league-broadcasts-v1.json');
  });
  final http.Client client;
  final DateTime Function() clock;
  final Duration spacing;
  final Future<File> Function()? cacheFile;
  Future<void>? _loaded;

  Future<void> _load() async {
    if (cacheFile == null) return;
    try {
      final file = await cacheFile!();
      if (!await file.exists() || await file.length() > 256 * 1024) return;
      final data = jsonDecode(await file.readAsString());
      if (data is! Map || data['version'] != 1 || data['entries'] is! List) {
        return;
      }
      for (final entry in (data['entries'] as List).take(12).whereType<Map>()) {
        final at = DateTime.tryParse('${entry['at']}');
        final key = entry['key'];
        if (at == null ||
            key is! String ||
            clock().isBefore(at) ||
            clock().difference(at) >= const Duration(minutes: 30)) {
          continue;
        }
        final rows = <LeagueBroadcastFixture>[];
        for (final f in (entry['rows'] as List).whereType<Map>()) {
          final listings = <SportsBroadcast>[];
          for (final b in (f['broadcasts'] as List).whereType<Map>()) {
            listings.add(SportsBroadcast(b['name'] as String,
                source: b['source'] as String,
                country: b['country'] as String,
                requiresGuide: b['requiresGuide'] == true,
                medium: 'TV',
                language: b['language'] as String? ?? ''));
          }
          rows.add(LeagueBroadcastFixture(
              f['id'] as String,
              f['league'] as String,
              DateTime.parse(f['start'] as String),
              f['home'] as String,
              f['away'] as String,
              listings));
        }
        _cache.putIfAbsent(key, () => (at, rows));
      }
    } catch (_) {/* Optional derived cache. */}
  }

  Future<void> _save() async {
    if (cacheFile == null) return;
    try {
      final entries = [
        for (final e in _cache.entries)
          if (_fresh(e.value))
            {
              'key': e.key,
              'at': e.value.$1.toIso8601String(),
              'rows': [
                for (final f in e.value.$2)
                  {
                    'id': f.id,
                    'league': f.league,
                    'start': f.start.toIso8601String(),
                    'home': f.home,
                    'away': f.away,
                    'broadcasts': [
                      for (final b in f.broadcasts)
                        {
                          'name': b.name,
                          'source': b.source,
                          'country': b.country,
                          'requiresGuide': b.requiresGuide,
                          'language': b.language
                        }
                    ]
                  }
              ]
            }
      ];
      final text = jsonEncode({'version': 1, 'entries': entries});
      if (utf8.encode(text).length > 256 * 1024) return;
      final file = await cacheFile!();
      final temporary = File('${file.path}.tmp');
      await temporary.writeAsString(text);
      await temporary.rename(file.path);
    } catch (_) {/* Network/local matching never depends on disk writes. */}
  }

  final _cache = <String, (DateTime, List<LeagueBroadcastFixture>)>{};
  final _inFlight = <String, Future<void>>{};
  Future<void> _queue = Future.value();
  DateTime? _budgetAt, _lastRequest;
  final _cooldowns = <String, DateTime>{};
  int _requests = 0;

  bool supports(SportsGame game) =>
      const {'nhl', 'mlb'}.contains(game.league.id);
  DateTime _day(SportsGame game) {
    final localEvening = game.start.toUtc().subtract(const Duration(hours: 12));
    return DateTime.utc(
        localEvening.year, localEvening.month, localEvening.day);
  }

  String _key(SportsGame game) => '${game.league.id}:${_date(_day(game))}';
  static String _date(DateTime day) => day.toIso8601String().substring(0, 10);
  bool _fresh((DateTime, List<LeagueBroadcastFixture>)? entry) =>
      entry != null &&
      !clock().isBefore(entry.$1) &&
      clock().difference(entry.$1) < const Duration(minutes: 30);

  List<SportsBroadcast> cachedFor(SportsGame game) {
    if (!supports(game)) return const [];
    final entry = _cache[_key(game)];
    if (!_fresh(entry)) return const [];
    // Both opponents, league and kickoff must agree. Ambiguous doubleheaders,
    // postponed fixtures and short city/mascot guesses supply no evidence.
    final hits = entry!.$2.where((f) => f.matches(game)).toList();
    return hits.length == 1 ? hits.single.broadcasts : const [];
  }

  Future<List<SportsBroadcast>> broadcastsFor(SportsGame game,
      {bool Function()? cancelled}) async {
    if (!supports(game) || cancelled?.call() == true) return const [];
    await (_loaded ??= _load());
    if (cancelled?.call() == true) return const [];
    final key = _key(game);
    if (!_fresh(_cache[key])) {
      final job = _inFlight[key] ??= _queue.then((_) async {
        if (cancelled?.call() == true || _fresh(_cache[key])) return;
        final now = clock();
        if (now.isBefore(_cooldowns[game.league.id] ?? DateTime(2000))) return;
        if (_budgetAt == null ||
            now.difference(_budgetAt!) >= const Duration(minutes: 10)) {
          _budgetAt = now;
          _requests = 0;
        }
        if (_requests >= 4) return;
        if (_lastRequest != null) {
          final delay = spacing - now.difference(_lastRequest!);
          if (delay > Duration.zero) await Future<void>.delayed(delay);
        }
        if (cancelled?.call() == true) return;
        _lastRequest = clock();
        _requests++;
        final day = _day(game);
        final uri = game.league.id == 'mlb'
            ? Uri.https('statsapi.mlb.com', '/api/v1/schedule',
                {'sportId': '1', 'date': _date(day), 'hydrate': 'broadcasts'})
            : Uri.https('api-web.nhle.com', '/v1/schedule/${_date(day)}');
        List<LeagueBroadcastFixture> rows = const [];
        try {
          final response =
              await client.get(uri).timeout(const Duration(seconds: 4));
          if (response.statusCode == 429) {
            _cooldowns[game.league.id] =
                clock().add(const Duration(minutes: 10));
          } else if (response.statusCode == 200 &&
              response.bodyBytes.length <= 2 * 1024 * 1024) {
            rows = await compute(
                parseLeagueBroadcasts, (game.league.id, response.body));
          }
        } catch (_) {
          // Failure stays local to optional broadcast hints. Negative caching
          // prevents repeated retries while the ordinary scoreboard works.
        }
        _cache[key] = (clock(), rows);
        while (_cache.length > 12) {
          _cache.remove(_cache.keys.first);
        }
        await _save();
      }).whenComplete(() {
        _inFlight.remove(key);
      });
      _queue = job.catchError((Object _) {});
      await job;
    }
    return cancelled?.call() == true ? const [] : cachedFor(game);
  }

  Future<void> warm(Iterable<SportsGame> games,
      {required bool Function() cancelled}) async {
    final seen = <String>{};
    for (final game in games) {
      if (cancelled()) return;
      if (!supports(game) || !seen.add(_key(game))) continue;
      await broadcastsFor(game, cancelled: cancelled);
      if (seen.length >= 4) return;
    }
  }
}

class LeagueBroadcastFixture {
  const LeagueBroadcastFixture(
      this.id, this.league, this.start, this.home, this.away, this.broadcasts);
  final String id, league, home, away;
  final DateTime start;
  final List<SportsBroadcast> broadcasts;
  bool matches(SportsGame game) =>
      game.league.id == league &&
      game.start.difference(start).abs() <= const Duration(minutes: 15) &&
      _sameTeam(home, game.home.name) &&
      _sameTeam(away, game.away.name);
  static bool _sameTeam(String a, String b) {
    final x = sportsNormalize(a).trim(), y = sportsNormalize(b).trim();
    return x.length >= 5 && x == y;
  }
}

List<LeagueBroadcastFixture> parseLeagueBroadcasts((String, String) input) {
  final data = jsonDecode(input.$2);
  if (data is! Map) return const [];
  if (input.$1 == 'mlb') return _parseMlbBroadcasts(data);
  if (input.$1 != 'nhl') return const [];
  final result = <String, LeagueBroadcastFixture>{};
  String localized(Object? v) =>
      v is Map ? (v['default'] ?? '').toString() : '';
  String nhlName(Map team) =>
      '${localized(team['placeName'])} ${localized(team['commonName'])}'.trim();
  final days = data['gameWeek'];
  if (days is! List) return const [];
  for (final day in days.whereType<Map>()) {
    final games = day['games'];
    if (games is! List) continue;
    for (final game in games.whereType<Map>()) {
      if (game['gameScheduleState'] != 'OK' ||
          !const {'FUT', 'PRE', 'LIVE', 'CRIT'}.contains(game['gameState'])) {
        continue;
      }
      final start = DateTime.tryParse('${game['startTimeUTC'] ?? ''}');
      final home = game['homeTeam'], away = game['awayTeam'];
      final id = '${game['id'] ?? ''}';
      if (start == null || id.isEmpty || home is! Map || away is! Map) continue;
      final networks = game['tvBroadcasts'];
      final listings = <String, SportsBroadcast>{};
      if (networks is List) {
        for (final network in networks.whereType<Map>()) {
          final name = '${network['network'] ?? ''}'.trim();
          final code = '${network['countryCode'] ?? ''}';
          final country = switch (code.toUpperCase()) {
            'US' || 'USA' => 'United States',
            'CA' || 'CAN' => 'Canada',
            'GB' || 'UK' => 'United Kingdom',
            'AU' => 'Australia',
            _ => '',
          };
          if (name.isEmpty || country.isEmpty) continue;
          listings['$name|$country'] =
              SportsBroadcast(name, source: 'NHL', country: country);
        }
      }
      if (listings.isEmpty) continue;
      final homeName = nhlName(home);
      final awayName = nhlName(away);
      result[id] = LeagueBroadcastFixture(id, input.$1, start, homeName,
          awayName, List.unmodifiable(listings.values));
    }
  }
  return List.unmodifiable(result.values);
}

List<LeagueBroadcastFixture> _parseMlbBroadcasts(Map data) {
  final dates = data['dates'];
  if (dates is! List) return const [];
  final result = <String, LeagueBroadcastFixture>{};
  const streaming = {
    'roku',
    'apple tv+',
    'apple tv',
    'prime video',
    'mlb.tv',
    'espn+',
    'peacock'
  };
  for (final day in dates.whereType<Map>()) {
    final games = day['games'];
    if (games is! List) continue;
    for (final game in games.whereType<Map>()) {
      final status = game['status'];
      if (status is! Map ||
          status['startTimeTBD'] == true ||
          !const {'Preview', 'Live'}.contains(status['abstractGameState']) ||
          const {'Postponed', 'Cancelled', 'Suspended'}
              .contains(status['detailedState'])) {
        continue;
      }
      final start = DateTime.tryParse('${game['gameDate'] ?? ''}');
      final teams = game['teams'];
      final networks = game['broadcasts'];
      final id = '${game['gamePk'] ?? ''}';
      if (start == null || teams is! Map || networks is! List || id.isEmpty) {
        continue;
      }
      String team(String side) {
        final entry = teams[side];
        return entry is Map && entry['team'] is Map
            ? '${entry['team']['name'] ?? ''}'
            : '';
      }

      final home = team('home'), away = team('away');
      if (home.isEmpty || away.isEmpty) continue;
      final listings = <String, SportsBroadcast>{};
      for (final network in networks.whereType<Map>()) {
        final name = '${network['name'] ?? ''}'.trim();
        if (network['type'] != 'TV' ||
            network['postGameShow'] == true ||
            name.isEmpty ||
            streaming.contains(name.toLowerCase())) {
          continue;
        }
        // The schedule does not reliably supply a country. Keep unknown-market
        // listings as hints requiring guide evidence, never infer US rights.
        final country =
            SportsBroadcast.countryName('${network['countryCode'] ?? ''}');
        final listing = SportsBroadcast(name,
            source: 'MLB',
            country: country,
            medium: 'TV',
            language: '${network['language'] ?? ''}',
            requiresGuide: country.isEmpty);
        listings[listing.evidenceKey] = listing;
      }
      if (listings.isNotEmpty) {
        result[id] = LeagueBroadcastFixture(
            id, 'mlb', start, home, away, List.unmodifiable(listings.values));
      }
    }
  }
  return List.unmodifiable(result.values);
}
