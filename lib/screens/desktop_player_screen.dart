import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:provider/provider.dart';

import '../models/channel.dart';
import '../services/desktop_mini_player.dart';
import '../services/epg_service.dart';
import '../services/playback_service.dart';
import '../services/playlist_manager.dart';
import '../services/storage_service.dart';
import '../services/watch_tracker.dart';
import '../l10n/l10n.dart';
import '../widgets/player_side_panel.dart';
import '../widgets/desktop_subtitles.dart';

/// A deliberately standalone, Windows-only playback screen — see
/// `pubspec.yaml`'s media_kit comment for why this exists at all:
/// `video_player_hdr` (every other platform's player, completely
/// untouched by this file) has no Windows implementation whatsoever, and
/// `PlaybackService`/`PlayerScreen`/`PlayerControls`/`mini_player_bar.dart`
/// are all built directly around that package's own controller/value
/// shape (buffering state, captions, backup-server retry, Up Next,
/// position-save timers, the shared-controller-across-presentation-widgets
/// architecture...). Threading a platform-agnostic abstraction through all
/// of that is a real, separate project of its own — this screen
/// deliberately does NOT attempt it. It's a self-contained player: its own
/// `Player`, its own controls (favorite, reload, recall, skip ±10s,
/// previous/next episode), no shared state with `PlaybackService` at all.
/// Two consequences of that worth knowing: opening this screen does not
/// feed Continue Watching/resume position (both
/// `PlaybackService` features), and Recall's history
/// ([_DesktopLiveHistory]) is its own in-memory, session-only list rather
/// than `PlaybackService.recentlyPlayed` — it never calls
/// `PlaybackService.play()`. Live channels are still written to that list
/// via `PlaybackService.recordWatched`, for the TV home's History group.
///
/// Leaving a *live* channel via the back button doesn't stop it — same
/// "keeps playing in the background" idea as `PlaybackService` already
/// has for mobile — it hands the running `Player`/`VideoController` off to
/// [DesktopMiniPlayer] instead of disposing them (see [_handleBack]), and
/// `DesktopLiveResumeHint` (mounted globally in main.dart) shows a small
/// clickable pill until it's resumed. A movie or episode has no such
/// handoff — same as mobile, those just stop on exit.
class DesktopPlayerScreen extends StatefulWidget {
  const DesktopPlayerScreen({
    super.key,
    required this.channel,
    this.queue,
    this.resolveQueued,
    this.existingPlayer,
    this.existingController,
  });

  final Channel channel;

  /// Every episode of the series this channel belongs to, in order — only
  /// meaningful (and only ever passed) for a TV show episode, same concept
  /// as `PlaybackService.setUpNextQueue`. Drives the Previous/Next episode
  /// buttons; null/empty for a movie or live channel, which have no such
  /// queue.
  final List<Channel>? queue;

  /// Gives a [queue] episode that has no URL yet (Archive) its stream —
  /// same role as `PlaybackService.setUpNextQueue`'s `resolve`.
  final Future<Channel?> Function(Channel)? resolveQueued;

  /// Set together, only by `DesktopLiveResumeHint` when resuming a
  /// minimized live channel — reuses the session already playing in the
  /// background instead of this screen creating (and restarting the
  /// stream with) a new `Player`. Null for every other caller, which
  /// always starts a fresh session.
  final Player? existingPlayer;
  final VideoController? existingController;

  @override
  State<DesktopPlayerScreen> createState() => _DesktopPlayerScreenState();
}

/// Recall's backing history — see [DesktopPlayerScreen]'s doc comment for
/// why this is separate from `PlaybackService.recentlyPlayed` rather than
/// reusing it. A plain static list (not persisted): good enough for "go
/// back to the live channel I was just on" within one run of the app.
class _DesktopLiveHistory {
  static final List<Channel> _recent = [];

  static void record(Channel channel) {
    _recent.removeWhere((c) => c.id == channel.id);
    _recent.insert(0, channel);
    if (_recent.length > 6) _recent.removeRange(6, _recent.length);
  }

  static List<Channel> recentExcluding(String id) =>
      _recent.where((c) => c.id != id).take(4).toList();
}

class _DesktopPlayerScreenState extends State<DesktopPlayerScreen> {
  late final Player _player;
  late final VideoController _videoController;
  late Channel _currentChannel;
  bool _controlsVisible = true;

  /// [PlayerSidePanel] (Last channels / My Teams / Live now) on a live
  /// channel: the left-edge tab or the Left key opens it, Esc / a click on
  /// the video closes it — Windows has no remote Left.
  bool _panelOpen = false;
  final FocusNode _rootFocus = FocusNode(debugLabel: 'desktop-player-root');

  void _openPanel() {
    if (!_isLive) return;
    setState(() {
      _panelOpen = true;
      _controlsVisible = false;
    });
  }

  void _closePanel() {
    if (!_panelOpen) return;
    setState(() => _panelOpen = false);
    _rootFocus.requestFocus();
  }

  /// False when this screen is reusing a session handed off by
  /// [DesktopMiniPlayer] (see [initState]) — [dispose] must never tear
  /// down a `Player` it didn't create itself.
  bool _ownsPlayer = true;

  /// True once [_handleBack] has handed the live session to
  /// [DesktopMiniPlayer] — [dispose] must not also dispose it in that
  /// case, even though this screen did create it.
  bool _handedOffToMiniPlayer = false;

  /// Reopen live channels that unexpectedly report completion. Native reconnect options do
  /// not cover every clean EOF; VOD completion is handled separately.
  StreamSubscription<bool>? _completedSubscription;

  bool get _isLive => Channel.isLiveId(_currentChannel.rawId);
  List<Channel> get _queue => widget.queue ?? const [];
  int get _currentIndex => _queue.indexWhere((c) => c.id == _currentChannel.id);
  Channel? get _previousEpisode =>
      !_isLive && _currentIndex > 0 ? _queue[_currentIndex - 1] : null;
  Channel? get _nextEpisode =>
      !_isLive && _currentIndex >= 0 && _currentIndex < _queue.length - 1
          ? _queue[_currentIndex + 1]
          : null;

  @override
  void initState() {
    super.initState();
    _currentChannel = widget.channel;
    if (widget.existingPlayer != null && widget.existingController != null) {
      _player = widget.existingPlayer!;
      _videoController = widget.existingController!;
      _ownsPlayer = false;
    } else {
      _player = Player();
      // Bound live-stream I/O waits and enable native reconnects for streamed input. The
      // completion listener also handles clean EOF cases that native reconnect settings can
      // miss.
      (_player.platform as NativePlayer).setProperty('demuxer-lavf-o',
          'reconnect=1,reconnect_at_eof=1,reconnect_streamed=1,reconnect_delay_max=5,rw_timeout=15000000');
      _videoController = VideoController(_player);
      _player.open(Media(_currentChannel.url));
      _applySeriesSubtitles();
    }
    if (_isLive) _DesktopLiveHistory.record(_currentChannel);
    // Trakt/Simkl, for Media Hub titles (a no-op otherwise).
    unawaited(WatchTracker.instance.started(_currentChannel.id));
    // Persist the last live channel here because desktop playback does not call
    // PlaybackService.play(). Do not treat movies or episodes as live startup-resume targets.
    if (_isLive) {
      context.read<StorageService>().setLastChannelId(_currentChannel.id);
      // Feeds the TV home's "History" group (live channels only, so
      // Continue Watching is unaffected).
      context.read<PlaybackService>().recordWatched(_currentChannel);
    }
    if (_isLive) {
      _completedSubscription = _player.stream.completed.listen((completed) {
        if (completed && mounted) {
          debugPrint(
              '[auto-recover] live channel reported completed — reopening');
          _reload();
        }
      });
    }
  }

  /// Trakt/Simkl: where [_currentChannel] stopped (this player keeps no
  /// resume positions, so it reports straight from mpv's state).
  void _reportStopped() {
    final state = _player.state;
    unawaited(WatchTracker.instance
        .stopped(_currentChannel.id, state.position, state.duration));
  }

  @override
  void dispose() {
    if (!_handedOffToMiniPlayer) _reportStopped();
    _completedSubscription?.cancel();
    _rootFocus.dispose();
    if (_ownsPlayer && !_handedOffToMiniPlayer) _player.dispose();
    super.dispose();
  }

  /// A live channel keeps playing in the background instead of stopping —
  /// see the class doc comment. A movie or episode just pops normally;
  /// [dispose] tears its `Player` down the same way it always has.
  void _handleBack() {
    if (_isLive) {
      DesktopMiniPlayer.instance
          .minimize(_currentChannel, _player, _videoController);
      _handedOffToMiniPlayer = true;
    }
    Navigator.of(context).pop();
  }

  Future<void> _switchTo(Channel channel) async {
    if (channel.url.isEmpty) {
      final resolve = widget.resolveQueued;
      Channel? resolved;
      try {
        resolved = resolve == null ? null : await resolve(channel);
      } catch (_) {
        resolved = null;
      }
      if (!mounted) return;
      if (resolved == null || resolved.url.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(tr('No playable stream for this title.')),
          backgroundColor: Colors.red.shade900,
        ));
        return;
      }
      channel = resolved;
    }
    _reportStopped();
    setState(() => _currentChannel = channel);
    await _player.open(Media(channel.url));
    if (!mounted) return;
    unawaited(WatchTracker.instance.started(channel.id));
    _applySeriesSubtitles();
    if (_isLive) _DesktopLiveHistory.record(channel);
    // See initState's identical call for why — keeps it current across a
    // channel switch too, not just the one this screen opened with.
    if (_isLive) {
      context.read<StorageService>().setLastChannelId(channel.id);
      context.read<PlaybackService>().recordWatched(channel);
    }
  }

  /// An episode gets the subtitles chosen earlier in its series (same
  /// memory as Android's, see DesktopSubtitles.applyForSeries).
  void _applySeriesSubtitles() {
    if (_isLive) return;
    unawaited(DesktopSubtitles.applyForSeries(
            context.read<StorageService>(), _currentChannel, _player)
        .catchError((Object _) {}));
  }

  /// Manual reconnect for a stalled live stream — this screen has none of
  /// `PlaybackService`'s automatic backup-server retry, so a simple
  /// re-open is the only recovery available.
  void _reload() => _player.open(Media(_currentChannel.url));

  void _skip(Duration amount) {
    final current = _player.state.position;
    var target = current + amount;
    if (target < Duration.zero) target = Duration.zero;
    final duration = _player.state.duration;
    if (duration > Duration.zero && target > duration) target = duration;
    _player.seek(target);
  }

  Future<void> _openRecallPicker() async {
    final history = _DesktopLiveHistory.recentExcluding(_currentChannel.id);
    final chosen = await showModalBottomSheet<Channel>(
      context: context,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black38,
      builder: (sheetContext) => SafeArea(
        child: Container(
          margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.85),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                child: Text(
                  tr('Recall — recently watched'),
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.bold),
                ),
              ),
              if (history.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    tr('No other live channels watched yet this session.'),
                    style: const TextStyle(color: Colors.white70, fontSize: 13),
                  ),
                )
              else
                ...history.map((c) => ListTile(
                      dense: true,
                      leading:
                          const Icon(Icons.tv, color: Colors.white54, size: 20),
                      title: Text(c.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: Colors.white, fontSize: 14)),
                      onTap: () => Navigator.of(sheetContext).pop(c),
                    )),
            ],
          ),
        ),
      ),
    );
    if (chosen != null) _switchTo(chosen);
  }

  String _formatDuration(Duration d) {
    if (d.isNegative || d == Duration.zero) return '--:--';
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  /// The player bar, one row like the Android player's (1.0.18): title on
  /// the left, buttons centred (scaled down to fit, never more than 60 % of
  /// the width), time on the right; a slim seek bar above it for VOD. Live
  /// shows what's left of the programme instead of a seek bar — never from
  /// the stream's own duration (a DVR window looked like a ~30 s file).
  Widget _buildBar(PlaylistManager playlist) {
    return StreamBuilder<bool>(
      stream: _player.stream.playing,
      initialData: _player.state.playing,
      builder: (context, playingSnapshot) {
        final playing = playingSnapshot.data ?? false;
        final width = MediaQuery.sizeOf(context).width;
        final buttons = Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Recall goes furthest left: it means *backward*.
            if (_isLive)
              IconButton(
                icon: const Icon(Icons.history, color: Colors.white),
                tooltip: tr('Recall — go back to a recent channel'),
                onPressed: _openRecallPicker,
              ),
            IconButton(
              icon: Icon(
                _currentChannel.isFavorite ? Icons.star : Icons.star_border,
                color: _currentChannel.isFavorite ? Colors.amber : Colors.white,
              ),
              tooltip: _currentChannel.isFavorite
                  ? tr('Remove from favorites')
                  : tr('Add to favorites'),
              onPressed: () {
                playlist.toggleFavorite(_currentChannel);
                setState(() {});
              },
            ),
            if (_isLive)
              IconButton(
                icon: const Icon(Icons.refresh, color: Colors.white),
                tooltip: tr('Reload channel'),
                onPressed: _reload,
              ),
            if (_previousEpisode != null)
              IconButton(
                icon: const Icon(Icons.skip_previous, color: Colors.white),
                tooltip: tr('Previous episode'),
                onPressed: () => _switchTo(_previousEpisode!),
              ),
            if (!_isLive)
              IconButton(
                icon: const Icon(Icons.replay_10, color: Colors.white),
                onPressed: () => _skip(const Duration(seconds: -10)),
              ),
            IconButton(
              iconSize: 40,
              color: Colors.white,
              icon: Icon(playing ? Icons.pause : Icons.play_arrow),
              onPressed: () => playing ? _player.pause() : _player.play(),
            ),
            if (!_isLive)
              IconButton(
                icon: const Icon(Icons.forward_10, color: Colors.white),
                onPressed: () => _skip(const Duration(seconds: 10)),
              ),
            if (_nextEpisode != null)
              IconButton(
                icon: const Icon(Icons.skip_next, color: Colors.white),
                tooltip: tr('Next episode'),
                onPressed: () => _switchTo(_nextEpisode!),
              ),
            if (!_isLive)
              DesktopSubtitleButton(
                  // A new episode is a new file: fresh track list.
                  key: ValueKey(_currentChannel.id),
                  player: _player,
                  channel: _currentChannel),
          ],
        );
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!_isLive)
              StreamBuilder<Duration>(
                stream: _player.stream.position,
                initialData: _player.state.position,
                builder: (context, posSnapshot) {
                  final position = posSnapshot.data ?? Duration.zero;
                  final duration = _player.state.duration;
                  final sliderMax = duration.inMilliseconds > 0
                      ? duration.inMilliseconds.toDouble()
                      : 1.0;
                  return SizedBox(
                    height: 24,
                    child: SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        trackHeight: 3,
                        thumbShape:
                            const RoundSliderThumbShape(enabledThumbRadius: 6),
                        overlayShape:
                            const RoundSliderOverlayShape(overlayRadius: 12),
                      ),
                      child: Slider(
                        value: position.inMilliseconds
                            .clamp(0, sliderMax.toInt())
                            .toDouble(),
                        max: sliderMax,
                        onChanged: duration.inMilliseconds > 0
                            ? (v) =>
                                _player.seek(Duration(milliseconds: v.round()))
                            : null,
                      ),
                    ),
                  );
                },
              ),
            Row(
              children: [
                Expanded(
                  child: Text(
                    _currentChannel.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w600),
                  ),
                ),
                ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: width * 0.6),
                  child: FittedBox(fit: BoxFit.scaleDown, child: buttons),
                ),
                Expanded(
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: _isLive
                        ? _LiveRemainingLabel(channelId: _currentChannel.epgId)
                        : StreamBuilder<Duration>(
                            stream: _player.stream.position,
                            initialData: _player.state.position,
                            builder: (context, posSnapshot) => Text(
                              '${_formatDuration(posSnapshot.data ?? Duration.zero)}'
                              ' / ${_formatDuration(_player.state.duration)}',
                              style: const TextStyle(
                                  color: Colors.white70, fontSize: 13),
                            ),
                          ),
                  ),
                ),
              ],
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final playlist = context.watch<PlaylistManager>();
    final size = MediaQuery.sizeOf(context);
    return PopScope(
      // Back with the side panel open closes it first.
      canPop: !_panelOpen,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _closePanel();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Focus(
          focusNode: _rootFocus,
          autofocus: true,
          onKeyEvent: (_, event) {
            if (event is KeyDownEvent &&
                event.logicalKey == LogicalKeyboardKey.arrowLeft &&
                // Not while arrowing along the player bar's buttons.
                _rootFocus.hasPrimaryFocus &&
                _isLive &&
                !_panelOpen) {
              _openPanel();
              return KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          },
          child: GestureDetector(
            onTap: () => _panelOpen
                ? _closePanel()
                : setState(() => _controlsVisible = !_controlsVisible),
            child: Stack(
              fit: StackFit.expand,
              children: [
                // NoVideoControls — Video defaults to its own built-in
                // AdaptiveVideoControls overlay (play/pause, seek bar, and
                // its own fullscreen toggle). Left on, that showed up as a
                // second player bar stacked on top of this screen's own,
                // and its fullscreen button entered real native-window
                // fullscreen with no way back to this screen's back
                // button (which isn't part of that overlay at all) short of
                // closing the app. This screen's own overlay below is the
                // only controls surface.
                Center(
                    child: Video(
                        controller: _videoController,
                        controls: NoVideoControls)),
                if (_controlsVisible) ...[
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    child: Container(
                      padding: const EdgeInsets.fromLTRB(8, 8, 16, 24),
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Colors.black.withValues(alpha: 0.6),
                            Colors.transparent,
                          ],
                        ),
                      ),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: IconButton(
                          icon:
                              const Icon(Icons.arrow_back, color: Colors.white),
                          onPressed: _handleBack,
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: Container(
                      padding: const EdgeInsets.fromLTRB(16, 28, 16, 12),
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.bottomCenter,
                          end: Alignment.topCenter,
                          colors: [
                            Colors.black.withValues(alpha: 0.8),
                            Colors.transparent,
                          ],
                        ),
                      ),
                      child: _buildBar(playlist),
                    ),
                  ),
                  if (_isLive && !_panelOpen)
                    Positioned(
                      left: 0,
                      top: 0,
                      bottom: 0,
                      child: Center(
                        child: PlayerSidePanelTab(onTap: _openPanel),
                      ),
                    ),
                ],
                if (_panelOpen)
                  Positioned(
                    left: 0,
                    top: 0,
                    bottom: 0,
                    width: math.min(PlayerSidePanel.width, size.width * 0.88),
                    child: GestureDetector(
                      // Clicks on the panel's empty space mustn't reach the
                      // video's click-to-close.
                      onTap: () {},
                      child: PlayerSidePanel(
                        current: _currentChannel,
                        onClose: _closePanel,
                        onPlay: _switchTo,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The live-only replacement for the seek bar — same widget/logic as
/// `PlayerControls`' private `_LiveRemainingLabel` on mobile: how long is
/// left in whatever's currently airing, from EPG data, not the video
/// controller's own (untrustworthy, for a live stream) duration.
class _LiveRemainingLabel extends StatelessWidget {
  const _LiveRemainingLabel({required this.channelId});

  final String channelId;

  @override
  Widget build(BuildContext context) {
    final epg = context.watch<EpgService>();
    final programme = epg.getCurrentProgram(channelId);
    if (programme == null) return const SizedBox.shrink();
    final remaining = programme.stop.difference(DateTime.now());
    if (remaining.isNegative) return const SizedBox.shrink();
    final minutes = remaining.inMinutes;
    return Align(
      alignment: Alignment.centerRight,
      child: Text(
        minutes < 1
            ? tr('Ending now')
            : tr('{minutes} min left', {'minutes': minutes}),
        style: const TextStyle(color: Colors.white70, fontSize: 12),
      ),
    );
  }
}
