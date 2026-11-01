# Development tools

These tools are separate from the normal `lib/main.dart` app entry point.

| Purpose | Tools |
| --- | --- |
| Source privacy and clean exports | `audit_repository.py`, `export_source.py`, `tests/` |
| APK privacy, runtime completeness and size | `audit_apk.py` |
| Dependency and licence inventory | `dependency_inventory.py`, `android_dependency_inventory.gradle` |
| TV frame, CPU and database profiling | `tv_profile.dart`, `tv_cpu_sample.dart`, `tv_database_profile.dart`, `profile_tv_navigation.py`, `profile_tv_hold.py` |
| Local playback fixtures | `tv_fixture_server.py`, `tv_fixture_setup.dart`, `tv_fixture_cleanup.dart`, `tv_playback_smoke.dart` |
| Sports and multiview diagnostics | `tv_replay_audit.dart`, `tv_multiview_profile.dart` |
| Optional phone-pairing relay | [pair_relay/](pair_relay/README.md) |
| Split-file APK downloads | `package_preview_download.py` |

Read each script's header and CLI help before running it. Device profiling sends remote input; fixture setup and cleanup modify the installed app's test playlist. Use a dedicated test install and locally served media. The profiling scripts currently target the release application ID, so a separate debug install requires adjusting that target.

Keep device addresses and private paths in the ignored `.env`, and reports outside the checkout. Never pass the entire `.env` to Flutter build definitions. [Build and test instructions](../docs/development.md) · [Release preparation](../docs/release.md).

Source exports audit the copied bytes and discard partial output on failure. Compressed archives, symlinks and nested repositories stop the export for review. Keep the checkout idle while exporting; source scans do not clear older Git history for publication.

APK downloads also undergo an audit before any parts are written. Signing verification, embedded-version checks and device testing remain separate release steps. Keep debug symbols outside the checkout and published downloads.
