# Android release checks

Before publishing a release, verify the exact source and APK together:

- Run static analysis, app tests, source privacy checks and the tooling tests in [development](development.md).
- Export a clean source snapshot and run an independent secret scanner against it. Review screenshots and image metadata separately.
- Check the APK's decompressed contents, complete runtime architectures, application ID, version and release signature. Keep signing keys and local configuration outside published files.
- Retain upstream attribution, dependency notices and matching native sources. See the [dependency inventory](dependencies/README.md).
- Verify uploaded assets and checksums before publishing the draft release. Record completed checks and any testing limitations in its release notes.

A clean working tree does not clear old commits, build outputs or local files for publication. Start a new repository from the reviewed snapshot when prior development history is not intended for release.

Windows binaries remain excluded until the native source/build gap recorded in the inventory is resolved.

[Release preparation](release.md) · [Installation](install.md) · [Attribution](../NOTICE.md)
