# iptv-app

An IPTV player for Android phones and TVs. Bring your own M3U or Xtream Codes playlist and XMLTV guide.

**[Releases](https://github.com/akus0/iptv-app-public/releases)** · [Phone and TV installation](docs/install.md)

Source is available now. A verified public APK has not been published yet. Android releases will use one APK for ARM phones, Android TV and Google TV running Android 7.0 or newer, hosted here on GitHub.

![Live TV guide on TV](docs/screenshots/live-tv.png)

## Features

- **Live TV:** programme guide, category folders, favourites, history, and search across channels and current programmes.
- **Sports:** live and upcoming events, scores, ranked channel suggestions, plus replays and highlights found in your guide.
- **Movies & Series:** Xtream libraries with category browsing, search, favourites and continue watching. Categories load on demand.
- **Multiview:** two or four channels, selectable audio, and horizontal or vertical two-screen layouts.
- **Playback:** preview and fullscreen controls, picture-in-picture and background audio on supported Android devices.
- **Appearance:** remote-friendly TV navigation, compact phone layouts, and dark grey, OLED black or light themes.

## Get started

1. Open **Settings → Playlists & guide → Add Playlist** and enter your playlist details.
2. Choose **Organise with iptv-app** for grouped categories, or **Keep provider categories** for the original layout.
3. For an Xtream playlist, enable the content you want under **Content from this playlist**. Guide updates and supplementary sources are under **Playlists & guide → TV guide**.

The app includes no channels, subscriptions or media. Sports coverage depends on the available schedules and your guide; suggested channels may need manual selection. Multiview needs enough device capacity and connections allowed by your provider.

## Screenshots

| Live TV on phone | Sports on phone |
| --- | --- |
| <img src="docs/screenshots/live-tv-phone.png" width="300" alt="Phone Live TV guide with channel list and preview"> | <img src="docs/screenshots/sports-phone.png" width="300" alt="Tennis event with tournament, score and suggested channel"> |

| Replays | Highlights |
| --- | --- |
| <img src="docs/screenshots/replays-phone.png" width="300" alt="Replay listings with league initials, dates and programme details"> | <img src="docs/screenshots/highlights-phone.png" width="300" alt="Highlights grouped by sport with programme summaries"> |

**Sports on TV**

![Sports on TV with preview beside the events](docs/screenshots/sports-tv.png)

**Sports in phone landscape**

![Landscape sports layout](docs/screenshots/sports-landscape.png)

**Movies on TV**

![Movies browser on TV](docs/screenshots/movies-tv.png)

Current app layouts rendered with sample data; video and poster placeholders are intentional. [Screenshot details](docs/screenshots/README.md).

## Build

Use Flutter 3.47.7, JDK 21 and the Android SDK:

```sh
flutter pub get
flutter run
```

See [development](docs/development.md) for checks and local settings, and [release preparation](docs/release.md) for signed APKs.

## Licence

GPL-3.0. Based on [VesperTV](https://github.com/NoXqc/VesperTV) by NoXqc and contributors; this fork is independently maintained.

[Licence](LICENSE) · [Attribution](NOTICE.md) · [Trademark terms](TRADEMARKS.md) · [Changelog](CHANGELOG.md)
