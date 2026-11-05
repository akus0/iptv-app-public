import '../utils/channel_content.dart';
import '../utils/thai_epg.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:crypto/crypto.dart';
import '../models/channel.dart';
import '../models/m3u_group.dart';
import '../models/playlist_profile.dart';
import '../models/series_details.dart';
import '../models/vod_details.dart';
import '../models/xtream_category.dart';
import '../models/xtream_series.dart';
import '../utils/constants.dart';
import 'catalog_database.dart';
import 'm3u_parser.dart';
import 'storage_service.dart';
import 'xtream_api_service.dart';
import 'catalog_api.dart';
import 'stalker_portal_service.dart';
import '../l10n/l10n.dart';

/// Catalogue state for one playlist. Live data and on-demand library metadata
/// notify independently so library activity does not invalidate live matching.
class PlaylistSession {
  PlaylistSession({
    required PlaylistProfile profile,
    required this.storage,
    required this.catalogDb,
    required this.favoriteIds,
    required this.favoriteSeriesIds,
    required this.onNotify,
    this.onLibraryNotify,
  }) : _profile = profile;

  PlaylistProfile _profile;
  PlaylistProfile get profile => _profile;
  set profile(PlaylistProfile value) {
    if (_profile.userAgent != value.userAgent) {
      final api = catalogApi;
      if (api is XtreamApiService) api.userAgent = value.userAgent;
      if (api is StalkerPortalService) {
        // A portal may bind its token to the client identity. Reauthenticate
        // lazily on the next request, without reloading cached catalogues.
        api.dispose();
        catalogApi = StalkerPortalService(value);
      }
    }
    _profile = value;
  }

  final StorageService storage;
  final CatalogDatabase catalogDb;

  /// Read-only access to `PlaylistManager`'s global favorite id sets —
  /// favorites stay shared across every playlist (unlike hidden/favorited
  /// *groups*, which are per-playlist), so this session only ever reads
  /// them (to stamp `isFavorite` while loading), never owns or writes them.
  final Set<String> Function() favoriteIds;
  final Set<String> Function() favoriteSeriesIds;

  /// Forwards to the owning `PlaylistManager`'s own `notifyListeners()` —
  /// screens listen to that single `ChangeNotifier`, not to this session
  /// directly.
  final VoidCallback onNotify;
  final VoidCallback? onLibraryNotify;

  bool isLoading = false;
  String? error;
  DateTime? lastLoaded;
  String? loadingPhase;
  Map<String, int>? lastLoadSummary;

  /// Background catalog warm-up progress (Xtream mode only) — walks every
  /// VOD/series category that hasn't been loaded yet so nothing requires
  /// manually opening every category to populate it. Tracked per content
  /// type (not just combined) so the UI can show "Movies: 45/159" and
  /// "TV Shows: 22/80" separately, matching how the user actually thinks
  /// about the three content types.
  bool isWarmingCatalog = false;
  int warmCatalogDone = 0;
  int warmCatalogTotal = 0;
  int vodCatalogDone = 0;
  int vodCatalogTotal = 0;
  int seriesCatalogDone = 0;
  int seriesCatalogTotal = 0;

  Set<String> hiddenGroups = {};
  final Map<String, Set<String>> _libraryHiddenGroups = {};
  Set<String> hiddenGroupsForType(String type) => type == 'tv'
      ? hiddenGroups
      : (_libraryHiddenGroups[type] ?? hiddenGroups);
  bool isGroupHidden(String title, String type) =>
      hiddenGroupsForType(type).contains(title);
  Set<String> favoritedGroups = {};

  /// User-chosen group order per content type ('tv'/'vod'/'series') — see
  /// [moveGroup]. Missing/empty = provider order.
  Map<String, List<String>> groupOrder = {};

  /// Live TV only — see [AppConstants.keyHiddenChannels]'s doc comment
  /// for why this exists alongside whole-group hiding. Keyed by
  /// [Channel.rawId].
  Set<String> hiddenChannels = {};

  /// See [AppConstants.keyEpgIdOverrides]'s doc comment. Keyed by
  /// [Channel.rawId] -> the assigned EPG id; stamped onto each matching
  /// `Channel.epgIdOverride` wherever this session (re)builds its channel
  /// lists (the same loops that stamp `isFavorite`).
  Map<String, String> epgIdOverrides = {};

  /// See [AppConstants.keyChannelLinks]'s doc comment. Keyed by
  /// [Channel.rawId] -> the linked channel elsewhere. Unlike
  /// [epgIdOverrides]/[hiddenChannels], not stamped onto the `Channel`
  /// objects themselves — nothing reads a link off a `Channel` directly,
  /// every lookup goes through `PlaylistManager.channelLinkFor` instead,
  /// so there's no per-channel field to keep in sync on every rebuild.
  Map<String, ChannelLink> channelLinks = {};

  /// See [AppConstants.keyAutoPairedChannelLinks]/
  /// [AppConstants.keyAutoPairedEpgOverrides]'s doc comment — which
  /// entries in [channelLinks]/[epgIdOverrides] were set by "Auto-Pair
  /// Channels" rather than picked by hand, so "Unpair Channels" knows
  /// exactly what it's allowed to undo.
  Set<String> autoPairedChannelLinks = {};
  Set<String> autoPairedEpgOverrides = {};

  // --- M3U-mode state ---------------------------------------------------
  List<Channel> _channels = [];
  List<Channel> get channels => _channels;
  set channels(List<Channel> value) {
    _channels = value;
    _m3uIndex = null;
  }

  Map<String, List<Channel>>? _m3uIndex;
  Map<String, List<Channel>> get _m3uGroups =>
      _m3uIndex ??= _indexGroups(channels);

  static Map<String, List<Channel>> _indexGroups(List<Channel> source) {
    final groups = <String, List<Channel>>{};
    for (final channel in source) {
      groups.putIfAbsent(channel.group, () => []).add(channel);
    }
    return groups;
  }

  /// Prepare a replacement off the active catalogue, yielding between small
  /// chunks. Publish atomically so readers never see a partially indexed list.
  Future<void> _installLiveCatalogue(List<Channel> loaded,
      {required bool xtream}) async {
    final groups = <String, List<Channel>>{};
    var count = 0;
    for (final channel in loaded) {
      groups.putIfAbsent(channel.group, () => []).add(channel);
      if (++count % 1024 == 0) await Future<void>.delayed(Duration.zero);
    }
    // Read viewer state after yielding: a profile may have changed meanwhile.
    final favorites = favoriteIds();
    for (final channel in loaded) {
      channel.isFavorite = favorites.contains(channel.id);
      channel.epgIdOverride = epgIdOverrides[channel.rawId];
    }
    if (xtream) {
      liveChannels = loaded;
      _liveIndex = groups;
    } else {
      channels = loaded;
      _m3uIndex = groups;
    }
  }

  // --- Xtream-mode state --------------------------------------------------
  CatalogApi? catalogApi;
  List<Channel> _liveChannels = [];
  List<Channel> get liveChannels => _liveChannels;
  set liveChannels(List<Channel> value) {
    _liveChannels = value;
    _liveIndex = null;
  }

  Map<String, List<Channel>>? _liveIndex;
  Map<String, List<Channel>> get _liveGroups =>
      _liveIndex ??= _indexGroups(liveChannels);
  List<XtreamCategory> liveCategories = [];
  List<XtreamCategory> vodCategories = [];
  List<XtreamCategory> seriesCategories = [];
  final Map<String, String> vodCategoryIdByName = {};
  final Map<String, String> seriesCategoryIdByName = {};
  final Map<String, List<Channel>> vodByCategoryName = {};
  final Map<String, List<XtreamSeries>> seriesByCategoryName = {};
  // A category's true item count, independent of _maxItemsPerCategory's
  // display cap — the full set is always fetched from the network and
  // saved to the database (see _persistVodCategory/_persistSeriesCategory)
  // regardless of the cap, but vodByCategoryName/seriesByCategoryName
  // themselves only ever hold up to the cap, so there was previously no
  // way for the UI to show a category's real size. See
  // vodCategoryTotalCount/seriesCategoryTotalCount.
  final Map<String, int> vodCategoryTotalCount = {};
  final Map<String, int> seriesCategoryTotalCount = {};
  final Set<String> loadingCategoryNames = {};
  // Which tab category ('vod'/'series') currently has a self-sustaining
  // ensureCategoriesLoaded worker pool running — see that method's doc
  // comment for the bug this exists to fix (a rebuild-dependent design
  // that could silently stall for minutes once the browse screen simply
  // stopped being rebuilt).
  final Set<String> categoriesLoadingActive = {};

  /// Bound category retries per session. Rebuilds must not repeatedly retry failed requests;
  /// an explicit refresh resets the failure counts.
  final Map<String, int> categoryFailureCounts = {};
  static const int _maxCategoryFailures = 2;

  /// Caps how many items of a single category are held in memory/rendered
  /// at once — even with a real on-disk database, a single oversized
  /// category (some providers bundle thousands of items under one
  /// "24/7"-style category) can still be enough to strain a
  /// memory-constrained device by itself, since the whole category is
  /// still materialized into Dart objects the moment it's opened. This is
  /// a blunt cap (silently truncates), not real pagination (load-more-on-
  /// scroll) — a full pagination UI is a bigger follow-up; this at least
  /// puts a ceiling on the worst case. The *database* still stores the
  /// full category, so raising this cap later doesn't need a re-fetch
  /// from the network.
  static const int _maxItemsPerCategory = 300;

  bool get hasCatalog => profile.hasCatalog;

  /// Bound category request concurrency using account metadata when available, with a
  /// conservative fallback of three.
  int get _categoryConcurrency {
    final accountLimit = catalogApi?.maxConnections;
    return accountLimit == null ? 3 : accountLimit.clamp(1, 3);
  }

  /// The in-flight (or completed) [ensureLiveChannelsLoaded] load, shared
  /// across every caller — see that method's doc comment for why this
  /// needs to be a shared Future rather than a plain boolean guard.
  Future<void>? liveChannelsFuture;

  bool isGroupFavorited(String title) => favoritedGroups.contains(title);

  /// Every cache file this playlist owns is namespaced by its profile id
  /// — the whole reason a second playlist's cache can't collide with the
  /// first's (or, on upgrade, why a pre-multi-playlist cache file is never
  /// looked up again under its new suffixed name — see
  /// `Channel.fromJson`'s doc comment).
  String _cacheName(String base) => '${base}_${profile.id}';

  List<Channel> get allCachedVod =>
      vodByCategoryName.values.expand((l) => l).toList();
  List<XtreamSeries> get allCachedSeries =>
      seriesByCategoryName.values.expand((l) => l).toList();

  int? vodCategoryTotalCountFor(String categoryName) =>
      vodCategoryTotalCount[categoryName];
  int? seriesCategoryTotalCountFor(String categoryName) =>
      seriesCategoryTotalCount[categoryName];

  /// Reload persisted visibility and order without fetching catalogue data.
  void _loadViewerScopedState() {
    favoritedGroups = storage.getFavoritedGroups(profile.id);
    groupOrder = {
      for (final type in const ['tv', 'vod', 'series'])
        type: storage.getGroupOrder(profile.id, type),
    };
    hiddenChannels = storage.getHiddenChannels(profile.id);

    hiddenGroups = storage.getHiddenGroupsForType(profile.id, 'tv');
    for (final type in ['vod', 'series']) {
      _libraryHiddenGroups[type] =
          storage.getHiddenGroupsForType(profile.id, type);
    }
  }

  /// Called by `PlaylistManager.applyActiveViewer` whenever the active
  /// viewer changes — reloads this playlist's favorited/hidden-groups/
  /// hidden-channels state for whichever viewer is active now, without
  /// touching anything network-related (categories/channels already loaded
  /// stay loaded; only which of them count as hidden changes).
  void reloadViewerState() => _loadViewerScopedState();

  /// Re-stamps every already-loaded [Channel]/[XtreamSeries]' `isFavorite`
  /// flag against [favoriteIds]/[favoriteSeriesIds]' *current* value —
  /// called by `PlaylistManager.applyActiveViewer` right after a viewer
  /// switch, since those two callbacks just started returning the
  /// newly-active viewer's own favorites, but every object already sitting
  /// in memory still carries whichever viewer's favorite state was true
  /// when it was first loaded (or last restamped).
  void restampFavorites() {
    final favs = favoriteIds();
    final seriesFavs = favoriteSeriesIds();
    for (final c in channels) {
      c.isFavorite = favs.contains(c.id);
    }
    for (final c in liveChannels) {
      c.isFavorite = favs.contains(c.id);
    }
    for (final list in vodByCategoryName.values) {
      for (final c in list) {
        c.isFavorite = favs.contains(c.id);
      }
    }
    for (final list in seriesByCategoryName.values) {
      for (final s in list) {
        s.isFavorite = seriesFavs.contains(s.id);
      }
    }
  }

  Future<void> _visibilityWrite = Future.value();
  Future<void> _applyGroupHiddenChange(Iterable<String> titles, bool hidden,
      {String type = 'tv'}) {
    final captured = titles.toList();
    final write = _visibilityWrite.then((_) async {
      for (final libraryType in ['vod', 'series']) {
        _libraryHiddenGroups.putIfAbsent(libraryType, () => {...hiddenGroups});
      }
      final next = {...hiddenGroupsForType(type)};
      if (hidden) {
        next.addAll(captured);
      } else {
        next.removeAll(captured);
      }
      await storage.setHiddenGroupsForType(profile.id, type, next);
      if (type == 'tv') {
        hiddenGroups = next;
      } else {
        _libraryHiddenGroups[type] = next;
      }
    });
    _visibilityWrite = write.then<void>((_) {}, onError: (Object _) {});
    return write;
  }

  // --- Startup: restore from cache, or do a fresh load ---------------------

  /// Restores this playlist from its on-disk cache, or does a fresh
  /// network load if there's no cache yet. Returns once *something* is
  /// showable (cache hit or fresh load finished/failed).
  Future<void> restoreOrLoad() async {
    epgIdOverrides = storage.getEpgIdOverrides(profile.id);
    channelLinks = storage.getChannelLinks(profile.id);
    autoPairedChannelLinks = storage.getAutoPairedChannelLinks(profile.id);
    autoPairedEpgOverrides = storage.getAutoPairedEpgOverrides(profile.id);

    // Compute viewer-scoped visibility after categories have loaded. An empty pre-load
    // category set cannot correctly apply a restricted viewer's allowlist.
    try {
      if (hasCatalog) {
        catalogApi?.dispose();
        if (profile.isStalker) {
          catalogApi = StalkerPortalService(profile);
        } else {
          final server = profile.serverCandidates.firstOrNull;
          final username = profile.xtreamUsername;
          final password = profile.xtreamPassword;
          if (server == null || username == null || password == null) return;
          catalogApi = XtreamApiService(
              server: server,
              username: username,
              password: password,
              userAgent: profile.userAgent,
              playlistId: profile.id);
        }
        if (!profile.includeLive) {
          liveChannels = [];
          liveCategories = [];
          _liveIndex = {};
          // A library-only source never adds channels or blocks startup on a
          // provider request. Categories are fetched when a library is opened.
          return;
        }
        final cacheMatches = !profile.isStalker ||
            storage.getPortalCacheIdentity(profile.id) ==
                portalConnectionIdentity(profile);
        if (cacheMatches && await _restoreXtreamCache()) return;
        await loadFromCatalog();
        return;
      }

      final url = profile.m3uUrl;
      if (url == null || url.isEmpty) return;
      if (await _restoreM3uCache()) return;
      await loadFromUrl(url);
    } finally {
      _loadViewerScopedState();
    }
  }

  // --- M3U mode -----------------------------------------------------------

  static const _categoryPreviewFile = 'm3u_category_preview';
  List<String>? _previewTitles;
  String? _previewSource;

  String _categoryPreviewSource(String url) =>
      sha256.convert(utf8.encode(url)).toString();

  /// Only category names: the sidebar can organise itself while the large
  /// channel file decodes on its worker. Visibility and order stay viewer-local.
  Future<void> _restoreM3uCategoryPreview(String url) async {
    try {
      final raw = await storage.readCacheFile(_cacheName(_categoryPreviewFile));
      if (raw == null || raw.length > 256 * 1024) return;
      final value = jsonDecode(raw);
      if (value is! Map ||
          value['version'] != 1 ||
          value['source'] != _categoryPreviewSource(url)) {
        return;
      }
      final titles = value['titles'];
      if (titles is! List ||
          titles.length > 4096 ||
          titles.any((t) => t is! String || t.length > 512)) {
        return;
      }
      final names = titles.cast<String>().toList(growable: false);
      if (names.toSet().length != names.length || profile.m3uUrl != url) return;
      _previewTitles = names;
      _previewSource = value['source'] as String;
      _m3uIndex = {for (final title in names) title: const <Channel>[]};
      _loadViewerScopedState();
      if (names.isNotEmpty) onNotify();
    } catch (_) {
      // Optional metadata must never prevent the authoritative cache loading.
    }
  }

  Future<void> _saveM3uCategoryPreview(String url) async {
    final names = _m3uGroups.keys.toList(growable: false);
    final source = _categoryPreviewSource(url);
    if ((source == _previewSource && listEquals(names, _previewTitles)) ||
        names.length > 4096 ||
        names.any((name) => name.length > 512)) {
      return;
    }
    final raw = jsonEncode({
      'version': 1,
      'source': source,
      'titles': names,
    });
    if (raw.length > 256 * 1024) return;
    try {
      await storage.writeCacheFile(_cacheName(_categoryPreviewFile), raw);
      _previewTitles = names;
      _previewSource = source;
    } catch (_) {
      // A failed preview write does not invalidate the channel catalogue.
    }
  }

  Future<bool> _restoreM3uCache() async {
    // Read, decode and parse all on a background isolate — this used to do
    // the lot on the main thread, for a list that can run to tens of
    // thousands of channels. See StorageService.cacheFilePath.
    final path = await storage
        .cacheFilePath(_cacheName(AppConstants.cacheFileM3uChannels));
    if (path == null) return false;
    try {
      final url = profile.m3uUrl ?? '';
      final restored = await Future.wait<Object?>([
        compute(_readChannelsFile, path),
        _restoreM3uCategoryPreview(url),
      ]);
      final loaded = restored.first as List<Channel>;
      await _installLiveCatalogue(loaded, xtream: false);
      unawaited(_saveM3uCategoryPreview(url));
      return true;
    } catch (e) {
      debugPrint(
          'PlaylistSession: failed to restore M3U cache: ${e.runtimeType}');
      return false;
    }
  }

  Future<void> loadFromUrl(String url) async {
    isLoading = true;
    error = null;
    lastLoadSummary = null;
    loadingPhase = tr('Connecting to server...');
    onNotify();

    try {
      final parsed = await M3uParser.fetchAndParse(url,
          playlistId: profile.id,
          liveOnly: true,
          headers: profile.requestHeaders);
      await _installLiveCatalogue(parsed, xtream: false);
      final counts = <String, int>{'tv': parsed.length, 'vod': 0, 'series': 0};
      lastLoadSummary = counts;
      lastLoaded = DateTime.now();
      profile = profile.copyWith(m3uUrl: url);
      await storage.writeCacheFile(
        _cacheName(AppConstants.cacheFileM3uChannels),
        await compute(_encodeChannels, parsed),
      );
      unawaited(_saveM3uCategoryPreview(url));

      loadingPhase = tr('Playlist added');
      onNotify();
    } catch (e) {
      error = e.toString();
      debugPrint('PlaylistSession error: ${e.runtimeType}');
    } finally {
      isLoading = false;
      loadingPhase = null;
      onNotify();
    }
    // See the matching call/comment at the end of loadFromCatalog.
    _loadViewerScopedState();
  }

  /// All groups, in first-seen order, including hidden ones (used by the
  /// Group Management screen). M3U mode only.
  List<M3uGroup> get allGroups {
    return _m3uGroups.entries
        .map((entry) => M3uGroup(
              title: entry.key,
              playlistId: profile.id,
              channels: entry.value,
              isHidden: hiddenGroups.contains(entry.key),
            ))
        .toList();
  }

  /// Imported M3U entries are live unless their IDs/routes explicitly mark
  /// on-demand content, which is filtered during import/restore.
  String _classifyGroup(String title) {
    return 'tv';
  }

  // --- Xtream mode ----------------------------------------------------------

  Future<void> _persistVodCategory(String categoryName, List<Channel> items) =>
      catalogDb.upsertVodCategory(profile.id, categoryName, items);

  Future<void> _persistSeriesCategory(
          String categoryName, List<XtreamSeries> items) =>
      catalogDb.upsertSeriesCategory(profile.id, categoryName, items);

  Future<bool> _restoreXtreamCache() async {
    try {
      final liveCatRaw = await storage
          .readCacheFile(_cacheName(AppConstants.cacheFileLiveCategories));
      if (liveCatRaw == null) return false;
      final vodCatRaw = AppConstants.onDemandEnabled
          ? await storage.readCacheFile(
                  _cacheName(AppConstants.cacheFileVodCategories)) ??
              '[]'
          : '[]';
      final seriesCatRaw = AppConstants.onDemandEnabled
          ? await storage.readCacheFile(
                  _cacheName(AppConstants.cacheFileSeriesCategories)) ??
              '[]'
          : '[]';

      final decoded = await compute(
        _decodeXtreamCategoriesBatch,
        _XtreamCategoriesRaw(
            liveCatRaw: liveCatRaw,
            vodCatRaw: vodCatRaw,
            seriesCatRaw: seriesCatRaw),
      );
      liveCategories = decoded.liveCategories;
      vodCategories = decoded.vodCategories;
      seriesCategories = decoded.seriesCategories;

      vodCategoryIdByName
        ..clear()
        ..addEntries(vodCategories.map((c) => MapEntry(c.name, c.id)));
      seriesCategoryIdByName
        ..clear()
        ..addEntries(seriesCategories.map((c) => MapEntry(c.name, c.id)));

      // Deliberately NOT restoring every cached category's items into
      // memory here — vodByCategoryName/seriesByCategoryName simply start
      // empty every launch, exactly like a fresh install;
      // ensureCategoryLoaded queries the local catalog database on demand
      // the moment a category is actually opened. See CatalogDatabase's
      // doc comment for the memory-capacity problem this avoids.

      lastLoadSummary = {
        'tv': liveChannels.length,
        'vod': vodCategories.length,
        'series': seriesCategories.length,
      };
      return true;
    } catch (e) {
      debugPrint(
          'PlaylistSession: failed to restore Xtream cache: ${e.runtimeType}');
      return false;
    }
  }

  /// Load live channels on demand and share the in-flight Future with all callers.
  /// Awaiting callers must wait for the same load rather than search a still-empty list;
  /// completed loads return immediately.
  Future<void> ensureLiveChannelsLoaded() {
    if (!hasCatalog || liveChannels.isNotEmpty) return Future<void>.value();
    return liveChannelsFuture ??= _loadLiveChannelsOnce();
  }

  Future<void> _loadLiveChannelsOnce() async {
    // Keep lazy live-channel loading independent of the foreground add/edit isLoading flag.
    // Background callers can run while playlist setup is still authenticating.
    await Future<void>.delayed(Duration.zero);
    onNotify();
    try {
      List<Channel> loaded;
      // Path, not contents — see StorageService.cacheFilePath.
      final path = await storage
          .cacheFilePath(_cacheName(AppConstants.cacheFileLiveChannels));
      if (path != null) {
        loaded = await compute(_readChannelsFile, path);
      } else {
        final api = catalogApi;
        if (api == null) return;
        final categoryNames = {for (final c in liveCategories) c.id: c.name};
        loaded = await api.getLiveStreams(categoryNames: categoryNames);
        await storage.writeCacheFile(
          _cacheName(AppConstants.cacheFileLiveChannels),
          await compute(_encodeChannels, loaded),
        );
      }
      await _installLiveCatalogue(loaded, xtream: true);
      lastLoadSummary = {...?lastLoadSummary, 'tv': liveChannels.length};
    } catch (e) {
      debugPrint(
          'PlaylistSession: failed to load live channels: ${e.runtimeType}');
      liveChannelsFuture = null; // allow a retry on the next access
    } finally {
      onNotify();
    }
  }

  /// How long to wait before trying the next server in the list. Only
  /// ever waited *between* attempts, never before the first or after the
  /// last — the point is to not machine-gun a provider's whole set of
  /// hostnames in the same instant, not to add latency for its own sake.
  static const _backupServerDelay = Duration(seconds: 3);

  /// Authenticates against [PlaylistProfile.serverCandidates] in order,
  /// returning the first one that answers. With no backups configured
  /// this is exactly the old single-server behaviour, message for
  /// message; the per-attempt reporting only appears once there's
  /// actually more than one server to talk about.
  ///
  /// A server that answers and *rejects* the account (bad credentials,
  /// expired/disabled subscription) stops the walk immediately instead of
  /// cycling through every backup — that server was reachable, so the
  /// problem follows the account to every other hostname too, and
  /// burying "your subscription expired" under a minute of fallback
  /// attempts helps nobody.
  Future<CatalogApi> _connectWithFallback() async {
    if (profile.isStalker) {
      final api = StalkerPortalService(profile);
      try {
        await api.authenticate();
        return api;
      } catch (_) {
        api.dispose();
        rethrow;
      }
    }
    final candidates = profile.serverCandidates;
    final username = profile.xtreamUsername!;
    final password = profile.xtreamPassword!;
    Object? lastError;

    for (var i = 0; i < candidates.length; i++) {
      final server = candidates[i];
      final label = _hostLabel(server);
      if (candidates.length > 1) {
        loadingPhase = tr('Connecting to {label} ({p}/{candidates})...',
            {'label': label, 'p': i + 1, 'candidates': candidates.length});
        onNotify();
      }
      try {
        final api = XtreamApiService(
            server: server,
            username: username,
            password: password,
            userAgent: profile.userAgent,
            playlistId: profile.id);
        await api.authenticate();
        if (candidates.length > 1) {
          loadingPhase = tr('Connected to {label}', {'label': label});
          onNotify();
        }
        await _rememberWorkingServer(server);
        return api;
      } catch (e) {
        lastError = e;
        if (_isAccountRejection(e)) rethrow;
        if (candidates.length > 1) {
          loadingPhase = tr(
              'Connecting to {label} ({p}/{candidates})... failed',
              {'label': label, 'p': i + 1, 'candidates': candidates.length});
          onNotify();
        }
        final hasMore = i < candidates.length - 1;
        if (hasMore) await Future<void>.delayed(_backupServerDelay);
      }
    }
    throw lastError ?? Exception('No server configured for this playlist');
  }

  /// Persisted so the next launch starts from whatever actually answered
  /// rather than re-walking a primary that's been down for days. Direct
  /// field assignment for the same reason [PlaylistProfile.expiresAt] uses
  /// one — see that field's doc comment.
  Future<void> _rememberWorkingServer(String server) async {
    if (profile.lastWorkingServer == server) return;
    profile.lastWorkingServer = server;
    final updated = storage
        .getPlaylists()
        .map((p) => p.id == profile.id ? profile : p)
        .toList();
    await storage.setPlaylists(updated);
  }

  Future<void> _commitPortalCache({bool keepLibraryMetadata = false}) async {
    if (!profile.isStalker) return;
    final identity = portalConnectionIdentity(profile);
    if (storage.getPortalCacheIdentity(profile.id) != identity) {
      await catalogDb.clearForPlaylist(profile.id);
      if (!profile.includeLive) {
        await storage
            .deleteCacheFile(_cacheName(AppConstants.cacheFileLiveCategories));
        await storage
            .deleteCacheFile(_cacheName(AppConstants.cacheFileLiveChannels));
      }
    }
    if (!keepLibraryMetadata) {
      await storage
          .deleteCacheFile(_cacheName(AppConstants.cacheFileVodCategories));
      await storage
          .deleteCacheFile(_cacheName(AppConstants.cacheFileSeriesCategories));
    }
    await storage.setPortalCacheIdentity(profile.id, identity);
  }

  Future<void> loadFromCatalog() async {
    isLoading = true;
    error = null;
    lastLoadSummary = null;
    loadingPhase = tr('Connecting to server...');
    onNotify();

    try {
      final api = await _connectWithFallback();
      catalogApi?.dispose();
      catalogApi = api;
      // Refreshed on every successful connect, not just once at add time —
      // a provider extending/changing an account's expiry should show
      // the current value on the next connect, not whatever it was when
      // this playlist was first added. See PlaylistProfile.expiresAt's
      // doc comment for why this can legitimately stay null.
      if (api.expiryDate != profile.expiresAt) {
        // Direct field assignment, not copyWith — expiresAt is mutable
        // for exactly this (like enabled/sortOrder elsewhere on this
        // class), and copyWith's `expiresAt ?? this.expiresAt` can't
        // distinguish "not specified" from "a provider stopped
        // reporting one," so it could never actually clear a stale value.
        profile.expiresAt = api.expiryDate;
        final updated = storage
            .getPlaylists()
            .map((p) => p.id == profile.id ? profile : p)
            .toList();
        await storage.setPlaylists(updated);
      }
      // Same reasoning/pattern as expiresAt just above — see
      // PlaylistProfile.maxConnections' own doc comment for why this is
      // worth persisting and surfacing to the user at all.
      if (api.maxConnections != profile.maxConnections) {
        profile.maxConnections = api.maxConnections;
        final updated = storage
            .getPlaylists()
            .map((p) => p.id == profile.id ? profile : p)
            .toList();
        await storage.setPlaylists(updated);
      }

      if (!profile.includeLive) {
        liveChannels = [];
        liveCategories = [];
        _liveIndex = {};
        _libraryCategoriesReady = false;
        if (profile.isStalker) {
          vodCategories = [];
          seriesCategories = [];
        }
        await ensureLibraryCategories(refresh: true);
        await _commitPortalCache(keepLibraryMetadata: true);
        lastLoaded = DateTime.now();
        return;
      }
      final loadedCategories = await api.getLiveCategories();
      final liveCategoryNames = {
        for (final c in loadedCategories) c.id: c.name
      };

      loadingPhase = tr('Finding live channels...');
      onNotify();
      final loadedLive = api is StalkerPortalService
          ? await api.getLiveStreams(
              categoryNames: liveCategoryNames,
              onProgress: (count) {
                if (!isLoading || !identical(catalogApi, api)) return;
                loadingPhase = tr(
                    'Finding live channels... ({loadedLive} found)',
                    {'loadedLive': count});
                onNotify();
              })
          : await api.getLiveStreams(categoryNames: liveCategoryNames);
      // Keep the previous groups with their channels if either request fails.
      liveCategories = loadedCategories;
      await _installLiveCatalogue(loadedLive, xtream: true);
      await storage.writeCacheFile(
        _cacheName(AppConstants.cacheFileLiveCategories),
        await compute(
            _encodeJsonList, loadedCategories.map((c) => c.toJson()).toList()),
      );
      await storage.writeCacheFile(
        _cacheName(AppConstants.cacheFileLiveChannels),
        await compute(_encodeChannels, loadedLive),
      );
      await _commitPortalCache();
      loadingPhase = tr('Finding live channels... ({loadedLive} found)',
          {'loadedLive': loadedLive.length});
      onNotify();

      // Library categories refresh on demand, independently of Live TV.
      _libraryCategoriesReady = false;
      _libraryLoaded.clear();
      vodCategories = [];
      seriesCategories = [];
      vodCategoryIdByName.clear();
      seriesCategoryIdByName.clear();
      vodByCategoryName.clear();
      seriesByCategoryName.clear();

      lastLoadSummary = {
        'tv': loadedLive.length,
        'vod': vodCategories.length,
        'series': seriesCategories.length,
      };
      lastLoaded = DateTime.now();

      loadingPhase = tr('Playlist added');
      onNotify();
    } catch (e) {
      error = e.toString();
      debugPrint('PlaylistSession error: ${e.runtimeType}');
    } finally {
      isLoading = false;
      loadingPhase = null;
      onNotify();
    }

    // Restore saved selections after a fresh category fetch.
    _loadViewerScopedState();

    // Library titles are loaded only when requested by a library screen.
  }

  Future<void>? _libraryCategoriesFlight;
  bool _libraryCategoriesReady = false;
  (bool, bool)? _librarySelection;
  final Map<String, Future<void>> _libraryFlights = {};
  final Set<String> _libraryLoaded = {};
  Future<void> _libraryQueue = Future.value();

  /// Only category names: never downloads all titles or touches Live TV.
  Future<void> ensureLibraryCategories({bool refresh = false}) {
    if (!hasCatalog || !AppConstants.onDemandEnabled) return Future.value();
    if (_libraryCategoriesFlight != null) return _libraryCategoriesFlight!;
    if (_libraryCategoriesReady &&
        !refresh &&
        _librarySelection == (profile.includeMovies, profile.includeSeries)) {
      return Future.value();
    }
    return _libraryCategoriesFlight = _fetchLibraryCategories(refresh)
        .whenComplete(() => _libraryCategoriesFlight = null);
  }

  Future<void> _fetchLibraryCategories(bool refresh) async {
    final api = catalogApi;
    if (api == null) return;
    if (profile.isStalker &&
        storage.getPortalCacheIdentity(profile.id) !=
            portalConnectionIdentity(profile)) {
      await api.authenticate();
      await _commitPortalCache();
      vodCategories = [];
      seriesCategories = [];
      _libraryLoaded.clear();
    }
    // Sequential metadata calls respect small providers and low-memory TVs.
    if (profile.includeMovies && (refresh || vodCategories.isEmpty)) {
      final items = await api.getVodCategories();
      await storage.writeCacheFile(
          _cacheName(AppConstants.cacheFileVodCategories),
          await compute(
              _encodeJsonList, items.map((c) => c.toJson()).toList()));
      vodCategories = items;
      vodCategoryIdByName
        ..clear()
        ..addEntries(items.map((c) => MapEntry(c.name, c.id)));
    }
    if (profile.includeSeries && (refresh || seriesCategories.isEmpty)) {
      final items = await api.getSeriesCategories();
      await storage.writeCacheFile(
          _cacheName(AppConstants.cacheFileSeriesCategories),
          await compute(
              _encodeJsonList, items.map((c) => c.toJson()).toList()));
      seriesCategories = items;
      seriesCategoryIdByName
        ..clear()
        ..addEntries(items.map((c) => MapEntry(c.name, c.id)));
    }
    _libraryCategoriesReady = true;
    _librarySelection = (profile.includeMovies, profile.includeSeries);
    _loadViewerScopedState();
    (onLibraryNotify ?? onNotify)();
  }

  /// One in-flight request per category, one provider request at a time.
  /// Titles stay in SQLite, not a growing in-memory copy of every category.
  Future<void> loadLibraryCategory(String name, String type,
      {bool refresh = false}) {
    if ((type == 'vod' && !profile.includeMovies) ||
        (type == 'series' && !profile.includeSeries)) {
      return Future.value();
    }
    final key = _loadKey(type, name);
    final running = _libraryFlights[key];
    if (running != null) return running;
    if (!refresh && _libraryLoaded.contains(key)) return Future.value();
    return _libraryFlights[key] =
        _loadLibraryCategory(name, type, key, refresh: refresh)
            .whenComplete(() {
      _libraryFlights.remove(key);
    });
  }

  Future<void> _loadLibraryCategory(String name, String type, String key,
      {required bool refresh}) async {
    // A saved category must not wait behind another category's slow network
    // request. Only downloads/writes share the provider queue; local reads
    // are independent, and the per-category flight still deduplicates callers.
    if (!refresh) {
      final count = type == 'vod'
          ? await catalogDb.getVodCategoryCount(profile.id, name)
          : await catalogDb.getSeriesCategoryCount(profile.id, name);
      if (count > 0) {
        _libraryLoaded.add(key);
        return;
      }
    }
    final job = _libraryQueue.then((_) async {
      final api = catalogApi;
      final id =
          (type == 'vod' ? vodCategoryIdByName : seriesCategoryIdByName)[name];
      if (api == null || id == null) {
        throw StateError('Category is unavailable');
      }
      if (type == 'vod') {
        final items = await api.getVodStreams(id, name);
        await _persistVodCategory(name, items);
        vodByCategoryName.remove(name);
      } else {
        final items = await api.getSeriesForCategory(id);
        await _persistSeriesCategory(name, items);
        seriesByCategoryName.remove(name);
      }
      _libraryLoaded.add(key);
    });
    _libraryQueue =
        job.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    await job;
  }

  /// Fetches a VOD or series category's items the first time it's opened,
  /// then caches them (in memory for the rest of the session, and to the
  /// local catalog database). No-ops for live (already loaded whole) and
  /// for categories already cached in memory this session.
  Future<void> ensureCategoryLoaded(
      String categoryName, String tabCategory) async {
    if (!AppConstants.onDemandEnabled || tabCategory == 'tv') return;
    if (tabCategory == 'vod' && vodByCategoryName.containsKey(categoryName)) {
      return;
    }
    if (tabCategory == 'series' &&
        seriesByCategoryName.containsKey(categoryName)) {
      return;
    }
    final key = _loadKey(tabCategory, categoryName);
    if (loadingCategoryNames.contains(key)) return;
    if ((categoryFailureCounts[key] ?? 0) >= _maxCategoryFailures) return;

    loadingCategoryNames.add(key);
    isLoading = true;
    onNotify();

    try {
      if (tabCategory == 'vod') {
        final cached = await catalogDb.getVodCategory(profile.id, categoryName,
            limit: _maxItemsPerCategory);
        if (cached.isNotEmpty) {
          vodByCategoryName[categoryName] = cached;
          vodCategoryTotalCount[categoryName] =
              await catalogDb.getVodCategoryCount(profile.id, categoryName);
          return;
        }
        final api = catalogApi;
        final categoryId = vodCategoryIdByName[categoryName];
        if (!hasCatalog || api == null || categoryId == null) return;
        final items = await api.getVodStreams(categoryId, categoryName);
        for (final channel in items) {
          channel.isFavorite = favoriteIds().contains(channel.id);
          channel.epgIdOverride = epgIdOverrides[channel.rawId];
        }
        await _persistVodCategory(categoryName, items);
        vodByCategoryName[categoryName] =
            items.take(_maxItemsPerCategory).toList();
        vodCategoryTotalCount[categoryName] = items.length;
      } else {
        final cached = await catalogDb.getSeriesCategory(
            profile.id, categoryName,
            limit: _maxItemsPerCategory);
        if (cached.isNotEmpty) {
          seriesByCategoryName[categoryName] = cached;
          seriesCategoryTotalCount[categoryName] =
              await catalogDb.getSeriesCategoryCount(profile.id, categoryName);
          return;
        }
        final api = catalogApi;
        final categoryId = seriesCategoryIdByName[categoryName];
        if (!hasCatalog || api == null || categoryId == null) return;
        final items = await api.getSeriesForCategory(categoryId);
        for (final series in items) {
          series.isFavorite = favoriteSeriesIds().contains(series.id);
        }
        await _persistSeriesCategory(categoryName, items);
        seriesByCategoryName[categoryName] =
            items.take(_maxItemsPerCategory).toList();
        seriesCategoryTotalCount[categoryName] = items.length;
      }
    } catch (e) {
      error = e.toString();
      debugPrint('PlaylistSession category load failed: ${e.runtimeType}');
      categoryFailureCounts[key] = (categoryFailureCounts[key] ?? 0) + 1;
    } finally {
      loadingCategoryNames.remove(key);
      isLoading = false;
      onNotify();
    }
  }

  String _loadKey(String tabCategory, String categoryName) =>
      '$tabCategory:$categoryName';

  /// Self-sustaining, concurrency-capped category worker pool. Keep one pool per tab so
  /// progress does not depend on unrelated widget rebuilds.
  Future<void> ensureCategoriesLoaded(
      Iterable<String> categoryNames, String tabCategory) async {
    if (!AppConstants.onDemandEnabled) return;
    if (categoriesLoadingActive.contains(tabCategory)) return;
    final namesList = categoryNames.toList();
    if (namesList.isEmpty) return;

    categoriesLoadingActive.add(tabCategory);
    final maxConcurrent = _categoryConcurrency;
    try {
      final loadedMap =
          tabCategory == 'vod' ? vodByCategoryName : seriesByCategoryName;
      var index = 0;
      Future<void> worker() async {
        while (index < namesList.length) {
          final name = namesList[index++];
          final key = _loadKey(tabCategory, name);
          if (loadedMap.containsKey(name) ||
              (categoryFailureCounts[key] ?? 0) >= _maxCategoryFailures) {
            continue;
          }
          await ensureCategoryLoaded(name, tabCategory);
        }
      }

      await Future.wait(List.generate(
          maxConcurrent.clamp(1, namesList.length), (_) => worker()));
    } finally {
      categoriesLoadingActive.remove(tabCategory);
    }
  }

  Future<bool> _loadOneVodCategory(CatalogApi api, XtreamCategory cat,
      {bool force = false}) async {
    final key = _loadKey('vod', cat.name);
    if ((!force && vodByCategoryName.containsKey(cat.name)) ||
        loadingCategoryNames.contains(key) ||
        (categoryFailureCounts[key] ?? 0) >= _maxCategoryFailures) {
      return !loadingCategoryNames.contains(key) &&
          (categoryFailureCounts[key] ?? 0) == 0;
    }
    loadingCategoryNames.add(key);
    try {
      final items = await api.getVodStreams(cat.id, cat.name);
      for (final channel in items) {
        channel.isFavorite = favoriteIds().contains(channel.id);
        channel.epgIdOverride = epgIdOverrides[channel.rawId];
      }
      await _persistVodCategory(cat.name, items);
      vodByCategoryName[cat.name] = items.take(_maxItemsPerCategory).toList();
      vodCategoryTotalCount[cat.name] = items.length;
      categoryFailureCounts.remove(key);
      return true;
    } catch (e) {
      debugPrint(
          'PlaylistSession: background load failed for movies: ${e.runtimeType}');
      categoryFailureCounts[key] = (categoryFailureCounts[key] ?? 0) + 1;
      return false;
    } finally {
      loadingCategoryNames.remove(key);
    }
  }

  Future<bool> _loadOneSeriesCategory(CatalogApi api, XtreamCategory cat,
      {bool force = false}) async {
    final key = _loadKey('series', cat.name);
    if ((!force && seriesByCategoryName.containsKey(cat.name)) ||
        loadingCategoryNames.contains(key) ||
        (categoryFailureCounts[key] ?? 0) >= _maxCategoryFailures) {
      return !loadingCategoryNames.contains(key) &&
          (categoryFailureCounts[key] ?? 0) == 0;
    }
    loadingCategoryNames.add(key);
    try {
      final items = await api.getSeriesForCategory(cat.id);
      for (final series in items) {
        series.isFavorite = favoriteSeriesIds().contains(series.id);
      }
      await _persistSeriesCategory(cat.name, items);
      seriesByCategoryName[cat.name] =
          items.take(_maxItemsPerCategory).toList();
      seriesCategoryTotalCount[cat.name] = items.length;
      categoryFailureCounts.remove(key);
      return true;
    } catch (e) {
      debugPrint(
          'PlaylistSession: background load failed for TV shows: ${e.runtimeType}');
      categoryFailureCounts[key] = (categoryFailureCounts[key] ?? 0) + 1;
      return false;
    } finally {
      loadingCategoryNames.remove(key);
    }
  }

  DateTime? _lastWarmupNotify;

  /// Notifying on every single category (up to 200+ times in a row) forces
  /// a full rebuild of whatever's on screen that many times in rapid
  /// succession — on weaker TV-box hardware that's enough rebuild pressure
  /// to make the UI thread choke badly enough to get killed. Progress at
  /// a few updates per second is visually indistinguishable from every
  /// single one, so throttle it; [force] still always notifies.
  void _notifyWarmupProgress({bool force = false}) {
    final now = DateTime.now();
    if (!force &&
        _lastWarmupNotify != null &&
        now.difference(_lastWarmupNotify!) <
            const Duration(milliseconds: 400)) {
      return;
    }
    _lastWarmupNotify = now;
    onNotify();
  }

  /// Walks every VOD/series category that isn't cached yet and isn't
  /// hidden, one at a time, fetching its items in the background.
  Future<void> warmAllCategories() => _warmCategories(force: false);

  /// Re-fetches every non-hidden VOD/series category's items, including
  /// ones already cached — the "Update content" action.
  Future<void> refreshAllCategories() => _warmCategories(force: true);

  /// True when this playlist hasn't had a *full* sync (every non-hidden
  /// category's items, not just category names/live channels) recently
  /// enough.
  bool needsFullSync() {
    if (!AppConstants.onDemandEnabled) return false;
    if (!hasCatalog) return false;
    final last = storage.getLastFullSyncAt(profile.id);
    if (last == null) return true;
    return DateTime.now().difference(last) >
        Duration(days: profile.syncFrequencyDays);
  }

  Future<void>? _fullSyncFlight;

  /// Share an explicit full update until its catalogue work has finished.
  Future<void> runFullCatalogSync() => _fullSyncFlight ??=
      _runFullCatalogSync().whenComplete(() => _fullSyncFlight = null);

  Future<void> _runFullCatalogSync() async {
    if (!hasCatalog) return;
    await loadFromCatalog();
    if (error != null) return;
    try {
      // Ordinary startup remains lazy; only an explicit full update loads
      // library metadata before walking the visible categories.
      await ensureLibraryCategories();
      await refreshAllCategories();
    } catch (e) {
      error = tr('Could not update the library. Please try again.');
      debugPrint('PlaylistSession: full update failed: ${e.runtimeType}');
      onNotify();
    }
  }

  Future<void> _warmCategories({required bool force}) async {
    if (!AppConstants.onDemandEnabled) return;
    if (isWarmingCatalog) return;

    final api = catalogApi;
    if (api == null) return;

    if (force) categoryFailureCounts.clear();

    try {
      final vodTodo = vodCategories
          .where((c) =>
              profile.includeMovies &&
              (force || !vodByCategoryName.containsKey(c.name)) &&
              !isGroupHidden(c.name, 'vod'))
          .toList();
      final seriesTodo = seriesCategories
          .where((c) =>
              profile.includeSeries &&
              (force || !seriesByCategoryName.containsKey(c.name)) &&
              !isGroupHidden(c.name, 'series'))
          .toList();
      final total = vodTodo.length + seriesTodo.length;
      var complete = true;
      if (total > 0) {
        isWarmingCatalog = true;
        warmCatalogDone = 0;
        warmCatalogTotal = total;
        vodCatalogDone = 0;
        vodCatalogTotal = vodTodo.length;
        seriesCatalogDone = 0;
        seriesCatalogTotal = seriesTodo.length;
        _notifyWarmupProgress(force: true);

        // Share the allowance across movies and series, rather than
        // allowing each content type to use the entire provider limit.
        var index = 0;
        Future<void> worker() async {
          while (index < total) {
            final next = index++;
            final isVod = next < vodTodo.length;
            final success = isVod
                ? await _loadOneVodCategory(api, vodTodo[next], force: force)
                : await _loadOneSeriesCategory(
                    api, seriesTodo[next - vodTodo.length],
                    force: force);
            complete = complete && success;
            if (isVod) {
              vodCatalogDone++;
            } else {
              seriesCatalogDone++;
            }
            warmCatalogDone++;
            _notifyWarmupProgress();
          }
        }

        await Future.wait(List.generate(
            _categoryConcurrency.clamp(1, total), (_) => worker()));
      }
      if (complete) {
        await storage.setLastFullSyncAt(profile.id, DateTime.now());
      } else if (force) {
        error = tr('Some categories could not be updated. Please try again.');
      }
    } catch (e) {
      if (force) error = tr('Could not update the library. Please try again.');
      debugPrint('PlaylistSession: catalog warm-up failed: ${e.runtimeType}');
    } finally {
      isWarmingCatalog = false;
      _notifyWarmupProgress(force: true);
    }
  }

  // Only pending work is shared. A different connection or plot-only query
  // gets its own result, and failures are removed so a later visit can retry.
  final _episodeLoads =
      <(CatalogApi, int, String, bool), Future<SeriesEpisodesResult>>{};
  final _vodInfoLoads = <(CatalogApi, String), Future<VodDetails>>{};

  /// Fetches episodes for one series, grouped by season number.
  Future<SeriesEpisodesResult> loadSeriesEpisodes(XtreamSeries series,
      {bool plotOnly = false}) {
    final api = catalogApi;
    if (api == null) {
      return Future.value(
          (episodes: <int, List<Channel>>{}, plot: null, details: null));
    }
    final key = (api, series.seriesId, series.name, plotOnly);
    return _episodeLoads.putIfAbsent(
        key,
        () => _loadSeriesEpisodesOnce(api, series, plotOnly: plotOnly)
                .whenComplete(() {
              _episodeLoads.remove(key);
            }));
  }

  Future<SeriesEpisodesResult> _loadSeriesEpisodesOnce(
      CatalogApi api, XtreamSeries series,
      {required bool plotOnly}) async {
    final result = await api.getSeriesEpisodes(series.seriesId, series.name,
        plotOnly: plotOnly);
    for (final list in result.episodes.values) {
      for (final channel in list) {
        channel.isFavorite = favoriteIds().contains(channel.id);
        channel.epgIdOverride = epgIdOverrides[channel.rawId];
        channel.seriesId = series.seriesId;
        channel.seriesName = series.name;
        channel.seriesCoverUrl = series.coverUrl;
      }
    }
    return result;
  }

  /// Movie plot/description — [rawStreamId] is `Channel.rawId` with its
  /// `xt_vod_` prefix already stripped by the caller (`PlaylistManager
  /// .getVodDescription`).
  Future<String?> getVodDescription(String rawStreamId) async {
    final api = catalogApi;
    if (api == null) return null;
    return api.getVodDescription(rawStreamId);
  }

  /// [getVodDescription] plus the provider's HD poster/backdrop from the
  /// same `get_vod_info` response.
  Future<VodDetails> getVodInfo(String rawStreamId) {
    final api = catalogApi;
    if (api == null) return Future.value(VodDetails.empty);
    final key = (api, rawStreamId);
    return _vodInfoLoads.putIfAbsent(
        key,
        () => api.getVodInfo(rawStreamId).whenComplete(() {
              _vodInfoLoads.remove(key);
            }));
  }

  /// Applies [groupOrder] for [type]: titles the user has ordered come
  /// first in that order, anything not in it yet (e.g. a category the
  /// provider added since) follows in provider order.
  List<M3uGroup> _ordered(String type, List<M3uGroup> groups) {
    final order = groupOrder[type];
    if (order == null || order.isEmpty) return groups;
    final byTitle = <String, List<M3uGroup>>{};
    for (final g in groups) {
      (byTitle[g.title] ??= []).add(g);
    }
    final result = <M3uGroup>[];
    for (final title in order) {
      final matches = byTitle.remove(title);
      if (matches != null) result.addAll(matches);
    }
    for (final g in groups) {
      if (byTitle.containsKey(g.title)) result.add(g);
    }
    return result;
  }

  /// Moves [title] by [delta] places among the *visible* (non-hidden)
  /// groups of [type] — a hidden neighbour in between would otherwise make
  /// a press look like it did nothing. Clamped to the ends, so a big
  /// negative delta means "move to top". Returns the new visible index, or
  /// null if [title] isn't a visible group of [type]. [shown], when given,
  /// is the exact list of titles on screen (the Movies/TV Shows rail also
  /// leaves out categories that haven't loaded anything yet) and is used
  /// as the "visible" list instead.
  Future<int?> moveGroup(String type, String title, int delta,
      {List<String>? shown}) async {
    final all = switch (type) {
      'tv' => tvGroups,
      'vod' => vodGroups,
      _ => seriesGroups,
    }
        .map((g) => g.title)
        .toSet()
        .toList();
    // Order always comes from [all] (the current saved order); [shown] only
    // decides membership, so a stale copy from a quick double-press is fine.
    final shownSet = shown?.toSet();
    final visible = all
        .where((t) =>
            shownSet != null ? shownSet.contains(t) : !isGroupHidden(t, type))
        .toList();
    final from = visible.indexOf(title);
    if (from < 0) return null;
    final to = (from + delta).clamp(0, visible.length - 1);
    if (to == from) return from;
    final anchor = visible[to];
    all.remove(title);
    final anchorIndex = all.indexOf(anchor);
    all.insert(delta < 0 ? anchorIndex : anchorIndex + 1, title);
    groupOrder[type] = all;
    await storage.setGroupOrder(profile.id, type, all);
    onNotify();
    return to;
  }

  List<M3uGroup> get tvGroups => _ordered('tv', _providerTvGroups);

  List<M3uGroup> get _providerTvGroups {
    if (hasCatalog) {
      return liveCategories
          .map((c) => M3uGroup(
                title: c.name,
                playlistId: profile.id,
                channels: const [],
                isHidden: hiddenGroups.contains(c.name),
              ))
          .toList();
    }
    return allGroups;
  }

  List<M3uGroup> get vodGroups => _ordered('vod', _providerVodGroups);

  List<M3uGroup> get _providerVodGroups {
    if (!profile.includeMovies) return const [];
    if (hasCatalog) {
      return vodCategories
          .map((c) => M3uGroup(
                title: c.name,
                playlistId: profile.id,
                channels: vodByCategoryName[c.name] ?? const [],
                isHidden: isGroupHidden(c.name, 'vod'),
              ))
          .toList();
    }
    return allGroups
        .where((g) => _classifyGroup(g.title) == 'vod')
        .map((g) => M3uGroup(
            title: g.title,
            playlistId: g.playlistId,
            channels: g.channels,
            isHidden: isGroupHidden(g.title, 'vod')))
        .toList();
  }

  List<M3uGroup> get seriesGroups => _ordered('series', _providerSeriesGroups);

  List<M3uGroup> get _providerSeriesGroups {
    if (!profile.includeSeries) return const [];
    if (hasCatalog) {
      return seriesCategories
          .map((c) => M3uGroup(
                title: c.name,
                playlistId: profile.id,
                channels: const [],
                isHidden: isGroupHidden(c.name, 'series'),
              ))
          .toList();
    }
    return allGroups
        .where((g) => _classifyGroup(g.title) == 'series')
        .map((g) => M3uGroup(
            title: g.title,
            playlistId: g.playlistId,
            channels: g.channels,
            isHidden: isGroupHidden(g.title, 'series')))
        .toList();
  }

  List<Channel> visibleChannels(
      {String? groupTitle, required String category}) {
    if (hasCatalog) {
      switch (category) {
        case 'tv':
          final list = groupTitle != null
              ? (_liveGroups[groupTitle] ?? const <Channel>[])
              : liveChannels.where((c) => !hiddenGroups.contains(c.group));
          // Applied even when a specific group was asked for (unlike
          // hiddenGroups above) — a hidden channel is usually a
          // duplicate *within* an otherwise-wanted group, so hiding the
          // whole group isn't the option the user actually wants.
          return list.where((c) => !hiddenChannels.contains(c.rawId)).toList();
        case 'vod':
          return groupTitle != null
              ? (vodByCategoryName[groupTitle] ?? const [])
              : vodByCategoryName.entries
                  .where((e) => !isGroupHidden(e.key, 'vod'))
                  .expand((e) => e.value)
                  .toList();
        default:
          return const [];
      }
    }

    if (groupTitle != null) {
      final list = _m3uGroups[groupTitle] ?? const <Channel>[];
      return (category == 'tv'
              ? list.where((c) => !hiddenChannels.contains(c.rawId))
              : list)
          .toList();
    }
    return channels
        .where((c) =>
            category == 'tv' &&
            !hiddenGroups.contains(c.group) &&
            (category != 'tv' || !hiddenChannels.contains(c.rawId)))
        .toList();
  }

  Future<int> hideNonThaiEntries() async {
    final ids = {
      for (final channel in hasCatalog ? liveChannels : channels)
        if (!hiddenGroups.contains(channel.group) &&
            isNonThaiEntryInThaiGroup(channel))
          channel.rawId,
    }.difference(hiddenChannels);
    if (ids.isEmpty) return 0;
    hiddenChannels.addAll(ids);
    await storage.setHiddenChannels(profile.id, hiddenChannels);
    onNotify();
    return ids.length;
  }

  Future<void> toggleChannelHidden(String rawId) async {
    if (hiddenChannels.contains(rawId)) {
      hiddenChannels.remove(rawId);
    } else {
      hiddenChannels.add(rawId);
    }
    await storage.setHiddenChannels(profile.id, hiddenChannels);
    onNotify();
  }

  /// [epgId] null clears the override (back to this channel's own rawId).
  /// Patches every already-loaded `Channel` with this [rawId] in place
  /// (both `channels` and `liveChannels` — one of them is always empty
  /// depending on mode, so this is safe to run unconditionally on both
  /// rather than needing to know which mode this session is in) rather
  /// than requiring a full reload for the change to show up anywhere.
  /// [isAuto] marks this as "Auto-Pair Channels"' own doing rather than a
  /// manual pick — see [autoPairedEpgOverrides]'s doc comment. A manual
  /// call (the ordinary picker screen's own default) always clears that
  /// mark, whether it's setting a fresh value or clearing one outright —
  /// either way this rawId is no longer "just an auto guess" once a
  /// person has looked at it.
  Future<void> setEpgIdOverride(String rawId, String? epgId,
      {bool isAuto = false}) async {
    if (epgId == null || epgId.isEmpty) {
      epgIdOverrides.remove(rawId);
    } else {
      epgIdOverrides[rawId] = epgId;
    }
    if (isAuto && epgId != null && epgId.isNotEmpty) {
      autoPairedEpgOverrides.add(rawId);
    } else {
      autoPairedEpgOverrides.remove(rawId);
    }
    await storage.setEpgIdOverrides(profile.id, epgIdOverrides);
    await storage.setAutoPairedEpgOverrides(profile.id, autoPairedEpgOverrides);
    for (final channel in channels) {
      if (channel.rawId == rawId) channel.epgIdOverride = epgIdOverrides[rawId];
    }
    for (final channel in liveChannels) {
      if (channel.rawId == rawId) channel.epgIdOverride = epgIdOverrides[rawId];
    }
    onNotify();
  }

  /// See [setChannelLinksBulk]'s doc comment — same fix, for EPG
  /// assignments instead of cross-playlist links. Also patches every
  /// affected `Channel.epgIdOverride` in one pass over each list (not
  /// once per entry in [newOverrides] — the same quadratic trap
  /// [setChannelLinksBulk] describes applies here just as much, since
  /// [setEpgIdOverride] above re-scans the *entire* channel list on
  /// every single call).
  Future<void> setEpgIdOverridesBulk(Map<String, String> newOverrides) async {
    if (newOverrides.isEmpty) return;
    epgIdOverrides.addAll(newOverrides);
    autoPairedEpgOverrides.addAll(newOverrides.keys);
    await storage.setEpgIdOverrides(profile.id, epgIdOverrides);
    await storage.setAutoPairedEpgOverrides(profile.id, autoPairedEpgOverrides);
    for (final channel in channels) {
      final id = newOverrides[channel.rawId];
      if (id != null) channel.epgIdOverride = id;
    }
    for (final channel in liveChannels) {
      final id = newOverrides[channel.rawId];
      if (id != null) channel.epgIdOverride = id;
    }
    onNotify();
  }

  Future<void> removeAutomaticGuideSource(String prefix) async {
    final removed = autoPairedEpgOverrides
        .where((id) => epgIdOverrides[id]?.startsWith(prefix) ?? false)
        .toSet();
    if (removed.isEmpty) return;
    final next = Map<String, String>.of(epgIdOverrides)
      ..removeWhere((id, _) => removed.contains(id));
    final automatic = autoPairedEpgOverrides.difference(removed);
    await storage.setEpgIdOverrides(profile.id, next);
    await storage.setAutoPairedEpgOverrides(profile.id, automatic);
    epgIdOverrides = next;
    autoPairedEpgOverrides = automatic;
    for (final channel in channels.followedBy(liveChannels)) {
      if (removed.contains(channel.rawId)) channel.epgIdOverride = null;
    }
    onNotify();
  }

  /// [link] null clears it. No per-`Channel` field to patch afterward —
  /// see [channelLinks]'s own doc comment for why this is simpler than
  /// [setEpgIdOverride] just above it. [isAuto]: see that same method's
  /// own doc comment.
  Future<void> setChannelLink(String rawId, ChannelLink? link,
      {bool isAuto = false}) async {
    if (link == null) {
      channelLinks.remove(rawId);
    } else {
      channelLinks[rawId] = link;
    }
    if (isAuto && link != null) {
      autoPairedChannelLinks.add(rawId);
    } else {
      autoPairedChannelLinks.remove(rawId);
    }
    await storage.setChannelLinks(profile.id, channelLinks);
    await storage.setAutoPairedChannelLinks(profile.id, autoPairedChannelLinks);
    onNotify();
  }

  /// Apply bulk channel links with one map write and one in-memory patch pass. Repeated
  /// single-link writes would serialize the growing map for every match.
  Future<void> setChannelLinksBulk(Map<String, ChannelLink> newLinks) async {
    if (newLinks.isEmpty) return;
    channelLinks.addAll(newLinks);
    autoPairedChannelLinks.addAll(newLinks.keys);
    await storage.setChannelLinks(profile.id, channelLinks);
    await storage.setAutoPairedChannelLinks(profile.id, autoPairedChannelLinks);
    onNotify();
  }

  List<XtreamSeries> visibleSeries(String? categoryName) {
    if (categoryName != null) {
      return seriesByCategoryName[categoryName] ?? const [];
    }
    return seriesByCategoryName.entries
        .where((e) => !isGroupHidden(e.key, 'series'))
        .expand((e) => e.value)
        .toList();
  }

  Future<void> setGroupFavorited(String title, bool favorited) async {
    if (favorited) {
      favoritedGroups.add(title);
    } else {
      favoritedGroups.remove(title);
    }
    await storage.setFavoritedGroups(profile.id, favoritedGroups);
    onNotify();
  }

  Future<void> toggleGroupHidden(String groupTitle) async {
    final hidden = !hiddenGroups.contains(groupTitle);
    await _applyGroupHiddenChange([groupTitle], hidden);
    onNotify();
  }

  Future<void> setGroupHidden(String groupTitle, bool hidden,
      {bool loadImmediately = true, String type = 'tv'}) async {
    await _applyGroupHiddenChange([groupTitle], hidden, type: type);
    (type == 'tv' ? onNotify : (onLibraryNotify ?? onNotify))();
    if (!hidden && loadImmediately) {
      unawaited(_loadIfNewlyShown(groupTitle, type));
    }
  }

  Future<void> setGroupsHidden(Iterable<String> groupTitles, bool hidden,
      {bool loadImmediately = true, String type = 'tv'}) async {
    await _applyGroupHiddenChange(groupTitles, hidden, type: type);
    (type == 'tv' ? onNotify : (onLibraryNotify ?? onNotify))();
    if (!hidden && loadImmediately) {
      for (final title in groupTitles) {
        unawaited(_loadIfNewlyShown(title, type));
      }
    }
  }

  Future<void> _loadIfNewlyShown(String groupTitle, String type) async {
    if (!hasCatalog) return;
    if (type == 'vod' && vodCategoryIdByName.containsKey(groupTitle)) {
      await ensureCategoryLoaded(groupTitle, 'vod');
    } else if (type == 'series' &&
        seriesCategoryIdByName.containsKey(groupTitle)) {
      await ensureCategoryLoaded(groupTitle, 'series');
    }
  }
}

// Top-level — required by `compute`, which runs this on a separate isolate
// with no access to instance state.
class _XtreamCategoriesRaw {
  const _XtreamCategoriesRaw({
    required this.liveCatRaw,
    required this.vodCatRaw,
    required this.seriesCatRaw,
  });
  final String liveCatRaw;
  final String vodCatRaw;
  final String seriesCatRaw;
}

class _XtreamCategoriesDecoded {
  const _XtreamCategoriesDecoded({
    required this.liveCategories,
    required this.vodCategories,
    required this.seriesCategories,
  });
  final List<XtreamCategory> liveCategories;
  final List<XtreamCategory> vodCategories;
  final List<XtreamCategory> seriesCategories;
}

_XtreamCategoriesDecoded _decodeXtreamCategoriesBatch(
    _XtreamCategoriesRaw raw) {
  final liveCategories = (jsonDecode(raw.liveCatRaw) as List)
      .map((e) => XtreamCategory.fromJson(e as Map<String, dynamic>))
      .toList();
  final vodCategories = (jsonDecode(raw.vodCatRaw) as List)
      .map((e) => XtreamCategory.fromJson(e as Map<String, dynamic>))
      .toList();
  final seriesCategories = (jsonDecode(raw.seriesCatRaw) as List)
      .map((e) => XtreamCategory.fromJson(e as Map<String, dynamic>))
      .toList();
  return _XtreamCategoriesDecoded(
    liveCategories: liveCategories,
    vodCategories: vodCategories,
    seriesCategories: seriesCategories,
  );
}

/// Isolate entry point: reads a cached channel list straight from disk, so
/// the file read and its UTF-8 decode happen off the main thread as well as
/// the JSON parse. See StorageService.cacheFilePath for why that matters.
List<Channel> _readChannelsFile(String path) {
  final channels = Channel.withUniqueIds(
      _decodeLiveChannelsBatch(File(path).readAsStringSync()));
  return channels.where((c) => !isOnDemandChannel(c)).toList();
}

String _encodeChannels(List<Channel> channels) =>
    jsonEncode(channels.map((c) => c.toJson()).toList());

List<Channel> _decodeLiveChannelsBatch(String raw) => (jsonDecode(raw) as List)
    .map((e) => Channel.fromJson(e as Map<String, dynamic>))
    .toList();

/// Serialize channel caches off the main isolate, matching the background decode path. Large
/// catalogues must not block UI updates while JSON is encoded.
String _encodeJsonList(List<Map<String, dynamic>> maps) => jsonEncode(maps);

/// Just the hostname for status messages — a full `http://host:8080` in
/// "Connecting to ..." reads as noise on a TV across the room.
String _hostLabel(String server) {
  final host = Uri.tryParse(server)?.host ?? '';
  return host.isEmpty ? tr('server') : host;
}

/// True when a server answered and turned the *account* away, as opposed
/// to not answering at all. See `PlaylistSession._connectWithFallback`
/// for why these cases differ. Typed XC errors retain this distinction
/// independently of their displayed message; older errors use the text fallback.
bool _isAccountRejection(Object error) {
  if (error is XtreamException) return error.accountRejected;
  final text = error.toString().toLowerCase();
  return text.contains('invalid xtream username') ||
      text.contains('account is not active');
}
