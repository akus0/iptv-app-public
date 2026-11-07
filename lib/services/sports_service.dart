import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../models/sports.dart';
import '../models/sports_progress.dart';
import '../models/sports_feed_issue.dart';
import '../utils/sports_calendar.dart';
import 'storage_service.dart';
import 'k_league_scoreboard.dart';
import 'easl_scoreboard.dart';
import 'regional_baseball.dart';
import 'b_league.dart';
import 'motorsport_schedule_service.dart';

bool supportsSportsScoreboard(SportsLeague league) =>
    league.source == 'ESPN' ||
    league.source == 'K League' ||
    league.source == 'EASL' ||
    const {'NPB', 'KBO', 'ABL', 'B.League'}.contains(league.source);

/// Calendar-only series remain separate from score-capable competitions.
bool supportsSportsSchedule(SportsLeague league) =>
    supportsSportsScoreboard(league) || league.source == 'RaceTV Guide';

/// Catalogue discovery is local. Feeds are loaded only by the visible view.
final sportsBrowseLeagues = List<SportsLeague>.unmodifiable({
  for (final league in [...kSportsLeagues, ...kSportsLeagueBank])
    if (league.id != 'rugby.live') league.id: league,
}.values);

/// The viewer's favourite leagues, loaded by default. Existing enabled-league
/// preferences retain their keys and selection; browsing never rewrites them.
List<SportsLeague> savedSportsLeagues(StorageService storage) {
  final hiddenGuide = storage.getHiddenGuideLeagues().toSet();
  final selected = storage.getSportsLeagues();
  final all = storage.getSportsAllLeagues() || selected == null;
  final ids = all
      ? <String>{
          ...kDefaultSportsLeagueIds,
          // Explicitly enabled optional feeds survive the existing "all" preference.
          for (final id in selected ?? const <String>[])
            if (sportsLeagueById(id)?.enabledByDefault == false) id,
        }
      : selected;
  final leagues = [
    for (final id in ids)
      if (sportsLeagueById(id) case final l?)
        if (l.source != 'Channel guide' && l.id != 'rugby.live') l,
    for (final league in kAutomaticSportsLeagues)
      if (!hiddenGuide.contains(league.id)) league,
  ];
  return leagues.isNotEmpty
      ? leagues
      : [for (final id in kDefaultSportsLeagueIds) sportsLeagueById(id)!];
}

/// Optional opening league, retained under its legacy single-favourite key.
/// It must still belong to the default favourite-league selection.
SportsLeague? favoriteSportsLeague(StorageService storage) {
  final id = storage.getSportsFavoriteLeague();
  if (id == null) return null;
  return savedSportsLeagues(storage).where((l) => l.id == id).firstOrNull;
}

/// Shared score loading, caching and failure handling. ESPN uses daily boards;
/// regional feeds share monthly or season snapshots. Responses are adapted off
/// the UI isolate, with freshness based on upcoming, live and finished games.
class SportsService {
  SportsService._()
      : _client = http.Client(),
        _clock = DateTime.now,
        _motorsport = MotorsportScheduleService.instance,
        requestTimeout = const Duration(seconds: 15);
  @visibleForTesting
  SportsService.withClient(this._client,
      {DateTime Function()? clock,
      MotorsportScheduleService? motorsport,
      this.requestTimeout = const Duration(seconds: 15)})
      : _clock = clock ?? DateTime.now,
        _motorsport =
            motorsport ?? MotorsportScheduleService(_client, clock: clock);
  final MotorsportScheduleService _motorsport;
  static SportsService? _shared;
  static SportsService get instance => _shared ??= SportsService._();

  /// Keep widget fixtures independent: cached scores and their HTTP client
  /// otherwise survive between tests that mount the normal app routes.
  @visibleForTesting
  static void resetForTesting() {
    _shared?._client.close();
    _shared = null;
  }

  static const _base = 'https://site.api.espn.com/apis/site/v2/sports';

  final http.Client _client;
  final Duration requestTimeout;
  final DateTime Function() _clock;
  final Map<String, _CacheEntry> _cache = {};
  final Map<String, Future<List<SportsGame>>> _inFlight = {};
  final Map<String, _ScoreFailure> _failures = {};
  final Map<String, DateTime> _rateLimitedUntil = {};
  final Queue<Completer<void>> _downloadQueue = Queue();
  int _activeDownloads = 0;
  final Map<String, int> _networkFailures = {};

  /// Read-only replay enrichment shares the normal HTTP limit, parser and
  /// day cache. It must never alter the live hub's error/loading state.
  Future<List<SportsGame>> replayGames(SportsLeague league, DateTime day) =>
      _fetch(league, day);

  List<SportsGame> get cachedReplayGames => [
        for (final entry in _cache.values) ...entry.games,
      ];

  /// Schedule uses the shared daily feeds without changing Events status or
  /// applying Events' live-only rugby filter. No other calendar day is prefetched.
  List<SportsGame> cachedScheduleDay(List<SportsLeague> leagues, DateTime day) {
    final first = sportsCalendarDay(day), end = sportsCalendarDay(day, 1);
    final found = <String, SportsGame>{};
    void add(Iterable<SportsGame> games) {
      for (final game in games) {
        if ((!game.start.isBefore(first) && game.start.isBefore(end)) ||
            _tournamentDay(game, first)) {
          found['${game.league.id}:${game.id}'] = game;
        }
      }
    }

    for (final (league, date) in _requestsFor(leagues, day, schedule: true)) {
      add(_cache[_scoreboardKey(league, date)]?.games ?? const []);
    }
    final calendars = leagues
        .where((l) => l.source == 'RaceTV Guide')
        .map((l) => l.id)
        .toSet();
    if (calendars.isNotEmpty) {
      add(_motorsport
          .gamesForDay(day)
          .where((g) => calendars.contains(g.league.id)));
    }
    return found.values.toList()
      ..sort((a, b) {
        final time = a.start.compareTo(b.start);
        return time != 0
            ? time
            : '${a.league.id}:${a.id}'.compareTo('${b.league.id}:${b.id}');
      });
  }

  /// Two workers bound outstanding work; leaving the pane stops subsequent
  /// requests. The shared day cache, in-flight requests and retry backoff remain
  /// authoritative. Progress is bounded to avoid rebuilding for each feed.
  Future<({List<SportsGame> games, bool incomplete})> scheduleDay(
      List<SportsLeague> leagues, DateTime day,
      {bool Function()? shouldContinue,
      void Function(List<SportsGame>)? onProgress}) async {
    final requests = _requestsFor(leagues, day, schedule: true);
    var cursor = 0, incomplete = false;
    Timer? publish;
    var published = cachedScheduleDay(leagues, day);
    bool active() => shouldContinue?.call() ?? true;
    void changed() {
      if (onProgress == null || publish != null) return;
      publish = Timer(const Duration(milliseconds: 400), () {
        publish = null;
        if (!active()) return;
        final next = cachedScheduleDay(leagues, day);
        if (listEquals(published, next)) return;
        published = next;
        onProgress(next);
      });
    }

    Future<void> worker() async {
      while (active() && cursor < requests.length) {
        final (league, date) = requests[cursor++];
        try {
          await _fetch(league, date);
          if (_failures.containsKey(_scoreboardKey(league, date))) {
            incomplete = true;
          }
        } catch (_) {
          incomplete = true;
        }
        if (active()) changed();
      }
    }

    try {
      await Future.wait([worker(), worker()]);
      if (active() && leagues.any((l) => l.source == 'RaceTV Guide')) {
        await _motorsport.warm(cancelled: () => !active());
        incomplete |= !_motorsport.hasFreshSnapshot;
      }
    } finally {
      publish?.cancel();
    }
    return (
      games: cachedScheduleDay(leagues, day),
      incomplete: incomplete || !active()
    );
  }

  final Map<String, _CacheEntry> _scheduleCache = {};
  final Map<String, Future<List<SportsGame>>> _schedulePending = {};

  /// Explicit schedule browsing only. Monthly boards avoid one request per day;
  /// requests and parsing share the score service's existing concurrency limits.
  Future<({List<SportsGame> games, bool incomplete})> scheduleGames(
      SportsLeague league, DateTime from, DateTime through,
      {bool Function()? shouldContinue}) async {
    if (!supportsSportsSchedule(league) || league.id == 'rugby.live') {
      return (games: const <SportsGame>[], incomplete: true);
    }
    final first = sportsCalendarDay(from);
    final end = sportsCalendarDay(through, 1);
    if (!end.isAfter(first) || end.difference(first).inDays > 33) {
      throw ArgumentError('Schedule windows must be between 1 and 32 days');
    }
    final games = <String, SportsGame>{};
    var incomplete = false;
    void add(Iterable<SportsGame> entries) {
      for (final game in entries) {
        if (!game.start.isBefore(first) && game.start.isBefore(end)) {
          games['${game.league.id}:${game.id}'] = game;
        }
      }
    }

    if (league.source == 'RaceTV Guide') {
      await _motorsport.warm(cancelled: () => shouldContinue?.call() == false);
      if (shouldContinue?.call() == false) {
        return (games: const <SportsGame>[], incomplete: true);
      }
      for (var day = first;
          day.isBefore(end);
          day = sportsCalendarDay(day, 1)) {
        add(_motorsport
            .gamesForDay(day)
            .where((game) => game.league.id == league.id));
      }
      incomplete = !_motorsport.hasFreshSnapshot;
    } else if (league.source == 'ESPN') {
      // Feed dates use US calendar boundaries. Include the preceding UTC day
      // before applying exact local boundaries, including month/year and DST.
      final utcFirst = first.toUtc().subtract(const Duration(days: 1));
      final utcLast = end.toUtc();
      for (var month = DateTime(utcFirst.year, utcFirst.month);
          !month.isAfter(DateTime(utcLast.year, utcLast.month));
          month = DateTime(month.year, month.month + 1)) {
        if (shouldContinue?.call() == false) break;
        final key = '${league.id}|${_espnDate(month).substring(0, 6)}';
        try {
          final entries = await _scheduleMonth(league, month, key);
          add(entries);
          // A full response at the provider limit may have more fixtures.
          if (entries.length >= 1000) incomplete = true;
        } catch (_) {
          incomplete = true;
          add(_scheduleCache[key]?.games ?? const []);
        }
      }
    } else {
      // Regional feeds choose their own daily/monthly/season cache keys.
      // Three workers bound queued work even for a 31-day window.
      var cursor = sportsCalendarDay(first, -1);
      final regionalEnd = sportsCalendarDay(end, 1);
      Future<void> worker() async {
        while (
            cursor.isBefore(regionalEnd) && (shouldContinue?.call() ?? true)) {
          final day = cursor;
          cursor = sportsCalendarDay(cursor, 1);
          try {
            add(await _fetch(league, day));
            if (_failures.containsKey(_scoreboardKey(league, day))) {
              incomplete = true;
            }
          } catch (_) {
            incomplete = true;
          }
        }
      }

      await Future.wait([worker(), worker(), worker()]);
    }
    final sorted = games.values.toList()
      ..sort((a, b) {
        final time = a.start.compareTo(b.start);
        return time != 0 ? time : a.id.compareTo(b.id);
      });
    return (games: sorted, incomplete: incomplete);
  }

  Future<List<SportsGame>> _scheduleMonth(
      SportsLeague league, DateTime month, String key) {
    final hit = _scheduleCache[key];
    final age = hit == null ? null : _clock().difference(hit.fetchedAt);
    if (age != null && !age.isNegative && age < const Duration(minutes: 10)) {
      return Future.value(hit!.games);
    }
    return _schedulePending[key] ??= () async {
      await _acquireDownload();
      try {
        final params = <String, String>{
          'dates': _espnDate(month).substring(0, 6),
          'limit': '1000',
          if (league.espnPath == 'basketball/mens-college-basketball')
            'groups': '50',
          if (league.espnPath == 'football/college-football') 'groups': '80',
        };
        final url = Uri.parse('$_base/${league.espnPath}/scoreboard')
            .replace(queryParameters: params);
        final response = await _getScoreboard(url);
        if (response.statusCode != 200) {
          throw StateError('Schedule unavailable');
        }
        final games = await _parseScoreboard(response.body, league);
        _scheduleCache.remove(key);
        _scheduleCache[key] = _CacheEntry(games, _clock());
        while (_scheduleCache.length > 12) {
          _scheduleCache.remove(_scheduleCache.keys.first);
        }
        return games;
      } finally {
        _releaseDownload();
      }
    }()
        .whenComplete(() {
      _schedulePending.remove(key);
    });
  }

  // All leagues can mean hundreds of requests and JSON isolates. Limit the
  // whole service, including loads shared by the hub and player's side panel.
  Future<void> _acquireDownload() async {
    if (_activeDownloads < 6) {
      _activeDownloads++;
      return;
    }
    final slot = Completer<void>();
    _downloadQueue.add(slot);
    // Time the request, not its position in the queue. A healthy all-league
    // load on a TV can legitimately take longer than 25 seconds to drain.
    await slot.future;
  }

  void _releaseDownload() {
    if (_downloadQueue.isNotEmpty) {
      _downloadQueue.removeFirst().complete();
    } else {
      _activeDownloads--;
      if (_activeDownloads == 0) _networkFailures.clear();
    }
  }

  Future<http.Response> _getScoreboard(Uri url,
      {Map<String, String>? body}) async {
    final limited = _rateLimitedUntil[url.host];
    if (limited != null && _clock().isBefore(limited)) {
      throw _ScoreFailure('rate limit', limited, 1);
    }
    // Drain a disconnected batch instead of opening hundreds of doomed sockets.
    if ((_networkFailures[url.host] ?? 0) >= 6) {
      throw http.ClientException('Score connection unavailable');
    }
    final abort = Completer<void>();
    try {
      // Abort the actual transport too: Future.timeout alone leaves stalled
      // sockets alive after their slot has been given to the next request.
      final request = http.AbortableRequest(body == null ? 'GET' : 'POST', url,
          abortTrigger: abort.future);
      if (body != null) {
        request.headers['Content-Type'] = 'application/json; charset=utf-8';
        request.headers['Accept-Language'] = 'en';
        request.body = jsonEncode(body);
      }
      final response = await _client.send(request).then((response) {
        if (!const {
          'npb.jp',
          'eng.koreabaseball.com',
          'statsapi.mlb.com',
          'www.bleague.jp',
        }.contains(url.host)) {
          return http.Response.fromStream(response);
        }
        var bytes = 0;
        final bounded = response.stream.map((chunk) {
          bytes += chunk.length;
          if (bytes > 2 * 1024 * 1024) {
            if (!abort.isCompleted) abort.complete();
            throw StateError('Regional sports response too large');
          }
          return chunk;
        });
        return http.Response.fromStream(http.StreamedResponse(
          bounded,
          response.statusCode,
          headers: response.headers,
          request: response.request,
          reasonPhrase: response.reasonPhrase,
          isRedirect: response.isRedirect,
          persistentConnection: response.persistentConnection,
        ));
      }).timeout(requestTimeout, onTimeout: () {
        abort.complete();
        throw TimeoutException('Event feed timed out', requestTimeout);
      });
      _networkFailures[url.host] = 0;
      if (response.statusCode == 429) {
        final header = response.headers['retry-after'];
        final seconds = int.tryParse(header ?? '');
        final until = seconds != null
            ? _clock().add(Duration(seconds: seconds.clamp(1, 86400)))
            : _retryAfterDate(header) ??
                _clock().add(const Duration(minutes: 1));
        if (_rateLimitedUntil[url.host] == null ||
            until.isAfter(_rateLimitedUntil[url.host]!)) {
          _rateLimitedUntil[url.host] = until;
        }
        throw _ScoreFailure('rate limit', _rateLimitedUntil[url.host]!, 1,
            response: response);
      }
      return response;
    } on TimeoutException {
      _networkFailures.update(url.host, (count) => count + 1,
          ifAbsent: () => 1);
      rethrow;
    } on http.ClientException {
      _networkFailures.update(url.host, (count) => count + 1,
          ifAbsent: () => 1);
      rethrow;
    }
  }

  DateTime? _retryAfterDate(String? value) {
    if (value == null) return null;
    // HTTP dates are parsed without a platform dependency (web builds too).
    try {
      final parts = value.split(' ');
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
      if (parts.length != 6 || parts.last != 'GMT') return null;
      final time = parts[4].split(':').map(int.parse).toList();
      final month = months.indexOf(parts[2]) + 1;
      if (month == 0 || time.length != 3) return null;
      final date = DateTime.utc(int.parse(parts[3]), month, int.parse(parts[1]),
          time[0], time[1], time[2]);
      return date.isAfter(_clock()) ? date : null;
    } catch (_) {
      return null;
    }
  }

  List<SportsFeedIssue> issuesForDay(
          List<SportsLeague> leagues, DateTime day) =>
      [
        for (final (league, date) in _requestsFor(leagues, day))
          if (_failures[_scoreboardKey(league, date)]?.issue case final issue?)
            issue,
      ];

  bool _retryDeferred(String key) =>
      _failures[key]?.retryAt.isAfter(_clock()) ?? false;

  /// Scope errors to the requested day/leagues, not whichever other Sports
  /// route or replay lookup happened to finish last.
  String? errorForDay(List<SportsLeague> leagues, DateTime day) {
    final errors = <String, int>{};
    var total = 0, failed = 0;
    for (final (league, date) in _requestsFor(leagues, day)) {
      total++;
      final failure = _failures[_scoreboardKey(league, date)];
      if (failure == null) continue;
      failed++;
      errors.update(failure.reason, (count) => count + 1, ifAbsent: () => 1);
    }
    if (failed == 0) return null;
    final reasons = errors.keys.join(', ');
    return '$failed of $total event feeds unavailable ($reasons). '
        'Saved events remain available; their scores may be out of date. '
        '${errors.containsKey('rate limit') ? 'Waiting for the source’s retry window.' : 'Automatic retries are spaced out. Refresh to try again now.'}';
  }

  static String _scoreboardKey(SportsLeague league, DateTime date) =>
      '${league.id}|${switch (league.source) {
        'K League' || 'NPB' => _espnDate(date).substring(0, 6),
        'ABL' => '${ablSeasonYear(date)}',
        'EASL' => 'current-season',
        _ => _espnDate(date),
      }}';

  /// Every game of [leagues] that starts on the local calendar day [day],
  /// plus — when [day] is today — games from the day before that are still
  /// live past midnight. ESPN buckets games by US Eastern date, so the days
  /// either side are fetched too (cached) and filtered locally; otherwise a
  /// European viewer would lose every evening NHL game, which falls on the
  /// next local day.
  ///
  List<DateTime> _datesFor(DateTime day) {
    return [
      sportsCalendarDay(day),
      sportsCalendarDay(day, -1),
      sportsCalendarDay(day, 1),
    ];
  }

  List<(SportsLeague, DateTime)> _requestsFor(
      List<SportsLeague> leagues, DateTime day,
      {bool schedule = false}) {
    final seen = <String>{};
    // Schedule needs each selected competition's future fixtures; the aggregate
    // rugby feed replaces concrete leagues only in Events' live-only view.
    final enabled = schedule
        ? leagues
            .where((l) => supportsSportsScoreboard(l) && l.id != 'rugby.live')
        : _requestLeagues(leagues);
    return [
      for (final date in _datesFor(day))
        for (final league in enabled)
          if (seen.add(_scoreboardKey(league, date))) (league, date),
    ];
  }

  List<SportsLeague> _requestLeagues(List<SportsLeague> leagues) {
    final allRugby = leagues.any((l) => l.id == 'rugby.live');
    return leagues
        .where((l) =>
            supportsSportsScoreboard(l) &&
            (!allRugby ||
                !l.espnPath.startsWith('rugby/') ||
                l.id == 'rugby.live'))
        .toList();
  }

  /// Reopening the tab immediately returns known games for this day/selection.
  List<SportsGame> cachedGamesForDay(
          List<SportsLeague> leagues, DateTime day) =>
      _gamesOnDay([
        for (final (league, date) in _requestsFor(leagues, day))
          if (league.id != 'rugby.live' ||
              _clock().difference(
                      _cache[_scoreboardKey(league, date)]?.fetchedAt ??
                          DateTime(2000)) <
                  const Duration(minutes: 3))
            _cache[_scoreboardKey(league, date)]?.games ?? const [],
      ], day);

  Future<List<SportsGame>> gamesForDay(List<SportsLeague> leagues, DateTime day,
          {void Function(List<SportsGame>)? onProgress,
          bool forceRefresh = false,
          void Function(SportsWorkProgress)? onStatus}) =>
      _gamesForDay(leagues, day,
          onProgress: onProgress,
          forceRefresh: forceRefresh,
          onStatus: onStatus);

  /// Visible event browsing stops scheduling new work when its view is left.
  /// Every result scope shares the same feeds, ranking, cache and parsers.
  Future<List<SportsGame>> gamesForDayWhileActive(
          List<SportsLeague> leagues, DateTime day,
          {required bool Function() shouldContinue,
          void Function(List<SportsGame>)? onProgress,
          bool forceRefresh = false,
          void Function(SportsWorkProgress)? onStatus}) =>
      _gamesForDay(leagues, day,
          shouldContinue: shouldContinue,
          onProgress: onProgress,
          forceRefresh: forceRefresh,
          onStatus: onStatus);

  Future<List<SportsGame>> _gamesForDay(
      List<SportsLeague> leagues, DateTime day,
      {void Function(List<SportsGame>)? onProgress,
      bool forceRefresh = false,
      bool Function()? shouldContinue,
      void Function(SportsWorkProgress)? onStatus}) async {
    bool active() => shouldContinue?.call() ?? true;
    if (!active()) return cachedGamesForDay(leagues, day);
    leagues = _requestLeagues(leagues);
    final requests = _requestsFor(leagues, day);
    final total = requests.length;
    // A warm visit needs no request queue, timers or hundreds of Futures.
    // In-flight forced refreshes still win over the older cached response.
    if (!forceRefresh &&
        requests.every((request) {
          final (league, date) = request;
          return !_inFlight.containsKey(_scoreboardKey(league, date)) &&
              (_retryDeferred(_scoreboardKey(league, date)) ||
                  (!_failures.containsKey(_scoreboardKey(league, date)) &&
                      _freshEntry(league, date) != null));
        })) {
      lastError = errorForDay(leagues, day);
      return cachedGamesForDay(leagues, day);
    }
    var completed = 0, failed = 0;
    String? latest;
    Timer? statusTimer;
    void publishStatus() {
      if (!active()) return;
      onStatus?.call(SportsWorkProgress(SportsWorkStage.scores,
          completed: completed, total: total, detail: latest, failed: failed));
    }

    publishStatus();
    Timer? publishTimer;
    var published = cachedGamesForDay(leagues, day);
    void scheduleProgress() {
      if (!active() || onProgress == null || publishTimer != null) return;
      // At most two UI updates a second, even with many fast cached replies.
      publishTimer = Timer(const Duration(milliseconds: 400), () {
        publishTimer = null;
        if (!active()) return;
        final next = cachedGamesForDay(leagues, day);
        // Empty/cached replies and timezone-neighbour fixtures often leave
        // today's events unchanged. Avoid rebuilding and rematching that same
        // list while the status counters continue updating independently.
        if (listEquals(published, next)) return;
        published = next;
        onProgress(next);
      });
    }

    // Change queue order only: retain coverage, TTLs and the six-request cap.
    // A local date can be ahead of ESPN's US date, especially in the morning.
    final now = _clock();
    final eastern = now.toUtc().subtract(const Duration(hours: 5));
    final preferred = sportsCalendarDay(day) == _today()
        ? DateTime(eastern.year, eastern.month, eastern.day)
        : sportsCalendarDay(day);
    int priority((SportsLeague, DateTime) request) {
      final games = _cache[_scoreboardKey(request.$1, request.$2)]?.games;
      if (games?.any((g) => g.isLive) == true) return 0;
      if (games?.any((g) =>
              g.state == GameState.pre &&
              g.start.isAfter(now.subtract(const Duration(hours: 1))) &&
              g.start.isBefore(now.add(const Duration(hours: 2)))) ==
          true) {
        return 1;
      }
      return request.$2 == preferred ? 2 : 3;
    }

    // Stable ties preserve league order. The summer offset can only alter
    // priority around midnight; every neighbouring date is still requested.
    final ordered = requests.indexed
        .map((entry) => (entry.$1, entry.$2, priority(entry.$2)))
        .toList()
      ..sort((a, b) {
        final order = a.$3.compareTo(b.$3);
        return order != 0 ? order : a.$1.compareTo(b.$1);
      });
    Future<void> fetch(SportsLeague league, DateTime date) async {
      await _fetch(league, date, forceRefresh: forceRefresh);
      completed++;
      latest = league.shortName;
      if (_failures.containsKey(_scoreboardKey(league, date))) failed++;
      if (active() && onStatus != null) {
        statusTimer ??= Timer(const Duration(milliseconds: 350), () {
          statusTimer = null;
          publishStatus();
        });
      }
      scheduleProgress();
    }

    try {
      if (shouldContinue == null) {
        await Future.wait([
          for (final (_, (league, date), _) in ordered) fetch(league, date),
        ]);
      } else {
        var cursor = 0;
        Future<void> worker() async {
          while (active() && cursor < ordered.length) {
            final (_, (league, date), _) = ordered[cursor++];
            await fetch(league, date);
            if (cursor % 8 == 0) await Future<void>.delayed(Duration.zero);
          }
        }

        await Future.wait([for (var i = 0; i < 6; i++) worker()]);
      }
    } finally {
      publishTimer?.cancel();
      statusTimer?.cancel();
      publishStatus();
    }
    lastError = errorForDay(leagues, day);
    return cachedGamesForDay(leagues, day);
  }

  List<SportsGame> _gamesOnDay(
      Iterable<List<SportsGame>> results, DateTime day) {
    final local = DateTime(day.year, day.month, day.day);
    final nextDay = sportsCalendarDay(local, 1);
    final previousDay = sportsCalendarDay(local, -1);
    final today = _today();
    final seen = <String>{};
    final games = <SportsGame>[];
    for (final list in results) {
      for (final g in list) {
        // Rugby Events are score-backed live fixtures, never programmes or schedules.
        if (g.league.espnPath.startsWith('rugby/') &&
            g.state != GameState.live) {
          continue;
        }
        if (!seen.add('${g.league.id}:${g.id}')) continue;
        // Compare instants against local calendar boundaries once per read.
        // Repeated toLocal/year/month/day conversions for every cached event
        // are costly on TVs. Calendar days, rather than 24-hour durations,
        // preserve membership across daylight-saving changes.
        final start = g.start;
        final sameDay =
            g.end == null && !start.isBefore(local) && start.isBefore(nextDay);
        final carriedOver = local == today &&
            g.isLive &&
            start.isBefore(local) &&
            !start.isBefore(previousDay);
        if (sameDay || carriedOver || _tournamentDay(g, local)) games.add(g);
      }
    }
    games.sort((a, b) {
      final byStart = a.start.compareTo(b.start);
      return byStart != 0 ? byStart : a.league.id.compareTo(b.league.id);
    });
    return games;
  }

  /// A golf tournament runs Thursday to Sunday but ESPN dates it once, at
  /// US-Eastern midnight of day one (`04:00Z`/`05:00Z`), with `endDate` the
  /// last day's midnight. Shown on each of its days: those are Eastern
  /// calendar dates, so read them 4 h back from UTC rather than in the
  /// viewer's zone (midnight Eastern is the evening before in California).
  static bool _tournamentDay(SportsGame g, DateTime localDay) {
    final end = g.end;
    if (end == null) return false;
    DateTime easternDate(DateTime utc) {
      final t = utc.subtract(const Duration(hours: 4));
      return DateTime(t.year, t.month, t.day);
    }

    final first = easternDate(g.start);
    final last = easternDate(end);
    return !localDay.isBefore(first) && !localDay.isAfter(last);
  }

  /// Set when the most recent load had at least one failed request.
  String? lastError;

  DateTime _today() {
    final n = _clock();
    return DateTime(n.year, n.month, n.day);
  }

  static String _espnDate(DateTime d) => '${d.year.toString().padLeft(4, '0')}'
      '${d.month.toString().padLeft(2, '0')}'
      '${d.day.toString().padLeft(2, '0')}';

  final Map<String, (List<DateTime>, DateTime)> _windowStarts = {};
  final Map<String, Future<List<DateTime>?>> _windowStartsInFlight = {};

  /// Start of [league]'s first game on or after the local day [from], from
  /// ESPN's dateless scoreboard (the league's current or next round). Lets
  /// an empty day offer "Next game: ..." — cups and off-season leagues can
  /// go weeks without a game. Null when ESPN lists nothing upcoming.
  Future<DateTime?> nextGameStart(SportsLeague league, DateTime from) async {
    if (league.source != 'ESPN' || league.id == 'rugby.live') return null;
    final day = sportsCalendarDay(from);
    // Event sports query a date range; another browsing day is another window.
    // Team sports use the same dateless scoreboard and can share its cache.
    final key = league.kind == SportsKind.team
        ? league.id
        : '${league.id}|${_espnDate(day)}';
    final hit = _windowStarts[key];
    List<DateTime>? starts = hit?.$1;
    if (hit == null ||
        _clock().difference(hit.$2) > const Duration(minutes: 30)) {
      starts = await (_windowStartsInFlight[key] ??=
          _downloadWindowStarts(league, day, key).whenComplete(() {
        _windowStartsInFlight.remove(key);
      }));
    }
    DateTime? first;
    for (final start in starts ?? const <DateTime>[]) {
      if (!start.isBefore(day) && (first == null || start.isBefore(first))) {
        first = start;
      }
    }
    return first;
  }

  Future<List<DateTime>?> _downloadWindowStarts(
      SportsLeague league, DateTime day, String key) async {
    var acquired = false;
    try {
      await _acquireDownload();
      acquired = true;
      // Event sports' dateless scoreboard is the *last* event (UFC showed
      // last week's card, so "no upcoming games"); a 60-day range lists
      // what's next. Team leagues keep the dateless call — a range there
      // is hundreds of games (NHL's failed outright).
      final range = league.kind == SportsKind.team
          ? ''
          : '?dates=${_espnDate(day)}-${_espnDate(sportsCalendarDay(day, 60))}';
      final response = await _getScoreboard(
          Uri.parse('$_base/${league.espnPath}/scoreboard$range'));
      if (response.statusCode != 200) return null;
      final games = await _parseScoreboard(response.body, league);
      final starts = [for (final g in games) g.start.toLocal()];
      _windowStarts.remove(key);
      _windowStarts[key] = (starts, _clock());
      while (_windowStarts.length > 64) {
        _windowStarts.remove(_windowStarts.keys.first);
      }
      return starts;
    } catch (e) {
      debugPrint('SportsService: ${league.id} next game failed: $e');
      return null;
    } finally {
      if (acquired) _releaseDownload();
    }
  }

  _CacheEntry? _freshEntry(SportsLeague league, DateTime date) {
    final cached = _cache[_scoreboardKey(league, date)];
    if (cached == null) return null;
    final now = _clock();
    if (now.isBefore(cached.fetchedAt)) return null;
    // No feed expires before 50 seconds. Avoid scanning its games or deriving
    // calendar dates until the shortest freshness window can actually expire.
    // At the boundary use the existing rules (rugby expires at exactly 50s).
    if (now.difference(cached.fetchedAt) < const Duration(seconds: 50)) {
      return cached;
    }
    final fresh = league.id == 'rugby.live'
        ? now.difference(cached.fetchedAt) < const Duration(seconds: 50)
        : !cached.isStale(
            (league.source == 'K League' || league.source == 'NPB')
                ? DateTime(date.year, date.month + 1, 0)
                : (league.source == 'EASL' || league.source == 'ABL')
                    ? _today()
                    : date,
            _today(),
            now);
    return fresh ? cached : null;
  }

  Future<List<SportsGame>> _fetch(SportsLeague league, DateTime date,
      {bool forceRefresh = false}) {
    if (!supportsSportsScoreboard(league)) return Future.value(const []);
    final key = _scoreboardKey(league, date);
    final pending = _inFlight[key];
    if (pending != null) return pending;
    if (!forceRefresh && _retryDeferred(key)) {
      return Future.value(_cache[key]?.games ?? const []);
    }
    final cached = forceRefresh || _failures.containsKey(key)
        ? null
        : _freshEntry(league, date);
    if (cached != null) return Future.value(cached.games);
    return _inFlight[key] = _download(league, date, key).whenComplete(() {
      _inFlight.remove(key);
    });
  }

  Future<List<SportsGame>> _download(
      SportsLeague league, DateTime date, String key) async {
    final isKLeague = league.source == 'K League';
    final url = switch (league.source) {
      'K League' => Uri.https('www.kleague.com', '/getScheduleList.do'),
      'EASL' => Uri.https('easl.joshricha.com', '/api/v1/matches'),
      'NPB' => Uri.https('npb.jp',
          '/games/${date.year}/schedule_${date.month.toString().padLeft(2, '0')}_detail.html'),
      'B.League' => Uri.https('www.bleague.jp', '/en/schedule/', {
          'year': '${date.year}',
          'mon': '${date.month}',
          'day': date.day.toString().padLeft(2, '0'),
          'tab': '1',
        }),
      'KBO' => Uri.https('eng.koreabaseball.com', '/Schedule/Scoreboard.aspx', {
          'searchDate':
              '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}',
        }),
      'ABL' => Uri.https('statsapi.mlb.com', '/api/v1/schedule', {
          'sportId': '17',
          'leagueId': '595',
          'season': '${ablSeasonYear(date)}',
          'hydrate': 'team,venue(timezone),linescore',
        }),
      _ => Uri.parse(
          '$_base/${league.espnPath}/scoreboard?dates=${_espnDate(date)}${_scoreboardOptions(league)}'),
    };
    var acquired = false;
    http.Response? response;
    try {
      await _acquireDownload();
      acquired = true;
      response = await _getScoreboard(url,
          body: isKLeague
              ? {
                  'leagueId': league.id.split('.').last,
                  'year': '${date.year}',
                  'month': date.month.toString().padLeft(2, '0'),
                  'teamId': '',
                  'ticketYn': '',
                  'lang': 'en',
                }
              : null);
      if (response.statusCode != 200) {
        throw Exception('HTTP ${response.statusCode}');
      }
      final body = const {'NPB', 'KBO', 'B.League'}.contains(league.source)
          ? utf8.decode(response.bodyBytes)
          : response.body;
      // A busy NFL Sunday is a few hundred KB of JSON — decoded off the UI
      // isolate so the screen keeps responding on a weak box.
      final games = await _parseScoreboard(body, league);
      _cache.remove(key);
      _cache[key] = _CacheEntry(games, _clock());
      while (_cache.length > 600) {
        _failures.remove(_cache.keys.first);
        _cache.remove(_cache.keys.first);
      }
      _failures.remove(key);
      return games;
    } catch (e) {
      if (e is _ScoreFailure &&
          e.response == null &&
          _failures.containsKey(key)) {
        // Waiting is not a new response. Preserve the last real HTTP evidence.
        return _cache[key]?.games ?? const [];
      }
      if (kDebugMode && e is! _ScoreFailure) {
        debugPrint('SportsService: ${league.id} ${_espnDate(date)} failed: $e');
      }
      final attempts = ((_failures[key]?.attempts ?? 0) + 1).clamp(1, 5);
      final reason = e is _ScoreFailure
          ? e.reason
          : e is TimeoutException
              ? 'timeout'
              : e is http.ClientException
                  ? 'connection'
                  : e is FormatException
                      ? 'invalid response'
                      : e.toString().contains('HTTP ')
                          ? 'HTTP ${e.toString().split('HTTP ').last}'
                          : 'source error';
      final retryAt = e is _ScoreFailure
          ? e.retryAt
          : _clock().add(
              Duration(seconds: (30 * (1 << (attempts - 1))).clamp(30, 300)));
      _failures.remove(key);
      final received = response ?? (e is _ScoreFailure ? e.response : null);
      // Copy only a bounded response preview, never retain whole HTTP bodies.
      final bytes = received?.bodyBytes;
      final body = bytes == null
          ? null
          : utf8.decode(bytes.take(2048).toList(), allowMalformed: true) +
              (bytes.length > 2048 ? '\n… response truncated at 2 KB' : '');
      _failures[key] = _ScoreFailure(reason, retryAt, attempts,
          issue: SportsFeedIssue(
              league: league.name,
              endpoint: url.toString(),
              reason: reason,
              checkedAt: _clock(),
              retryAt: retryAt,
              statusCode: received?.statusCode,
              responseBody: body,
              contentType: received?.headers['content-type'],
              lastSuccess: _cache[key]?.fetchedAt,
              requested: e is! _ScoreFailure || e.response != null));
      while (_failures.length > 600) {
        _failures.remove(_failures.keys.first);
      }
      return _cache[key]?.games ?? const [];
    } finally {
      if (acquired) _releaseDownload();
    }
  }
}

class _ScoreFailure implements Exception {
  const _ScoreFailure(this.reason, this.retryAt, this.attempts,
      {this.response, this.issue});
  final http.Response? response;
  final SportsFeedIssue? issue;
  final String reason;
  final DateTime retryAt;
  final int attempts;
  @override
  String toString() => 'Event feed unavailable: $reason';
}

String _scoreboardOptions(SportsLeague league) => switch (league.espnPath) {
      'basketball/mens-college-basketball' => '&groups=50&limit=300',
      'football/college-football' => '&groups=80&limit=300',
      _ => league.id == 'rugby.live' ? '&limit=100' : '',
    };

class _CacheEntry {
  _CacheEntry(this.games, this.fetchedAt);
  final List<SportsGame> games;
  final DateTime fetchedAt;
  static final _postponed =
      RegExp(r'postponed|cancelled|canceled', caseSensitive: false);

  bool isStale(DateTime espnDate, DateTime today, DateTime now) {
    final age = now.difference(fetchedAt);
    final live = games.any((g) => g.isLive);
    final startsSoon = games.any((g) {
      if (g.state != GameState.pre || _postponed.hasMatch(g.statusText)) {
        return false;
      }
      final until = g.start.difference(now.toUtc());
      return until >= const Duration(hours: -3) &&
          until < const Duration(minutes: 30);
    });
    if (live || startsSoon) return age > const Duration(seconds: 50);
    final d = DateTime(espnDate.year, espnDate.month, espnDate.day);
    if (d.isBefore(sportsCalendarDay(today, -1))) {
      return age > const Duration(hours: 6);
    }
    return age > const Duration(minutes: 10);
  }
}

// Bound CPU concurrency independently of the six HTTP slots. Fast replies are
// parsed together, rather than starting up to six competing Dart isolates on a
// small TV CPU. Each malformed response still fails independently.
final _scoreboardParseQueue =
    Queue<(String, SportsLeague, Completer<List<SportsGame>>)>();
bool _parsingScoreboards = false;
Future<List<SportsGame>> _parseScoreboard(String body, SportsLeague league) {
  final done = Completer<List<SportsGame>>();
  _scoreboardParseQueue.add((body, league, done));
  if (!_parsingScoreboards) {
    _parsingScoreboards = true;
    unawaited(_drainScoreboards());
  }
  return done.future;
}

Future<void> _drainScoreboards() async {
  try {
    while (_scoreboardParseQueue.isNotEmpty) {
      await Future<void>.delayed(Duration.zero);
      final batch = <(String, SportsLeague, Completer<List<SportsGame>>)>[];
      var size = 0;
      while (_scoreboardParseQueue.isNotEmpty &&
          batch.length < 4 &&
          size < 1024 * 1024) {
        final item = _scoreboardParseQueue.removeFirst();
        batch.add(item);
        size += item.$1.length;
      }
      try {
        final parsed = await compute(_parseScoreboardBatch,
            [for (final item in batch) (item.$1, item.$2)]);
        for (var i = 0; i < batch.length; i++) {
          final result = parsed[i];
          if (result.$2 != null) {
            batch[i].$3.completeError(FormatException(result.$2!));
          } else {
            batch[i].$3.complete(result.$1!);
          }
        }
      } catch (error, stack) {
        for (final item in batch) {
          if (!item.$3.isCompleted) item.$3.completeError(error, stack);
        }
      }
    }
  } finally {
    _parsingScoreboards = false;
  }
}

List<(List<SportsGame>?, String?)> _parseScoreboardBatch(
        List<(String, SportsLeague)> batch) =>
    [for (final item in batch) _parseScoreboardResult(item)];
(List<SportsGame>?, String?) _parseScoreboardResult(
    (String, SportsLeague) item) {
  try {
    return (
      switch (item.$2.source) {
        'K League' => parseKLeagueScoreboard(item.$1, item.$2),
        'EASL' => parseEaslScoreboard(item.$1, item.$2),
        'NPB' => parseNpbScoreboard(item.$1, item.$2),
        'KBO' => parseKboScoreboard(item.$1, item.$2),
        'B.League' => parseBLeagueScoreboard(item.$1, item.$2),
        'ABL' => parseAblScoreboard(item.$1, item.$2),
        _ => parseEspnScoreboard(item),
      },
      null
    );
  } catch (error) {
    return (null, error.toString());
  }
}

/// Top-level so [compute] can run it on a background isolate.
@visibleForTesting
List<SportsGame> parseEspnScoreboard((String, SportsLeague) args) {
  final (body, league) = args;
  final json = jsonDecode(body);
  if (json is! Map<String, dynamic>) {
    throw const FormatException('Expected scoreboard object');
  }
  final events = json['events'];
  if (events is! List) {
    throw const FormatException('Expected scoreboard events');
  }
  final games = <SportsGame>[];
  for (final e in events) {
    try {
      final m = e as Map<String, dynamic>;
      switch (league.kind) {
        case SportsKind.broadcast:
          break;
        case SportsKind.team:
          final game = _parseEvent(
              m, league.id == 'rugby.live' ? _rugbyEventLeague(m) : league);
          if (game != null) games.add(game);
        case SportsKind.golf:
          final game = _parseGolf(m, league);
          if (game != null) games.add(game);
        case SportsKind.racing:
          games.addAll(_parseRacing(m, league));
        case SportsKind.fight:
          final game = _parseFightCard(m, league);
          if (game != null) games.add(game);
        case SportsKind.tennis:
          games.addAll(_parseTennis(m, league));
      }
    } catch (_) {
      // One malformed event shouldn't drop the whole league.
    }
  }
  return games;
}

// ESPN's all-rugby feed supplies the competition slug in event links. Keep
// stable league IDs so picks and ordinary per-league fixtures refer to one event.
final _rugbyLeagueLink = RegExp(r'/league/(\d+)');
SportsLeague _rugbyEventLeague(Map<String, dynamic> event) {
  for (final link in event['links'] as List? ?? const []) {
    if (link is! Map) continue;
    final id = _rugbyLeagueLink.firstMatch(link['href']?.toString() ?? '')?[1];
    if (id == null) continue;
    return sportsLeagueById('rugby.$id') ??
        SportsLeague(
            id: 'rugby.$id',
            espnPath: 'rugby/$id',
            name: 'International & club rugby',
            shortName: 'Rugby',
            logoUrl: '',
            hasStandings: false);
  }
  return kLiveRugbyLeague;
}

// ------------------------------------------------------------ event sports

// These statuses interrupt an ongoing contest; a provider's broad "post"
// state must not turn an unfinished match into a final result.
const _interruptedStatuses = {
  'STATUS_SUSPENDED': 'Suspended',
  'STATUS_INTERRUPTED': 'Interrupted',
  'STATUS_MEDICAL_TIMEOUT': 'Medical timeout',
  'STATUS_TIMEOUT': 'Timeout',
  'STATUS_RAIN_DELAY': 'Rain delay',
};

GameState _stateOf(Map<String, dynamic>? status) {
  final type = status?['type'] as Map?;
  if (type?['completed'] == true) return GameState.post;
  if (_interruptedStatuses.containsKey(type?['name'])) return GameState.live;
  return switch (type?['state']) {
    'in' => GameState.live,
    'post' => GameState.post,
    _ => GameState.pre,
  };
}

String _statusTextOf(Map<String, dynamic>? status) {
  final type = status?['type'] as Map?;
  // Interrupted feeds can omit shortDetail or leave it blank. Keep the reason
  // visible on the card rather than showing an empty live-status label.
  for (final key in ['shortDetail', 'detail', 'description']) {
    final text = type?[key]?.toString().trim();
    if (text != null && text.isNotEmpty) return text;
  }
  return _interruptedStatuses[type?['name']] ?? '';
}

List<String> _broadcastsOf(Iterable<Map<String, dynamic>> comps) =>
    _broadcastDetailsOf(comps).map((b) => b.name).toSet().toList();

List<SportsBroadcast> _broadcastDetailsOf(
    Iterable<Map<String, dynamic>> comps) {
  final out = <String, SportsBroadcast>{};
  String label(Object? value) => value is Map
      ? (value['shortName'] ??
              value['name'] ??
              value['displayName'] ??
              value['type'] ??
              '')
          .toString()
      : value is String
          ? value
          : '';
  for (final comp in comps) {
    for (final key in ['broadcasts', 'geoBroadcasts']) {
      final rows = comp[key];
      if (rows is! List) continue;
      for (final row in rows.whereType<Map>()) {
        final names = <String>{
          if (row['names'] is List)
            ...(row['names'] as List).whereType<String>(),
          label(row['media'])
        };
        for (final raw in names) {
          final name = raw.trim();
          if (name.isEmpty) continue;
          final listing = SportsBroadcast(name,
              source: 'ESPN',
              country: SportsBroadcast.countryName('${row['region'] ?? ''}'),
              medium: label(row['type']),
              market: label(row['market']),
              language: '${row['lang'] ?? ''}');
          out[listing.evidenceKey] = listing;
        }
      }
    }
  }
  // Geo metadata overrides a duplicate unqualified network from broadcasts.
  final qualified = out.values
      .where((b) => b.country.isNotEmpty || b.medium.isNotEmpty)
      .map((b) => b.name.toLowerCase())
      .toSet();
  return out.values
      .where((b) =>
          b.country.isNotEmpty ||
          b.medium.isNotEmpty ||
          !qualified.contains(b.name.toLowerCase()))
      .toList();
}

String? _venueOf(Map<String, dynamic> e, Map<String, dynamic>? comp) {
  Object? v = e['circuit'] ?? comp?['venue'] ?? e['venues'];
  if (v is List) v = v.isEmpty ? null : v.first;
  if (v is! Map) return null;
  final name = v['fullName']?.toString();
  final city = (v['address'] as Map?)?['city']?.toString();
  if (name == null || name.isEmpty) return city;
  return city == null || city.isEmpty || name.contains(city)
      ? name
      : '$name, $city';
}

List<Map<String, dynamic>> _competitorsByOrder(Map<String, dynamic> comp) {
  final list = [
    for (final c in (comp['competitors'] as List?) ?? const [])
      (c as Map).cast<String, dynamic>()
  ];
  int order(Map<String, dynamic> c) => (c['order'] as num?)?.toInt() ?? 1 << 20;
  list.sort((a, b) => order(a).compareTo(order(b)));
  return list;
}

String? _flagOf(Map<String, dynamic> c) =>
    ((c['athlete'] as Map?)?['flag'] as Map?)?['href']?.toString();

String _athleteName(Map<String, dynamic> c, {bool short = false}) {
  final a = (c['athlete'] as Map?) ?? const {};
  return ((short ? a['shortName'] : null) ??
          a['displayName'] ??
          a['fullName'] ??
          '')
      .toString();
}

/// Golf and racing have no sides; the cards read the event instead, but the
/// rest of the tab (glow, picks, search) still expects two teams.
SportsTeam _placeholderSide(SportsLeague league, String title) => SportsTeam(
      id: '',
      name: title,
      shortName: title,
      abbreviation: league.shortName,
      logoUrl: league.logoUrl,
    );

SportsGame? _parseGolf(Map<String, dynamic> e, SportsLeague league) {
  final comp = ((e['competitions'] as List?)?.firstOrNull as Map?)
      ?.cast<String, dynamic>();
  if (comp == null) return null;
  final status = (comp['status'] ?? e['status']) as Map<String, dynamic>?;
  final state = _stateOf(status);
  final title = (e['name'] ?? '').toString();
  final players = _competitorsByOrder(comp);
  // Ties share a place ("T3"), the way every leaderboard shows them.
  final leaders = <SportsEventEntry>[];
  if (state != GameState.pre) {
    for (var i = 0; i < players.length && leaders.length < 5; i++) {
      final score = players[i]['score']?.toString();
      var first = i;
      while (first > 0 && players[first - 1]['score']?.toString() == score) {
        first--;
      }
      final tied = (i + 1 < players.length &&
              players[i + 1]['score']?.toString() == score) ||
          first != i;
      leaders.add(SportsEventEntry(
        position: '${tied ? 'T' : ''}${first + 1}',
        name: _athleteName(players[i], short: true),
        flagUrl: _flagOf(players[i]),
        value: score,
      ));
    }
  }
  final round = (status?['period'] as num?)?.toInt();
  final side = _placeholderSide(league, title);
  final endRaw = e['endDate']?.toString();
  return SportsGame(
    id: e['id'].toString(),
    league: league,
    start: DateTime.parse((e['date'] ?? comp['date']).toString()).toUtc(),
    end: endRaw == null ? null : DateTime.tryParse(endRaw)?.toUtc(),
    state: state,
    statusText: _statusTextOf(status),
    home: side,
    away: side,
    broadcasts: _broadcastsOf([comp]),
    scoreboardBroadcasts: _broadcastDetailsOf([comp]),
    event: SportsEventInfo(
      title: title,
      participantIds: [
        for (final player in players)
          if (player['athlete'] case {'id': final Object id}) id.toString()
      ],
      playActive: !const {
        'STATUS_PLAY_COMPLETE',
        'STATUS_SUSPENDED',
        'STATUS_DELAYED',
        'STATUS_POSTPONED',
      }.contains((status?['type'] as Map?)?['name']),
      session: state != GameState.pre && round != null && round > 0
          ? 'Round $round'
          : null,
      venue: _venueOf(e, comp),
      leaders: leaders,
    ),
  );
}

/// ESPN's session abbreviations. F1 practices are watchable sessions too.
const Map<String, String?> _racingSessions = {
  'FP1': null,
  'FP2': null,
  'FP3': null,
  'SS': 'Sprint Qualifying',
  'SR': 'Sprint',
  'Qual': 'Qualifying',
  'Race': 'Race',
};

List<SportsGame> _parseRacing(Map<String, dynamic> e, SportsLeague league) {
  final title = (e['name'] ?? '').toString();
  final side = _placeholderSide(league, title);
  final out = <SportsGame>[];
  for (final raw in (e['competitions'] as List?) ?? const []) {
    final comp = (raw as Map).cast<String, dynamic>();
    final abbr = (comp['type'] as Map?)?['abbreviation']?.toString();
    // NASCAR/IndyCar events are one untyped competition: the race.
    final session = abbr == null
        ? 'Race'
        : (_racingSessions.containsKey(abbr) ? _racingSessions[abbr] : abbr);
    final shownSession = session ??
        (league.id == 'racing.f1' && const {'FP1', 'FP2', 'FP3'}.contains(abbr)
            ? 'Practice ${abbr!.substring(2)}'
            : null);
    if (shownSession == null) continue;
    final status = (comp['status'] ?? e['status']) as Map<String, dynamic>?;
    final state = _stateOf(status);
    final drivers = _competitorsByOrder(comp);
    out.add(SportsGame(
      id: (comp['id'] ?? e['id']).toString(),
      league: league,
      start: DateTime.parse((comp['date'] ?? e['date']).toString()).toUtc(),
      state: state,
      statusText: _statusTextOf(status),
      home: side,
      away: side,
      broadcasts: _broadcastsOf([comp]),
      scoreboardBroadcasts: _broadcastDetailsOf([comp]),
      event: SportsEventInfo(
        title: title,
        participantIds: [
          for (final driver in drivers)
            if (driver['athlete'] case {'id': final Object id}) id.toString()
        ],
        participantNames: {
          for (final driver in drivers)
            if (driver['athlete'] case {'id': final Object id})
              id.toString(): _athleteName(driver)
        },
        session: shownSession,
        venue: _venueOf(e, comp),
        // Before the start the order is just the entry list.
        leaders: state == GameState.pre
            ? const []
            : [
                for (var i = 0; i < drivers.length && i < 5; i++)
                  SportsEventEntry(
                    position: '${i + 1}',
                    name: _athleteName(drivers[i], short: true),
                    flagUrl: _flagOf(drivers[i]),
                  ),
              ],
      ),
    ));
  }
  return out;
}

/// A tennis tournament is one ESPN event with `groupings` (Men's Singles,
/// Women's Doubles…), each listing every match of the tournament. Each
/// main-draw singles match becomes a card ([gamesForDay] keeps the day's):
/// doubles (no athlete per side) and qualifying rounds are left out — a
/// tournament day would otherwise be 50+ cards. Score = sets won.
List<SportsGame> _parseTennis(Map<String, dynamic> e, SportsLeague league) {
  final tournament = (e['name'] ?? '').toString();
  final out = <SportsGame>[];
  for (final g in (e['groupings'] as List?) ?? const []) {
    final grouping =
        ((g as Map)['grouping'] as Map?)?['displayName']?.toString() ?? '';
    if (!grouping.toLowerCase().contains('singles')) continue;
    for (final c in (g['competitions'] as List?) ?? const []) {
      final comp = (c as Map).cast<String, dynamic>();
      final round = ((comp['round'] as Map?)?['displayName'] ?? '').toString();
      if (round.toLowerCase().contains('qualif')) continue;
      final players = _competitorsByOrder(comp);
      if (players.length != 2 || players.any((p) => p['athlete'] is! Map)) {
        continue;
      }
      final date = DateTime.tryParse((comp['date'] ?? '').toString());
      if (date == null) continue;
      final status = comp['status'] as Map<String, dynamic>?;
      final state = _stateOf(status);
      List<num> sets(Map<String, dynamic> p) => [
            for (final l in (p['linescores'] as List?) ?? const [])
              ((l as Map)['value'] as num?) ?? 0,
          ];
      final a = sets(players[0]), b = sets(players[1]);
      int won(List<num> mine, List<num> theirs) {
        var n = 0;
        for (var i = 0; i < mine.length && i < theirs.length; i++) {
          // A set still being played counts once it's over (6+ games, 2 up,
          // or 7 after a tie-break) — otherwise only finished matches.
          final done = state == GameState.post || i < mine.length - 1;
          if (done && mine[i] > theirs[i]) n++;
        }
        return n;
      }

      SportsTeam player(Map<String, dynamic> p, int setsWon) {
        final full = _athleteName(p);
        return SportsTeam(
          id: ((p['athlete'] as Map?)?['id'] ?? p['id'] ?? full).toString(),
          name: full,
          shortName: full,
          abbreviation: full
              .split(' ')
              .where((w) => w.isNotEmpty)
              .map((w) => w[0])
              .take(2)
              .join()
              .toUpperCase(),
          logoUrl: _flagOf(p),
          score: state == GameState.pre ? null : '$setsWon',
        );
      }

      out.add(SportsGame(
        id: comp['id'].toString(),
        league: league,
        start: date.toUtc(),
        state: state,
        statusText: _statusTextOf(status),
        home: player(players[0], won(a, b)),
        away: player(players[1], won(b, a)),
        broadcasts: _broadcastsOf([e, comp]),
        scoreboardBroadcasts: _broadcastDetailsOf([e, comp]),
        event: SportsEventInfo(
          title: tournament,
          matchingNames: {
            for (final key in ['shortName', 'shortDisplayName'])
              if (e[key] is String && (e[key] as String).trim().isNotEmpty)
                (e[key] as String).trim(),
            if (comp['venue'] is Map &&
                (comp['venue']['fullName'] ?? '').toString().contains(','))
              comp['venue']['fullName'].toString().split(',').first.trim(),
            // City names often replace the sponsor title in TV listings.
            for (final v in [
              comp['venue'],
              if (e['venues'] is List) ...(e['venues'] as List),
            ])
              if (v is Map && v['address'] is Map)
                if ((v['address']['city'] ?? '').toString().trim().length >= 4)
                  v['address']['city'].toString().trim(),
          }.toList(),
          session: round.isEmpty ? grouping : round,
          court: (comp['venue'] as Map?)?['court']?.toString(),
          venue: _venueOf(e, comp),
        ),
      ));
    }
  }
  return out;
}

/// A fight card is one ESPN event with a competition per fight. The card
/// shows the main event: the fight whose two names are in the event's name
/// ("UFC Fight Night: Allen vs. Duncan"), else the last one listed.
SportsGame? _parseFightCard(Map<String, dynamic> e, SportsLeague league) {
  final comps = [
    for (final c in (e['competitions'] as List?) ?? const [])
      (c as Map).cast<String, dynamic>()
  ];
  if (comps.isEmpty) return null;
  final name = (e['name'] ?? '').toString();
  final lowerName = name.toLowerCase();
  bool billed(Map<String, dynamic> comp) {
    final fighters = (comp['competitors'] as List?) ?? const [];
    return fighters.length == 2 &&
        fighters.every((f) {
          final full = _athleteName((f as Map).cast<String, dynamic>());
          final parts = full.toLowerCase().split(' ');
          return parts.isNotEmpty && lowerName.contains(parts.last);
        });
  }

  final main = comps.where(billed).lastOrNull ?? comps.last;
  final fighters = _competitorsByOrder(main);
  if (fighters.length != 2) return null;
  final status = (e['status'] ?? main['status']) as Map<String, dynamic>?;
  final liveBout = comps
      .where((c) =>
          _stateOf(c['status'] as Map<String, dynamic>?) == GameState.live)
      .firstOrNull;
  // The headline fight can still be scheduled while the undercard is live.
  // Use an actual live bout, never the wall clock, to repair a pending card.
  final effectiveStatus = _stateOf(status) == GameState.pre && liveBout != null
      ? liveBout['status'] as Map<String, dynamic>?
      : status;
  final mainState = _stateOf(main['status'] as Map<String, dynamic>?);
  SportsTeam fighter(Map<String, dynamic> c) {
    final full = _athleteName(c);
    final records = c['records'] as List?;
    return SportsTeam(
      id: ((c['athlete'] as Map?)?['id'] ?? c['id'] ?? full).toString(),
      name: full,
      shortName: full,
      abbreviation: full
          .split(' ')
          .where((w) => w.isNotEmpty)
          .map((w) => w[0])
          .take(2)
          .join()
          .toUpperCase(),
      logoUrl: _flagOf(c),
      record: (records != null && records.isNotEmpty)
          ? (records.first as Map)['summary']?.toString()
          : null,
      // W / L once the main event is decided (no score in MMA). A draw or
      // no contest has no winner, so no letters.
      score: mainState == GameState.post &&
              fighters.any((f) => f['winner'] == true)
          ? (c['winner'] == true ? 'W' : 'L')
          : null,
    );
  }

  DateTime start =
      DateTime.parse((comps.first['date'] ?? e['date']).toString());
  for (final c in comps) {
    final d = DateTime.tryParse((c['date'] ?? '').toString());
    if (d != null && d.isBefore(start)) start = d;
  }
  final type = main['type'] as Map?;
  final weightClass = (type?['text'] ?? type?['abbreviation'])?.toString();
  return SportsGame(
    id: e['id'].toString(),
    league: league,
    start: start.toUtc(),
    state: _stateOf(effectiveStatus),
    statusText: _statusTextOf(effectiveStatus),
    home: fighter(fighters[0]),
    away: fighter(fighters[1]),
    broadcasts: _broadcastsOf([e, ...comps]),
    scoreboardBroadcasts: _broadcastDetailsOf([e, ...comps]),
    event: SportsEventInfo(
      title: name,
      participantIds: [
        for (final competition in comps)
          for (final fighter
              in (competition['competitors'] as List?) ?? const [])
            if (fighter case {'athlete': {'id': final Object id}}) id.toString()
      ],
      session: weightClass,
      venue: _venueOf(e, null),
    ),
  );
}

SportsGame? _parseEvent(Map<String, dynamic> e, SportsLeague league) {
  final competitions = e['competitions'] as List?;
  if (competitions == null || competitions.isEmpty) return null;
  final comp = competitions.first as Map<String, dynamic>;
  final competitors = (comp['competitors'] as List?) ?? const [];
  SportsTeam? home;
  SportsTeam? away;
  for (final c in competitors) {
    final m = c as Map<String, dynamic>;
    final team = _parseTeam(m);
    if (m['homeAway'] == 'home') {
      home = team;
    } else {
      away = team;
    }
  }
  if (home == null || away == null) return null;

  final status = (comp['status'] ?? e['status']) as Map<String, dynamic>?;
  final state = _stateOf(status);

  final broadcasts = _broadcastsOf([e, comp]);

  return SportsGame(
    id: e['id'].toString(),
    league: league,
    start: DateTime.parse((comp['date'] ?? e['date']).toString()).toUtc(),
    state: state,
    statusText: _statusTextOf(status),
    home: home,
    away: away,
    broadcasts: broadcasts.toList(),
    scoreboardBroadcasts: _broadcastDetailsOf([e, comp]),
    leaders: _scoreboardLeaders(comp, competitors),
    situation: state == GameState.live
        ? _situationOf(comp['situation'], league)
        : null,
  );
}

/// ESPN's "rating" leader repeats another line ("29 PTS").
const _skippedLeaderStats = {'RAT', 'MLB'};

SportsLeader? _leaderOf(Map category, {String? teamId}) {
  final first = (category['leaders'] as List?)?.firstOrNull as Map?;
  final athlete = first?['athlete'] as Map?;
  if (first == null || athlete == null) return null;
  final name = (athlete['shortName'] ?? athlete['displayName'])?.toString();
  final value = first['displayValue']?.toString();
  if (name == null || value == null || value.isEmpty) return null;
  return SportsLeader(
    stat: (category['shortDisplayName'] ??
            category['abbreviation'] ??
            category['displayName'] ??
            '')
        .toString(),
    name: name,
    value: value,
    teamId: ((first['team'] as Map?)?['id'] ??
            (athlete['team'] as Map?)?['id'] ??
            teamId)
        ?.toString(),
    position: (athlete['position'] as Map?)?['abbreviation']?.toString(),
  );
}

/// Football puts one leader per stat on the competition; hockey/basketball/
/// baseball give each team its own — merged here to the better of the two
/// per stat, in ESPN's order.
List<SportsLeader> _scoreboardLeaders(
    Map<String, dynamic> comp, List competitors) {
  final out = <SportsLeader>[];
  for (final c in (comp['leaders'] as List?) ?? const []) {
    final l = _leaderOf(c as Map);
    if (l != null && !_skippedLeaderStats.contains(l.stat)) out.add(l);
  }
  if (out.isNotEmpty) return out;
  final byStat = <String, (SportsLeader, double)>{};
  final order = <String>[];
  for (final t in competitors) {
    final teamId = (((t as Map)['team'] as Map?)?['id'] ?? t['id'])?.toString();
    for (final c in (t['leaders'] as List?) ?? const []) {
      final l = _leaderOf(c as Map, teamId: teamId);
      if (l == null || _skippedLeaderStats.contains(l.stat)) continue;
      final v =
          ((c['leaders'] as List).first['value'] as num?)?.toDouble() ?? 0;
      final had = byStat[l.stat];
      if (had == null) order.add(l.stat);
      if (had == null || v > had.$2) byStat[l.stat] = (l, v);
    }
  }
  return [for (final s in order) byStat[s]!.$1];
}

SportsSituation? _situationOf(Object? raw, SportsLeague league) {
  if (raw is! Map) return null;
  final lastPlay = (raw['lastPlay'] as Map?)?['text']?.toString();
  String? text = raw['downDistanceText']?.toString();
  if (text == null && raw['outs'] != null) {
    // Baseball: "1-2, 2 out · 1st, 3rd".
    bool on(String k) => raw[k] == true || raw[k] is Map;
    final bases = [
      if (on('onFirst')) '1st',
      if (on('onSecond')) '2nd',
      if (on('onThird')) '3rd',
    ];
    text = [
      if (raw['balls'] != null && raw['strikes'] != null)
        '${raw['balls']}-${raw['strikes']}',
      '${raw['outs']} out',
      if (bases.isNotEmpty) bases.join(', '),
    ].join(' · ');
  }
  final possession = raw['possession']?.toString();
  if (text == null && possession == null && lastPlay == null) return null;
  return SportsSituation(
    text: text,
    possessionTeamId: possession,
    redZone: raw['isRedZone'] == true,
    lastPlay: lastPlay,
  );
}

SportsTeam _parseTeam(Map<String, dynamic> c) {
  final t = (c['team'] as Map?)?.cast<String, dynamic>() ?? const {};
  String? record;
  final records = c['records'] as List?;
  if (records != null && records.isNotEmpty) {
    record = (records.first as Map)['summary']?.toString();
  }
  // Team schedules: `record: [{displayValue: "2-1-0, 4 PTS"}]`.
  final schedRecord = c['record'];
  if (record == null && schedRecord is List && schedRecord.isNotEmpty) {
    record = (schedRecord.first as Map)['displayValue']
        ?.toString()
        .split(',')
        .first
        .trim();
  }
  // Scoreboard: "3"; team schedules: {value: 3.0, displayValue: "3"}.
  final rawScore = c['score'];
  final score = rawScore is Map
      ? rawScore['displayValue']?.toString()
      : rawScore?.toString();
  String? logo = t['logo']?.toString();
  final logos = t['logos'];
  if (logo == null && logos is List && logos.isNotEmpty) {
    logo = (logos.first as Map)['href']?.toString();
  }
  final name = (t['displayName'] ?? t['name'] ?? '').toString();
  final shortName = (t['shortDisplayName'] ?? t['name'] ?? name).toString();
  final location = t['location']?.toString();
  // `nickname` is inconsistently a city, mascot or editorial label across
  // ESPN feeds. Retain only the explicit alternate team name here.
  final rawName = t['name'];
  final alias =
      rawName is String && rawName.length <= 120 ? rawName.trim() : '';
  return SportsTeam(
    id: (t['id'] ?? name).toString(),
    name: name,
    shortName: shortName,
    abbreviation: (t['abbreviation'] ?? '').toString(),
    location: location,
    matchingNames: alias.length >= 3 &&
            alias != name.trim() &&
            alias != shortName.trim() &&
            alias != location?.trim()
        ? List.unmodifiable([alias])
        : const [],
    logoUrl: logo,
    color: t['color']?.toString(),
    record: record,
    score: score,
  );
}
