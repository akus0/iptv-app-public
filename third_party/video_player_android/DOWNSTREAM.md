# Downstream maintenance

This directory contains the Android video-player implementation derived from Flutter's `video_player_android` 2.12.2. Retain its original BSD licence and source copyright headers.

This fork's changes include native-surface handling, track controls, multiview resource management, playback lifecycle/recovery and support for Jellyfin's FFmpeg audio decoder. These changes were made before and during October 2026. The original README describes the upstream package; app-specific changes are maintained here and in the application tests.

The added Jellyfin decoder is a separate GPL-3.0 dependency. It is not covered by the plugin's BSD licence. Exact Maven coordinates, source/build revisions and notice requirements are recorded in `../../docs/dependencies/`.

Review local Java/Kotlin changes before replacing this directory with a newer upstream package. Preserve the method-channel API used by the application and re-run native/player regression tests. Resource and package names are retained for compatibility.
