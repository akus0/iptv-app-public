# App screenshots

These captures render the current Flutter screens at TV, phone portrait and phone landscape sizes. The sample collection contains 102 channels across nine categories, 30 sports events across five leagues, a populated schedule, a 20-team standings table, and 24 titles in each on-demand library. Replay and highlight listings use sample guide entries.

All fixtures, scores, programme listings, channel identities and library titles are demonstration data. Team names are used to illustrate the interface; these are not current results or broadcast claims. The preview is a static illustration labelled **Sample preview**, and the posters and numbered channel badges are original fixture artwork. No subscription stream, provider account, private playlist or real-device capture is included. Published releases may differ from these current-source views.

## Live TV

![TV programme guide](live-tv.png)

![Expanded TV programme guide with the main menu and categories collapsed](live-tv-expanded.png)

<img src="live-tv-phone.png" width="360" alt="Phone guide with sample channels and programme listings">

## Sports events

![Sports events on TV](sports-tv.png)

![Sports events in phone landscape](sports-landscape.png)

<img src="sports-phone.png" width="360" alt="Phone events with sample scores and channel matches">

## Standings and schedule

![TV standings with a populated sample league table](standings-tv.png)

![TV schedule](schedule-tv.png)

| Standings on phone | Schedule on phone |
| --- | --- |
| <img src="standings-phone.png" width="320" alt="Sample football standings on phone"> | <img src="schedule-phone.png" width="320" alt="Sample fixtures and channel choices on phone"> |

![Standings in phone landscape](standings-landscape.png)

![Schedule in phone landscape](schedule-landscape.png)

## Replays and highlights

![Replay listings on TV](replays-tv.png)

![Highlight listings on TV](highlights-tv.png)

| Replays on phone | Highlights on phone |
| --- | --- |
| <img src="replays-phone.png" width="320" alt="Phone replay listings"> | <img src="highlights-phone.png" width="320" alt="Phone highlights"> |

![Replays in phone landscape](replays-landscape.png)

![Highlights in phone landscape](highlights-landscape.png)

## Movies and series

![Movies on TV with original sample posters](movies-tv.png)

![Series on TV with original sample posters](series-tv.png)

| Movies on phone | Series on phone |
| --- | --- |
| <img src="movies-phone.png" width="320" alt="Sample movie library on phone"> | <img src="series-phone.png" width="320" alt="Sample series library on phone"> |

## Settings

![Settings beside the preview on TV](settings-tv.png)

<img src="settings-phone.png" width="360" alt="Compact settings on phone">

## Refresh these images

The opt-in capture harness is [readme_screenshots_test.dart](../../test/readme_screenshots_test.dart). It mounts the production widgets with in-memory playlists, guide data, sports services and catalogue entries. Playback and image loading use local fixtures; HTTP responses are mocked. No app code or device installation is changed.

Provide `Roboto-Regular.ttf` and `MaterialIcons-Regular.otf` from the Flutter SDK's `bin/cache/artifacts/material_fonts` directory. Also provide an emoji font supported by the host renderer and [Noto Sans Symbols 2](https://github.com/notofonts/noto-fonts/tree/main/hinted/ttf/NotoSansSymbols2), licensed under the SIL Open Font License. These captures use the macOS system Apple Color Emoji font; emoji appearance varies by device. Fonts stay outside the repository. The harness resolves Android font fallbacks explicitly because the widget-test engine otherwise uses its block-shaped Ahem test font for some controls.

```sh
flutter test --concurrency=1 test/readme_screenshots_test.dart \
  --dart-define=LAYOUT_FONT_DIR=/path/to/flutter-fonts \
  --dart-define=README_EMOJI_FONT=/path/to/host-emoji-font.ttc \
  --dart-define=README_SYMBOL_FONT=/path/to/NotoSansSymbols2-Regular.ttf \
  --dart-define=README_SCREENSHOT_DIR=/tmp/iptv-app-screenshots
```

Without `README_SCREENSHOT_DIR`, these capture cases are skipped. Captures are rendered at twice the logical resolution: TV 1920 × 1080, phone portrait 780 × 1688, and phone landscape 1688 × 780. Review every generated image for missing glyphs, empty states, clipping and private data before replacing the corresponding PNGs here. Keep original provider data and device diagnostics outside the checkout.
