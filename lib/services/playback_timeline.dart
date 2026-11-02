import 'package:flutter/services.dart';
import 'package:video_player_hdr/video_player_hdr.dart';
import 'subtitle_tracks.dart';

/// A real native seek window, never inferred from a live stream's duration.
class PlaybackTimeline {
  const PlaybackTimeline(
      {required this.seekable,
      required this.live,
      required this.duration,
      required this.position,
      required this.buffered,
      required this.defaultPosition,
      this.windowStart});
  final bool seekable, live;
  final int duration, position, buffered, defaultPosition;
  final int? windowStart;
  bool get hasDvr => live && seekable && duration >= 30000;
  bool get behindLive => live && defaultPosition - position > 15000;
  factory PlaybackTimeline.fromMap(Map data) {
    int number(String key) => (data[key] as num?)?.toInt() ?? 0;
    return PlaybackTimeline(
        seekable: data['seekable'] == true,
        live: data['live'] == true,
        duration: number('duration'),
        position: number('position'),
        buffered: number('buffered'),
        defaultPosition: number('defaultPosition'),
        windowStart: (data['windowStart'] as num?)?.toInt());
  }
}

class PlaybackTimelineBridge {
  static const channel = MethodChannel('iptv-app/playback-timeline');
  static Future<PlaybackTimeline?> read(
      VideoPlayerHdrController controller) async {
    try {
      final data = await channel.invokeMapMethod<String, dynamic>(
          'snapshot', {'playerId': SubtitleTracks.playerIdOf(controller)});
      return data == null || data.isEmpty
          ? null
          : PlaybackTimeline.fromMap(data);
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  static Future<bool> seek(VideoPlayerHdrController controller, int position,
      PlaybackTimeline window,
      {required bool liveOnly}) async {
    try {
      return await channel.invokeMethod<bool>('seek', {
            'playerId': SubtitleTracks.playerIdOf(controller),
            'position': position,
            'windowStart': window.windowStart,
            'liveOnly': liveOnly
          }) ??
          false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  static Future<bool> goLive(VideoPlayerHdrController controller) async {
    try {
      return await channel.invokeMethod<bool>(
              'goLive', {'playerId': SubtitleTracks.playerIdOf(controller)}) ??
          false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }
}
