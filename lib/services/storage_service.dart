import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/channel.dart';
import '../models/playlist_profile.dart';
import '../models/viewer_profile.dart';
import '../models/sports.dart';
import '../utils/constants.dart';

/// Wraps [SharedPreferences] for small settings values, and the OS temp
/// directory for larger cached payloads (parsed playlist/catalog JSON) —
/// multi-MB strings don't belong in SharedPreferences' XML-backed store,
/// and living under the temp dir means the OS can reclaim them under
/// storage pressure with no worse outcome than "re-fetch from network".
class StorageService {
  late SharedPreferences _prefs;
  Directory? _cacheDir;

  /// See the "Viewer-profile scoping" section below for what this drives.
  /// Loaded once at [init] and kept in memory rather than read from
  /// [_prefs] on every single per-viewer getter/setter — `ViewerProfileService
  /// .switchTo` updates this (via [setActiveViewerId]) and the persisted
  /// value together, in that order, before anything else reads a
  /// per-viewer key again, so there's never a window where the two disagree.
  String _activeViewerId = AppConstants.mainViewerId;

  String getMultiviewLayout() =>
      _prefs.getString('multiview_layout') ?? 'automatic';
  Future<void> setMultiviewLayout(String layout) async {
    await _prefs.setString('multiview_layout', layout);
  }

  bool getMultiviewFill() => _prefs.getBool('multiview_fill') ?? false;
  Future<void> setMultiviewFill(bool fill) async {
    await _prefs.setBool('multiview_fill', fill);
  }

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    // Apply the fork's starting layout once, including existing installs.
    // Subsequent changes in Settings remain the user's choice.
    if (!(_prefs.getBool('iptv_classic_layout_v1') ?? false)) {
      await setPaletteId('classic_tv');
      await setGuideViewMode('timeline');
      await setGuideFullVideo(false);
      await setHideMovies(true);
      await setHideShows(true);
      await setHideArchive(true);
      await setHideMultiview(true);
      await setResumeLastChannelAtStartup(false);
      await setResumeLastChannelInGuide(true);
      await setShowResumePill(false);
      await _prefs.setBool('iptv_classic_layout_v1', true);
    }
    // Restore the library tabs once; later visibility choices are preserved.
    if (!(_prefs.getBool('iptv_library_tabs_v1') ?? false)) {
      await setHideMovies(false);
      await setHideShows(false);
      await _prefs.setBool('iptv_library_tabs_v1', true);
    }
    // Restore multiview once; subsequent visibility choices are preserved.
    if (!(_prefs.getBool('iptv_multiview_v1') ?? false)) {
      await setHideMultiview(false);
      await _prefs.setBool('iptv_multiview_v1', true);
    }
    _activeViewerId = _prefs.getString(AppConstants.keyActiveViewerId) ??
        AppConstants.mainViewerId;
    await _migrateSportsCoverage();
  }

  Future<void> _migrateSportsCoverage() async {
    final firstSelection = getSportsLeagues() == null;
    final key = _vk('sports_coverage_v92');
    if (_prefs.getBool(key) == true) return;
    const additions = ['eng.2', 'mma.ufc', 'mma.pfl'];
    await setSportsAddedLeagues(
        {...getSportsAddedLeagues(), ...additions}.toList());
    await setSportsLeagues({
      ...?getSportsLeagues(),
      if (getSportsLeagues() == null) ...kDefaultSportsLeagueIds,
      ...additions,
    }.toList());
    await setSportsChannelFilter('possible');
    if (firstSelection) await setSportsAllLeagues(true);
    await _prefs.setBool(key, true);
  }

  Future<Directory> _ensureCacheDir() async {
    final existing = _cacheDir;
    if (existing != null) return existing;
    final base = await getTemporaryDirectory();
    final dir = Directory('${base.path}/nox_cache');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    _cacheDir = dir;
    return dir;
  }

  // --- Generic on-disk JSON cache -----------------------------------------

  Future<void> writeCacheFile(String name, String content) async {
    final dir = await _ensureCacheDir();
    await File('${dir.path}/$name.json').writeAsString(content);
  }

  /// Path of a cache file if it exists, for callers that read *and*
  /// decode it on a background isolate. [readCacheFile] reads on the
  /// calling isolate, and `File.readAsString` does its whole UTF-8 decode
  /// there as one uninterrupted task — measured on real hardware as ~43%
  /// of the main thread's time across a cold start, because the big cache
  /// files (live channels, EPG) are tens of MB and channel names full of
  /// non-ASCII (superscript "ᴴᴰ", "ᴿᴬᵂ"...) force the slow two-byte decode
  /// path. With Dart now sharing Android's main thread, a remote key press
  /// that lands during one of those decodes can wait past Android's 5s
  /// input timeout and get the app killed as not responding. Handing the
  /// isolate a path instead also avoids copying the whole decoded string
  /// into it, which `compute(decode, rawString)` did on the main thread too.
  Future<String?> cacheFilePath(String name) async {
    final dir = await _ensureCacheDir();
    final file = File('${dir.path}/$name.json');
    return await file.exists() ? file.path : null;
  }

  Future<String?> readCacheFile(String name) async {
    final dir = await _ensureCacheDir();
    final file = File('${dir.path}/$name.json');
    if (!await file.exists()) return null;
    try {
      return await file.readAsString();
    } catch (_) {
      return null;
    }
  }

  Future<void> deleteCacheFile(String name) async {
    final dir = await _ensureCacheDir();
    final file = File('${dir.path}/$name.json');
    if (await file.exists()) {
      await file.delete();
    }
  }

  // --- Multi-playlist list --------------------------------------------------

  List<PlaylistProfile> getPlaylists() {
    final raw = _prefs.getString(AppConstants.keyPlaylists);
    if (raw == null || raw.isEmpty) return [];
    final decoded = jsonDecode(raw) as List<dynamic>;
    return decoded
        .map((e) => PlaylistProfile.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> setPlaylists(List<PlaylistProfile> playlists) =>
      _prefs.setString(AppConstants.keyPlaylists,
          jsonEncode(playlists.map((p) => p.toJson()).toList()));

  bool getMigratedToMultiPlaylist() =>
      _prefs.getBool(AppConstants.keyMigratedToMultiPlaylist) ?? false;
  Future<void> setMigratedToMultiPlaylist(bool value) =>
      _prefs.setBool(AppConstants.keyMigratedToMultiPlaylist, value);

  // --- Legacy single-playlist scalars — read-only, migration use only ------
  // See AppConstants' doc comment on these keys: nothing writes any of these
  // anymore, they only feed PlaylistManager._migrateLegacySinglePlaylist.

  List<String> getLibraryBrowseSelection(bool series) =>
      _prefs.getStringList(
          'library_browse_${_activeViewerId}_${series ? 'series' : 'movies'}') ??
      const [];

  Future<void> setLibraryBrowseSelection(bool series, List<String> selection) =>
      _prefs.setStringList(
          'library_browse_${_activeViewerId}_${series ? 'series' : 'movies'}',
          selection);

  String? getLegacyM3uUrl() => _prefs.getString(AppConstants.keyM3uUrl);
  String? getLegacyEpgUrl() => _prefs.getString(AppConstants.keyEpgUrl);
  String getLegacyPlaylistMode() =>
      _prefs.getString(AppConstants.keyPlaylistMode) ?? 'm3u';
  String? getLegacyXtreamServer() =>
      _prefs.getString(AppConstants.keyXtreamServer);
  String? getLegacyXtreamUsername() =>
      _prefs.getString(AppConstants.keyXtreamUsername);
  String? getLegacyXtreamPassword() =>
      _prefs.getString(AppConstants.keyXtreamPassword);
  bool getLegacyPlaylistEnabled() =>
      _prefs.getBool(AppConstants.keyPlaylistEnabled) ?? true;
  Set<String> getLegacyHiddenGroups() =>
      (_prefs.getStringList(AppConstants.keyHiddenGroups) ?? []).toSet();
  Set<String> getLegacyFavoritedGroups() =>
      (_prefs.getStringList(AppConstants.keyFavoritedGroups) ?? []).toSet();
  int getLegacySyncFrequencyDays() =>
      _prefs.getInt(AppConstants.keySyncFrequencyDays) ??
      AppConstants.defaultSyncFrequencyDays;
  DateTime? getLegacyLastFullSyncAt() {
    final raw = _prefs.getString(AppConstants.keyLastFullSyncAt);
    return raw == null ? null : DateTime.tryParse(raw);
  }

  int getRefreshInterval() {
    final stored = _prefs.getInt(AppConstants.keyRefreshInterval);
    // A pre-database install stored 15-120 min — not an option any more.
    return AppConstants.refreshIntervalOptions.contains(stored)
        ? stored!
        : AppConstants.defaultRefreshIntervalMinutes;
  }

  Future<void> setRefreshInterval(int minutes) =>
      _prefs.setInt(AppConstants.keyRefreshInterval, minutes);

  /// Null/empty means "release-date sorting is off" — `TmdbEnrichmentService`
  /// treats a missing key as a no-op rather than erroring, so a user who
  /// never sets one just never sees that sort option do anything, instead
  /// of a hard failure.
  String? getTmdbApiKey() => _prefs.getString(AppConstants.keyTmdbApiKey);
  Future<void> setTmdbApiKey(String key) =>
      _prefs.setString(AppConstants.keyTmdbApiKey, key);

  /// Subtitle add-ons, see AddonService. Null = never saved (defaults).
  String? getAddonsJson() => _prefs.getString(AppConstants.keyAddons);
  Future<void> setAddonsJson(String json) =>
      _prefs.setString(AppConstants.keyAddons, json);

  /// Archive tab sources (ArchiveService). Null = never saved (none).
  String? getArchiveHistoryJson() =>
      _prefs.getString(AppConstants.keyArchiveHistory);
  Future<void> setArchiveHistoryJson(String? json) => json == null
      ? _prefs.remove(AppConstants.keyArchiveHistory)
      : _prefs.setString(AppConstants.keyArchiveHistory, json);

  String? getArchiveRecentSearchesJson() =>
      _prefs.getString(AppConstants.keyArchiveRecentSearches);
  Future<void> setArchiveRecentSearchesJson(String json) =>
      _prefs.setString(AppConstants.keyArchiveRecentSearches, json);

  String? getArchiveSourcesJson() =>
      _prefs.getString(AppConstants.keyArchiveSources);
  Future<void> setArchiveSourcesJson(String json) =>
      _prefs.setString(AppConstants.keyArchiveSources, json);

  /// Languages picked from online subtitles (add-on codes like "fre"),
  /// most recent first — the player's Subtitles list offers them directly.
  String? getSeriesSubtitlesJson() =>
      _prefs.getString(AppConstants.keySeriesSubtitles);
  Future<void> setSeriesSubtitlesJson(String json) =>
      _prefs.setString(AppConstants.keySeriesSubtitles, json);

  List<String> getOnlineSubtitleLangs() =>
      _prefs.getStringList(AppConstants.keyOnlineSubtitleLangs) ?? const [];
  Future<void> addOnlineSubtitleLang(String lang) {
    final list = [lang, ...getOnlineSubtitleLangs().where((l) => l != lang)];
    return _prefs.setStringList(
        AppConstants.keyOnlineSubtitleLangs, list.take(3).toList());
  }

  /// When "What's New" was last TMDB-enriched — see
  /// `PlaylistManager.refreshWhatsNewTmdbIfDue`'s doc comment. Null means
  /// never (a freshly-added key, or TMDB sorting never used at all).
  DateTime? getWhatsNewTmdbLastRefreshed() {
    final raw = _prefs.getString(AppConstants.keyWhatsNewTmdbLastRefreshed);
    return raw == null ? null : DateTime.tryParse(raw);
  }

  Future<void> setWhatsNewTmdbLastRefreshed(DateTime time) => _prefs.setString(
      AppConstants.keyWhatsNewTmdbLastRefreshed, time.toIso8601String());

  /// See `AppConstants.keyWhatsNewVodIds`'s doc comment. Empty (not null)
  /// when never refreshed yet — callers treat that as "nothing curated
  /// yet", same as any other empty list.
  List<String> getWhatsNewVodIds() =>
      _prefs.getStringList(AppConstants.keyWhatsNewVodIds) ?? [];
  Future<void> setWhatsNewVodIds(List<String> ids) =>
      _prefs.setStringList(AppConstants.keyWhatsNewVodIds, ids);

  List<String> getWhatsNewSeriesIds() =>
      _prefs.getStringList(AppConstants.keyWhatsNewSeriesIds) ?? [];
  Future<void> setWhatsNewSeriesIds(List<String> ids) =>
      _prefs.setStringList(AppConstants.keyWhatsNewSeriesIds, ids);

  /// Public supplementary feeds are opt-in for new installs. Existing
  /// assignments continue to update until the user chooses their sources.
  Set<String>? getSupplementaryGuideSelection() =>
      _prefs.getStringList('iptv_supplementary_guides')?.toSet();
  Future<void> setSupplementaryGuideSelection(Set<String> ids) =>
      _prefs.setStringList('iptv_supplementary_guides', ids.toList()..sort());

  DateTime? getGuideEnrichmentRefresh(String url) {
    final value = _prefs.getInt('guide_fill_refresh:$url');
    return value == null ? null : DateTime.fromMillisecondsSinceEpoch(value);
  }

  Future<void> setGuideEnrichmentRefresh(String url) => _prefs.setInt(
      'guide_fill_refresh:$url', DateTime.now().millisecondsSinceEpoch);

  Set<String> getGuideEnrichmentRequestedIds(String url) =>
      (_prefs.getStringList('guide_fill_ids:$url') ?? const <String>[]).toSet();
  Future<void> setGuideEnrichmentRequestedIds(String url, Set<String> ids) =>
      _prefs.setStringList('guide_fill_ids:$url', ids.toList());
  Future<void> clearGuideEnrichmentRefreshes() async {
    for (final key in _prefs
        .getKeys()
        .where((k) =>
            k.startsWith('guide_fill_refresh:') ||
            k.startsWith('guide_fill_ids:'))
        .toList()) {
      await _prefs.remove(key);
    }
  }

  bool getLiveCategoryFolders() =>
      _prefs.getBool(_vk('live_category_folders')) ?? true;
  Future<void> setLiveCategoryFolders(bool enabled) =>
      _prefs.setBool(_vk('live_category_folders'), enabled);
  Set<String> getOpenLiveCategoryFolders() =>
      (_prefs.getStringList(_vk('live_category_open')) ?? const <String>[])
          .toSet();
  Future<void> setOpenLiveCategoryFolders(Set<String> keys) =>
      _prefs.setStringList(_vk('live_category_open'), keys.toList());

  bool getTime24h() => _prefs.getBool(AppConstants.keyTime24h) ?? true;
  Future<void> setTime24h(bool value) =>
      _prefs.setBool(AppConstants.keyTime24h, value);

  String? getSkippedUpdateVersion() =>
      _prefs.getString(AppConstants.keySkippedUpdateVersion);
  Future<void> setSkippedUpdateVersion(String version) =>
      _prefs.setString(AppConstants.keySkippedUpdateVersion, version);

  bool getShowClock() => _prefs.getBool(AppConstants.keyShowClock) ?? true;
  Future<void> setShowClock(bool value) =>
      _prefs.setBool(AppConstants.keyShowClock, value);

  /// "Don't show this again" on the Multiview connections tip.
  bool getMultiviewHideTips() =>
      _prefs.getBool(AppConstants.keyMultiviewHideTips) ?? false;
  Future<void> setMultiviewHideTips(bool value) =>
      _prefs.setBool(AppConstants.keyMultiviewHideTips, value);

  /// Settings > General: open the last live channel fullscreen right after
  /// the splash (Android; Windows always does). Off = the "Hold > to resume"
  /// pill only.
  bool getResumeLastChannelAtStartup() =>
      _prefs.getBool(AppConstants.keyResumeLastChannelAtStartup) ?? true;
  Future<void> setResumeLastChannelAtStartup(bool value) =>
      _prefs.setBool(AppConstants.keyResumeLastChannelAtStartup, value);
  bool getResumeLastChannelInGuide() =>
      _prefs.getBool(AppConstants.keyResumeLastChannelInGuide) ?? false;
  Future<void> setResumeLastChannelInGuide(bool value) =>
      _prefs.setBool(AppConstants.keyResumeLastChannelInGuide, value);
  bool getHideMoviesShows() =>
      _prefs.getBool(AppConstants.keyHideMoviesShows) ?? false;
  Future<void> setHideMoviesShows(bool value) =>
      _prefs.setBool(AppConstants.keyHideMoviesShows, value);

  /// Separate Movies / TV Shows switches; unset = the old combined one.
  bool getHideMovies() =>
      _prefs.getBool(AppConstants.keyHideMovies) ?? getHideMoviesShows();
  Future<void> setHideMovies(bool value) =>
      _prefs.setBool(AppConstants.keyHideMovies, value);
  bool getHideShows() =>
      _prefs.getBool(AppConstants.keyHideShows) ?? getHideMoviesShows();
  Future<void> setHideShows(bool value) =>
      _prefs.setBool(AppConstants.keyHideShows, value);
  bool getVideoFill() => _prefs.getBool(AppConstants.keyVideoFill) ?? false;
  Future<void> setVideoFill(bool value) =>
      _prefs.setBool(AppConstants.keyVideoFill, value);
  bool getHideArchive() => _prefs.getBool(AppConstants.keyHideArchive) ?? false;
  Future<void> setHideArchive(bool value) =>
      _prefs.setBool(AppConstants.keyHideArchive, value);
  bool getHideMultiview() =>
      _prefs.getBool(AppConstants.keyHideMultiview) ?? false;
  Future<void> setHideMultiview(bool value) =>
      _prefs.setBool(AppConstants.keyHideMultiview, value);

  /// Settings > General: the "Hold > to resume" reminder pill (Android and
  /// Windows). Off hides only the pill; hold-Right still resumes.
  bool getShowResumePill() =>
      _prefs.getBool(AppConstants.keyShowResumePill) ?? true;
  Future<void> setShowResumePill(bool value) =>
      _prefs.setBool(AppConstants.keyShowResumePill, value);

  /// Sports tab league ids in display order; null = never chosen (the
  /// screen falls back to its own default set).
  List<String>? getSportsLeagues() =>
      _prefs.getStringList(_vk(AppConstants.keySportsLeagues));
  Future<void> setSportsLeagues(List<String> ids) async {
    await _prefs.setStringList(_vk(AppConstants.keySportsLeagues), ids);
    await setSportsAllLeagues(false);
  }

  bool getSportsAllLeagues() =>
      _prefs.getBool(_vk('sports_all_leagues')) ?? false;
  Future<void> setSportsAllLeagues(bool value) =>
      _prefs.setBool(_vk('sports_all_leagues'), value);

  /// Separate opt-outs let newly discovered guide leagues appear on upgrades
  /// without rewriting a viewer's scoreboard selections.
  List<String> getHiddenGuideLeagues() =>
      _prefs.getStringList(_vk('sports_hidden_guide_leagues')) ?? const [];
  Future<void> setHiddenGuideLeagues(List<String> ids) =>
      _prefs.setStringList(_vk('sports_hidden_guide_leagues'), ids);

  /// Legacy catalogue additions, retained for preference migration. Enabled
  /// league IDs now determine selection without a separate add step.
  List<String> getSportsAddedLeagues() =>
      _prefs.getStringList(_vk(AppConstants.keySportsAddedLeagues)) ?? const [];
  Future<void> setSportsAddedLeagues(List<String> ids) =>
      _prefs.setStringList(_vk(AppConstants.keySportsAddedLeagues), ids);

  /// The favourite league id (null = none). See
  /// [AppConstants.keySportsFavoriteLeague].
  String? getSportsFavoriteLeague() =>
      _prefs.getString(_vk(AppConstants.keySportsFavoriteLeague));
  Future<void> setSportsFavoriteLeague(String? id) => id == null
      ? _prefs.remove(_vk(AppConstants.keySportsFavoriteLeague))
      : _prefs.setString(_vk(AppConstants.keySportsFavoriteLeague), id);

  String getSportsChannelFilter() =>
      _prefs.getString(_vk('sports_channel_filter')) ?? 'possible';
  Future<void> setSportsChannelFilter(String value) =>
      _prefs.setString(_vk('sports_channel_filter'), value);

  bool getSportsWithChannel() =>
      _prefs.getBool(_vk(AppConstants.keySportsWithChannel)) ?? false;
  Future<void> setSportsWithChannel(bool value) =>
      _prefs.setBool(_vk(AppConstants.keySportsWithChannel), value);

  bool getSportsOnlineExtras() =>
      _prefs.getBool(_vk('sports_online_extras')) ?? true;
  Future<void> setSportsOnlineExtras(bool enabled) =>
      _prefs.setBool(_vk('sports_online_extras'), enabled);

  bool getSportsHideScores() =>
      _prefs.getBool(_vk(AppConstants.keySportsHideScores)) ?? false;
  Future<void> setSportsHideScores(bool value) =>
      _prefs.setBool(_vk(AppConstants.keySportsHideScores), value);

  /// Raw JSON of the user's game/team -> channel picks; parsed by
  /// `SportsChannelPicks` (null = none yet).
  String? getSportsChannelPicks() =>
      _prefs.getString(_vk(AppConstants.keySportsChannelPicks));
  Future<void> setSportsChannelPicks(String json) =>
      _prefs.setString(_vk(AppConstants.keySportsChannelPicks), json);

  /// My Teams, in follow order, as `leagueId|teamId` (parsed by
  /// `FollowedTeam.parse`).
  List<String> getSportsFollowedTeams() =>
      _prefs.getStringList(_vk(AppConstants.keySportsFollowedTeams)) ??
      const [];
  Future<void> setSportsFollowedTeams(List<String> teams) =>
      _prefs.setStringList(_vk(AppConstants.keySportsFollowedTeams), teams);

  /// Last Multiview layout: true = 4 screens (2x2), false = 2 stacked.
  bool getMultiviewQuad() =>
      _prefs.getBool(AppConstants.keyMultiviewQuad) ?? false;
  Future<void> setMultiviewQuad(bool value) =>
      _prefs.setBool(AppConstants.keyMultiviewQuad, value);

  /// Falls back to the first entry (Minimalist) when unset or when the
  /// stored id doesn't match a known palette — no migration attempted from
  /// the old single-seed-color storage, a fresh sensible default is simpler
  /// than trying to map an arbitrary old color onto the closest palette.
  String getPaletteId() =>
      _prefs.getString(AppConstants.keyPaletteId) ??
      AppConstants.cyberpunkPalettes.first.id;
  Future<void> setPaletteId(String id) =>
      _prefs.setString(AppConstants.keyPaletteId, id);

  /// 'auto' or 'tv'. A saved 'phone' (the old phone-only home screen,
  /// removed) reads as 'auto'.
  String getLayoutMode() {
    final mode = _prefs.getString(AppConstants.keyLayoutMode) ??
        AppConstants.defaultLayoutMode;
    return mode == 'phone' ? 'auto' : mode;
  }

  Future<void> setLayoutMode(String mode) =>
      _prefs.setString(AppConstants.keyLayoutMode, mode);

  /// 'auto' or a language code ('en', 'fr', 'es', 'it'). main.dart reads the key directly before `runApp`
  /// (the splash text is already translated), this only writes it.
  Future<void> setLanguage(String value) =>
      _prefs.setString(AppConstants.keyLanguage, value);

  /// 'live' or 'timeline'.
  String getGuideViewMode() =>
      _prefs.getString(AppConstants.keyGuideViewMode) ??
      AppConstants.defaultGuideViewMode;
  Future<void> setGuideViewMode(String mode) =>
      _prefs.setString(AppConstants.keyGuideViewMode, mode);

  bool getGuideFullVideo() =>
      _prefs.getBool(AppConstants.keyGuideFullVideo) ?? false;
  Future<void> setGuideFullVideo(bool value) =>
      _prefs.setBool(AppConstants.keyGuideFullVideo, value);

  // --- Favorites (per viewer, shared across every playlist) -----------------
  // Favorites aren't namespaced by playlist (a favorited channel is just a
  // composite playlistId::rawId already, so there's no collision risk the
  // way group *names* have) but ARE namespaced per viewer — see
  // "Viewer-profile scoping" below.

  Set<String> getFavorites() =>
      (_prefs.getStringList(_vk(AppConstants.keyFavorites)) ?? []).toSet();
  Future<void> setFavorites(Set<String> ids) =>
      _prefs.setStringList(_vk(AppConstants.keyFavorites), ids.toList());

  Set<String> getFavoriteSeries() =>
      (_prefs.getStringList(_vk(AppConstants.keyFavoriteSeries)) ?? []).toSet();
  Future<void> setFavoriteSeries(Set<String> ids) =>
      _prefs.setStringList(_vk(AppConstants.keyFavoriteSeries), ids.toList());

  // --- Hidden / favorited groups (per playlist, per viewer) -----------------
  // Group identity is (playlistId, title), not just title — two different
  // providers can easily have a same-named category. Each playlist gets its
  // own namespaced key rather than one shared Set, so there's no collision;
  // each viewer gets its own copy of that on top, so a restricted viewer's
  // hidden groups are independent of what any other viewer hides.

  Set<String> getHiddenGroups(String playlistId) =>
      (_prefs.getStringList(_vkp(AppConstants.keyHiddenGroups, playlistId)) ??
              [])
          .toSet();
  Future<void> setHiddenGroups(String playlistId, Set<String> groups) =>
      _prefs.setStringList(
          _vkp(AppConstants.keyHiddenGroups, playlistId), groups.toList());

  /// Keyed by `Channel.rawId` (not the composite `id`) — this is already
  /// namespaced per playlist and per viewer via the key suffixes, same as
  /// [getHiddenGroups].
  Set<String> getHiddenChannels(String playlistId) =>
      (_prefs.getStringList(_vkp(AppConstants.keyHiddenChannels, playlistId)) ??
              [])
          .toSet();
  Future<void> setHiddenChannels(String playlistId, Set<String> rawIds) =>
      _prefs.setStringList(
          _vkp(AppConstants.keyHiddenChannels, playlistId), rawIds.toList());

  /// Keyed by `Channel.rawId` -> the assigned EPG feed's own channel id —
  /// see [AppConstants.keyEpgIdOverrides]'s doc comment. A malformed/
  /// pre-Map value (there isn't one pre-existing, but a corrupt prefs
  /// entry isn't unheard of elsewhere in this file) reads back as empty
  /// rather than throwing.
  Map<String, String> getEpgIdOverrides(String playlistId) {
    final raw =
        _prefs.getString('${AppConstants.keyEpgIdOverrides}_$playlistId');
    if (raw == null) return {};
    try {
      return (jsonDecode(raw) as Map<String, dynamic>)
          .map((k, v) => MapEntry(k, v as String));
    } catch (_) {
      return {};
    }
  }

  Future<void> setEpgIdOverrides(
          String playlistId, Map<String, String> overrides) =>
      _prefs.setString('${AppConstants.keyEpgIdOverrides}_$playlistId',
          jsonEncode(overrides));

  /// Keyed by `Channel.rawId` -> the linked channel's own (playlistId,
  /// rawId) — see [AppConstants.keyChannelLinks]'s doc comment. Same
  /// "corrupt/missing reads back empty" tolerance as [getEpgIdOverrides].
  Map<String, ChannelLink> getChannelLinks(String playlistId) {
    final raw = _prefs.getString('${AppConstants.keyChannelLinks}_$playlistId');
    if (raw == null) return {};
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      return decoded.map((k, v) {
        final m = v as Map<String, dynamic>;
        return MapEntry(k, (
          playlistId: m['playlistId'] as String,
          rawId: m['rawId'] as String
        ));
      });
    } catch (_) {
      return {};
    }
  }

  Future<void> setChannelLinks(
          String playlistId, Map<String, ChannelLink> links) =>
      _prefs.setString(
          '${AppConstants.keyChannelLinks}_$playlistId',
          jsonEncode(links.map((k, v) =>
              MapEntry(k, {'playlistId': v.playlistId, 'rawId': v.rawId}))));

  /// See [AppConstants.keyAutoPairedChannelLinks]'s doc comment.
  Set<String> getAutoPairedChannelLinks(String playlistId) =>
      (_prefs.getStringList(
                  '${AppConstants.keyAutoPairedChannelLinks}_$playlistId') ??
              [])
          .toSet();
  Future<void> setAutoPairedChannelLinks(
          String playlistId, Set<String> rawIds) =>
      _prefs.setStringList(
          '${AppConstants.keyAutoPairedChannelLinks}_$playlistId',
          rawIds.toList());

  /// See [AppConstants.keyAutoPairedEpgOverrides]'s doc comment.
  Set<String> getAutoPairedEpgOverrides(String playlistId) =>
      (_prefs.getStringList(
                  '${AppConstants.keyAutoPairedEpgOverrides}_$playlistId') ??
              [])
          .toSet();
  Future<void> setAutoPairedEpgOverrides(
          String playlistId, Set<String> rawIds) =>
      _prefs.setStringList(
          '${AppConstants.keyAutoPairedEpgOverrides}_$playlistId',
          rawIds.toList());

  Set<String> getFavoritedGroups(String playlistId) => (_prefs.getStringList(
              _vkp(AppConstants.keyFavoritedGroups, playlistId)) ??
          [])
      .toSet();
  Future<void> setFavoritedGroups(String playlistId, Set<String> groups) =>
      _prefs.setStringList(
          _vkp(AppConstants.keyFavoritedGroups, playlistId), groups.toList());

  /// [type] is 'tv'/'vod'/'series' — see [AppConstants.keyGroupOrder].
  /// Empty = provider order (nothing moved yet).
  List<String> getGroupOrder(String playlistId, String type) =>
      _prefs.getStringList(
          _vkp('${AppConstants.keyGroupOrder}_$type', playlistId)) ??
      [];
  Future<void> setGroupOrder(
          String playlistId, String type, List<String> titles) =>
      _prefs.setStringList(
          _vkp('${AppConstants.keyGroupOrder}_$type', playlistId), titles);

  // --- Search history (per viewer) ------------------------------------------

  static const _maxRecentSearches = 10;

  /// Most-recent-first. Shared across Live TV/Movies/TV Shows scopes rather
  /// than kept separate per scope — simpler, and a remembered search is
  /// useful regardless of which scope tab happens to be selected right now.
  List<String> getRecentSearches() =>
      _prefs.getStringList(_vk(AppConstants.keyRecentSearches)) ?? [];

  Future<void> addRecentSearch(String query) {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return Future.value();
    final list = getRecentSearches()
        .where((s) => s.toLowerCase() != trimmed.toLowerCase())
        .toList();
    list.insert(0, trimmed);
    if (list.length > _maxRecentSearches) {
      list.removeRange(_maxRecentSearches, list.length);
    }
    return _prefs.setStringList(_vk(AppConstants.keyRecentSearches), list);
  }

  Future<void> clearRecentSearches() =>
      _prefs.remove(_vk(AppConstants.keyRecentSearches));

  // --- EPG cache -------------------------------------------------------------
  // The programme data itself lives in `EpgDatabase`. Only the last-updated
  // timestamp stays here.

  DateTime? getEpgLastUpdated() {
    final raw = _prefs.getString(AppConstants.keyEpgLastUpdated);
    return raw == null ? null : DateTime.tryParse(raw);
  }

  Future<void> setEpgLastUpdated(DateTime time) =>
      _prefs.setString(AppConstants.keyEpgLastUpdated, time.toIso8601String());

  // --- Full catalog sync (per playlist) -----------------------------------
  // Sync frequency itself lives directly on PlaylistProfile.syncFrequencyDays
  // now (see StorageService.setPlaylists) — only the "when did it last
  // actually run" timestamp needs its own namespaced key here.

  DateTime? getLastFullSyncAt(String playlistId) {
    final raw =
        _prefs.getString('${AppConstants.keyLastFullSyncAt}_$playlistId');
    return raw == null ? null : DateTime.tryParse(raw);
  }

  Future<void> setLastFullSyncAt(String playlistId, DateTime time) =>
      _prefs.setString('${AppConstants.keyLastFullSyncAt}_$playlistId',
          time.toIso8601String());

  // --- Resume playback (per viewer) ---------------------------------------

  String? getLastChannelId() =>
      _prefs.getString(_vk(AppConstants.keyLastChannelId));
  Future<void> setLastChannelId(String id) =>
      _prefs.setString(_vk(AppConstants.keyLastChannelId), id);

  /// The viewer suffix goes at the *end*, after [channelId] — not
  /// immediately after the prefix — so every viewer's position/duration key
  /// still starts with [AppConstants.keyLastPositionPrefix]/
  /// [keyLastDurationPrefix] and [clearCache]'s existing `startsWith` sweep
  /// below keeps catching all of them, not just Main's.
  String _positionKey(String channelId) =>
      _vk('${AppConstants.keyLastPositionPrefix}$channelId');
  String _durationKey(String channelId) =>
      _vk('${AppConstants.keyLastDurationPrefix}$channelId');

  int getLastPosition(String channelId) =>
      _prefs.getInt(_positionKey(channelId)) ?? 0;
  Future<void> setLastPosition(String channelId, int milliseconds) =>
      _prefs.setInt(_positionKey(channelId), milliseconds);

  int getLastDuration(String channelId) =>
      _prefs.getInt(_durationKey(channelId)) ?? 0;

  /// A resume point known only as a fraction (Trakt/Simkl paused at 42 %,
  /// the title never played here so its length is unknown): saved as
  /// position/duration on a 1,000,000 scale, so progress bars and "resume"
  /// read it as is, plus a flag so the player converts it to a real time
  /// once the duration is known ([PlaybackService.play]). Its key starts
  /// with the position prefix, so clearing history sweeps it too.
  static const resumeFractionScale = 1000000;
  String _fractionKey(String channelId) =>
      _vk('${AppConstants.keyLastPositionPrefix}frac:$channelId');

  Future<void> setResumeFraction(String channelId, double fraction) async {
    await _prefs.setBool(_fractionKey(channelId), true);
    await setLastDuration(channelId, resumeFractionScale);
    await setLastPosition(
        channelId, (fraction.clamp(0.0, 1.0) * resumeFractionScale).round());
  }

  bool isResumeFraction(String channelId) =>
      _prefs.getBool(_fractionKey(channelId)) ?? false;

  Future<void> clearResumeFraction(String channelId) =>
      _prefs.remove(_fractionKey(channelId));
  Future<void> setLastDuration(String channelId, int milliseconds) =>
      _prefs.setInt(_durationKey(channelId), milliseconds);

  /// Fraction watched (0.0-1.0), or null when there's nothing to compute
  /// one from — no saved position, or duration was never recorded (e.g.
  /// playback never got far enough to report one).
  double? getWatchedFraction(String channelId) {
    final duration = getLastDuration(channelId);
    final position = getLastPosition(channelId);
    if (duration <= 0 || position <= 0) return null;
    return (position / duration).clamp(0.0, 1.0);
  }

  /// True once far enough into playback to call it done — not exactly 100%,
  /// since end credits/a few trailing seconds are routinely never watched.
  bool isFullyWatched(String channelId) {
    final fraction = getWatchedFraction(channelId);
    return fraction != null && fraction >= 0.95;
  }

  /// The active viewer's saved positions/durations — the movie/episode
  /// progress bars and Continue Watching resume points (Settings > General
  /// "Clear Movies & TV Shows history"). Other viewers' keys are untouched:
  /// Main's are the bare keys (no viewer suffix), everyone else's end with
  /// their own suffix (see [_vk]).
  Future<void> clearPlaybackPositions() async {
    final ownSuffix = '${AppConstants.viewerKeySuffix}$_activeViewerId';
    final isMain = _activeViewerId == AppConstants.mainViewerId;
    final keys = _prefs
        .getKeys()
        .where((k) =>
            (k.startsWith(AppConstants.keyLastPositionPrefix) ||
                k.startsWith(AppConstants.keyLastDurationPrefix)) &&
            (isMain
                ? !k.contains(AppConstants.viewerKeySuffix)
                : k.endsWith(ownSuffix)))
        .toList();
    for (final key in keys) {
      await _prefs.remove(key);
    }
  }

  /// Clears EPG cache, the entire on-disk playlist/catalog cache (including
  /// the per-category files — there's one per VOD/series category, named
  /// dynamically by category id, so wiping the whole directory is simpler
  /// and more thorough than trying to enumerate them), and saved playback
  /// positions. Playlist/EPG source settings, favorites, and hidden-group
  /// choices are left untouched.
  // --- Device transfer (Settings > Transfer to another device) -----------

  /// The pending internet transfer's raw JSON (`AppConstants.keyCloudTransfer`).
  String? getCloudTransfer() => _prefs.getString(AppConstants.keyCloudTransfer);
  Future<void> setCloudTransfer(String? json) => json == null
      ? _prefs.remove(AppConstants.keyCloudTransfer)
      : _prefs.setString(AppConstants.keyCloudTransfer, json);

  /// Keys that describe *this device* or a cache, never the user's setup:
  /// left out of a transfer and kept as-is on the receiving device.
  static const _transferSkipExact = {
    AppConstants.keyEpgCache,
    AppConstants.keyEpgLastUpdated,
    AppConstants.keyLayoutMode,
    AppConstants.keyWindowsWindowed,
    AppConstants.keyWindowsBounds,
    AppConstants.keyVideoFill,
    AppConstants.keyPlaylistEnabled,
    AppConstants.keyPinFailCount,
    AppConstants.keyPinLockedUntil,
    AppConstants.keyFavoritesDbReconciled,
    AppConstants.keyWhatsNewTmdbLastRefreshed,
    AppConstants.keyWhatsNewVodIds,
    AppConstants.keyWhatsNewSeriesIds,
    AppConstants.keyCloudTransfer,
    AppConstants.keySplashGreeting,
    AppConstants.keySkippedUpdateVersion,
  };

  /// Prefix-matched skips: the per-playlist full-sync timestamps (a copied
  /// one would tell the new, empty device its catalog is fresh).
  static const _transferSkipPrefixes = [AppConstants.keyLastFullSyncAt];

  static bool _transferable(String key) =>
      !_transferSkipExact.contains(key) &&
      !_transferSkipPrefixes.any(key.startsWith);

  /// The Archive tab's data: its sources, plus the watch progress of its
  /// titles (position/duration keys of `archive::arc_…` channel ids — see
  /// `ArchiveService.channelId`). Its catalog cache is a separate database
  /// and never transfers.
  static bool _isArchiveKey(String key) =>
      key == AppConstants.keyArchiveSources ||
      key == AppConstants.keyArchiveHistory ||
      key == AppConstants.keyArchiveRecentSearches ||
      key.contains('archive::arc_');

  /// Present in a payload sent without the Archive tab's data: the
  /// receiving device then keeps its own instead of losing it.
  static const _transferArchiveExcluded = 'vesper_transfer_archive_excluded';

  /// Everything the user set up — playlists, every viewer's favorites,
  /// hidden groups, progress, history, Sports, settings — as a
  /// type-tagged map (`{"t": "s"|"b"|"i"|"d"|"l", "v": ...}` per key) that
  /// [importForTransfer] restores exactly. Catalog/EPG caches aren't in
  /// here: the receiving device downloads them from the provider.
  ///
  /// [includeArchive] false (Transfer > "Include Archive tab data" off)
  /// leaves out [_isArchiveKey] keys and marks the payload so the receiver
  /// keeps its own Archive data.
  Map<String, Object> exportForTransfer({bool includeArchive = true}) {
    final out = <String, Object>{
      if (!includeArchive) _transferArchiveExcluded: {'t': 'b', 'v': true},
    };
    for (final key in _prefs.getKeys()) {
      if (!_transferable(key)) continue;
      if (!includeArchive && _isArchiveKey(key)) continue;
      final v = _prefs.get(key);
      final tagged = switch (v) {
        String s => {'t': 's', 'v': s},
        bool b => {'t': 'b', 'v': b},
        int i => {'t': 'i', 'v': i},
        double x => {'t': 'd', 'v': x},
        List<String> l => {'t': 'l', 'v': l},
        _ => null,
      };
      if (tagged != null) out[key] = tagged;
    }
    return out;
  }

  /// Replaces this device's setup with [values] from [exportForTransfer].
  /// Device-only keys ([_transferable] = false) are kept; everything else
  /// is removed first so nothing from the old setup lingers. The app must
  /// restart afterwards — services hold the old state in memory.
  Future<void> importForTransfer(Map<String, Object?> values) async {
    final keepArchive = values.containsKey(_transferArchiveExcluded);
    for (final key in _prefs.getKeys().toList()) {
      if (keepArchive && _isArchiveKey(key)) continue;
      if (_transferable(key)) await _prefs.remove(key);
    }
    for (final entry in values.entries) {
      if (!_transferable(entry.key)) continue;
      if (entry.key == _transferArchiveExcluded) continue;
      if (keepArchive && _isArchiveKey(entry.key)) continue;
      final tagged = entry.value;
      if (tagged is! Map) continue;
      final v = tagged['v'];
      switch (tagged['t']) {
        case 's' when v is String:
          await _prefs.setString(entry.key, v);
        case 'b' when v is bool:
          await _prefs.setBool(entry.key, v);
        case 'i' when v is int:
          await _prefs.setInt(entry.key, v);
        case 'd' when v is num:
          await _prefs.setDouble(entry.key, v.toDouble());
        case 'l' when v is List:
          await _prefs.setStringList(entry.key, [
            for (final s in v)
              if (s is String) s
          ]);
      }
    }
  }

  Future<void> clearCache() async {
    await _prefs.remove(AppConstants.keyEpgCache);
    await _prefs.remove(AppConstants.keyEpgLastUpdated);
    await _prefs.remove(AppConstants.keyLastFullSyncAt);
    final positionKeys = _prefs
        .getKeys()
        .where((k) =>
            k.startsWith(AppConstants.keyLastPositionPrefix) ||
            k.startsWith(AppConstants.keyLastDurationPrefix) ||
            k.startsWith('${AppConstants.keyLastFullSyncAt}_'))
        .toList();
    for (final key in positionKeys) {
      await _prefs.remove(key);
    }

    final dir = await _ensureCacheDir();
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
    await dir.create(recursive: true);
  }

  // --- Viewer-profile scoping ----------------------------------------------
  // See `AppConstants`' "Viewer profiles" section and `ViewerProfile`'s doc
  // comment for the feature. Every getter/setter above this point that's
  // marked "(per viewer)" below resolves its key through `_vk`/`_vkp`
  // instead of the bare constant — a no-op for `mainViewerId`, so an
  // upgrading install with no other viewer keeps reading/writing exactly
  // the key it always has.

  /// Appends the active viewer's suffix to [base] — a no-op for
  /// [AppConstants.mainViewerId]. Every per-viewer getter/setter is built
  /// from this (or [_vkp] for a key that's also namespaced per playlist).
  String _vk(String base) => _activeViewerId == AppConstants.mainViewerId
      ? base
      : '$base${AppConstants.viewerKeySuffix}$_activeViewerId';

  /// Same as [_vk], for a key namespaced per playlist *and* per viewer —
  /// the playlist suffix always comes first, viewer suffix last, so
  /// `deleteViewerData`'s single "ends with the viewer suffix" sweep still
  /// finds it regardless of which playlist it belongs to.
  String _vkp(String base, String playlistId) => _vk('${base}_$playlistId');

  String getActiveViewerId() => _activeViewerId;

  Future<void> setActiveViewerId(String id) async {
    _activeViewerId = id;
    await _prefs.setString(AppConstants.keyActiveViewerId, id);
    await _migrateSportsCoverage();
  }

  /// Always at least one entry (Main) — an install that's never configured
  /// any other viewer simply hasn't written this key yet.
  List<ViewerProfile> getViewerProfiles() {
    final raw = _prefs.getString(AppConstants.keyViewerProfiles);
    if (raw == null || raw.isEmpty) return [ViewerProfile.main()];
    try {
      final decoded = jsonDecode(raw) as List<dynamic>;
      final profiles = decoded
          .map((e) => ViewerProfile.fromJson(e as Map<String, dynamic>))
          .toList();
      return profiles.isEmpty ? [ViewerProfile.main()] : profiles;
    } catch (_) {
      return [ViewerProfile.main()];
    }
  }

  Future<void> setViewerProfiles(List<ViewerProfile> profiles) =>
      _prefs.setString(AppConstants.keyViewerProfiles,
          jsonEncode(profiles.map((p) => p.toJson()).toList()));

  /// `{v, salt, hash}` — see `ParentalPin` for how this is produced/checked.
  /// Null means no PIN has ever been set (no restricted profile exists yet).
  Map<String, dynamic>? getParentalPin() {
    final raw = _prefs.getString(AppConstants.keyParentalPin);
    if (raw == null) return null;
    try {
      return jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  Future<void> setParentalPin(Map<String, dynamic> record) =>
      _prefs.setString(AppConstants.keyParentalPin, jsonEncode(record));

  Future<void> clearParentalPin() => _prefs.remove(AppConstants.keyParentalPin);

  /// Consecutive wrong-PIN attempts — persisted (not just in memory) so
  /// restarting the app doesn't reset a lockout a kid could otherwise use
  /// to get unlimited guesses.
  int getPinFailCount() => _prefs.getInt(AppConstants.keyPinFailCount) ?? 0;
  Future<void> setPinFailCount(int count) =>
      _prefs.setInt(AppConstants.keyPinFailCount, count);

  DateTime? getPinLockedUntil() {
    final raw = _prefs.getString(AppConstants.keyPinLockedUntil);
    return raw == null ? null : DateTime.tryParse(raw);
  }

  Future<void> setPinLockedUntil(DateTime? time) => time == null
      ? _prefs.remove(AppConstants.keyPinLockedUntil)
      : _prefs.setString(
          AppConstants.keyPinLockedUntil, time.toIso8601String());

  bool getFavoritesDbReconciled() =>
      _prefs.getBool(AppConstants.keyFavoritesDbReconciled) ?? false;
  Future<void> setFavoritesDbReconciled(bool value) =>
      _prefs.setBool(AppConstants.keyFavoritesDbReconciled, value);

  /// A restricted viewer's shown-groups allowlist — see
  /// [AppConstants.keyShownGroups]'s doc comment. (Per playlist, per viewer.)
  Set<String> getShownGroups(String playlistId) =>
      (_prefs.getStringList(_vkp(AppConstants.keyShownGroups, playlistId)) ??
              [])
          .toSet();
  Future<void> setShownGroups(String playlistId, Set<String> groups) =>
      _prefs.setStringList(
          _vkp(AppConstants.keyShownGroups, playlistId), groups.toList());

  /// Removes every one of [viewerId]'s own keys — favorites, hidden/shown/
  /// favorited groups and hidden channels for every playlist, positions/
  /// durations, recent searches, and its last-channel id — in one sweep,
  /// since every per-viewer key (see [_vk]/[_vkp]) ends with the same
  /// `__vp_<id>` suffix regardless of which feature or playlist it belongs
  /// to. Refuses [AppConstants.mainViewerId] outright: that id's data lives
  /// under the bare, unsuffixed keys every pre-profiles install already
  /// depends on, which this must never touch. The per-viewer
  /// recently-played cache *file* is a separate concern, deleted by
  /// whoever owns that file (`PlaybackService`), not here.
  Future<void> deleteViewerData(String viewerId) async {
    if (viewerId == AppConstants.mainViewerId) return;
    final suffix = '${AppConstants.viewerKeySuffix}$viewerId';
    final keys = _prefs.getKeys().where((k) => k.endsWith(suffix)).toList();
    for (final key in keys) {
      await _prefs.remove(key);
    }
  }
}
