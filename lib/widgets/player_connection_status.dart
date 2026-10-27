import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../services/playback_service.dart';
import '../models/channel.dart';
import '../services/playback_health.dart';
import '../utils/playback_error_message.dart';
import 'player_chrome.dart';
import 'player_stream_info.dart';

/// Compact feedback over the existing surface. No layout movement or live probes.
class PlayerConnectionStatus extends StatelessWidget {
  const PlayerConnectionStatus(
      {super.key, this.onSwitch, this.switchFocusNode});
  final VoidCallback? onSwitch;
  final FocusNode? switchFocusNode;
  @override
  Widget build(BuildContext context) {
    final playback = context.read<PlaybackService>();
    return ValueListenableBuilder<StreamHealth>(
        valueListenable: playback.health,
        builder: (context, health, _) => PlayerStatusCard(
              health: health,
              onRetry: playback.currentChannel != null &&
                      Channel.isLiveId(playback.currentChannel!.rawId)
                  ? playback.reloadCurrentChannel
                  : null,
              onInfo: () => showPlayerStreamInfo(context),
              onSwitch: onSwitch,
              switchFocusNode: switchFocusNode,
            ));
  }
}

class PlayerStatusCard extends StatelessWidget {
  const PlayerStatusCard(
      {super.key,
      required this.health,
      this.onRetry,
      this.onInfo,
      this.onSwitch,
      this.switchFocusNode});
  final StreamHealth health;
  final VoidCallback? onRetry, onInfo, onSwitch;
  final FocusNode? switchFocusNode;
  @override
  Widget build(BuildContext context) {
    final h = health;
    if (h.phase == StreamPhase.idle ||
        h.phase == StreamPhase.playing ||
        h.phase == StreamPhase.paused ||
        (h.phase == StreamPhase.buffering && h.seconds < 2)) {
      return const SizedBox.shrink();
    }
    final failed = h.phase == StreamPhase.failed;
    final title = switch (h.phase) {
      StreamPhase.failed => playbackIssueTitle(h.error ?? ''),
      StreamPhase.recovering => h.attempt > 0
          ? 'Reconnecting · ${h.attempt}/${h.maxAttempts}'
          : 'Reconnecting',
      StreamPhase.buffering =>
        h.bufferSeconds > 0 ? 'Resuming playback' : 'Buffering',
      StreamPhase.suppressed => 'Playback interrupted',
      _ => h.seconds >= 8 ? 'Stream taking longer to open' : 'Connecting',
    };
    final detail = switch (h.phase) {
      StreamPhase.failed => h.error?.contains('[HTTP ') == true
          ? playbackErrorMessage(h.error!).split('\n').skip(1).join(' ')
          : playbackErrorMessage(h.error ?? ''),
      StreamPhase.recovering => h.retrySeconds > 0
          ? '${playbackRecoveryReason(h.detail)} · retry in ${h.retrySeconds}s'
          : '${playbackRecoveryReason(h.detail)} · reopening · ${h.seconds}s',
      StreamPhase.buffering => h.bufferSeconds > 0
          ? '${h.bufferSeconds}s buffered · waiting for playback'
          : 'Waiting for more stream data · ${h.seconds}s',
      StreamPhase.suppressed =>
        'Waiting for audio focus or an available audio output',
      _ => h.bufferSeconds > 0
          ? 'Receiving data · preparing playback'
          : 'Waiting for playable data · ${h.seconds}s',
    };
    return LayoutBuilder(
        builder: (context, box) => Center(
                child: ConstrainedBox(
              constraints:
                  BoxConstraints(maxWidth: 360, maxHeight: box.maxHeight),
              child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Container(
                    padding: const EdgeInsets.fromLTRB(10, 9, 8, 7),
                    decoration: BoxDecoration(
                        color: const Color(0xDE141B23),
                        border: Border.all(color: const Color(0x80394755)),
                        borderRadius: BorderRadius.circular(5)),
                    child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(children: [
                            if (failed || h.phase == StreamPhase.suppressed)
                              Icon(
                                  failed
                                      ? Icons.error_outline_rounded
                                      : Icons.pause_circle_outline,
                                  size: 16,
                                  color: failed
                                      ? const Color(0xFFE7A7A7)
                                      : playerMuted)
                            else
                              const SizedBox(
                                  width: 14,
                                  height: 14,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 1.5)),
                            const SizedBox(width: 8),
                            Expanded(
                                child: Text(title,
                                    maxLines: box.maxHeight < 180 ? 1 : 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                        fontSize: 12,
                                        height: 1.2,
                                        fontWeight: FontWeight.w600))),
                          ]),
                          const SizedBox(height: 5),
                          Text(detail,
                              maxLines: box.maxHeight < 180 &&
                                      MediaQuery.textScalerOf(context)
                                              .scale(10) >
                                          12
                                  ? 1
                                  : box.maxHeight < 220
                                      ? 2
                                      : 4,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  fontSize: 10,
                                  height: 1.3,
                                  color: playerMuted)),
                          if (failed)
                            Shortcuts(
                                shortcuts: const {
                                  SingleActivator(LogicalKeyboardKey.enter):
                                      ActivateIntent(),
                                  SingleActivator(LogicalKeyboardKey.select):
                                      ActivateIntent(),
                                  SingleActivator(LogicalKeyboardKey.arrowLeft):
                                      DirectionalFocusIntent(
                                          TraversalDirection.left),
                                  SingleActivator(
                                          LogicalKeyboardKey.arrowRight):
                                      DirectionalFocusIntent(
                                          TraversalDirection.right),
                                },
                                child: FocusScope(
                                    child: Row(children: [
                                  if (onRetry != null)
                                    _RecoverySwitchButton(
                                        key: const ValueKey('connection-retry'),
                                        focusNode: onSwitch == null
                                            ? switchFocusNode
                                            : null,
                                        onPressed: onRetry!,
                                        child: const Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Icon(Icons.refresh_rounded,
                                                  size: 16),
                                              SizedBox(width: 5),
                                              Text('Retry',
                                                  style:
                                                      TextStyle(fontSize: 11)),
                                            ])),
                                  if (onSwitch != null)
                                    Expanded(
                                        child: _RecoverySwitchButton(
                                            focusNode: switchFocusNode,
                                            onPressed: onSwitch!,
                                            child: const Text('Switch channel',
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style:
                                                    TextStyle(fontSize: 11)))),
                                  if (onInfo != null)
                                    PlayerAction(
                                        key: const ValueKey('connection-info'),
                                        icon: Icons.info_outline_rounded,
                                        label: 'Stream info',
                                        compact: true,
                                        onPressed: onInfo),
                                ]))),
                        ]),
                  )),
            )));
  }
}

class _RecoverySwitchButton extends StatefulWidget {
  const _RecoverySwitchButton(
      {super.key,
      required this.onPressed,
      required this.child,
      this.focusNode});
  final VoidCallback onPressed;
  final Widget child;
  final FocusNode? focusNode;
  @override
  State<_RecoverySwitchButton> createState() => _RecoverySwitchButtonState();
}

class _RecoverySwitchButtonState extends State<_RecoverySwitchButton> {
  @override
  void initState() {
    super.initState();
    if (widget.focusNode != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.focusNode?.requestFocus();
      });
    }
  }

  @override
  Widget build(BuildContext context) => TextButton(
      focusNode: widget.focusNode,
      onPressed: widget.onPressed,
      style: TextButton.styleFrom(
          minimumSize: const Size(44, 40),
          padding: const EdgeInsets.symmetric(horizontal: 6)),
      child: widget.child);
}
