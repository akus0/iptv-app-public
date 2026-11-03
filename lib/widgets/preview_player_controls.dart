import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/playback_service.dart';
import '../services/playback_health.dart';
import '../services/app_preferences.dart';
import '../services/picture_in_picture_service.dart';
import '../screens/player_screen.dart';
import '../screens/multiview_screen.dart';
import '../models/channel.dart';
import 'player_chrome.dart';
import 'player_controls.dart';
import 'player_stream_info.dart';

/// Keeps the native video at a stable position while its light overlay changes.
class PreviewPlayerControls extends StatefulWidget {
  const PreviewPlayerControls(
      {super.key,
      required this.child,
      required this.onFullscreen,
      this.active = true});
  final Widget child;
  final VoidCallback? onFullscreen;
  final bool active;

  @override
  State<PreviewPlayerControls> createState() => _PreviewPlayerControlsState();
}

class _PreviewPlayerControlsState extends State<PreviewPlayerControls> {
  bool _visible = false;
  Timer? _timer;
  int _heldPointers = 0;
  final _focus = FocusScopeNode();
  PictureInPictureService? _pip;

  void _syncPip() {
    final pip = context.read<PlaybackService>().pictureInPicture;
    if (!identical(_pip, pip)) {
      _pip?.setPreviewVisible(this, false);
      _pip = pip;
    }
    _pip!.setPreviewVisible(
        this,
        widget.active &&
            widget.onFullscreen != null &&
            !context.read<AppPreferences>().isTelevision &&
            (ModalRoute.isCurrentOf(context) ?? false));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncPip();
  }

  void _hideLater() {
    _timer?.cancel();
    if (_heldPointers > 0) return;
    _timer = Timer(const Duration(seconds: 4), () {
      if (!mounted) return;
      if (_focus.hasFocus && context.read<AppPreferences>().isTelevision) {
        _hideLater();
        return;
      }
      setState(() => _visible = false);
    });
  }

  void _toggle() {
    setState(() => _visible = !_visible);
    if (_visible) {
      _hideLater();
    } else {
      _timer?.cancel();
    }
  }

  @override
  void didUpdateWidget(PreviewPlayerControls oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncPip();
    if (!widget.active) {
      _visible = false;
      _timer?.cancel();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _pip?.setPreviewVisible(this, false);
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final playback = context.watch<PlaybackService>();
    final controller = widget.active ? playback.controller : null;
    final enabled = widget.onFullscreen != null;
    return Stack(children: [
      widget.child,
      if (enabled)
        Positioned.fill(
            child: ValueListenableBuilder<StreamHealth>(
          valueListenable: playback.health,
          builder: (context, health, child) => IgnorePointer(
              // Let Retry / Info / linked-channel buttons in the video pane
              // receive taps instead of the preview's full-size tap target.
              ignoring: health.phase == StreamPhase.failed,
              child: child),
          child: Semantics(
              button: true,
              label:
                  controller == null ? 'Play preview' : 'Show player controls',
              child: GestureDetector(
                  key: const ValueKey('preview-controls-toggle'),
                  behavior: HitTestBehavior.opaque,
                  onTap: controller == null ? widget.onFullscreen : _toggle)),
        )),
      if (_visible && enabled && controller != null)
        Positioned.fill(
            child: ValueListenableBuilder<StreamHealth>(
                valueListenable: playback.health,
                builder: (context, health, child) => Visibility(
                    visible: health.phase != StreamPhase.failed, child: child!),
                child: FocusScope(
                    node: _focus,
                    child: Listener(
                      onPointerDown: (_) {
                        _heldPointers++;
                        _timer?.cancel();
                      },
                      onPointerUp: (_) => _releasePointer(),
                      onPointerCancel: (_) => _releasePointer(),
                      child: Stack(children: [
                        Positioned(
                            top: 0,
                            right: 0,
                            child: Container(
                              decoration: const BoxDecoration(
                                  gradient: LinearGradient(
                                      begin: Alignment.topCenter,
                                      end: Alignment.bottomCenter,
                                      colors: [
                                    Color(0x70000000),
                                    Colors.transparent
                                  ])),
                              child: PlayerUtilityActions(
                                onMultiview: context
                                            .read<AppPreferences>()
                                            .hideMultiview ||
                                        playback.currentChannel == null ||
                                        !Channel.isLiveId(
                                            playback.currentChannel!.rawId)
                                    ? null
                                    : () async {
                                        final channel = playback.currentChannel;
                                        final navigator = Navigator.of(context);
                                        final origin = ModalRoute.of(context);
                                        // Multiview releases the preview before opening its
                                        // players. Stopping here would unmount these controls
                                        // before they can navigate or restore the preview.
                                        await navigator.push(MaterialPageRoute(
                                            builder: (_) => MultiviewScreen(
                                                initialChannel: channel)));
                                        if (navigator.mounted &&
                                            origin?.isCurrent == true &&
                                            channel != null) {
                                          await playback.play(channel);
                                        }
                                      },
                                onInfo: () {
                                  _timer?.cancel();
                                  showPlayerStreamInfo(context)
                                      .whenComplete(() {
                                    if (mounted) _hideLater();
                                  });
                                },
                                onReconnect: playback.currentChannel != null &&
                                        Channel.isLiveId(
                                            playback.currentChannel!.rawId)
                                    ? () {
                                        _hideLater();
                                        playback.reloadCurrentChannel();
                                      }
                                    : null,
                                onSettings: () {
                                  _timer?.cancel();
                                  showPlayerSettings(context,
                                          controller: controller,
                                          channel: playback.currentChannel)
                                      .whenComplete(() {
                                    if (mounted) _hideLater();
                                  });
                                },
                              ),
                            )),
                        Positioned(
                            left: 0,
                            right: 0,
                            bottom: 0,
                            child: Container(
                              decoration: const BoxDecoration(
                                  gradient: LinearGradient(
                                      begin: Alignment.topCenter,
                                      end: Alignment.bottomCenter,
                                      colors: [
                                    Colors.transparent,
                                    Color(0xB3000000)
                                  ])),
                              padding: const EdgeInsets.fromLTRB(4, 4, 4, 2),
                              child: PlayerToolbar(
                                controller: controller,
                                isLive: playback.currentChannel == null ||
                                    Channel.isLiveId(
                                        playback.currentChannel!.rawId),
                                compact: true,
                                onActivity: _hideLater,
                                onFullscreen: widget.onFullscreen,
                                onEnterPip:
                                    playback.pictureInPicture.supported &&
                                            playback.currentChannel != null
                                        ? () {
                                            setState(() => _visible = false);
                                            PlayerScreen.open(
                                                Navigator.of(context),
                                                playback.currentChannel!,
                                                startInPictureInPicture: true);
                                          }
                                        : null,
                              ),
                            )),
                      ]),
                    )))),
    ]);
  }

  void _releasePointer() {
    if (_heldPointers > 0) _heldPointers--;
    _hideLater();
  }
}
