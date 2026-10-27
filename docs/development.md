# Development

Use Flutter 3.47.7, JDK 21 and the Android SDK. The locked dependencies require Dart 3.12+ and Flutter 3.44+.

The package retains its Dart 3.3 language mode; the lockfile determines the higher SDK requirement. Treat language-mode changes as a separate migration.

```sh
flutter pub get
flutter run
```

Keep `pubspec.lock`; dependency upgrades are separate changes. To verify the pinned resolution, use `flutter pub get --enforce-lockfile`. The patched Android player lives in [third_party/video_player_android](../third_party/video_player_android/DOWNSTREAM.md).

## Checks

```sh
flutter analyze
flutter test --concurrency=1
python3 tools/audit_repository.py
python3 -m unittest discover -s tools/tests
```

Use focused tests while editing. Optional fixture/device tests skip when their inputs are unavailable. Routine tests must use synthetic data, not subscription streams.

For GitHub Actions, copy [the privacy-check workflow](../tools/source-audit.workflow.yml) to `.github/workflows/source-audit.yml` using a login with workflow permissions. The checks above also run locally.

## Code map

| Area | Location |
| --- | --- |
| Screens, shared controls and remote navigation | `lib/screens/`, `lib/widgets/` |
| Playback and multiview | `lib/services/playback_service.dart`, `multiview_session.dart` |
| Playlists and on-demand libraries | `lib/services/playlist_manager.dart`, `playlist_session.dart` |
| Programme guide and storage | `lib/services/epg_service.dart`, `epg_database.dart` |
| Sports loading, matching and discovery | `lib/services/sports_*` |
| Category grouping and presentation | `lib/utils/` |
| Tests and local profiling | `test/`, `tools/` |

## Local settings

Copy `.env.example` to `.env` and run `chmod 600 .env`. Use unquoted `KEY=value` entries; escape backslashes as `\\`. Keep keystores and private datasets outside the checkout.

Gradle reads the four Android signing settings; environment variables take precedence. **Never pass the whole `.env` to `--dart-define-from-file`**: that could embed secrets in the app.

Optional public build settings are `PAIR_RELAY_BASE`, `TRAKT_CLIENT_ID`, `SIMKL_CLIENT_ID` and `TRAKT_REDIRECT_URI`. Register your own services before using them. These values are visible in distributed binaries; playlist credentials belong in runtime settings. LAN phone pairing needs no relay.

Sports scores, schedules and channel matching do not require private build credentials. The sports services use public endpoints and the user's playlist/guide. `PRIVATE_*` entries in `.env.example` are file paths for optional offline tests, not API keys; the normal app does not read them. Public feeds may still be unavailable or rate-limited. Optional TMDB enrichment uses a key entered by the user in Settings.

Keep device serials, addresses and private fixture paths in `.env`. Keep logs and device captures outside source. Reviewed screenshots using sample data belong in [docs/screenshots](screenshots/README.md).

[Release preparation](release.md) · [Dependency inventory](dependencies/README.md) · [Development tools](../tools/README.md)
