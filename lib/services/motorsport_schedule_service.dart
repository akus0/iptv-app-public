import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../models/sports.dart';
import '../utils/endurance_racing.dart';

/// Optional calendar, not a live timing feed. One shared, bounded download
/// covers all series; parsing runs off the UI thread. No channel/provider IO.
class MotorsportScheduleService {
  MotorsportScheduleService(this._client, {DateTime Function()? clock})
      : _clock = clock ?? DateTime.now;
  static final instance = MotorsportScheduleService(http.Client());
  static const source = 'RaceTV Guide';
  final http.Client _client;
  final DateTime Function() _clock;
  List<MotorsportSession> _sessions = const [];
  DateTime? _fetchedAt, _retryAfter;
  Future<void>? _inFlight;
  final _days = <String, (int, List<SportsGame>)>{};

  Future<void> warm({required bool Function() cancelled}) async {
    final now = _clock();
    if (cancelled() ||
        (_fetchedAt != null &&
            now.difference(_fetchedAt!) < const Duration(hours: 6)) ||
        (_retryAfter != null && now.isBefore(_retryAfter!))) {
      return;
    }
    await (_inFlight ??=
        _download(cancelled).whenComplete(() => _inFlight = null));
  }

  Future<void> _download(bool Function() cancelled) async {
    try {
      final request = http.Request(
          'GET', Uri.https('www.racetvguide.com', '/calendars/all.ics'));
      final response =
          await _client.send(request).timeout(const Duration(seconds: 8));
      if (response.statusCode != 200 ||
          (response.contentLength ?? 0) > 1024 * 1024) {
        await response.stream.listen(null).cancel();
        throw const FormatException('Calendar unavailable');
      }
      final bytes = <int>[];
      await for (final chunk
          in response.stream.timeout(const Duration(seconds: 8))) {
        if (cancelled() || bytes.length + chunk.length > 1024 * 1024) {
          throw const FormatException('Calendar cancelled or oversized');
        }
        bytes.addAll(chunk);
      }
      if (cancelled()) return;
      final sessions = await compute(parseMotorsportCalendar, bytes);
      if (sessions.isEmpty) throw const FormatException('Empty calendar');
      if (cancelled()) return;
      _sessions = sessions;
      _fetchedAt = _clock();
      _retryAfter = null;
      _days.clear();
    } catch (_) {
      if (cancelled()) return; // Leaving the tab is not a source failure.
      _retryAfter = _clock().add(const Duration(minutes: 15));
      // A failure keeps the last usable calendar without restarting a loop.
    }
  }

  List<SportsGame> gamesForDay(DateTime day) {
    final now = _clock().toUtc();
    if (_fetchedAt == null ||
        now.difference(_fetchedAt!) > const Duration(days: 2)) {
      return const [];
    }
    final key = '${day.year}-${day.month}-${day.day}';
    final minute = now.millisecondsSinceEpoch ~/ 60000;
    final old = _days[key];
    if (old != null && old.$1 == minute) return old.$2;
    final from = DateTime(day.year, day.month, day.day).toUtc();
    final to = DateTime(day.year, day.month, day.day + 1).toUtc();
    final games = <SportsGame>[];
    for (final s in _sessions) {
      if (!s.start.isBefore(to) || !s.end.isAfter(from)) continue;
      final state = now.isBefore(s.start)
          ? GameState.pre
          : now.isBefore(s.end)
              ? GameState.live
              : GameState.post;
      final side = SportsTeam(
          id: s.id, name: s.title, shortName: s.title, abbreviation: '');
      games.add(SportsGame(
          id: 'calendar:${s.id}',
          league: s.league,
          start: s.start,
          end: s.end,
          state: state,
          statusText: state == GameState.live
              ? 'Scheduled now'
              : state == GameState.post
                  ? 'Schedule ended'
                  : 'Scheduled',
          home: side,
          away: side,
          source: source,
          event: SportsEventInfo(
              title: s.title,
              session: s.session,
              venue: s.venue,
              matchingNames: s.aliases)));
    }
    // Reuse object identity between polls when no session changed state.
    final result = old != null &&
            old.$2.length == games.length &&
            games.indexed.every((e) =>
                e.$2.id == old.$2[e.$1].id && e.$2.state == old.$2[e.$1].state)
        ? old.$2
        : games;
    _days[key] = (minute, result);
    while (_days.length > 8) {
      _days.remove(_days.keys.first);
    }
    return result;
  }
}

class MotorsportSession {
  const MotorsportSession(this.id, this.league, this.start, this.end,
      this.title, this.session, this.venue, this.aliases);
  final String id, title, session, venue;
  final SportsLeague league;
  final DateTime start, end;
  final List<String> aliases;
}

/// Strict UTC subset used by the public feed. Ambiguous floating/all-day times,
/// cancelled entries and non-driving activities cannot become on-now cards.
List<MotorsportSession> parseMotorsportCalendar(List<int> bytes) {
  if (bytes.length > 1024 * 1024) return const [];
  final text = utf8.decode(bytes).replaceAll(RegExp(r'\r?\n[ \t]'), '');
  if (!text.startsWith('BEGIN:VCALENDAR')) return const [];
  String unescape(String s) => s.replaceAllMapped(RegExp(r'\\([nN,;\\])'),
      (m) => m[1]!.toLowerCase() == 'n' ? '\n' : m[1]!);
  DateTime? stamp(String? s) {
    if (s == null || !RegExp(r'^\d{8}T\d{6}Z$').hasMatch(s)) return null;
    final parsed = DateTime.tryParse(s);
    if (parsed == null) return null;
    String two(int n) => '$n'.padLeft(2, '0');
    final roundTrip =
        '${parsed.year}${two(parsed.month)}${two(parsed.day)}T${two(parsed.hour)}${two(parsed.minute)}${two(parsed.second)}Z';
    return roundTrip == s ? parsed : null;
  }

  final result = <String, MotorsportSession>{};
  for (final block in text.split('BEGIN:VEVENT').skip(1).take(3000)) {
    if (!block.contains('END:VEVENT')) continue;
    final fields = <String, String>{};
    for (final line
        in const LineSplitter().convert(block.split('END:VEVENT').first)) {
      final colon = line.indexOf(':');
      if (colon > 0) {
        fields[line.substring(0, colon)] = line.substring(colon + 1);
      }
    }
    if (fields['STATUS'] == 'CANCELLED') continue;
    final start = stamp(fields['DTSTART']), end = stamp(fields['DTEND']);
    final id = fields['UID'];
    // Some series use a direct series URL; others supply only the calendar
    // URL in DESCRIPTION. All three formats occur in the same shared feed.
    final link = fields['URL'] ??
        RegExp(r'https://www\.racetvguide\.com/calendars/[a-z0-9-]+/')
            .firstMatch(unescape(fields['DESCRIPTION'] ?? ''))
            ?.group(0);
    final url = Uri.tryParse(link ?? '');
    final path = url?.pathSegments.where((p) => p.isNotEmpty).toList() ??
        const <String>[];
    final slug = path.length == 1
        ? path.first
        : path.length == 2 &&
                const {'how-to-watch', 'calendars'}.contains(path.first)
            ? path.last
            : null;
    if (id == null ||
        id.length > 400 ||
        start == null ||
        end == null ||
        !end.isAfter(start) ||
        end.difference(start) > const Duration(hours: 26) ||
        url?.host != 'www.racetvguide.com' ||
        slug == null) {
      continue;
    }
    final league = motorsportCalendarLeagues[slug];
    if (league == null) {
      continue; // ESPN keeps ownership of its existing series.
    }
    final summary = unescape(fields['SUMMARY'] ?? '').trim();
    final split = summary.indexOf(' - ');
    final session = split < 0 ? summary : summary.substring(split + 3);
    if (session.isEmpty ||
        session.length > 200 ||
        RegExp(r'parade|press conference|autograph|pit.?walk|grid.?walk|ceremony|drivers.? briefing',
                caseSensitive: false)
            .hasMatch(session)) {
      continue;
    }
    final venue = unescape(fields['LOCATION'] ?? '').trim();
    if (venue.isEmpty ||
        venue.length > 300 ||
        venue.toLowerCase().contains('tbd')) {
      continue;
    }
    final circuit = venue.split(' · ').first.trim();
    final aliases = <String>[
      circuit,
      ...enduranceVenueAliases(league.id, circuit)
    ];
    if (league.id == 'racing.supercars') {
      const circuits = {
        'surfers paradise': 'Gold Coast 500',
        'mount panorama': 'Bathurst',
        'sandown': 'Sandown',
        'adelaide': 'Adelaide',
        'townsville': 'Townsville',
        'hidden valley': 'Darwin',
        'taup': 'Taupo',
        'sydney': 'Sydney',
        'queensland raceway': 'Ipswich',
        'wanneroo': 'Perth',
        'the bend': 'The Bend',
      };
      for (final entry in circuits.entries) {
        if (circuit.toLowerCase().contains(entry.key)) {
          aliases.insert(0, entry.value);
          if (entry.value == 'Gold Coast 500') aliases.add('Gold Coast');
        }
      }
    }
    if (const {'racing.motogp', 'racing.moto2', 'racing.moto3'}
        .contains(league.id)) {
      const grandPrixNames = {
        'phillip island': 'Australian Grand Prix',
        'sepang': 'Malaysian Grand Prix',
        'lusail': 'Qatar Grand Prix',
        'algarve': 'Portuguese Grand Prix',
        'ricardo tormo': 'Valencian Grand Prix',
      };
      for (final entry in grandPrixNames.entries) {
        if (circuit.toLowerCase().contains(entry.key)) {
          aliases.insert(0, entry.value);
        }
      }
    }
    result[id] = MotorsportSession(id, league, start, end,
        '${league.shortName} · ${aliases.first}', session, venue, aliases);
  }
  return result.values.toList()..sort((a, b) => a.start.compareTo(b.start));
}
