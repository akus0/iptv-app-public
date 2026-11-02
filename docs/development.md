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
| Programme guide and storage | `lib/services/epg_service.dart`, `xmltv_parser.dart`, `epg_database.dart` |
| Sports loading, matching and discovery | `lib/services/sports_*` |
| Category grouping and presentation | `lib/utils/` |
| Tests and local profiling | `test/`, `tools/` |

Stalker / MAC portal setup, loading boundaries and compatibility notes are in
[the portal guide](stalker.md). The shared `CatalogApi` contract reuses existing
catalogue storage; portal authentication and stream resolution stay in
`stalker_portal_service.dart`.

## UI responsiveness checks

Sports tabs distinguish selection from focus: the underline identifies the open page, while a border identifies remote/keyboard focus. Touch input suppresses that border even when Flutter retains logical focus. Explicitly resolve the tab button's `side`, since the theme can override a border supplied through `shape`. Input-mode changes rebuild only the tab strip through a local notifier; activating a tab moves its focus anchor without starting extra data work.

Schedule channel labels read the current Events match session by the same league/event identity and use its displayed-channel selection, confidence and saved-pick rules. Only mounted fixture rows resolve labels; activation reads the current result again and uses the existing preview/playback queue. Do not call matching, catalogue preparation or guide searches from Schedule. Unmatched rows open details, and matched rows retain details through hold-to-open and their touch info button. Keep row heights stable as matches arrive so focus and date tracking do not jump.

Replay/highlight foreground scans use the same cooperative cancellation points as idle preparation. Leaving a panel invalidates its request generation, including a quick leave-and-return before the next yield. Cancelled scans must not publish a completed cache entry or overwrite the current panel; prepared facts and valid partial results remain reusable. Exercise queued cancellation, worker cleanup, returning to the panel and unchanged final classifications when profiling a large catalogue.

Flutter handles input and synchronous Dart preparation on the UI isolate. A frame runs animation callbacks, widget build, layout, paint/compositing and scene submission, followed by finalization and post-frame callbacks; raster work is measured separately. A short screen `build()` does not imply a fast first frame: descendant layout, catalogue preparation, native resource waits and extra frame barriers can dominate. See [WidgetsBinding.drawFrame](https://api.flutter.dev/flutter/widgets/WidgetsBinding/drawFrame.html), [performance practices](https://docs.flutter.dev/perf/best-practices) and [device profiling](https://docs.flutter.dev/perf/ui-performance).

Top-level tab routes and Settings already use zero-duration transitions. Library and Settings results can forward to their next destination without waiting for overlay disposal and briefly rendering Live TV between tabs. Sports still waits for disposal when transferring an existing video preview; filtered/replay exits must first make their PopScope permit leaving. Delayed Live focus restoration must check that Live is still the current route.

On physical TVs, the root theme also gives ordinary Material routes zero forward and reverse transition durations. This includes nested settings and detail pages; touch devices retain their platform transitions. Cache both theme variants so local screen themes do not invalidate the root theme cache. Custom player routes retain their existing ownership and disposal rules.

`RouteAwareRegion` owns Live's route dependency and observer subscription. Navigation must not make the entire retained Live screen rebuild just because `ModalRoute.isCurrent` changes. Its callbacks read the current route object directly. Provider updates received while another page covers Live defer rebuilding its content until `didPopNext`; current data is then read normally. Dialogs still allow visible Live content to update. Test repeated pushes/pops, dialogs, deferred provider updates, restored focus and viewer changes.

`PlaybackService.parkLiveChannel` starts releasing a live decoder while Library opens. Subsequent playback still waits on the existing release queue; only the same request generation may restore the resume hint. Do not replace decoder ownership barriers with arbitrary timers. `playback_recovery_test.dart` covers delayed release and intervening play/stop; `live_layout_navigation_test.dart` covers navigation while release is pending and same-frame Library/Settings forwarding.

Live TV column depth is a local `ValueNotifier`: rail widths, dividers and shortcut bindings listen to it while retaining the menu, categories and guide as stable children. TV focus changes must not call screen-wide `setState`; touch layouts still need it for collapsed icons and their Back button. Real catalogue, preference and playback notifications continue rebuilding their dependent content. Keep hidden TV columns mounted at their expanded internal width so Back restores their focus and scroll position.

TV Live categories use `VerticalRailTraversalPolicy` for Up/Down. Read each eligible row's current rectangle once and select the nearest row vertically; repeated geometric sorting across a large expanded category tree can block input before a frame starts. Fresh geometry preserves category reordering and folder changes. Left/Right and Tab retain their existing traversal, while row movement handlers still take precedence. TV row reveal is immediate and only scrolls clipped rows; touch retains its existing behavior. Regression tests cover large rails, disabled/removed/reordered rows and browsing categories after Favourites or History without scrolling animations or catalogue reloads.

Multiview's category picker uses the sliver form of `LiveCategoryFolders`, mounting rows near the viewport instead of laying out every category. The selected row occupies its own box sliver so returning from the guide can still focus and reveal a distant category. Recheck reveal after layout resolves estimated list extents. Preserve original ordering, folder preferences, collection/source identities and variable row heights. Large-list tests cover bounded mounted controls, a distant initial selection, repeated arrow navigation and returning after changing categories. Other category hosts retain their existing rendering.

A retained guide still changes viewport width when the rails hide. Its horizontal `ScrollMetricsNotification` refreshes programme culling after layout, independently of guide builds and scroll-offset listeners. Programme focus reveals only the horizontal axis; vertical positioning belongs to the guide's minimal row reveal. Calling `Scrollable.ensureVisible` across all ancestors can unexpectedly top-align the selected channel. `live_layout_navigation_test.dart` covers fast repeated column drills, unchanged guide widgets, remembered focus and both scroll offsets, newly exposed programme cells, off-screen horizontal focus restoration and subsequent catalogue updates in preview and full-video layouts.

Search builds result cards near the horizontal viewport. Row keys, focus nodes and scroll controllers belong to the screen and use stable content-type identities, so catalogue notifications or late rows do not replace the focused row. Child identity lookup indexes only as far as reconciliation requests; eagerly constructing a full key index can erase the gain from lazy widgets on a large result set. Live filtering reuses the playlist's visible snapshot and keys its result by playlist identity, live revision and query. Visibility changes must invalidate it. `search_navigation_test.dart` covers large catalogues, focus/scroll retention, removed results, late rows and returning to a recycled first card.

Library caches only pure category-title classification, bounded to 4,096 entries and 262,144 retained text characters, bypassing unusually long entries. Each tree still uses current group objects, visibility, provider layout and ordering. Never cache viewer decisions or full category trees by title alone. Compare complete tree identities, labels and paths when changing classification.

For each performance pass, compare release/profile builds on the same physical device with the same catalogue and navigation sequence. Record action-to-first-frame separately from network completion and synchronous build time. Test repeated visits, real remote input, background loading and pending player teardown. Use synthetic large catalogues for repeatable Search checks; keep subscriber data and private profiling entry points out of distributed builds. Maintain normal playback, image decoding limits, lazy guide/library lists and existing targeted focus rebuilds.

For deeper navigation diagnostics, keep the profiler in a private entry point. Time the navigation callback, synchronous route setup, widget build, root pipeline layout/compositing/paint, tree finalization and the engine's frame timestamps separately. Layout includes lazy descendant construction. A post-frame observer can resume after other microtasks; its latency is not a physical display-presentation measurement. Frame submission and rasterization can overlap later UI-isolate work, so do not blindly add every duration. Observe routes without registering new inherited-widget dependencies, buffer detailed records outside the measured callback, and pair delayed `FrameTiming` reports by monotonic timestamps rather than the currently selected page. Compare both settled and rapid navigation, then confirm with native remote key events. Keep first page appearance separate from the first frame containing database results.

Sports cached-day filtering compares event instants with precomputed local midnight boundaries. Use calendar arithmetic for previous/next day, preserving 23/25-hour days, carry-over live games, duplicate removal and tournament rules; do not substitute an elapsed 24-hour window. Score responses younger than the shortest freshness window (50 seconds) need no per-game freshness scan. Clock rewinds, refresh requests, failures and exact expiry boundaries still follow their existing rules. `sports_calendar_test.dart` runs under `TZ=Australia/Melbourne`, `TZ=America/New_York` and `TZ=UTC`; `sports_loading_test.dart` covers the different exact-50-second rugby and ordinary-score boundaries.

Mobile multiview owns an `ImmersiveSystemUi` lease while mounted. Android's native `WindowInsetsControllerCompat` hides the system bars with transient swipe reveal; Flutter's legacy immersive `SystemUiMode` is ignored when targeting Android 16. The activity restores the prior bar visibility/behaviour on release and reapplies hiding when window focus returns. Dart leases prevent an outgoing route from showing bars over its replacement. Video surfaces retain their bounds when transient bars appear; only overlay controls consume safe-area padding. See [Android immersive mode](https://developer.android.com/develop/ui/views/layout/immersive) and `multiview_ui_test.dart` / `immersive_system_ui_test.dart`.

The Add Playlist form keeps its Add/Save action outside the scrolling fields, inside the keyboard-resized body and system safe area. Short landscape phones use the stacked form; the three-column layout remains for wide TV/tablet views. `add_playlist_layout_test.dart` covers source switching, add/edit submission, keyboard reachability, system insets and disabled duplicate submission at small portrait, landscape and TV sizes. The wide options pane scrolls independently so Xtream content toggles cannot push the save action off screen. Phone pairing prefers physical LAN interfaces and excludes known VPN tunnels; VPN software must permit local network access.

`playlist_save_failure_test.dart` covers rejected M3U, Xtream and Stalker additions, repeated activation, storage failures, retry and leaving while validation is pending. Roll back failed new profiles even after the form is disposed; retain the error locally while mounted and keep feedback above the fixed save action. Restore Save focus after a submitted request only if the user has not navigated elsewhere; local field validation retains its corrective focus. Existing profiles and cached content remain available after a failed refresh.

An explicit full catalogue update refreshes library metadata before downloading visible categories. Ordinary live loading remains lazy. Share overlapping full updates and one provider request allowance across movies and series. Do not advance the full-sync timestamp after metadata, category or storage failure. Reject malformed Xtream list responses rather than replacing saved titles with an empty list. `playlist_refresh_reliability_test.dart` exercises the real HTTP parsing path against a loopback fixture, including failed authentication, partial updates, malformed responses, disabled content, hidden groups, library-only playlists and retries. Sports overlays own a local scaffold messenger so Undo stays above the modal barrier; their scaffold must not apply keyboard insets a second time. Favourite rows explicitly move Right to their remove button and Left back to the row, since nested controls inside the row rectangle are unreliable targets for geometric directional traversal.

Group Management searches all live category names in the selected playlist, including hidden groups. Search is case-insensitive and matches every whitespace-separated term. Keep typing local to the lazy list; provider notifications must refresh visibility without losing the query. With an active filter, Show/Hide matches affects only matching titles; clearing search never changes selections. Preserve deferred loading during playlist setup. The search field uses TV keyboard gating and owns digit/caret keys while focused; short keyboard layouts prioritize search and results. `group_management_search_test.dart` covers large lists, loading policy, provider isolation, filtering, bulk actions, scroll reset, tab retention and phone/remote input.

Movies and Series title search spans every visible category and enabled playlist for the selected content type. Clearing it returns to the selected category; favourites and continue-watching retain their own filters. SQL applies the allowed `(playlist_id, category_name)` scope before count/sort/paging, using a transaction-local replacement of a temporary scope table to avoid SQLite parameter limits. Return only the current 60-title page; never use the older 200-result search cap or in-memory category previews. Literal `%`, `_` and backslashes are escaped.

An explicit library search uses `LibrarySearchLoader` to fill missing categories sequentially through the existing category request queue. Saved titles appear first; successful empty categories are remembered for this screen session and failures remain retryable. Clearing search, changing shelves/content type or disposing the screen stops subsequent requests; an already-running fetch may finish safely into the cache. Downloads do not start during ordinary browsing. Query generations reject stale replies. Late titles offer Update results while a poster is focused, preserving its position; otherwise completion refreshes the active query. `library_search_test.dart` covers SQL scope/pagination, over 1,200 categories, concurrent content scopes, cancellation/retries, phone/TV search, and late results without focus movement.

## Sports performance checks

### Matching flow and ownership

| Responsibility | Implementation |
| --- | --- |
| Visible state, completed identities and expiry | `sports_screen.dart`, `sports_match_session.dart` |
| Live-first batch selection and serialized worker jobs | `sports_match_batch_plan.dart`, `sports_work_queue.dart` |
| Worker lifecycle, transfers and guide snapshot dependencies | `sports_matching_worker.dart`, `guide_read_tracker.dart` |
| Guide reads, optional title index and exact title filtering | `epg_database.dart`, `sports_guide_search_index.dart`, `sports_title_filter.dart` |
| Programme postings, text facts and prefix reuse | `sports_programme_index.dart` (private part of the matcher) |
| Evidence scoring, eligibility and shared-feed conflict resolution | `sports_channel_matcher.dart` |
| Pure text/date/time helpers with focused equivalence tests | `sports_language.dart`, `sports_title_matcher.dart`, `sports_date_matcher.dart`, `sports_programme_time_index.dart` |

Keep candidate selection separate from scoring: an index narrows work but cannot confirm a match. Pure text caches may survive unchanged inputs; decisions must still respect catalogue identity, guide corrections, current time, picks and programme expiry. Keep database resources with their owner and CPU-only work in the matching/filtering workers. A catalogue change while programme preparation yields asks the caller to retry before scoring or publishing.

Session publication and later input refreshes share one programme-expiry rule. Drop already-ended programme evidence from incoming replies before recording completion, preserving manual picks and finished-event history. Otherwise a cached historical reply can repeatedly restore evidence that the next batch immediately expires, leaving a completed scan permanently short of its checked count. Programme evidence that expires after publication still requests a fresh check normally.

### Browsing while loading

Measure remote input and frame work during cold matching as well as total matching time. Background guide refreshes share that startup window: XMLTV decompression, UTF-8 decoding, tokenization and timestamp parsing run in `xmltv_parser.dart` on a separate isolate. The caller retains HTTP and database ownership. The worker pulls at most 64 KiB of input per request and waits for each 1,000-row database batch; final channel catalogues transfer when the worker exits. Preserve channel normalization, localized titles, subtitles, timestamps, retention windows and the unfiltered assignment catalogue when changing this path. Errors and the ten-minute timeout cancel the input and terminate the worker; stale-source deletion still requires successful parsing.

TV Sports rows use fixed extents and build lazily. Keep the focused row alive, resolve pending navigation by stable section/card identity, and accumulate arrow steps while an off-screen target mounts. New results preserve the focused card's scroll position; a removed card moves to a surviving neighbour. Deferred restoration must yield to newer user navigation. Regression coverage in `live_layout_navigation_test.dart` exercises rapid arrows, off-screen headings, streamed arrivals/removals and toolbar escape; `xmltv_parser_test.dart` covers streamed gzip/Unicode, filtering, backpressure and cancellation.

### Guide search

Guide rows use SQLite's `(channel_id, start)` primary key, with secondary indexes for expiry and source refreshes. Channel-name matching uses in-memory token postings, checking the shortest posting list before testing a phrase. Measure SQL reads, text analysis and rendering separately before adding indexes.

For device profiling, build `tools/tv_profile.dart` with `IPTV_DISABLE_AUTOPLAY=true` and `IPTV_PROFILE_SPORTS=true`. Add `IPTV_PROFILE_GUIDE_INDEXES=true` to inspect existing guide query plans and sample read timings. This inspection is read-only and logs no guide content. Use the normal entry point for distributed builds.

Sports title search uses an optional persistent FTS4 dictionary (FTS5 where FTS4 is unavailable). Up to four encoded trigrams per ASCII keyword narrow substring candidates; the existing matcher verifies every hit. SQLite deduplicates candidate IDs before transferring titles. Bounded SQL unions and implicit conjunctions also work with Android's basic FTS4 parser.

Unicode and pending titles retain exact checks. Native keywords do not force ASCII keywords to scan the whole dictionary; short ASCII keywords still do. This relies on non-Unicode RegExp case folding ([Dart semantics](https://api.dart.dev/dart-core/RegExp-class.html), [ECMAScript Canonicalize](https://tc39.es/ecma262/2024/multipage/text-processing.html#sec-runtime-semantics-canonicalize-ch)).

Guide writes queue new titles; idle maintenance derives tokens in bounded batches. Missing tables/triggers or index errors fall back to ordinary guide reads without entering database recovery. Cancellation leaves pending titles searchable. Rebuild the dictionary if token/language rules change. Scoped title queries serialize their complete cursor/table lifecycle to avoid temporary-schema locks; failures release the queue for retries. Other guide reads remain independent.

J1 matching recognises `J.League` and `JLeague` as competition vocabulary alongside `J1 League`, without using the short `J1` label to widen guide searches. Abbreviated team evidence still needs both opponents and a fixture connector. A named or dated event feed is evidence of a listing, not verification of its live stream; expired guide entries for rotating slots must not establish a current fixture. The six-fixture regression covers partial provider coverage, stale slots, unrelated Tokyo tennis, wrong opponents and replays.

The title worker caches translated or normalised fallback text only. Ordinary ASCII misses return no fallback and must not evict more expensive Unicode/language results between fixture batches. This cache stores no query results; changed keywords still run the same exact matcher, with the existing entry, character, long-title and worker-lifetime limits.

Native club vocabulary lives in `sports_team_vocabulary.dart`. Verified full Japanese/Korean club names and selected EASL Japanese/Chinese names use the existing cached language fallback; fixture queries stay in their canonical spelling. Native scoreboard identities use the same exact lookup. Do not infer clubs from bare cities, mascots or automatic transliteration. Preserve women's/youth qualifiers, opponent and time checks; FC Tokyo's short name must not identify Tokyo Verdy. An unnamed numbered feed or expired programme still cannot confirm a fixture.

JEF United Ichihara-Chiba, JEF United Chiba and JEF Utd Chiba share an exact full-name alias lookup at fixture preparation, matching ESPN's names to the [official club identity](https://www.jleague.jp/en/club/chiba/). Original names stay eligible and native titles retain the existing translation path. No extra guide requests or per-row alias scans are needed. J1 and K League disable sport-only suggestions: generic football coverage cannot identify these competitions' event streams. Exact fixtures, current guide evidence, explicitly listed broadcasters, league-specific suggestions and saved picks keep their normal checks. The fallback policy participates in match/cache identity. Do not repair a stale numbered event feed by borrowing a different provider's slot number or ignoring guide timestamps.

Club identities are checked against the [J.LEAGUE bilingual directory](https://archive.j-league.or.jp/teams), [K League club pages](https://www.kleague.com/club/club.do?teamId=K10), [KFA club list](https://img.kfa.or.kr/data_rule/2025_korea_cup_operation_rule_01.pdf), [EASL Japanese directory](https://www.easl.basketball/ja/teams) and [Taoyuan's official site](https://www.taoyuanpilots.tw/). This is a bounded vocabulary, not general Asian-language translation. Native guide dictionary rows already use exact fallback verification, so these native-only additions do not require rebuilding the search index.

Sports broadcaster aliases expand only explicit listings through existing exact channel-name buckets. The stored canonical channel text is unchanged, so new aliases do not invalidate the startup text cache. Added alias candidates require US region evidence; an unscoped FS1 listing must not select an Australian Fox Sports 1 feed. Existing exact-name candidates retain their normal checks. Linear ACCN/SECN/BTN/CBSSN names must remain separate from ACCNX, SECN+, B1G+/BTN+, parent networks and alternate/overflow feeds. Region and current-guide vetoes still apply. The [ACC](https://theacc.com/news/2019/3/11/general-acc-network-frequently-asked-questions.aspx) and [SEC](https://www.secsports.com/news/2021/08/about-sec-networksec-network) document these linear/digital distinctions. A Coupang Play or K League TV listing without opponents or guide evidence must not confirm an arbitrary feed.

College school aliases use exact normalized identity lookups, including [UNC Greensboro/UNCG](https://uncgspartans.com/), [UNC Wilmington/UNCW](https://uncwsports.com/), [UAB](https://uabsports.com/sports/football/schedule), [UMBC](https://umbcretrievers.com/) and [UIC](https://web3.ncaa.org/directory/orgDetail?id=302). Campus qualifiers must not identify Alabama, Maryland, Illinois or UNC's other teams; Boston U means Boston University, never Boston College or a generic Boston team. One fixture context shares its opponent phrases between retrieval and synopsis checks. Compact gender labels include both `Ice Hockey (W)` and `W Ice Hockey` (and the corresponding men's labels); they must not cross NCAA men's/women's fixtures. `sports_listed_network_test.dart` exercises the broadcaster contract for every configured league/guide category, alongside targeted school, sport, gender, country and streaming negatives. Compare fixed-input scoring and guide requests against the previous matcher before retaining changes; live feed timing alone cannot prove a performance gain.

Query-local channel IDs use bounded native write batches with no returned insert IDs: eight statements of at most 500 IDs per transfer. These temporary writes need no transaction: a failed batch discards the incomplete scope before the ordinary scoped cursor runs. Do not cache scopes across catalogues or use a partially populated table after a write error. Test failures after an earlier statement succeeds, as well as catalogue changes and final partial batches.

### Scheduling and programme preparation

Cold-start measurements must enter Sports during guide loading and distinguish first suggestions, completed Live + soon matching and the whole day's completion. Provisional broadcaster suggestions can precede the guide preload; they never replace a completed match. All live fixtures are checked together before later fixtures, preserving shared-feed conflict checks. Prepared programme postings can be reused or extended only when their row contents and tennis context agree; caches remain bounded and guide corrections still invalidate decisions. Fully prepared windows skip temporary text-map construction. Early guide snapshots can become eligible for persistent results after startup completes, but refreshing, failed or changed snapshots must not be saved.

Later fixtures run in batches of at most 128 events spanning eight hours. Reconsider newly arrived live fixtures between batches, checking the entire live cohort before promoting shared-feed assignments. Seed tennis tournament vocabulary from the complete schedule first. Completed identities survive batch boundaries; partial browse snapshots never acquire a completed-pass signature. Reused broad guide reads are narrowed to the batch's scoring window before constructing programme postings, retaining overlapping slots and the existing boundary margin.

Check known live fixtures before scanning for additional guide-only events. Discovery still precedes later-fixture batches, and newly discovered identities cause a live-cohort recheck. If the initial title query fails, retain guide-only coverage from the current snapshot while reporting the failure. Title reads start at the earliest scoring reference and use programme overlap, preserving broadcasts that started earlier. Keep the full future window for delayed sessions and all-day events.

Start full guide reads before provisional current-guide scoring, so native SQLite work can overlap worker scoring. Skip the provisional pass when the reads are already ready. Keep provisional confidence and caches separate; publish full tennis coverage after provisional scoring returns. Failed reads remain retryable. Save the completed input signature only after the batch plan has checked all current inputs, so queued score updates do not repeat an already completed pass.

Programme postings retain at most two indexes and 160,000 rows. Keep the latest index and favour the larger reusable window over small tail batches; select the longest exact prefix when extending an index. Release storage before allocating a replacement. Guide generation, row contents/order and tennis context must still match before reusing postings. This cache does not extend match freshness.

Programme time candidates retain two hour endpoints per row instead of repeating row IDs in hourly sets. Preserve the original 35-minute start margin, inclusive stop bucket, truncation toward zero before the Unix epoch and unconditional candidate fallback for ranges over 16 hours. Exact programme time checks still run during scoring. Compare membership against the old hourly sets, including prefix extension, malformed intervals and extreme dates.

### Cache validity and bounded text work

Completed worker batches track current/next channel reads with bounded bitsets (64 batches, at most 1 MiB). Snapshot turnover invalidates batches that consulted changed channels, including absent programmes. New or removed synopsis evidence invalidates all batches that used the synopsis pool. A database refresh resets every decision; untracked, disk-restored or evicted dependencies also require a fresh check after snapshot changes. Keep the original result expiry, and resolve shared-feed conflicts again when combining retained and newly checked events. Dependencies are never persisted.

The worker can persist bounded channel-name normalization and network aliases. Rebuild IDs, guide links, exclusions and postings from the current playlist; never restore these from the text cache. Cache reads verify format version, checksum and size limits, with ordinary normalization as fallback. Bump `SportsChannelTextCache.version` when the normalization or alias rules change. Version 2 retains validated entries from version 1 unless their names contain Japanese/Korean/Chinese script affected by the new vocabulary. Accents, flags and decorative quality suffixes keep their existing cache entries. Future normalization changes must not inherit this migration without equivalence evidence. Disk I/O and encoding stay in the worker.

Idle, replay and ended-name checks are lazy, in-memory facts stored in one byte per channel. Replace them atomically with every rebuilt channel index, including same-size renames and reordering. Game state, event dates and current guide eligibility are still evaluated for each request; never cache the complete eligibility decision as a channel-name fact.

Date checks reuse the three calendar dates around the reference while it remains in the same UTC day. The reference is still derived from the event and current clock on every check. Only those three date records are retained; crossing UTC midnight or rewinding into another day replaces them. Local times retain the original duration arithmetic across daylight-saving changes, and extreme dates retain the original overflow behaviour. Preserve explicit-year and ambiguous day/month rules.

Current/next and scoped title reads use native SQLite cursors with bounded transfers. ASCII fallback lookup uses Aho–Corasick; Unicode case folding and translation retain the original semantics. Text caches have entry and character limits. Background scoring yields less frequently than UI work, while result notifications remain throttled. `IPTV_PROFILE_GUIDE_FTS=true` remains a separate temporary word-index benchmark, not a production matching benchmark.

Dictionary title verification runs in one reusable worker, with at most 1,024 titles per transfer; cursors and temporary tables stay with the database owner. The candidate cursor fetches the same bounded 1,024-title batch from SQLite, avoiding four smaller platform transfers before verification can start. The worker retains query-independent translation and normalization for up to 16,384 titles and 2 Mi characters, and releases its cache after 30 seconds idle. Small tails and worker failures use the same local matcher. Literal ASCII hits also short-circuit mixed-language queries, even when titles contain native text or decoration. On a miss, mixed native query/title pairs retain the original combined regular expression's case folding, followed by the unchanged translation fallback. Compare exact title sets on one unchanged guide with both query orders, then measure cold screen entry separately. A newer guide or different fixtures can change total matching time independently of the code.

Single-day scoped title queries can materialize conservative candidates entirely in SQLite, avoiding the global title transfer and exact-hit write loop. For more than one 1,024-title batch, a bounded probe counts overlapping candidate programme rows up to the title count plus one. Only when there are no more programme rows than candidate titles does the caller defer exact verification until its programme cursor. Small dictionaries and multi-day windows retain dictionary verification; unavailable indexes and failed probes retain the ordinary exact cursor fallback. Candidate results explicitly state whether verification has already occurred. Never accept an unverified candidate as a match. The scoped reader uses the same language matcher, a bounded cache of pure fallback text (16,384 entries / 2 Mi characters), query-local title decisions and the existing cursor yield interval. No persistent schema migration or synchronous index rebuild is required. Compare all ordered programme fields, exercise both plans and failure cleanup, then measure complete cold matching separately.

The title cache uses a linked list for recency and eviction. Repeatedly removing `Map.keys.first` can scan deleted slots as a dictionary-sized query churns the cache; changing the keywords must not turn a bounded cache into repeated linear eviction work. Include a full-dictionary short-keyword query in device comparisons, not only selective indexed searches.

Bulk title filtering precomputes the ASCII automaton's transitions in the worker, using a compact alphabet and 16-bit state IDs. Retained arrays are limited to 1 MiB; larger tables, more than 65,536 states and empty patterns keep the sparse matcher. Small local checks also keep the sparse path to avoid extra setup on the UI thread. Unicode and mixed native matching retain the existing regular expressions and language fallback. Validate exact title results, overlapping suffixes and both table limits before comparing device timings.

Programme identity indexing skips description normalization when an ASCII synopsis cannot contain a fixture connector, or when the title provides no sport context and the synopsis cannot name an explicit sport. Both rejection checks derive their expressions and translated aliases from the same vocabulary as full verification. Sports-titled and dedicated tennis/motorsport coverage retain their existing synopsis path; a positive shortcut result never supplies evidence by itself. Apostrophes that can join letters under the shared fixture-normalization rule, `@` and non-ASCII text retain full analysis; ordinary ASCII possessives and quotes use the same rejection checks as other punctuation; tennis and motorsport coverage titles retain descriptions even without connectors. Verify byte-for-byte identity equality on unchanged guide rows in both execution orders before measuring cold entry. Never use this shortcut alone to establish a match.

Conflict checks share only text-derived facts across fixtures: routing-label removal, explicit sports and general gender markers. Their cache uses the existing 8,192-entry and 1 Mi character-cost limits, accounts for the fixed sport vocabulary, and bypasses inputs over 2,048 code units. Sport, gender, tournament, session and opponent decisions remain fixture-specific; no match outcomes or guide objects enter this shared cache. `sports_conflict_evidence_test.dart` checks the same school pair across sports and genders in both fixture orders, plus guide corrections that rotate a channel between those events.

Name normalization writes short ASCII labels directly into a bounded byte buffer. Non-ASCII input falls back with the entire original string, preserving Unicode lowercasing, accents, scripts and padding; inputs over 2,048 code units also retain the rune path. Check exact output equality at buffer boundaries and on mixed-language guide text in both benchmark orders. This changes computation only, not normalization rules or cache identity.

### Supplemental evidence and replays

Scoreboard hints preserve country and TV/streaming metadata. Optional NHL/MLB broadcast schedules share bounded day requests and a 30-minute disk cache. MLB radio, app-only and post-game listings are excluded; listings without market information require guide corroboration. Network failures do not block local matching.

Replays and Highlights share one current-guide result. Current programme analysis, including misses, survives refreshes; departed slots are discarded and the working set is bounded. Large cold scans use one worker with 64-programme batches, then publish immutable partial results at most every 400ms. Clearly labelled programmes are processed first; ambiguous guide-copy evidence waits for the full scan.

Idle preparation follows event matching. Programme boundaries, guide corrections and catalogue changes expire results; unchanged full-timeline loads do not. Keep tests for gaps, expiry, cancellation, worker/local equivalence, catalogue replacement and focus during progressive updates. `profileGuideBatchReads()` in the diagnostic tools compares SQLite batch sizes without changing the database.

## Local settings

Copy `.env.example` to `.env` and run `chmod 600 .env`. Use unquoted `KEY=value` entries; escape backslashes as `\\`. Keep keystores and private datasets outside the checkout.

Gradle reads the four Android signing settings; environment variables take precedence. **Never pass the whole `.env` to `--dart-define-from-file`**: that could embed secrets in the app.

The optional public build setting `PAIR_RELAY_BASE` selects a self-hosted phone-pairing relay. These values are visible in distributed binaries; playlist credentials belong in runtime settings. LAN phone pairing needs no relay.

Sports scores, schedules and channel matching do not require private build credentials. The sports services use public endpoints and the user's playlist/guide. `PRIVATE_*` entries in `.env.example` are file paths for optional offline tests, not API keys; the normal app does not read them. Public feeds may still be unavailable or rate-limited.

Keep device serials, addresses and private fixture paths in `.env`. Keep logs and device captures outside source. Reviewed screenshots using sample data belong in [docs/screenshots](screenshots/README.md).

[Release preparation](release.md) · [Dependency inventory](dependencies/README.md) · [Development tools](../tools/README.md)

## Android scope

The app retains IPTV playlists, Live TV, Sports matching, Movies, Series, local history, embedded subtitles and multiview. Media-server/archive catalogues, detailed match summaries, account scrobbling, profile management, online subtitle add-ons, desktop players and the inactive APK updater/settings transfer have been removed. Phone-to-TV playlist entry remains available. Sports replays and highlights load when selected rather than warming in the background.

Keep the existing stored viewer namespace even though profile management is gone: changing it would hide saved favourites, history and resume positions for upgraded installations. Do not delete legacy keys or alter catalogue schemas as part of UI cleanup. The Android Media3/FFmpeg decoder is still required for IPTV playback; it is independent of the removed media-server integration.


### Category visibility and optional standings

Category snapshots are immutable and shared until the owning catalogue changes. Library notifications invalidate Movies/Series snapshots without invalidating Live TV or restarting its matching. Group Management saves selections as they change and keeps Done visible; the remote Right key reaches Done from any category row. Movies and Series metadata loads only when their management tab is opened, without downloading titles.

Visibility uses `hidden_groups_by_type` in the existing playlist/viewer namespace. Until a scoped edit, all types inherit the legacy hidden groups. The first edit stores all three scopes together so identically named Live TV, Movies and Series categories remain independent after restart. Serialized writes preserve rapid changes and failed writes retain the last saved state.

Standings is an on-demand Sports tab inside the event pane; league management and sports favourites use bounded overlays. Team membership uses a set; saved IDs and ordering retain their existing format. Names are remembered from already-loaded games or explicitly opened tables. Add team remains above the favourites list. The standings service is created on demand, has no polling/startup hooks, limits concurrent requests to two and cached leagues to 16, and parses bounded responses off the UI isolate. Successful results expire after 30 minutes; failures use a short retry delay and preserve any saved table. Requests time out and abort after 12 seconds.

Missing tables can try one explicitly labelled previous season, then offer an alphabetical team directory. International rugby tests offer teams directly. Never manufacture national NCAA standings from independent conferences, infer positions from alphabetical order, or present a previous season as current. Provider availability differs by league and season.

The inline standings pane shares the existing preview and player key. Event polling, matching batches and score callbacks pause outside Events; completed service requests may still populate shared caches. Returning presents retained events before resuming through the existing cache and matching queue. Completed score snapshots within the 30-second poll interval can be reused; interrupted, failed or older loads still refresh. Hidden event/standings trees are removed rather than laid out offstage; a bounded `SportsStandingsBrowseState` retains league, filters and scroll position. Standings supplies its selectors/actions to the same toolbar layout as Events, Replays and Highlights. The header and body share one preview-width calculation. Events keeps its controls in the top toolbar. A compact time button selects the existing four modes; the calendar icon selects a day. Phones and narrow/enlarged TV layouts combine time/channel choices in a single Filters panel, keeping sport and league selectors wide. Time filtering stays local, and channel confidence rules are unchanged. TV traversal orders tab, filter and action groups before comparing unscrolled positions so clipped tabs remain reachable. Standings league selection is scoped to the selected sport, without redundant sport and sort controls; favourites still supports all-sport discovery. Use pane constraints for responsive controls and pass keyboard visibility from the outer Scaffold so portrait search can compact the preview without replacing it. Overlays pause event work explicitly because dialog routes do not trigger the page-route observer.

Standings browsing uses sport, league and conference selectors with local search. Only confirming a different league loads data; cancelled selectors do not fetch. Keep per-league search/filter/scroll state bounded and preserve keyed row state when removing favourites. Small cached logos, portraits or flags come from the existing response, with initials when absent. The shared sports picker must retain search focus when an empty result becomes populated. Cover narrow phones, landscape keyboards, enlarged text and TV remote input in `sports_teams_screen_test.dart` and `sports_presentation_test.dart`.

Sports channel picker order is presentation-only. Before a manual choice, enrichment may improve ranking. After a choice, reuse the viewed order and change the selected/playing badges; a newly searched channel is placed beside the original suggestion. The shared matcher retains only channel IDs for 24 recently viewed fixtures, at most 6,000 IDs total and 15 minutes of inactivity. Reconcile against current rows so removed/rejected channels and stale confidence cannot be resurrected. Catalogue/fixture changes start a new order. See `sports_picker_consistency_test.dart`.

The Watch on channel browser filters the loaded candidate set locally. Suggested order stays separate from channel-name, country/region and playlist ordering. Country parsing is conservative: conflicting or absent channel/category labels remain unspecified. Saved picks do not count as event-specific or likely evidence. Metadata parsing and stable merge sorting yield in short slices, with generations cancelling obsolete work. Default browsing bypasses this work. Keep visible rows reconciled to current evidence during updates, restore row identity after filters/search, start at the top after an explicit sort change, and keep search input distinct from its pending results. Filter preferences are scoped to 24 events for the current Sports screen; they do not alter saved matches or issue guide/provider requests. `sports_channel_browser_test.dart` covers filtering, cancellation, session bounds and phone/TV controls.

Standings headers and rows share explicit rank, crest, statistic and favourite-action widths. Do not infer trailing space from Material ListTile defaults: tap-target sizing can shift the row columns without shifting headings. Row focus decorates a stable child; alternating backgrounds and separators do not add scrolling listeners or rebuild statistics. Geometry tests cover rugby, racing and college records across TV, phone and enlarged text.

Schedule only loads while its tab is opened. The Sports host supplies the current supported league, or an enabled league, so the first visit has fixtures without a selection step. Remembered choices take precedence. One most recent window is retained for two minutes for immediate returns; an incomplete window retries. An unselected standalone pane makes no requests. One selected league uses shared score-service HTTP limits and off-isolate parsing. ESPN monthly boards are bounded to 12 cached snapshots with ten-minute freshness; regional providers reuse their daily/monthly/season keys. Exact local date boundaries filter and deduplicate fixtures, with adjacent provider dates included across timezone boundaries. Leaving cancels future queued window work; an in-flight response may complete into cache. Failures preserve available cached fixtures with an incomplete-data message and never modify Events error state. Schedule browsing never runs channel matching or starts playback.

Optional regional providers (`NPB`, `KBO`, `ABL`, `B.League`) declare `enabledByDefault: false`; both default and legacy “all” preferences preserve the previous startup workload, while explicit selections remain enabled. Standings reads [NPB](https://npb.jp/bis/eng/2026/stats/), [KBO](https://eng.koreabaseball.com/Standings/TeamStandings.aspx), [ABL’s MLB feed](https://statsapi.mlb.com/api/v1/standings?leagueId=595&season=2025&standingsTypes=regularSeason&hydrate=team) and [B.League](https://www.bleague.jp/en/standings-stats/). NPB monthly fixtures, KBO and B.League daily fixtures, and ABL season fixtures share the score service cache and parser queue. Public responses are bounded to 2 MiB, with explicit provider timezones and stable club identifiers. Changed markup or unknown identities fail rather than guessing. ABL uses the labelled previous completed table when preseason has no current standings. No per-team logo/metadata fan-out is required.

Sports dialogs use `showSportsDialog`, retaining guarded origin/close behavior
and phone transitions while removing the 150 ms Material route transition on TV.
Wide choice dialogs align with the content side. League pickers memoize sorted
options, filter locally through labelled Sport/Order controls, and keep result
rows lazy. League management search never changes the enabled set; toggles save
in place and clearing a query retains those selections. Nested standings uses
the same selectors, search and table controls as the inline pane.

Sports filter and record popups share `SportsCompactDialog` and `SportsOptionButton`: bounded width/height, stationary title/actions, scrollable content, 34 px TV controls and 40 px compact-phone / 48 px regular touch targets (growing with text scaling). Channel filter edits remain drafts until Show channels; closing cancels, and Reset all only closes its current route. Schedule suppresses provider timezone strings beside local kickoff times, keeps exceptional statuses, and uses compact striped date-grouped rows.

Compact Sports density applies to portrait phones and short landscape viewports. Shared control sizing, day tiles, search insets and table geometry retain text-scale floors. Team details show the identity once in the header and use only supplied records and the existing sport-specific standings profile for summary metrics. Detail links adapt to pane width and text size; no new requests or animations are introduced.

`CompactChoiceList` retains lazy rows and stable focus identities. Its optional
content builder defers schedule time formatting and row construction to mounted
rows; keep that content outside focus repaint builders. Filtering and updated
snapshots still replace the content, including score visibility and clock format.
 Page/Channel keys move by the current viewport, Home/End jump directly, and opt-in TV footers expose the same actions for lists over 30 results. Right moves from a result to page controls; Up returns to the remembered result. Restored or manually scrolled offsets determine paging when the old focused row is no longer visible. Standings Left returns from a team row to search while favourite stars retain their own directional behavior. Navigation tests exercise 5,000 grouped rows, bounded focus nodes, rapid paging, filtering and restored offsets.

Sports details reuse the instant Sports panel, preserving preview ownership and browsing state. Schedule fixtures, standings team rows and the channel picker information action open details explicitly; hidden scores require a reveal before requesting game details. One ESPN summary or team response supplies available comparisons, lineups and rosters. Numeric provider identities and game competitors must agree. Responses are capped at 2 MiB, parsed off the UI isolate, limited to two concurrent requests and cached in 24 bounded entries. No player, logo, linked-resource or background polling fan-out is added. Pregame comparisons are season data and are labelled accordingly. Regional feeds retain their known overview and optional exact-ID team fixtures without sending regional identifiers to ESPN. The team fixtures action explicitly loads the next 30 days through the existing schedule service; no team schedule is loaded while simply browsing standings. Detail rows remain lazy with shared header/cell widths, and full row values are available through a compact popup.

Schedule calendar summaries retain only sport counts for at most 62 dates. All-sports Day remains a single requested date; opening Week/Month does not prefetch dates. Load week visits at most seven dates sequentially through the existing two-worker day loader, reuses fresh summaries and cancels queued work on navigation or disposal. Month shows known counts, with unloaded/partial dates distinguished from confirmed empty dates. Single-league calendars use the existing bounded range loader with real month boundaries. Day ordering and sport grouping are local and retain the same fixture identities and score-hiding behavior.


Sports favourites resolve legacy ID-only entries one league at a time while the
favourites pane is open, preserving saved order and the last browsed league.
If a current table lacks a saved club, one cached ESPN directory request can
recover its identity without assigning a rank. Directory requests share the
standings service limits and total cache bound; explicit retry bypasses the
short failure cooldown.
Sports entry points open favourites in the content-side overlay, preserving the
preview. Its list uses explicit detail activation, so scrolling does not start
team-detail requests. Standalone wide layouts still support a detail column;
there, remote focus waits 250 ms and keeps only the latest selection behind one
active request. Responses reuse the bounded detail cache,
and extra fixtures remain an explicit action. Team records appear directly in
the summary. No favourite metadata or details are requested at app startup.

Playlist refresh confirmation starts with Cancel focused and has no TV route
animation; phone transitions keep their existing behavior. The launching tile
stays focusable until confirmation; held activation is guarded. A per-playlist
refresh restricts the existing catalogue sync to that enabled playlist, while
M3U refresh retains its normal single-list load. The progress route removes only
itself on completion or error.

Favourite selection and detail completion use local listenables: neither should
rebuild the search controls or refilter the saved list. Rows retain their text,
logos and actions across focus/selection paints, with distinct focus and selected
indicators. Keep the list lazy with a short off-screen cache; enlarged text may
increase row height. Tests cover rapid remote scrolling while a request is pending,
retained scroll position, removal/undo and closing before completion.

Refresh actions own their focus nodes. After a blocking catalogue update completes
or fails, restore the originating action only while its route is still current;
non-blocking M3U refresh must not steal focus from continued browsing.

Sports overlays use the hub's preview-width calculation to centre within the
landscape content column. They use transparent modal barriers: preview brightness
is preserved while input remains in the active popup. Portrait and constrained
viewports stay centred across the available width. Keep the wrapper tree stable
across rotation so search and selection survive. Keyboard insets reduce height
without changing portrait alignment.

The shared Sports toolbar retains its element and focus tree across tab changes;
its horizontal scroll position persists. Payloads still unmount when hidden.
TV Schedule uses a small lookahead beyond the viewport. Its browse state
caches one text/date index and one filtered projection, invalidated by fixture
identity, timezone, scope, search, ordering and favourite revision. League lookup
is direct, with no catalogue scan for the all-sports overview. Keep touch list
prefetching unchanged and verify remote paging at virtual boundaries.
Grouped choice lists supply their indexed total height to the sliver delegate;
an estimated average can otherwise clamp a last-result jump before its target.

Schedule owns a local horizontal control path: the header enters Day, Down enters
dates/results, and Up from dates returns to the last attached local control.
Standings exits its first row through Search, then League, without replaying the
directional history of the left tab strip. Test these paths with real key events.
League management filters its cached catalogue by sport, saved state and text.
Bulk edits apply only to the visible IDs and retain at least one enabled league;
writes are guarded, failures restore the prior selection, and Close waits for
save finalisation. Long lists share bounded row focus and indexed page shortcuts.

Events and Schedule offer local favourites-only filters; Standings preserves its
existing ranked favourites view. These never enable hidden leagues or initiate
new feeds. Schedule retains its filter while switching tabs; calendar totals
remain all-team counts and say so when drilling into a favourite-filtered day.
Membership uses league-scoped IDs and a weak per-game cache invalidated after
saved membership/identity changes. Supplied field-sport entry lists include
athletes outside the displayed leaders. Racing additionally requires the saved
name to agree with the supplied athlete name, since driver and constructor IDs
can overlap. Missing participant data never implies an athlete is entered.

Schedule completed-game visibility is local to its retained browse state and defaults
to hidden. Only provider-confirmed finals are removed; postponed, cancelled, delayed
and suspended fixtures remain visible. Chronological lists include a non-focusable
current-time marker, with one mounted-view minute timer and no polling. Showing
completed fixtures reveals the first live fixture or the next start around now.
Grouped lists retain their sport grouping and have no time marker. Multi-day league
lists highlight the visible/focused row's date without changing the actual date
filter or loading another window; all-sports Day still loads one date on request.
Pending fixture updates appear in the top control row and preserve the first visible
fixture identity when applied. The shared indexed list includes marker heights in
its scroll extent and reports active-row changes without rebuilding the fixture list.

Events retains one ranked base projection and one favourites subset. Changes to the
feed, match evidence, filter scope, time bucket or favourites revision invalidate the
base; toggling favourites alone does not sort again. Card-key index maps belong to
the same immutable section snapshot. Keep the existing matching and active-browse
order safeguards; presentation caches must never change channel confidence.

Match overviews display already-supplied scoreboard leaders and live situation data,
including possession and last play. These add no service calls and remain behind
score-reveal protection. Provider coverage varies; omitted data stays omitted.

Long Schedule date strips use indexed horizontal layout and bounded label metrics.
Arrow keys reveal unmounted dates before focusing them; selection changes scroll the
date into view without taking focus from the fixtures. Keep enlarged text, both list
ends and rapid reversals covered in `sports_schedule_days_test.dart`.
TV event and replay shelves limit overscan on both axes. Standings and Sports pickers
also retain a short lookahead. Do not apply the TV limits to touch scrolling. Test
several sports at once: a single populated shelf cannot expose the multiplied cost
of vertical and horizontal prefetch. Preserve exact geometry and deferred focus when
crossing an unbuilt row or card.
