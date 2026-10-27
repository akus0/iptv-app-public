import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

import '../models/archive_models.dart';
import '../models/channel.dart';
import 'archive_api_service.dart';
import 'archive_cache.dart';
import 'media_server_api.dart';
import 'storage_service.dart';
import 'tracker_api.dart';

/// One row of the Archive browse: a source's catalog and its titles, or
/// (with [searchQuery]) that catalog's results for a search.
class ArchiveRow {
  const ArchiveRow({
    required this.source,
    required this.catalog,
    required this.items,
    this.searchQuery,
    this.itemSources,
  });

  final ArchiveSource source;
  final ArchiveCatalog catalog;
  final List<ArchiveMeta> items;
  final String? searchQuery;

  /// Set on the watched-history row, whose titles come from several
  /// sources: the source of each item (else every item is [source]'s).
  final List<ArchiveSource>? itemSources;

  ArchiveSource sourceAt(int i) => itemSources?[i] ?? source;

  bool get isSearch => searchQuery != null;
  bool get isHistory => itemSources != null;

  String get key => isHistory
      ? 'history|${catalog.type.wire}'
      : isSearch
          ? 'search|${ArchiveService._rowKey(source, catalog)}'
          : ArchiveService._rowKey(source, catalog);

  /// The row header: the catalog's own name, or the source name when the
  /// catalog has none. Provider row names ("Popular") and search rows are
  /// translated by the screen.
  String get title => catalog.name.isEmpty ? source.name : catalog.name;
}

/// One stream offered for a title, with the source that offered it.
class ArchiveStreamOption {
  const ArchiveStreamOption({required this.source, required this.stream});

  final ArchiveSource source;
  final ArchiveStream stream;
}

/// The Archive tab's state: the user's sources (Settings > Archive
/// sources), their catalog rows (cache first, then network), and turning
/// a picked title into a [Channel] the existing player can play.
///
/// Sources are any server that follows the Stremio add-on REST schema
/// (see [ArchiveApiService]) — the app ships none, so nothing is
/// contacted until the user adds one. Only direct http(s) streams are
/// used; torrent/debrid entries are ignored on purpose.
class ArchiveService extends ChangeNotifier {
  ArchiveService(this._storage,
      {ArchiveApiService? api,
      ArchiveCache? cache,
      MediaServerApi? servers,
      TrackerApi? trackers})
      : _api = api ?? ArchiveApiService(),
        _cache = cache ?? ArchiveCache(),
        _servers = servers ?? MediaServerApi(),
        _trackers = trackers ?? TrackerApi();

  final StorageService _storage;
  final ArchiveApiService _api;
  final ArchiveCache _cache;

  /// Jellyfin/Emby sources ([ArchiveSource.server]) go here instead of
  /// [_api]; everything else (rows, cache, search, history, Play) is the
  /// same for both kinds of source.
  final MediaServerApi _servers;

  /// Trakt/Simkl accounts ([ArchiveSource.tracker]): their lists are rows.
  final TrackerApi _trackers;

  Future<List<ArchiveMeta>> _page(ArchiveSource s, ArchiveCatalog c,
      {int skip = 0, String? search}) async {
    if (s.tracker != null) {
      if (search != null) return const []; // lists aren't searchable
      final login = await _freshTracker(s);
      return _trackers.fetchCatalog(login, c, skip: skip);
    }
    return s.server != null
        ? _servers.fetchCatalog(s, c, skip: skip, search: search)
        : _api.fetchCatalog(s.catalogBaseUrl, c, skip: skip, search: search);
  }

  // ---- Trakt / Simkl -------------------------------------------------------

  /// [s]'s login, refreshed (and saved) first when it's about to expire.
  Future<TrackerLogin> _freshTracker(ArchiveSource s) async {
    final login = s.tracker!;
    if (!login.needsRefresh) return login;
    final fresh = await _trackers.refresh(login);
    await _saveSources([
      for (final x in sources)
        x.manifestUrl == s.manifestUrl ? x.copyWith(tracker: fresh) : x,
    ]);
    return fresh;
  }

  /// The connected tracker account of [kind], if any.
  ArchiveSource? trackerSource(TrackerKind kind) =>
      sources.where((s) => s.tracker?.kind == kind).firstOrNull;

  /// Every enabled account's login, fresh — what `WatchTracker` reports to.
  Future<List<TrackerLogin>> trackerLogins() async {
    final out = <TrackerLogin>[];
    for (final s in enabledSources) {
      if (s.tracker == null) continue;
      try {
        out.add(await _freshTracker(s));
      } catch (e) {
        debugPrint('ArchiveService: source token refresh failed: ${e.runtimeType}');
      }
    }
    return out;
  }

  /// Adds (or replaces: one account per tracker) a signed-in account.
  Future<ArchiveSource> addTracker(TrackerLogin login) async {
    final source = ArchiveSource(
      manifestUrl: '${login.kind.name}://account',
      name: login.kind.label,
      description: login.userName,
      catalogs: TrackerApi.catalogsFor(login.kind),
      tracker: login,
    );
    await _saveSources([
      for (final s in sources)
        if (s.tracker?.kind != login.kind) s,
      source,
    ]);
    unawaited(refresh(force: true));
    return source;
  }

  /// Every Archive [Channel] uses this playlist id; `PlaybackService.play`
  /// lets it through (no playlist profile backs it).
  static const playlistId = 'archive';

  /// A cached catalog younger than this isn't refetched on open.
  static const _staleAfter = Duration(hours: 12);

  /// Pages fetched per catalog (sources usually send 100 per page).
  static const _pagesPerCatalog = 2;

  final Map<String, List<ArchiveMeta>> _items = {};
  bool _loadedFromCache = false;
  bool _refreshing = false;
  bool _refreshAgain = false;
  String? lastError;

  bool get refreshing => _refreshing;

  // ---- sources ------------------------------------------------------------

  List<ArchiveSource> get sources {
    final raw = _storage.getArchiveSourcesJson();
    if (raw == null) return const [];
    try {
      return [
        for (final j in jsonDecode(raw) as List)
          if (ArchiveSource.fromJson(Map<String, dynamic>.from(j as Map))
              case final s)
            // A tracker's rows are always the current set (accounts added
            // before "Continue watching" existed get it too).
            s.tracker == null
                ? s
                : s.copyWith(catalogs: TrackerApi.catalogsFor(s.tracker!.kind)),
      ];
    } catch (_) {
      return const [];
    }
  }

  List<ArchiveSource> get enabledSources =>
      sources.where((s) => s.enabled).toList();

  Future<void> _saveSources(List<ArchiveSource> list) async {
    await _storage
        .setArchiveSourcesJson(jsonEncode([for (final s in list) s.toJson()]));
    _notify();
  }

  /// Checks [link]'s manifest and adds it. Throws [ArchiveApiException]
  /// (bad link, no streams/catalogs) or [StateError] (already added).
  Future<ArchiveSource> addSource(String link) async {
    final source = await _api.fetchManifest(link);
    final list = sources;
    if (list.any((s) => s.manifestUrl == source.manifestUrl)) {
      throw StateError('already added');
    }
    await _saveSources([...list, source]);
    unawaited(refresh(force: true));
    return source;
  }

  /// Signs in to a Jellyfin/Emby server and adds it (signing in again as
  /// the same user replaces the old login). Throws
  /// [MediaServerLoginException] (wrong user/password),
  /// [MediaServerNoLibraryException] or [ArchiveApiException] (no server
  /// there).
  Future<ArchiveSource> addMediaServer(
      String address, String userName, String password) async {
    final source = await _servers.connect(address, userName, password);
    final list = sources;
    final at = list.indexWhere((s) => s.manifestUrl == source.manifestUrl);
    await _saveSources(at < 0
        ? [...list, source]
        : [for (var i = 0; i < list.length; i++) i == at ? source : list[i]]);
    unawaited(refresh(force: true));
    return source;
  }

  Future<void> setEnabled(ArchiveSource source, bool on) => _saveSources([
        for (final s in sources)
          s.manifestUrl == source.manifestUrl ? s.copyWith(enabled: on) : s,
      ]);

  Future<void> removeSource(ArchiveSource source) async {
    await _saveSources(
        sources.where((s) => s.manifestUrl != source.manifestUrl).toList());
    _items.removeWhere((k, _) => k.startsWith('${source.key}|'));
    await _cache.deleteSource(source.key);
    _notify();
  }

  /// Removes every source and its cached rows (Clear archives).
  Future<void> clearAll() async {
    await _saveSources(const []);
    _items.clear();
    await _cache.clear();
    _notify();
  }

  // ---- catalog rows -------------------------------------------------------

  static String _rowKey(ArchiveSource s, ArchiveCatalog c) =>
      '${s.key}|${c.wire}|${c.slug}';

  /// Catalogs of [type] to read, one per distinct row: a provider catalog
  /// shared by several stream-only sources is listed once (Play still
  /// asks every stream-only source — see [streams]). While a genre is
  /// picked ([setGenre]) only the catalogs offering it are listed, narrowed
  /// to it; [filtered] false lists the plain ones (search ignores genre).
  ///
  /// Catalogs of a custom type (`wireType` set: browsed under Movies) are
  /// only listed while the [otherGenre] filter is picked, and then alone —
  /// search follows the same split.
  List<(ArchiveSource, ArchiveCatalog)> _catalogs(ArchiveType type,
      {bool filtered = true}) {
    final other = _genre[type] == otherGenre;
    final genre = filtered && !other ? _genre[type] : null;
    final shown = <String>{};
    return [
      for (final s in enabledSources)
        for (final base in s.catalogs)
          if (base.type == type && (base.wireType != null) == other)
            if (genre == null ? base : base.withGenre(genre) case final c?)
              if (!s.streamOnly ||
                  shown.add('${s.catalogBaseUrl}|${c.wire}|${c.slug}'))
                (s, c),
    ];
  }

  // ---- genre filter -------------------------------------------------------

  /// The genre picked per type (rail "Genre"), kept for the session.
  final Map<ArchiveType, String> _genre = {};

  /// The "Other" pick in the genre filter: shows the catalogs of custom
  /// types (not movie/series) instead of the regular rows. Not a real
  /// genre name, so it can't collide with one.
  static const otherGenre = '\u0001other';

  String? genre(ArchiveType type) => _genre[type];

  /// Every genre a regular catalog of [type] can be narrowed to, in the
  /// order the sources list them, then [otherGenre] when an enabled source
  /// has catalogs of a custom type browsed under [type].
  List<String> genres(ArchiveType type) {
    final regular = <String>{};
    var other = false;
    for (final s in enabledSources) {
      for (final c in s.catalogs) {
        if (c.type != type) continue;
        if (c.wireType != null) {
          other = true;
        } else {
          regular.addAll(c.genres);
        }
      }
    }
    return [...regular, if (other) otherGenre];
  }

  /// Narrows [type]'s rows to [genre] (null = all): the rows offering it
  /// are shown from cache at once and fetched behind when stale.
  Future<void> setGenre(ArchiveType type, String? genre) async {
    if (_genre[type] == genre) return;
    if (genre == null) {
      _genre.remove(type);
    } else {
      _genre[type] = genre;
    }
    _notify();
    if (genre == null) return;
    for (final (s, c) in _catalogs(type)) {
      final key = _rowKey(s, c);
      if (_items.containsKey(key)) continue;
      try {
        _items[key] = await _cache.read(s.key, c);
      } catch (e) {
        debugPrint('ArchiveService: cache read failed: ${e.runtimeType}');
      }
    }
    _notify();
    await refresh();
  }

  /// The current search per type: its query and result rows.
  final Map<ArchiveType, (String, List<ArchiveRow>)> _search = {};
  bool _searching = false;
  bool get searching => _searching;
  String? searchQuery(ArchiveType type) => _search[type]?.$1;

  /// Searches every searchable catalog of [type] (the provider's Popular
  /// for stream-only sources). The results become the first rows.
  ///
  /// Partial words work: the server's matches and the titles already
  /// loaded in this source's rows are both kept only when a word of the
  /// title starts with the query, titles that start with it first (see
  /// [rankSearch]) — "li" finds "Lioness", then "The Lincoln Lawyer". A
  /// source without a searchable catalog is searched in its loaded rows
  /// only. One results row per source (stream-only sources sharing the
  /// provider count as one).
  Future<void> search(ArchiveType type, String query) async {
    final q = query.trim();
    if (q.isEmpty) return clearSearch(type);
    unawaited(_rememberSearch(type, q));
    _searching = true;
    _search[type] = (q, const []);
    _notify();
    final out = <ArchiveRow>[];
    try {
      final groups = <String, List<(ArchiveSource, ArchiveCatalog)>>{};
      for (final sc in _catalogs(type, filtered: false)) {
        final s = sc.$1;
        groups
            .putIfAbsent(
                s.streamOnly ? s.catalogBaseUrl : s.manifestUrl, () => [])
            .add(sc);
      }
      for (final group in groups.values) {
        final found = <ArchiveMeta>[];
        for (final (s, c) in group) {
          if (!c.searchable) continue;
          try {
            found.addAll(await _page(s, c, search: q));
          } catch (e) {
            debugPrint('ArchiveService: catalogue search failed: ${e.runtimeType}');
          }
        }
        for (final (s, c) in group) {
          found.addAll(_items[_rowKey(s, c)] ?? const []);
        }
        final items = rankSearch(q, found);
        if (items.isEmpty) continue;
        final (s, c) = group.firstWhere((sc) => sc.$2.searchable,
            orElse: () => group.first);
        out.add(
            ArchiveRow(source: s, catalog: c, items: items, searchQuery: q));
      }
    } finally {
      // A newer search (or a clear) replaced this one: drop these results.
      if (_search[type]?.$1 == q) _search[type] = (q, out);
      _searching = false;
      _notify();
    }
  }

  void clearSearch(ArchiveType type) {
    if (_search.remove(type) != null) _notify();
  }

  bool canSearch(ArchiveType type) => _catalogs(type).isNotEmpty;

  // ---- recent searches ----------------------------------------------------

  static const _recentSearchMax = 8;

  Map<String, dynamic> _recentSearchMap() {
    try {
      final raw = _storage.getArchiveRecentSearchesJson();
      return raw == null
          ? {}
          : Map<String, dynamic>.from(jsonDecode(raw) as Map);
    } catch (_) {
      return {};
    }
  }

  /// The last searches of [type], newest first (each category its own).
  List<String> recentSearches(ArchiveType type) => [
        for (final q in (_recentSearchMap()[type.wire] as List? ?? const []))
          '$q',
      ];

  Future<void> _rememberSearch(ArchiveType type, String query) async {
    final lower = query.toLowerCase();
    final list = [
      query,
      ...recentSearches(type).where((q) => q.toLowerCase() != lower),
    ].take(_recentSearchMax).toList();
    await _storage.setArchiveRecentSearchesJson(
        jsonEncode({..._recentSearchMap(), type.wire: list}));
  }

  Future<void> forgetRecentSearches(ArchiveType type) async {
    await _storage.setArchiveRecentSearchesJson(
        jsonEncode({..._recentSearchMap()}..remove(type.wire)));
    _notify();
  }

  // ---- watched history ----------------------------------------------------

  /// Titles kept in the history (both categories together).
  static const _historyMax = 40;

  List<Map<String, dynamic>> _historyEntries() {
    try {
      final raw = _storage.getArchiveHistoryJson();
      if (raw == null) return [];
      return [
        for (final e in jsonDecode(raw) as List)
          if (e is Map) Map<String, dynamic>.from(e),
      ];
    } catch (_) {
      return [];
    }
  }

  /// Called when a title (a movie, or a show's episode) starts playing: it
  /// moves to the front of its category's "Recently watched" row.
  Future<void> recordWatched(ArchiveSource source, ArchiveMeta meta) async {
    final entries = [
      {'src': source.manifestUrl, 'meta': meta.toJson()},
      ..._historyEntries().where((e) => !(e['src'] == source.manifestUrl &&
          (e['meta'] as Map?)?['id'] == meta.id)),
    ].take(_historyMax).toList();
    await _storage.setArchiveHistoryJson(jsonEncode(entries));
    _notify();
  }

  Future<void> removeFromHistory(ArchiveSource source, ArchiveMeta meta) async {
    final entries = _historyEntries()
        .where((e) => !(e['src'] == source.manifestUrl &&
            (e['meta'] as Map?)?['id'] == meta.id))
        .toList();
    await _storage
        .setArchiveHistoryJson(entries.isEmpty ? null : jsonEncode(entries));
    _notify();
  }

  /// "Recently watched" for [type]: played titles whose source is still
  /// enabled, newest first. Not narrowed by the genre filter.
  ArchiveRow? _historyRow(ArchiveType type) {
    final byUrl = {for (final s in enabledSources) s.manifestUrl: s};
    final items = <ArchiveMeta>[];
    final sources = <ArchiveSource>[];
    for (final e in _historyEntries()) {
      final source = byUrl[e['src']];
      final m = e['meta'];
      if (source == null || m is! Map) continue;
      final meta = ArchiveMeta.fromJson(Map<String, dynamic>.from(m));
      if (meta == null || meta.type != type) continue;
      // Custom-type titles only under the Other filter, like their rows.
      if ((meta.wireType != null) != (_genre[type] == otherGenre)) continue;
      items.add(meta);
      sources.add(source);
    }
    if (items.isEmpty) return null;
    return ArchiveRow(
      source: sources.first,
      catalog:
          ArchiveCatalog(type: type, id: 'history', name: 'Recently watched'),
      items: items,
      itemSources: sources,
    );
  }

  /// Lower case, accents off, anything else than letters/digits = space.
  static String _fold(String s) {
    const from = 'àáâãäåçèéêëìíîïñòóôõöùúûüýÿœæ';
    const to = 'aaaaaaceeeeiiiinooooouuuuyyoa';
    final b = StringBuffer();
    for (final ch in s.toLowerCase().split('')) {
      final i = from.indexOf(ch);
      b.write(i >= 0 ? to[i] : ch);
    }
    return b.toString().replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim();
  }

  /// [items] where [query] appears at the start of a word of the title
  /// ("lincoln law" finds "The Lincoln Lawyer"), deduplicated:
  /// titles starting with the query first, then the rest, each keeping the
  /// order they came in (server relevance, then row order).
  static List<ArchiveMeta> rankSearch(
      String query, Iterable<ArchiveMeta> items) {
    final q = _fold(query);
    if (q.isEmpty) return const [];
    final starts = <ArchiveMeta>[];
    final words = <ArchiveMeta>[];
    final seen = <String>{};
    for (final m in items) {
      if (!seen.add(m.id)) continue;
      final name = _fold(m.name);
      if (name.startsWith(q)) {
        starts.add(m);
      } else if (' $name'.contains(' $q')) {
        words.add(m);
      }
    }
    return [...starts, ...words];
  }

  /// Rows of [type] from every enabled source, in source then manifest
  /// order. Rows not loaded yet (or empty) are left out, and so is a
  /// provider row an earlier stream-only source already shows (Play still
  /// asks every stream-only source — see [resolve]).
  List<ArchiveRow> rows(ArchiveType type) => [
        ...?_search[type]?.$2,
        if (_historyRow(type) case final history?) history,
        for (final (s, c) in _catalogs(type))
          if (_items[_rowKey(s, c)] case final items? when items.isNotEmpty)
            ArchiveRow(source: s, catalog: c, items: items),
      ];

  final Set<String> _loadingMore = {};
  final Set<String> _exhausted = {};

  /// Appends [row]'s next page (called as focus nears its end), so a row
  /// keeps scrolling past the pages [refresh] fetched. Not cached: a
  /// refresh starts the row over.
  Future<void> loadMore(ArchiveRow row) async {
    final key = row.key;
    if (row.isSearch ||
        row.isHistory ||
        _exhausted.contains(key) ||
        !_loadingMore.add(key)) {
      return;
    }
    try {
      final have = _items[key] ?? const <ArchiveMeta>[];
      final batch = await _page(row.source, row.catalog, skip: have.length);
      final seen = {for (final m in have) m.id};
      final fresh = batch.where((m) => seen.add(m.id)).toList();
      if (fresh.isEmpty) {
        _exhausted.add(key);
      } else {
        _items[key] = [...have, ...fresh];
        _notify();
      }
    } catch (e) {
      debugPrint('ArchiveService: additional rows failed: ${e.runtimeType}');
    } finally {
      _loadingMore.remove(key);
    }
  }

  bool hasAny(ArchiveType type) =>
      enabledSources.any((s) => s.catalogs.any((c) => c.type == type));

  /// Call when the Archive tab opens: draws the cached rows at once, then
  /// refreshes stale catalogs behind them.
  Future<void> open() async {
    if (!_loadedFromCache) {
      _loadedFromCache = true;
      for (final type in ArchiveType.values) {
        for (final (s, c) in _catalogs(type)) {
          try {
            _items[_rowKey(s, c)] = await _cache.read(s.key, c);
          } catch (e) {
            debugPrint('ArchiveService: cache read failed: ${e.runtimeType}');
          }
        }
      }
      _notify();
    }
    unawaited(refresh());
  }

  /// Refetches catalogs older than [_staleAfter] (all of them with
  /// [force]). A failing source keeps its cached rows.
  Future<void> refresh({bool force = false}) async {
    if (_refreshing) {
      // A genre picked mid-refresh adds rows the running pass won't reach.
      _refreshAgain = true;
      return;
    }
    _refreshing = true;
    lastError = null;
    _notify();
    try {
      for (final type in ArchiveType.values) {
        for (final (s, c) in _catalogs(type)) {
          final key = _rowKey(s, c);
          if (!force) {
            final at = await _cache.fetchedAt(s.key, c);
            if (at != null &&
                DateTime.now().difference(at) < _staleAfter &&
                (_items[key]?.isNotEmpty ?? false)) {
              continue;
            }
          }
          try {
            final items = <ArchiveMeta>[];
            final seen = <String>{};
            for (var page = 0; page < _pagesPerCatalog; page++) {
              final batch = await _page(s, c, skip: items.length);
              final fresh = batch.where((m) => seen.add(m.id)).toList();
              if (fresh.isEmpty) break;
              items.addAll(fresh);
              if (batch.length < 50) break; // a short page = the last one
            }
            _items[key] = items;
            _exhausted.remove(key);
            await _cache.write(s.key, c, items);
            _notify();
          } catch (e) {
            lastError = '${s.name}: $e';
            debugPrint('ArchiveService: catalogue failed: ${e.runtimeType}');
          }
        }
      }
    } finally {
      _refreshing = false;
      _notify();
    }
    if (_refreshAgain) {
      _refreshAgain = false;
      await refresh();
    }
  }

  // ---- details + playback -------------------------------------------------

  static String _rawId(ArchiveSource source, String videoId,
          {required bool episode}) =>
      'arc_${episode ? 'ep' : 'vod'}_${source.key}_$videoId';

  /// The [Channel.id] [channelFor] gives a title — known before resolving, so
  /// detail pages can show saved progress (StorageService positions).
  static String channelId(ArchiveSource source, String videoId,
          {required bool episode}) =>
      '$playlistId::${_rawId(source, videoId, episode: episode)}';

  Future<ArchiveMeta?> meta(ArchiveSource source, ArchiveMeta preview) =>
      // A tracker's titles are IMDb ids: the provider has their metas.
      source.tracker != null
          ? _api.fetchMeta(
              ArchiveCatalogProvider.baseUrl, preview.type, preview.id)
          : source.server != null
              ? _servers.fetchMeta(source, preview)
              : _api.fetchMeta(source.catalogBaseUrl, preview.type, preview.id,
                  wire: preview.wire);

  /// The sources asked for a title's streams: [source] itself, then — for
  /// a title from the public provider — every other enabled stream-only
  /// source on the same provider, since they share the same IMDB ids.
  List<ArchiveSource> _streamSources(ArchiveSource source) => [
        // A tracker list has no streams: every stream-only add-on is asked,
        // like for the provider's own rows (same IMDb ids).
        if (source.tracker != null)
          for (final s in enabledSources)
            if (s.streamOnly) s,
        if (source.tracker == null) source,
        if (source.streamOnly)
          for (final s in enabledSources)
            if (s.streamOnly &&
                s.manifestUrl != source.manifestUrl &&
                s.catalogBaseUrl == source.catalogBaseUrl)
              s,
      ];

  /// Every direct http(s) stream for [meta] (a movie) or one of its
  /// [episode]s, in source then server order — the detail page plays a
  /// single one at once and lets the user pick when there are several
  /// (quality, language…). Each source is asked at its own `/stream/` with
  /// the title's id (`tt…`, or `tt…:{season}:{episode}` for a provider
  /// episode); a failing source is skipped, and its error rethrown only
  /// when no source answered with anything.
  Future<List<ArchiveStreamOption>> streams(
    ArchiveSource source,
    ArchiveMeta meta, {
    ArchiveVideo? episode,
  }) async {
    final videoId = episode?.id ?? meta.id;
    final out = <ArchiveStreamOption>[];
    final urls = <String>{};
    Object? error;
    for (final s in _streamSources(source)) {
      try {
        for (final st in s.server != null
            ? _servers.streams(s, videoId)
            : await _api.fetchStreams(s.baseUrl, meta.type, videoId,
                wire: meta.wire)) {
          if (urls.add(st.url)) {
            out.add(ArchiveStreamOption(source: s, stream: st));
          }
        }
      } catch (e) {
        error ??= e;
        debugPrint('ArchiveService: streams failed: ${e.runtimeType}');
      }
    }
    if (out.isEmpty && error != null) throw error;
    return out;
  }

  /// The [Channel] that plays [stream] for [meta] or its [episode]. Its id
  /// comes from [source] (the row the title was opened from), not from the
  /// stream picked, so progress is kept whichever stream plays.
  Channel channelFor(
    ArchiveSource source,
    ArchiveMeta meta,
    ArchiveStream stream, {
    ArchiveVideo? episode,
  }) {
    final videoId = episode?.id ?? meta.id;
    final rawId = _rawId(source, videoId, episode: episode != null);
    return Channel(
      id: '$playlistId::$rawId',
      rawId: rawId,
      playlistId: playlistId,
      name: episode == null
          ? meta.name
          : 'S${episode.season.toString().padLeft(2, '0')}'
              'E${episode.episode.toString().padLeft(2, '0')}'
              '${episode.title.isEmpty ? '' : ' - ${episode.title}'}',
      group: meta.name,
      url: stream.url,
      logoUrl: episode?.thumbnailUrl ?? meta.posterUrl,
      subtitleUrl: stream.subtitleUrl,
      posterUrl: meta.posterUrl,
      backdropUrl: meta.backgroundUrl,
      seriesName: episode == null ? null : meta.name,
      seriesCoverUrl: episode == null ? null : meta.posterUrl,
    );
  }

  /// Defer notifications until the current build/layout/paint phase completes.
  void _notify() {
    final phase = SchedulerBinding.instance.schedulerPhase;
    if (phase == SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) => notifyListeners());
    } else {
      notifyListeners();
    }
  }
}
