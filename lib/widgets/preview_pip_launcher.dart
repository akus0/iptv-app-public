import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/channel.dart';
import '../screens/player_screen.dart';
import '../services/playback_service.dart';
import '../utils/player_route.dart';

/// When Android enters PiP from a preview, display just the existing player.
/// The channel/controller stay owned by PlaybackService: no second stream.
class PreviewPipLauncher extends StatefulWidget {
  const PreviewPipLauncher(
      {super.key, required this.navigatorKey, this.playerBuilder});
  final GlobalKey<NavigatorState> navigatorKey;
  final Widget Function(Channel)? playerBuilder;
  @override
  State<PreviewPipLauncher> createState() => _PreviewPipLauncherState();
}

class _PreviewPipLauncherState extends State<PreviewPipLauncher> {
  PlaybackService? _playback;
  bool _opening = false;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final playback = context.read<PlaybackService>();
    if (identical(playback, _playback)) return;
    _playback?.pictureInPicture.removeListener(_onMode);
    _playback = playback;
    playback.pictureInPicture.addListener(_onMode);
  }

  void _onMode() {
    final playback = _playback!;
    final channel = playback.currentChannel;
    final navigator = widget.navigatorKey.currentState;
    if (!mounted ||
        _opening ||
        !playback.pictureInPicture.active ||
        playback.isFullscreenActive ||
        playback.pictureInPicture.fullscreenVisible ||
        channel == null ||
        navigator == null) {
      return;
    }
    _opening = true;
    PlayerNavigation.open(
            navigator,
            (_) =>
                widget.playerBuilder?.call(channel) ??
                PlayerScreen(channel: channel))
        .whenComplete(() => _opening = false);
  }

  @override
  void dispose() {
    _playback?.pictureInPicture.removeListener(_onMode);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
