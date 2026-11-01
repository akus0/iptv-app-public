package io.flutter.plugins.videoplayer;

import android.util.LongSparseArray;
import androidx.annotation.NonNull;
import androidx.annotation.OptIn;
import androidx.media3.common.C;
import androidx.media3.common.Player;
import androidx.media3.common.Timeline;
import androidx.media3.common.util.UnstableApi;
import io.flutter.plugin.common.BinaryMessenger;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import java.util.HashMap;
import java.util.Map;

/** Reads the existing player's timeline. Never opens a stream or adds a player. */
@OptIn(markerClass = UnstableApi.class)
final class PlaybackTimelineBridge implements MethodChannel.MethodCallHandler {
  private final LongSparseArray<VideoPlayer> players;
  private final MethodChannel channel;

  PlaybackTimelineBridge(BinaryMessenger messenger, LongSparseArray<VideoPlayer> players) {
    this.players = players;
    channel = new MethodChannel(messenger, "iptv-app/playback-timeline");
    channel.setMethodCallHandler(this);
  }

  void dispose() { channel.setMethodCallHandler(null); }

  static boolean canSeek(Player player) {
    return player.isCommandAvailable(Player.COMMAND_SEEK_IN_CURRENT_MEDIA_ITEM)
        && player.isCurrentMediaItemSeekable() && player.getDuration() > 0;
  }

  static Map<String, Object> snapshot(Player player) {
    Map<String, Object> data = new HashMap<>();
    Timeline timeline = player.getCurrentTimeline();
    if (timeline.isEmpty()) return data;
    Timeline.Window window = timeline.getWindow(player.getCurrentMediaItemIndex(), new Timeline.Window());
    data.put("seekable", canSeek(player));
    data.put("live", player.isCurrentMediaItemLive());
    data.put("duration", Math.max(0, player.getDuration()));
    data.put("position", Math.max(0, player.getCurrentPosition()));
    data.put("buffered", Math.max(0, player.getBufferedPosition()));
    data.put("defaultPosition", Math.max(0, window.getDefaultPositionMs()));
    if (window.windowStartTimeMs != C.TIME_UNSET) data.put("windowStart", window.windowStartTimeMs);
    return data;
  }

  static boolean seek(Player player, long position, Long originalStart, boolean liveOnly) {
    if (!canSeek(player) || (liveOnly && !player.isCurrentMediaItemLive())) return false;
    Timeline timeline = player.getCurrentTimeline();
    if (timeline.isEmpty()) return false;
    Timeline.Window window = timeline.getWindow(player.getCurrentMediaItemIndex(), new Timeline.Window());
    // A sliding window can move while the viewer is dragging the scrubber.
    if (originalStart != null && window.windowStartTimeMs != C.TIME_UNSET) {
      position += originalStart - window.windowStartTimeMs;
    }
    player.seekTo(Math.max(0, Math.min(player.getDuration(), position)));
    return true;
  }

  static void applyMultiviewBudget(
      androidx.media3.exoplayer.trackselection.DefaultTrackSelector selector, int screens) {
    // Constraints select existing adaptive variants, never transcode or open
    // another connection. Keep the selector's fallback for fixed-quality feeds.
    int width = screens >= 4 ? 960 : 1280;
    int height = screens >= 4 ? 540 : 720;
    var current = selector.getParameters();
    if (current.maxVideoWidth == width && current.maxVideoHeight == height
        && current.maxVideoFrameRate == 30) return;
    selector.setParameters(current.buildUpon()
        .setMaxVideoSize(width, height).setMaxVideoFrameRate(30));
  }

  @Override
  public void onMethodCall(@NonNull MethodCall call, @NonNull MethodChannel.Result result) {
    Number id = call.argument("playerId");
    VideoPlayer video = id == null ? null : players.get(id.longValue());
    if (video == null) { result.success(null); return; }
    Player player = video.getExoPlayer();
    try {
      switch (call.method) {
        case "configureRecovery":
          if (Boolean.TRUE.equals(call.argument("live"))) video.enableLiveRecovery();
          result.success(true);
          break;
        case "multiviewBudget":
          Number screens = call.argument("screens");
          boolean texture = video instanceof io.flutter.plugins.videoplayer.texture.TextureVideoPlayer;
          if (texture && screens != null && video.trackSelector != null) {
            applyMultiviewBudget(video.trackSelector, screens.intValue());
          }
          result.success(texture);
          break;
        case "health": result.success(video.playbackHealth()); break;
        case "snapshot": result.success(snapshot(player)); break;
        case "seek":
          Number position = call.argument("position");
          Number start = call.argument("windowStart");
          result.success(position != null && seek(player, position.longValue(),
              start == null ? null : start.longValue(), Boolean.TRUE.equals(call.argument("liveOnly"))));
          break;
        case "goLive":
          boolean allowed = player.isCurrentMediaItemLive()
              && player.isCommandAvailable(Player.COMMAND_SEEK_TO_DEFAULT_POSITION);
          if (allowed) player.seekToDefaultPosition();
          result.success(allowed);
          break;
        default: result.notImplemented();
      }
    } catch (RuntimeException error) {
      result.error("timeline_unavailable", "Playback timeline changed", null);
    }
  }
}
