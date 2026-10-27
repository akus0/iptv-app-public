# Licence and attribution

iptv-app is a modified fork of [VesperTV](https://github.com/NoXqc/VesperTV), originally developed by NoXqc and contributors. The source code is distributed under the GNU General Public License, version 3; see [LICENSE](LICENSE). This fork is independently maintained and is not an official or endorsed VesperTV release.

Modifications through 27 October 2026 include phone/TV layouts, category organisation, sports matching and discovery, playback controls, multiview, reliability and performance work. See [CHANGELOG.md](CHANGELOG.md).

The fork uses its own TV/play icon. Retained platform resource names and storage identifiers exist for compatibility and do not imply use of upstream branding. Upstream trademark terms remain in [TRADEMARKS.md](TRADEMARKS.md). Its hosted pairing service is not a default endpoint in this fork.

## Dependencies and data

- The modified Flutter Android video plugin retains its BSD licence and copyright notices in `third_party/video_player_android/LICENSE` and source headers.
- Android playback uses AndroidX Media3 and Jellyfin's FFmpeg decoder. Other targets use media_kit and its native dependencies. Distributing binaries requires satisfying their licences and corresponding-source obligations as applicable, in addition to this application's GPL. Keep dependency versions and build sources with each release.
- Dependency notices are available through the app's licence viewer, including additional Android native-library notices. The [dependency inventory](docs/dependencies/README.md) records resolved versions, hashes and source references. That viewer alone is not a substitute for providing required source/build materials for native libraries.
- Sports schedules, scores, guide listings, metadata and provider-supplied artwork come from third parties. Their names and logos remain the property of their respective owners. GPL coverage of this app does not grant rights to those datasets, artwork or services.
- Replay and highlight league badges use locally rendered text initials. No league-logo image assets are bundled.
- TMDB metadata requires a user-supplied key. This product uses the TMDB API but is not endorsed or certified by TMDB.

No channels, subscription credentials or playlists are included. Users supply their own authorised sources.
