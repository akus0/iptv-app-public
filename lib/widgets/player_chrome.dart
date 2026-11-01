import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:video_player_hdr/video_player_hdr.dart';
import '../l10n/l10n.dart';
import '../services/playback_timeline.dart';
import '../services/playback_health.dart';
import 'hold_to_activate.dart';

const playerPanelColor = Color(0xF0171D25);
const playerMuted = Color(0xFF9BA8B7);

class PlayerAction extends StatelessWidget {
  const PlayerAction(
      {super.key,
      required this.icon,
      required this.label,
      required this.onPressed,
      this.focusNode,
      this.autofocus = false,
      this.selected = false,
      this.prominent = false,
      this.subtle = false,
      this.compact = false});
  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final FocusNode? focusNode;
  final bool selected, prominent, compact, autofocus, subtle;
  @override
  Widget build(BuildContext context) => IconButton(
      autofocus: autofocus,
      focusNode: focusNode,
      tooltip: tr(label),
      onPressed: onPressed,
      iconSize: prominent
          ? 28
          : subtle
              ? 18
              : 20,
      style: ButtonStyle(
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        minimumSize:
            WidgetStatePropertyAll(Size(compact ? 44 : 48, compact ? 44 : 48)),
        padding: const WidgetStatePropertyAll(EdgeInsets.all(8)),
        shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(5))),
        foregroundColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.disabled)
                ? Colors.white24
                : selected
                    ? Theme.of(context).colorScheme.primary
                    : subtle && !s.contains(WidgetState.focused)
                        ? const Color(0xFFF1F4F8)
                        : Colors.white.withValues(alpha: .88)),
        backgroundColor: WidgetStateProperty.resolveWith((s) =>
            s.contains(WidgetState.focused)
                ? const Color(0xFF36516A)
                : Colors.transparent),
        side: WidgetStateProperty.resolveWith((s) => BorderSide(
            color: s.contains(WidgetState.focused)
                ? Theme.of(context).colorScheme.primary
                : Colors.transparent)),
      ),
      icon: Icon(icon,
          shadows: subtle
              ? const [Shadow(color: Colors.black87, blurRadius: 4)]
              : null));
}

String playerTime(int milliseconds) {
  final d = Duration(milliseconds: milliseconds.clamp(0, 1 << 53));
  final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
  return d.inHours > 0 ? '${d.inHours}:$minutes:$seconds' : '$minutes:$seconds';
}

/// One transport for preview and fullscreen. Native timeline reads happen only
/// while visible, at most once a second. A drag commits ONE seek on release.
class PlayerTransport extends StatefulWidget {
  const PlayerTransport(
      {super.key,
      required this.controller,
      required this.isLive,
      this.active = true,
      this.showTimeline = true,
      this.compact = false,
      this.onActivity,
      this.playFocusNode,
      this.onPrevious,
      this.onNext,
      this.trailing = const [],
      this.trailingExtraWidth = 0});
  final VideoPlayerHdrController controller;
  final bool isLive, active, compact, showTimeline;
  final VoidCallback? onActivity, onPrevious, onNext;
  final FocusNode? playFocusNode;
  final List<Widget> trailing;
  final double trailingExtraWidth;
  @override
  State<PlayerTransport> createState() => _PlayerTransportState();
}

class _PlayerTransportState extends State<PlayerTransport> {
  PlaybackTimeline? _window, _dragWindow;
  double? _drag;
  int? _dragGeneration;
  Timer? _timer;
  bool _reading = false;
  int _generation = 0;
  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void didUpdateWidget(PlayerTransport old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller ||
        old.isLive != widget.isLive ||
        old.active != widget.active ||
        old.showTimeline != widget.showTimeline) {
      _generation++;
      _window = null;
      _drag = null;
      _dragWindow = null;
      _dragGeneration = null;
      _start();
    }
  }

  void _start() {
    _timer?.cancel();
    if (!widget.active || !widget.isLive || !widget.showTimeline) return;
    unawaited(_read());
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _read());
  }

  Future<void> _read() async {
    if (_reading || !widget.active || !widget.controller.value.isInitialized) {
      return;
    }
    _reading = true;
    final generation = _generation;
    try {
      final result = await PlaybackTimelineBridge.read(widget.controller);
      if (mounted && generation == _generation) {
        setState(() => _window = result);
      }
    } finally {
      _reading = false;
    }
  }

  @override
  void dispose() {
    _generation++;
    _timer?.cancel();
    super.dispose();
  }

  void _activity() => widget.onActivity?.call();
  Future<void> _seek(int position, [PlaybackTimeline? anchor]) async {
    _activity();
    final controller = widget.controller;
    try {
      if (widget.isLive) {
        final window = anchor ?? _window;
        if (window == null || !window.hasDvr) return;
        await PlaybackTimelineBridge.seek(controller, position, window,
            liveOnly: true);
        await _read();
      } else {
        await controller.seekTo(Duration(
            milliseconds:
                position.clamp(0, controller.value.duration.inMilliseconds)));
      }
    } catch (_) {/* A channel switch can invalidate a pending seek. */}
  }

  Future<void> _goLive() async {
    _activity();
    final controller = widget.controller;
    final generation = _generation;
    final moved = await PlaybackTimelineBridge.goLive(controller);
    if (!mounted || generation != _generation || !moved) return;
    try {
      await controller.play();
    } catch (_) {
      return;
    }
    await _read();
  }

  Future<void> _togglePlayback() async {
    _activity();
    final controller = widget.controller;
    final native = await PlaybackHealthBridge.read(controller);
    if (!mounted || !identical(controller, widget.controller)) return;
    final playing =
        (native?['playWhenReady'] as bool?) ?? controller.value.isPlaying;
    PlaybackHealthBridge.rememberIntent(controller, !playing);
    if (playing) {
      await controller.pause();
    } else {
      await controller.play();
    }
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<
          VideoPlayerHdrValue>(
      valueListenable: widget.controller,
      builder: (context, value, _) {
        final intendedPlaying =
            PlaybackHealthBridge.intendedPlaying(widget.controller) ??
                value.isPlaying;
        final window = _dragWindow ?? _window;
        final seekable = widget.showTimeline &&
            value.isInitialized &&
            (widget.isLive
                ? window?.hasDvr == true
                : value.duration.inMilliseconds > 0);
        final duration = widget.isLive
            ? window?.duration ?? 0
            : value.duration.inMilliseconds;
        final position = widget.isLive
            ? window?.position ?? 0
            : value.position.inMilliseconds;
        final shown = (_drag ?? position.toDouble())
            .clamp(0.0, duration > 0 ? duration.toDouble() : 1.0);
        final behind = widget.isLive && window?.behindLive == true;
        return LayoutBuilder(builder: (context, box) {
          final episodeCount = (widget.onPrevious == null ? 0 : 1) +
              (widget.onNext == null ? 0 : 1);
          final actionSize = widget.compact ? 44 : 48;
          final splitActions =
              (widget.trailing.length + 1 + episodeCount) * actionSize +
                      widget.trailingExtraWidth >
                  box.maxWidth;
          final actionCount =
              (splitActions ? 0 : widget.trailing.length) + 3 + episodeCount;
          final showSkip = seekable &&
              box.maxWidth >=
                  actionCount * (widget.compact ? 44 : 48) +
                      (splitActions ? 0 : widget.trailingExtraWidth);
          var liveButtonWidth = 0.0;
          if (!widget.compact && widget.isLive && seekable) {
            final label = TextPainter(
                text: TextSpan(
                    text: tr(behind ? 'Go live' : 'Live'),
                    style: DefaultTextStyle.of(context)
                        .style
                        .copyWith(fontSize: 11)),
                textDirection: Directionality.of(context),
                textScaler: MediaQuery.textScalerOf(context))
              ..layout();
            liveButtonWidth = (label.width + 40).clamp(64, double.infinity);
            label.dispose();
          }
          final inlineLive = !widget.compact &&
              box.maxWidth >=
                  actionCount * 48 +
                      liveButtonWidth +
                      widget.trailingExtraWidth;
          return Column(mainAxisSize: MainAxisSize.min, children: [
            if (seekable)
              Row(children: [
                Expanded(
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: Row(children: [
                        Expanded(
                            child: Text(
                                widget.isLive
                                    ? '${tr('Rewind')} · ${playerTime(duration)}'
                                    : playerTime(shown.round()),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    fontSize: 10, color: playerMuted))),
                        const SizedBox(width: 8),
                        Expanded(
                            child: Text(
                                widget.isLive
                                    ? (behind
                                        ? '${playerTime((window!.defaultPosition - shown).round())} ${tr('behind live')}'
                                        : tr('Live'))
                                    : playerTime(duration),
                                textAlign: TextAlign.right,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    fontSize: 10,
                                    color: behind
                                        ? playerMuted
                                        : Colors.white70))),
                      ])),
                  ExcludeFocus(
                      child: SizedBox(
                          height: 26,
                          child: SliderTheme(
                              data: SliderTheme.of(context).copyWith(
                                  trackHeight: 2,
                                  thumbShape: const RoundSliderThumbShape(
                                      enabledThumbRadius: 5),
                                  overlayShape: SliderComponentShape.noOverlay),
                              child: Slider(
                                key: const ValueKey('player-seek'),
                                value: shown,
                                max: duration.toDouble(),
                                secondaryTrackValue: widget.isLive
                                    ? (window?.buffered ?? 0)
                                        .clamp(shown, duration.toDouble())
                                        .toDouble()
                                    : null,
                                semanticFormatterCallback: (v) =>
                                    playerTime(v.round()),
                                onChangeStart: (v) {
                                  _activity();
                                  setState(() {
                                    _dragGeneration = _generation;
                                    _dragWindow = _window;
                                    _drag = v;
                                  });
                                },
                                onChanged: (v) {
                                  if (_dragGeneration != _generation) return;
                                  _activity();
                                  setState(() => _drag = v);
                                },
                                onChangeEnd: (v) {
                                  final valid = _dragGeneration == _generation;
                                  final anchor = _dragWindow;
                                  setState(() {
                                    _drag = null;
                                    _dragWindow = null;
                                    _dragGeneration = null;
                                  });
                                  if (valid) {
                                    unawaited(_seek(v.round(), anchor));
                                  }
                                },
                              )))),
                ])),
                if (!inlineLive && widget.isLive && behind)
                  TextButton(
                      key: const ValueKey('player-go-live'),
                      onPressed: _goLive,
                      style: TextButton.styleFrom(
                          minimumSize: const Size(60, 44),
                          padding: const EdgeInsets.symmetric(horizontal: 8)),
                      child: Text(tr('Go live'),
                          style: const TextStyle(fontSize: 11))),
              ]),
            Row(children: [
              if (widget.onPrevious != null)
                PlayerAction(
                    icon: Icons.skip_previous_rounded,
                    label: 'Previous episode',
                    onPressed: widget.onPrevious,
                    compact: widget.compact),
              if (showSkip)
                HoldToActivate(
                    holdDuration: const Duration(milliseconds: 400),
                    onTap: () => _seek(position - 10000),
                    onHold: () => _seek(position - 60000),
                    child: PlayerAction(
                        key: const ValueKey('player-rewind'),
                        icon: Icons.replay_10_rounded,
                        label: 'Back 10 seconds · hold for 1 minute',
                        compact: widget.compact,
                        onPressed: () => _seek(position - 10000))),
              PlayerAction(
                  key: const ValueKey('player-play-pause'),
                  focusNode: widget.playFocusNode,
                  icon: intendedPlaying
                      ? Icons.pause_rounded
                      : Icons.play_arrow_rounded,
                  label: intendedPlaying ? 'Pause' : 'Play',
                  prominent: true,
                  compact: widget.compact,
                  onPressed: value.isInitialized ? _togglePlayback : null),
              if (showSkip)
                HoldToActivate(
                    holdDuration: const Duration(milliseconds: 400),
                    onTap: () => _seek(position + 10000),
                    onHold: () => _seek(position + 60000),
                    child: PlayerAction(
                        key: const ValueKey('player-forward'),
                        icon: Icons.forward_10_rounded,
                        label: 'Forward 10 seconds · hold for 1 minute',
                        compact: widget.compact,
                        onPressed: () => _seek(position + 10000))),
              if (widget.onNext != null)
                PlayerAction(
                    icon: Icons.skip_next_rounded,
                    label: 'Next episode',
                    onPressed: widget.onNext,
                    compact: widget.compact),
              if (widget.isLive && seekable && inlineLive)
                TextButton(
                    key: const ValueKey('player-go-live'),
                    onPressed: _goLive,
                    child: Text(tr(behind ? 'Go live' : 'Live'),
                        style: const TextStyle(fontSize: 11))),
              const Spacer(),
              if (!splitActions) ...widget.trailing,
            ]),
            if (splitActions)
              Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: widget.trailing),
          ]);
        });
      });
}

/// Shared audio state follows the controller, not the lifetime of an overlay.
/// Weak keys avoid retaining old players after channel changes.
final _rememberedVolume = Expando<double>();

void _toggleMute(VideoPlayerHdrController controller) {
  final volume = controller.value.volume;
  if (volume > 0) {
    _rememberedVolume[controller] = volume;
    unawaited(controller.setVolume(0));
  } else {
    unawaited(controller.setVolume(_rememberedVolume[controller] ?? 1));
  }
}

class PlayerMuteButton extends StatelessWidget {
  const PlayerMuteButton(
      {super.key,
      required this.controller,
      this.compact = false,
      this.onActivity});
  final VideoPlayerHdrController controller;
  final bool compact;
  final VoidCallback? onActivity;
  @override
  Widget build(BuildContext context) =>
      ValueListenableBuilder<VideoPlayerHdrValue>(
          valueListenable: controller,
          builder: (context, value, _) => PlayerAction(
                key: const ValueKey('player-mute'),
                compact: compact,
                selected: value.volume == 0,
                icon: value.volume == 0
                    ? Icons.volume_off_outlined
                    : value.volume < .5
                        ? Icons.volume_down_outlined
                        : Icons.volume_up_outlined,
                label: value.volume == 0 ? 'Unmute' : 'Mute',
                onPressed: () {
                  onActivity?.call();
                  _toggleMute(controller);
                },
              ));
}

class PlayerVolume extends StatelessWidget {
  const PlayerVolume(
      {super.key,
      required this.controller,
      this.onActivity,
      this.showMute = true,
      this.compact = false});
  final VideoPlayerHdrController controller;
  final VoidCallback? onActivity;
  final bool showMute, compact;
  @override
  Widget build(BuildContext context) => ValueListenableBuilder<
          VideoPlayerHdrValue>(
      valueListenable: controller,
      builder: (context, value, _) => SizedBox(
          height: 44,
          child: Row(children: [
            if (showMute)
              PlayerMuteButton(
                  controller: controller,
                  compact: compact,
                  onActivity: onActivity)
            else
              Padding(
                  padding: const EdgeInsets.only(left: 12),
                  child: Text(tr('Volume'),
                      style:
                          const TextStyle(fontSize: 11, color: playerMuted))),
            Expanded(
                child: SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                        trackHeight: 2,
                        thumbShape:
                            const RoundSliderThumbShape(enabledThumbRadius: 5),
                        overlayShape:
                            const RoundSliderOverlayShape(overlayRadius: 12)),
                    child: Slider(
                        key: const ValueKey('player-volume-slider'),
                        value: value.volume.clamp(0, 1),
                        semanticFormatterCallback: (v) =>
                            '${(v * 100).round()}%',
                        onChangeStart: (_) => onActivity?.call(),
                        onChanged: (v) {
                          onActivity?.call();
                          if (v > 0) _rememberedVolume[controller] = v;
                          controller.setVolume(v);
                        }))),
            SizedBox(
                width: 34,
                child: Text('${(value.volume * 100).round()}%',
                    style: const TextStyle(fontSize: 10, color: playerMuted))),
          ])));
}

/// One audio control: tap the speaker to mute, drag beside it for level.
/// Only this small subtree listens to volume changes.
class PlayerAudioControl extends StatelessWidget {
  const PlayerAudioControl(
      {super.key,
      required this.controller,
      this.compact = false,
      this.width = 160,
      this.onActivity});
  final VideoPlayerHdrController controller;
  final bool compact;
  final double width;
  final VoidCallback? onActivity;
  @override
  Widget build(BuildContext context) => SizedBox(
        width: width,
        height: compact ? 44 : 48,
        child: Row(children: [
          PlayerMuteButton(
              controller: controller, compact: compact, onActivity: onActivity),
          Expanded(
              child: ValueListenableBuilder<VideoPlayerHdrValue>(
            valueListenable: controller,
            builder: (context, value, _) => SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 2,
                activeTrackColor: Colors.white70,
                inactiveTrackColor: Colors.white24,
                thumbColor: Colors.white,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 4),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
                showValueIndicator: ShowValueIndicator.onDrag,
              ),
              child: Semantics(
                  label: 'Volume',
                  child: Slider(
                    key: const ValueKey('player-volume-slider'),
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    value: value.volume.clamp(0, 1),
                    label: '${(value.volume * 100).round()}%',
                    semanticFormatterCallback: (v) => '${(v * 100).round()}%',
                    onChangeStart: (_) => onActivity?.call(),
                    onChangeEnd: (_) => onActivity?.call(),
                    onChanged: (v) {
                      onActivity?.call();
                      if (v > 0) _rememberedVolume[controller] = v;
                      controller.setVolume(v);
                    },
                  )),
            ),
          )),
        ]),
      );
}

/// Quiet secondary actions placed at the top edge by the owning player.
class PlayerUtilityActions extends StatelessWidget {
  const PlayerUtilityActions(
      {super.key,
      required this.onSettings,
      this.onInfo,
      this.onReconnect,
      this.onMultiview,
      this.onRotate,
      this.infoFocusNode,
      this.compact = true});
  final VoidCallback onSettings;
  final VoidCallback? onInfo, onReconnect, onRotate, onMultiview;
  final FocusNode? infoFocusNode;
  final bool compact;
  @override
  Widget build(BuildContext context) =>
      Row(mainAxisSize: MainAxisSize.min, children: [
        if (onRotate != null)
          PlayerAction(
              key: const ValueKey('player-rotate'),
              icon: Icons.screen_rotation_outlined,
              label: 'Rotate screen',
              compact: compact,
              subtle: true,
              onPressed: onRotate),
        if (onInfo != null)
          PlayerAction(
              key: const ValueKey('player-info'),
              focusNode: infoFocusNode,
              icon: Icons.info_outline_rounded,
              label: 'Stream info',
              compact: compact,
              subtle: true,
              onPressed: onInfo),
        if (onReconnect != null)
          PlayerAction(
              key: const ValueKey('player-reconnect'),
              icon: Icons.refresh_rounded,
              label: 'Reconnect',
              compact: compact,
              subtle: true,
              onPressed: onReconnect),
        if (onMultiview != null)
          PlayerAction(key: const ValueKey('player-multiview'),
              icon: Icons.grid_view, label: 'Multiview', compact: compact,
              subtle: true, onPressed: onMultiview),
        PlayerAction(
            key: const ValueKey('player-settings'),
            icon: Icons.tune_rounded,
            label: 'Playback settings',
            compact: compact,
            subtle: true,
            onPressed: onSettings),
      ]);
}

/// Transport stays at the bottom; expand/collapse always occupies the last slot.
class PlayerToolbar extends StatelessWidget {
  const PlayerToolbar(
      {super.key,
      required this.controller,
      required this.isLive,
      this.onFullscreen,
      this.fullscreen = false,
      this.compact = false,
      this.active = true,
      this.onActivity,
      this.onOpenChannels,
      this.onEnterPip,
      this.playFocusNode,
      this.onPrevious,
      this.onNext});
  final VideoPlayerHdrController controller;
  final bool isLive, fullscreen, compact, active;
  final VoidCallback? onFullscreen,
      onActivity,
      onOpenChannels,
      onEnterPip,
      onPrevious,
      onNext;
  final FocusNode? playFocusNode;
  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, box) {
        final actionSize = compact ? 44.0 : 48.0;
        final otherActions = 1 +
            (onOpenChannels == null ? 0 : 1) +
            (onEnterPip == null ? 0 : 1) +
            (onFullscreen == null ? 0 : 1);
        final audioWidth = compact
            ? (box.maxWidth - otherActions * actionSize).clamp(88.0, 108.0)
            : 160.0;
        return PlayerTransport(
          controller: controller,
          isLive: isLive,
          active: active,
          compact: compact,
          playFocusNode: playFocusNode,
          onActivity: onActivity,
          onPrevious: onPrevious,
          onNext: onNext,
          trailingExtraWidth: audioWidth - actionSize,
          trailing: [
            if (onOpenChannels != null)
              PlayerAction(
                  key: const ValueKey('player-channels'),
                  icon: Icons.view_list_outlined,
                  label: 'Channels',
                  compact: compact,
                  onPressed: () {
                    onActivity?.call();
                    onOpenChannels!();
                  }),
            PlayerAudioControl(
                controller: controller,
                compact: compact,
                width: audioWidth,
                onActivity: onActivity),
            if (onEnterPip != null)
              PlayerAction(
                  key: const ValueKey('player-pip'),
                  icon: Icons.picture_in_picture_alt_outlined,
                  label: 'Picture-in-picture',
                  compact: compact,
                  onPressed: () {
                    onActivity?.call();
                    onEnterPip!();
                  }),
            if (onFullscreen != null)
              PlayerAction(
                  key: const ValueKey('player-fullscreen'),
                  icon: fullscreen
                      ? Icons.fullscreen_exit_rounded
                      : Icons.fullscreen_rounded,
                  label: fullscreen ? 'Exit fullscreen' : 'Fullscreen',
                  compact: compact,
                  onPressed: onFullscreen),
          ],
        );
      });
}

/// Reports layout changes only, never playback ticks. Keeps subtitles above the
/// actual controls at every text size without rebuilding the native video.
class PlayerControlsSize extends SingleChildRenderObjectWidget {
  const PlayerControlsSize(
      {super.key, required this.onHeight, required super.child});
  final ValueChanged<double> onHeight;
  @override
  RenderObject createRenderObject(BuildContext context) =>
      _PlayerControlsSize(onHeight);
  @override
  void updateRenderObject(
      BuildContext context, covariant RenderProxyBox renderObject) {
    (renderObject as _PlayerControlsSize).onHeight = onHeight;
  }
}

class _PlayerControlsSize extends RenderProxyBox {
  _PlayerControlsSize(this.onHeight);
  ValueChanged<double> onHeight;
  double? _height;
  @override
  void performLayout() {
    super.performLayout();
    if (_height == size.height) return;
    _height = size.height;
    final height = size.height;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (attached && _height == height) onHeight(height);
    });
  }
}
