# Release preparation

## Source and checks

Run the checks in [development](development.md), then scan the source with Gitleaks or an equivalent secret scanner. Review screenshots manually. Keep credentials, signing keys, private data and generated downloads out of Git.

Source audits cover the current files, not previously published commits or binaries. To create a reviewed source snapshot without Git history, preserve the licence and attribution and run:

```sh
python3 tools/export_source.py /path/outside/checkout/source-snapshot
```

The destination must be new. The exporter writes the exact bytes it audits, omits Git history and ignored files, and discards incomplete exports. File-list changes during export require a retry. It preserves executable permissions without copying local file metadata. Avoid editing the checkout while exporting.

Archives, symlinks and nested repositories require separate review; the exporter will not silently include them. Do not copy the old `.git` directory, local configuration or build output into the snapshot. Automated scans cannot establish that arbitrary images or encoded text contain no private data; retain manual review.

Adding a file to `.gitignore` does not remove it from Git. The audit also flags tracked files matching ignore rules. Review those entries and untrack local-only files before exporting; keep any needed local copies outside the snapshot.

In the snapshot directory, initialise a new history before running the Git-based source checks:

```sh
git init -b main
python3 tools/audit_repository.py
python3 -m unittest discover -s tools/tests
```

Set a public commit identity, such as a GitHub noreply address, before the first commit. Review `git status` and the staged files before connecting a new remote.

## Android APK

1. Set the four signing values from `.env.example`; keep the keystore outside source. Preserve the certificate for updates. Without these values, local release builds fall back to debug signing and are not distribution builds.
2. Increase the version/build number in `pubspec.yaml`. Build from a neutral directory such as `/workspace/iptv-app` so generated source paths do not expose a personal home directory.
3. Build and verify:

```sh
flutter build apk --release --target-platform android-arm,android-arm64
python3 tools/audit_apk.py build/app/outputs/flutter-apk/app-release.apk
```

This creates one APK containing both ARM runtimes at `build/app/outputs/flutter-apk/app-release.apk`. No architecture choice is needed when installing it. The Gradle configuration keeps plugin libraries aligned with the requested Flutter targets.

The APK audit scans decompressed entries and filenames, checks for private/generated files and verifies complete Flutter runtime libraries for each packaged ABI. It reports sizes without extracting files or printing matched secrets. Review findings before distribution; the download packager now enforces this check on the exact bytes it packages.

Separately check the application ID, embedded version, signing certificate and checksum with Android build tools. The audit does not verify signatures or all manifest metadata, and cannot prove arbitrary encoded data is safe. The download manifest uses the checkout's `pubspec.yaml`, so verify that it matches the APK. Old APKs are not cleared by a clean source scan; rebuild from the final reviewed source.

## GitHub Releases

Create a version tag from the reviewed source and prepare a draft release. Attach:

- `iptv-app.apk`: the signed, audited APK. Keep this filename stable for the latest-download link.
- `iptv-app-source.zip`: the exact corresponding application source, without local configuration or build output.
- `android-native-sources.zip`: the pinned decoder build project, Media3 and FFmpeg source trees, licences and build instructions.
- `SHA256SUMS.txt`: SHA-256 checksums of the three files above.

Verify the draft assets before publishing. The stable APK address is `https://github.com/akus0/iptv-app-public/releases/latest/download/iptv-app.apk`; mark a normal release as latest for that route to work. Keep experimental prereleases separate. The [installation guide](install.md) describes phone/TV installation and optional Downloader codes.

## Distribution

Publish the exact corresponding application and native-library sources, build scripts and notices alongside each binary. Use the [dependency inventory](dependencies/README.md); the Jellyfin sources JAR alone omits FFmpeg. Keep Windows binaries out of releases until the recorded libmpv source/build gap is resolved.

For a split-file web download, use:

```sh
python3 tools/package_preview_download.py APK_PATH --output-dir OUTPUT_DIRECTORY
```

Keep that output outside source. Verify the downloaded checksum and retain the intended access controls. Use your own branding and relay infrastructure.

[Current release review](release-readiness.md) · [Licence and attribution](../NOTICE.md)
