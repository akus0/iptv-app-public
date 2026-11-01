import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/archive_models.dart';

/// Register independent public OAuth clients before enabling these integrations.
/// Client IDs are public build settings, not account credentials.
const String kTraktClientId = String.fromEnvironment('TRAKT_CLIENT_ID');
const String kSimklClientId = String.fromEnvironment('SIMKL_CLIENT_ID');
const String kTraktRedirectUri = String.fromEnvironment('TRAKT_REDIRECT_URI');

/// The device sign-in did not finish: code expired, denied, or used.
class TrackerAuthException implements Exception {
  TrackerAuthException(this.reason);
  final String reason;
  @override
  String toString() => 'TrackerAuthException: $reason';
}

/// What the TV shows while the viewer signs in on their phone: "go to
/// [verificationUrl] and enter [userCode]".
class TrackerDeviceCode {
  const TrackerDeviceCode({
    required this.kind,
    required this.userCode,
    required this.verificationUrl,
    required this.deviceCode,
    required this.expiresIn,
    required this.interval,
    this.qrUrl,
  });

  final TrackerKind kind;
  final String userCode;
  final String verificationUrl;
  final String deviceCode;
  final Duration expiresIn;
  final Duration interval;

  /// The page with the code already filled in, when the service offers
  /// one (Simkl) — the QR code opens it; else [verificationUrl].
  final String? qrUrl;
}

/// A play reported to Trakt/Simkl: a movie, or an episode of a show, by
/// IMDb id (Media Hub) and/or TMDB id (IPTV titles from the provider).
class TrackedItem {
  const TrackedItem.movie(this.imdb, {this.tmdb})
      : season = null,
        episode = null;
  const TrackedItem.episode(this.imdb,
      {this.tmdb, required int this.season, required int this.episode});

  /// The movie's or the show's IMDb id.
  final String? imdb;

  /// The movie's or the show's TMDB id.
  final String? tmdb;
  final int? season;
  final int? episode;

  bool get isEpisode => season != null;
  bool get hasIds => imdb != null || tmdb != null;

  Map<String, dynamic> get ids => {
        if (imdb != null) 'imdb': imdb,
        if (tmdb != null) 'tmdb': int.tryParse(tmdb!) ?? tmdb,
      };

  /// The body both services' scrobble endpoints take (Simkl copied
  /// Trakt's format).
  Map<String, dynamic> toBody() => isEpisode
      ? {
          'show': {'ids': ids},
          'episode': {'season': season, 'number': episode},
        }
      : {
          'movie': {'ids': ids}
        };

  /// The `/sync/history` (and `/remove`) body for this one item.
  Map<String, dynamic> toHistoryBody() => isEpisode
      ? {
          'shows': [
            {
              'ids': ids,
              'seasons': [
                {
                  'number': season,
                  'episodes': [
                    {'number': episode}
                  ],
                }
              ],
            }
          ]
        }
      : {
          'movies': [
            {'ids': ids}
          ]
        };
}

/// A movie or episode paused part-way on a tracker (Trakt `/sync/playback`,
/// Simkl the same): the Media Hub's "Continue watching" and resume points.
class PausedItem {
  const PausedItem({
    required this.type,
    required this.title,
    required this.progress,
    required this.pausedAt,
    this.imdb,
    this.tmdb,
    this.year,
    this.season,
    this.episode,
  });

  /// [ArchiveType.movie], or [ArchiveType.series] for an episode ([title]
  /// and the ids are then the show's).
  final ArchiveType type;
  final String title;

  /// Percent, 0-100.
  final double progress;
  final DateTime pausedAt;
  final String? imdb;
  final String? tmdb;
  final String? year;
  final int? season;
  final int? episode;
}

/// What an account has watched: episodes per show and movies, each keyed
/// by `imdb:tt…` / `tmdb:123` ([TrackerHistory.keys]), plus [paused].
class TrackerHistory {
  TrackerHistory({
    Map<String, Set<String>>? episodes,
    Set<String>? movies,
    List<PausedItem>? paused,
  })  : episodes = episodes ?? {},
        movies = movies ?? {},
        paused = paused ?? [];

  /// Show key -> watched episodes as `season:number`.
  final Map<String, Set<String>> episodes;
  final Set<String> movies;
  final List<PausedItem> paused;

  static List<String> keys({String? imdb, String? tmdb}) => [
        if (imdb != null && imdb.isNotEmpty) 'imdb:$imdb',
        if (tmdb != null && tmdb.isNotEmpty && tmdb != '0') 'tmdb:$tmdb',
      ];

  static List<String> _keysOf(Object? ids) => ids is Map
      ? keys(imdb: ids['imdb']?.toString(), tmdb: ids['tmdb']?.toString())
      : const [];

  /// [other] added in (several accounts: watched anywhere counts; a pause
  /// on both keeps the newer one).
  void merge(TrackerHistory other) {
    other.episodes
        .forEach((k, v) => episodes.putIfAbsent(k, () => <String>{}).addAll(v));
    movies.addAll(other.movies);
    paused.addAll(other.paused);
    paused.sort((a, b) => b.pausedAt.compareTo(a.pausedAt));
    final seen = <String>{};
    paused.retainWhere((p) => seen.add(
        '${p.type.wire}|${p.imdb ?? p.tmdb ?? p.title}|${p.season}:${p.episode}'));
  }

  bool episodeWatched(List<String> showKeys, int season, int episode) =>
      showKeys.any((k) => episodes[k]?.contains('$season:$episode') ?? false);

  bool movieWatched(List<String> keys) => keys.any(movies.contains);

  PausedItem? pausedEpisode(List<String> showKeys, int season, int episode) =>
      paused
          .where((p) =>
              p.type == ArchiveType.series &&
              p.season == season &&
              p.episode == episode &&
              keys(imdb: p.imdb, tmdb: p.tmdb).any(showKeys.contains))
          .firstOrNull;

  PausedItem? pausedMovie(List<String> movieKeys) => paused
      .where((p) =>
          p.type == ArchiveType.movie &&
          keys(imdb: p.imdb, tmdb: p.tmdb).any(movieKeys.contains))
      .firstOrNull;
}

/// Plain HTTP client for Trakt and Simkl, mapped onto the Media Hub: sign in
/// with a code on the TV (device flow — nothing to type on the remote but
/// the viewer's phone), their lists as catalogs (posters by IMDb id from
/// Stremio's public image service, like [ArchiveCatalogProvider]'s rows),
/// and scrobbling. No state: the login lives on the [ArchiveSource].
class TrackerApi {
  TrackerApi({
    http.Client? client,
    String traktClientId = kTraktClientId,
    String simklClientId = kSimklClientId,
    String traktRedirectUri = kTraktRedirectUri,
  })  : _client = client ?? http.Client(),
        _traktClientId = traktClientId,
        _simklClientId = simklClientId,
        _traktRedirectUri = traktRedirectUri;

  final String _traktClientId;
  final String _simklClientId;
  final String _traktRedirectUri;

  final http.Client _client;
  static const _timeout = Duration(seconds: 20);
  static const _trakt = 'https://api.trakt.tv';
  static const _simkl = 'https://api.simkl.com';
  static const _pageSize = 100;

  static String clientId(TrackerKind k) =>
      k == TrackerKind.trakt ? kTraktClientId : kSimklClientId;

  static bool isConfigured(TrackerKind k) => clientId(k).isNotEmpty;

  Map<String, String> _headers(TrackerKind k, [String? token]) => {
        'Content-Type': 'application/json',
        if (k == TrackerKind.trakt) ...{
          'trakt-api-version': '2',
          'trakt-api-key': _traktClientId,
        } else ...{
          'simkl-api-key': _simklClientId,
          'app-name': 'iptv-app',
          'app-version': '1',
          'User-Agent': 'iptv-app',
        },
        if (token != null) 'Authorization': 'Bearer $token',
      };

  Object? _decode(http.Response r) {
    if (r.body.isEmpty) return null;
    try {
      return jsonDecode(utf8.decode(r.bodyBytes));
    } catch (_) {
      return null;
    }
  }

  // ---- sign-in ------------------------------------------------------------

  /// Starts a device sign-in: the code to show on the TV.
  Future<TrackerDeviceCode> startSignIn(TrackerKind k) async {
    final http.Response r;
    if (k == TrackerKind.trakt) {
      r = await _client
          .post(Uri.parse('$_trakt/oauth/device/code'),
              headers: _headers(k),
              body: jsonEncode({'client_id': _traktClientId}))
          .timeout(_timeout);
    } else {
      // Simkl AUTH V2 device flow (RFC 8628). Write scope: scrobbling.
      r = await _client
          .post(Uri.parse('$_simkl/oauth2/device'),
              headers: _headers(k),
              body: jsonEncode({
                'client_id': _simklClientId,
                'scope': 'media:read media:write',
              }))
          .timeout(_timeout);
    }
    final j = _decode(r);
    if (r.statusCode != 200 || j is! Map || j['user_code'] == null) {
      throw TrackerAuthException('start ${r.statusCode}');
    }
    final page = j['verification_url'] ?? j['verification_uri'];
    return TrackerDeviceCode(
      kind: k,
      userCode: '${j['user_code']}',
      verificationUrl:
          '${page ?? (k == TrackerKind.trakt ? 'https://auth.trakt.tv/activate' : 'https://simkl.com/pin')}',
      // Simkl: the page with the code filled in — what the QR code opens.
      qrUrl: j['verification_uri_complete']?.toString(),
      deviceCode: '${j['device_code']}',
      expiresIn: Duration(seconds: (j['expires_in'] as num?)?.toInt() ?? 600),
      interval: Duration(seconds: (j['interval'] as num?)?.toInt() ?? 5),
    );
  }

  /// One poll of a running sign-in: the login once approved, null while
  /// it's still pending. Throws [TrackerAuthException] when it can't finish.
  Future<TrackerLogin?> pollSignIn(TrackerDeviceCode code) async {
    final trakt = code.kind == TrackerKind.trakt;
    final r = await _client
        .post(
            Uri.parse(
                trakt ? '$_trakt/oauth/device/token' : '$_simkl/oauth2/token'),
            headers: _headers(code.kind),
            body: jsonEncode(trakt
                ? {'code': code.deviceCode, 'client_id': _traktClientId}
                : {
                    'grant_type':
                        'urn:ietf:params:oauth:grant-type:device_code',
                    'device_code': code.deviceCode,
                    'client_id': _simklClientId,
                  }))
        .timeout(_timeout);
    final j = _decode(r);
    if (r.statusCode == 200 && j is Map && j['access_token'] != null) {
      return _withUser(_login(code.kind, Map<String, dynamic>.from(j)));
    }
    // Trakt: 400 pending, 429 slow down (404/409/410/418 = never). Simkl:
    // 400 with authorization_pending / slow_down (expired_token = never).
    if (trakt && (r.statusCode == 400 || r.statusCode == 429)) return null;
    final error = j is Map ? j['error']?.toString() : null;
    if (!trakt && (error == 'authorization_pending' || error == 'slow_down')) {
      return null;
    }
    throw TrackerAuthException('${code.kind.name} ${r.statusCode} $error');
  }

  /// A token response as a login. Both services' tokens expire (Trakt: a
  /// day or more, Simkl V2: 7 days) and refresh with the client id alone.
  TrackerLogin _login(TrackerKind kind, Map<String, dynamic> j) {
    final created = (j['created_at'] as num?)?.toInt() ??
        DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final expiresIn = (j['expires_in'] as num?)?.toInt() ??
        (kind == TrackerKind.trakt ? 86400 : 604800);
    return TrackerLogin(
      kind: kind,
      accessToken: '${j['access_token']}',
      refreshToken: j['refresh_token']?.toString(),
      expiresAtMs: (created + expiresIn) * 1000,
    );
  }

  /// Adds the account's display name (best effort; the login works without).
  Future<TrackerLogin> _withUser(TrackerLogin login) async {
    try {
      final base = login.kind == TrackerKind.trakt ? _trakt : _simkl;
      final r = await _client
          .get(Uri.parse('$base/users/settings'),
              headers: _headers(login.kind, login.accessToken))
          .timeout(_timeout);
      final j = _decode(r);
      final user = j is Map ? j['user'] : null;
      final name =
          user is Map ? (user['username'] ?? user['name'])?.toString() : null;
      if (name == null || name.isEmpty) return login;
      return TrackerLogin(
        kind: login.kind,
        accessToken: login.accessToken,
        refreshToken: login.refreshToken,
        expiresAtMs: login.expiresAtMs,
        userName: name,
      );
    } catch (_) {
      return login;
    }
  }

  /// A fresh token ([login] as is when it has no refresh token — a Simkl
  /// AUTH V1 login never expires).
  Future<TrackerLogin> refresh(TrackerLogin login) async {
    if (login.refreshToken == null) return login;
    final trakt = login.kind == TrackerKind.trakt;
    final r = await _client
        .post(Uri.parse(trakt ? '$_trakt/oauth/token' : '$_simkl/oauth2/token'),
            headers: _headers(login.kind),
            body: jsonEncode({
              'refresh_token': login.refreshToken,
              'client_id': trakt ? _traktClientId : _simklClientId,
              'grant_type': 'refresh_token',
              if (trakt) 'redirect_uri': _traktRedirectUri,
            }))
        .timeout(_timeout);
    final j = _decode(r);
    if (r.statusCode != 200 || j is! Map || j['access_token'] == null) {
      throw TrackerAuthException('refresh ${r.statusCode}');
    }
    final fresh = _login(login.kind, Map<String, dynamic>.from(j));
    return TrackerLogin(
      kind: fresh.kind,
      accessToken: fresh.accessToken,
      // Simkl keeps the same refresh token (window extended).
      refreshToken: fresh.refreshToken ?? login.refreshToken,
      expiresAtMs: fresh.expiresAtMs,
      userName: login.userName,
    );
  }

  // ---- lists as Media Hub rows --------------------------------------------

  /// The rows an account gets. Ids are `{tracker}.{list}`; names are
  /// translated where they're shown.
  static List<ArchiveCatalog> catalogsFor(TrackerKind k) => switch (k) {
        TrackerKind.trakt => const [
            ArchiveCatalog(
                type: ArchiveType.movie,
                id: 'trakt.playback',
                name: 'Continue watching on Trakt'),
            ArchiveCatalog(
                type: ArchiveType.series,
                id: 'trakt.playback',
                name: 'Continue watching on Trakt'),
            ArchiveCatalog(
                type: ArchiveType.movie,
                id: 'trakt.watchlist',
                name: 'Trakt watchlist'),
            ArchiveCatalog(
                type: ArchiveType.series,
                id: 'trakt.watchlist',
                name: 'Trakt watchlist'),
            ArchiveCatalog(
                type: ArchiveType.movie,
                id: 'trakt.trending',
                name: 'Trending on Trakt'),
            ArchiveCatalog(
                type: ArchiveType.series,
                id: 'trakt.trending',
                name: 'Trending on Trakt'),
          ],
        TrackerKind.simkl => const [
            ArchiveCatalog(
                type: ArchiveType.movie,
                id: 'simkl.playback',
                name: 'Continue watching on Simkl'),
            ArchiveCatalog(
                type: ArchiveType.series,
                id: 'simkl.playback',
                name: 'Continue watching on Simkl'),
            ArchiveCatalog(
                type: ArchiveType.series,
                id: 'simkl.watching',
                name: 'Watching on Simkl'),
            ArchiveCatalog(
                type: ArchiveType.movie,
                id: 'simkl.plantowatch',
                name: 'Simkl plan to watch'),
            ArchiveCatalog(
                type: ArchiveType.series,
                id: 'simkl.plantowatch',
                name: 'Simkl plan to watch'),
          ],
      };

  /// One page of an account list. Simkl lists come whole (page 0 only).
  Future<List<ArchiveMeta>> fetchCatalog(
      TrackerLogin login, ArchiveCatalog catalog,
      {int skip = 0}) async {
    final movies = catalog.type == ArchiveType.movie;
    if (catalog.id.endsWith('.playback')) {
      // Paused items, newest first: movies as such, episodes as their show
      // (once per show). IMDb id needed to show and play them here.
      if (skip > 0) return const [];
      final paused = await fetchPaused(login);
      final seen = <String>{};
      return [
        for (final p in paused)
          if (p.type == catalog.type && p.imdb != null && seen.add(p.imdb!))
            ArchiveMeta(
              id: p.imdb!,
              type: p.type,
              name: p.title,
              year: p.year,
              posterUrl:
                  'https://images.metahub.space/poster/medium/${p.imdb}/img',
              backgroundUrl:
                  'https://images.metahub.space/background/medium/${p.imdb}/img',
            ),
      ];
    }
    final Uri uri;
    if (login.kind == TrackerKind.trakt) {
      final page = '${skip ~/ _pageSize + 1}';
      final path = switch (catalog.id) {
        'trakt.trending' => movies ? '/movies/trending' : '/shows/trending',
        _ => movies ? '/sync/watchlist/movies' : '/sync/watchlist/shows',
      };
      uri = Uri.parse('$_trakt$path')
          .replace(queryParameters: {'page': page, 'limit': '$_pageSize'});
    } else {
      if (skip > 0) return const [];
      final status =
          catalog.id == 'simkl.watching' ? 'watching' : 'plantowatch';
      uri = Uri.parse(
          '$_simkl/sync/all-items/${movies ? 'movies' : 'shows'}/$status');
    }
    final r = await _client
        .get(uri, headers: _headers(login.kind, login.accessToken))
        .timeout(_timeout);
    if (r.statusCode == 401) throw TrackerAuthException('401');
    if (r.statusCode != 200) return const [];
    final j = _decode(r);
    // Trakt: a list of {movie|show: {...}}; Simkl: {movies|shows: [...]}.
    final items = j is List
        ? j
        : j is Map
            ? (j[movies ? 'movies' : 'shows'] as List? ?? const [])
            : const [];
    final key = movies ? 'movie' : 'show';
    return [
      for (final it in items)
        if (it is Map && it[key] is Map)
          if (metaFor(Map<String, dynamic>.from(it[key] as Map),
                  movies ? ArchiveType.movie : ArchiveType.series)
              case final m?)
            m,
    ];
  }

  /// A tracker title as a Media Hub meta, by IMDb id (no IMDb id = left
  /// out: nothing could play or show it).
  static ArchiveMeta? metaFor(Map<String, dynamic> j, ArchiveType type) {
    final ids = j['ids'];
    final imdb = ids is Map ? ids['imdb']?.toString() : null;
    final title = j['title']?.toString().trim();
    if (imdb == null || !imdb.startsWith('tt') || title == null) return null;
    return ArchiveMeta(
      id: imdb,
      type: type,
      name: title,
      year: j['year']?.toString(),
      posterUrl: 'https://images.metahub.space/poster/medium/$imdb/img',
      backgroundUrl: 'https://images.metahub.space/background/medium/$imdb/img',
    );
  }

  // ---- watched history (read back) ----------------------------------------

  Future<Object?> _getJson(TrackerLogin login, String url,
      [Map<String, String>? query]) async {
    var uri = Uri.parse(url);
    if (login.kind == TrackerKind.simkl) {
      query = {
        ...?query,
        'client_id': _simklClientId,
        'app-name': 'iptv-app',
        'app-version': '1',
      };
    }
    if (query != null) uri = uri.replace(queryParameters: query);
    final r = await _client
        .get(uri, headers: _headers(login.kind, login.accessToken))
        .timeout(const Duration(seconds: 30));
    if (r.statusCode == 401) throw TrackerAuthException('401');
    if (r.statusCode != 200) {
      throw TrackerAuthException('history ${r.statusCode}');
    }
    return _decode(r);
  }

  /// Everything [login] has watched (episodes per show, movies) and its
  /// paused items. Trakt: `/sync/watched/{shows,movies}` + `/sync/playback`;
  /// Simkl: `/sync/all-items` (`extended=full` for the episodes) +
  /// `/sync/playback`.
  Future<TrackerHistory> fetchHistory(TrackerLogin login) async {
    final h = TrackerHistory();
    void addShow(Object? show, Object? seasons) {
      final keys = TrackerHistory._keysOf(show is Map ? show['ids'] : null);
      if (keys.isEmpty || seasons is! List) return;
      final eps = <String>{
        for (final s in seasons)
          if (s is Map)
            for (final e in (s['episodes'] as List? ?? const []))
              if (e is Map) '${s['number']}:${e['number']}',
      };
      for (final k in keys) {
        h.episodes.putIfAbsent(k, () => <String>{}).addAll(eps);
      }
    }

    void addMovie(Object? movie) => h.movies
        .addAll(TrackerHistory._keysOf(movie is Map ? movie['ids'] : null));

    if (login.kind == TrackerKind.trakt) {
      final shows = await _getJson(login, '$_trakt/sync/watched/shows');
      for (final s in (shows is List ? shows : const [])) {
        if (s is Map) addShow(s['show'], s['seasons']);
      }
      final movies = await _getJson(login, '$_trakt/sync/watched/movies');
      for (final m in (movies is List ? movies : const [])) {
        if (m is Map) addMovie(m['movie']);
      }
    } else {
      final shows = await _getJson(login, '$_simkl/sync/all-items/shows/all',
          {'extended': 'full', 'include_all_episodes': 'yes'});
      for (final s
          in (shows is Map ? shows['shows'] as List? ?? const [] : const [])) {
        if (s is Map) addShow(s['show'], s['seasons']);
      }
      final movies =
          await _getJson(login, '$_simkl/sync/all-items/movies/completed');
      for (final m in (movies is Map
          ? movies['movies'] as List? ?? const []
          : const [])) {
        if (m is Map) addMovie(m['movie']);
      }
    }
    h.paused.addAll(await fetchPaused(login));
    h.paused.sort((a, b) => b.pausedAt.compareTo(a.pausedAt));
    return h;
  }

  /// [login]'s paused movies and episodes, newest first.
  Future<List<PausedItem>> fetchPaused(TrackerLogin login) async {
    final out = <PausedItem>[];
    final playback = await _getJson(login,
        '${login.kind == TrackerKind.trakt ? _trakt : _simkl}/sync/playback');
    for (final p in (playback is List ? playback : const [])) {
      if (p is! Map) continue;
      final episode = p['episode'];
      final isEpisode = episode is Map;
      final owner = (isEpisode ? p['show'] : p['movie']);
      if (owner is! Map) continue;
      final ids = owner['ids'];
      final progress = (p['progress'] as num?)?.toDouble();
      final title = owner['title']?.toString();
      if (progress == null || title == null || ids is! Map) continue;
      int? n(Object? v) => v is num ? v.toInt() : int.tryParse('$v');
      out.add(PausedItem(
        type: isEpisode ? ArchiveType.series : ArchiveType.movie,
        title: title,
        progress: progress,
        pausedAt: DateTime.tryParse('${p['paused_at']}') ?? DateTime(2000),
        imdb: ids['imdb']?.toString(),
        tmdb: ids['tmdb']?.toString(),
        year: owner['year']?.toString(),
        season: isEpisode ? n(episode['season']) : null,
        // Simkl's docs show both `number` and `episode`.
        episode: isEpisode ? n(episode['number'] ?? episode['episode']) : null,
      ));
    }
    out.sort((a, b) => b.pausedAt.compareTo(a.pausedAt));
    return out;
  }

  /// Marks [item] watched (or, with [watched] false, unwatched) on
  /// [login]'s account — the series page's hold-OK toggle. Best effort.
  Future<bool> setWatched(TrackerLogin login, TrackedItem item,
      {required bool watched}) async {
    final base = login.kind == TrackerKind.trakt ? _trakt : _simkl;
    try {
      final r = await _client
          .post(Uri.parse('$base/sync/history${watched ? '' : '/remove'}'),
              headers: _headers(login.kind, login.accessToken),
              body: jsonEncode(item.toHistoryBody()))
          .timeout(_timeout);
      return r.statusCode == 200 || r.statusCode == 201;
    } catch (_) {
      return false;
    }
  }

  // ---- scrobbling ----------------------------------------------------------

  /// Tells [login]'s service that [item] started / paused / stopped at
  /// [progress] percent. A stop at 80 %+ marks it watched (both services).
  /// Best effort: a failure is only returned, never thrown.
  Future<bool> scrobble(TrackerLogin login, TrackedItem item, String action,
      double progress) async {
    final base = login.kind == TrackerKind.trakt ? _trakt : _simkl;
    try {
      final r = await _client
          .post(Uri.parse('$base/scrobble/$action'),
              headers: _headers(login.kind, login.accessToken),
              body: jsonEncode({
                ...item.toBody(),
                'progress': double.parse(progress.toStringAsFixed(2)),
              }))
          .timeout(_timeout);
      // Trakt answers 409 when the same stop was just sent: fine.
      return r.statusCode == 201 || r.statusCode == 200 || r.statusCode == 409;
    } catch (_) {
      return false;
    }
  }

  void close() => _client.close();
}
