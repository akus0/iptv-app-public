/// Data models for the Archive tab: public-domain film/series sources that
/// speak the Stremio add-on REST schema (`manifest.json`,
/// `/catalog/{type}/{id}.json`, `/meta/{type}/{id}.json`,
/// `/stream/{type}/{id}.json`). Any source following that schema works —
/// the app ships none hard-wired; the user adds the ones they like in
/// Settings > Archive sources (see `ArchiveService`).
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';

/// The two content types the Archive tab browses. [wire] is the schema's
/// own `type` string.
enum ArchiveType {
  movie('movie'),
  series('series');

  const ArchiveType(this.wire);
  final String wire;

  static ArchiveType? fromWire(String? s) => switch (s) {
        'movie' => ArchiveType.movie,
        'series' => ArchiveType.series,
        _ => null,
      };

  /// Where a source's own catalog/meta of type [s] is browsed: movie and
  /// series as such, any other type ("tv", "channel", custom ones) under
  /// Movies, played like a movie. Null when there's no type at all.
  static ArchiveType? bucketFor(String? s) {
    final t = s?.trim() ?? '';
    return t.isEmpty ? null : fromWire(t) ?? ArchiveType.movie;
  }
}

/// One catalog a source's manifest lists, e.g. `{type: movie, id: pd_noir,
/// name: Film Noir}`. Only catalogs that need no `extra` argument (search
/// or genre are optional or absent) are kept — those are the ones that can
/// be shown as a plain row. An optional genre is the Extras genre filter.
class ArchiveCatalog {
  const ArchiveCatalog({
    required this.type,
    required this.id,
    required this.name,
    this.extra = const {},
    this.searchable = false,
    this.genres = const [],
    this.wireType,
  });

  final ArchiveType type;
  final String id;
  final String name;

  /// The source's own type string when it isn't [type]'s (a custom type
  /// browsed under Movies, see [ArchiveType.bucketFor]); null otherwise.
  final String? wireType;

  /// The type sent in `/catalog/{type}/…` requests.
  String get wire => wireType ?? type.wire;

  /// Fixed extra arguments sent with every page, e.g. `{genre: 2026}` for
  /// the provider's "New" row (its `year` catalog requires a year).
  final Map<String, String> extra;

  /// The catalog takes the schema's optional `search` extra.
  final bool searchable;

  /// The values its optional `genre` extra offers (the manifest's
  /// `options`), minus pure years: what the Extras genre filter can ask
  /// this catalog for. Empty = the row can't be filtered.
  final List<String> genres;

  /// This catalog narrowed to [genre] (sent as the `genre` extra), or null
  /// when it doesn't offer that genre or already fixes its own.
  ArchiveCatalog? withGenre(String genre) =>
      extra.containsKey('genre') || !genres.contains(genre)
          ? null
          : ArchiveCatalog(
              type: type,
              id: id,
              name: name,
              extra: {...extra, 'genre': genre},
              searchable: searchable,
              genres: genres,
              wireType: wireType,
            );

  /// [id] plus [extra]: unique per row, used for cache rows and row keys.
  String get slug => extra.isEmpty
      ? id
      : '$id?${[
          for (final e in extra.entries) '${e.key}=${e.value}'
        ].join('&')}';

  Map<String, dynamic> toJson() => {
        'type': wire,
        'id': id,
        'name': name,
        if (extra.isNotEmpty) 'fixedExtra': extra,
        if (searchable) 'searchable': true,
        if (genres.isNotEmpty) 'genres': genres,
      };

  /// Reads both a manifest entry (`extra: [{name: search}, …]`) and the
  /// stored form ([toJson]).
  static ArchiveCatalog? fromJson(Map<String, dynamic> j) {
    final wire = j['type']?.toString().trim();
    final type = ArchiveType.bucketFor(wire);
    final id = j['id']?.toString();
    if (type == null || id == null || id.isEmpty) return null;
    final fixed = j['fixedExtra'];
    final extras = j['extra'] as List? ?? const [];
    final genreOptions = [
      ...(j['genres'] as List? ?? const []),
      for (final e in extras)
        if (e is Map && e['name'] == 'genre' && e['isRequired'] != true)
          ...(e['options'] as List? ?? const []),
    ];
    return ArchiveCatalog(
      type: type,
      id: id,
      name: (j['name']?.toString() ?? '').trim(),
      extra: fixed is Map
          ? {for (final e in fixed.entries) '${e.key}': '${e.value}'}
          : const {},
      searchable: j['searchable'] == true ||
          extras.any((e) => e is Map && e['name'] == 'search') ||
          (j['extraSupported'] as List? ?? const []).contains('search'),
      genres: [
        for (final g in {for (final o in genreOptions) '$o'.trim()})
          if (g.isNotEmpty && !RegExp(r'^\d+$').hasMatch(g)) g,
      ],
      wireType: wire == type.wire ? null : wire,
    );
  }
}

/// The public catalog provider that fills the grids for stream-only
/// sources: add-ons keyed on IMDB ids (`tt…`) that, as the add-on SDK
/// allows, ship no `/catalog/` or `/meta/` of their own. Posters, titles
/// and episode lists come from here; only `/stream/` goes to the source.
class ArchiveCatalogProvider {
  static const baseUrl = 'https://v3-cinemeta.strem.io';
  static const name = 'Cinemeta';

  /// The genres its Popular and Featured catalogs take (its manifest's
  /// `genre` options; series add three TV-only ones).
  static const movieGenres = [
    'Action', 'Adventure', 'Animation', 'Biography', 'Comedy', 'Crime', //
    'Documentary', 'Drama', 'Family', 'Fantasy', 'History', 'Horror',
    'Mystery', 'Romance', 'Sci-Fi', 'Sport', 'Thriller', 'War', 'Western',
  ];
  static const seriesGenres = [
    ...movieGenres,
    'Reality-TV', 'Talk-Show', 'Game-Show', //
  ];

  /// The rows a stream-only source shows, for the [types] it streams:
  /// Popular (also the one searched), New (this year's titles — the
  /// provider's `year` catalog needs the year) and Featured (by rating).
  /// Names are translated where they're shown.
  static List<ArchiveCatalog> catalogsFor(Iterable<ArchiveType> types,
      {DateTime? now}) {
    final year = '${(now ?? DateTime.now()).year}';
    return [
      for (final t in const [ArchiveType.movie, ArchiveType.series])
        if (types.contains(t)) ...[
          ArchiveCatalog(
              type: t,
              id: 'top',
              name: 'Popular',
              searchable: true,
              genres: t == ArchiveType.movie ? movieGenres : seriesGenres),
          ArchiveCatalog(
              type: t, id: 'year', name: 'New', extra: {'genre': year}),
          ArchiveCatalog(
              type: t,
              id: 'imdbRating',
              name: 'Featured',
              genres: t == ArchiveType.movie ? movieGenres : seriesGenres),
        ],
    ];
  }
}

/// The two media servers Settings > Connect Jellyfin / Emby speaks to. Emby
/// is Jellyfin's parent (forked in 2018): same REST API, but different
/// auth headers and often a `/emby` path (see `MediaServerApi`).
enum MediaServerKind {
  jellyfin('Jellyfin'),
  emby('Emby');

  const MediaServerKind(this.label);
  final String label;

  static MediaServerKind? fromName(String? s) => switch (s) {
        'jellyfin' => MediaServerKind.jellyfin,
        'emby' => MediaServerKind.emby,
        _ => null,
      };
}

/// The signed-in user of a media-server source: what every request to
/// that server needs (`MediaServerApi`).
class MediaServerLogin {
  const MediaServerLogin({
    required this.kind,
    required this.userId,
    required this.token,
    required this.deviceId,
    this.userName = '',
  });

  final MediaServerKind kind;
  final String userId;
  final String token;

  /// Sent in the auth header; the server ties the token to it.
  final String deviceId;
  final String userName;

  Map<String, dynamic> toJson() => {
        'kind': kind.name,
        'userId': userId,
        'token': token,
        'deviceId': deviceId,
        if (userName.isNotEmpty) 'userName': userName,
      };

  static MediaServerLogin? fromJson(Object? j) {
    if (j is! Map) return null;
    final kind = MediaServerKind.fromName(j['kind']?.toString());
    final userId = j['userId']?.toString();
    final token = j['token']?.toString();
    if (kind == null || userId == null || token == null) return null;
    return MediaServerLogin(
      kind: kind,
      userId: userId,
      token: token,
      deviceId: j['deviceId']?.toString() ?? userId,
      userName: j['userName']?.toString() ?? '',
    );
  }
}

/// The two watch trackers (Settings > Trakt & Simkl, `TrackerApi`).
enum TrackerKind {
  trakt('Trakt'),
  simkl('Simkl');

  const TrackerKind(this.label);
  final String label;

  static TrackerKind? fromName(String? s) => switch (s) {
        'trakt' => TrackerKind.trakt,
        'simkl' => TrackerKind.simkl,
        _ => null,
      };
}

/// A connected Trakt/Simkl account. Trakt tokens expire ([expiresAtMs],
/// Simkl V2 after 7 days — both refreshed with the client id alone).
class TrackerLogin {
  const TrackerLogin({
    required this.kind,
    required this.accessToken,
    this.refreshToken,
    this.expiresAtMs,
    this.userName = '',
  });

  final TrackerKind kind;
  final String accessToken;
  final String? refreshToken;
  final int? expiresAtMs;
  final String userName;

  /// Expired, or expiring within the hour.
  bool get needsRefresh =>
      refreshToken != null &&
      expiresAtMs != null &&
      DateTime.now().millisecondsSinceEpoch >
          expiresAtMs! - const Duration(hours: 1).inMilliseconds;

  Map<String, dynamic> toJson() => {
        'kind': kind.name,
        'access': accessToken,
        if (refreshToken != null) 'refresh': refreshToken,
        if (expiresAtMs != null) 'expires': expiresAtMs,
        if (userName.isNotEmpty) 'user': userName,
      };

  static TrackerLogin? fromJson(Object? j) {
    if (j is! Map) return null;
    final kind = TrackerKind.fromName(j['kind']?.toString());
    final access = j['access']?.toString();
    if (kind == null || access == null) return null;
    return TrackerLogin(
      kind: kind,
      accessToken: access,
      refreshToken: j['refresh']?.toString(),
      expiresAtMs: (j['expires'] as num?)?.toInt(),
      userName: j['user']?.toString() ?? '',
    );
  }
}

/// A source the user added: its manifest plus whether it's switched on.
///
/// A Trakt/Simkl account is a source too ([tracker] set): its catalogs are
/// the account's lists (watchlist, …) by IMDb id, metas and posters come
/// from [ArchiveCatalogProvider], and Play asks the stream-only add-ons —
/// like the provider's own rows. Its plays are also reported back
/// (`WatchTracker`).
///
/// A Jellyfin/Emby server is a source too ([server] set): its
/// [manifestUrl] is `{apiBase}#{userId}` (one source per server + user),
/// its catalogs are the user's movie and TV libraries, and every request
/// goes through `MediaServerApi` instead of the add-on schema.
class ArchiveSource {
  const ArchiveSource({
    required this.manifestUrl,
    required this.name,
    this.description = '',
    this.logoUrl,
    this.catalogs = const [],
    this.catalogProviderUrl,
    this.enabled = true,
    this.server,
    this.tracker,
  });

  final String manifestUrl;
  final String name;
  final String description;
  final String? logoUrl;
  final List<ArchiveCatalog> catalogs;

  /// Set for a stream-only source: where its [catalogs] and metas are
  /// fetched from ([ArchiveCatalogProvider.baseUrl]). Null when the source
  /// serves its own catalogs.
  final String? catalogProviderUrl;
  final bool enabled;

  /// Set for a Jellyfin/Emby server source.
  final MediaServerLogin? server;

  /// Set for a Trakt/Simkl account source.
  final TrackerLogin? tracker;

  bool get streamOnly => catalogProviderUrl != null;

  /// Where its resources live: the manifest URL minus `/manifest.json` (a
  /// media server: its API base, without the `#userId`).
  String get baseUrl {
    if (server != null) return manifestUrl.split('#').first;
    final u = manifestUrl.trim();
    return u.endsWith('/manifest.json')
        ? u.substring(0, u.length - '/manifest.json'.length)
        : u.replaceAll(RegExp(r'/+$'), '');
  }

  /// Where `/catalog/` and `/meta/` live: the provider for a stream-only
  /// source, else the source itself. `/stream/` always uses [baseUrl].
  String get catalogBaseUrl =>
      catalogProviderUrl ??
      (tracker != null ? ArchiveCatalogProvider.baseUrl : baseUrl);

  /// Short stable key for cache rows and channel ids (the manifest URL can
  /// be long; ids only need to be unique per install).
  /// sha1, not `hashCode`: it's persisted (cache rows, resume positions).
  String get key =>
      sha1.convert(utf8.encode(manifestUrl)).toString().substring(0, 12);

  ArchiveSource copyWith(
          {bool? enabled,
          List<ArchiveCatalog>? catalogs,
          TrackerLogin? tracker}) =>
      ArchiveSource(
        manifestUrl: manifestUrl,
        name: name,
        description: description,
        logoUrl: logoUrl,
        catalogs: catalogs ?? this.catalogs,
        catalogProviderUrl: catalogProviderUrl,
        enabled: enabled ?? this.enabled,
        server: server,
        tracker: tracker ?? this.tracker,
      );

  Map<String, dynamic> toJson() => {
        'url': manifestUrl,
        'name': name,
        'description': description,
        'logo': logoUrl,
        'catalogs': [for (final c in catalogs) c.toJson()],
        if (catalogProviderUrl != null) 'catalogProvider': catalogProviderUrl,
        'enabled': enabled,
        if (server != null) 'server': server!.toJson(),
        if (tracker != null) 'tracker': tracker!.toJson(),
      };

  factory ArchiveSource.fromJson(Map<String, dynamic> j) {
    final stored = [
      for (final c in (j['catalogs'] as List? ?? const []))
        if (c is Map)
          if (ArchiveCatalog.fromJson(Map<String, dynamic>.from(c))
              case final cat?)
            cat,
    ];
    final provider = j['catalogProvider'] as String?;
    return ArchiveSource(
      manifestUrl: j['url'] as String,
      name: (j['name'] as String?) ?? j['url'] as String,
      description: (j['description'] as String?) ?? '',
      logoUrl: j['logo'] as String?,
      // A stream-only source's rows are re-derived from its types, so new
      // provider rows (and next year's "New") reach sources added earlier.
      // (A tracker's rows are its own lists — kept as stored.)
      catalogs: provider == null || j['tracker'] != null
          ? stored
          : ArchiveCatalogProvider.catalogsFor(
              {for (final c in stored) c.type}),
      catalogProviderUrl: provider,
      enabled: j['enabled'] != false,
      server: MediaServerLogin.fromJson(j['server']),
      tracker: TrackerLogin.fromJson(j['tracker']),
    );
  }
}

/// One title in a catalog (the schema's "meta preview"), or the full meta
/// when it came from `/meta/` (then [videos] is filled for a series).
class ArchiveMeta {
  const ArchiveMeta({
    required this.id,
    required this.type,
    required this.name,
    this.posterUrl,
    this.backgroundUrl,
    this.year,
    this.description,
    this.genres = const [],
    this.runtime,
    this.rating,
    this.cast = const [],
    this.director = const [],
    this.videos = const [],
    this.wireType,
    this.imdbId,
  });

  final String id;
  final ArchiveType type;
  final String name;

  /// The IMDb id when [id] isn't one (a Jellyfin/Emby item's provider id);
  /// see [imdb].
  final String? imdbId;

  /// The title's IMDb id (`tt…`), if known — what Trakt/Simkl are told.
  String? get imdb {
    if (imdbId != null) return imdbId;
    final base = id.split(':').first;
    return RegExp(r'^tt\d+$').hasMatch(base) ? base : null;
  }

  /// The source's own type string when it isn't [type]'s (see
  /// [ArchiveCatalog.wireType]); null otherwise.
  final String? wireType;

  /// The type sent in `/meta/` and `/stream/` requests.
  String get wire => wireType ?? type.wire;
  final String? posterUrl;
  final String? backgroundUrl;

  /// `releaseInfo` as sources send it: "1931", or "1959-1964" for a series.
  final String? year;
  final String? description;
  final List<String> genres;
  final String? runtime;

  /// `imdbRating` as sent ("8.9"); only on full metas from the provider.
  final String? rating;
  final List<String> cast;
  final List<String> director;

  /// Episodes, only on a series' full meta.
  final List<ArchiveVideo> videos;

  static String? _str(Object? v) {
    final s = v?.toString().trim();
    return (s == null || s.isEmpty) ? null : s;
  }

  static List<String> _strs(Object? v) => [
        for (final x in (v is List ? v : const []))
          if (_str(x) case final s?) s,
      ];

  /// [fallbackType]/[fallbackWire] (the catalog's) stand in when the meta
  /// carries no type. Ids are kept as the source sends them: IMDb `tt…` or
  /// the source's own.
  static ArchiveMeta? fromJson(Map<String, dynamic> j,
      {ArchiveType? fallbackType, String? fallbackWire}) {
    final id = _str(j['id']);
    final name = _str(j['name']);
    final ownWire = _str(j['type']);
    final wire = ownWire ?? fallbackWire ?? fallbackType?.wire;
    final type = ownWire != null
        ? ArchiveType.bucketFor(ownWire)
        : (fallbackType ?? ArchiveType.bucketFor(wire));
    if (id == null || name == null || type == null) return null;
    return ArchiveMeta(
      id: id,
      type: type,
      wireType: wire == null || wire == type.wire ? null : wire,
      imdbId: _str(j['imdb_id']),
      name: name,
      posterUrl: _str(j['poster']),
      backgroundUrl: _str(j['background']),
      year: _str(j['releaseInfo']) ?? _str(j['year']),
      description: _str(j['description']),
      genres: _strs(j['genres']),
      runtime: _str(j['runtime']),
      rating: _str(j['imdbRating']),
      cast: _strs(j['cast']),
      director: _strs(j['director']),
      videos: [
        for (final v in (j['videos'] as List? ?? const []))
          if (v is Map)
            if (ArchiveVideo.fromJson(Map<String, dynamic>.from(v))
                case final video?)
              video,
      ]..sort((a, b) {
          final s = a.season.compareTo(b.season);
          return s != 0 ? s : a.episode.compareTo(b.episode);
        }),
    );
  }

  /// What the cache stores: the preview fields only (no episode list).
  Map<String, dynamic> toJson() => {
        'id': id,
        'type': wire,
        'name': name,
        if (imdbId != null) 'imdb_id': imdbId,
        if (posterUrl != null) 'poster': posterUrl,
        if (backgroundUrl != null) 'background': backgroundUrl,
        if (year != null) 'releaseInfo': year,
        if (description != null) 'description': description,
        if (genres.isNotEmpty) 'genres': genres,
        if (runtime != null) 'runtime': runtime,
      };
}

/// One episode of a series meta. [id] is what `/stream/series/` takes —
/// usually `{seriesId}:{season}:{episode}`, but sources may use their own.
class ArchiveVideo {
  const ArchiveVideo({
    required this.id,
    required this.title,
    required this.season,
    required this.episode,
    this.thumbnailUrl,
    this.overview,
    this.released,
  });

  final String id;
  final String title;
  final int season;
  final int episode;
  final String? thumbnailUrl;
  final String? overview;

  /// Air date as sent (usually ISO 8601).
  final String? released;

  static ArchiveVideo? fromJson(Map<String, dynamic> j) {
    final id = j['id']?.toString();
    if (id == null || id.isEmpty) return null;
    int toInt(Object? v) => v is num ? v.toInt() : int.tryParse('$v') ?? 0;
    final season = toInt(j['season']);
    final episode = toInt(j['episode'] ?? j['number']);
    return ArchiveVideo(
      id: id,
      title: (j['title'] ?? j['name'] ?? '').toString().trim(),
      season: season,
      episode: episode,
      thumbnailUrl: ArchiveMeta._str(j['thumbnail']),
      overview: ArchiveMeta._str(j['overview'] ?? j['description']),
      released: ArchiveMeta._str(j['released'] ?? j['firstAired']),
    );
  }
}

/// One playable stream from `/stream/`. Only direct http(s) URLs are kept —
/// torrent (`infoHash`), YouTube (`ytId`) and `externalUrl` entries are
/// dropped by [ArchiveApiService.fetchStreams]: the app plays files, it
/// doesn't fetch torrents.
class ArchiveStream {
  const ArchiveStream(
      {required this.url, this.name, this.title, this.subtitleUrl});

  final String url;

  /// The schema's `name`: usually the source plus quality ("My Source 4K").
  final String? name;

  /// The schema's `title` (or `description`): file, size, language… — may
  /// span several lines.
  final String? title;

  /// `name` + `title` on one line, e.g. "Internet Archive · 512Kb MPEG4".
  String? get label {
    final s = [name, title?.replaceAll(RegExp(r'\s*\n\s*'), ' ')]
        .whereType<String>()
        .join(' · ');
    return s.isEmpty ? null : s;
  }

  /// First subtitle the stream carries, if any (`subtitles[0].url`).
  final String? subtitleUrl;
}
