import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:video_player_hdr/video_player_hdr.dart';
import '../models/channel.dart';
import '../utils/playback_error_message.dart';
import 'playback_health.dart';
import 'playback_timeline.dart';
import 'subtitle_tracks.dart';
import 'package:flutter/services.dart';

class MultiviewCell extends ChangeNotifier {
  Channel? channel;
  VideoPlayerHdrController? controller;
  bool loading = false;
  String? error;
  int generation = 0;
  Completer<void>? cancellation;
  void cancel() {
    final pending = cancellation;
    if (pending != null && !pending.isCompleted) pending.complete();
  }

  Object? _flags;
  VoidCallback? _listener;
  void changed() => notifyListeners();
  void watch() {
    final c = controller;
    if (c == null) return;
    _listener = () {
      final v = c.value;
      final flags = (
        v.isInitialized,
        v.isBuffering,
        v.isPlaying,
        v.errorDescription,
        v.size,
        v.rotationCorrection
      );
      if (_flags == flags) return;
      _flags = flags;
      error = v.hasError ? playbackIssueTitle(v.errorDescription ?? '') : null;
      notifyListeners();
    };
    c.addListener(_listener!);
  }

  void unwatch() {
    if (_listener != null) controller?.removeListener(_listener!);
    _listener = null;
    _flags = null;
  }
}

typedef MultiviewControllerFactory = VideoPlayerHdrController Function(
    Channel channel);

/// Owns at most four players. Opens and releases are serialized; stale selections
/// cannot resurrect a removed tile or briefly require an extra decoder/stream.
class MultiviewSession extends ChangeNotifier {
  MultiviewSession(
      {MultiviewControllerFactory? createController,
      this.configure,
      this.configureGrid,
      this.openTimeout = const Duration(seconds: 25)})
      : createController = createController ??
            ((c) => VideoPlayerHdrController.networkUrl(Uri.parse(c.url),
                videoPlayerOptions: VideoPlayerOptions(
                    mixWithOthers: true, allowBackgroundPlayback: true)));
  final MultiviewControllerFactory createController;
  final Future<void> Function(VideoPlayerHdrController)? configure;
  final Future<void> Function(VideoPlayerHdrController, int)? configureGrid;
  Future<void> _configureGrid(VideoPlayerHdrController controller) async {
    if (configureGrid != null) {
      await configureGrid!(controller, _visibleCount);
      return;
    }
    try {
      await PlaybackTimelineBridge.channel
          .invokeMethod<bool>('multiviewBudget', {
        'playerId': SubtitleTracks.playerIdOf(controller),
        'screens': _visibleCount,
      });
    } on MissingPluginException {
      // Other platforms retain their existing stream selection.
    } on PlatformException {
      // A released player must not prevent layout changes.
    }
  }

  final Duration openTimeout;
  final cells = List.generate(4, (_) => MultiviewCell());
  int active = 0;
  bool muted = false,
      _closed = false,
      _suspended = false,
      _releaseFailed = false;
  int _visibleCount = 2;
  Future<void> _queue = Future.value(), _audioQueue = Future.value();
  Future<void> _lifecycleQueue = Future.value();
  int _audioRevision = 0;
  final Set<int> _resume = {};
  Future<void>? _closing;

  Future<void> _enqueue(Future<void> Function() work) {
    final job = _queue.then((_) => work());
    _queue = job.catchError((Object _) {});
    return job;
  }

  bool _owns(int i, int token) => !_closed && cells[i].generation == token;
  void _changed() {
    if (!_closed) notifyListeners();
  }

  /// Only duplicate screens are rejected locally. The provider decides whether
  /// another stream can be served; reported subscription caps are not enforced.
  String? problemFor(int i, Channel channel) {
    for (var j = 0; j < cells.length; j++) {
      final other = cells[j];
      if (j != i &&
          (other.loading || other.controller != null) &&
          (other.channel?.id == channel.id ||
              other.channel?.url == channel.url)) {
        return 'This channel is already open in another screen.';
      }
    }
    return null;
  }

  Future<void> assign(int i, Channel channel) async {
    if (_closed || i >= _visibleCount) return;
    final cell = cells[i];
    final problem = problemFor(i, channel);
    if (problem != null) throw StateError(problem);
    cell.cancel();
    final cancellation = cell.cancellation = Completer<void>();
    final token = ++cell.generation;
    cell.channel = channel;
    cell.loading = true;
    cell.error = null;
    cell.changed();
    _changed();
    await _enqueue(() async {
      if (!_owns(i, token)) return;
      await _release(cell);
      if (!_owns(i, token)) return;
      if (_releaseFailed) {
        cell.loading = false;
        cell.error =
            'Player could not close. Exit multiview before trying again.';
        cell.changed();
        return;
      }
      late final VideoPlayerHdrController c;
      try {
        c = createController(channel);
        cell.controller = c;
        await Future.any([
          c.initialize(viewType: VideoViewType.textureView),
          cancellation.future
        ]).timeout(openTimeout);
        if (!_owns(i, token)) {
          await _release(cell);
          return;
        }
        await c.setVolume(0);
        if (configure != null) {
          await configure!(c);
        } else {
          await PlaybackHealthBridge.configure(c, true);
        }
        if (!_owns(i, token)) {
          await _release(cell);
          return;
        }
        await _configureGrid(c);
        if (!_owns(i, token)) {
          await _release(cell);
          return;
        }
        cell.loading = false;
        cell.watch();
        if (cells[active].controller == null) active = i;
        await _applyAudio();
        if (!_suspended && i < _visibleCount) {
          await c.play();
        } else {
          _resume.add(i);
        }
        cell.changed();
        _changed();
      } catch (e) {
        await _release(cell);
        if (!_owns(i, token)) return;
        cell.loading = false;
        cell.error = e is TimeoutException
            ? 'Connection timed out'
            : playbackIssueTitle(e.toString());
        cell.changed();
        _changed();
      }
    });
  }

  Future<void> _release(MultiviewCell cell) async {
    cell.unwatch();
    final old = cell.controller;
    cell.controller = null;
    if (!_closed) cell.changed();
    // Allow the video widget to detach before destroying its texture.
    try {
      await old?.dispose();
    } catch (_) {
      _releaseFailed = true;
    }
  }

  Future<void> clear(int i) {
    if (_closed) return Future.value();
    final cell = cells[i];
    cell.cancel();
    ++cell.generation;
    cell.channel = null;
    cell.loading = false;
    cell.error = null;
    _resume.remove(i);
    cell.changed();
    if (active == i) {
      active =
          cells.indexWhere((c) => c.channel != null && c.controller != null);
      if (active < 0) active = 0;
    }
    _changed();
    return _enqueue(() async {
      await _release(cell);
      await _applyAudio();
    });
  }

  Future<void> selectAudio(int i) async {
    if (_closed || cells[i].channel == null || (active == i && !muted)) return;
    active = i;
    muted = false;
    _changed();
    await _applyAudio();
  }

  Future<void> toggleMute() async {
    if (_closed) return;
    muted = !muted;
    _changed();
    await _applyAudio();
  }

  Future<void> _applyAudio() {
    // Mute first, then unmute only the latest selection. Rapid clicks cannot
    // leave two audible players; selecting sound never reconnects a stream.
    final revision = ++_audioRevision;
    return _audioQueue = _audioQueue.catchError((Object _) {}).then((_) async {
      if (_closed || revision != _audioRevision) return;
      final target = muted ? null : cells[active].controller;
      for (final cell in cells) {
        try {
          final c = cell.controller;
          if (c != null && !identical(c, target) && c.value.volume != 0) {
            await c.setVolume(0);
          }
        } catch (_) {}
      }
      if (!_closed && !muted && revision == _audioRevision) {
        try {
          if (target != null && target.value.volume != 1) {
            await target.setVolume(1);
          }
        } catch (_) {}
      }
    });
  }

  Future<void> setVisibleCount(int count) async {
    final changed = _visibleCount != count;
    _visibleCount = count;
    // Hidden screens release decoders and provider connections, including
    // portrait rotation. They never keep secretly downloading in the background.
    for (var i = count; i < cells.length; i++) {
      await clear(i);
    }
    if (changed && !_closed) {
      for (final cell in cells.take(_visibleCount)) {
        final controller = cell.controller;
        if (controller != null && controller.value.isInitialized) {
          await _configureGrid(controller);
        }
      }
    }
  }

  Future<void> suspend(bool value) async {
    if (_closed || _suspended == value) return;
    _suspended = value;
    // A slow connection in another tile must not delay pausing existing players.
    // isPlaying can be false during buffering even though playback is intended.
    await (_lifecycleQueue =
        _lifecycleQueue.catchError((Object _) {}).then((_) async {
      if (_closed) return;
      for (var i = 0; i < cells.length; i++) {
        final c = cells[i].controller;
        if (_closed || c == null || !c.value.isInitialized) continue;
        try {
          if (_suspended) {
            _resume.add(i);
            await c.pause();
          } else if (_resume.remove(i) && i < _visibleCount) {
            await c.play();
          }
        } catch (_) {/* A removed tile may already have released its player. */}
      }
    }));
  }

  Future<void> close() => _closing ??= () async {
        _closed = true;
        for (final c in cells) {
          c.cancel();
          ++c.generation;
        }
        await _queue;
        await _audioQueue;
        await _lifecycleQueue;
        for (final c in cells) {
          await _release(c);
        }
      }();

  @override
  void dispose() {
    unawaited(close().whenComplete(() {
      for (final c in cells) {
        c.dispose();
      }
    }));
    super.dispose();
  }
}
