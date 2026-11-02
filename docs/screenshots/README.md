# App screenshots

Rendered from the current Flutter widgets with sample channels, events and a test catalogue. No subscription streams or account details are used; video previews and movie posters are intentionally empty.

## Live TV

![Live TV guide on TV](live-tv.png)

<img src="live-tv-phone.png" width="300" alt="Live TV guide on phone">

## Sports

![Sports on TV](sports-tv.png)

![Sports in phone landscape](sports-landscape.png)

| Events on phone | Replays on phone |
| --- | --- |
| <img src="sports-phone.png" width="300" alt="Tennis event with tournament, score and suggested channel"> | <img src="replays-phone.png" width="300" alt="Replay listings with league initials, dates and guide details"> |

<img src="highlights-phone.png" width="300" alt="Highlights grouped by sport with programme summaries">

## Movies

![Movies browser on TV](movies-tv.png)

## Refresh these images

Use the screenshot cases in `test/live_layout_navigation_test.dart` and `test/library_test.dart`. Set `LAYOUT_FONT_DIR` to a local folder containing `Roboto-Regular.ttf` and `MaterialIcons-Regular.otf`:

```sh
flutter test --concurrency=1 --dart-define=CAPTURE_LAYOUT=true --dart-define=LAYOUT_FONT_DIR=/path/to/fonts test/live_layout_navigation_test.dart --name 'guide and navigation fit (1280|390)|tennis tournament cards fit (390|844|1280)'
flutter test --dart-define=LAYOUT_FONT_DIR=/path/to/fonts test/library_test.dart --name 'library fits Size\(960'
```

The tests write PNGs to `/tmp`. Review them before replacing the files here. Keep real-device captures and private data outside the repository.
