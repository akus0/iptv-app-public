package io.flutter.plugins.videoplayer;
import static org.junit.Assert.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;
import android.net.Uri;
import android.os.Looper;
import androidx.media3.common.*;
import androidx.media3.datasource.*;
import androidx.media3.exoplayer.ExoPlayer;
import io.flutter.plugins.videoplayer.platformview.PlatformViewExoPlayerEventListener;
import java.time.Duration;
import java.util.Collections;
import java.util.concurrent.atomic.*;
import org.junit.*;
import org.junit.runner.RunWith;
import org.mockito.InOrder;
import org.robolectric.*;
import org.robolectric.annotation.Config;

@RunWith(RobolectricTestRunner.class) @Config(sdk = 28)
public class LivePlaybackRecoveryTest {
  private ExoPlayer player;
  private VideoPlayerCallbacks events;
  private PlatformViewExoPlayerEventListener listener;
  private final AtomicBoolean intent = new AtomicBoolean(true);
  private final AtomicInteger state = new AtomicInteger(Player.STATE_READY);
  private final AtomicLong position = new AtomicLong(1000);
  @Before public void setUp() {
    player = mock(ExoPlayer.class); events = mock(VideoPlayerCallbacks.class);
    when(player.getPlayWhenReady()).thenAnswer(i -> intent.get());
    when(player.getPlaybackState()).thenAnswer(i -> state.get());
    when(player.getCurrentPosition()).thenAnswer(i -> position.get());
    when(player.getCurrentTracks()).thenReturn(Tracks.EMPTY);
    when(player.getDuration()).thenReturn(60000L);
    doAnswer(i -> { state.set(Player.STATE_IDLE); return null; }).when(player).stop();
    doAnswer(i -> { state.set(Player.STATE_BUFFERING); return null; }).when(player).prepare();
    listener = new PlatformViewExoPlayerEventListener(player, events);
    listener.enableLiveRecovery(); listener.playRequested();
  }
  @After public void tearDown() { listener.dispose(); }
  private void waitSeconds(int n) { Shadows.shadowOf(Looper.getMainLooper()).idleFor(Duration.ofSeconds(n)); }
  private void networkError() { listener.onPlayerError(new PlaybackException("Network interruption", null, PlaybackException.ERROR_CODE_IO_NETWORK_CONNECTION_FAILED)); }
  @Test public void liveEofClosesBeforeDelayedPrepareAndNeverCompletes() {
    listener.onPlaybackStateChanged(Player.STATE_ENDED);
    verify(events, never()).onPlaybackStateChanged(PlatformPlaybackState.ENDED);
    verify(events).onPlaybackStateChanged(PlatformPlaybackState.BUFFERING);
    verify(player).stop(); waitSeconds(2); verify(player, never()).prepare(); waitSeconds(1);
    InOrder order = inOrder(player); order.verify(player).stop(); order.verify(player).seekToDefaultPosition(); order.verify(player).prepare();
    verify(player, never()).play(); verify(player, never()).setPlayWhenReady(true);
  }
  @Test public void pauseCancelsRetryAndExplicitResumeCanRetry() {
    networkError(); listener.pauseRequested(); intent.set(false); waitSeconds(30); verify(player, never()).prepare();
    intent.set(true); listener.playRequested(); waitSeconds(6); verify(player).prepare();
  }
  @Test public void ordinaryBufferingRecoveryDoesNotRestart() {
    state.set(Player.STATE_BUFFERING); waitSeconds(10); state.set(Player.STATE_READY);
    for (int i=0;i<20;i++) { position.addAndGet(2000); waitSeconds(2); } verify(player, never()).stop();
  }
  @Test public void frozenClockEventuallyRetriesEvenWhenReportedPlaying() {
    when(player.isPlaying()).thenReturn(true); waitSeconds(20); verify(player).stop(); verify(player, never()).prepare(); waitSeconds(3); verify(player).prepare();
  }
  @Test public void pauseAndAudioFocusSuppressionAreRespected() {
    intent.set(false); waitSeconds(60); intent.set(true);
    when(player.getPlaybackSuppressionReason()).thenReturn(Player.PLAYBACK_SUPPRESSION_REASON_TRANSIENT_AUDIO_FOCUS_LOSS);
    waitSeconds(60); verify(player, never()).stop(); verify(player, never()).prepare();
  }
  @Test public void systemPauseDuringBackoffPreventsReopen() {
    networkError(); intent.set(false); waitSeconds(30); verify(player, never()).prepare();
  }
  @Test public void readyBouncesDoNotResetRetryBudget() {
    for (int delay : new int[] {3,6,12}) { networkError(); waitSeconds(delay); state.set(Player.STATE_READY); listener.onPlaybackStateChanged(Player.STATE_READY); }
    networkError(); waitSeconds(40); verify(player, times(3)).prepare(); verify(events).onError(eq("VideoError"), contains("Network interruption"), isNull());
  }
  @Test public void sustainedProgressResetsBudget() {
    for (int delay : new int[] {3,6,12}) { networkError(); waitSeconds(delay); }
    state.set(Player.STATE_READY);
    for (int i=0;i<17;i++) { position.addAndGet(2000); waitSeconds(2); }
    networkError(); waitSeconds(3); verify(player, times(4)).prepare(); verify(events, never()).onError(anyString(),anyString(),any());
  }
  @Test public void corruptSegmentCanRecoverWithoutBeingCalledUnsupported() {
    listener.onPlayerError(new PlaybackException("Corrupt frame", null, PlaybackException.ERROR_CODE_DECODING_FAILED));
    waitSeconds(3); verify(player).prepare();
    verify(events,never()).onError(anyString(),anyString(),any());
  }
  @Test public void permanentFailuresDoNotReopen() {
    for (int status : new int[] {401,403,404,410,429}) {
      HttpDataSource.InvalidResponseCodeException cause = new HttpDataSource.InvalidResponseCodeException(status,"Refused",null,Collections.emptyMap(),new DataSpec(Uri.parse("https://example.invalid/channel")),new byte[0]);
      assertTrue(LivePlaybackRecovery.permanent(new PlaybackException("Source",cause,PlaybackException.ERROR_CODE_IO_BAD_HTTP_STATUS)));
    }
    listener.onPlayerError(new PlaybackException("Unsupported codec",null,PlaybackException.ERROR_CODE_DECODING_FORMAT_UNSUPPORTED));
    waitSeconds(30); verify(player,never()).prepare(); verify(events).onError(eq("VideoError"),contains("Unsupported codec"),isNull());
  }
  @Test public void disposeCancelsDelayedRetryAndWatchdog() {
    networkError(); listener.dispose(); waitSeconds(60); verify(player,never()).prepare(); verify(player,times(1)).stop();
  }
  @Test public void vodStillCompletesNormallyWithoutOptIn() {
    listener.dispose(); listener = new PlatformViewExoPlayerEventListener(player,events);
    listener.onPlaybackStateChanged(Player.STATE_ENDED); waitSeconds(30);
    verify(events).onPlaybackStateChanged(PlatformPlaybackState.ENDED); verify(player,never()).stop();
  }
  @Test public void startupCanRetryBeforeInitialPlay() {
    listener.dispose(); intent.set(false); listener = new PlatformViewExoPlayerEventListener(player,events); listener.enableLiveRecovery();
    networkError(); waitSeconds(3); verify(player).prepare(); verify(player,never()).play();
  }
}
