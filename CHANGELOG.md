# Changelog

## 0.1.0 — source release, 27 October 2026

- First public source snapshot; prepared GitHub-hosted Android releases and phone/TV installation instructions.
- Added APK privacy and runtime-completeness checks before packaging downloads; aligned native libraries with the selected build targets.
- Corrected binary URL boundaries and removed costly hostname backtracking in privacy scans. Debug-symbol files are excluded from source exports.
- Extended displayed playback-error redaction to mixed-case HTTP and RTSP/RTMP addresses, preserving error details and recovery behaviour.
- Corrected environment-setting precedence and the optional relay's default pairing-page path; refreshed its deployment notes and labels.
- Source audits and exports now flag tracked files that match ignore rules, including rules changed during export.
- Made source exports audit the copied bytes, discard incomplete output and reject unreviewed archives. Extended privacy checks for Unicode text and short stream URLs.
- Removed per-build catalogue logging, limited account-related console errors to exception types, and corrected stale implementation comments.
- Corrected stale documentation and the Flutter SDK minimum; clarified development tools and fresh-repository setup. Locked dependencies, Dart language mode and runtime logic are unchanged.
- Strengthened URL and privacy checks without changing playback or matching logic.
- Updated the app README, development/release guides and sample-data screenshots.
- Expanded the README gallery to eight screenshots and refreshed repository and web metadata for iptv-app.

- Replaced bundled replay/highlight league logos with compact, sport-coloured initials.

- Updated source packaging, release documentation and independent app branding.
- Moved local signing/device configuration to an ignored `.env`; retained application identifiers and signing compatibility.
- Replaced inherited launcher artwork with the fork's TV/play icon and made optional relay/OAuth registrations explicit build settings.
- Added source/history privacy checks and safe source-export tooling.
- Inventoried Dart and Android native dependencies; added missing native notices to the licence viewer and clearer upstream attribution.
- Hardened source auditing against credential-bearing URLs and symlinked directories.

## Current application

The fork includes compact phone and TV layouts; Live TV, Sports, Movies and Series; category organisation; EPG enrichment; event channel matching; replay/highlight discovery; multiview; picture-in-picture; and playback recovery.

Recent reliability work improves sports cache reuse, progressive loading, remote navigation, fullscreen/preview transitions, feed failure diagnostics and dismissible theme-aware notices. Original project history is available from the upstream repository linked in `NOTICE.md`.
