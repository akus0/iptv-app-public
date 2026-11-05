// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

package io.flutter.plugins.videoplayer.platformview;

import androidx.annotation.NonNull;
import androidx.annotation.OptIn;
import androidx.media3.common.Format;
import androidx.media3.common.PlaybackException;
import androidx.media3.common.util.UnstableApi;
import androidx.media3.exoplayer.ExoPlayer;
import androidx.media3.exoplayer.trackselection.DefaultTrackSelector;
import io.flutter.plugins.videoplayer.ExoPlayerEventListener;
import io.flutter.plugins.videoplayer.VideoPlayerCallbacks;

public final class PlatformViewExoPlayerEventListener extends ExoPlayerEventListener {
  public PlatformViewExoPlayerEventListener(
      @NonNull ExoPlayer exoPlayer, @NonNull VideoPlayerCallbacks events) {
    super(exoPlayer, events);
  }

  @OptIn(markerClass = UnstableApi.class)
  @Override
  public void onPlayerError(@NonNull PlaybackException error) {
    // Some firmware advertises tunneling but rejects a particular codec or
    // audio output. Retry once in the same player without tunneling. The
    // parameter remains disabled for this player, so a second failure goes to
    // normal bounded recovery. Preserve play/pause intent and close first.
    if (exoPlayer.isTunnelingEnabled()
        && error.errorCode >= PlaybackException.ERROR_CODE_DECODER_INIT_FAILED
        && error.errorCode <= PlaybackException.ERROR_CODE_AUDIO_TRACK_OFFLOAD_INIT_FAILED
        && exoPlayer.getTrackSelector() instanceof DefaultTrackSelector selector
        && selector.getParameters().tunnelingEnabled) {
      selector.setParameters(selector.buildUponParameters().setTunnelingEnabled(false));
      exoPlayer.stop();
      exoPlayer.prepare();
      return;
    }
    super.onPlayerError(error);
  }

  @OptIn(markerClass = UnstableApi.class)
  @Override
  protected void sendInitialized() {
    // We can't rely on VideoSize here, because at this point it is not available - the platform
    // view was not created yet. We use the video format instead.
    Format videoFormat = exoPlayer.getVideoFormat();
    if (videoFormat == null) {
      // VesperTV: audio-only stream (a radio channel). Unplayable video never gets here, see
      // ExoPlayerEventListener.sendInitializedOrReportUnplayable.
      events.onInitialized(0, 0, exoPlayer.getDuration(), RotationDegrees.ROTATE_0.getDegrees());
      return;
    }
    RotationDegrees rotationCorrection = RotationDegrees.fromDegrees(videoFormat.rotationDegrees);
    int width = videoFormat.width;
    int height = videoFormat.height;

    // Anamorphic content is stored with non-square pixels, so the coded width has to be
    // scaled by the pixel aspect ratio to obtain the display width. This is applied before
    // the rotation swap below, because Format reports the ratio for the unrotated frame.
    // Width is only scaled when it is known (Format.NO_VALUE is negative), and is clamped to at
    // least one pixel so that a malformed ratio cannot report a zero width.
    float pixelWidthHeightRatio = videoFormat.pixelWidthHeightRatio;
    if (width > 0 && pixelWidthHeightRatio > 0 && pixelWidthHeightRatio != 1f) {
      width = Math.max(1, Math.round(width * pixelWidthHeightRatio));
    }

    // Switch the width/height if video was taken in portrait mode and a rotation
    // correction was detected.
    if (rotationCorrection == RotationDegrees.ROTATE_90
        || rotationCorrection == RotationDegrees.ROTATE_270) {
      int displayWidth = width;
      width = height;
      height = displayWidth;

      rotationCorrection = RotationDegrees.fromDegrees(0);
    }

    events.onInitialized(width, height, exoPlayer.getDuration(), rotationCorrection.getDegrees());
  }
}
