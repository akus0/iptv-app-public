// VesperTV patch: memory budget for the player's buffer (see the callers in
// PlatformViewVideoPlayer and TextureVideoPlayer).
package io.flutter.plugins.videoplayer;

import android.app.ActivityManager;
import android.content.Context;
import androidx.annotation.NonNull;
import androidx.annotation.OptIn;
import androidx.media3.common.util.UnstableApi;
import androidx.media3.exoplayer.DefaultLoadControl;

/**
 * Caps how many bytes a player may buffer on small-RAM devices. The buffer
 * is Java heap: with only the duration limits, a 4K remux (50-100 Mbit/s)
 * kept ExoPlayer's default ~140 MB cap full on a 1.7 GB Fire TV Stick, the
 * whole device ran out of memory and VesperTV was closed as not
 * responding (Media Hub 4K movie, 2026-10-21). Bigger devices keep
 * media3's own default.
 */
@OptIn(markerClass = UnstableApi.class)
public final class BufferBudget {
  private BufferBudget() {}

  /** Devices under this much RAM get a byte cap. */
  private static final long SMALL_RAM_BYTES = 2_500L * 1024 * 1024;

  /** The full-screen player: ~6 s of a 4K remux, ~20 s of 4K live TV. */
  public static final int MAIN_PLAYER_BYTES = 64 * 1024 * 1024;

  /** Each texture player (Multiview screens, Compatibility video). */
  public static final int TEXTURE_PLAYER_BYTES = 32 * 1024 * 1024;

  private static Boolean small;

  static synchronized boolean isSmallDevice(@NonNull Context context) {
    if (small == null) {
      boolean result = false;
      ActivityManager am = (ActivityManager) context.getSystemService(Context.ACTIVITY_SERVICE);
      if (am != null) {
        ActivityManager.MemoryInfo info = new ActivityManager.MemoryInfo();
        am.getMemoryInfo(info);
        result = am.isLowRamDevice() || info.totalMem < SMALL_RAM_BYTES;
      }
      small = result;
    }
    return small;
  }

  /** Applies [bytes] as the buffer cap on a small device; no-op otherwise. */
  public static void apply(
      @NonNull Context context, @NonNull DefaultLoadControl.Builder builder, int bytes) {
    if (!isSmallDevice(context)) return;
    builder.setTargetBufferBytes(bytes);
    // Bytes win over the duration limits (media3's default, made explicit).
    builder.setPrioritizeTimeOverSizeThresholds(false);
  }
}
