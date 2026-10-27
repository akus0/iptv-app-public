package io.flutter.plugins.videoplayer;

import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

import android.app.ActivityManager;
import android.content.Context;
import android.net.Uri;
import android.os.Looper;
import androidx.media3.common.C;
import androidx.media3.common.Format;
import androidx.media3.common.PlaybackException;
import androidx.media3.common.Player;
import androidx.media3.common.TrackGroup;
import androidx.media3.common.Tracks;
import androidx.media3.datasource.DataSpec;
import androidx.media3.datasource.HttpDataSource;
import androidx.media3.exoplayer.DefaultLoadControl;
import androidx.media3.exoplayer.ExoPlayer;
import io.flutter.plugins.videoplayer.platformview.PlatformViewExoPlayerEventListener;
import java.time.Duration;
import java.util.Collections;
import org.junit.Before;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.Shadows;
import org.robolectric.annotation.Config;
import org.robolectric.util.ReflectionHelpers;

/** Regression coverage for the selectively ported upstream Android fixes. No streams opened. */
@RunWith(RobolectricTestRunner.class)
@Config(sdk = 28)
public final class UpstreamCompatibilityTest {
  private ExoPlayer player;
  private VideoPlayerCallbacks callbacks;
  private PlatformViewExoPlayerEventListener listener;

  @Before
  public void setUp() {
    player = mock(ExoPlayer.class);
    callbacks = mock(VideoPlayerCallbacks.class);
    when(player.getCurrentTracks()).thenReturn(Tracks.EMPTY);
    when(player.getDuration()).thenReturn(1000L);
    listener = new PlatformViewExoPlayerEventListener(player, callbacks);
    ReflectionHelpers.setStaticField(BufferBudget.class, "small", null);
  }

  private Context device(long megabytes, boolean lowRam) {
    Context context = mock(Context.class);
    ActivityManager manager = mock(ActivityManager.class);
    when(context.getSystemService(Context.ACTIVITY_SERVICE)).thenReturn(manager);
    when(manager.isLowRamDevice()).thenReturn(lowRam);
    doAnswer(invocation -> {
      ActivityManager.MemoryInfo info = invocation.getArgument(0);
      info.totalMem = megabytes * 1024 * 1024;
      return null;
    }).when(manager).getMemoryInfo(any());
    return context;
  }

  @Test
  public void smallTvCapsMainAndTextureBuffers() {
    Context context = device(2048, false);
    DefaultLoadControl.Builder main = mock(DefaultLoadControl.Builder.class);
    DefaultLoadControl.Builder texture = mock(DefaultLoadControl.Builder.class);
    BufferBudget.apply(context, main, BufferBudget.MAIN_PLAYER_BYTES);
    BufferBudget.apply(context, texture, BufferBudget.TEXTURE_PLAYER_BYTES);
    verify(main).setTargetBufferBytes(64 * 1024 * 1024);
    verify(texture).setTargetBufferBytes(32 * 1024 * 1024);
    verify(main).setPrioritizeTimeOverSizeThresholds(false);
    verify(texture).setPrioritizeTimeOverSizeThresholds(false);
  }

  @Test
  public void largerDeviceRetainsMedia3Defaults() {
    DefaultLoadControl.Builder builder = mock(DefaultLoadControl.Builder.class);
    BufferBudget.apply(device(4096, false), builder, BufferBudget.MAIN_PLAYER_BYTES);
    verifyNoInteractions(builder);
  }

  @Test
  public void explicitAndroidLowRamFlagAlsoGetsCap() {
    DefaultLoadControl.Builder builder = mock(DefaultLoadControl.Builder.class);
    BufferBudget.apply(device(4096, true), builder, BufferBudget.MAIN_PLAYER_BYTES);
    verify(builder).setTargetBufferBytes(64 * 1024 * 1024);
  }

  @Test
  public void audioOnlyInitializesWithoutNullVideoCrash() {
    listener.onPlaybackStateChanged(Player.STATE_READY);
    verify(callbacks).onInitialized(0, 0, 1000L, 0);
    verify(callbacks, never()).onError(anyString(), anyString(), any());
  }

  @Test
  public void unsupportedVideoReportsErrorAndPausesAudio() {
    Format format = new Format.Builder().setSampleMimeType("video/dolby-vision")
        .setWidth(3840).setHeight(2160).build();
    Tracks.Group group = new Tracks.Group(new TrackGroup(format), false,
        new int[] {C.FORMAT_UNSUPPORTED_SUBTYPE}, new boolean[] {false});
    when(player.getCurrentTracks()).thenReturn(new Tracks(Collections.singletonList(group)));
    listener.onPlaybackStateChanged(Player.STATE_READY);
    verify(player).setPlayWhenReady(false);
    verify(callbacks).onError(eq("VideoError"), contains("[UNSUPPORTED_VIDEO:"), isNull());
    verify(callbacks, never()).onInitialized(anyInt(), anyInt(), anyLong(), anyInt());
  }

  @Test
  public void normalVideoKeepsDimensionsAndInitialization() {
    when(player.getVideoFormat()).thenReturn(
        new Format.Builder().setWidth(1920).setHeight(1080).build());
    listener.onPlaybackStateChanged(Player.STATE_READY);
    verify(callbacks).onInitialized(1920, 1080, 1000L, 0);
    verify(player, never()).setPlayWhenReady(false);
  }

  private void delayedFailure() {
    Shadows.shadowOf(Looper.getMainLooper()).idleFor(Duration.ofSeconds(12));
    listener.onPlayerError(new PlaybackException("Unavailable", null,
        PlaybackException.ERROR_CODE_IO_NETWORK_CONNECTION_FAILED));
  }

  @Test
  public void slowFailuresCannotRetryForever() {
    for (int n = 0; n < 4; n++) delayedFailure();
    verify(player, times(3)).prepare();
    verify(callbacks).onError(eq("VideoError"), contains("Unavailable"), isNull());
  }

  @Test
  public void successfulRecoveryResetsConsecutiveFailures() {
    for (int n = 0; n < 3; n++) delayedFailure();
    listener.onPlaybackStateChanged(Player.STATE_READY);
    delayedFailure();
    verify(player, times(4)).prepare();
    verify(callbacks, never()).onError(anyString(), anyString(), any());
  }

  @Test
  public void goneStreamReportsHttpStatusWithoutReopening() {
    HttpDataSource.InvalidResponseCodeException cause =
        new HttpDataSource.InvalidResponseCodeException(404, "Not Found", null,
            Collections.emptyMap(), new DataSpec(Uri.parse("https://example.invalid/gone")),
            new byte[0]);
    listener.onPlayerError(new PlaybackException("Source error", cause,
        PlaybackException.ERROR_CODE_IO_BAD_HTTP_STATUS));
    verify(player, never()).prepare();
    verify(callbacks).onError(eq("VideoError"), contains("[HTTP 404 Not Found]"), isNull());
  }
}
