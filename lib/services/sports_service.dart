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

/// The viewer's enabled leagues, or the full catalogue for a new selection.
/// Shared by the Sports tab and the player's side panel.
List<SportsLeague> savedSportsLeagues(StorageService storage) {
  final hiddenGuide = storage.getHiddenGuideLeagues().toSet();
  final all =
      storage.getSportsAllLeagues() || storage.getSportsLeagues() == null;
  final leagues = [
    for (final id
        in all ? kDefaultSportsLeagueIds : storage.getSportsLeagues()!)
      if (sportsLeagueById(id) case final l?)
        if (l.source != 'Channel guide' && l.id != 'rugby.live') l,
    for (final league in kAutomaticSportsLeagues)
      if (!hiddenGuide.contains(league.id)) league,
  ];
  return leagues.isNotEmpty
      ? leagues
      : [for (final id in kDefaultSportsLeagueIds) sportsLeagueById(id)!];
}

/// The favourite league, when it's still one of [savedSportsLeagues] (a
/// disabled league doesn't count).
SportsLeague? favoriteSportsLeague(StorageService storage) {
  final id = storage.getSportsFavoriteLeague();
  if (id == null) return null;
  return savedSportsLeagues(storage).where((l) => l.id == id).firstOrNull;
}

/// Cached scores and schedules from ESPN's site API. Requests are scoped by league and
/// date rather than individual game; freshness depends on whether games are upcoming,
/// live or finished. Keep response adaptation here so UI models remain provider-neutral.
class SportsService {
  SportsService._()
      : _client = http.Client(),
        _clock = DateTime.now,
        requestTimeout = const Duration(seconds: 15);
  @visibleForTesting
  SportsService.withClient(this._client,
      {DateTime Function()? clock,
      this.requestTimeout = const Duration(seconds: 15)})
      : _clock = clock ?? DateTime.now;
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
  DateTime? _rateLimitedUntil;
  final Queue<Completer<void>> _downloadQueue = Queue();
  int _activeDownloads = 0;
  int _networkFailures = 0;

  /// Read-only replay enrichment shares the normal HTTP limit, parser and
  /// day cache. It must never alter the live hub's error/loading state.
  Future<List<SportsGame>> replayGames(SportsLeague league, DateTime day) =>
      _fetch(league, day);

  List<SportsGame> get cachedReplayGames => [
        for (final entry in _cache.values) ...entry.games,
      ];

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
      if (_activeDownloads == 0) _networkFailures = 0;
    }
  }

  Future<http.Response> _getScoreboard(Uri url) async {
    final limited = _rateLimitedUntil;
    if (limited != null && _clock().isBefore(limited)) {
      throw _ScoreFailure('rate limit', limited, 1);
    }
    // Drain a disconnected batch instead of opening hundreds of doomed sockets.
    if (_networkFailures >= 6) {
      throw http.ClientException('Score connection unavailable');
    }
    final abort = Completer<void>();
    try {
      // Abort the actual transport too: Future.timeout alone leaves stalled
      // sockets alive after their slot has been given to the next request.
      final request =
          http.AbortableRequest('GET', url, abortTrigger: abort.future);
      final response = await _client
          .send(request)
          .then(http.Response.fromStream)
          .timeout(requestTimeout, onTimeout: () {
        abort.complete();
        throw TimeoutException('Event feed timed out', requestTimeout);
      });
      _networkFailures = 0;
      if (response.statusCode == 429) {
        final header = response.headers['retry-after'];
        final seconds = int.tryParse(header ?? '');
        final until = seconds != null
            ? _clock().add(Duration(seconds: seconds.clamp(1, 86400)))
            : _retryAfterDate(header) ??
                _clock().add(const Duration(minutes: 1));
        if (_rateLimitedUntil == null || until.isAfter(_rateLimitedUntil!)) {
          _rateLimitedUntil = until;
        }
        throw _ScoreFailure('rate limit', _rateLimitedUntil!, 1,
            response: response);
      }
      return response;
    } on TimeoutException {
      _networkFailures++;
      rethrow;
    } on http.ClientException {
      _networkFailures++;
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
        for (final date in _datesFor(day))
          for (final league in _requestLeagues(leagues))
            if (_failures['${league.id}|${_espnDate(date)}']?.issue
                case final issue?)
              issue,
      ];

  bool _retryDeferred(String key) =>
      _failures[key]?.retryAt.isAfter(_clock()) ?? false;

  /// Scope errors to the requested day/leagues, not whichever other Sports
  /// route or replay lookup happened to finish last.
  String? errorForDay(List<SportsLeague> leagues, DateTime day) {
    final errors = <String, int>{};
    var total = 0, failed = 0;
    for (final date in _datesFor(day)) {
      for (final league in _requestLeagues(leagues)) {
        total++;
        final failure = _failures['${league.id}|${_espnDate(date)}'];
        if (failure == null) continue;
        failed++;
        errors.update(failure.reason, (count) => count + 1, ifAbsent: () => 1);
      }
    }
    if (failed == 0) return null;
    final reasons = errors.keys.join(', ');
    return '$failed of $total event feeds unavailable ($reasons). '
        'Saved events remain available; their scores may be out of date. '
        '${errors.containsKey('rate limit') ? 'Waiting for the source’s retry window.' : 'Automatic retries are spaced out. Refresh to try again now.'}';
  }

  /// Every game of [leagues] that starts on the local calendar day [day],
  /// plus — when [day] is today — games from the day before that are still
  /// live past midnight. ESPN buckets games by US Eastern date, so the days
  /// either side are fetched too (cached) and filtered locally; otherwise a
  /// European viewer would lose every evening NHL game, which falls on the
  /// next local day.
  ///
  /// Never throws: a league that fails keeps its last cached games (or
  /// none), and [lastError] says so.
  List<DateTime> _datesFor(DateTime day) {
    return [
      sportsCalendarDay(day),
      sportsCalendarDay(day, -1),
      sportsCalendarDay(day, 1),
    ];
  }

  /// Synchronous session snapshot: reopening the tab never hides known games
  /// behind a network refresh. Only the requested leagues/day are returned.
  List<SportsLeague> _requestLeagues(List<SportsLeague> leagues) {
    final allRugby = leagues.any((l) => l.id == 'rugby.live');
    return leagues
        .where((l) =>
            l.source == 'ESPN' &&
            (!allRugby ||
                !l.espnPath.startsWith('rugby/') ||
                l.id == 'rugby.live'))
        .toList();
  }

  List<SportsGame> cachedGamesForDay(
          List<SportsLeague> leagues, DateTime day) =>
      _gamesOnDay([
        for (final date in _datesFor(day))
          for (final league in _requestLeagues(leagues))
            if (league.id != 'rugby.live' ||
                _clock().difference(
                        _cache['${league.id}|${_espnDate(date)}']?.fetchedAt ??
                            DateTime(2000)) <
                    const Duration(minutes: 3))
              _cache['${league.id}|${_espnDate(date)}']?.games ?? const [],
      ], day);

  Future<List<SportsGame>> gamesForDay(List<SportsLeague> leagues, DateTime day,
      {void Function(List<SportsGame>)? onProgress,
      bool forceRefresh = false,
      void Function(SportsWorkProgress)? onStatus}) async {
    leagues = _requestLeagues(leagues);
    final dates = _datesFor(day);
    final total = dates.length * leagues.length;
    // A warm visit needs no request queue, timers or hundreds of Futures.
    // In-flight forced refreshes still win over the older cached response.
    if (!forceRefresh &&
        dates.every((date) => leagues.every((league) =>
            !_inFlight.containsKey('${league.id}|${_espnDate(date)}') &&
            (_retryDeferred('${league.id}|${_espnDate(date)}') ||
                (!_failures.containsKey('${league.id}|${_espnDate(date)}') &&
                    _freshEntry(league, date) != null))))) {
      lastError = errorForDay(leagues, day);
      return cachedGamesForDay(leagues, day);
    }
    var completed = 0, failed = 0;
    String? latest;
    Timer? statusTimer;
    void publishStatus() =>
        onStatus?.call(SportsWorkProgress(SportsWorkStage.scores,
            completed: completed,
            total: total,
            detail: latest,
            failed: failed));
    publishStatus();
    Timer? publishTimer;
    var published = cachedGamesForDay(leagues, day);
    void scheduleProgress() {
      if (onProgress == null || publishTimer != null) return;
      // At most two UI updates a second, even with many fast cached replies.
      publishTimer = Timer(const Duration(milliseconds: 400), () {
        publishTimer = null;
        final next = cachedGamesForDay(leagues, day);
        // Empty/cached replies and timezone-neighbour fixtures often leave
        // today's events unchanged. Avoid rebuilding and rematching that same
        // list while the status counters continue updating independently.
        if (listEquals(published, next)) return;
        published = next;
        onProgress(next);
      });
    }

    // Today's date for every league first, then the timezone neighbours.
    // The global six-request cap still protects weak devices.
    try {
      await Future.wait([
        for (final date in dates)
          for (final league in leagues)
            _fetch(league, date, forceRefresh: forceRefresh).then((_) {
              completed++;
              latest = league.shortName;
              if (_failures.containsKey('${league.id}|${_espnDate(date)}')) {
                failed++;
              }
              if (onStatus != null) {
                statusTimer ??= Timer(const Duration(milliseconds: 350), () {
                  statusTimer = null;
                  publishStatus();
                });
              }
              scheduleProgress();
            }),
      ]);
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
        final start = g.start.toLocal();
        final sameDay = g.end == null &&
            start.year == local.year &&
            start.month == local.month &&
            start.day == local.day;
        final carriedOver = local == today &&
            g.state == GameState.live &&
            start.isBefore(local);
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

  static const _standingsBase = 'https://site.api.espn.com/apis/v2/sports';
  final Map<String, (SportsStandings, DateTime)> _standingsCache = {};
  final Map<String, Future<SportsStandings?>> _standingsInFlight = {};

  /// Conference/league tables for [league]. Null when ESPN can't be reached
  /// and nothing is cached. Standings only move when a game ends, so a
  /// 15-minute cache is plenty.
  Future<SportsStandings?> standings(SportsLeague league) {
    if (league.source != 'ESPN') return Future.value(null);
    final cached = _standingsCache[league.id];
    if (cached != null &&
        _clock().difference(cached.$2) < const Duration(minutes: 15)) {
      return Future.value(cached.$1);
    }
    return _standingsInFlight[league.id] ??=
        _downloadStandings(league).whenComplete(() {
      _standingsInFlight.remove(league.id);
    });
  }

  Future<SportsStandings?> _downloadStandings(SportsLeague league) async {
    final url = Uri.parse('$_standingsBase/${league.espnPath}/standings');
    try {
      final response =
          await _client.get(url).timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) {
        throw Exception('HTTP ${response.statusCode}');
      }
      final standings =
          await compute(parseEspnStandings, (response.body, league));
      _standingsCache[league.id] = (standings, _clock());
      return standings;
    } catch (e) {
      debugPrint('SportsService: ${league.id} standings failed: $e');
      return _standingsCache[league.id]?.$1;
    }
  }

  final Map<String, (SportsTeamSchedule, DateTime)> _scheduleCache = {};
  final Map<String, Future<SportsTeamSchedule?>> _scheduleInFlight = {};

  /// [teamId]'s whole season (My Teams): record, standing line and every
  /// game. Null when ESPN can't be reached and nothing is cached. One call
  /// per team (two for soccer: ESPN only returns played games unless asked
  /// for `fixture=true`, which returns only the upcoming ones).
  Future<SportsTeamSchedule?> teamSchedule(SportsLeague league, String teamId) {
    if (league.source != 'ESPN' || teamId.startsWith('tsdb:')) {
      return Future.value(null);
    }
    final key = '${league.id}|$teamId';
    final cached = _scheduleCache[key];
    if (cached != null) {
      final live = cached.$1.games.any((g) => g.state == GameState.live);
      final age = _clock().difference(cached.$2);
      if (age <
          (live ? const Duration(seconds: 50) : const Duration(minutes: 10))) {
        return Future.value(cached.$1);
      }
    }
    return _scheduleInFlight[key] ??=
        _downloadSchedule(league, teamId, key).whenComplete(() {
      _scheduleInFlight.remove(key);
    });
  }

  Future<SportsTeamSchedule?> _downloadSchedule(
      SportsLeague league, String teamId, String key) async {
    final base = '$_base/${league.espnPath}/teams/$teamId/schedule';
    try {
      final responses = await Future.wait([
        _client.get(Uri.parse(base)).timeout(const Duration(seconds: 15)),
        if (league.soccer)
          _client
              .get(Uri.parse('$base?fixture=true'))
              .timeout(const Duration(seconds: 15)),
      ]);
      for (final r in responses) {
        if (r.statusCode != 200) throw Exception('HTTP ${r.statusCode}');
      }
      // A hockey season is ~1 MB of JSON — parsed off the UI isolate.
      final schedule = await compute(
          parseEspnTeamSchedule, ([for (final r in responses) r.body], league));
      if (schedule == null) throw Exception('no team in response');
      _scheduleCache[key] = (schedule, _clock());
      return schedule;
    } catch (e) {
      debugPrint(
          'SportsService: ${league.id} team $teamId schedule failed: $e');
      return _scheduleCache[key]?.$1;
    }
  }

  final Map<String, (SportsGameSummary, DateTime)> _summaryCache = {};
  final Map<String, Future<SportsGameSummary?>> _summaryInFlight = {};

  /// One game's box score, leaders, injuries and its teams' standings (the
  /// live list's detail pop-up). One call per opened game, cached 30 s
  /// while it's live. Null when ESPN can't be reached and nothing is cached.
  Future<SportsGameSummary?> gameSummary(SportsGame game) {
    if (game.source != 'ESPN') return Future.value(null);
    final key = '${game.league.id}|${game.id}';
    final cached = _summaryCache[key];
    if (cached != null &&
        _clock().difference(cached.$2) <
            (game.state == GameState.live
                ? const Duration(seconds: 30)
                : const Duration(minutes: 10))) {
      return Future.value(cached.$1);
    }
    return _summaryInFlight[key] ??= () async {
      final url =
          Uri.parse('$_base/${game.league.espnPath}/summary?event=${game.id}');
      // It's ~40 KB gzipped and answers in well under a second, so a slow
      // try is a stuck connection, not a big download: give up after 6 s
      // and retry once (the Formuler took ~30 s to fill the
      // pop-up with one 15 s try).
      for (var attempt = 1; attempt <= 2; attempt++) {
        final watch = Stopwatch()..start();
        try {
          final response =
              await _client.get(url).timeout(const Duration(seconds: 6));
          if (response.statusCode != 200) {
            throw Exception('HTTP ${response.statusCode}');
          }
          final httpMs = watch.elapsedMilliseconds;
          // ~400 KB of JSON: parsed off the UI isolate.
          final summary = await compute(
              parseEspnSummary, (response.body, game.home.id, game.away.id));
          debugPrint('SportsService: summary ${game.id} try $attempt: '
              'http ${httpMs}ms ${response.bodyBytes.length}B, '
              'parse ${watch.elapsedMilliseconds - httpMs}ms');
          _summaryCache[key] = (summary, _clock());
          return summary;
        } catch (e) {
          debugPrint('SportsService: ${game.league.id} summary ${game.id} '
              'try $attempt after ${watch.elapsedMilliseconds}ms: $e');
        }
      }
      return _summaryCache[key]?.$1;
    }()
        .whenComplete(() {
      // A block, not `=> remove(key)`: remove returns this very future, and
      // whenComplete waits for a returned future — so it waited on itself
      // forever and the pop-up only filled at its 30 s refresh.
      _summaryInFlight.remove(key);
    });
  }

  /// Starts [gameSummary] for a row the user is resting on, so OK opens the
  /// pop-up already filled. Cached/in-flight games cost nothing.
  void prefetchSummary(SportsGame game) => unawaited(gameSummary(game));

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
    final cached = _cache['${league.id}|${_espnDate(date)}'];
    if (cached == null) return null;
    final now = _clock();
    if (now.isBefore(cached.fetchedAt)) return null;
    final fresh = league.id == 'rugby.live'
        ? now.difference(cached.fetchedAt) < const Duration(seconds: 50)
        : !cached.isStale(date, _today(), now);
    return fresh ? cached : null;
  }

  Future<List<SportsGame>> _fetch(SportsLeague league, DateTime date,
      {bool forceRefresh = false}) {
    if (league.source != 'ESPN') return Future.value(const []);
    final key = '${league.id}|${_espnDate(date)}';
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
    final url = Uri.parse(
        '$_base/${league.espnPath}/scoreboard?dates=${_espnDate(date)}${league.id == 'rugby.live' ? '&limit=100' : ''}');
    var acquired = false;
    http.Response? response;
    try {
      await _acquireDownload();
      acquired = true;
      response = await _getScoreboard(url);
      if (response.statusCode != 200) {
        throw Exception('HTTP ${response.statusCode}');
      }
      final body = response.body;
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

class _CacheEntry {
  _CacheEntry(this.games, this.fetchedAt);
  final List<SportsGame> games;
  final DateTime fetchedAt;

  bool isStale(DateTime espnDate, DateTime today, DateTime now) {
    final age = now.difference(fetchedAt);
    final live = games.any((g) => g.state == GameState.live);
    final startsSoon = games.any((g) =>
        g.state == GameState.pre &&
        g.start.difference(now.toUtc()).inMinutes < 30);
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
    return (parseEspnScoreboard(item), null);
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

GameState _stateOf(Map<String, dynamic>? status) =>
    switch ((status?['type'] as Map?)?['state']) {
      'in' => GameState.live,
      'post' => GameState.post,
      _ => GameState.pre,
    };

String _statusTextOf(Map<String, dynamic>? status) {
  final type = status?['type'] as Map?;
  return (type?['shortDetail'] ?? type?['detail'] ?? '').toString();
}

List<String> _broadcastsOf(Iterable<Map<String, dynamic>> comps) {
  final out = <String>{};
  void add(Object? value) {
    if (value is String && value.trim().isNotEmpty) out.add(value.trim());
  }

  for (final comp in comps) {
    for (final key in ['broadcasts', 'geoBroadcasts']) {
      final rows = comp[key];
      if (rows is! List) continue;
      for (final row in rows) {
        if (row is! Map) continue;
        final names = row['names'];
        if (names is List) {
          for (final name in names) {
            add(name);
          }
        }
        final media = row['media'];
        if (media is Map) {
          add(media['shortName'] ?? media['name'] ?? media['displayName']);
        } else {
          add(media);
        }
      }
    }
  }
  return out.toList();
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
    statusText: state == GameState.pre ? '' : _statusTextOf(status),
    home: side,
    away: side,
    broadcasts: _broadcastsOf([comp]),
    event: SportsEventInfo(
      title: title,
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
      event: SportsEventInfo(
        title: title,
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
    event: SportsEventInfo(
      title: name,
      session: weightClass,
      venue: _venueOf(e, null),
    ),
  );
}

/// Top-level so [compute] can run it on a background isolate. [bodies] are
/// the team schedule responses (soccer: results + fixtures); events are
/// merged by id and sorted oldest first. Null when there's no team.
@visibleForTesting
SportsTeamSchedule? parseEspnTeamSchedule((List<String>, SportsLeague) args) {
  final (bodies, league) = args;
  Map<String, dynamic>? teamJson;
  final byId = <String, SportsGame>{};
  for (final body in bodies) {
    final json = jsonDecode(body);
    if (json is! Map<String, dynamic>) continue;
    teamJson ??= (json['team'] as Map?)?.cast<String, dynamic>();
    for (final e in (json['events'] as List?) ?? const []) {
      try {
        final game = _parseEvent(e as Map<String, dynamic>, league);
        if (game != null) byId[game.id] = game;
      } catch (_) {
        // One malformed event shouldn't drop the season.
      }
    }
  }
  if (teamJson == null || teamJson['id'] == null) return null;
  final t = teamJson;
  final name = (t['displayName'] ?? t['name'] ?? '').toString();
  final team = SportsTeam(
    id: t['id'].toString(),
    name: name,
    shortName: (t['shortDisplayName'] ?? t['name'] ?? name).toString(),
    abbreviation: (t['abbreviation'] ?? '').toString(),
    location: t['location']?.toString(),
    logoUrl: t['logo']?.toString(),
    color: t['color']?.toString(),
    record: t['recordSummary']?.toString(),
  );
  // Schedule events leave out team colours; give the followed team its own
  // so the cards and glow match the rest of the tab.
  SportsTeam withColor(SportsTeam s) => s.id != team.id || s.color != null
      ? s
      : SportsTeam(
          id: s.id,
          name: s.name,
          shortName: s.shortName,
          abbreviation: s.abbreviation,
          location: s.location,
          logoUrl: s.logoUrl,
          color: team.color,
          record: s.record,
          score: s.score,
        );
  final games = [
    for (final g in byId.values)
      SportsGame(
        id: g.id,
        league: g.league,
        start: g.start,
        state: g.state,
        statusText: g.statusText,
        home: withColor(g.home),
        away: withColor(g.away),
        broadcasts: g.broadcasts,
      ),
  ]..sort((a, b) => a.start.compareTo(b.start));
  return SportsTeamSchedule(
    league: league,
    team: team,
    games: games,
    standingSummary: t['standingSummary']?.toString(),
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
  final type = status?['type'] as Map<String, dynamic>?;
  final state = switch (type?['state']) {
    'in' => GameState.live,
    'post' => GameState.post,
    _ => GameState.pre,
  };

  final broadcasts = _broadcastsOf([e, comp]);

  return SportsGame(
    id: e['id'].toString(),
    league: league,
    start: DateTime.parse((comp['date'] ?? e['date']).toString()).toUtc(),
    state: state,
    statusText: (type?['shortDetail'] ?? type?['detail'] ?? '').toString(),
    home: home,
    away: away,
    broadcasts: broadcasts.toList(),
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

/// Box-score columns worth a glance, per category, in display order; a
/// category whose labels hit none of them is left out (returns, punting).
const List<List<String>> _boxColumns = [
  ['C/ATT', 'YDS', 'TD', 'INT'], // passing
  ['CAR', 'YDS', 'TD'], // rushing
  ['REC', 'TGTS', 'YDS', 'TD'], // receiving
  ['TOT', 'SACKS', 'TFL'], // defensive
  ['FG', 'XP', 'PTS'], // kicking
  ['MIN', 'PTS', 'REB', 'AST', '3PT', 'STL', 'BLK'], // basketball
  ['G', 'A', 'S', '+/-', 'TOI'], // hockey skaters (S = shots)
  ['SA', 'SV', 'SV%', 'GA'], // goalies
  ['H-AB', 'R', 'HR', 'RBI', 'BB', 'K'], // batting
  ['IP', 'H', 'ER', 'BB', 'K', 'PC'], // pitching
];

const _boxCategories = {
  'passing',
  'rushing',
  'receiving',
  'defensive',
  'kicking',
  'forwards',
  'defenses',
  'goalies',
};

/// Top-level so [compute] can run it on a background isolate.
@visibleForTesting
SportsGameSummary parseEspnSummary((String, String, String) args) {
  final (body, homeId, awayId) = args;
  final json = jsonDecode(body);
  if (json is! Map<String, dynamic>) return const SportsGameSummary();
  final box = json['boxscore'] as Map?;

  // Team stats, away | home.
  final teamStats = <(String, String, String)>[];
  final boxTeams = [
    for (final t in (box?['teams'] as List?) ?? const []) t as Map
  ];
  Map? statsOf(String id) => boxTeams
      .where((t) => (t['team'] as Map?)?['id']?.toString() == id)
      .firstOrNull;
  final away = statsOf(awayId);
  final home = statsOf(homeId);
  if (away != null && home != null) {
    final homeByName = {
      for (final s in (home['statistics'] as List?) ?? const [])
        (s as Map)['name']: s['displayValue']?.toString(),
    };
    for (final s in (away['statistics'] as List?) ?? const []) {
      final m = s as Map;
      final label = (m['label'] ?? m['abbreviation'])?.toString();
      final a = m['displayValue']?.toString();
      final h = homeByName[m['name']];
      if (label == null || a == null || h == null) continue;
      teamStats.add((label, a, h));
    }
  }

  // Box score: per team, a few columns of the top players per category.
  final players = <String, List<SportsPlayerGroup>>{};
  for (final t in (box?['players'] as List?) ?? const []) {
    final teamId = ((t as Map)['team'] as Map?)?['id']?.toString();
    if (teamId == null) continue;
    final groups = <SportsPlayerGroup>[];
    for (final c in (t['statistics'] as List?) ?? const []) {
      final cat = c as Map;
      final labels = [
        for (final l in (cat['labels'] as List?) ?? const []) '$l'
      ];
      final name = cat['name']?.toString();
      final title = name ??
          (labels.contains('IP')
              ? 'pitching'
              : labels.contains('AB')
                  ? 'batting'
                  : 'players');
      if (name != null && !_boxCategories.contains(name)) continue;
      // The column set this category matches best (rushing also has
      // passing's YDS/TD — the first set with two hits dropped CAR).
      List<String>? wanted;
      for (final cols in _boxColumns) {
        final hit = [
          for (final x in cols)
            if (labels.contains(x)) x
        ];
        if (hit.length >= 2 && hit.length > (wanted?.length ?? 0)) {
          wanted = hit;
        }
      }
      if (wanted == null) continue;
      final idx = [for (final x in wanted) labels.indexOf(x)];
      double num0(List s, String label) {
        final i = labels.indexOf(label);
        if (i < 0 || i >= s.length) return 0;
        final v = '${s[i]}'.split(RegExp(r'[-/]')).first;
        return double.tryParse(v) ?? 0;
      }

      double rank(List s) {
        if (labels.contains('G') && labels.contains('A')) {
          return num0(s, 'G') + num0(s, 'A') + num0(s, 'S') / 100;
        }
        for (final k in ['PTS', 'YDS', 'TOT']) {
          if (labels.contains(k)) return num0(s, k);
        }
        if (labels.contains('H-AB')) {
          return num0(s, 'H-AB') + num0(s, 'RBI') + num0(s, 'R') / 2;
        }
        return 0; // pitchers / goalies: ESPN's order (starter first)
      }

      final rows = <(String, List<String>, double)>[];
      for (final a in (cat['athletes'] as List?) ?? const []) {
        final m = a as Map;
        final stats = (m['stats'] as List?) ?? const [];
        if (stats.isEmpty) continue; // DNP
        final ath = m['athlete'] as Map? ?? const {};
        final n = (ath['shortName'] ?? ath['displayName'])?.toString();
        if (n == null) continue;
        rows.add((
          n,
          [for (final i in idx) i < stats.length ? '${stats[i]}' : ''],
          rank(stats)
        ));
      }
      if (rows.isEmpty) continue;
      // Stable: equal ranks keep ESPN's order.
      final indexed = rows.indexed.toList()
        ..sort((x, y) {
          final r = y.$2.$3.compareTo(x.$2.$3);
          return r != 0 ? r : x.$1.compareTo(y.$1);
        });
      final take = switch (title) {
        'players' => 5,
        'passing' || 'kicking' || 'goalies' || 'pitching' => 2,
        _ => 3,
      };
      groups.add(SportsPlayerGroup(
        title: title,
        labels: wanted,
        rows: [for (final r in indexed.take(take)) (r.$2.$1, r.$2.$2)],
      ));
    }
    if (groups.isNotEmpty) players[teamId] = groups;
  }

  // Leaders per team.
  final leaders = <String, List<SportsLeader>>{};
  for (final t in (json['leaders'] as List?) ?? const []) {
    final teamId = ((t as Map)['team'] as Map?)?['id']?.toString();
    if (teamId == null) continue;
    final list = <SportsLeader>[];
    for (final c in (t['leaders'] as List?) ?? const []) {
      final cat = c as Map;
      final l = _leaderOf(cat, teamId: teamId);
      if (l == null) continue;
      list.add(SportsLeader(
          stat: (cat['displayName'] ?? l.stat).toString(),
          name: l.name,
          value: l.value,
          teamId: teamId,
          position: l.position));
    }
    if (list.isNotEmpty) leaders[teamId] = list;
  }

  // Injuries per team (football/basketball list them before and during).
  final injuries = <String, List<SportsInjury>>{};
  for (final t in (json['injuries'] as List?) ?? const []) {
    final teamId = ((t as Map)['team'] as Map?)?['id']?.toString();
    if (teamId == null) continue;
    final list = <SportsInjury>[];
    for (final i in (t['injuries'] as List?) ?? const []) {
      final m = i as Map;
      final ath = m['athlete'] as Map? ?? const {};
      final n = (ath['shortName'] ?? ath['displayName'])?.toString();
      final status = m['status']?.toString();
      if (n == null || status == null) continue;
      list.add(SportsInjury(
        name: n,
        status: status,
        position: (ath['position'] as Map?)?['abbreviation']?.toString(),
        detail: (m['details'] as Map?)?['type']?.toString(),
      ));
    }
    if (list.isNotEmpty) injuries[teamId] = list;
  }

  // Soccer scorers.
  final goals = <SportsGoal>[];
  for (final k in (json['keyEvents'] as List?) ?? const []) {
    final m = k as Map;
    if (m['scoringPlay'] != true) continue;
    final who = (((m['participants'] as List?)?.firstOrNull as Map?)?['athlete']
            as Map?)?['displayName']
        ?.toString();
    if (who == null) continue;
    final type = ((m['type'] as Map?)?['text'] ?? '').toString().toLowerCase();
    goals.add(SportsGoal(
      minute: ((m['clock'] as Map?)?['displayValue'] ?? '').toString(),
      scorer: who,
      teamId: (m['team'] as Map?)?['id']?.toString(),
      penalty: type.contains('penalty'),
    ));
  }

  // Hockey goal details come from Goal-typed plays when keyEvents is absent. Other sports'
  // scoring plays have different meanings.
  if (goals.isEmpty) {
    for (final p in (json['plays'] as List?) ?? const []) {
      final m = p as Map;
      if (m['scoringPlay'] != true) continue;
      final type = m['type'] as Map?;
      final kind = (type?['abbreviation'] ?? type?['text'] ?? '')
          .toString()
          .toLowerCase();
      if (kind != 'goal') continue;
      String? scorer;
      final assists = <String>[];
      for (final x in (m['participants'] as List?) ?? const []) {
        final part = x as Map;
        final ath = part['athlete'] as Map? ?? const {};
        final n = (ath['shortName'] ?? ath['displayName'])?.toString();
        if (n == null) continue;
        if (part['type'] == 'scorer') {
          scorer = n;
        } else if (part['type'] == 'assister') {
          assists.add(n);
        }
      }
      if (scorer == null) continue;
      final away = m['awayScore'], home = m['homeScore'];
      goals.add(SportsGoal(
        minute: ((m['clock'] as Map?)?['displayValue'] ?? '').toString(),
        scorer: scorer,
        teamId: (m['team'] as Map?)?['id']?.toString(),
        period: (m['period'] as Map?)?['displayValue']?.toString(),
        assists: assists,
        score: away is num && home is num ? '$away-$home' : null,
      ));
    }
  }

  // Standings groups that hold either team: a few columns, wins first.
  const preferred = [
    'overall', 'Total', 'W', 'D', 'L', 'T', 'OTL', 'P', 'PTS', 'PCT', 'GB', //
    'GD', 'CONF', 'STRK',
  ];
  final tables = <SportsSummaryTable>[];
  final groupsJson =
      ((json['standings'] as Map?)?['groups'] as List?) ?? const [];
  for (final g in groupsJson) {
    final gm = g as Map;
    final entries =
        ((gm['standings'] as Map?)?['entries'] as List?) ?? const [];
    final ids = [
      for (final e in entries) ((e as Map)['id'] ?? '').toString(),
    ];
    if (!ids.contains(homeId) && !ids.contains(awayId)) continue;
    final first = entries.isEmpty ? null : entries.first as Map;
    final stats = [
      for (final s in (first?['stats'] as List?) ?? const []) s as Map
    ];
    final cols = [
      for (final p in preferred)
        if (stats.any((s) => s['abbreviation'] == p)) p,
    ].take(5).toList();
    String header(String abbr) {
      final s = stats.firstWhere((s) => s['abbreviation'] == abbr);
      return (s['shortDisplayName'] ?? abbr).toString();
    }

    tables.add(SportsSummaryTable(
      title: (gm['header'] ?? '')
          .toString()
          .replaceFirst(RegExp(r'^\d{4}(-\d{2})?\s+'), '')
          .replaceFirst(RegExp(r'\s+Standings$'), ''),
      labels: [for (final c in cols) header(c)],
      rows: [
        for (final e in entries)
          (
            ((e as Map)['id'] ?? '').toString(),
            (e['team'] ?? '').toString(),
            [
              for (final c in cols)
                ((e['stats'] as List?)
                            ?.cast<Map>()
                            .where((s) => s['abbreviation'] == c)
                            .firstOrNull?['displayValue'] ??
                        '')
                    .toString(),
            ],
          ),
      ],
    ));
  }

  return SportsGameSummary(
    teamStats: teamStats,
    players: players,
    leaders: leaders,
    injuries: injuries,
    goals: goals,
    tables: tables,
  );
}

/// Top-level so [compute] can run it on a background isolate. ESPN nests
/// groups (college conferences hold divisions); every node that carries
/// `standings.entries` becomes one table, in ESPN's order.
@visibleForTesting
SportsStandings parseEspnStandings((String, SportsLeague) args) {
  final (body, league) = args;
  final json = jsonDecode(body);
  final groups = <SportsStandingGroup>[];
  var preseason = false;
  String? season;

  void walk(Map<String, dynamic> node) {
    final standings = node['standings'];
    if (standings is Map && standings['entries'] is List) {
      // Soccer tables always say seasonType 1; only the US leagues use it
      // for exhibition games.
      if (!league.soccer && standings['seasonType'] == 1) preseason = true;
      // The table's own season ("2026" for a finished MLB year — the
      // top-level `season` already says 2027); soccer appends the league
      // name ("2026-27 English Premier League"), keep just the years.
      season ??= RegExp(r'^\d{4}(-\d{2})?')
          .firstMatch(standings['seasonDisplayName']?.toString() ?? '')
          ?.group(0);
      final rows = <SportsStandingRow>[];
      for (final e in standings['entries'] as List) {
        try {
          rows.add(_parseStandingRow(e as Map<String, dynamic>));
        } catch (_) {
          // Skip a malformed team rather than the whole table.
        }
      }
      if (rows.isNotEmpty) {
        groups.add(SportsStandingGroup(
          // "2026-27 English Premier League" → "English Premier League";
          // the season is shown on its own.
          name: (node['name'] ?? league.name)
              .toString()
              .replaceFirst(RegExp(r'^\d{4}(-\d{2})?\s+'), ''),
          rows: _sortStandings(rows, league),
        ));
      }
    }
    for (final c in (node['children'] as List?) ?? const []) {
      if (c is Map<String, dynamic>) walk(c);
    }
  }

  if (json is Map<String, dynamic>) walk(json);
  return SportsStandings(
    league: league,
    groups: groups,
    season: season,
    preseason: preseason,
  );
}

SportsStandingRow _parseStandingRow(Map<String, dynamic> e) {
  // Racing's driver table lists athletes (with a flag) instead of teams.
  final t = ((e['team'] ?? e['athlete']) as Map).cast<String, dynamic>();
  final logos = t['logos'] as List? ??
      [if (t['flag'] is Map) t['flag']]; // href, same shape as a logo
  final name = (t['displayName'] ?? t['name'] ?? '').toString();
  final stats = <String, String>{};
  for (final s in (e['stats'] as List?) ?? const []) {
    final m = s as Map;
    final key = (m['name'] ?? m['type'])?.toString();
    if (key == null) continue;
    // College football repeats the whole set per split (overall, home,
    // away); the first one is the overall line.
    var value = (m['displayValue'] ?? m['summary'] ?? '').toString();
    // NHL's last-ten reads "6-1-1, 0" (a trailing shootout count).
    if (key == 'Last Ten Games') value = value.split(',').first.trim();
    stats.putIfAbsent(key, () => value);
  }
  // Racing: drivers have `championshipPts`, F1 constructors `points` — one
  // column reads both.
  if (stats['points'] != null) {
    stats.putIfAbsent('championshipPts', () => stats['points']!);
  }
  final note = e['note'] as Map?;
  return SportsStandingRow(
    team: SportsTeam(
      id: (t['id'] ?? name).toString(),
      name: name,
      shortName: (t['shortDisplayName'] ?? t['name'] ?? name).toString(),
      abbreviation: (t['abbreviation'] ?? '').toString(),
      location: t['location']?.toString(),
      logoUrl:
          logos.isNotEmpty ? (logos.first as Map)['href']?.toString() : null,
      color: t['color']?.toString(),
    ),
    position: 0,
    stats: stats,
    // replaceAll: ESPN has sent "##B5E7CE" (Europa League).
    noteColor: note?['color']?.toString().replaceAll('#', ''),
    note: note?['description']?.toString(),
  );
}

/// ESPN's entries are not in table order (NBA/MLB come alphabetical-ish).
/// Soccer has a `rank`; the others a `playoffSeed`, which is 0 for everyone
/// before a season starts — then wins/points decide.
List<SportsStandingRow> _sortStandings(
    List<SportsStandingRow> rows, SportsLeague league) {
  double num(SportsStandingRow r, String k) =>
      double.tryParse(r.stat(k).replaceAll('+', '')) ?? 0;
  final key = league.soccer || league.kind == SportsKind.racing
      ? 'rank'
      : 'playoffSeed';
  final ranked = rows.every((r) => num(r, key) > 0);
  final sorted = [...rows];
  sorted.sort((a, b) {
    if (ranked) return num(a, key).compareTo(num(b, key));
    final byPoints = num(b, 'points').compareTo(num(a, 'points'));
    if (league.espnPath.startsWith('hockey') && byPoints != 0) return byPoints;
    final byPct = num(b, 'winPercent').compareTo(num(a, 'winPercent'));
    return byPct != 0 ? byPct : num(b, 'wins').compareTo(num(a, 'wins'));
  });
  return [
    for (var i = 0; i < sorted.length; i++)
      SportsStandingRow(
        team: sorted[i].team,
        position: i + 1,
        stats: sorted[i].stats,
        noteColor: sorted[i].noteColor,
        note: sorted[i].note,
      ),
  ];
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
  return SportsTeam(
    id: (t['id'] ?? name).toString(),
    name: name,
    shortName: (t['shortDisplayName'] ?? t['name'] ?? name).toString(),
    abbreviation: (t['abbreviation'] ?? '').toString(),
    location: t['location']?.toString(),
    logoUrl: logo,
    color: t['color']?.toString(),
    record: record,
    score: score,
  );
}
