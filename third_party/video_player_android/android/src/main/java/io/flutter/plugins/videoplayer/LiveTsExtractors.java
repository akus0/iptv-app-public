package io.flutter.plugins.videoplayer;

import android.net.Uri;
import android.util.SparseArray;
import androidx.annotation.Nullable;
import androidx.media3.common.Format;
import androidx.media3.common.MimeTypes;
import androidx.media3.common.ParserException;
import androidx.media3.common.util.ParsableByteArray;
import androidx.media3.common.util.TimestampAdjuster;
import androidx.media3.common.util.UnstableApi;
import androidx.media3.extractor.DefaultExtractorsFactory;
import androidx.media3.extractor.Extractor;
import androidx.media3.extractor.ExtractorOutput;
import androidx.media3.extractor.ExtractorsFactory;
import androidx.media3.extractor.text.DefaultSubtitleParserFactory;
import androidx.media3.extractor.ts.DefaultTsPayloadReaderFactory;
import androidx.media3.extractor.ts.TsExtractor;
import androidx.media3.extractor.ts.TsPayloadReader;
import java.util.Collections;
import java.util.List;
import java.util.Map;

/** Keeps a damaged Dolby audio packet from terminating an otherwise playable live TS feed. */
@UnstableApi
final class LiveTsExtractors implements ExtractorsFactory {
  private static final List<Format> CAPTIONS = Collections.singletonList(
      new Format.Builder().setSampleMimeType(MimeTypes.APPLICATION_CEA608).build());
  private final DefaultExtractorsFactory defaults =
      new DefaultExtractorsFactory().setTsSubtitleFormats(CAPTIONS);

  @Override
  public Extractor[] createExtractors() {
    return createExtractors(Uri.EMPTY, Collections.emptyMap());
  }

  @Override
  public Extractor[] createExtractors(Uri uri, Map<String, List<String>> responseHeaders) {
    Extractor[] result = defaults.createExtractors(uri, responseHeaders);
    for (int i = 0; i < result.length; i++) {
      if (result[i] instanceof TsExtractor) {
        // Same Media3 defaults, including caption discovery and subtitle parsing.
        result[i] = new TsExtractor(TsExtractor.MODE_SINGLE_PMT, 0,
            new DefaultSubtitleParserFactory(), new TimestampAdjuster(0),
            new PayloadFactory(), TsExtractor.DEFAULT_TIMESTAMP_SEARCH_BYTES);
      }
    }
    return result;
  }

  static final class PayloadFactory implements TsPayloadReader.Factory {
    private final DefaultTsPayloadReaderFactory defaults =
        new DefaultTsPayloadReaderFactory(0, CAPTIONS);

    @Override
    public SparseArray<TsPayloadReader> createInitialPayloadReaders() {
      return defaults.createInitialPayloadReaders();
    }

    @Nullable
    @Override
    public TsPayloadReader createPayloadReader(int streamType, TsPayloadReader.EsInfo info) {
      TsPayloadReader reader = defaults.createPayloadReader(streamType, info);
      return reader != null && (streamType == TsExtractor.TS_STREAM_TYPE_AC3
          || streamType == TsExtractor.TS_STREAM_TYPE_E_AC3)
          ? new AudioPacketGuard(reader) : reader;
    }
  }

  static final class AudioPacketGuard implements TsPayloadReader {
    private final TsPayloadReader reader;
    private boolean awaitingPacketStart;
    private int corruptPackets;
    private long lastCorruptAt;
    private int discardedBytes;

    AudioPacketGuard(TsPayloadReader reader) { this.reader = reader; }

    @Override
    public void init(TimestampAdjuster adjuster, ExtractorOutput output, TrackIdGenerator ids) {
      reader.init(adjuster, output, ids);
    }

    @Override
    public void seek() {
      awaitingPacketStart = false;
      discardedBytes = 0;
      corruptPackets = 0;
      reader.seek();
    }

    @Override
    public void consume(ParsableByteArray data, int flags) throws ParserException {
      if (awaitingPacketStart && (flags & FLAG_PAYLOAD_UNIT_START_INDICATOR) == 0) {
        discardedBytes += data.bytesLeft();
        if (discardedBytes > 256 * 1024) {
          throw ParserException.createForMalformedContainer(
              "Dolby audio packet synchronization did not recover", null);
        }
        data.setPosition(data.limit());
        return;
      }
      awaitingPacketStart = false;
      try {
        reader.consume(data, flags);
      } catch (IndexOutOfBoundsException corruptAudioHeader) {
        long now = android.os.SystemClock.elapsedRealtime();
        if (now - lastCorruptAt > 10_000) corruptPackets = 0;
        lastCorruptAt = now;
        if (++corruptPackets > 8) {
          throw ParserException.createForMalformedContainer(
              "Repeated invalid Dolby audio headers", corruptAudioHeader);
        }
        // Media3 1.9.2's AC3 parser indexes its bitrate table with an unchecked
        // frame-size code. A damaged header was aborting the entire 4K stream.
        // Discard this audio PES only; restart at a real packet boundary so
        // continuation bytes cannot be mistaken for a new timestamp/header.
        reader.seek();
        awaitingPacketStart = true;
        discardedBytes = 0;
        data.setPosition(data.limit());
      }
    }
  }
}
