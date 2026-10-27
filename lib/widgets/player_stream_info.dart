import '../utils/guarded_dialog.dart';
import 'hold_to_activate.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:video_player_hdr/video_player_hdr.dart';
import '../l10n/l10n.dart';
import '../models/channel.dart';
import '../services/epg_service.dart';
import '../services/playback_service.dart';
import '../services/playback_health.dart';
import '../services/playback_timeline.dart';
import '../services/subtitle_tracks.dart';
import '../services/playlist_manager.dart';
import '../utils/playback_error_message.dart';
import '../utils/time_format.dart';
import 'player_chrome.dart';
import 'player_dialog.dart';

Future<void> showPlayerStreamInfo(BuildContext context,
        {bool fromHold = false}) =>
    showGuardedDialog<void>(
        context: context,
        barrierColor: const Color(0x40000000),
        builder: (_) => fromHold
            ? const SwallowHeldActivate(child: PlayerStreamInfo())
            : const PlayerStreamInfo());

/// Only samples the existing player while this panel is open. No HTTP probes,
/// stream opens or catalog scans. Track metadata reads are coalesced/throttled.
class PlayerStreamInfo extends StatefulWidget {
  const PlayerStreamInfo({super.key});
  @override
  State<PlayerStreamInfo> createState() => _PlayerStreamInfoState();
}

class _PlayerStreamInfoState extends State<PlayerStreamInfo> {
  Timer? _timer;
  PlaybackService? _playback;
  VideoPlayerHdrController? _controller;
  VideoTrack? _video;
  VideoAudioTrack? _audio;
  PlaybackTimeline? _timeline;
  List<VideoTrack>? _videos;
  List<VideoAudioTrack>? _audios;
  List<SubtitleTrack>? _subtitles;
  bool _reading = false;
  int _ticks = 0, _generation = 0;
  int? _bufferSeconds;
  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted ||
          !(ModalRoute.isCurrentOf(context) ?? false) ||
          (WidgetsBinding.instance.lifecycleState != null &&
              WidgetsBinding.instance.lifecycleState !=
                  AppLifecycleState.resumed)) {
        return;
      }
      _sample();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _playback = context.watch<PlaybackService>();
    if (!identical(_controller, _playback!.controller)) {
      _controller = _playback!.controller;
      _generation++;
      _video = null;
      _audio = null;
      _timeline = null;
      _videos = null;
      _audios = null;
      _subtitles = null;
      _bufferSeconds = null;
      _ticks = 0;
      // Deferred so a controller changing during a build never calls setState there.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _sample();
      });
    }
  }

  void _sample() {
    final controller = _controller;
    final value = controller?.value;
    int? buffer;
    if (value != null && value.isInitialized) {
      for (final range in value.buffered) {
        if (range.start <= value.position && range.end >= value.position) {
          final seconds = (range.end - value.position).inSeconds;
          if (buffer == null || seconds > buffer) buffer = seconds;
        }
      }
    }
    setState(() => _bufferSeconds = buffer);
    if (controller != null && value!.isInitialized && _ticks++ % 3 == 0) {
      unawaited(_readTracks(controller));
    }
  }

  Future<void> _readTracks(VideoPlayerHdrController controller) async {
    if (_reading) return;
    _reading = true;
    final generation = _generation;
    // Capabilities run independently. One slow/unsupported track API cannot
    // hold up the other metadata; the whole coalesced sample is bounded to 2s.
    void publish(VoidCallback update) {
      if (mounted && generation == _generation) setState(update);
    }

    List<VideoTrack>? videos;
    List<VideoAudioTrack>? audios;
    List<SubtitleTrack>? subtitles;
    PlaybackTimeline? timeline;
    await Future.wait([
      () async {
        try {
          if (controller.isVideoTrackSupportAvailable()) {
            videos = await controller
                .getVideoTracks()
                .timeout(const Duration(seconds: 2));
          }
        } catch (_) {}
        publish(() {
          _videos = videos;
          _video = videos?.where((t) => t.isSelected).firstOrNull;
        });
      }(),
      () async {
        try {
          if (controller.isAudioTrackSupportAvailable()) {
            audios = await controller
                .getAudioTracks()
                .timeout(const Duration(seconds: 2));
          }
        } catch (_) {}
        publish(() {
          _audios = audios;
          _audio = audios?.where((t) => t.isSelected).firstOrNull;
        });
      }(),
      () async {
        try {
          timeline = await PlaybackTimelineBridge.read(controller)
              .timeout(const Duration(seconds: 2));
        } catch (_) {}
        publish(() => _timeline = timeline);
      }(),
      () async {
        try {
          subtitles =
              await SubtitleTracks.list(SubtitleTracks.playerIdOf(controller))
                  .timeout(const Duration(seconds: 2));
        } catch (_) {}
        publish(() => _subtitles = subtitles);
      }(),
    ]);

    _reading = false;
  }

  @override
  void dispose() {
    _timer?.cancel();
    _generation++;
    super.dispose();
  }

  String _known(Object? value) =>
      value == null || value.toString().isEmpty ? tr('Not reported') : '$value';
  String _rate(int? value) => value == null || value <= 0
      ? tr('Not reported')
      : value >= 1000000
          ? '${(value / 1000000).toStringAsFixed(2)} Mb/s'
          : '${(value / 1000).round()} kb/s';
  Widget _group(String title, List<(String, String)> fields) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PlayerSection(title),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
                color: const Color(0x661F2A36),
                border: Border.all(color: const Color(0x303E4E60)),
                borderRadius: BorderRadius.circular(5)),
            child: LayoutBuilder(builder: (context, box) {
              final columns = box.maxWidth >= 260 ? 2 : 1;
              return Wrap(spacing: 12, runSpacing: 13, children: [
                for (final field in fields)
                  SizedBox(
                      width: (box.maxWidth - (columns - 1) * 12) / columns,
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(tr(field.$1),
                                style: const TextStyle(
                                    fontSize: 10, color: playerMuted)),
                            const SizedBox(height: 3),
                            Text(field.$2,
                                style: TextStyle(
                                    fontSize: 12,
                                    height: 1.25,
                                    fontWeight: FontWeight.w500,
                                    color: field.$2 == tr('Not reported')
                                        ? playerMuted
                                        : Colors.white)),
                          ])),
              ]);
            }),
          )
        ],
      );

  String _aspect(int width, int height) {
    if (width <= 0 || height <= 0) return tr('Not reported');
    final divisor = width.gcd(height);
    return '${width ~/ divisor}:${height ~/ divisor}';
  }

  @override
  Widget build(BuildContext context) {
    final playback = _playback!;
    final channel = playback.currentChannel;
    final value = _controller?.value;
    final health = playback.health.value;
    final rawError = playback.error ?? value?.errorDescription ?? health.error;
    final reconnecting = health.phase == StreamPhase.recovering;
    final state = switch (health.phase) {
      StreamPhase.recovering => 'Reconnecting',
      StreamPhase.failed => 'Connection problem',
      StreamPhase.connecting => 'Connecting',
      StreamPhase.buffering => 'Buffering',
      StreamPhase.suppressed => 'Playback interrupted',
      StreamPhase.playing => 'Playing',
      _ => rawError != null
          ? 'Connection problem'
          : value?.isInitialized != true
              ? 'Connecting'
              : value!.isBuffering
                  ? 'Buffering'
                  : value.isPlaying
                      ? 'Playing'
                      : 'Paused',
    };
    final uri = Uri.tryParse(_controller?.dataSource ?? channel?.url ?? '');
    final now = channel == null
        ? null
        : context.read<EpgService>().getCurrentProgram(channel.epgId);
    final width = (_video?.width ?? 0) > 0
        ? _video!.width!
        : value?.size.width.round() ?? 0;
    final height = (_video?.height ?? 0) > 0
        ? _video!.height!
        : value?.size.height.round() ?? 0;
    final live = channel == null || Channel.isLiveId(channel.rawId);
    final languages = _audios
        ?.map((t) => languageName(t.language))
        .where((s) => s.isNotEmpty)
        .toSet()
        .join(' · ');
    final selectedSubtitle = _subtitles?.where((t) => t.selected).firstOrNull;
    final external = _controller != null &&
        SubtitleTracks.externalFor.value ==
            SubtitleTracks.playerIdOf(_controller!);
    final subtitle = external
        ? (SubtitleTracks
                .externalLabel[SubtitleTracks.playerIdOf(_controller!)] ??
            tr('External subtitles'))
        : selectedSubtitle != null
            ? (selectedSubtitle.label ??
                languageName(selectedSubtitle.language))
            : _subtitles == null
                ? tr('Not reported')
                : tr('Off');
    return PlayerDialog(
        keyboardScroll: true,
        title: 'Stream info',
        subtitle: channel?.name,
        icon: Icons.info_outline_rounded,
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const SizedBox(height: 12),
          Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                  color: const Color(0x88202C38),
                  borderRadius: BorderRadius.circular(5)),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Icon(
                          rawError != null ? Icons.error_outline : Icons.circle,
                          size: rawError != null ? 18 : 8,
                          color: rawError != null
                              ? const Color(0xFFE99898)
                              : Theme.of(context).colorScheme.primary),
                      const SizedBox(width: 8),
                      Text(tr(state),
                          style: const TextStyle(
                              fontSize: 14, fontWeight: FontWeight.w600))
                    ]),
                    const SizedBox(height: 6),
                    Text(
                        reconnecting
                            ? playback.reconnectStatus ??
                                'Attempt ${health.attempt}/${health.maxAttempts} · ${health.retrySeconds > 0 ? "retry in ${health.retrySeconds}s" : "reopening stream"}'
                            : value?.isInitialized != true && rawError == null
                                ? tr(
                                    'Waiting for the stream. Details appear as the player receives them.')
                                : tr('Updated from the current player'),
                        style: const TextStyle(
                            fontSize: 11, height: 1.3, color: playerMuted)),
                  ])),
          if (rawError != null)
            Padding(
                padding: const EdgeInsets.all(8),
                child: Text(
                    playbackErrorMessage(rawError).replaceAll(
                        RegExp(r'https?://[^\s<>]+'), '[stream address]'),
                    style: const TextStyle(
                        fontSize: 12, color: Color(0xFFE99898)))),
          if (rawError != null &&
              !playbackErrorMessage(rawError)
                  .contains(safePlaybackError(rawError)))
            _group('Player error', [('Details', safePlaybackError(rawError))]),
          if (playback.health.lastFailure != null && rawError == null)
            _group('Last interruption', [
              (
                'Player report',
                safePlaybackError(playback.health.lastFailure!)
              ),
            ]),
          _group('Playback', [
            ('Type', tr(live ? 'Live TV' : 'On demand')),
            (
              'Buffered ahead',
              _bufferSeconds == null ? tr('Not reported') : '$_bufferSeconds s'
            ),
            (
              'Rewind',
              value?.isInitialized != true
                  ? tr('Waiting for stream')
                  : !live
                      ? tr('On-demand seeking')
                      : _timeline?.hasDvr == true
                          ? '${playerTime(_timeline!.duration)} ${tr('available')}'
                          : _timeline == null
                              ? tr('Not reported')
                              : tr('Not available on this stream')
            ),
            if (live && _timeline?.live == true)
              (
                'Behind live target',
                playerTime((_timeline!.defaultPosition - _timeline!.position)
                    .clamp(0, 1 << 53)),
              ),
            if (!live && value?.isInitialized == true)
              (
                'Position / duration',
                '${playerTime(value!.position.inMilliseconds)} / ${playerTime(value.duration.inMilliseconds)}'
              ),
            (
              'Playback speed',
              value == null
                  ? tr('Not reported')
                  : '${value.playbackSpeed.toStringAsFixed(2)}×'
            ),
            (
              'Volume',
              value == null
                  ? tr('Not reported')
                  : value.volume == 0
                      ? tr('Muted')
                      : '${(value.volume * 100).round()}%'
            ),
          ]),
          _group('Video', [
            (
              'Resolution',
              width > 0 && height > 0 ? '$width × $height' : tr('Not reported')
            ),
            ('Frame proportions', _aspect(width, height)),
            ('Video codec', _known(_video?.codec)),
            (
              'Frame rate',
              _video?.frameRate != null && _video!.frameRate! > 0
                  ? '${_video!.frameRate!.toStringAsFixed(2)} fps'
                  : tr('Not reported')
            ),
            ('Track bitrate', _rate(_video?.bitrate)),
            (
              'Video tracks',
              _videos == null ? tr('Not reported') : '${_videos!.length}'
            ),
            if (_video?.label?.isNotEmpty == true)
              ('Selected quality', _video!.label!),
          ]),
          _group('Audio', [
            ('Audio track', _known(_audio?.label ?? _audio?.language)),
            ('Audio codec', _known(_audio?.codec)),
            (
              'Channels',
              _audio?.channelCount == 1
                  ? tr('Mono · 1')
                  : _audio?.channelCount == 2
                      ? tr('Stereo · 2')
                      : _known(_audio?.channelCount)
            ),
            (
              'Sample rate',
              _audio?.sampleRate != null && _audio!.sampleRate! > 0
                  ? '${(_audio!.sampleRate! / 1000).toStringAsFixed(1)} kHz'
                  : tr('Not reported')
            ),
            ('Track bitrate', _rate(_audio?.bitrate)),
            (
              'Audio tracks',
              _audios == null ? tr('Not reported') : '${_audios!.length}'
            ),
            if (languages?.isNotEmpty == true)
              ('Available languages', languages!),
          ]),
          _group('Subtitles', [
            ('Selected', _known(subtitle)),
            (
              'Embedded tracks',
              _subtitles == null ? tr('Not reported') : '${_subtitles!.length}'
            ),
            if (selectedSubtitle?.closedCaptions == true)
              ('Type', tr('Closed captions')),
            if (value != null && value.captionOffset != Duration.zero)
              ('Timing offset', '${value.captionOffset.inMilliseconds} ms'),
          ]),
          _group('Source', [
            (
              'Server',
              uri?.host.isNotEmpty == true ? uri!.host : tr('Not reported')
            ),
            (
              'Connection',
              uri?.scheme.isNotEmpty == true
                  ? uri!.scheme.toUpperCase()
                  : tr('Not reported')
            ),
            (
              'Playlist',
              channel == null
                  ? tr('Not reported')
                  : _known(context
                      .read<PlaylistManager>()
                      .playlistNameFor(channel.playlistId))
            ),
            if (channel?.group.isNotEmpty == true) ('Group', channel!.group),
          ]),
          if (now != null) ...[
            const PlayerSection('On now'),
            Text(now.title,
                style:
                    const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
            const SizedBox(height: 5),
            Text(
                '${TimeFormat.hm.format(now.start)}–${TimeFormat.hm.format(now.stop)}',
                style: const TextStyle(fontSize: 11, color: playerMuted)),
            if (now.description?.isNotEmpty == true)
              Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(now.description!,
                      style: const TextStyle(
                          fontSize: 12, height: 1.4, color: playerMuted))),
          ],
        ]));
  }
}
