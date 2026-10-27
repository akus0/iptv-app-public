import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../models/sports.dart';
import 'sports_channel_matcher.dart' show sportsNormalize;

/// Optional public league schedules. Only dates leave the app, never playlist
/// names, guide text, subscription URLs or credentials. No scores are replaced.
class LeagueBroadcastService {
  LeagueBroadcastService(this.client,
      {DateTime Function()? clock, this.spacing = const Duration(seconds: 1)})
      : clock = clock ?? DateTime.now;
  static final instance = LeagueBroadcastService(http.Client());
  final http.Client client;
  final DateTime Function() clock;
  final Duration spacing;
  final _cache = <String, (DateTime, List<LeagueBroadcastFixture>)>{};
  final _inFlight = <String, Future<void>>{};
  Future<void> _queue = Future.value();
  DateTime? _budgetAt, _lastRequest;
  final _cooldowns = <String, DateTime>{};
  int _requests = 0;

  bool supports(SportsGame game) => game.league.id == 'nhl';
  DateTime _day(SportsGame game) {
    final localEvening = game.start.toUtc().subtract(const Duration(hours: 12));
    return DateTime.utc(
        localEvening.year, localEvening.month, localEvening.day);
  }

  String _key(SportsGame game) => '${game.league.id}:${_date(_day(game))}';
  static String _date(DateTime day) => day.toIso8601String().substring(0, 10);
  bool _fresh((DateTime, List<LeagueBroadcastFixture>)? entry) =>
      entry != null &&
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
        final uri = Uri.https('api-web.nhle.com', '/v1/schedule/${_date(day)}');
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
