import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:video_player_hdr/video_player_hdr.dart';
import 'playback_timeline.dart';
import 'subtitle_tracks.dart';

enum StreamPhase {
  idle,
  connecting,
  buffering,
  recovering,
  playing,
  paused,
  suppressed,
  failed
}

@immutable
class StreamHealth {
  const StreamHealth(this.phase,
      {this.seconds = 0,
      this.bufferSeconds = 0,
      this.attempt = 0,
      this.maxAttempts = 3,
      this.retrySeconds = 0,
      this.error,
      this.detail});
  final StreamPhase phase;
  final int seconds, bufferSeconds, attempt, maxAttempts, retrySeconds;
  final String? error, detail;
  @override
  bool operator ==(Object other) =>
      other is StreamHealth &&
      other.phase == phase &&
      other.seconds == seconds &&
      other.bufferSeconds == bufferSeconds &&
      other.attempt == attempt &&
      other.maxAttempts == maxAttempts &&
      other.retrySeconds == retrySeconds &&
      other.error == error &&
      other.detail == detail;
  @override
  int get hashCode => Object.hash(phase, seconds, bufferSeconds, attempt,
      maxAttempts, retrySeconds, error, detail);
}

class PlaybackHealthBridge {
  static final _intent = Expando<bool>();
  static void rememberIntent(
      VideoPlayerHdrController controller, bool playing) {
    _intent[controller] = playing;
  }

  static bool? intendedPlaying(VideoPlayerHdrController controller) =>
      _intent[controller];
  static Future<Map<String, dynamic>?> read(
      VideoPlayerHdrController controller) async {
    if (SubtitleTracks.playerIdOf(controller) < 0) return null;
    try {
      final data = await PlaybackTimelineBridge.channel
          .invokeMapMethod<String, dynamic>('health', {
        'playerId': SubtitleTracks.playerIdOf(controller)
      }).timeout(const Duration(seconds: 1));
      if (data?['playWhenReady'] is bool) {
        _intent[controller] = data!['playWhenReady'] as bool;
      }
      return data;
    } catch (_) {
      return null;
    }
  }

  static Future<bool> configure(
      VideoPlayerHdrController controller, bool live) async {
    if (SubtitleTracks.playerIdOf(controller) < 0) return false;
    try {
      return await PlaybackTimelineBridge.channel.invokeMethod<bool>(
              'configureRecovery', {
            'playerId': SubtitleTracks.playerIdOf(controller),
            'live': live
          }).timeout(const Duration(seconds: 1)) ??
          false;
    } catch (_) {
      return false;
    }
  }
}

/// One lightweight status sampler for the shared player, not one per preview.
/// The native watchdog owns recovery (also while Flutter is backgrounded).
/// This notifier only rebuilds the small status overlay, never the Sports Hub.
class PlaybackHealthMonitor extends ValueNotifier<StreamHealth> {
  PlaybackHealthMonitor() : super(const StreamHealth(StreamPhase.idle));
  VideoPlayerHdrController? _controller;
  Timer? _timer;
  final _clock = Stopwatch()..start();
  Map<String, dynamic>? _native;
  bool _live = false, _configured = false, _reading = false, _disposed = false;
  int _generation = 0, _phaseAt = 0;
  Object? _flags;
  String? _error, _reconnecting;
  double lastVolume = 1;
  String? get lastFailure => _native?['lastFailure'] as String?;

  void attach(VideoPlayerHdrController? controller, {required bool live}) {
    _controller?.removeListener(_changed);
    _timer?.cancel();
    _generation++;
    _controller = controller;
    _live = live;
    _native = null;
    _configured = false;
    _flags = null;
    _phaseAt = _clock.elapsedMilliseconds;
    if (controller?.value.isInitialized == true &&
        !controller!.value.hasError) {
      lastVolume = controller.value.volume;
    }
    controller?.addListener(_changed);
    if (controller != null) {
      _timer = Timer.periodic(const Duration(seconds: 1), (_) => _poll());
    }
    _publish();
  }

  void updateExternal(String? error, String? reconnecting) {
    _error = error;
    _reconnecting = reconnecting;
    _publish();
  }

  void _changed() {
    final v = _controller?.value;
    if (v?.isInitialized == true && !v!.hasError) lastVolume = v.volume;
    final flags =
        (v?.isInitialized, v?.isBuffering, v?.isPlaying, v?.errorDescription);
    if (flags == _flags) return;
    _flags = flags;
    _publish();
  }

  Future<void> _poll() async {
    final c = _controller;
    if (_disposed || c == null || _reading) return;
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (lifecycle != null &&
        lifecycle != AppLifecycleState.resumed &&
        lifecycle != AppLifecycleState.inactive) {
      return;
    }
    _reading = true;
    final generation = _generation;
    if (!_configured) {
      final configured = await PlaybackHealthBridge.configure(c, _live);
      if (_disposed || generation != _generation) {
        _reading = false;
        return;
      }
      _configured = configured;
    }
    final data = await PlaybackHealthBridge.read(c);
    _reading = false;
    if (_disposed || generation != _generation) return;
    _native = data;
    _publish();
  }

  void _publish() {
    if (_disposed) return;
    final v = _controller?.value;
    final native = _native;
    final error = _error ??
        v?.errorDescription ??
        (native?['failed'] == true
            ? (native?['lastFailure'] as String?)
            : null);
    final StreamPhase phase;
    if (error != null) {
      phase = StreamPhase.failed;
    } else if (_reconnecting != null) {
      phase = StreamPhase.recovering;
    } else if (v == null) {
      phase = StreamPhase.idle;
    } else if (v.isInitialized && native?['playWhenReady'] == false) {
      phase = StreamPhase.paused;
    } else if (native?['recovering'] == true) {
      phase = StreamPhase.recovering;
    } else if (!v.isInitialized) {
      phase = StreamPhase.connecting;
    } else if ((native?['suppression'] as num? ?? 0) != 0) {
      phase = StreamPhase.suppressed;
    } else if (v.isBuffering ||
        native?['state'] == 2 ||
        (native?['playWhenReady'] == true && native?['playing'] == false)) {
      phase = StreamPhase.buffering;
    } else if (v.isPlaying || native?['playing'] == true) {
      phase = StreamPhase.playing;
    } else {
      phase = StreamPhase.paused;
    }
    if (phase != value.phase) _phaseAt = _clock.elapsedMilliseconds;
    final waiting = phase == StreamPhase.connecting ||
        phase == StreamPhase.buffering ||
        phase == StreamPhase.recovering;
    final candidate = StreamHealth(phase,
        seconds: waiting ? (_clock.elapsedMilliseconds - _phaseAt) ~/ 1000 : 0,
        bufferSeconds:
            waiting ? ((native?['bufferedMs'] as num? ?? 0) / 1000).floor() : 0,
        attempt: phase == StreamPhase.recovering
            ? (native?['attempt'] as num? ?? 0).toInt()
            : 0,
        maxAttempts: (native?['maxAttempts'] as num? ?? 3).toInt(),
        retrySeconds:
            waiting ? ((native?['retryInMs'] as num? ?? 0) / 1000).ceil() : 0,
        error: error,
        detail: _reconnecting ?? (native?['lastFailure'] as String?));
    if (candidate != value) value = candidate;
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    _timer?.cancel();
    _controller?.removeListener(_changed);
    _clock.stop();
    super.dispose();
  }
}
