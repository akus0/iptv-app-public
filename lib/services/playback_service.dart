import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:http/http.dart' as http;
import 'package:video_player_hdr/video_player_hdr.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../models/channel.dart';
import '../models/playlist_profile.dart';
import '../utils/constants.dart';
import 'playlist_manager.dart';
import 'storage_service.dart';
import 'watch_tracker.dart';
import 'picture_in_picture_service.dart';
import 'playback_health.dart';
import '../l10n/l10n.dart';

/// Owns the shared VideoPlayerHdrController and channel lifecycle. Preview and fullscreen
/// attach to the same playback session rather than opening duplicate decoders.
class PlaybackService extends ChangeNotifier {
  PlaybackService(this._storage, this._playlistManager) {
    pictureInPicture.addListener(notifyListeners);
  }

  final pictureInPicture = PictureInPictureService();
  final health = PlaybackHealthMonitor();
  int _request = 0;
  bool _disposed = false;
  Future<void>? _release;
  bool _releaseFailed = false;
  static const _releaseFailure =
      'The previous player could not close. Restart the app before opening another stream.';

  bool _owns(VideoPlayerHdrController c, int request) =>
      !_disposed && request == _request && identical(controller, c);

  @override
  void notifyListeners() {
    if (_disposed) return;
    health.updateExternal(error, reconnectStatus);
    super.notifyListeners();
  }

  Future<void> _releaseController(VideoPlayerHdrController? c) {
    // A second channel selection must also wait for the previous release.
    // No opening a replacement while the old provider connection is closing.
    final pending = _release;
    return _release = () async {
      if (pending != null) await pending;
      if (_releaseFailed) return;
      try {
        await c?.dispose();
      } catch (_) {
        // Do not open another provider connection when release is unconfirmed.
        _releaseFailed = true;
      }
    }();
  }

  @visibleForTesting
  VideoPlayerHdrController createController(Channel channel, {String? url}) =>
      VideoPlayerHdrController.networkUrl(Uri.parse(url ?? channel.url),
          videoPlayerOptions: _videoOptions,
          closedCaptionFile: channel.subtitleUrl == null
              ? null
              : _loadCaptions(channel.subtitleUrl!));

  Future<bool> _readyToPlay(
      VideoPlayerHdrController c, int request, bool live) async {
    if (!_owns(c, request)) return false;
    await PlaybackHealthBridge.configure(c, live);
    if (!_owns(c, request)) return false;
    notifyListeners();
    await SchedulerBinding.instance.endOfFrame;
    await Future<void>.delayed(const Duration(milliseconds: 250));
    return _owns(c, request);
  }

  VideoPlayerOptions get _videoOptions => VideoPlayerOptions(
        // Native lifecycle handling distinguishes screen lock from dismissal.
        // onPause must keep running
        // because a visible PiP window is a paused Activity.
        allowBackgroundPlayback: PictureInPictureService.isAndroid,
      );

  static const _recentlyPlayedCacheKey = 'recently_played';
  static const _maxRecentlyPlayed = 30;

  /// Main keeps the bare `recently_played` cache file name an upgrading
  /// install already has — every other viewer gets its own, so "Continue
  /// Watching" doesn't mix one viewer's history into another's. Same
  /// suffix convention as `StorageService`'s per-viewer prefs keys, just
  /// applied to a cache *file* name instead of a prefs key, since this
  /// list has always lived in the file cache, not SharedPreferences.
  String get _recentlyPlayedCacheKeyForViewer {
    final viewerId = _storage.getActiveViewerId();
    return viewerId == AppConstants.mainViewerId
        ? _recentlyPlayedCacheKey
        : '${_recentlyPlayedCacheKey}_vp_$viewerId';
  }

  final StorageService _storage;
  final PlaylistManager _playlistManager;

  Channel? currentChannel;

  /// The live list the user last picked a channel from (TvHomeScreen's
  /// Live list / Timeline guide, Favourites included) — what the player's
  /// CH+/CH- step through. Plain field, no notify; PlayerScreen falls back
  /// to the channel's own group when the playing channel isn't in it.
  List<Channel>? zapList;
  VideoPlayerHdrController? _controller;
  VideoPlayerHdrController? get controller => _controller;
  set controller(VideoPlayerHdrController? value) {
    _controller = value;
    if (!_disposed) {
      health.attach(value,
          live: currentChannel != null &&
              Channel.isLiveId(currentChannel!.rawId));
    }
    pictureInPicture.attach(value,
        title: currentChannel?.name,
        allowBackgroundAudio:
            currentChannel != null && Channel.isLiveId(currentChannel!.rawId));
  }

  Future<void>? initFuture;
  String? error;

  /// Set while a failed live stream is being retried against this
  /// playlist's backup servers (see [PlaylistProfile.backupServers]) —
  /// shown by `PlayerControls` in place of the dead-end playback error it
  /// would otherwise land on immediately. Null whenever no such retry is
  /// in progress, which is the overwhelmingly common case.
  String? reconnectStatus;

  /// True while `PlayerScreen` is actually mounted and showing this
  /// channel fullscreen — set/cleared by that screen's own
  /// `initState`/`dispose` via [setFullscreenActive]. `LiveResumeHint`
  /// reads this both to stop the global hold-Right gesture from firing
  /// again on top of an already-showing fullscreen view, and to hide its
  /// own reminder text while fullscreen is already showing.
  bool isFullscreenActive = false;

  Object? _fullscreenOwner;
  bool ownsFullscreen(Object owner) => identical(_fullscreenOwner, owner);

  void claimFullscreen(Object owner) {
    _fullscreenOwner = owner;
    isFullscreenActive = true;
    _notifyFullscreenChange();
  }

  bool releaseFullscreen(Object owner) {
    if (!ownsFullscreen(owner)) return false;
    _fullscreenOwner = null;
    isFullscreenActive = false;
    _notifyFullscreenChange();
    return true;
  }

  void _notifyFullscreenChange() {
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) => notifyListeners());
    } else {
      notifyListeners();
    }
  }

  /// Notify listeners when the pending channel changes so resume hints cannot retain a stale
  /// channel name.
  void setFullscreenActive(bool value) {
    if (isFullscreenActive == value) return;
    isFullscreenActive = value;
    notifyListeners();
  }

  /// Last live channel offered by LiveResumeHint after launch, without opening a decoder.
  /// Clear this pending state when any real [play] call starts.
  Channel? pendingResumeChannel;

  void setPendingResumeChannel(Channel? channel) {
    pendingResumeChannel = channel;
    notifyListeners();
  }

  Timer? _positionSaveTimer;

  /// Ordered episodes the currently playing channel came from (e.g. a
  /// whole series, season-by-season) — set by `SeriesDetailScreen` when an
  /// episode is opened, so playback can auto-advance near the end (see the
  /// position timer in [play]). Left in place across a switch rather than
  /// cleared, so advancing repeatedly through a season/series just keeps
  /// working — a channel that isn't actually in here (a movie, a live
  /// channel picked afterward) simply finds no match in [_nextInQueue] and
  /// this becomes a no-op until the next episode is opened.
  List<Channel>? _upNextQueue;

  /// Turns a queued episode with no URL yet (Archive: its stream is only
  /// looked up when it's about to play) into a playable one — see [play].
  /// Null for queues whose episodes already carry their URL.
  Future<Channel?> Function(Channel)? _upNextResolver;
  bool _resolvingQueued = false;

  void setUpNextQueue(List<Channel>? queue,
      {Future<Channel?> Function(Channel)? resolve}) {
    _upNextQueue = queue;
    _upNextResolver = resolve;
  }

  Channel? get _nextInQueue {
    final queue = _upNextQueue;
    final current = currentChannel;
    if (queue == null || current == null) return null;
    final index = queue.indexWhere((c) => c.id == current.id);
    if (index < 0 || index + 1 >= queue.length) return null;
    return queue[index + 1];
  }

  /// Public alias of [_nextInQueue] — lets the "Up Next" bubble in
  /// [PlayerScreen] show what's coming without duplicating the lookup.
  Channel? get nextUpChannel => _nextInQueue;

  Channel? get _previousInQueue {
    final queue = _upNextQueue;
    final current = currentChannel;
    if (queue == null || current == null) return null;
    final index = queue.indexWhere((c) => c.id == current.id);
    if (index <= 0) return null;
    return queue[index - 1];
  }

  /// Public alias of [_previousInQueue] — lets [PlayerControls]' explicit
  /// "Previous episode" button jump back without duplicating the lookup.
  /// Null (button hidden) for a movie/live channel — anything not actually
  /// in [_upNextQueue] — the same way [nextUpChannel] already behaves.
  Channel? get previousUpChannel => _previousInQueue;

  /// Set when the user dismisses the "Up Next" bubble — reset on every
  /// [play] call, so it only ever suppresses auto-advance for the episode
  /// it was dismissed on, not every episode after it.
  bool _autoAdvanceDismissed = false;

  void dismissAutoAdvance() {
    _autoAdvanceDismissed = true;
    notifyListeners();
  }

  List<Channel> _recentlyPlayed = [];

  /// Most-recently-played items, newest first — the raw material for a
  /// "Continue Watching" row. Filter by id prefix (`xt_vod_`/`xt_ep_`) and
  /// [StorageService.getLastPosition] to find what's actually resumable.
  List<Channel> get recentlyPlayed => _recentlyPlayed;

  bool get isPlayingSomething => currentChannel != null;

  Future<void> init() async {
    final raw = await _storage.readCacheFile(_recentlyPlayedCacheKeyForViewer);
    if (raw == null) return;
    try {
      _recentlyPlayed = (jsonDecode(raw) as List)
          .map((e) => Channel.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      _recentlyPlayed = [];
    }
  }

  /// Called by `ViewerProfileService.switchTo` after the active viewer has
  /// already changed — re-reads whichever viewer's recently-played list is
  /// now active (same logic as [init], just callable again later) and
  /// re-stamps `isFavorite` on every item against the newly-active
  /// viewer's own favorites, since these [Channel] objects don't live long
  /// enough to go through `PlaylistSession.restampFavorites`' own pass
  /// over its in-memory catalog lists.
  Future<void> reloadForViewer() async {
    await init();
    for (final c in _recentlyPlayed) {
      c.isFavorite = _playlistManager.isChannelFavorited(c.id);
    }
    notifyListeners();
  }

  /// The last [limit] distinct *live* channels watched, newest first — the
  /// TV layout's "History" popup. [recentlyPlayed] also carries movies/
  /// episodes (Continue Watching), so it's filtered here.
  List<Channel> recentLiveChannels({int limit = 10}) {
    final seen = <String>{};
    final result = <Channel>[];
    for (final c in _recentlyPlayed) {
      if (!Channel.isLiveId(c.rawId) || !seen.add(c.id)) continue;
      result.add(c);
      if (result.length >= limit) break;
    }
    return result;
  }

  /// Records [channel] in [recentlyPlayed] without playing it — for the
  /// Windows player, which never goes through [play] (see
  /// `DesktopPlayerScreen`'s doc comment) but should still feed History.
  Future<void> recordWatched(Channel channel) => _recordRecentlyPlayed(channel);

  /// Settings > General history clearing, for the active viewer. [live]
  /// true drops the live channels (the "History" popup); false drops the
  /// movies/episodes (Continue Watching) plus their saved positions.
  Future<void> clearRecentlyPlayed({required bool live}) async {
    _recentlyPlayed.removeWhere((c) => Channel.isLiveId(c.rawId) == live);
    await _storage.writeCacheFile(
      _recentlyPlayedCacheKeyForViewer,
      jsonEncode(_recentlyPlayed.map((c) => c.toJson()).toList()),
    );
    if (!live) await _storage.clearPlaybackPositions();
    notifyListeners();
  }

  Future<void> _recordRecentlyPlayed(Channel channel) async {
    _recentlyPlayed.removeWhere((c) => c.id == channel.id);
    _recentlyPlayed.insert(0, channel);
    if (_recentlyPlayed.length > _maxRecentlyPlayed) {
      _recentlyPlayed = _recentlyPlayed.sublist(0, _maxRecentlyPlayed);
    }
    await _storage.writeCacheFile(
      _recentlyPlayedCacheKeyForViewer,
      jsonEncode(_recentlyPlayed.map((c) => c.toJson()).toList()),
    );
    notifyListeners();
  }

  /// Starts playing [channel]. No-ops if it's already the current channel
  /// (so re-opening the fullscreen view for the channel the mini-player is
  /// already showing doesn't restart it).
  Future<void> play(Channel channel) async {
    // A queued episode whose stream isn't known yet (Archive Next / auto-
    // advance): resolve it first. Guarded, so the position timer's repeat
    // calls near the end don't start a second lookup.
    if (channel.url.isEmpty) {
      final resolve = _upNextResolver;
      if (resolve == null || _resolvingQueued) return;
      _resolvingQueued = true;
      Channel? resolved;
      try {
        resolved = await resolve(channel);
      } catch (e) {
        debugPrint('PlaybackService: up-next lookup failed: ${e.runtimeType}');
      } finally {
        _resolvingQueued = false;
      }
      if (resolved == null || resolved.url.isEmpty) {
        error = tr('No playable stream for this title.');
        notifyListeners();
        return;
      }
      channel = resolved;
    }
    // Archive titles belong to no playlist (see ArchiveService).
    if (!Channel.isArchiveId(channel.rawId) &&
        !_playlistManager.isPlaylistEnabled(channel.playlistId)) {
      error = tr(
          'This playlist is disabled on this device — enable it in Settings > Playlist Manager to watch.');
      notifyListeners();
      return;
    }
    if (currentChannel?.id == channel.id && controller != null) return;

    final request = ++_request;
    _reloadingCurrentChannel = false;
    await _teardown();
    if (_disposed || request != _request) return;
    if (_releaseFailed) {
      error = _releaseFailure;
      reconnectStatus = null;
      notifyListeners();
      return;
    }
    currentChannel = channel;
    error = null;
    reconnectStatus = null;
    _autoAdvanceDismissed = false;
    // Real playback has started — whatever cold-launch pill this might
    // have been about has nothing left to offer, whether this is the same
    // channel or a different one the user picked instead.
    pendingResumeChannel = null;
    notifyListeners();
    unawaited(_recordRecentlyPlayed(channel));

    // Apply saved positions only to VOD. Live streams have sliding windows and stale
    // positions can stall playback. Channel.isLiveId expects rawId, not the playlist-prefixed
    // composite id.
    final isLive = Channel.isLiveId(channel.rawId);
    final savedPositionMs = isLive ? 0 : _storage.getLastPosition(channel.id);
    final newController = createController(channel);
    controller = newController;

    initFuture = newController
        .initialize(viewType: VideoViewType.platformView)
        .timeout(const Duration(seconds: 30),
            onTimeout: () => throw TimeoutException(
                'No playable data received within 30 seconds [STREAM_OPEN_TIMEOUT]'))
        .then((_) async {
      if (!_owns(newController, request)) return;
      if (savedPositionMs > 0) {
        var seekMs = savedPositionMs;
        // A Trakt/Simkl resume point saved as a fraction (length unknown
        // until now): the real time, then the flag goes.
        if (_storage.isResumeFraction(channel.id)) {
          seekMs = (savedPositionMs /
                  StorageService.resumeFractionScale *
                  newController.value.duration.inMilliseconds)
              .round();
          await _storage.clearResumeFraction(channel.id);
        }
        if (!_owns(newController, request)) return;
        await newController.seekTo(Duration(milliseconds: seekMs));
      }
      // Surface first, then play. The video view (a platform view) is only
      // built once this controller reads as initialized; playing before
      // that meant the decoder started with no surface and got one
      // mid-stream, which some TV boxes' decoders answer with a restart:
      // one frame, black until the next keyframe, then the picture
      // (Timeline guide).
      if (!await _readyToPlay(newController, request, isLive)) return;
      await newController.play();
      if (!_owns(newController, request)) return;
      // Fire TV/Android TV boxes otherwise sleep the screen mid-stream on
      // idle-input timeout, exactly like they would for any non-video app —
      // there was nothing here telling the OS playback is active.
      unawaited(WakelockPlus.enable());
      // Trakt/Simkl, for Media Hub titles (a no-op otherwise).
      unawaited(WatchTracker.instance.started(channel.id));
      await _storage.setLastChannelId(channel.id);
      // Live streams report zero/unknown duration — that's fine, it just
      // means StorageService.getWatchedFraction has nothing to compute a
      // percentage from for those, which is the correct outcome (a live
      // channel doesn't have a "% watched").
      final duration = newController.value.duration;
      if (duration > Duration.zero) {
        await _storage.setLastDuration(channel.id, duration.inMilliseconds);
      }
      notifyListeners();
    }).catchError((e) async {
      if (!_owns(newController, request)) return;
      if (await _retryOnBackupServers(channel, e, request)) return;
      if (_disposed || request != _request) return;
      error = _releaseFailed ? _releaseFailure : e.toString();
      // A timed-out initialization must stop loading before the user retries.
      if (identical(controller, newController)) {
        controller = null;
        await _releaseController(newController);
      }
      if (request == _request) notifyListeners();
    });

    _positionSaveTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      final c = controller;
      final ch = currentChannel;
      // See the doc comment above `isLive` — never persist a "resume
      // point" for a live channel in the first place, not just skip
      // reading one back.
      if (c != null &&
          ch != null &&
          c.value.isInitialized &&
          !Channel.isLiveId(ch.rawId)) {
        _storage.setLastPosition(ch.id, c.value.position.inMilliseconds);
        final duration = c.value.duration;
        if (duration > Duration.zero) {
          _storage.setLastDuration(ch.id, duration.inMilliseconds);
          // Auto-advance a season/series near the end.
          final remaining = duration - c.value.position;
          if (remaining <= const Duration(seconds: 30) &&
              !_autoAdvanceDismissed) {
            final next = _nextInQueue;
            if (next != null) unawaited(play(next));
          }
        }
      }
    });

    notifyListeners();
  }

  /// True while a manual [reloadCurrentChannel] is in flight — guards
  /// against mashing the button mid-reload starting a second overlapping
  /// swap.
  bool _reloadingCurrentChannel = false;

  /// Explicit reconnect also releases first; never opens a second subscription
  /// connection while the previous player is alive. Automatic recovery stays native.
  Future<void> reloadCurrentChannel() async {
    final channel = currentChannel;
    if (channel == null ||
        !Channel.isLiveId(channel.rawId) ||
        _reloadingCurrentChannel) {
      return;
    }
    final request = ++_request;
    _reloadingCurrentChannel = true;
    reconnectStatus = tr('Reconnecting...');
    error = null;
    final previous = controller;
    final volume = previous?.value.hasError == true
        ? health.lastVolume
        : previous?.value.volume ?? 1.0;
    controller = null;
    notifyListeners();
    VideoPlayerHdrController? replacement;
    try {
      await _releaseController(previous);
      if (_releaseFailed) throw StateError(_releaseFailure);
      await Future<void>.delayed(_backupServerDelay);
      if (_disposed || request != _request) return;
      final next = replacement = createController(channel);
      await next.setVolume(volume);
      if (_disposed || request != _request) {
        await _releaseController(next);
        return;
      }
      controller = next;
      final future = next.initialize(viewType: VideoViewType.platformView).timeout(
          const Duration(seconds: 30),
          onTimeout: () => throw TimeoutException(
              'No playable data received within 30 seconds [STREAM_OPEN_TIMEOUT]'));
      initFuture = future;
      notifyListeners();
      await future;
      if (!await _readyToPlay(next, request, true)) return;
      await next.play();
      if (!_owns(next, request)) return;
      reconnectStatus = null;
      error = null;
      notifyListeners();
    } catch (e) {
      if (_disposed || request != _request) return;
      if (identical(controller, replacement)) controller = null;
      await _releaseController(replacement);
      if (_disposed || request != _request) return;
      reconnectStatus = null;
      error = e.toString();
      notifyListeners();
    } finally {
      if (request == _request) _reloadingCurrentChannel = false;
    }
  }

  /// Same spacing as `PlaylistSession`'s catalog-side fallback, for the
  /// same reason — don't fire every one of a provider's hostnames at once.
  static const _backupServerDelay = Duration(seconds: 3);

  /// A live stream that failed to open gets retried against this
  /// playlist's configured backup servers before the viewer is shown a
  /// dead end. Returns true if one of them took over, in which case the
  /// caller leaves [error] alone.
  ///
  /// Deliberately narrow about when it even tries:
  /// * live only — a VOD/episode URL is a specific file on a specific
  ///   server, not a channel every mirror of an account carries.
  /// * connection-shaped failures only — see [isDecoderPlaybackError]. No
  ///   number of alternate hostnames makes a decoder that can't handle
  ///   4K HDR HEVC suddenly handle it, and cycling servers for half a
  ///   minute before admitting that is strictly worse than saying so.
  Future<bool> _retryOnBackupServers(
      Channel channel, Object failure, int request) async {
    if (!Channel.isLiveId(channel.rawId)) return false;
    if (isPermanentPlaybackError(failure.toString())) return false;

    PlaylistProfile? profile;
    for (final p in _playlistManager.profiles) {
      if (p.id == channel.playlistId) {
        profile = p;
        break;
      }
    }
    if (profile == null || !profile.isXtream) return false;

    final currentOrigin = _originOf(channel.url);
    final candidates = profile.serverCandidates
        .where((s) => _originOf(s) != currentOrigin)
        .toList();
    if (candidates.isEmpty) return false;

    for (var i = 0; i < candidates.length; i++) {
      // Still the current channel? A viewer who changed channel (or
      // backed out entirely) while this was retrying has already said
      // what they want, and hijacking that with a late reconnect would
      // be worse than the failure being retried. [reconnectStatus] is
      // deliberately left alone on these bail-outs — whoever took over
      // (`play`/`stop`) has already cleared it, and clearing it here
      // could stomp a status that now belongs to *their* attempt.
      if (_disposed || request != _request) return false;

      final server = candidates[i];
      reconnectStatus = tr(
          'Trying to reconnect on backup servers ({p}/{candidates})...',
          {'p': i + 1, 'candidates': candidates.length});
      error = null;
      notifyListeners();
      final previous = controller;
      final volume = previous?.value.hasError == true
          ? health.lastVolume
          : previous?.value.volume ?? 1.0;
      controller = null;
      await _releaseController(previous);
      if (_releaseFailed) return false;
      await Future<void>.delayed(_backupServerDelay);
      if (_disposed || request != _request) return false;

      final retryUrl = _swapOrigin(channel.url, server);
      final retryController = createController(channel, url: retryUrl);
      controller = retryController;
      try {
        await retryController.setVolume(volume);
        if (!_owns(retryController, request)) return false;
        final future = retryController
            .initialize(viewType: VideoViewType.platformView)
            .timeout(const Duration(seconds: 30));
        initFuture = future;
        await future;
        if (!await _readyToPlay(retryController, request, true)) return false;
        await retryController.play();
        if (!_owns(retryController, request)) return false;
        reconnectStatus = null;
        error = null;
        unawaited(_playlistManager.rememberWorkingServer(profile.id, server));
        notifyListeners();
        return true;
      } catch (e) {
        if (_disposed || request != _request) return false;
        if (identical(controller, retryController)) controller = null;
        await _releaseController(retryController);
        if (isPermanentPlaybackError(e.toString())) break;
      }
    }

    if (request == _request && !_disposed) {
      reconnectStatus = null;
      notifyListeners();
    }
    return false;
  }

  /// The `scheme://host:port` of a URL, with nothing after it — what has
  /// to change to point the same stream at a different server.
  static String _originOf(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.host.isEmpty) return url;
    return uri.hasPort
        ? '${uri.scheme}://${uri.host}:${uri.port}'
        : '${uri.scheme}://${uri.host}';
  }

  /// Rebuilds a stream URL against [server], keeping the whole path
  /// (`/live/user/pass/12345.ts`) as-is — a backup server for the same
  /// account serves the same stream ids under the same credentials, so
  /// only the origin ever differs.
  static String _swapOrigin(String url, String server) {
    final uri = Uri.tryParse(url);
    if (uri == null) return url;
    var base = server.trim();
    while (base.endsWith('/')) {
      base = base.substring(0, base.length - 1);
    }
    final query = uri.hasQuery ? '?${uri.query}' : '';
    return '$base${uri.path}$query';
  }

  Future<void> stop() async {
    final request = ++_request;
    _reloadingCurrentChannel = false;
    await _teardown();
    if (_disposed || request != _request) return;
    currentChannel = null;
    error = null;
    reconnectStatus = null;
    // Clear the pending-resume hint when stopping, including handoff to Multiview, so a stale
    // cold-start suggestion cannot reappear.
    pendingResumeChannel = null;
    notifyListeners();
  }

  Future<ClosedCaptionFile> _loadCaptions(String url) async {
    final response = await http.get(Uri.parse(url));
    final content = response.body;
    if (url.toLowerCase().endsWith('.vtt')) {
      return WebVTTCaptionFile(content);
    }
    return SubRipCaptionFile(content);
  }

  Future<void> _teardown() async {
    _positionSaveTimer?.cancel();
    _positionSaveTimer = null;
    // A final exact-position save before disposing — the periodic timer
    // above only runs every 5 seconds, so without this, stopping shortly
    // after the last tick could leave Continue Watching up to 5 seconds
    // stale instead of reflecting exactly where playback actually left
    // off. Same isLive guard as the periodic save: never persist a
    // "resume point" for a live channel in the first place.
    final ch = currentChannel;
    final old = controller;
    final oldValue = old?.value;
    controller = null;
    initFuture = null;
    final released = _releaseController(old);
    if (ch != null &&
        old != null &&
        oldValue!.isInitialized &&
        !Channel.isLiveId(ch.rawId)) {
      await _storage.setLastPosition(ch.id, oldValue.position.inMilliseconds);
      final duration = oldValue.duration;
      if (duration > Duration.zero) {
        await _storage.setLastDuration(ch.id, duration.inMilliseconds);
        // Watched / paused at, for Trakt/Simkl (Media Hub titles only).
        unawaited(
            WatchTracker.instance.stopped(ch.id, oldValue.position, duration));
      }
    }
    unawaited(WakelockPlus.disable());
    await released;
  }

  @override
  void dispose() {
    _disposed = true;
    _request++;
    pictureInPicture.removeListener(notifyListeners);
    pictureInPicture.dispose();
    unawaited(_teardown());
    health.dispose();
    super.dispose();
  }
}

/// True for the one failure class that's about this device rather than
/// the stream's source: a `MediaCodecVideoRenderer` giving up on a format
/// (in practice 4K HDR HEVC 10-bit on a box whose decoder claims support
/// it doesn't actually have). Shared deliberately rather than pattern-
/// matched separately in each place that cares — `PlayerControls` uses it
/// to explain the limitation, `PlaybackService` uses it to *not* waste
/// the viewer's time cycling backup servers over something no server
/// change can fix, and those two must agree on what counts.
bool isDecoderPlaybackError(String raw) {
  final lower = raw.toLowerCase();
  return lower.contains('mediacodecvideorenderer') ||
      lower.contains('[unsupported_video:') ||
      (lower.contains('hevc') && lower.contains('10bit'));
}

/// Failures for which repeated provider requests cannot repair the current URL.
bool isPermanentPlaybackError(String raw) {
  if (isDecoderPlaybackError(raw)) return true;
  final status =
      int.tryParse(RegExp(r'\[HTTP (\d{3})\b').firstMatch(raw)?.group(1) ?? '');
  return const {401, 403, 404, 410, 429}.contains(status);
}
