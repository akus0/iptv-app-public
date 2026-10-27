// VesperTV patch: embedded subtitle tracks (MKV/MP4 text tracks) for the Flutter side.
//
// The stock plugin exposes audio/video tracks only. This adds, beside the pigeon API:
//  * MethodChannel "vespertv/subtitles": getTextTracks(playerId) -> list of maps,
//    selectTextTrack(playerId, group, track) (group < 0 = subtitles off);
//  * EventChannel "vespertv/subtitles/cues": {playerId, text} whenever the shown cues change
//    (text "" = nothing on screen). Flutter draws the text itself over the video.
// Text tracks start disabled on every player (Multiview tiles and live channels never want them);
// selecting one enables the text renderer. Image subtitles (PGS/VobSub) are not listed: their
// cues are bitmaps, which this text-only bridge can't carry.

package io.flutter.plugins.videoplayer;

import android.util.LongSparseArray;
import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.annotation.OptIn;
import androidx.media3.common.C;
import androidx.media3.common.Format;
import androidx.media3.common.MimeTypes;
import androidx.media3.common.Player;
import androidx.media3.common.TrackSelectionOverride;
import androidx.media3.common.Tracks;
import androidx.media3.common.text.Cue;
import androidx.media3.common.text.CueGroup;
import androidx.media3.common.util.UnstableApi;
import androidx.media3.exoplayer.trackselection.DefaultTrackSelector;
import io.flutter.plugin.common.BinaryMessenger;
import io.flutter.plugin.common.EventChannel;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

@OptIn(markerClass = UnstableApi.class)
final class SubtitleBridge implements MethodChannel.MethodCallHandler, EventChannel.StreamHandler {
  private final LongSparseArray<VideoPlayer> players;
  private final MethodChannel methods;
  private final EventChannel events;
  @Nullable private EventChannel.EventSink sink;

  SubtitleBridge(@NonNull BinaryMessenger messenger, @NonNull LongSparseArray<VideoPlayer> players) {
    this.players = players;
    methods = new MethodChannel(messenger, "vespertv/subtitles");
    events = new EventChannel(messenger, "vespertv/subtitles/cues");
    methods.setMethodCallHandler(this);
    events.setStreamHandler(this);
  }

  void dispose() {
    methods.setMethodCallHandler(null);
    events.setStreamHandler(null);
    sink = null;
  }

  /** Called for every new player: text off, and its cues forwarded to Flutter. */
  void attach(@NonNull VideoPlayer player, long id) {
    DefaultTrackSelector selector = player.trackSelector;
    if (selector != null) {
      selector.setParameters(
          selector.buildUponParameters().setTrackTypeDisabled(C.TRACK_TYPE_TEXT, true).build());
    }
    player
        .getExoPlayer()
        .addListener(
            new Player.Listener() {
              @Override
              public void onCues(@NonNull CueGroup cueGroup) {
                EventChannel.EventSink s = sink;
                if (s == null) return;
                StringBuilder text = new StringBuilder();
                for (Cue cue : cueGroup.cues) {
                  if (cue.text == null) continue;
                  if (text.length() > 0) text.append('\n');
                  text.append(cue.text);
                }
                Map<String, Object> event = new HashMap<>();
                event.put("playerId", id);
                event.put("text", text.toString());
                s.success(event);
              }
            });
  }

  private static boolean isTextFormat(@Nullable String mime) {
    return mime != null
        && !MimeTypes.APPLICATION_PGS.equals(mime)
        && !MimeTypes.APPLICATION_VOBSUB.equals(mime)
        && !MimeTypes.APPLICATION_DVBSUBS.equals(mime);
  }

  @Override
  public void onMethodCall(@NonNull MethodCall call, @NonNull MethodChannel.Result result) {
    Number idArg = call.argument("playerId");
    VideoPlayer player = idArg == null ? null : players.get(idArg.longValue());
    if (player == null) {
      result.error("no_player", "No player " + idArg, null);
      return;
    }
    switch (call.method) {
      case "getTextTracks":
        result.success(textTracks(player));
        break;
      case "selectTextTrack":
        Number group = call.argument("group");
        Number track = call.argument("track");
        try {
          select(player, group == null ? -1 : group.intValue(), track == null ? 0 : track.intValue());
          result.success(null);
        } catch (RuntimeException e) {
          result.error("select_failed", e.getMessage(), null);
        }
        break;
      default:
        result.notImplemented();
    }
  }

  private static List<Map<String, Object>> textTracks(@NonNull VideoPlayer player) {
    List<Map<String, Object>> out = new ArrayList<>();
    Tracks tracks = player.getExoPlayer().getCurrentTracks();
    for (int g = 0; g < tracks.getGroups().size(); g++) {
      Tracks.Group group = tracks.getGroups().get(g);
      if (group.getType() != C.TRACK_TYPE_TEXT) continue;
      for (int t = 0; t < group.length; t++) {
        Format f = group.getTrackFormat(t);
        String mime = f.sampleMimeType != null ? f.sampleMimeType : f.codecs;
        if (!isTextFormat(mime)) continue;
        Map<String, Object> m = new HashMap<>();
        m.put("group", g);
        m.put("track", t);
        m.put("language", f.language);
        m.put("label", f.label);
        m.put("forced", (f.selectionFlags & C.SELECTION_FLAG_FORCED) != 0);
        // Live closed captions (see HttpVideoAsset.liveCaptionExtractors).
        m.put(
            "cc",
            MimeTypes.APPLICATION_CEA608.equals(mime) || MimeTypes.APPLICATION_CEA708.equals(mime));
        m.put("selected", group.isTrackSelected(t));
        out.add(m);
      }
    }
    return out;
  }

  private static void select(@NonNull VideoPlayer player, int groupIndex, int trackIndex) {
    DefaultTrackSelector selector = player.trackSelector;
    if (selector == null) throw new IllegalStateException("No track selector");
    if (groupIndex < 0) {
      selector.setParameters(
          selector
              .buildUponParameters()
              .clearOverridesOfType(C.TRACK_TYPE_TEXT)
              .setTrackTypeDisabled(C.TRACK_TYPE_TEXT, true)
              .build());
      return;
    }
    Tracks tracks = player.getExoPlayer().getCurrentTracks();
    if (groupIndex >= tracks.getGroups().size()) {
      throw new IllegalArgumentException("groupIndex out of range");
    }
    Tracks.Group group = tracks.getGroups().get(groupIndex);
    if (group.getType() != C.TRACK_TYPE_TEXT || trackIndex < 0 || trackIndex >= group.length) {
      throw new IllegalArgumentException("not a text track");
    }
    selector.setParameters(
        selector
            .buildUponParameters()
            .setTrackTypeDisabled(C.TRACK_TYPE_TEXT, false)
            .setOverrideForType(new TrackSelectionOverride(group.getMediaTrackGroup(), trackIndex))
            .build());
  }

  @Override
  public void onListen(Object arguments, EventChannel.EventSink events) {
    sink = events;
  }

  @Override
  public void onCancel(Object arguments) {
    sink = null;
  }
}
