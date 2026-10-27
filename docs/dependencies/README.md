# Dependencies and notices

Pinned versions, licence metadata and source references for the reviewed build:

| File | Contents |
| --- | --- |
| [dart-packages.json](dart-packages.json) | 134 Dart/Flutter packages, scope, source archives and licence hashes |
| [android-runtime.json](android-runtime.json) | 101 external Android modules, artifact hashes and POM licence metadata |
| [native-sources.json](native-sources.json) | Native build revisions, submodules, SDK versions and unresolved source gaps |
| [advisories.json](advisories.json) | Dated OSV results; no matches returned for the queried versions/commit |

All inventoried Dart packages have licence text. Licence labels are pattern-based; full texts remain authoritative. Advisory coverage is incomplete and must be rechecked for releases.

Additional Android notices live in [assets/licenses](../../assets/licenses/) and load through **Settings → About iptv-app → Open-source licences**. Flutter supplies Dart-package and engine notices separately. Neither replaces required source distribution.

## Update the inventory

After `flutter pub get` with the intended SDK:

```sh
python3 tools/dependency_inventory.py
cd android
./gradlew -I ../tools/android_dependency_inventory.gradle writeReleaseDependencyInventory
```

The Gradle task may fetch Maven metadata; it does not upgrade dependencies. Review `native-sources.json` and the native notice manifest manually when versions change.

## Binary releases

- **Android:** Jellyfin's decoder declares GPL-3.0. Its sources JAR excludes FFmpeg. Supply its build project and both pinned Media3/FFmpeg submodule trees, not just the JAR. The app's Media3 version and decoder's build revision differ; both are recorded.
- **Windows:** the locked libmpv binary lacks a verified complete source/build package. [Upstream enquiry](https://github.com/media-kit/media-kit/issues/1460). Hold Windows binary releases until resolved or replaced and tested. The wrapper's MIT licence does not cover the native libraries.
- **Other obligations:** preserve each dependency's notices and source requirements, including desktop `dbus` under MPL-2.0. The inventory locates materials; it is not a complete native-source archive.

Sports data and provider artwork have separate terms. Bundled league logos have been removed; replay/highlight badges use locally rendered initials.
