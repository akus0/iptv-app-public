import 'package:flutter/material.dart';

import '../models/cyberpunk_palette.dart';

/// App-wide constants: display strings, theme seed, and the SharedPreferences
/// keys used by [StorageService]. Centralized here so key names never drift
/// between the services that read and write them.
class AppConstants {
  static const String appName = 'iptv-app';

  // Libraries load on demand; enabling tabs never starts a bulk catalogue sync.
  static const bool onDemandEnabled = true;

  /// This app uses its own distribution channel.
  static const bool updatesEnabled = false;

  /// The Sports tab's name. A brand: not translated.
  static const String sportsTabName = 'Sports';
  static const Color seedColor = Colors.deepPurple;

  /// Screen width above which "auto" layout mode switches to the TV UI.
  /// Real TVs/boxes routinely report >=1200 logical px in landscape;
  /// phones and even large tablets stay below it. Also used to decide
  /// whether the fullscreen player should touch orientation at all — see
  /// PlayerScreen's doc comment on why forcing portrait on a TV-sized
  /// screen is actively harmful, not just pointless.
  static const double tvLayoutWidthThreshold = 1200;

  /// Layout default for new installations. Specialised builds can override
  /// it with `--dart-define=DEFAULT_LAYOUT_MODE=tv`.
  static const String defaultLayoutMode =
      String.fromEnvironment('DEFAULT_LAYOUT_MODE', defaultValue: 'auto');

  /// Default guide presentation; existing stored preferences are migrated
  /// by StorageService where needed.
  static const String defaultGuideViewMode = 'timeline';

  // SharedPreferences keys.
  //
  // keyM3uUrl/keyEpgUrl/keyXtreamServer.../keyPlaylistMode/
  // keyPlaylistEnabled/the global keyHiddenGroups/keyFavoritedGroups/
  // keySyncFrequencyDays/keyLastFullSyncAt below are LEGACY —
  // pre-multi-playlist, single global scalars. Nothing writes them
  // anymore; they're read exactly once, by
  // PlaylistManager._migrateLegacySinglePlaylist, to build the one
  // PlaylistProfile an upgrading install starts with. Kept (not deleted)
  // as a cheap fallback during early rollout of that migration.
  static const String keyM3uUrl = 'nox_m3u_url';
  static const String keyEpgUrl = 'nox_epg_url';
  static const String keyRefreshInterval = 'nox_refresh_interval_minutes';
  static const String keyTmdbApiKey = 'nox_tmdb_api_key';
  // Stremio-style subtitle add-ons (AddonService), JSON list.
  static const String keyAddons = 'vesper_addons';
  // Archive tab sources (Stremio-schema catalogs + streams), JSON list.
  static const String keyArchiveSources = 'vesper_archive_sources';

  /// Extras: titles played (newest first, JSON) and recent searches per
  /// category (JSON `{movie: [...], series: [...]}`). Sent with "Include
  /// Extras tab data" like the sources.
  static const String keyArchiveHistory = 'vesper_archive_history';
  static const String keyArchiveRecentSearches =
      'vesper_archive_recent_searches';
  // Online subtitle languages picked before, most recent first.
  static const String keyOnlineSubtitleLangs = 'vesper_online_sub_langs';
  // Subtitle choice per series (SubtitleTracks.rememberForSeries), JSON.
  static const String keySeriesSubtitles = 'vesper_series_subs';
  static const String keyWhatsNewTmdbLastRefreshed =
      'nox_whats_new_tmdb_last_refreshed';

  /// The curated "What's New" selection itself — see
  /// `PlaylistManager.refreshWhatsNewTmdbIfDue`'s doc comment for why
  /// this exists as a separately-persisted, ordered id list rather than
  /// just re-deriving "newest" from the provider catalog on every read:
  /// the actual selection now comes from matching TMDB's own trending/
  /// popular titles against the catalog, which is too expensive (a TMDB
  /// fetch plus a DB search per candidate) to redo on every carousel
  /// render. `Channel.id`s and `XtreamSeries.id`s respectively, in
  /// display order.
  static const String keyWhatsNewVodIds = 'nox_whats_new_vod_ids';
  static const String keyWhatsNewSeriesIds = 'nox_whats_new_series_ids';
  static const String keyFavorites = 'nox_favorites';
  static const String keyFavoriteSeries = 'nox_favorite_series';
  static const String keyHiddenGroups = 'nox_hidden_groups';

  /// A restricted ("kid") viewer's *shown*-groups allowlist — the inverse
  /// of [keyHiddenGroups]'s blocklist. See `ViewerProfile.isRestricted`'s
  /// doc comment for why a restricted viewer needs the opposite default
  /// (a newly-added category should start hidden for them, not visible).
  /// Namespaced per playlist exactly like [keyHiddenGroups].
  static const String keyShownGroups = 'nox_shown_groups';

  /// Per-channel hide, scoped to live TV only — for duplicate feeds a
  /// provider lists within an otherwise-wanted group (e.g. the same
  /// channel in both HD and HEVC), where hiding the whole group isn't
  /// an option. Namespaced per playlist exactly like [keyHiddenGroups].
  static const String keyHiddenChannels = 'nox_hidden_channels';

  /// Manual EPG channel-id assignment (see `Channel.epgIdOverride`) —
  /// `Channel.rawId` -> the EPG feed's own `<channel id>`, JSON-encoded
  /// since a `Map`, unlike the `Set`s above, needs more than
  /// `getStringList`/`setStringList`. Namespaced per playlist exactly
  /// like [keyHiddenChannels].
  static const String keyEpgIdOverrides = 'nox_epg_id_overrides';

  /// Manual cross-playlist "same real-world channel" link (see
  /// `PlaylistManager.channelLinkFor`) — lets a live channel on one
  /// playlist name its equivalent on another, for manual failover when
  /// this playlist's own server (and its own backup servers) are down.
  /// One-to-one only: a channel links to at most one other channel, not
  /// a chain across three+ playlists. `Channel.rawId` -> the target
  /// channel's own (playlistId, rawId) — JSON-encoded for the same reason
  /// as [keyEpgIdOverrides]. Namespaced per playlist like every other key
  /// here.
  static const String keyChannelLinks = 'nox_channel_links';

  /// Track automatic links and guide overrides separately per playlist. Manual changes remove
  /// the automatic marker so undoing auto-pairing cannot erase a manual choice.
  static const String keyAutoPairedChannelLinks = 'nox_auto_paired_links';
  static const String keyAutoPairedEpgOverrides = 'nox_auto_paired_epg';
  static const String keyFavoritedGroups = 'nox_favorited_groups';

  /// User-chosen group order (long-press a group → Move), per playlist and
  /// per viewer, one list per content type ('tv'/'vod'/'series'): the key
  /// gets a `_<type>` suffix before the usual playlist/viewer suffixes.
  static const String keyGroupOrder = 'nox_group_order';
  static const String keyRecentSearches = 'nox_recent_searches';

  /// The JSON-encoded `List<PlaylistProfile>` — the whole multi-playlist
  /// list lives in one SharedPreferences string, same "small scalar" shape
  /// as everything else in this section (unlike the EPG cache, which is
  /// genuinely large and lives in a disk cache file instead — see
  /// cacheFileEpgPrograms below). Deliberately NOT a cache file: this has
  /// to survive `StorageService.clearCache()`, which wipes the whole
  /// OS-reclaimable cache directory on purpose.
  static const String keyPlaylists = 'nox_playlists';

  /// One-time guard so `PlaylistManager._migrateLegacySinglePlaylist` only
  /// ever runs once per install, even across many future launches.
  static const String keyMigratedToMultiPlaylist =
      'nox_migrated_multi_playlist';
  static const String keyEpgCache = 'nox_epg_cache';
  static const String keyEpgLastUpdated = 'nox_epg_last_updated';
  static const String keyLastChannelId = 'nox_last_channel_id';
  static const String keyLastPositionPrefix = 'nox_last_position_';
  static const String keyLastDurationPrefix = 'nox_last_duration_';

  // --- Viewer profiles -----------------------------------------------------
  // See `ViewerProfile`'s doc comment for the feature this supports: several
  // viewers sharing one device/playlist set, each with their own favorites/
  // hidden-groups/watch-history. `mainViewerId`'s data lives under every
  // *existing* unsuffixed key above completely unchanged — an upgrading
  // install with no viewer profiles yet is simply "Main", reading exactly
  // what it already had, with no migration/data-movement step at all. Only
  // a second-or-later viewer's data gets the `__vp_<id>` suffix added by
  // `StorageService`'s viewer-scoping helpers.
  static const String mainViewerId = 'main';
  static const String keyViewerProfiles = 'nox_viewer_profiles';
  static const String keyActiveViewerId = 'nox_active_viewer';
  static const String keyParentalPin = 'nox_parental_pin';
  static const String keyPinFailCount = 'nox_pin_fail_count';
  static const String keyPinLockedUntil = 'nox_pin_locked_until';

  /// One-time guard — see `PlaylistManager`'s favorites-reconciliation step
  /// in its `init()`, which only ever needs to run once per install.
  static const String keyFavoritesDbReconciled = 'nox_fav_db_reconciled';

  /// Suffix appended to a per-viewer-scoped key for every viewer except
  /// [mainViewerId] — see `StorageService._vk`.
  static const String viewerKeySuffix = '__vp_';

  /// LEGACY global scalar — when the last full catalog sync completed.
  /// Per-playlist now (`'${keyLastFullSyncAt}_$playlistId'`, read/written
  /// via `StorageService.getLastFullSyncAt(playlistId)`/
  /// `setLastFullSyncAt`); this bare key is only read once, during
  /// migration. See PlaylistManager.needsFullSync/runFullCatalogSync.
  static const String keyLastFullSyncAt = 'nox_last_full_sync_at';

  /// LEGACY global scalar — "how often" for the above. Per-playlist now,
  /// as `PlaylistProfile.syncFrequencyDays`; this bare key is only read
  /// once, during migration. `defaultSyncFrequencyDays`/
  /// `syncFrequencyDaysOptions` below are still live — they're
  /// `PlaylistProfile.syncFrequencyDays`'s default value and the dropdown
  /// options in its detail-panel UI, not tied to this legacy key.
  static const String keySyncFrequencyDays = 'nox_sync_frequency_days';
  static const int defaultSyncFrequencyDays = 3;
  static const List<int> syncFrequencyDaysOptions = [1, 3, 7, 10, 14];

  // LEGACY global scalars — one playlist's mode/login, superseded by
  // PlaylistProfile. Only read once, during migration.
  static const String keyPlaylistMode = 'nox_playlist_mode';
  static const String keyXtreamServer = 'nox_xtream_server';
  static const String keyXtreamUsername = 'nox_xtream_username';
  static const String keyXtreamPassword = 'nox_xtream_password';

  static const String keyShowClock = 'nox_show_clock';
  static const String keyMultiviewHideTips = 'vesper_multiview_hide_tips';
  static const String keyMultiviewQuad = 'vesper_multiview_quad';
  static const String keyResumeLastChannelAtStartup =
      'vesper_resume_last_channel_at_startup';

  /// Startup alternative to the full-screen resume above: the last channel
  /// plays in the guide's preview box. At most one of the two is on.
  static const String keyResumeLastChannelInGuide =
      'vesper_resume_last_channel_in_guide';
  static const String keyShowResumePill = 'vesper_show_resume_pill';

  /// Hides the Movies and TV Shows tabs (and their search results) — for
  /// people who get movies/shows elsewhere (debrid etc.).
  static const String keyHideMoviesShows = 'vesper_hide_movies_shows';
  // Split from keyHideMoviesShows (which now only seeds these two).
  static const String keyHideMovies = 'vesper_hide_movies';
  static const String keyHideShows = 'vesper_hide_shows';
  static const String keyHideArchive = 'vesper_hide_archive';
  static const String keyHideMultiview = 'vesper_hide_multiview';

  /// Sports tab, per viewer: leagues shown (ordered ids), spoiler mode, and
  /// the user's own game -> channel picks (JSON, see `SportsChannelPicks`).
  static const String keySportsLeagues = 'vesper_sports_leagues';
  static const String keySportsAddedLeagues = 'vesper_sports_added_leagues';
  static const String keySportsWithChannel = 'vesper_sports_with_channel';
  static const String keySportsHideScores = 'vesper_sports_hide_scores';
  static const String keySportsChannelPicks = 'vesper_sports_channel_picks';
  static const String keySportsFollowedTeams = 'vesper_sports_followed_teams';

  /// Per viewer: the favourite league (League manager, hold OK): Sports
  /// opens on it and its games lead the player side panel's Live now.
  static const String keySportsFavoriteLeague = 'vesper_sports_favorite_league';
  static const String keyPaletteId = 'nox_palette_id';

  /// UI layout: 'auto' picks phone vs TV by screen size, 'phone'/'tv' force
  /// one regardless — needed because plenty of real Android boxes (this
  /// one included) aren't officially certified Android TV devices, so
  /// there's no fully reliable automatic signal for "this is a TV".
  static const String keyLayoutMode = 'nox_layout_mode';

  /// This device's pending internet transfer (`cloud_transfer.dart`), JSON
  /// `{"code": "...", "expires": <ms>}` — so Send can show it again and
  /// delete it. Device-only: never part of a transfer.
  static const String keyCloudTransfer = 'vesper_cloud_transfer';

  /// UI language for the whole device (not per viewer): 'auto' follows the
  /// system language, or a language code ('en', 'fr', 'es', 'it'). See lib/l10n/l10n.dart.
  static const String keyLanguage = 'vesper_language';

  /// Windows: windowed instead of full screen, and the window's last
  /// bounds ("x,y,w,h") — see DesktopWindow. This PC only.
  static const String keyWindowsWindowed = 'vesper_windows_windowed';
  static const String keyWindowsBounds = 'vesper_windows_bounds';

  /// Fullscreen player: zoom the picture to fill the screen (crops the
  /// edges) instead of fitting it with black bars — the player's ⛶ button.
  /// This device only (a phone and a TV want different things).
  static const String keyVideoFill = 'vesper_video_fill';

  /// 24-hour (default) vs 12-hour times everywhere — `utils/time_format.dart`.
  static const String keyTime24h = 'vesper_time_24h';

  /// Release tag the launch update popup was told to skip
  /// (`widgets/update_prompt.dart`); a newer tag is offered again.
  static const String keySkippedUpdateVersion = 'vesper_skipped_update';

  /// Next splash greeting to show (index into SplashGreeting.bank).
  static const String keySplashGreeting = 'vesper_splash_greeting';

  /// Live TV presentation: 'live' (single-channel now/next) or 'timeline'
  /// (cable-guide grid, all visible channels at once).
  static const String keyGuideViewMode = 'nox_guide_view_mode';

  /// Timeline guide only: the live video fills the whole screen behind a
  /// translucent guide (and a 3-row grid) instead of the small corner box.
  static const String keyGuideFullVideo = 'vesper_guide_full_video';

  /// LEGACY global scalar — "enable/disable playlist" (freeing a
  /// provider's connection slot for another device without touching
  /// cached catalog/credentials). Per-playlist now, as
  /// `PlaylistProfile.enabled`; this bare key is only read once, during
  /// migration.
  static const String keyPlaylistEnabled = 'nox_playlist_enabled';

  /// Duo-tone accent palettes offered in Settings > Theme — replaced the
  /// old flat single-color presets, which couldn't represent a deliberate
  /// two-hue "cyberpunk" accent (Material's `ColorScheme.fromSeed` only
  /// derives one hue's tonal ramp). "Dark/Gold" is deliberately the most
  /// restrained of the four — muted rather than neon — so there's a safe
  /// option for a shared device an older user might also use.
  static const List<CyberpunkPalette> cyberpunkPalettes = [
    CyberpunkPalette(
      id: 'classic_tv',
      label: 'Dark grey',
      primary: Color(0xFF90CAF9),
      secondary: Color(0xFF90CAF9),
    ),
    CyberpunkPalette(
      id: 'oled',
      label: 'OLED black',
      primary: Color(0xFF90CAF9),
      secondary: Color(0xFF90CAF9),
    ),
    CyberpunkPalette(
      id: 'light',
      label: 'Light',
      primary: Color(0xFF17649B),
      secondary: Color(0xFF17649B),
    ),
  ];

  // On-disk cache file names (under the OS temp/cache directory — safe to
  // lose; the app just re-fetches from the network if they're missing).
  static const String cacheFileM3uChannels = 'm3u_channels';
  static const String cacheFileLiveChannels = 'xtream_live_channels';
  static const String cacheFileLiveCategories = 'xtream_live_categories';
  static const String cacheFileVodCategories = 'xtream_vod_categories';
  static const String cacheFileSeriesCategories = 'xtream_series_categories';
  // Per-category VOD/series *items* (not just the category list above) live
  // in CatalogDatabase (a real local database) now, not a JSON file per
  // category — see that class's doc comment for why.

  /// EPG programme cache. Was a SharedPreferences string (`keyEpgCache`,
  /// kept below only so `clearCache` can sweep away any leftover value
  /// from before this changed) — SharedPreferences backs onto a single XML
  /// file the OS loads whole, which is a bad fit for a full-catalog EPG
  /// blob that can be many MB; moved to the same disk-file cache the
  /// playlist/catalog data already uses.
  /// Superseded by `EpgDatabase` — kept only so `EpgService.init` can
  /// delete the leftover file on upgrading installs.
  static const String cacheFileEpgPrograms = 'epg_programs';

  /// Rolling window `EpgDatabase` keeps. Past: the Timeline guide shows 1 h
  /// back, so 2 h covers it; a future catch-up feature widens just this
  /// (no schema change). Future: anything *starting* within 36 h — with the
  /// 12 h default refresh that leaves ~24 h of guide if refreshes fail or
  /// the box stays off.
  static const Duration epgPastRetention = Duration(hours: 2);
  static const Duration epgFutureWindow = Duration(hours: 36);

  /// EPG auto-refresh. Was 15-120 min — each refresh is ~45 s of heavy
  /// work on a Formuler (measured), so every 30 min cost a quarter of the
  /// box's time. A stored legacy value falls back to the default (see
  /// `StorageService.getRefreshInterval`).
  static const int defaultRefreshIntervalMinutes = 720;
  static const List<int> refreshIntervalOptions = [360, 720, 1440];
}
