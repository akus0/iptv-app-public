import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../models/channel.dart';
import '../models/epg_program.dart';
import '../models/sports.dart';
import 'sports_channel_matcher.dart';

/// Optional public metadata only: no subscription identifiers or stream URLs
/// leave the device. Failure cannot invalidate local guide matches.
class SkyTennisScheduleService {
  SkyTennisScheduleService(this.client, {DateTime Function()? clock})
      : clock = clock ?? DateTime.now;
  static const source = 'Sky programme schedule';
  static const _cacheKey = 'sports_sky_linear_v1';
  static const ttl = Duration(minutes: 10);
  static const channels = {
    '1705': 'Sky Sports Tennis',
    '1701': 'Sky Sports Main Event'
  };
  final http.Client client;
  final DateTime Function() clock;
  Set<String> _services = {};
  List<EpgProgram> _rows = const [];
  DateTime? _checked, _retryAt;
  String? _key;
  Future<void>? _loading;
  bool _restored = false;

  void configureChannels(Iterable<Channel> installed) {
    final ids = <String>{};
    for (final c in installed) {
      final id = SportsChannelMatcher.skyTennisServiceFor(c);
      if (id != null) ids.add(id);
    }
    if (setEquals(ids, _services)) return;
    _services = ids;
    _key = null;
    _checked = null;
    _retryAt = null;
    _rows = const [];
  }

  bool _eligible(SportsGame g) =>
      g.league.kind == SportsKind.tennis &&
      g.state == GameState.live &&
      !g.start.isAfter(clock().add(const Duration(minutes: 30))) &&
      g.start.isAfter(clock().subtract(const Duration(hours: 12)));

  List<SportsBroadcast> cachedFor(SportsGame game) {
    final now = clock();
    if (!_eligible(game) ||
        _checked == null ||
        now.isBefore(_checked!) ||
        now.difference(_checked!) >= ttl) {
      return const [];
    }
    final result = <SportsBroadcast>[];
    for (final p in _rows) {
      if (!_services.contains(p.channelId) || !p.isNowPlaying(now)) continue;
      final exact = SportsChannelMatcher.tennisProgrammeIsExact(game, p,
          requireTournament: true);
      // Mixed blocks can suggest coverage, but never identify a numbered feed
      // or become exact just because both names occur somewhere in the text.
      if (!exact &&
          !SportsChannelMatcher.tennisListingFits(
              game, '${p.title} ${p.description ?? ''}', '')) {
        continue;
      }
      result.add(SportsBroadcast(channels[p.channelId]!,
          source: source,
          country: 'United Kingdom',
          tournamentOnly: !exact,
          programme: p,
          expiresAt: _checked!.add(ttl)));
    }
    return result;
  }

  Future<void> warm(List<SportsGame> games,
      {required bool Function() cancelled}) async {
    if (cancelled() || _services.isEmpty || !games.any(_eligible)) return;
    if (_loading != null) return _loading;
    _loading = _warm(cancelled).whenComplete(() => _loading = null);
    await _loading;
  }

  Future<void> _warm(bool Function() cancelled) async {
    final now = clock().toUtc();
    // Sky's broadcast day crosses UTC midnight. Ask for yesterday as well
    // only before 06:00 UTC; the combined result stays bounded to two batches.
    final dates = [
      if (now.hour < 6) now.subtract(const Duration(days: 1)),
      now
    ];
    String day(DateTime d) => '${d.year}${d.month.toString().padLeft(2, '0')}'
        '${d.day.toString().padLeft(2, '0')}';
    final ids = _services.toList()..sort();
    final key = '${dates.map(day).join(',')}|${ids.join(',')}';
    if (!_restored) {
      _restored = true;
      try {
        final prefs = await SharedPreferences.getInstance();
        final raw = prefs.getString(_cacheKey);
        if (raw != null && raw.length <= 128 * 1024) {
          final saved = jsonDecode(raw) as Map<String, dynamic>;
          final at = DateTime.fromMillisecondsSinceEpoch(
              saved['checked'] as int,
              isUtc: true);
          if (saved['key'] == key &&
              !at.isAfter(now) &&
              now.difference(at) < ttl) {
            _rows = _decodeStored(saved['rows'] as List);
            _checked = at;
            _key = key;
            _retryAt = at.add(ttl);
          }
        }
      } catch (_) {/* Disposable optional cache. */}
    }
    if (cancelled()) return;
    if (_key == key && _retryAt != null && now.isBefore(_retryAt!)) return;
    _key = key;
    _retryAt = now.add(ttl);
    final servicesAtStart = ids.join(',');
    try {
      final rows = <EpgProgram>[];
      for (final date in dates) {
        if (cancelled()) return;
        final abort = Completer<void>();
        final timer = Timer(const Duration(seconds: 4), () => abort.complete());
        try {
          final request = http.AbortableRequest(
              'GET',
              Uri.https('awk.epgsky.com',
                  '/hawk/linear/schedule/${day(date)}/$servicesAtStart'),
              abortTrigger: abort.future)
            ..headers['X-SkyOTT-Territory'] = 'GB';
          final response =
              await client.send(request).timeout(const Duration(seconds: 4));
          if (response.statusCode != 200 ||
              (int.tryParse(response.headers['age'] ?? '0') ?? 0) > 600 ||
              (response.contentLength ?? 0) > 256 * 1024) {
            await response.stream.listen((_) {}).cancel();
            throw const FormatException('Schedule unavailable');
          }
          final bytes =
              await response.stream.fold<List<int>>([], (buffer, chunk) {
            if (buffer.length + chunk.length > 256 * 1024) {
              throw const FormatException('Schedule too large');
            }
            buffer.addAll(chunk);
            return buffer;
          }).timeout(const Duration(seconds: 4));
          if (cancelled()) return;
          rows.addAll(
              await compute(parseSkyTennisSchedule, utf8.decode(bytes)));
        } finally {
          timer.cancel();
          if (!abort.isCompleted) abort.complete();
        }
      }
      if (cancelled() ||
          servicesAtStart != (_services.toList()..sort()).join(',')) {
        return;
      }
      _rows = <String, EpgProgram>{
        for (final p in rows)
          if (_services.contains(p.channelId) && p.stop.isAfter(now))
            '${p.channelId}|${p.start.millisecondsSinceEpoch}': p,
      }.values.take(256).toList();
      _checked = clock();
      _retryAt = _checked!.add(ttl);
      try {
        final prefs = await SharedPreferences.getInstance();
        final encoded = jsonEncode({
          'key': key,
          'checked': _checked!.millisecondsSinceEpoch,
          'rows': [
            for (final p in _rows)
              [
                p.channelId,
                p.title,
                p.description,
                p.start.millisecondsSinceEpoch,
                p.stop.millisecondsSinceEpoch
              ]
          ]
        });
        if (encoded.length <= 128 * 1024) {
          await prefs.setString(_cacheKey, encoded);
        }
      } catch (_) {/* Matching does not depend on disk cache writes. */}
    } catch (_) {
      // A failed refresh never extends the lifetime of previous evidence.
      _retryAt = clock().add(const Duration(minutes: 15));
    }
  }
}

List<EpgProgram> _decodeStored(List<dynamic> rows) => [
      for (final row in rows.take(256))
        EpgProgram(
            channelId: row[0] as String,
            title: row[1] as String,
            description: row[2] as String?,
            start:
                DateTime.fromMillisecondsSinceEpoch(row[3] as int, isUtc: true),
            stop:
                DateTime.fromMillisecondsSinceEpoch(row[4] as int, isUtc: true),
            isLive: true),
    ];

/// Only explicit live tennis programmes on verified linear services. Parsing
/// is bounded and runs off the UI isolate; unknown payloads fail closed.
List<EpgProgram> parseSkyTennisSchedule(String body) {
  final data = jsonDecode(body) as Map<String, dynamic>;
  final schedules = data['schedule'];
  if (schedules is! List) throw const FormatException('Missing schedule');
  final rows = <EpgProgram>[];
  for (final schedule in schedules.take(20)) {
    if (schedule is! Map ||
        !SkyTennisScheduleService.channels.containsKey(schedule['sid'])) {
      continue;
    }
    final events = schedule['events'];
    if (events is! List) continue;
    for (final event in events.take(256)) {
      if (event is! Map || event['st'] is! num || event['d'] is! num) continue;
      final title = event['t'];
      final description = event['sy'];
      if (title is! String ||
          title.length > 300 ||
          !RegExp(r'^live\b.*\b(?:tennis|atp|wta)\b', caseSensitive: false)
              .hasMatch(title)) {
        continue;
      }
      final seconds = (event['d'] as num).toInt();
      if (seconds <= 0 || seconds > 12 * 3600) continue;
      // Do not truncate a long multi-fixture synopsis into an apparent pair.
      if (description is String && description.length > 640) continue;
      final start = DateTime.fromMillisecondsSinceEpoch(
          (event['st'] as num).toInt() * 1000,
          isUtc: true);
      rows.add(EpgProgram(
          channelId: schedule['sid'] as String,
          title: title,
          description: description is String ? description : null,
          start: start,
          stop: start.add(Duration(seconds: seconds)),
          isLive: true));
    }
  }
  return rows;
}
