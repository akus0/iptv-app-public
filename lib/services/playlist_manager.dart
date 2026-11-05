import '../utils/guide_enrichment.dart';
import '../utils/playlist_user_agent.dart';
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import '../models/channel.dart';
import '../models/m3u_group.dart';
import '../models/playlist_profile.dart';
import '../models/series_details.dart';
import '../models/vod_details.dart';
import '../models/xtream_series.dart';
import '../utils/channel_name_matching.dart';
import '../utils/constants.dart';
import '../utils/live_category_folders.dart';
import '../utils/thai_epg.dart';
import 'catalog_database.dart';
import 'epg_service.dart';
import 'epg_database.dart' show EpgRow;
import 'playlist_session.dart';
import 'stalker_portal_service.dart';
import 'storage_service.dart';

/// Combines playlist sessions and dispatches catalogue, visibility and favourite
/// changes. M3U playlists supply live channels; Xtream libraries load categories
/// and titles on demand. Existing viewer storage namespaces remain compatible.
class PlaylistManager extends ChangeNotifier {
  PlaylistManager(this._storage, this._catalogDb);

  final StorageService _storage;
  final CatalogDatabase _catalogDb;

  bool _deferredNotifyPending = false;
  int _changeRevision = 0;
  int get changeRevision => _changeRevision;
  int _liveRevision = 0;
  int get liveRevision => _liveRevision;
  List<Channel>? _visibleLiveSnapshot;
  final Map<String, List<M3uGroup>> _groupSnapshots = {};
  final Map<(String, String), List<M3uGroup>> _playlistGroupSnapshots = {};

  /// Shared by the guide, sports matcher and player picker. Only live-catalogue
  /// changes invalidate this read-only view; library metadata cannot change it.
  List<Channel> get visibleLiveChannels => _visibleLiveSnapshot ??=
      List<Channel>.unmodifiable(visibleChannels(category: 'tv'));

  void notifyLibraryChanged() {
    _groupSnapshots.remove('vod');
    _groupSnapshots.remove('series');
    _playlistGroupSnapshots.removeWhere((key, _) => key.$2 != 'tv');
    _changeRevision++;
    _publishNotification();
  }

  /// Defer notifications raised during build, layout or paint until the frame ends.
  /// Synchronous mid-frame notifications can lose updates or trigger framework assertions in
  /// other listeners.
  @override
  void notifyListeners() {
    _groupSnapshots.clear();
    _playlistGroupSnapshots.clear();
    _changeRevision++;
    _liveRevision++;
    _visibleLiveSnapshot = null;
    _publishNotification();
  }

  void _publishNotification() {
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      if (_deferredNotifyPending) return;
      _deferredNotifyPending = true;
      SchedulerBinding.instance.addPostFrameCallback((_) {
        _deferredNotifyPending = false;
        super.notifyListeners();
      });
      return;
    }
    super.notifyListeners();
  }

  Set<String> _favoriteIds = {};
  Set<String> _favoriteSeriesIds = {};

  final List<PlaylistSession> _sessions = [];

  /// Whichever session a foreground operation (adding/editing/syncing one
  /// playlist) is currently running against — `CatalogSyncBody` and the
  /// back-compat single-session-shaped getters below all reflect this one
  /// session, not a merge across every playlist. Multiple playlists never
  /// load in the foreground simultaneously — the blocking "Updating
  /// Content" screen is mandatory for every playlist add/sync, first or
  /// not (see `AddPlaylistScreen`) — so there's only ever one meaningful
  /// answer to "what's loading right now" at the UI layer.
  PlaylistSession? _foregroundSession;

  /// Loading state during initial restoration, before a foreground session exists to
  /// supply isLoading.
  bool _initializing = false;
  Future<void>? _restoreFuture;

  /// Completes when the existing restore finishes; never starts a second load.
  Future<void> get whenRestored => _restoreFuture ?? Future<void>.value();

  // --- Back-compat single-session-shaped getters ----------------------------
  // Used by CatalogSyncBody/CatalogSyncScreen and anywhere else that shows
  // "the operation currently in the foreground", not a merge across every
  // playlist.
  bool get isLoading =>
      _initializing || (_foregroundSession?.isLoading ?? false);
  String? get error {
    final foreground = _foregroundSession;
    // A null error means this operation succeeded. Falling back to another
    // playlist here makes a successful add/edit report an unrelated failure.
    if (foreground != null) return foreground.error;
    return anyPlaylistError;
  }

  /// Overall connection health for the home screen and refresh-all results.
  /// Individual add/edit results must use [error] instead.
  String? get anyPlaylistError => _enabledSessionsSorted
      .map((s) => s.error)
      .whereType<String>()
      .firstOrNull;

  DateTime? get lastLoaded => _foregroundSession?.lastLoaded;
  String? get loadingPhase => _foregroundSession?.loadingPhase;
  Map<String, int>? get lastLoadSummary => _foregroundSession?.lastLoadSummary;
  bool get isWarmingCatalog => _foregroundSession?.isWarmingCatalog ?? false;
  int get warmCatalogDone => _foregroundSession?.warmCatalogDone ?? 0;
  int get warmCatalogTotal => _foregroundSession?.warmCatalogTotal ?? 0;
  int get vodCatalogDone => _foregroundSession?.vodCatalogDone ?? 0;
  int get vodCatalogTotal => _foregroundSession?.vodCatalogTotal ?? 0;
  int get seriesCatalogDone => _foregroundSession?.seriesCatalogDone ?? 0;
  int get seriesCatalogTotal => _foregroundSession?.seriesCatalogTotal ?? 0;

  List<PlaylistProfile> get profiles => _sessions.map((s) => s.profile).toList()
    ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));

  List<PlaylistSession> get _enabledSessionsSorted =>
      _sessions.where((s) => s.profile.enabled).toList()
        ..sort((a, b) => a.profile.sortOrder.compareTo(b.profile.sortOrder));

  /// Same as [_enabledSessionsSorted], ordered by [tabCategory]'s own
  /// priority override instead of the shared base [PlaylistProfile
  /// .sortOrder] — see [PlaylistProfile.sortOrderFor]'s doc comment. Used
  /// by every getter below whose order is actually what the user sees
  /// rendered in that specific tab (channels/tvGroups/vodGroups/
  /// seriesGroups); everything else (connection retries, counts, favorite
  /// lists, ...) stays on the plain base order above since nothing about
  /// those is tab-specific or genuinely order-sensitive to the viewer.
  List<PlaylistSession> _enabledSessionsSortedFor(String tabCategory) =>
      _sessions.where((s) => s.profile.enabled).toList()
        ..sort((a, b) => a.profile
            .sortOrderFor(tabCategory)
            .compareTo(b.profile.sortOrderFor(tabCategory)));

  PlaylistSession? _sessionFor(String playlistId) {
    for (final s in _sessions) {
      if (s.profile.id == playlistId) return s;
    }
    return null;
  }

  String categoryLayoutFor(String playlistId) {
    final session = _sessionFor(playlistId);
    return resolveLiveCategoryLayout(session?.profile.categoryLayout ?? 'auto',
        groupsForPlaylist(playlistId, 'tv'));
  }

  /// Whether this specific playlist is enabled — used by `PlaybackService`
  /// to block playback for a disabled playlist's channels, the per-channel
  /// replacement for what used to be one global "playlist enabled" toggle
  /// (`AppPreferences.playlistEnabled`) before multi-playlist support.
  bool isPlaylistEnabled(String playlistId) =>
      _sessionFor(playlistId)?.profile.enabled ?? false;

  /// True if an enabled playlist supplies a category catalogue — gates library UI
  /// (the TV Shows tab, Full Catalog Sync, etc.). With a mixed M3U +
  /// portal setup, that UI shows up because at least one playlist can use
  /// it; per-playlist screens (Group Management, Playlist Manager's detail
  /// panel) check `PlaylistProfile.hasCatalog` directly instead.
  bool get hasCatalog => _enabledSessionsSorted.any((s) => s.hasCatalog);

  // --- Init / migration -----------------------------------------------------

  /// With [restoreInBackground], only local account/settings setup blocks
  /// startup. A missing cache or slow provider must not trap the entire app
  /// behind the splash. The same restore continues and notifies the guide.
  Future<void> init({bool restoreInBackground = false}) async {
    // Set synchronously, before the first `await` — matches the old
    // single-playlist behavior where whatever's on screen the instant it
    // renders needs to already read "loading", not a flash of "no
    // channels found" from a still-empty, not-yet-started PlaylistManager.
    _initializing = true;
    notifyListeners();
    try {
      await _migrateLegacySinglePlaylist();
      await _reconcileFavoritesFromDbOnce();

      _catalogDb.isVodFavorite = (id) => _favoriteIds.contains(id);
      _catalogDb.isSeriesFavorite = (id) => _favoriteSeriesIds.contains(id);

      _favoriteIds = _storage.getFavorites();
      _favoriteSeriesIds = _storage.getFavoriteSeries();

      _sessions
        ..clear()
        ..addAll(_storage.getPlaylists().map((profile) => PlaylistSession(
              profile: profile,
              storage: _storage,
              catalogDb: _catalogDb,
              favoriteIds: () => _favoriteIds,
              favoriteSeriesIds: () => _favoriteSeriesIds,
              onNotify: notifyListeners,
              onLibraryNotify: notifyLibraryChanged,
            )));

      notifyListeners();
      // Every enabled playlist restores (from its own cache, or a fresh
      // network load if there's none yet) in parallel — each one notifies
      // independently via its own `onNotify`, so the UI fills in
      // playlist-by-playlist rather than waiting for the slowest one.
      _restoreFuture = _restoreSessions();
      if (!restoreInBackground) await _restoreFuture;
    } catch (_) {
      _initializing = false;
      notifyListeners();
      rethrow;
    }
  }

  Future<void> _restoreSessions() async {
    try {
      await Future.wait(_enabledSessionsSorted.map(_restoreSession));
      // Wait for cached categories before resolving legacy layouts. An empty
      // or failed restore must not permanently choose the wrong presentation.
      for (final session in _sessions) {
        if (session.profile.categoryLayout == 'auto' &&
            session.tvGroups.isNotEmpty) {
          await updatePlaylist(session.profile
              .copyWith(categoryLayout: categoryLayoutFor(session.profile.id)));
        }
      }
    } finally {
      _initializing = false;
      notifyListeners();
    }
  }

  Future<void> _restoreSession(PlaylistSession session) async {
    session.error = null;
    try {
      await session.restoreOrLoad();
    } catch (error) {
      // Cache/platform failures must also be retryable without losing settings.
      session.error = 'Could not load playlist. Please try again.';
      debugPrint('Playlist restore failed: ${error.runtimeType}');
    }
  }

  /// Manual "Retry" action for the connection-failed empty state (Live TV,
  /// Movies/TV Shows). Only re-runs sessions that are actually in an error
  /// state — not every enabled playlist — so this can't turn into the same
  /// "hammer the server with more requests than it wants" problem
  /// `XtreamApiService.maxConnections` was added to prevent for the
  /// concurrent-category-fetch path; a manual, user-initiated single retry
  /// is a different, much smaller thing than that was.
  Future<void> retryFailedConnections() async {
    final failed =
        _enabledSessionsSorted.where((s) => s.error != null).toList();
    await Future.wait(failed.map(_restoreSession));
    notifyListeners();
  }

  /// Upgrading from the pre-multi-playlist version: the old single set of
  /// global scalar prefs (server/username/password, hidden/favorited
  /// groups, sync frequency) becomes one `PlaylistProfile` under a fixed,
  /// traceable id (`'migrated_default'`) rather than a random one — so
  /// support/logs can recognize it. Guarded so this only ever runs once.
  Future<void> _migrateLegacySinglePlaylist() async {
    if (_storage.getMigratedToMultiPlaylist()) return;
    if (_storage.getPlaylists().isNotEmpty) {
      // Fresh install of a version that already has multi-playlist
      // support — nothing to migrate, but still guard so this check
      // itself doesn't run on every future launch.
      await _storage.setMigratedToMultiPlaylist(true);
      return;
    }

    const migratedId = 'migrated_default';
    final mode = _storage.getLegacyPlaylistMode();
    final m3uUrl = _storage.getLegacyM3uUrl();
    final xtreamServer = _storage.getLegacyXtreamServer();
    final hasLegacyPlaylist =
        (mode == 'xtream' && xtreamServer != null && xtreamServer.isNotEmpty) ||
            (mode == 'm3u' && m3uUrl != null && m3uUrl.isNotEmpty);

    if (hasLegacyPlaylist) {
      final profile = PlaylistProfile(
        id: migratedId,
        name: 'My Playlist',
        mode: mode,
        m3uUrl: m3uUrl,
        epgUrl: _storage.getLegacyEpgUrl(),
        xtreamServer: xtreamServer,
        xtreamUsername: _storage.getLegacyXtreamUsername(),
        xtreamPassword: _storage.getLegacyXtreamPassword(),
        enabled: _storage.getLegacyPlaylistEnabled(),
        sortOrder: 0,
        syncFrequencyDays: _storage.getLegacySyncFrequencyDays(),
        createdAt: DateTime.now(),
      );
      await _storage.setPlaylists([profile]);
      await _storage.setHiddenGroups(
          migratedId, _storage.getLegacyHiddenGroups());
      await _storage.setFavoritedGroups(
          migratedId, _storage.getLegacyFavoritedGroups());
      final legacyLastSync = _storage.getLegacyLastFullSyncAt();
      if (legacyLastSync != null) {
        await _storage.setLastFullSyncAt(migratedId, legacyLastSync);
      }

      // Existing favorite ids were saved before id-prefixing existed —
      // rewrite them to the new '$playlistId::$rawId' shape (see
      // Channel.playlistId's doc comment) or they'd silently stop
      // matching anything post-migration. This is the single most
      // failure-prone step in the whole migration; a bug here would
      // silently drop a user's favorites with no visible error.
      final oldFavorites = _storage.getFavorites();
      await _storage
          .setFavorites(oldFavorites.map((id) => '$migratedId::$id').toSet());
      final oldSeriesFavorites = _storage.getFavoriteSeries();
      await _storage.setFavoriteSeries(
          oldSeriesFavorites.map((id) => '$migratedId::series_$id').toSet());
    }

    await _storage.setMigratedToMultiPlaylist(true);
  }

  // --- Viewer profiles --------------------------------------------------
  // `ViewerProfileService` owns profile CRUD and the actual switch
  // sequence; this class only needs the two things a switch changes for
  // *catalog* state — which favorites are active, and whether group
  // visibility is a blocklist or an allowlist (see `PlaylistSession
  // ._loadViewerScopedState`'s doc comment).

  /// Called by `ViewerProfileService.switchTo` once the new viewer id is
  /// already persisted (`StorageService.setActiveViewerId`) — reloads every
  /// session's favorited/hidden-groups/hidden-channels state and re-stamps
  /// `isFavorite` on every already-loaded `Channel`/`XtreamSeries` for the
  /// newly-active viewer. Deliberately never touches the network — a
  /// profile switch should feel instant, and the actual catalog (as
  /// opposed to which parts of it are hidden/favorited) is shared across
  /// every viewer regardless.
  void applyActiveViewer() {
    _favoriteIds = _storage.getFavorites();
    _favoriteSeriesIds = _storage.getFavoriteSeries();
    for (final session in _sessions) {
      session.reloadViewerState();
      session.restampFavorites();
    }
    notifyListeners();
  }

  /// One-time migration safety net for moving favorites off
  /// `CatalogDatabase`'s own `is_favorite` column onto callback-based reads
  /// — see `CatalogDatabase.isVodFavorite`'s doc comment for the drift this
  /// closes. Unions every VOD/series row the database's column still has
  /// set into Main's prefs favorite set, so a favorite that somehow only
  /// ever made it into the database (not the prefs set `toggleFavorite`
  /// actually writes) doesn't silently disappear the moment this version
  /// stops reading that column. Runs at most once per install, ever —
  /// guarded, not once per launch — and only ever touches Main's keys
  /// (this runs before any viewer other than Main can exist).
  Future<void> _reconcileFavoritesFromDbOnce() async {
    if (_storage.getFavoritesDbReconciled()) return;
    final playlistIds = _storage.getPlaylists().map((p) => p.id).toList();
    if (playlistIds.isNotEmpty) {
      final dbVod = await _catalogDb.getAllFavoriteVod(playlistIds);
      final dbSeries = await _catalogDb.getAllFavoriteSeries(playlistIds);
      if (dbVod.isNotEmpty || dbSeries.isNotEmpty) {
        final favorites = _storage.getFavorites()
          ..addAll(dbVod.map((c) => c.id));
        final seriesFavorites = _storage.getFavoriteSeries()
          ..addAll(dbSeries.map((s) => s.id));
        await _storage.setFavorites(favorites);
        await _storage.setFavoriteSeries(seriesFavorites);
      }
    }
    await _storage.setFavoritesDbReconciled(true);
  }

  /// Resolve current preferences at player creation without rewriting cached rows.
  Map<String, String> playbackHeaders(Channel channel) => withPlaylistUserAgent(
      channel.httpHeaders,
      _sessionFor(channel.playlistId)?.profile.userAgent ?? '');

  /// Stable portal commands are resolved at playback, never during browsing.
  Future<Channel> resolvePlaybackChannel(Channel channel) async {
    if (!channel.url.startsWith('stalker:')) return channel;
    final session = _sessionFor(channel.playlistId);
    if (session == null ||
        !session.profile.enabled ||
        !session.profile.isStalker) {
      throw const PortalException('This portal playlist is unavailable.');
    }
    return _portalApi(session).resolve(channel);
  }

  StalkerPortalService _portalApi(PlaylistSession session) {
    final existing = session.catalogApi;
    if (existing is StalkerPortalService &&
        portalConnectionIdentity(existing.profile) ==
            portalConnectionIdentity(session.profile)) {
      return existing;
    }
    // A failed account edit must not keep using the previous account's session.
    existing?.dispose();
    final api = StalkerPortalService(session.profile);
    session.catalogApi = api;
    return api;
  }

  @override
  void dispose() {
    for (final session in _sessions) {
      session.catalogApi?.dispose();
    }
    super.dispose();
  }

  // --- Add / update / remove / enable ---------------------------------------

  Future<void> addPlaylist(PlaylistProfile profile) async {
    final updated = [..._storage.getPlaylists(), profile];
    await _storage.setPlaylists(updated);
    _sessions.add(PlaylistSession(
      profile: profile,
      storage: _storage,
      catalogDb: _catalogDb,
      favoriteIds: () => _favoriteIds,
      favoriteSeriesIds: () => _favoriteSeriesIds,
      onNotify: notifyListeners,
      onLibraryNotify: notifyLibraryChanged,
    ));
    notifyListeners();
  }

  /// An explicit organisation choice also leaves the temporary flat Live view.
  /// This changes presentation only; catalogue data is not reloaded.
  Future<void> setCategoryLayout(String playlistId, String layout) async {
    final session = _sessionFor(playlistId);
    if (session == null || !const {'organised', 'provider'}.contains(layout)) {
      return;
    }
    if (layout == 'organised') {
      await _storage.setLiveCategoryFolders(true);
    }
    await updatePlaylist(session.profile.copyWith(categoryLayout: layout));
  }

  Future<void> updatePlaylist(PlaylistProfile profile) async {
    final updated = _storage
        .getPlaylists()
        .map((p) => p.id == profile.id ? profile : p)
        .toList();
    await _storage.setPlaylists(updated);
    final session = _sessionFor(profile.id);
    if (session != null) session.profile = profile;
    notifyListeners();
  }

  /// Request identity is not catalogue data. Saving it must not discard Sports
  /// matches, rescan channels or reconnect an already-playing stream.
  Future<void> setPlaylistUserAgent(String id, String value) async {
    if (playlistUserAgentError(value) != null) {
      throw const FormatException('Invalid user agent');
    }
    final session = _sessionFor(id);
    if (session == null) return;
    final profile = session.profile.copyWith(userAgent: value);
    if (profile.userAgent == session.profile.userAgent) return;
    await _storage.setPlaylists([
      for (final saved in _storage.getPlaylists())
        saved.id == id ? profile : saved,
    ]);
    session.profile = profile;
    _publishNotification();
  }

  Future<void> setPlaylistContent(String id,
      {required bool live, required bool movies, required bool series}) async {
    final session = _sessionFor(id);
    if (session == null ||
        !session.hasCatalog ||
        (!live && !movies && !series)) {
      return;
    }
    final liveChanged = live != session.profile.includeLive;
    await updatePlaylist(session.profile.copyWith(
        includeLive: live, includeMovies: movies, includeSeries: series));
    // Changing library choices never reloads the live catalogue.
    if (liveChanged) {
      await session.restoreOrLoad();
      notifyListeners();
    }
  }

  /// Commits a drag-reordered priority list for one tab — see
  /// `PlaylistProfile.liveSortOrder`'s doc comment. [orderedPlaylistIds]
  /// is every enabled playlist's id, first-to-last in the order the user
  /// just arranged them in [PlaylistPriorityScreen]; this stamps 0, 1, 2,
  /// ... onto that tab's override field for each one in turn. One storage
  /// write and one notify for the whole list, not one per playlist —
  /// dragging already fires this on every drop, and nothing here needs
  /// per-item granularity the way a single playlist's own settings edit
  /// does.
  Future<void> setCategoryPriority(
      String tabCategory, List<String> orderedPlaylistIds) async {
    final all = _storage.getPlaylists();
    final updated = all.map((p) {
      final index = orderedPlaylistIds.indexOf(p.id);
      if (index == -1) return p;
      return switch (tabCategory) {
        'tv' => p.copyWith(liveSortOrder: index),
        'vod' => p.copyWith(vodSortOrder: index),
        'series' => p.copyWith(seriesSortOrder: index),
        _ => p,
      };
    }).toList();
    await _storage.setPlaylists(updated);
    for (final profile in updated) {
      final session = _sessionFor(profile.id);
      if (session != null) session.profile = profile;
    }
    notifyListeners();
  }

  Future<void> removePlaylist(String playlistId) async {
    final updated =
        _storage.getPlaylists().where((p) => p.id != playlistId).toList();
    await _storage.setPlaylists(updated);
    _sessionFor(playlistId)?.catalogApi?.dispose();
    await _storage.setPortalCacheIdentity(playlistId, null);
    _sessions.removeWhere((s) => s.profile.id == playlistId);
    await _catalogDb.clearForPlaylist(playlistId);
    if (_foregroundSession?.profile.id == playlistId) _foregroundSession = null;
    notifyListeners();
  }

  Future<void> setPlaylistEnabled(String playlistId, bool enabled) async {
    final session = _sessionFor(playlistId);
    if (session == null) return;
    session.profile = session.profile.copyWith(enabled: enabled);
    await updatePlaylist(session.profile);
    if (enabled && session.channels.isEmpty && session.liveChannels.isEmpty) {
      await session.restoreOrLoad();
    }
    notifyListeners();
  }

  /// Adds an alternate server URL for this playlist to fall back to when
  /// its primary can't be reached (see
  /// `PlaylistSession._connectWithFallback`). No connection is attempted
  /// here — an unreachable backup is exactly what this list is *for*, so
  /// refusing to save one that happens to be down right now would be
  /// backwards. Ignores blanks and anything already in the list
  /// (including the primary itself, which is always tried anyway).
  Future<void> addBackupServer(String playlistId, String server) async {
    final session = _sessionFor(playlistId);
    if (session == null) return;
    final normalized = server.trim();
    if (normalized.isEmpty) return;
    final profile = session.profile;
    if (normalized == profile.xtreamServer ||
        profile.backupServers.contains(normalized)) {
      return;
    }
    profile.backupServers = [...profile.backupServers, normalized];
    await updatePlaylist(profile);
  }

  /// Records which server actually answered, so the next connect starts
  /// there. Called from the playback side too — a live stream that had to
  /// fall back to a backup mid-watch has just proven which server is
  /// carrying this account right now, and the catalog side should start
  /// from that one rather than rediscovering it on the next launch.
  Future<void> rememberWorkingServer(String playlistId, String server) async {
    final session = _sessionFor(playlistId);
    if (session == null) return;
    if (session.profile.lastWorkingServer == server) return;
    session.profile.lastWorkingServer = server;
    await updatePlaylist(session.profile);
  }

  Future<void> removeBackupServer(String playlistId, String server) async {
    final session = _sessionFor(playlistId);
    if (session == null) return;
    final profile = session.profile;
    profile.backupServers =
        profile.backupServers.where((s) => s != server).toList();
    // Whatever this playlist last connected through has to go too if it
    // was the server just removed, or the next connect would keep
    // preferring a hostname the user deliberately deleted.
    if (profile.lastWorkingServer == server) profile.lastWorkingServer = null;
    await updatePlaylist(profile);
  }

  /// Runs this playlist's fresh network load (Xtream login or M3U fetch),
  /// showing the blocking "Updating Content" screen the whole time — used
  /// by both a brand-new playlist's first add and re-saving an existing
  /// one's edited login details. Sets [_foregroundSession] so
  /// `CatalogSyncBody`'s progress fields reflect this specific playlist.
  Future<void> loadPlaylist(String playlistId) async {
    final session = _sessionFor(playlistId);
    if (session == null) return;
    _foregroundSession = session;
    if (session.hasCatalog) {
      await session.loadFromCatalog();
    } else {
      final url = session.profile.m3uUrl;
      if (url != null && url.isNotEmpty) await session.loadFromUrl(url);
    }
    notifyListeners();
  }

  // --- Merged catalog getters ------------------------------------------------

  /// Live-browsable channels for every enabled playlist — `liveChannels`
  /// for an Xtream session, the flat M3U list for an M3U one (M3U mode has
  /// no separate live/VOD/series storage split, unlike Xtream).
  /// The guide's empty-state check runs during ordinary widget rebuilds.
  /// Inspect source lengths rather than allocating a merged 80k-entry list.
  bool get hasLiveChannels => _sessions.any((s) =>
      s.profile.enabled &&
      (s.hasCatalog ? s.liveChannels : s.channels).isNotEmpty);

  List<Channel> get channels => _enabledSessionsSortedFor('tv')
      .expand((s) => s.hasCatalog ? s.liveChannels : s.channels)
      .toList();

  List<Channel> get allCachedVod =>
      _enabledSessionsSortedFor('vod').expand((s) => s.allCachedVod).toList();
  List<XtreamSeries> get allCachedSeries => _enabledSessionsSortedFor('series')
      .expand((s) => s.allCachedSeries)
      .toList();

  /// Shared immutable category views last until a catalogue/visibility notification.
  List<M3uGroup> _groups(String type) => _groupSnapshots.putIfAbsent(
      type,
      () => List.unmodifiable(_enabledSessionsSortedFor(type)
          .expand((s) => groupsForPlaylist(s.profile.id, type))));
  List<M3uGroup> get tvGroups => _groups('tv');
  List<M3uGroup> get vodGroups => _groups('vod');
  List<M3uGroup> get seriesGroups => _groups('series');
  List<M3uGroup> groupsForPlaylist(String id, String type) =>
      _playlistGroupSnapshots.putIfAbsent((id, type), () {
        final session = _sessionFor(id);
        if (session == null) return const [];
        return List.unmodifiable(switch (type) {
          'tv' => session.tvGroups,
          'vod' => session.vodGroups,
          _ => session.seriesGroups
        });
      });
  Future<void> ensureLibraryCategoriesFor(String id) =>
      _sessionFor(id)?.ensureLibraryCategories() ?? Future.value();

  int? vodCategoryTotalCount(String playlistId, String categoryName) =>
      _sessionFor(playlistId)?.vodCategoryTotalCountFor(categoryName);
  int? seriesCategoryTotalCount(String playlistId, String categoryName) =>
      _sessionFor(playlistId)?.seriesCategoryTotalCountFor(categoryName);

  Map<String, int>? summaryFor(String playlistId) =>
      _sessionFor(playlistId)?.lastLoadSummary;
  DateTime? lastLoadedFor(String playlistId) =>
      _sessionFor(playlistId)?.lastLoaded;

  /// This playlist's own display name — used by the merged group columns
  /// to label a divider row wherever two playlists' groups meet, so it's
  /// clear which playlist the groups below it belong to. Empty string
  /// (not null) if the playlist's since been removed out from under a
  /// still-rendering frame, so a stale divider reads as blank rather than
  /// throwing.
  String playlistNameFor(String playlistId) =>
      _sessionFor(playlistId)?.profile.name ?? '';

  bool isGroupFavorited(String playlistId, String title) =>
      _sessionFor(playlistId)?.isGroupFavorited(title) ?? false;

  Set<String> hiddenGroupsFor(String playlistId) =>
      _sessionFor(playlistId)?.hiddenGroups ?? {};

  /// Live TV only — see [AppConstants.keyHiddenChannels]'s doc comment.
  bool isChannelHidden(Channel channel) =>
      _sessionFor(channel.playlistId)?.hiddenChannels.contains(channel.rawId) ??
      false;

  Future<void> toggleChannelHidden(Channel channel) =>
      _sessionFor(channel.playlistId)?.toggleChannelHidden(channel.rawId) ??
      Future.value();

  /// [epgId] null clears a channel's manual EPG assignment — see
  /// [Channel.epgIdOverride]'s doc comment.
  Future<void> setEpgIdOverride(Channel channel, String? epgId) =>
      _sessionFor(channel.playlistId)?.setEpgIdOverride(channel.rawId, epgId) ??
      Future.value();

  /// Every channel whose current EPG assignment was set by "Auto-Pair
  /// Channels" rather than picked by hand, across every enabled playlist
  /// — feeds "Unpair Channels"' confirmation count before it actually
  /// runs. See [PlaylistSession.autoPairedEpgOverrides]'s doc comment.
  int get autoPairedEpgOverrideCount => _enabledSessionsSorted.fold(
      0, (sum, s) => sum + s.autoPairedEpgOverrides.length);

  /// Undo automatic EPG assignments while preserving manual selections. Return the number
  /// cleared.
  Future<int> unpairAutoEpgOverrides() async {
    var count = 0;
    for (final session in _enabledSessionsSorted) {
      for (final rawId in session.autoPairedEpgOverrides.toList()) {
        await session.setEpgIdOverride(rawId, null);
        count++;
      }
    }
    return count;
  }

  Future<void> removeAutomaticGuideSource(String prefix) async {
    for (final session in _sessions) {
      await session.removeAutomaticGuideSource(prefix);
    }
  }

  /// The manually-linked equivalent channel on another playlist, if this
  /// one has been given one — see [AppConstants.keyChannelLinks]'s doc
  /// comment. Null for the overwhelming majority of channels (no link
  /// set). Callers that want the actual live [Channel] this points at,
  /// not just the raw (playlistId, rawId) pair, use [resolveChannelLink].
  ChannelLink? channelLinkFor(Channel channel) =>
      _sessionFor(channel.playlistId)?.channelLinks[channel.rawId];

  /// Setting [link] also fills an unset reciprocal link on the target. Never overwrite an
  /// existing target link. Clearing removes only this channel's direction.
  Future<void> setChannelLink(Channel channel, ChannelLink? link) async {
    final session = _sessionFor(channel.playlistId);
    if (session == null) return;
    await session.setChannelLink(channel.rawId, link);
    if (link == null) return;
    final targetSession = _sessionFor(link.playlistId);
    if (targetSession != null &&
        !targetSession.channelLinks.containsKey(link.rawId)) {
      await targetSession.setChannelLink(
          link.rawId, (playlistId: channel.playlistId, rawId: channel.rawId));
    }
  }

  /// See [autoPairedEpgOverrideCount]'s doc comment — same idea, for
  /// cross-playlist channel links instead of EPG assignments.
  int get autoPairedChannelLinkCount => _enabledSessionsSorted.fold(
      0, (sum, s) => sum + s.autoPairedChannelLinks.length);

  /// See [unpairAutoEpgOverrides]'s doc comment — same idea, for
  /// cross-playlist channel links instead of EPG assignments.
  Future<int> unpairAutoChannelLinks() async {
    var count = 0;
    for (final session in _enabledSessionsSorted) {
      for (final rawId in session.autoPairedChannelLinks.toList()) {
        await session.setChannelLink(rawId, null);
        count++;
      }
    }
    return count;
  }

  /// Resolves a [ChannelLink] to the actual live [Channel] it points at —
  /// null if that playlist's since been removed/disabled, or that
  /// specific channel's since disappeared from a refreshed catalog (a
  /// provider dropping/renaming a channel). Searches `liveChannels`/
  /// `channels` directly (bypassing [visibleChannels]'s hidden-channel
  /// filtering, [Channel.epgId] resolution, etc.) — a link should still
  /// resolve to a channel the user has deliberately hidden, since hiding
  /// it from normal browsing isn't the same as wanting it excluded from
  /// failover.
  Channel? resolveChannelLink(ChannelLink link) {
    final session = _sessionFor(link.playlistId);
    if (session == null) return null;
    final all = session.hasCatalog ? session.liveChannels : session.channels;
    for (final c in all) {
      if (c.rawId == link.rawId) return c;
    }
    return null;
  }

  /// Buckets every channel in [source] by [canonicalChannelKey] — built
  /// once per source and reused across every candidate channel it's
  /// compared against, rather than recomputing/comparing token sets
  /// pairwise for every single pair (quadratic — noticeable on a real
  /// multi-thousand-channel catalog, not just in theory).
  Map<String, List<Channel>> _channelsByKey(Iterable<Channel> source) {
    final map = <String, List<Channel>>{};
    for (final c in source) {
      final key = canonicalChannelKey(c.name);
      if (key.isEmpty) continue;
      (map[key] ??= []).add(c);
    }
    return map;
  }

  /// "Auto-Pair Channels" for cross-playlist links — see
  /// `ChannelLinkingScreen`'s own doc comment and
  /// [channelNamesMatch]'s doc comment for why this only ever assigns an
  /// *unambiguous* exact match (found in exactly one other playlist,
  /// never more) and leaves everything else for the manual picker.
  /// Skips any channel that already has a link — running this again only
  /// fills in gaps, it never revisits a previous pairing (auto or
  /// manual). Returns every channel's composite `id` this pass actually
  /// linked, so the caller can offer to review just those.
  Future<Set<String>> autoPairChannelLinks() async {
    final sessions = _enabledSessionsSorted;
    // Match only visible channels, keeping work bounded to entries that the result-review UI
    // can show.
    final visibleBySession = <PlaylistSession, List<Channel>>{
      for (final s in sessions)
        s: visibleChannels(playlistId: s.profile.id, category: 'tv'),
    };
    final byKeyPerSession = <PlaylistSession, Map<String, List<Channel>>>{
      for (final s in sessions) s: _channelsByKey(visibleBySession[s]!),
    };

    final paired = <String>{};
    for (final session in sessions) {
      // Accumulate links in memory and persist once through setChannelLinksBulk, avoiding a
      // full growing-map write per match.
      final newLinks = <String, ChannelLink>{};
      for (final source in visibleBySession[session]!) {
        if (session.channelLinks.containsKey(source.rawId)) continue;
        final key = canonicalChannelKey(source.name);
        if (key.isEmpty) continue;
        Channel? found;
        var ambiguous = false;
        for (final other in sessions) {
          if (identical(other, session)) continue;
          final candidates = byKeyPerSession[other]?[key];
          if (candidates == null || candidates.isEmpty) continue;
          if (found != null || candidates.length > 1) {
            ambiguous = true;
            break;
          }
          found = candidates.first;
        }
        if (found != null && !ambiguous) {
          newLinks[source.rawId] =
              (playlistId: found.playlistId, rawId: found.rawId);
          paired.add(source.id);
        }
      }
      await session.setChannelLinksBulk(newLinks);
    }
    return paired;
  }

  /// "Auto-Pair Channels" for EPG assignment — see
  /// `EpgChannelMatchingScreen`'s own doc comment. Same unambiguous-
  /// exact-match-only rule as [autoPairChannelLinks]; also skips a
  /// channel that's already showing real programme data (an exact-id
  /// automatic match, or a previous assignment) — nothing to fix there.
  Future<Set<String>> autoPairEpgIds(EpgService epg) async {
    final byKey = <String, List<String>>{};
    for (final entry in epg.channelCatalog.entries) {
      final key = canonicalChannelKey(entry.value);
      if (key.isEmpty) continue;
      (byKey[key] ??= []).add(entry.key);
    }

    final paired = <String>{};
    for (final session in _enabledSessionsSorted) {
      // Same two fixes as autoPairChannelLinks (visible channels only,
      // one bulk write per session instead of one per match) — see that
      // method's own doc comments for why both matter.
      final newOverrides = <String, String>{};
      for (final channel
          in visibleChannels(playlistId: session.profile.id, category: 'tv')) {
        if (channel.epgIdOverride != null) continue;
        if (epg.hasPrograms(channel.epgId)) continue;
        final key = canonicalChannelKey(channel.name);
        if (key.isEmpty) continue;
        final candidates = byKey[key];
        if (candidates == null || candidates.length != 1) continue;
        newOverrides[channel.rawId] = candidates.first;
        paired.add(channel.id);
      }
      await session.setEpgIdOverridesBulk(newOverrides);
    }
    return paired;
  }

  List<PortalGuideSource> portalGuideSources() => [
        for (final session in _enabledSessionsSorted)
          if (session.profile.isStalker &&
              session.profile.includeLive &&
              (session.profile.epgUrl?.isEmpty ?? true))
            (
              id: session.profile.id,
              load: () async {
                if (!session.profile.enabled || !session.profile.isStalker) {
                  return <EpgRow>[];
                }
                return _portalApi(session).guideRows();
              }
            ),
      ];

  /// Feed selection shared by automatic refresh and guide settings.
  List<EpgSource> epgSources() => [
        for (final profile in profiles.where((p) => p.enabled && p.includeLive))
          if (profile.epgUrl?.isNotEmpty ?? false)
            EpgSource(
              url: profile.epgUrl!,
              knownChannelIds: knownChannelIdsFor(profile.id),
              headers: profile.requestHeaders,
            ),
      ];

  Set<String> supplementaryGuideSelection() {
    final saved = _storage.getSupplementaryGuideSelection();
    if (saved != null) return saved;
    final selected = <String>{};
    for (final channel in visibleChannels(category: 'tv')) {
      if (channel.epgId.startsWith(thaiEpgPrefix)) selected.add('th');
      for (final source in guideEnrichmentSources) {
        if (channel.epgId.startsWith(source.prefix)) {
          selected.add(source.country);
        }
      }
    }
    return selected;
  }

  /// Called after the primary guide is committed, so only genuine gaps are
  /// requested. No download for a source with no candidate channels.
  Future<List<EpgSource>> supplementaryGuideSources(EpgService epg) async {
    final selected = supplementaryGuideSelection();
    if (_storage.getSupplementaryGuideSelection() == null) {
      await _storage.setSupplementaryGuideSelection(selected);
    }
    if (selected.isNotEmpty) {
      await applyGuideEnrichment(epg,
          allowedSources: selected, primaryOnly: true);
    }
    final sources = <EpgSource>[];
    final custom =
        _storage.getCustomGuideSources().where((s) => s.enabled).toList();
    if (custom.isNotEmpty) {
      final channels = visibleLiveChannels;
      for (final source in custom) {
        final ids = <String>{};
        for (final channel in channels) {
          if (channel.epgId.startsWith(source.prefix)) {
            ids.add(channel.epgId);
          } else if (channel.epgIdOverride == null &&
              !epg.hasPrograms(channel.epgId)) {
            final providerId = channel.epgKey ?? channel.rawId;
            ids.add('${source.prefix}${providerId.trim().toLowerCase()}');
          }
        }
        // Never let an empty ID filter turn into a whole-feed import.
        if (ids.isNotEmpty) {
          sources.add(EpgSource(url: source.sourceUrl, knownChannelIds: ids));
        }
      }
    }
    if (selected.contains('th')) {
      await tidyThaiChannels();
      final ids = thaiGuideCandidates(epg);
      if (ids.isNotEmpty) {
        sources.add(EpgSource(url: thaiEpgSourceUrl, knownChannelIds: ids));
      }
    }
    for (final source in guideEnrichmentSources) {
      if (!selected.contains(source.country)) continue;
      final ids = guideEnrichmentCandidates(epg, source);
      if (ids.isNotEmpty) {
        sources.add(EpgSource(url: source.url, knownChannelIds: ids));
      }
    }
    return sources;
  }

  Future<void> finishSupplementaryGuides(EpgService epg) async {
    await _applyCustomGuides(epg);
    final selected = supplementaryGuideSelection();
    if (selected.isEmpty) return;
    await applyGuideEnrichment(epg, allowedSources: selected);
    if (selected.contains('th')) await applyThaiGuide(epg);
  }

  Future<void> _applyCustomGuides(EpgService epg) async {
    final sources =
        _storage.getCustomGuideSources().where((s) => s.enabled).toList();
    if (sources.isEmpty) return;
    for (final session in _enabledSessionsSorted) {
      final changes = <String, String>{};
      for (final channel
          in visibleChannels(playlistId: session.profile.id, category: 'tv')) {
        if (channel.epgIdOverride != null || epg.hasPrograms(channel.epgId)) {
          continue;
        }
        for (final source in sources) {
          final providerId = channel.epgKey ?? channel.rawId;
          final id = '${source.prefix}${providerId.trim().toLowerCase()}';
          final now = epg.getCurrentProgram(id);
          if (now == null || !now.isNowPlaying(DateTime.now())) continue;
          changes[channel.rawId] = id;
          break;
        }
      }
      await session.setEpgIdOverridesBulk(changes);
    }
  }

  Set<String> guideEnrichmentCandidates(
      EpgService epg, GuideEnrichmentSource source) {
    final ids = <String>{};
    for (final channel in visibleChannels(category: 'tv')) {
      // Keep earlier assignments: stale-row cleanup must not erase them when
      // this setup pass adds another channel from the same source.
      if (channel.epgId.startsWith(source.prefix)) {
        ids.add(channel.epgId);
      } else if (channel.epgIdOverride == null &&
          !epg.hasPrograms(channel.epgId)) {
        final match = guideEnrichmentMatch(channel);
        if (match?.country == source.country && match?.supplementalId != null) {
          ids.add(match!.supplementalId!);
        }
      }
    }
    return ids;
  }

  /// Never replaces a working/manual assignment. One batch per playlist.
  Future<int> applyGuideEnrichment(EpgService epg,
      {Set<String>? allowedSources, bool primaryOnly = false}) async {
    var count = 0;
    bool usable(String id) {
      final p = epg.getCurrentProgram(id);
      return p != null &&
          p.isNowPlaying(DateTime.now()) &&
          !const {
            'no data',
            'no information',
            'no title',
            'channel no longer available'
          }.contains(p.title.trim().toLowerCase());
    }

    for (final session in _enabledSessionsSorted) {
      final changes = <String, String>{};
      for (final channel
          in visibleChannels(playlistId: session.profile.id, category: 'tv')) {
        if (channel.epgIdOverride != null || epg.hasPrograms(channel.epgId)) {
          continue;
        }
        final match = guideEnrichmentMatch(channel);
        if (match == null ||
            (allowedSources != null &&
                !allowedSources.contains(match.country))) {
          continue;
        }
        final id = usable(match.primaryId)
            ? match.primaryId
            : (primaryOnly ? null : match.supplementalId);
        if (id != null && usable(id)) changes[channel.rawId] = id;
      }
      await session.setEpgIdOverridesBulk(changes);
      count += changes.length;
    }
    return count;
  }

  Future<int> tidyThaiChannels() async {
    var count = 0;
    for (final session in _enabledSessionsSorted) {
      count += await session.hideNonThaiEntries();
    }
    return count;
  }

  Set<String> thaiGuideCandidates(EpgService epg) {
    final ids = <String>{};
    for (final channel in visibleChannels(category: 'tv')) {
      if (channel.epgId.startsWith(thaiEpgPrefix)) {
        ids.add(channel.epgId);
      } else if (channel.epgIdOverride == null &&
          !epg.hasPrograms(channel.epgId)) {
        final id = thaiEpgCandidate(channel);
        if (id != null) ids.add(id);
      }
    }
    return ids;
  }

  /// One bulk write per playlist; only downloaded, current listings can be
  /// assigned. Existing assignments and working primary data take priority.
  Future<int> applyThaiGuide(EpgService epg) async {
    var count = 0;
    for (final session in _enabledSessionsSorted) {
      final changes = <String, String>{};
      for (final channel
          in visibleChannels(playlistId: session.profile.id, category: 'tv')) {
        if (channel.epgIdOverride != null || epg.hasPrograms(channel.epgId)) {
          continue;
        }
        final id = thaiEpgCandidate(channel);
        if (id == null) continue;
        final current = epg.getCurrentProgram(id);
        if (current == null ||
            !current.isNowPlaying(DateTime.now()) ||
            const {'no data', 'no information', 'no title'}
                .contains(current.title.toLowerCase())) {
          continue;
        }
        changes[channel.rawId] = id;
      }
      await session.setEpgIdOverridesBulk(changes);
      count += changes.length;
    }
    return count;
  }

  /// Every hidden channel across [playlistId] — used by the "Hidden
  /// channels" section in Group Management to list and unhide them.
  /// Resolved against [visibleChannels]-bypassing raw lists (`liveChannels`
  /// /`channels`) since the whole point is finding entries that
  /// `visibleChannels` itself would now filter out.
  List<Channel> hiddenChannelsFor(String playlistId) {
    final session = _sessionFor(playlistId);
    if (session == null) return const [];
    final rawIds = session.hiddenChannels;
    if (rawIds.isEmpty) return const [];
    final all = session.hasCatalog ? session.liveChannels : session.channels;
    return all.where((c) => rawIds.contains(c.rawId)).toList();
  }

  Set<String> favoritedGroupsFor(String playlistId) =>
      _sessionFor(playlistId)?.favoritedGroups ?? {};

  /// Every whole-favorited group's title across every enabled playlist —
  /// used by the sidebar's own "Favourites" group-title list. Same-named
  /// groups from two different playlists collapse into one entry here;
  /// an accepted, minor edge case (this feeds a display-only title list,
  /// not the actual channel lookup, which stays correctly scoped per
  /// playlist via `visibleChannels`).
  Set<String> get allFavoritedGroupTitles =>
      _enabledSessionsSorted.expand((s) => s.favoritedGroups).toSet();

  Future<void> ensureLibraryCategories({bool refresh = false}) async {
    await whenRestored;
    Object? failure;
    for (final session in _enabledSessionsSorted.where((s) => s.hasCatalog)) {
      try {
        await session.ensureLibraryCategories(refresh: refresh);
      } catch (e) {
        failure = e;
      }
    }
    if (failure != null) throw failure;
  }

  Future<void> loadLibraryCategory(String playlistId, String name, String type,
          {bool refresh = false}) =>
      _sessionFor(playlistId)
          ?.loadLibraryCategory(name, type, refresh: refresh) ??
      Future.value();

  /// Search the full saved library for this content type, independent of the
  /// currently browsed category. The current viewer's visible groups also
  /// exclude disabled playlists and content types before SQL pagination.
  Future<LibraryPage> searchLibraryPage(String query,
          {required bool series,
          LibrarySort sort = LibrarySort.provider,
          int offset = 0,
          int limit = 60}) =>
      _catalogDb.searchLibraryPage(
          groups: (series ? seriesGroups : vodGroups)
              .where((group) => !group.isHidden)
              .map((group) =>
                  (playlistId: group.playlistId, title: group.title)),
          series: series,
          query: query,
          sort: sort,
          offset: offset,
          limit: limit);

  Future<void> ensureCategoryLoaded(
          String playlistId, String categoryName, String tabCategory) =>
      _sessionFor(playlistId)
          ?.ensureCategoryLoaded(categoryName, tabCategory) ??
      Future.value();

  Future<void> ensureCategoriesLoaded(String playlistId,
          Iterable<String> categoryNames, String tabCategory) =>
      _sessionFor(playlistId)
          ?.ensureCategoriesLoaded(categoryNames, tabCategory) ??
      Future.value();

  List<Channel> visibleChannels(
      {String? playlistId, String? groupTitle, required String category}) {
    if (playlistId != null) {
      return _sessionFor(playlistId)
              ?.visibleChannels(groupTitle: groupTitle, category: category) ??
          const [];
    }
    return _enabledSessionsSorted
        .expand((s) =>
            s.visibleChannels(groupTitle: groupTitle, category: category))
        .toList();
  }

  List<XtreamSeries> visibleSeries({String? playlistId, String? categoryName}) {
    if (playlistId != null) {
      return _sessionFor(playlistId)?.visibleSeries(categoryName) ?? const [];
    }
    return _enabledSessionsSorted
        .expand((s) => s.visibleSeries(categoryName))
        .toList();
  }

  /// `CatalogDatabase.searchVod`/`searchSeries` wrapped here because that
  /// class has no concept of "hidden" at all — unlike [visibleChannels]/
  /// [visibleSeries] above (built from each session's own in-memory lists,
  /// already hidden-group-filtered), a direct SQL search sees every row
  /// regardless of visibility. [SearchScreen] calls these instead of
  /// `CatalogDatabase`'s methods directly, so a restricted viewer's search
  /// results can't surface a hidden category's titles. A restricted viewer
  /// queries a wider pool first, since most of it can get filtered out
  /// before [limit] is reached — same reasoning as [whatsNewVod]'s own
  /// over-fetch, just a smaller multiplier since this is an interactive,
  /// on-demand search, not a background job with time to spare.
  Future<List<Channel>> searchVisibleVod(String query, List<String> playlistIds,
      {int limit = 200}) async {
    final wider = limit;
    final rows = await _catalogDb.searchVod(query, playlistIds, limit: wider);
    return rows
        .where((c) => !_isHiddenForActiveViewer(
            c.playlistId, c.group, Channel.isLiveId(c.rawId) ? 'tv' : 'vod'))
        .take(limit)
        .toList();
  }

  Future<List<XtreamSeries>> searchVisibleSeries(
      String query, List<String> playlistIds,
      {int limit = 200}) async {
    final wider = limit;
    final rows =
        await _catalogDb.searchSeries(query, playlistIds, limit: wider);
    return rows
        .where((s) =>
            !_isHiddenForActiveViewer(s.playlistId, s.categoryId, 'series'))
        .take(limit)
        .toList();
  }

  /// Guide filter ids for one playlist. Use Channel.epgId, which includes overrides, rather
  /// than the playlist-prefixed composite id.
  Set<String> knownChannelIdsFor(String playlistId) {
    final session = _sessionFor(playlistId);
    if (session == null) return const {};
    // Skip hidden channels and groups when retaining guide data to reduce parsing and memory
    // use.
    return (session.hasCatalog ? session.liveChannels : session.channels)
        .where((c) =>
            !session.hiddenGroups.contains(c.group) &&
            !session.hiddenChannels.contains(c.rawId))
        .expand((c) sync* {
      yield c.epgId;
      // Keep a small set of audited alternate IDs from this same guide.
      // They can repair gaps later without a second guide download.
      if (c.epgIdOverride == null) {
        final match = guideEnrichmentMatch(c);
        if (match != null) yield match.primaryId;
      }
    }).toSet();
  }

  /// Ensures every enabled Xtream playlist's live channel list is loaded —
  /// see `PlaylistSession.ensureLiveChannelsLoaded`'s doc comment for why
  /// this is lazy per playlist. Safe to call unconditionally on every
  /// build; no-ops for anything already loaded.
  Future<void>? _liveLoadFuture;
  Future<void> ensureLiveChannelsLoaded() => _liveLoadFuture ??=
      _ensureLiveChannelsLoaded().whenComplete(() => _liveLoadFuture = null);

  Future<void> _ensureLiveChannelsLoaded() async {
    // Wait for each session's API/category setup before requesting its live
    // list. Rebuilds share the same pending future, including during restore.
    await whenRestored;
    await Future.wait(
        _enabledSessionsSorted.map((s) => s.ensureLiveChannelsLoaded()));
  }

  // --- Favorites (per viewer — see `applyActiveViewer`) ----------------------

  /// A restricted viewer's hidden-but-previously-favorited channel/series
  /// shouldn't still show up in Favorites just because it was favorited
  /// before its group got hidden (by them or by whoever set up their
  /// profile) — every favorite getter below filters through this. Uses the
  /// session's already-computed [PlaylistSession.hiddenGroups] (the
  /// blocklist-or-allowlist result — see that field's own doc comment),
  /// not a second hidden-groups lookup of its own.
  bool _isHiddenForActiveViewer(String playlistId, String group,
          [String type = 'tv']) =>
      _sessionFor(playlistId)?.isGroupHidden(group, type) ?? false;

  List<Channel> get favoriteChannels => _enabledSessionsSorted
          .expand((s) => s.hasCatalog
              ? [...s.liveChannels, ...s.allCachedVod]
              : s.channels)
          .where((c) {
        if (_isHiddenForActiveViewer(
            c.playlistId, c.group, Channel.isLiveId(c.rawId) ? 'tv' : 'vod')) {
          return false;
        }
        final favoritedGroups = _sessionFor(c.playlistId)?.favoritedGroups;
        return c.isFavorite || (favoritedGroups?.contains(c.group) ?? false);
      }).toList();

  /// The TV tab's Favourites list: starred live channels plus every
  /// channel of a favourited live group, per playlist in order (starred
  /// first within each playlist).
  List<Channel> get favoriteLiveChannelsWithGroups =>
      _enabledSessionsSorted.expand((s) {
        final live = s.hasCatalog
            ? s.liveChannels
            : s.channels.where((c) => _classifyGroupPublic(c.group) == 'tv');
        final visible = live
            .where((c) => !_isHiddenForActiveViewer(c.playlistId, c.group,
                Channel.isLiveId(c.rawId) ? 'tv' : 'vod'))
            .toList();
        final starred = visible.where((c) => c.isFavorite).toList();
        final starredIds = {for (final c in starred) c.id};
        return [
          ...starred,
          ...visible.where((c) =>
              !starredIds.contains(c.id) &&
              s.favoritedGroups.contains(c.group)),
        ];
      }).toList();

  List<Channel> get favoriteLiveChannels => _enabledSessionsSorted
      .expand((s) => s.hasCatalog
          ? s.liveChannels.where((c) => c.isFavorite)
          : s.channels.where(
              (c) => c.isFavorite && _classifyGroupPublic(c.group) == 'tv'))
      .where((c) => !_isHiddenForActiveViewer(
          c.playlistId, c.group, Channel.isLiveId(c.rawId) ? 'tv' : 'vod'))
      .toList();

  List<Channel> get favoriteMovies => _enabledSessionsSorted
      .expand((s) => (s.hasCatalog
          ? s.allCachedVod
          : s.channels.where((c) => _classifyGroupPublic(c.group) == 'vod')))
      .where((c) =>
          c.isFavorite &&
          !_isHiddenForActiveViewer(
              c.playlistId, c.group, Channel.isLiveId(c.rawId) ? 'tv' : 'vod'))
      .toList();

  List<XtreamSeries> get favoriteSeries => _enabledSessionsSorted
      .where((s) => s.hasCatalog)
      .expand((s) => s.allCachedSeries)
      .where((s) =>
          s.isFavorite &&
          !_isHiddenForActiveViewer(s.playlistId, s.categoryId, 'series'))
      .toList();

  List<Channel> get favoriteShowChannels => _enabledSessionsSorted
      .where((s) => !s.hasCatalog)
      .expand((s) => s.channels)
      .where((c) =>
          c.isFavorite &&
          _classifyGroupPublic(c.group) == 'series' &&
          !_isHiddenForActiveViewer(
              c.playlistId, c.group, Channel.isLiveId(c.rawId) ? 'tv' : 'vod'))
      .toList();

  /// Same classification `PlaylistSession._classifyGroup` uses — needed
  /// here too since the merged favorite getters above operate across
  /// sessions, not from inside one.
  String _classifyGroupPublic(String title) {
    return 'tv';
  }

  Future<void> toggleFavorite(Channel channel) async {
    channel.isFavorite = !channel.isFavorite;
    if (channel.isFavorite) {
      _favoriteIds.add(channel.id);
    } else {
      _favoriteIds.remove(channel.id);
    }
    await _storage.setFavorites(_favoriteIds);
    // Only while Main is active — downgrade insurance, not the source of
    // truth (see `CatalogDatabase.isVodFavorite`'s doc comment). Writing
    // this for a *non-Main* viewer would make the column actively wrong
    // for everyone else, not just stale: a bare bit can't represent "is
    // this favorited" for more than one viewer at once. Harmless no-op for
    // a live/M3U channel either way (no matching row in the database).
    if (_storage.getActiveViewerId() == AppConstants.mainViewerId) {
      await _catalogDb.setVodFavorite(channel.id, channel.isFavorite);
    }
    if (Channel.isLiveId(channel.rawId)) {
      notifyListeners();
    } else {
      notifyLibraryChanged();
    }
  }

  bool isSeriesFavorited(String seriesId) =>
      _favoriteSeriesIds.contains(seriesId);

  /// The composite-id equivalent of [isSeriesFavorited] — used by
  /// `PlaybackService.reloadForViewer` to re-stamp `isFavorite` on its own
  /// recently-played list after a viewer switch, without needing to search
  /// every session's own channel lists for a match.
  bool isChannelFavorited(String channelId) => _favoriteIds.contains(channelId);

  Future<void> toggleSeriesFavorite(XtreamSeries series) async {
    series.isFavorite = !series.isFavorite;
    if (series.isFavorite) {
      _favoriteSeriesIds.add(series.id);
    } else {
      _favoriteSeriesIds.remove(series.id);
    }
    await _storage.setFavoriteSeries(_favoriteSeriesIds);
    // See the matching comment in toggleFavorite above.
    if (_storage.getActiveViewerId() == AppConstants.mainViewerId) {
      await _catalogDb.setSeriesFavorite(series.id, series.isFavorite);
    }
    notifyLibraryChanged();
  }

  /// Hold on a tab's Favourites entry: empties that tab's Favourites for the
  /// active viewer — its starred items and its favourited groups (the
  /// Favourites view shows both). [tab] is 'TV', 'Movies' or 'TV Shows';
  /// [groups] are the tab's favourited groups, from the screen that lists
  /// them. Movies/series not loaded yet are cleared by id prefix, so a
  /// starred title in an unopened category doesn't survive.
  Future<void> clearFavorites(
      String tab, Iterable<({String playlistId, String title})> groups) async {
    final enabled = _enabledSessionsSorted.map((s) => '${s.profile.id}::');
    bool ofEnabled(String id) => enabled.any(id.startsWith);
    final channelIds = <String>{
      ...switch (tab) {
        'Movies' => favoriteMovies,
        'TV Shows' => favoriteShowChannels,
        _ => favoriteLiveChannels,
      }
          .map((c) => c.id),
      if (tab == 'Movies')
        ..._favoriteIds
            .where((id) => ofEnabled(id) && id.contains('::xt_vod_')),
      if (tab == 'TV Shows')
        ..._favoriteIds.where((id) => ofEnabled(id) && id.contains('::xt_ep_')),
    };
    final seriesIds = tab == 'TV Shows'
        ? {
            ...favoriteSeries.map((s) => s.id),
            ..._favoriteSeriesIds.where(ofEnabled),
          }
        : const <String>{};
    _favoriteIds.removeAll(channelIds);
    _favoriteSeriesIds.removeAll(seriesIds);
    await _storage.setFavorites(_favoriteIds);
    await _storage.setFavoriteSeries(_favoriteSeriesIds);
    // See the matching comment in toggleFavorite.
    if (_storage.getActiveViewerId() == AppConstants.mainViewerId) {
      for (final id in channelIds) {
        await _catalogDb.setVodFavorite(id, false);
      }
      for (final id in seriesIds) {
        await _catalogDb.setSeriesFavorite(id, false);
      }
    }
    for (final g in groups) {
      await _sessionFor(g.playlistId)?.setGroupFavorited(g.title, false);
    }
    // Every loaded copy, not just the ones listed above.
    for (final session in _sessions) {
      session.restampFavorites();
    }
    notifyListeners();
  }

  Future<void> toggleGroupHidden(String playlistId, String groupTitle) =>
      _sessionFor(playlistId)?.toggleGroupHidden(groupTitle) ?? Future.value();

  Future<void> setGroupHidden(String playlistId, String groupTitle, bool hidden,
          {bool loadImmediately = true, String type = 'tv'}) =>
      _sessionFor(playlistId)?.setGroupHidden(groupTitle, hidden,
          loadImmediately: loadImmediately, type: type) ??
      Future.value();

  Future<void> setGroupsHidden(
          String playlistId, Iterable<String> groupTitles, bool hidden,
          {bool loadImmediately = true, String type = 'tv'}) =>
      _sessionFor(playlistId)?.setGroupsHidden(groupTitles, hidden,
          loadImmediately: loadImmediately, type: type) ??
      Future.value();

  Future<void> setGroupFavorited(
          String playlistId, String title, bool favorited) =>
      _sessionFor(playlistId)?.setGroupFavorited(title, favorited) ??
      Future.value();

  /// See [PlaylistSession.moveGroup].
  Future<int?> moveGroup(
          String playlistId, String type, String title, int delta,
          {List<String>? shown}) =>
      _sessionFor(playlistId)?.moveGroup(type, title, delta, shown: shown) ??
      Future.value(null);

  // --- Full catalog sync ------------------------------------------------

  /// True if *any* enabled Xtream playlist is due for a full sync — see
  /// `PlaylistSession.needsFullSync`. main.dart checks this once at
  /// startup to decide whether to block behind [runFullCatalogSync].
  bool needsFullSync() => _enabledSessionsSorted.any((s) => s.needsFullSync());

  /// Runs every enabled Xtream playlist's full sync in turn (not in
  /// parallel — the blocking "Updating Content" screen shows one
  /// playlist's progress at a time via [_foregroundSession], which would
  /// be meaningless if several ran concurrently). Used by both the
  /// automatic launch-time sync (main.dart, gated by [needsFullSync]) and
  /// manual updates. An optional playlist ID restricts the refresh to that
  /// enabled playlist; manual refreshes do not depend on cache age.
  Future<void> runFullCatalogSync({String? playlistId}) async {
    for (final session in _enabledSessionsSorted.where((s) =>
        s.hasCatalog && (playlistId == null || s.profile.id == playlistId))) {
      _foregroundSession = session;
      notifyListeners();
      await session.runFullCatalogSync();
    }
  }

  Future<void> warmAllCategories(String playlistId) =>
      _sessionFor(playlistId)?.warmAllCategories() ?? Future.value();

  /// Whether any playlist currently has category fetches in flight —
  /// used by startup to hold the heaviest work (opening a video decoder,
  /// parsing EPG) until the catalog has gone quiet, rather than running
  /// both at once. See `main.dart`'s `_bootstrap`.
  bool get isLoadingCategories =>
      _sessions.any((s) => s.loadingCategoryNames.isNotEmpty);

  // --- Series / VOD detail --------------------------------------------------

  Future<SeriesEpisodesResult> loadSeriesEpisodes(XtreamSeries series,
      {bool plotOnly = false}) {
    final session = _sessionFor(series.playlistId);
    if (session == null) {
      return Future.value(
          (episodes: <int, List<Channel>>{}, plot: null, details: null));
    }
    return session
        .loadSeriesEpisodes(series, plotOnly: plotOnly)
        .then((result) {
      // get_series_info's fanart — the hero/carousel backdrop for this
      // show from now on, persisted so it isn't refetched next launch.
      _stampSeriesImages(series, result.details);
      return result;
    });
  }

  /// Movie plot/description, fetched on demand when [MovieDetailScreen]
  /// opens for one title. [channel.rawId] still carries its `xt_vod_`
  /// prefix (see `Channel.rawId`'s doc comment) — stripped here before
  /// the raw stream id reaches the API call.
  Future<String?> getVodDescription(Channel channel) async =>
      (await getVodDetails(channel)).plot;

  /// The whole `get_vod_info` result for one movie — at most one request
  /// per title per session (cached in memory, like the plot). The same
  /// response carries the provider's HD art (cover_big / backdrop_path):
  /// stamped onto [channel] and persisted, so the hero and the detail
  /// backdrop need neither a second fetch nor a TMDB key.
  Future<VodDetails> getVodDetails(Channel channel) async {
    final cached = _vodDetailsCache[channel.id];
    if (cached != null) {
      _stampVodImages(channel);
      return cached;
    }
    final session = _sessionFor(channel.playlistId);
    if (session == null) return VodDetails.empty;
    final rawStreamId = channel.rawId.replaceFirst('xt_vod_', '');
    final info = await session.getVodInfo(rawStreamId);
    _vodDetailsCache[channel.id] = info;
    _descriptionCache[channel.id] = info.plot;
    _providerImages[channel.id] =
        (poster: info.posterUrl, backdrop: info.backdropUrl);
    _stampVodImages(channel);
    if (info.posterUrl != null || info.backdropUrl != null) {
      unawaited(_catalogDb.setVodProviderImages(channel.id,
          posterUrl: info.posterUrl, backdropUrl: info.backdropUrl));
    }
    return info;
  }

  /// Already-fetched [getVodDetails] result, or null — no request.
  VodDetails? peekVodDetails(String id) => _vodDetailsCache[id];

  final Map<String, VodDetails> _vodDetailsCache = {};

  /// Provider HD art seen this session, by Channel.id / XtreamSeries.id —
  /// lets a *different* object for the same title (What's New, search,
  /// Continue Watching build their own) pick it up from the description
  /// cache path without another request.
  final Map<String, ({String? poster, String? backdrop})> _providerImages = {};

  void _stampVodImages(Channel channel) {
    final images = _providerImages[channel.id];
    if (images == null) return;
    if (images.poster != null) channel.providerPosterUrl = images.poster;
    if (images.backdrop != null) channel.providerBackdropUrl = images.backdrop;
  }

  void _stampSeriesImages(XtreamSeries series, SeriesDetails? details) {
    final fromInfo = details?.firstBackdrop;
    if (fromInfo != null) {
      _providerImages[series.id] = (poster: null, backdrop: fromInfo);
      if (series.providerBackdropUrl != fromInfo) {
        series.providerBackdropUrl = fromInfo;
        unawaited(_catalogDb.setSeriesProviderBackdropUrl(series.id, fromInfo));
      }
      return;
    }
    final known = _providerImages[series.id]?.backdrop;
    if (known != null) series.providerBackdropUrl ??= known;
  }

  // --- Browse-hero description cache ---------------------------------------
  //
  // In-memory only, cleared on relaunch. Shared between the Movies/TV
  // Shows browse hero's dwell-fetch (see `TvHomeScreen._updateBrowseFocus`)
  // and MovieDetailScreen/SeriesDetailScreen — whichever hits a given
  // title first populates it, and both read through it, so opening a
  // detail screen after browsing past it (or vice versa) never repeats
  // the same network fetch. Keyed by Channel.id/XtreamSeries.id, which
  // can't collide with each other (different prefixes).

  final Map<String, String?> _descriptionCache = {};

  bool hasCachedDescription(String id) => _descriptionCache.containsKey(id);
  String? peekCachedDescription(String id) => _descriptionCache[id];
  void cacheDescription(String id, String? plot) =>
      _descriptionCache[id] = plot;

  /// Movies browse hero only — cache-first, at most one network hit per
  /// title per session (a confirmed "no plot" is cached as null too, so
  /// it isn't retried every time the same title is refocused).
  Future<String?> getHeroVodDescription(Channel channel) async {
    if (_descriptionCache.containsKey(channel.id)) {
      _stampVodImages(channel);
      return _descriptionCache[channel.id];
    }
    final plot = await getVodDescription(channel);
    _descriptionCache[channel.id] = plot;
    return plot;
  }

  /// TV Shows browse hero only — `plotOnly: true` skips building the
  /// episode map entirely, which the hero never needs.
  Future<String?> getHeroSeriesDescription(XtreamSeries series) async {
    if (_descriptionCache.containsKey(series.id)) {
      _stampSeriesImages(series, null);
      return _descriptionCache[series.id];
    }
    // Also stamps the get_series_info fanart (see loadSeriesEpisodes).
    final result = await loadSeriesEpisodes(series, plotOnly: true);
    _descriptionCache[series.id] = result.plot;
    return result.plot;
  }
}
