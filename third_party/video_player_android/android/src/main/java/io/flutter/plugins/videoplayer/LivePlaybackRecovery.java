package io.flutter.plugins.videoplayer;

import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;
import androidx.media3.common.PlaybackException;
import androidx.media3.common.MediaItem;
import androidx.media3.common.Player;
import androidx.media3.datasource.HttpDataSource;
import androidx.media3.exoplayer.ExoPlayer;
import java.util.HashMap;
import java.util.Map;

/** Opt-in for the app's LIVE player only. No extra player, connection probe or frame polling. */
final class LivePlaybackRecovery {
  static final long CHECK_MS = 2000, STALL_MS = 10000, OPEN_STALL_MS = 20000,
      REFILL_GRACE_MS = 6000, MAX_STALL_MS = 30000, STABLE_MS = 30000;
  static final int MAX_ATTEMPTS = 3;
  private final ExoPlayer player;
  private final VideoPlayerCallbacks events;
  private final MediaItem mediaItem;
  private final Handler handler = new Handler(Looper.getMainLooper());
  private boolean disposed, pending, needsRetry, failed, hasPlayed, userPaused, hasProgress;
  private int attempts;
  private long lastPosition, progressAt, healthySince, retryAt, bufferProgressAt,
      bufferedPosition;
  private String failure;

  LivePlaybackRecovery(ExoPlayer player, VideoPlayerCallbacks events) {
    this.player = player;
    this.events = events;
    mediaItem = player.getCurrentMediaItem();
    resetProgress();
    handler.postDelayed(check, CHECK_MS);
  }

  private void resetProgress() {
    lastPosition = player.getCurrentPosition();
    progressAt = SystemClock.elapsedRealtime();
    bufferedPosition = player.getBufferedPosition();
    bufferProgressAt = 0;
    healthySince = 0;
  }

  static boolean permanent(PlaybackException error) {
    int code = error.errorCode;
    // A corrupt segment may cause DECODING_FAILED (4003); that can recover.
    if (code == PlaybackException.ERROR_CODE_DECODER_INIT_FAILED
        || code == PlaybackException.ERROR_CODE_DECODER_QUERY_FAILED
        || code == PlaybackException.ERROR_CODE_DECODING_FORMAT_EXCEEDS_CAPABILITIES
        || code == PlaybackException.ERROR_CODE_DECODING_FORMAT_UNSUPPORTED
        || (code >= 6000 && code < 7000)) return true;
    for (Throwable t = error.getCause(); t != null; t = t.getCause()) {
      if (t instanceof HttpDataSource.InvalidResponseCodeException) {
        int status = ((HttpDataSource.InvalidResponseCodeException) t).responseCode;
        if (status == 401 || status == 403 || status == 404 || status == 410 || status == 429) return true;
      }
      if (t.getCause() == t) break;
    }
    return false;
  }

  void error(PlaybackException error) {
    failure = "Video player had error " + error + ExoPlayerEventListener.describeCause(error);
    if (permanent(error)) { giveUp(); return; }
    needsRetry = true;
    if (!userPaused && (player.getPlayWhenReady() || !hasPlayed)) {
      retry(error.errorCode == PlaybackException.ERROR_CODE_BEHIND_LIVE_WINDOW);
    }
    // Paused means paused, including a headset disconnect or system media action.
  }

  void ended() {
    failure = "The live stream ended unexpectedly [LIVE_STREAM_ENDED]";
    needsRetry = true;
    if (!userPaused && (player.getPlayWhenReady() || !hasPlayed)) retry();
  }

  void playRequested() {
    hasPlayed = true;
    userPaused = false;
    resetProgress();
    if (needsRetry && !failed) retry();
  }

  void pauseRequested() {
    userPaused = true;
    handler.removeCallbacks(reopen);
    pending = false;
    resetProgress();
  }

  void seeked() { resetProgress(); }

  private void giveUp() {
    if (failed || disposed) return;
    failed = true;
    pending = false;
    handler.removeCallbacks(reopen);
    player.stop();
    events.onError("VideoError", failure == null ? "Stream did not recover [STREAM_STALLED]" : failure, null);
  }

  private void retry() {
    retry(false);
  }

  private void retry(boolean liveWindowExpired) {
    if (disposed || pending || failed) return;
    if (attempts >= MAX_ATTEMPTS) { giveUp(); return; }
    attempts++;
    // Close first, then back off. Never overlap provider connections.
    pending = true;
    needsRetry = true;
    // An expired live window needs a fresh timeline, not a network backoff.
    // Other failures retain a short close-before-open gap, increasing on failure.
    retryAt = SystemClock.elapsedRealtime()
        + (liveWindowExpired ? 0 : (2000L << (attempts - 1)));
    player.stop();
    resetProgress();
    handler.postDelayed(reopen, Math.max(0, retryAt - SystemClock.elapsedRealtime()));
  }

  private final Runnable reopen = new Runnable() { @Override public void run() {
    pending = false;
    if (disposed || failed || userPaused || (hasPlayed && !player.getPlayWhenReady())
        || player.getPlaybackSuppressionReason() != Player.PLAYBACK_SUPPRESSION_REASON_NONE) return;
    needsRetry = false;
    // Retain playWhenReady; never force play over a user pause or audio-focus loss.
    // A new source discards stale HLS manifests and progressive resume offsets.
    // Keep the player/surface and its configured factory (headers, captions,
    // track preferences, volume); only the live media source is replaced.
    if (mediaItem != null) player.setMediaItem(mediaItem, true);
    else player.seekToDefaultPosition();
    player.prepare();
    resetProgress();
  }};

  private final Runnable check = new Runnable() {
    @Override public void run() {
      if (disposed) return;
      long now = SystemClock.elapsedRealtime();
      if (!failed && !pending) {
        if (!player.getPlayWhenReady()
            || player.getPlaybackSuppressionReason() != Player.PLAYBACK_SUPPRESSION_REASON_NONE) {
          resetProgress();
        } else if (needsRetry) {
          retry();
        } else {
          long position = player.getCurrentPosition();
          long buffered = player.getBufferedPosition();
          if (buffered >= bufferedPosition + 250) {
            bufferProgressAt = now;
            bufferedPosition = buffered;
          } else if (buffered < bufferedPosition) {
            bufferedPosition = buffered;
          }
          if (position != lastPosition && player.getPlaybackState() == Player.STATE_READY) {
            hasProgress = true;
            progressAt = now;
            if (healthySince == 0) healthySince = now;
            if (now - healthySince >= STABLE_MS) { attempts = 0; failure = null; }
          } else {
            healthySince = 0;
            long stalledFor = now - progressAt;
            // Don't throw away a recovering connection while data is arriving.
            // The hard bound still catches unusable data or a wedged decoder.
            boolean refilling = player.getPlaybackState() == Player.STATE_BUFFERING
                && bufferProgressAt > 0 && now - bufferProgressAt < REFILL_GRACE_MS;
            if (stalledFor >= (hasProgress ? STALL_MS : OPEN_STALL_MS)
                && (!refilling || stalledFor >= MAX_STALL_MS)) {
              failure = "Playback stopped making progress [STREAM_STALLED]";
              retry();
            }
          }
          lastPosition = position;
        }
      }
      handler.postDelayed(this, CHECK_MS);
    }
  };

  Map<String, Object> snapshot() {
    Map<String, Object> result = new HashMap<>();
    result.put("attempt", attempts);
    result.put("maxAttempts", MAX_ATTEMPTS);
    result.put("recovering", pending || needsRetry || (attempts > 0 && player.getPlaybackState() != Player.STATE_READY));
    result.put("retryInMs", pending ? Math.max(0, retryAt - SystemClock.elapsedRealtime()) : 0L);
    result.put("failed", failed);
    result.put("refilling", !pending && !failed
        && player.getPlaybackState() == Player.STATE_BUFFERING
        && bufferProgressAt > 0
        && SystemClock.elapsedRealtime() - bufferProgressAt < REFILL_GRACE_MS);
    if (failure != null) result.put("lastFailure", failure);
    return result;
  }

  void dispose() {
    disposed = true;
    handler.removeCallbacks(check);
    handler.removeCallbacks(reopen);
  }
}
