// Device-only smoke test. No catalogue, history, or subscription is opened.
// Supply a locally served test video with --dart-define=IPTV_TEST_VIDEO=...
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:video_player_hdr/video_player_hdr.dart';
import 'package:nox_iptv/services/picture_in_picture_service.dart';

void main() => runApp(const MaterialApp(home: _Smoke()));

class _Smoke extends StatefulWidget {
  const _Smoke();
  @override
  State<_Smoke> createState() => _SmokeState();
}

class _SmokeState extends State<_Smoke> {
  final _pip = PictureInPictureService();
  VideoPlayerHdrController? _controller;
  String _status = 'Starting local playback test';

  void _report(String status) {
    // ignore: avoid_print
    print('IPTV_SMOKE $status');
    if (mounted) setState(() => _status = status);
  }

  @override
  void initState() {
    super.initState();
    unawaited(_run());
  }

  Future<void> _release() async {
    _pip.attach(null);
    final old = _controller;
    if (mounted) setState(() => _controller = null);
    await WidgetsBinding.instance.endOfFrame;
    await old?.dispose();
  }

  Future<void> _run() async {
    try {
      final url = Uri.parse(const String.fromEnvironment('IPTV_TEST_VIDEO'));
      if (!url.hasScheme) throw StateError('Test video is required');
      for (var i = 0; i < 4; i++) {
        final player = VideoPlayerHdrController.networkUrl(url,
            videoPlayerOptions:
                VideoPlayerOptions(allowBackgroundPlayback: true));
        _controller = player;
        _pip.attach(player,
            title: 'Local playback diagnostic', allowBackgroundAudio: true);
        await player
            .initialize(viewType: VideoViewType.platformView)
            .timeout(const Duration(seconds: 20));
        if (!mounted) return;
        setState(() {});
        await WidgetsBinding.instance.endOfFrame;
        await player.play();
        await Future<void>.delayed(const Duration(seconds: 4));
        if (player.value.hasError ||
            player.value.position.inMilliseconds < 500) {
          throw StateError('Playback did not advance');
        }
        _report('cycle_${i + 1}_passed');
        if (i == 3) {
          _report('BACKGROUND_READY');
          for (var second = 0; second < 24; second += 4) {
            final before = player.value.position;
            await Future<void>.delayed(const Duration(seconds: 4));
            if (player.value.hasError || player.value.position <= before) {
              throw StateError('Background playback did not advance');
            }
            _report('background_progress_${second + 4}');
          }
        }
        await _release();
      }
      _report('PASSED');
    } catch (error) {
      _report('FAILED_${error.runtimeType}');
      await _release();
    }
  }

  @override
  void dispose() {
    _pip.dispose();
    unawaited(_controller?.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
      backgroundColor: const Color(0xff171d25),
      body: Stack(children: [
        if (_controller?.value.isInitialized == true)
          Center(
              child: AspectRatio(
                  aspectRatio: _controller!.value.aspectRatio,
                  child: VideoPlayerHdr(_controller!))),
        Positioned(
            left: 24,
            bottom: 24,
            child: ColoredBox(
                color: Colors.black87,
                child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(_status,
                        style: const TextStyle(color: Colors.white))))),
      ]));
}
