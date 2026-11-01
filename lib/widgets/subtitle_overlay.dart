import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:video_player_hdr/video_player_hdr.dart';

import '../services/playback_service.dart';
import '../services/storage_service.dart';
import '../services/subtitle_tracks.dart';

/// Draws the current subtitle over the fullscreen video (Android): the
/// selected embedded track's cues, or a downloaded add-on file (the
/// controller's caption, see SubtitleTracks.useExternal). Nothing shows
/// until something is picked in the player's Subtitles button — the native
/// side starts every player with text off.
class SubtitleOverlay extends StatefulWidget {
  const SubtitleOverlay({super.key, required this.controller});

  final VideoPlayerHdrController controller;

  @override
  State<SubtitleOverlay> createState() => _SubtitleOverlayState();
}

class _SubtitleOverlayState extends State<SubtitleOverlay> {
  StreamSubscription<({int playerId, String text})>? _sub;
  String _cue = '';

  int get _playerId => SubtitleTracks.playerIdOf(widget.controller);

  @override
  void initState() {
    super.initState();
    _sub = SubtitleTracks.cues.listen((c) {
      if (c.playerId == _playerId && c.text != _cue && mounted) {
        setState(() => _cue = c.text);
      }
    });
    _applySeriesChoice();
  }

  @override
  void didUpdateWidget(SubtitleOverlay old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      _cue = '';
      _applySeriesChoice();
    }
  }

  /// A new episode's player: the subtitles picked earlier in this series
  /// come back on (SubtitleTracks.applyForSeries). Movies never do.
  void _applySeriesChoice() {
    final channel = context.read<PlaybackService>().currentChannel;
    if (channel == null) return;
    unawaited(SubtitleTracks.applyForSeries(
            context.read<StorageService>(), channel, widget.controller)
        .catchError((_) {}));
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  // SRT files carry <i>/<b>/<font> tags and ASS-style {\an8} codes.
  static final _tags = RegExp(r'<[^>]+>|\{\\[^}]*\}');

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int?>(
      valueListenable: SubtitleTracks.externalFor,
      builder: (context, external, _) {
        if (external != _playerId) return _box(context, _cue);
        return ValueListenableBuilder<VideoPlayerHdrValue>(
          valueListenable: widget.controller,
          builder: (context, value, _) => _box(context, value.caption.text),
        );
      },
    );
  }

  Widget _box(BuildContext context, String raw) {
    final text = raw.replaceAll(_tags, '').trim();
    if (text.isEmpty) return const SizedBox.shrink();
    final size = MediaQuery.sizeOf(context);
    return Center(
      child: Container(
        constraints: BoxConstraints(maxWidth: size.width * 0.8),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: Colors.white,
            fontSize: (size.shortestSide / 22).clamp(16.0, 30.0),
            fontWeight: FontWeight.w600,
            height: 1.25,
          ),
        ),
      ),
    );
  }
}
