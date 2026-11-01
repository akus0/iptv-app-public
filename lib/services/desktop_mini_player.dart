import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../models/channel.dart';

/// Windows-only holder for a live channel's `Player`/`VideoController`
/// after `DesktopPlayerScreen`'s back button minimizes it — the Windows
/// equivalent of `PlaybackService` continuing to play a live channel in
/// the background once its fullscreen view is left. Exists at all because
/// `DesktopPlayerScreen` deliberately never touches `PlaybackService` (see
/// its own doc comment) — this is a second, much smaller version of the
/// same idea, holding exactly one channel's session at a time: whatever
/// was most recently minimized. A movie or episode never lands here — see
/// `DesktopPlayerScreen._handleBack`, which only hands off a *live*
/// channel; VOD still just stops on exit, same as mobile.
class DesktopMiniPlayer {
  DesktopMiniPlayer._();
  static final DesktopMiniPlayer instance = DesktopMiniPlayer._();

  /// Null when nothing is minimized — `DesktopLiveResumeHint` watches this
  /// directly to decide whether to show its resume pill at all.
  final ValueNotifier<Channel?> channel = ValueNotifier(null);

  Player? _player;
  VideoController? _controller;

  /// Read-only access for a preview surface (the Timeline guide's own
  /// mini-player box) that wants to render the actual minimized stream
  /// without taking ownership of it the way [take] does. Safe to mount a
  /// second `Video` widget against this alongside (briefly) whatever
  /// still-live widget handed it off — unlike `video_player_hdr`'s
  /// platform views (see `LiveResumeHint`'s doc comment for the real bug
  /// that caused on mobile), `media_kit`'s texture-based rendering
  /// supports multiple simultaneous `Video` widgets on one controller.
  VideoController? get controller => _controller;

  /// Re-opens a live preview that reports `completed` — same app-level
  /// safety net as `DesktopPlayerScreen`'s own, since mpv's reconnect
  /// options don't catch every way a live stream ends. Only set for a
  /// session started by [play]; [take]/[clear] cancel it.
  StreamSubscription<bool>? _completedSub;

  /// Starts [ch] straight into this holder, without opening
  /// `DesktopPlayerScreen` — the guide's "first click previews, second
  /// click goes fullscreen" path. Reuses the current `Player` when there is
  /// one (just opens the new stream on it) so switching channels in the
  /// preview box never stacks up decoders.
  void play(Channel ch) {
    if (_player == null || _controller == null) {
      final created = Player();
      // Same reconnect tuning as DesktopPlayerScreen.initState — see its
      // comment.
      (created.platform as NativePlayer).setProperty('demuxer-lavf-o',
          'reconnect=1,reconnect_at_eof=1,reconnect_streamed=1,reconnect_delay_max=5,rw_timeout=15000000');
      _player = created;
      _controller = VideoController(created);
    }
    final player = _player!;
    _completedSub?.cancel();
    _completedSub = player.stream.completed.listen((completed) {
      final current = channel.value;
      if (completed && current != null && _player == player) {
        player.open(Media(current.url));
      }
    });
    player.open(Media(ch.url));
    channel.value = ch;
  }

  void minimize(Channel ch, Player player, VideoController controller) {
    _completedSub?.cancel();
    _completedSub = null;
    // Only one minimized session can exist at a time (there's only one
    // pill) — if something else was already minimized, it has no other
    // reference anywhere, so it must be disposed here or it'd keep
    // decoding in the background forever with nothing left to stop it.
    if (_player != null && _player != player) _player!.dispose();
    _player = player;
    _controller = controller;
    channel.value = ch;
  }

  /// Hands the live session back to a freshly reopened
  /// `DesktopPlayerScreen` instead of it creating a new `Player` — resuming
  /// fullscreen must not restart the stream. Clears this holder's own
  /// state since that screen now owns the session again.
  (Player, VideoController)? take() {
    final player = _player;
    final controller = _controller;
    if (player == null || controller == null) return null;
    _completedSub?.cancel();
    _completedSub = null;
    _player = null;
    _controller = null;
    channel.value = null;
    return (player, controller);
  }

  /// Dispose the minimized Player before starting an unrelated stream. minimize() only
  /// replaces an existing session when another session is minimized, so fresh playback must
  /// call this explicitly.
  void clear() {
    _completedSub?.cancel();
    _completedSub = null;
    _player?.dispose();
    _player = null;
    _controller = null;
    channel.value = null;
  }
}
