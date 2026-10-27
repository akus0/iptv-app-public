// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

package io.flutter.plugins.videoplayer.texture;

import android.content.Context;
import android.view.Surface;
import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.annotation.RestrictTo;
import androidx.annotation.VisibleForTesting;
import androidx.media3.common.MediaItem;
import androidx.media3.common.util.UnstableApi;
import androidx.media3.exoplayer.DefaultLoadControl;
import androidx.media3.exoplayer.DefaultRenderersFactory;
import androidx.media3.exoplayer.ExoPlayer;
import androidx.media3.exoplayer.audio.AudioSink;
import androidx.media3.exoplayer.audio.DefaultAudioSink;
import io.flutter.plugins.videoplayer.ExoPlayerEventListener;
import io.flutter.plugins.videoplayer.VideoAsset;
import io.flutter.plugins.videoplayer.VideoPlayer;
import io.flutter.plugins.videoplayer.VideoPlayerCallbacks;
import io.flutter.plugins.videoplayer.VideoPlayerOptions;
import io.flutter.view.TextureRegistry.SurfaceProducer;

/**
 * A subclass of {@link VideoPlayer} that adds functionality related to texture view as a way of
 * displaying the video in the app.
 *
 * <p>It manages the lifecycle of the texture and ensures that the video is properly displayed on
 * the texture.
 */
public final class TextureVideoPlayer extends VideoPlayer implements SurfaceProducer.Callback {
  // True when the ExoPlayer instance has a null surface.
  private boolean needsSurface = true;

  /**
   * Creates a texture video player.
   *
   * @param context application context.
   * @param events event callbacks.
   * @param surfaceProducer produces a texture to render to.
   * @param asset asset to play.
   * @param options options for playback.
   * @return a video player instance.
   */
  // TODO: Migrate to stable API, see https://github.com/flutter/flutter/issues/147039.
  @UnstableApi
  @NonNull
  public static TextureVideoPlayer create(
      @NonNull Context context,
      @NonNull VideoPlayerCallbacks events,
      @NonNull SurfaceProducer surfaceProducer,
      @NonNull VideoAsset asset,
      @NonNull VideoPlayerOptions options) {
    return new TextureVideoPlayer(
        events,
        surfaceProducer,
        asset.getMediaItem(),
        options,
        () -> {
          ExoPlayer.Builder builder = new ExoPlayer.Builder(context);
          DefaultLoadControl.Builder loadControlBuilder = new DefaultLoadControl.Builder();
          // Only Multiview uses texture players (the main player is a
          // platform view), so this is Multiview's buffer policy.
          // Xtream live is progressive .ts: it arrives at real-time speed,
          // so the cushion never grows beyond what's held before playback
          // (re)starts. The old 500 ms start thresholds meant any network
          // hiccup over ~0.5 s rebuffered, then resumed after another
          // 0.5 s — repeated micro-stutter. ~2.5 s to start / 4 s after a
          // rebuffer is in line with what other IPTV players hold. The old
          // 90-120 s min/max did nothing for progressive live (it can never
          // fill ahead of real time) — back to modest values.
          loadControlBuilder.setBufferDurationsMs(
              /* minBufferMs= */ 15_000,
              /* maxBufferMs= */ 30_000,
              /* bufferForPlaybackMs= */ 2_500,
              /* bufferForPlaybackAfterRebufferMs= */ 4_000);
          io.flutter.plugins.videoplayer.BufferBudget.apply(
              context, loadControlBuilder,
              io.flutter.plugins.videoplayer.BufferBudget.TEXTURE_PLAYER_BYTES);
          if (options.backBufferDurationMs != null) {
            if (options.backBufferDurationMs < 0) {
              throw new IllegalArgumentException("backBufferDurationMs must be at least 0");
            }
            if (options.backBufferDurationMs > 0) {
              // Clamp the value to ensure it fits within the int range expected by
              // DefaultLoadControl.
              int backBufferInt =
                  (int) Math.min(options.backBufferDurationMs.longValue(), Integer.MAX_VALUE);
              loadControlBuilder.setBackBuffer(backBufferInt, /* retainBackBufferFromKeyframe= */ true);
            }
          }
          // Multiview uses mixed audio; compatibility single-player mode does
          // not. Bound each grid player's buffer even on larger devices.
          if (options.mixWithOthers) {
            loadControlBuilder.setTargetBufferBytes(16 * 1024 * 1024);
            loadControlBuilder.setPrioritizeTimeOverSizeThresholds(false);
          }
          builder.setLoadControl(loadControlBuilder.build());
          androidx.media3.exoplayer.trackselection.DefaultTrackSelector trackSelector =
              new androidx.media3.exoplayer.trackselection.DefaultTrackSelector(context);
          if (options.mixWithOthers) {
            // Select a lighter adaptive rendition when offered. A fixed-quality
            // stream remains playable; this cannot transcode or reduce its fps.
            trackSelector.setParameters(trackSelector.buildUponParameters()
                .setMaxVideoSize(1280, 720).setMaxVideoFrameRate(30));
          }
          // Same audio setup as PlatformViewVideoPlayer.create() — see that
          // class's own doc comment for the full HDMI-passthrough/
          // setVolume() story. This class didn't need it when every
          // texture-view instance was a single always-visible stream, but
          // Multiview switched to texture views (see multiview_screen.dart's
          // own doc comment on the CPU cost of platform views) without
          // carrying this fix along — left every Multiview cell on the
          // stock, Context-aware AudioSink and no FFmpeg-decoder
          // preference, silently reintroducing both bugs this was written
          // to avoid.
          DefaultRenderersFactory renderersFactory =
              new DefaultRenderersFactory(context) {
                @Nullable
                @Override
                protected AudioSink buildAudioSink(
                    Context context,
                    boolean enableFloatOutput,
                    boolean enableAudioOutputPlaybackParams) {
                  //noinspection deprecation — deliberate: see the comment above.
                  return new DefaultAudioSink.Builder()
                      .setEnableFloatOutput(enableFloatOutput)
                      .setEnableAudioOutputPlaybackParameters(enableAudioOutputPlaybackParams)
                      .build();
                }
              };
          // ON, not PREFER — see PlatformViewVideoPlayer.create()'s own doc
          // comment for the full story (real Multiview instability traced
          // to PREFER needlessly software-decoding plain AAC instead of
          // using the hardware decoder).
          renderersFactory.setExtensionRendererMode(
              DefaultRenderersFactory.EXTENSION_RENDERER_MODE_ON);
          // Next decoder on a failed start — see PlatformViewVideoPlayer.
          renderersFactory.setEnableDecoderFallback(true);
          // A frozen live tile (playing, clock not advancing) is failed after 4 s instead of
          // media3's default 10 s, so ExoPlayerEventListener's in-place recovery kicks in sooner.
          builder.setStuckPlayingDetectionTimeoutMs(4_000);
          builder
              .setTrackSelector(trackSelector)
              .setMediaSourceFactory(asset.getMediaSourceFactory(context))
              .setRenderersFactory(renderersFactory);
          return builder.build();
        });
  }

  // TODO: Migrate to stable API, see https://github.com/flutter/flutter/issues/147039.
  @UnstableApi
  @VisibleForTesting
  public TextureVideoPlayer(
      @NonNull VideoPlayerCallbacks events,
      @NonNull SurfaceProducer surfaceProducer,
      @NonNull MediaItem mediaItem,
      @NonNull VideoPlayerOptions options,
      @NonNull ExoPlayerProvider exoPlayerProvider) {
    super(events, mediaItem, options, surfaceProducer, exoPlayerProvider);

    surfaceProducer.setCallback(this);

    Surface surface = surfaceProducer.getSurface();
    this.exoPlayer.setVideoSurface(surface);
    needsSurface = surface == null;
  }

  @NonNull
  @Override
  protected ExoPlayerEventListener createExoPlayerEventListener(
      @NonNull ExoPlayer exoPlayer, @Nullable SurfaceProducer surfaceProducer) {
    if (surfaceProducer == null) {
      throw new IllegalArgumentException(
          "surfaceProducer cannot be null to create an ExoPlayerEventListener for"
              + " TextureVideoPlayer.");
    }
    boolean surfaceProducerHandlesCropAndRotation = surfaceProducer.handlesCropAndRotation();
    return new TextureExoPlayerEventListener(
        exoPlayer, videoPlayerEvents, surfaceProducerHandlesCropAndRotation);
  }

  @RestrictTo(RestrictTo.Scope.LIBRARY)
  public void onSurfaceAvailable() {
    if (needsSurface) {
      // TextureVideoPlayer must always set a surfaceProducer.
      assert surfaceProducer != null;
      exoPlayer.setVideoSurface(surfaceProducer.getSurface());
      needsSurface = false;
    }
  }

  @RestrictTo(RestrictTo.Scope.LIBRARY)
  public void onSurfaceCleanup() {
    exoPlayer.setVideoSurface(null);
    needsSurface = true;
  }

  public void dispose() {
    // Super must be called first to ensure the player is released before the surface.
    super.dispose();

    // TextureVideoPlayer must always set a surfaceProducer.
    assert surfaceProducer != null;
    surfaceProducer.release();
  }
}
