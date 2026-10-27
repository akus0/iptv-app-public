package io.flutter.plugins.videoplayer;

import static org.junit.Assert.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

import androidx.media3.common.C;
import androidx.media3.common.PlaybackException;
import androidx.media3.common.util.ParsableByteArray;
import androidx.media3.common.util.TimestampAdjuster;
import androidx.media3.exoplayer.ExoPlayer;
import androidx.media3.exoplayer.trackselection.DefaultTrackSelector;
import androidx.media3.extractor.ExtractorOutput;
import androidx.media3.extractor.TrackOutput;
import androidx.media3.extractor.ts.Ac3Reader;
import androidx.media3.extractor.ts.PesReader;
import androidx.media3.extractor.ts.TsPayloadReader;
import io.flutter.plugins.videoplayer.platformview.PlatformViewExoPlayerEventListener;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.annotation.Config;

@RunWith(RobolectricTestRunner.class)
@Config(sdk = 28)
public final class TvPlaybackRegressionTest {
  @Test
  public void corruptAc3PacketDoesNotEndVideoAndNextAudioPacketRecovers() throws Exception {
    ExtractorOutput output = mock(ExtractorOutput.class);
    TrackOutput audio = mock(TrackOutput.class);
    when(output.track(anyInt(), eq(C.TRACK_TYPE_AUDIO))).thenReturn(audio);
    TsPayloadReader reader = new LiveTsExtractors.AudioPacketGuard(new PesReader(new Ac3Reader(null)));
    reader.init(new TimestampAdjuster(0), output, new TsPayloadReader.TrackIdGenerator(1, 1));
    // Reserved frame-size code 50 caused the real length=19/index=25 crash.
    reader.consume(packet(50), TsPayloadReader.FLAG_PAYLOAD_UNIT_START_INDICATOR);
    verify(audio, never()).format(any());
    // Continuation bytes must not be interpreted as another PES header.
    reader.consume(new ParsableByteArray(new byte[184]), 0);
    reader.consume(packet(0), TsPayloadReader.FLAG_PAYLOAD_UNIT_START_INDICATOR);
    reader.consume(packet(0), TsPayloadReader.FLAG_PAYLOAD_UNIT_START_INDICATOR);
    verify(audio).format(argThat(f -> f.sampleRate == 48000 && f.channelCount == 2));
    verify(audio).sampleMetadata(eq(0L), eq(C.BUFFER_FLAG_KEY_FRAME), eq(128), eq(0), isNull());
  }

  @Test
  public void persistentlyBrokenAudioFailsInsteadOfWaitingForever() throws Exception {
    ExtractorOutput output = mock(ExtractorOutput.class);
    when(output.track(anyInt(), anyInt())).thenReturn(mock(TrackOutput.class));
    TsPayloadReader reader = new LiveTsExtractors.AudioPacketGuard(new PesReader(new Ac3Reader(null)));
    reader.init(new TimestampAdjuster(0), output, new TsPayloadReader.TrackIdGenerator(1, 1));
    for (int i = 0; i < 8; i++) reader.consume(packet(50), 1);
    assertThrows(androidx.media3.common.ParserException.class, () -> reader.consume(packet(50), 1));
  }

  @Test
  public void missingPacketBoundaryHasBoundedDiscardBudget() throws Exception {
    TsPayloadReader delegate = mock(TsPayloadReader.class);
    doThrow(new ArrayIndexOutOfBoundsException()).when(delegate).consume(any(), anyInt());
    TsPayloadReader guard = new LiveTsExtractors.AudioPacketGuard(delegate);
    guard.consume(packet(50), 1);
    assertThrows(androidx.media3.common.ParserException.class,
        () -> guard.consume(new ParsableByteArray(new byte[256 * 1024 + 1]), 0));
  }

  @Test
  public void unguardedMedia3ReaderReproducesTheCapturedFailure() throws Exception {
    ExtractorOutput output = mock(ExtractorOutput.class);
    when(output.track(anyInt(), anyInt())).thenReturn(mock(TrackOutput.class));
    PesReader reader = new PesReader(new Ac3Reader(null));
    reader.init(new TimestampAdjuster(0), output, new TsPayloadReader.TrackIdGenerator(1, 1));
    assertThrows(ArrayIndexOutOfBoundsException.class,
        () -> reader.consume(packet(50), TsPayloadReader.FLAG_PAYLOAD_UNIT_START_INDICATOR));
  }

  @Test
  public void audioGuardDoesNotHideUnrelatedFailures() throws Exception {
    TsPayloadReader delegate = mock(TsPayloadReader.class);
    doThrow(new IllegalStateException("unrelated")).when(delegate).consume(any(), anyInt());
    TsPayloadReader guard = new LiveTsExtractors.AudioPacketGuard(delegate);
    assertThrows(IllegalStateException.class, () -> guard.consume(packet(0), 1));
  }

  @Test
  public void rejectedTunnelingRetriesOnceWithoutChangingPauseIntent() {
    ExoPlayer player = mock(ExoPlayer.class);
    DefaultTrackSelector selector = mock(DefaultTrackSelector.class);
    DefaultTrackSelector.Parameters parameters =
        new DefaultTrackSelector.Parameters.Builder().setTunnelingEnabled(true).build();
    when(player.isTunnelingEnabled()).thenReturn(true);
    when(player.getTrackSelector()).thenReturn(selector);
    when(selector.getParameters()).thenReturn(parameters);
    when(selector.buildUponParameters()).thenAnswer(i -> selector.getParameters().buildUpon());
    doAnswer(i -> {
      DefaultTrackSelector.Parameters.Builder builder = i.getArgument(0);
      when(selector.getParameters()).thenReturn(builder.build());
      return null;
    }).when(selector).setParameters(any(DefaultTrackSelector.Parameters.Builder.class));
    VideoPlayerCallbacks callbacks = mock(VideoPlayerCallbacks.class);
    PlatformViewExoPlayerEventListener listener = new PlatformViewExoPlayerEventListener(player, callbacks);
    PlaybackException error = new PlaybackException("decoder", null,
        PlaybackException.ERROR_CODE_DECODER_INIT_FAILED);
    listener.onPlayerError(error);
    assertFalse(selector.getParameters().tunnelingEnabled);
    var order = inOrder(player);
    order.verify(player).stop();
    order.verify(player).prepare();
    verify(player, never()).play();
    verify(player, never()).setPlayWhenReady(anyBoolean());
    listener.onPlayerError(error);
    verify(player, times(1)).prepare();
    verify(callbacks).onError(anyString(), anyString(), any());
  }

  @Test
  public void networkErrorsDoNotDisableTunneling() {
    ExoPlayer player = mock(ExoPlayer.class);
    when(player.isTunnelingEnabled()).thenReturn(true);
    var listener = new PlatformViewExoPlayerEventListener(player, mock(VideoPlayerCallbacks.class));
    listener.onPlayerError(new PlaybackException("network", null,
        PlaybackException.ERROR_CODE_IO_NETWORK_CONNECTION_FAILED));
    verify(player, never()).getTrackSelector();
  }

  private static ParsableByteArray packet(int frameSizeCode) {
    byte[] data = new byte[14 + 128];
    byte[] pes = {0, 0, 1, (byte) 0xbd, 0, (byte) 136, (byte) 0x80, (byte) 0x80,
        5, 0x21, 0, 1, 0, 1};
    System.arraycopy(pes, 0, data, 0, pes.length);
    data[14] = 0x0b;
    data[15] = 0x77;
    data[18] = (byte) frameSizeCode;
    data[19] = 0x40;
    data[20] = 0x40;
    return new ParsableByteArray(data);
  }
}
