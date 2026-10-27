package io.flutter.plugins.videoplayer;

import static org.junit.Assert.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

import androidx.media3.common.C;
import androidx.media3.common.Player;
import androidx.media3.common.Timeline;
import androidx.media3.exoplayer.ExoPlayer;
import java.util.Map;
import org.junit.Before;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.annotation.Config;

@RunWith(RobolectricTestRunner.class)
@Config(sdk = 28)
public final class PlaybackTimelineBridgeTest {
  private ExoPlayer player;
  private long windowStart;

  @Before public void setUp() {
    player = mock(ExoPlayer.class);
    Timeline timeline = mock(Timeline.class);
    when(player.getCurrentTimeline()).thenReturn(timeline);
    when(timeline.isEmpty()).thenReturn(false);
    when(timeline.getWindow(anyInt(), any(Timeline.Window.class))).thenAnswer(call -> {
      Timeline.Window window = call.getArgument(1);
      window.windowStartTimeMs = windowStart;
      return window;
    });
    when(player.getDuration()).thenReturn(600000L);
    when(player.isCurrentMediaItemLive()).thenReturn(true);
    when(player.isCurrentMediaItemSeekable()).thenReturn(true);
    when(player.isCommandAvailable(Player.COMMAND_SEEK_IN_CURRENT_MEDIA_ITEM)).thenReturn(true);
    windowStart = 1000000L;
  }
  @Test public void gridBudgetKeepsFallbackAndRestoresTwoScreenQuality() {
    var selector = mock(androidx.media3.exoplayer.trackselection.DefaultTrackSelector.class);
    var initial = new androidx.media3.exoplayer.trackselection.DefaultTrackSelector.Parameters.Builder()
        .setPreferredAudioLanguage("en").setMaxVideoSize(1280, 720).setMaxVideoFrameRate(30).build();
    when(selector.getParameters()).thenReturn(initial);
    doAnswer(call -> {
      var builder = (androidx.media3.exoplayer.trackselection.DefaultTrackSelector.Parameters.Builder) call.getArgument(0);
      when(selector.getParameters()).thenReturn(builder.build());
      return null;
    }).when(selector).setParameters(any(androidx.media3.exoplayer.trackselection.DefaultTrackSelector.Parameters.Builder.class));
    PlaybackTimelineBridge.applyMultiviewBudget(selector, 4);
    assertEquals(960, selector.getParameters().maxVideoWidth);
    assertEquals(540, selector.getParameters().maxVideoHeight);
    assertTrue(selector.getParameters().exceedVideoConstraintsIfNecessary);
    assertEquals(initial.preferredAudioLanguages, selector.getParameters().preferredAudioLanguages);
    PlaybackTimelineBridge.applyMultiviewBudget(selector, 4);
    verify(selector, times(1)).setParameters(any(androidx.media3.exoplayer.trackselection.DefaultTrackSelector.Parameters.Builder.class));
    PlaybackTimelineBridge.applyMultiviewBudget(selector, 2);
    assertEquals(1280, selector.getParameters().maxVideoWidth);
    assertEquals(720, selector.getParameters().maxVideoHeight);
  }

  @Test public void nonzeroLiveDurationDoesNotProveSeekability() {
    when(player.isCurrentMediaItemSeekable()).thenReturn(false);
    assertFalse(PlaybackTimelineBridge.canSeek(player));
    assertFalse(PlaybackTimelineBridge.seek(player, 120000, null, true));
    verify(player, never()).seekTo(anyLong());
    assertEquals(false, PlaybackTimelineBridge.snapshot(player).get("seekable"));
  }
  @Test public void releasedDragTracksTheMovingLiveWindow() {
    windowStart = 1010000L;
    assertTrue(PlaybackTimelineBridge.seek(player, 250000, 1000000L, true));
    verify(player).seekTo(240000L);
  }
  @Test public void expiredAndFuturePositionsClampToTheCurrentWindow() {
    assertTrue(PlaybackTimelineBridge.seek(player, -5000, null, true));
    verify(player).seekTo(0L);
    assertTrue(PlaybackTimelineBridge.seek(player, 900000, null, true));
    verify(player).seekTo(600000L);
  }
  @Test public void changedMediaOrMissingCommandCannotApplyAnOldLiveSeek() {
    when(player.isCurrentMediaItemLive()).thenReturn(false);
    assertFalse(PlaybackTimelineBridge.seek(player, 20000, null, true));
    when(player.isCurrentMediaItemLive()).thenReturn(true);
    when(player.isCommandAvailable(Player.COMMAND_SEEK_IN_CURRENT_MEDIA_ITEM)).thenReturn(false);
    assertFalse(PlaybackTimelineBridge.seek(player, 20000, null, true));
    verify(player, never()).seekTo(anyLong());
  }
  @Test public void unknownWindowStartIsNotSentAsATimestamp() {
    windowStart = C.TIME_UNSET;
    Map<String, Object> data = PlaybackTimelineBridge.snapshot(player);
    assertFalse(data.containsKey("windowStart"));
    assertEquals(true, data.get("live"));
  }
}
