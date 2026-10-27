import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/channel.dart';
import 'archive_service.dart';
import 'playlist_manager.dart';
import 'storage_service.dart';
import 'tracker_api.dart';

/// Brings the viewer's Trakt / Simkl history *into* the app: episodes and
/// movies watched elsewhere get the app's own "watched" mark, and items
/// paused elsewhere get a resume point — both written into the saved
/// positions every screen already reads (progress bars, checkmarks, Next
/// Up, Continue Watching, resume), so no screen needs its own sync code.
///
/// Matching is by IMDb id (Media Hub) or TMDB id (IPTV titles, from the
/// provider's catalog). Only fills in: never clears a local mark, never
/// overwrites a local resume point. The other direction (plays, marks
/// made here) goes out through `WatchTracker` / [setWatched].
class TrackerSync {
  TrackerSync._();
  static final instance = TrackerSync._();

  ArchiveService? _service;
  TrackerApi _api = TrackerApi();

  void attach(ArchiveService service, {TrackerApi? api}) {
    _service = service;
    if (api != null) _api = api;
  }

  static const _maxAge = Duration(minutes: 5);
  TrackerHistory? _cached;
  DateTime? _cachedAt;
  Future<TrackerHistory?>? _inFlight;

  /// Drop the cache (a play just finished, an account was connected).
  void invalidate() {
    _cached = null;
    _cachedAt = null;
  }

  /// Every connected account's history merged; null when none is connected.
  Future<TrackerHistory?> history({bool force = false}) {
    final service = _service;
    if (service == null) return Future.value(null);
    if (!force &&
        _cached != null &&
        DateTime.now().difference(_cachedAt!) < _maxAge) {
      return Future.value(_cached);
    }
    return _inFlight ??= () async {
      try {
        final logins = await service.trackerLogins();
        if (logins.isEmpty) return null;
        final merged = TrackerHistory();
        for (final login in logins) {
          try {
            merged.merge(await _api.fetchHistory(login));
          } catch (e) {
            debugPrint('TrackerSync: ${login.kind.label} history failed: ${e.runtimeType}');
          }
        }
        _cached = merged;
        _cachedAt = DateTime.now();
        return merged;
      } finally {
        _inFlight = null;
      }
    }();
  }

  /// Fills in a show's episodes ([episodes]: channel id -> (season,
  /// episode)) from the trackers. True when anything changed (redraw).
  Future<bool> applyToSeries(
    StorageService storage, {
    String? imdb,
    String? tmdb,
    required Map<String, (int, int)> episodes,
  }) async {
    final keys = TrackerHistory.keys(imdb: imdb, tmdb: tmdb);
    if (keys.isEmpty || episodes.isEmpty) return false;
    final h = await history();
    if (h == null) return false;
    var changed = false;
    for (final e in episodes.entries) {
      final (season, number) = e.value;
      if (h.episodeWatched(keys, season, number)) {
        changed |= await _markWatched(storage, e.key);
      } else if (h.pausedEpisode(keys, season, number) case final p?) {
        changed |= await _resumeAt(storage, e.key, p.progress);
      }
    }
    return changed;
  }

  /// Same for one movie's channel.
  Future<bool> applyToMovie(StorageService storage,
      {String? imdb, String? tmdb, required String channelId}) async {
    final keys = TrackerHistory.keys(imdb: imdb, tmdb: tmdb);
    if (keys.isEmpty) return false;
    final h = await history();
    if (h == null) return false;
    if (h.movieWatched(keys)) return _markWatched(storage, channelId);
    if (h.pausedMovie(keys) case final p?) {
      return _resumeAt(storage, channelId, p.progress);
    }
    return false;
  }

  /// The provider's movies (by their catalog TMDB id): watched ones get
  /// their checkmark and paused ones join Continue Watching without being
  /// opened first. Run in the background after startup / connecting.
  Future<int> applyToCatalog(
      StorageService storage, Iterable<Channel> movies) async {
    final h = await history();
    if (h == null || (h.movies.isEmpty && h.paused.isEmpty)) return 0;
    var n = 0;
    var i = 0;
    for (final c in movies) {
      // Yield now and then: a catalog can be tens of thousands of titles.
      if (++i % 2000 == 0) await Future<void>.delayed(Duration.zero);
      final keys = TrackerHistory.keys(tmdb: c.tmdbId);
      if (keys.isEmpty) continue;
      if (h.movieWatched(keys)) {
        if (await _markWatched(storage, c.id)) n++;
      } else if (h.pausedMovie(keys) case final p?) {
        if (await _resumeAt(storage, c.id, p.progress)) n++;
      }
    }
    return n;
  }

  /// [applyToCatalog] over every enabled playlist's movies, in the
  /// background (after startup, after connecting an account). Nothing to
  /// do — and nothing fetched — when no account is connected.
  Future<void> syncCatalog(
      StorageService storage, PlaylistManager playlist) async {
    try {
      if ((await _service?.trackerLogins())?.isEmpty ?? true) return;
      final n = await applyToCatalog(
          storage, playlist.visibleChannels(category: 'vod'));
      if (n > 0) debugPrint('TrackerSync: $n movies filled in from trackers');
    } catch (e) {
      debugPrint('TrackerSync: catalog sync failed: ${e.runtimeType}');
    }
  }

  /// Marks [item] watched / unwatched on every connected account (the
  /// hold-OK toggle on an episode). Best effort, in the background.
  Future<void> setWatched(TrackedItem item, {required bool watched}) async {
    final service = _service;
    if (service == null || !item.hasIds) return;
    final logins = await service.trackerLogins();
    await Future.wait([
      for (final l in logins) _api.setWatched(l, item, watched: watched),
    ]);
    invalidate();
  }

  /// The app's own "watched" (position = duration). Leaves an existing
  /// mark alone. 1 ms stands in for an unknown duration (same as the
  /// series page's hold-OK toggle); the next play writes the real one.
  Future<bool> _markWatched(StorageService storage, String id) async {
    if (storage.isFullyWatched(id)) return false;
    var duration = storage.getLastDuration(id);
    if (duration <= 0 || storage.isResumeFraction(id)) duration = 1;
    await storage.clearResumeFraction(id);
    await storage.setLastDuration(id, duration);
    await storage.setLastPosition(id, duration);
    return true;
  }

  /// A resume point at [percent] — only where there's none locally.
  Future<bool> _resumeAt(
      StorageService storage, String id, double percent) async {
    if (storage.getLastPosition(id) > 0 || percent <= 0 || percent >= 95) {
      return false;
    }
    final duration = storage.getLastDuration(id);
    if (duration > 1) {
      await storage.setLastPosition(id, (duration * percent / 100).round());
    } else {
      await storage.setResumeFraction(id, percent / 100);
    }
    return true;
  }
}
