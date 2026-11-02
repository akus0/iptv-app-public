/// Frame rate above which 1080p content counts as "FHD" rather than
/// plain "HD" — comfortably between a 30ish-fps broadcast feed (23.976,
/// 24, 25, 29.97, 30) and a 50/59.94/60fps one, so real-world rounding on
/// either side never crosses it by accident.
const _highFrameRateThreshold = 40.0;

/// Maps a decoded video track's real pixel height (and, at 1080p, its
/// frame rate) to a familiar broadcast quality label — read directly off
/// the already-playing stream's selected track, never guessed from a
/// channel's name (providers routinely tag a channel "4K" or "UHD" that
/// never actually decodes above 1080p, and conflate a 1080p30 broadcast
/// feed with true 1080p60).
///
/// Null below 1080p — not worth a badge for the common case, and this app
/// has no reliable way to tell an honest 720p feed from a downscaled one.
String? qualityLabelForTrack({required int height, double? frameRate}) {
  if (height >= 2160) return '4K';
  if (height >= 1080) {
    return (frameRate != null && frameRate > _highFrameRateThreshold)
        ? 'FHD'
        : 'HD';
  }
  return null;
}
