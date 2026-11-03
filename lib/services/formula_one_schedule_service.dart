import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../models/sports.dart';
import '../utils/formula_one.dart';

/// One small season calendar per six hours, independent of live-score polling.
/// Persisted schedules restore off the UI path; failures retain usable data.
class FormulaOneScheduleService {
  FormulaOneScheduleService(this.client,
      {DateTime Function()? clock, this.persist = false})
      : clock = clock ?? DateTime.now;
  static final instance =
      FormulaOneScheduleService(http.Client(), persist: true);
  final http.Client client;
  final DateTime Function() clock;
  final bool persist;
  final _seasons = <int, (DateTime, List<SportsGame>)>{};
  final _restored = <int>{};
  final _retry = <int, DateTime>{};
  final _flights = <int, Future<void>>{};
  final _days = <String, (int, List<SportsGame>)>{};

  Future<void> warm({required bool Function() cancelled}) async {
    final now = clock();
    for (final year in {
      now.year,
      if (now.month == 12 && now.day >= 25) now.year + 1,
      if (now.month == 1 && now.day <= 7) now.year - 1
    }) {
      if (cancelled()) return;
      await (_flights[year] ??= _warmYear(year, cancelled).whenComplete(() {
        _flights.remove(year);
      }));
    }
  }

  Future<void> _warmYear(int year, bool Function() cancelled) async {
    final key = 'iptv_f1_schedule_v1_$year';
    if (persist && _restored.add(year)) {
      try {
        final prefs = await SharedPreferences.getInstance();
        final raw = prefs.getString(key);
        if (raw != null && raw.length <= 256 * 1024) {
          final saved = jsonDecode(raw) as Map;
          final at = DateTime.parse(saved['at'] as String);
          final games =
              await compute(parseFormulaOneSchedule, saved['body'] as String);
          if (games.isNotEmpty &&
              games.every((g) =>
                  g.start.year >= year - 1 && g.start.year <= year + 1) &&
              !at.isAfter(clock())) {
            _seasons[year] = (at, games);
            _days.clear();
          }
        }
      } catch (_) {/* An unreadable optional cache never blocks scores. */}
    }
    final now = clock(), old = _seasons[year];
    if (cancelled() ||
        (old != null && now.difference(old.$1) < const Duration(hours: 6)) ||
        (_retry[year]?.isAfter(now) ?? false)) {
      return;
    }
    try {
      final request = http.Request(
          'GET',
          Uri.https(
              'api.jolpi.ca', '/ergast/f1/$year/races/', {'limit': '100'}));
      request.headers['User-Agent'] = 'iptv-app/0.1.0-preview.59';
      final response =
          await client.send(request).timeout(const Duration(seconds: 8));
      if (response.statusCode != 200 ||
          (response.contentLength ?? 0) > 256 * 1024) {
        await response.stream.listen(null).cancel();
        throw const FormatException('Calendar unavailable');
      }
      final body = await (() async {
        final bytes = <int>[];
        await for (final chunk in response.stream) {
          if (cancelled() || bytes.length + chunk.length > 256 * 1024) {
            throw const FormatException('Calendar too large');
          }
          bytes.addAll(chunk);
        }
        return utf8.decode(bytes);
      })()
          .timeout(const Duration(seconds: 8));
      final games = await compute(parseFormulaOneSchedule, body);
      if (games.isEmpty) throw const FormatException('No timed sessions');
      if (cancelled()) return;
      _seasons[year] = (clock(), games);
      _retry.remove(year);
      _days.clear();
      if (persist) {
        try {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString(
              key, jsonEncode({'at': clock().toIso8601String(), 'body': body}));
          await prefs.remove('iptv_f1_schedule_v1_${year - 2}');
        } catch (_) {/* Memory cache still works. */}
      }
    } catch (_) {
      if (!cancelled()) _retry[year] = clock().add(const Duration(minutes: 15));
    }
  }

  List<SportsGame> gamesForDay(DateTime day) {
    final now = clock();
    final key = '${day.year}-${day.month}-${day.day}';
    final minute = now.millisecondsSinceEpoch ~/ 60000;
    final old = _days[key];
    if (old?.$1 == minute) return old!.$2;
    final from = DateTime(day.year, day.month, day.day).toUtc();
    final to = DateTime(day.year, day.month, day.day + 1).toUtc();
    final result = <SportsGame>[];
    for (final season in _seasons.values) {
      if (now.difference(season.$1) > const Duration(days: 7)) continue;
      for (final g in season.$2) {
        if (!g.start.subtract(f1BuildUpLead(g)).isBefore(to) ||
            !g.end!.isAfter(from)) {
          continue;
        }
        final state = now.isBefore(g.start)
            ? GameState.pre
            : now.isBefore(g.end!)
                ? GameState.live
                : GameState.post;
        result.add(SportsGame(
            id: g.id,
            league: g.league,
            start: g.start,
            end: g.end,
            state: state,
            statusText: state == GameState.live
                ? 'Scheduled now'
                : state == GameState.post
                    ? 'Schedule ended'
                    : 'Scheduled',
            home: g.home,
            away: g.away,
            source: g.source,
            event: g.event));
      }
    }
    final games = old != null &&
            old.$2.length == result.length &&
            result.indexed.every((e) =>
                e.$2.id == old.$2[e.$1].id && e.$2.state == old.$2[e.$1].state)
        ? old.$2
        : result;
    _days[key] = (minute, games);
    while (_days.length > 8) {
      _days.remove(_days.keys.first);
    }
    return games;
  }
}

List<SportsGame> parseFormulaOneSchedule(String body) {
  final data = jsonDecode(body) as Map;
  final rows = (data['MRData'] as Map?)?['RaceTable'] as Map?;
  final league = sportsLeagueById('racing.f1')!;
  final games = <SportsGame>[];
  for (final raw in (rows?['Races'] as List? ?? const []).take(40)) {
    if (raw is! Map) continue;
    final title = (raw['raceName'] ?? '').toString().trim();
    if (title.isEmpty) continue;
    final circuit = raw['Circuit'] as Map?;
    final location = circuit?['Location'] as Map?;
    for (final entry in const {
      'FirstPractice': 'Practice 1',
      'SecondPractice': 'Practice 2',
      'ThirdPractice': 'Practice 3',
      'SprintQualifying': 'Sprint Qualifying',
      'Sprint': 'Sprint',
      'Qualifying': 'Qualifying',
      'Race': 'Race'
    }.entries) {
      final value = entry.key == 'Race' ? raw : raw[entry.key];
      if (value is! Map ||
          value['date'] is! String ||
          value['time'] is! String) {
        continue;
      }
      final start = DateTime.tryParse('${value['date']}T${value['time']}');
      if (start == null || !start.isUtc) {
        continue; // Never invent midnight starts or a local timezone.
      }
      final side =
          SportsTeam(id: '', name: title, shortName: title, abbreviation: 'F1');
      games.add(SportsGame(
          id: 'jolpica:${raw['season']}:${raw['round']}:${entry.key}',
          league: league,
          start: start,
          end: start.add(f1SessionDuration(entry.value)),
          state: GameState.pre,
          statusText: 'Scheduled',
          home: side,
          away: side,
          source: 'Jolpica',
          event: SportsEventInfo(
              title: title,
              session: entry.value,
              venue: circuit?['circuitName']?.toString(),
              matchingNames: [
                title,
                if (circuit?['circuitName'] is String)
                  circuit!['circuitName'] as String,
                if (location?['locality'] is String)
                  location!['locality'] as String,
                if (location?['country'] is String)
                  '${location!['country']} Grand Prix'
              ])));
    }
  }
  return games;
}
