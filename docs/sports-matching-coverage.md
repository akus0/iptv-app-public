# Sports matching coverage audit

Recorded 6 November 2026. This audit covers the complete catalogue of **232 leagues**,
including 138 team competitions, rather than only the default enabled leagues.

## Scope and evidence

- Queried all ESPN-backed team directories: 127 returned 7,092 team records. Three
  returned empty team lists; the synthetic `rugby.live` path returned 404. Other
  sources and non-team sports are explicitly marked below, not counted as passed.
- Constructed 3,537 paired fixtures from those identities, each with full-name,
  short-name and wrong-opponent guide variants. These are synthetic fixture tests
  using real public team identities, not 3,537 observed broadcasts.
- Existing Asian/native-language, college, tennis, motorsport, guide-retrieval,
  worker and cache regression tests remain separate from this directory sweep.
- On an ARM32 Android TV, captured the actual playlist's 19,101 channels, 29,202
  current/next guide rows and 724 events from the 152 scoreboard-capable leagues.
  The snapshot contains six live, 541 upcoming and 177 completed events. A missing
  current/next guide match for a future event is not evidence of a matcher bug.
- Snapshot IDs are anonymised and stream/account URLs are omitted. Private captures
  remain outside the repository. No extra directory requests run in the app.

## Directory comparison

The directory baseline is the previous alias pass; the TV baseline is the original
matcher from the current private revision, before the alias work. These comparisons
have different baselines and should not be combined into one improvement percentage.

| Check | Previous directory pass | Revised matcher |
|---|---:|---:|
| Full-name fixtures recognised | 3,292 | 3,530 |
| Short-name fixtures recognised | 3,273 | 3,523 |
| Wrong-opponent flags requiring review | 43 | 9 |

No previously recognised full-name or short-name fixture was lost in this sweep.
Remaining full-name misses are seven fixtures pairing duplicate identities or TBD
placeholders. Short-name misses additionally include indistinguishable city names,
missing age qualifiers and numeric labels. Do not accept these just to raise recall.
Nine wrong-opponent flags remain: several duplicate/indistinguishable source records,
plus ambiguous college short names (Charlotte, Troy and Columbia) and Louisville KY.
These need reliable identity evidence before further expansion; a directory name alone
cannot distinguish two clubs called Alianza FC. This is not a claim of perfect accuracy.

## Confirmed fixes

- ALM/ALW competition labels, with men/women conflict guards. The TV snapshot now
  matches **ALM: Sydney FC v Mariners** to Sydney FC vs Central Coast Mariners on
  eight channel variants. Its game had finished but its guide window was still open.
  Other captured fixture results remained unchanged in the initial comparison.
- Joining apostrophes use the same normalisation in team and guide identities.
- Explicit three-letter team words such as Sky/Sun can match with competition and
  opponent evidence; arbitrary city/mascot guesses remain excluded.
- Top 14 is recognised as a competition, while replay/highlight/countdown exclusions
  remain in place. Softball is not rejected because ESPN nests it under baseball.
- A team abbreviation inside its opponent's name cannot establish both participants.
  More named college campuses and distinct soccer clubs reject prefix collisions.
- A sport word inside an exact full club name, such as Rugby Borough, does not
  reclassify the fixture. Conflicting sport labels outside that identity still reject.
- Full-name candidates cannot poison the cached vocabulary used by later short names.
  Translated competition labels use the same vocabulary as the guide.

## TV measurements

Three fresh worker runs per version, with the same snapshot and fixed clock, and no
remote input during the quiet measurements:

| Measurement (median) | Original matcher | Revised matcher |
|---|---:|---:|
| Channel index | 2.159 s | 2.102 s |
| Match all 724 captured events | 7.909 s | 7.751 s |
| Cached repeat of all 724 events | 28.735 ms | 28.759 ms |
| Guide queries per cold run | 1 | 1 |
| Events with exact name/guide evidence | 8 | 9 |
| Process RSS after run | 285.5 MiB | 281.2 MiB |

All three runs returned the same results within each version. The only changed event
was Sydney FC vs Central Coast Mariners: eight exact guide choices replaced eight
generic sport suggestions. No other event's ranked suggestions changed. The small
speed/RSS differences are within normal device variability, not a claimed speedup.
One revised cached sample reached 46.7 ms; the other two were 27.9–28.8 ms.

The frozen-data benchmark runs matching in a worker isolate with in-memory guide
retrieval. It measures matcher work, not live network/SQLite load time or playback.
These are deliberately all-catalogue timings, not the Events tab's visible first-batch
latency. A CPU sample showed the matching DartWorker at one core's capacity while the
raster thread used about 3%; database work remained on Sqflite workers. Process RSS
includes the app and caches, so it cannot isolate the cost of the new aliases.

The remote workload activates all five Sports tabs in a fixed varied sequence of 48
transitions using Left/Right and OK. Standings/Schedule retained the saved Racing /
MotoGP scope; this is not a stress test of every populated standings table. Each
version was exercised while background work
was active and again after the diagnostic worker finished. Timing samples describe
rendered frames, not input-to-display latency; live feed completion means the exact
frame counts differ. In the final quiet repeat, baseline/revised runs rendered 368/395 frames. Frames
with build time above 16.7 ms were 78/77; raster frames above that threshold were
16/18. The worst two-second batch build p95 was 92.9/70.5 ms, and raster p95 was
31.8/24.0 ms. These runs show no obvious navigation regression, but neither proves
sub-100 ms input latency or eliminates the existing long frames. Earlier stress
runs with overlapping background work were noisier (revised worst batch build p95
86.4 ms and raster p95 65.6 ms); keep those results when assessing real-world load.

Validation: 360 matching/cache/alias tests, 67 non-team/retrieval/batch tests and the
full-directory diagnostic passed (428 total). Three optional external-data tests
were skipped. Focused static analysis reported no issues. The Android release build
completed with the existing plugin migration warning. Final TV installation uses the
normal entry point, with the diagnostic capture/benchmark omitted.

## Reproduction

```sh
dart run tools/sports_league_inventory.dart > /tmp/sports-inventory.json
python3 tools/audit_sports_team_directories.py /tmp/sports-inventory.json /tmp/sports-directories
flutter test test/sports_team_directory_audit_test.dart \
  --dart-define=SPORTS_TEAM_DIRECTORY_FILE=/tmp/sports-directories/summary.json \
  --dart-define=SPORTS_TEAM_DIRECTORY_REPORT=/tmp/sports-directory-results.json
```

Directory captures use ESPN's public `/apis/site/v2/sports/{sport}/{league}/teams`
endpoint with bounded concurrency and timeouts. Reuse a capture for before/after
comparisons; use a fresh output directory to inspect new source data. Verification
sources for the reviewed aliases include the [A-Leagues club directory](https://aleagues.com.au/a-league-clubs/),
[NPB clubs](https://npb.jp/eng/teams/), [Top 14 clubs](https://top14.lnr.fr/clubs) and
[WNBA teams](https://www.wnba.com/teams).

## Follow-up: complete-name spelling variants

A second pass used the same 7,092 captured team identities and added 112 synthetic
guide variants containing dotted initials, United/Utd or Saint/St. Full words and
opponents stay intact; leading United in country names is excluded. The comparison
is against the preceding revised matcher, not the original matcher above.

| Check | Previous pass | This pass |
|---|---:|---:|
| Variant guide titles recognised | 90 / 112 | 112 / 112 |
| Original full-name fixtures recognised | 3,530 / 3,537 | 3,530 / 3,537 |
| Original short-name fixtures recognised | 3,523 / 3,537 | 3,523 / 3,537 |
| Wrong-opponent flags | 9 | 9 |

The 22 newly recognised variant fixtures span 16 competitions. These are diagnostic
broadcast spellings generated from public team identities, not 22 newly verified live
broadcasts. The nine remaining identity ambiguities from the first audit are unchanged.

Dotted initials are compacted only inside a complete multiword name: D.C. United /
DC United, N.C. State / NC State and Manta F.C. / Manta FC. Bare initialisms are not
invented, and FC does not become SC. Soccer United/Utd and Saint/St variants use
competition and explicit-opponent evidence, preserving women's, youth, replay and
wrong-opponent checks. No broad city, mascot or fuzzy spelling expansion was added.

The captured guide also used both Crvena Zvezda and Red Star Belgrade. The
[club's own site](https://www.crvenazvezdafk.com/en) confirms those full identities.
Tests cover both directions in three UEFA competitions, the captured title format,
and exclusion of Red Star FC 93, bare Red Star, other sports and different squads.
No time checks were relaxed to make an expired listing count as a live match.

### TV confirmation

Seven separate offline fixtures were checked on the TV with 35 controlled guide
listings. The prior matcher accepted the seven original spellings; the new matcher
accepted both spellings for all seven fixtures (14 correct guide choices). All 21
wrong-opponent, replay and wrong-sport controls stayed excluded in all three runs.
These controlled fixtures were kept separate from the real playlist snapshot.

A 48-transition remote walk across the five Sports tabs completed on the updated
build while the app loaded its ordinary sports feeds. Of 421 rendered frames, 88
builds and 18 raster frames exceeded 16.7 ms. Worst two-second batch p95 was 86.2 ms
build / 25.6 ms raster. This checks navigation under this workload; it does not claim
instant transitions or a new rendering improvement. No playback was started.

A second A/B comparison reused the same real 19,101 channels, 29,202 current/next
guide rows and 724 events. All ranked results remained identical across versions
and all three runs: the snapshot contains no additional eligible current broadcast
for these newly supported spellings. Median matcher time was **7.772 s before /
7.767 s after**, with **one guide query** each. Cached repeat was 26.984 / 27.881 ms;
channel indexing was 2.124 / 2.164 s. These small differences are normal device
variation, not evidence of a speedup. Process RSS after matching was approximately
288.4 / 276.1 MiB, but includes unrelated app caches and GC timing.

Local validation: 391 matching, cache, alias and title-retrieval checks, one additional
FC/SC suffix regression and the complete-directory audit passed (393 checks total).
One optional external-data check was skipped. Focused static analysis found no issues.
The normal release APK was rebuilt separately so diagnostic capture does not run in
ordinary use. The matching decision version changes; channel-text cache format,
provider requests, database schema and playback behaviour remain unchanged.

## Follow-up: college campus identities

Six verified school identities now recognise UC / California campus spellings:
Davis, Irvine, Riverside, San Diego, Santa Barbara and UCLA / Los Angeles. These
are exact college-only aliases, not a global UC/Cal/California substitution. Added
campus suffix checks also prevent California Golden Bears from matching another
campus. No provider/directory requests or UI work are added. Matching decisions use
a new semantics version; channel-text caches remain reusable.

The same complete-directory sweep includes 33 synthetic expanded-campus guide
variants, using captured public team identities. Recognition increased from **3/33
to 33/33** across nine NCAA competitions (football, men's/women's soccer, basketball
and volleyball, baseball and softball). All original full-name, short-name and 112
previous spelling checks retained their results. The nine previously documented
wrong-opponent directory flags remain unchanged; this does not resolve ambiguous or
duplicate source records.

The real frozen TV comparison again used 19,101 channels, 29,202 guide rows and 724
events, with three fresh matching workers per version. **All ranked results were
identical**: this particular current/next guide capture does not add eligible
broadcasts for the new campus variants.

| Median measurement | Before | After |
|---|---:|---:|
| Channel indexing | 2.091 s | 2.018 s |
| Match all captured events | 7.737 s | 7.606 s |
| Cached repeat | 31.288 ms | 27.052 ms |
| Guide queries | 1 | 1 |
| Whole-process RSS after matching | 284.4 MiB | 290.2 MiB |

Timing differences are ordinary device variation, not a claimed speedup. RSS
includes app startup, guide caches and GC; it does not isolate the small alias map.
The benchmark uses an in-memory guide in a worker, not network/SQLite or end-to-end
cold startup. No provider streams were started.

Seven controlled TV fixtures with 37 guide listings were tested separately. Across
all three runs, correct guide choices increased from **8 to 19**, and incorrect
cross-campus choices decreased from **8 to 0**. The old California prefix could fill
its eight ranked slots with other campuses, displacing its own correct listing.
The revised matcher retains every expected choice and rejects wrong opponents,
replays and wrong sports. These are controlled examples, not extra matches observed
in the real guide. The normal APK was restored after testing, without diagnostic
capture or autoplay overrides.

Local validation: 400 matching/cache/title tests, an additional cross-sport/gender
campus regression and the full-directory audit passed (402 checks total). One
optional external-data test was skipped. Focused static analysis reported no issues.

## Follow-up: missing live guide coverage

A fresh TV capture contained 19,101 channels, 29,171 current/next guide rows and
724 score-feed events. The previous discovery path found 29 guide cards. Review
identified live tennis rounds/multi-court coverage, golf rounds and a localised
skating session that were not recognised. A golf score event marked completed could
already have correct channel matches while live guide coverage remained hidden.

Discovery now opts into explicit tennis/golf session evidence, with live status and
existing programme-window, replay, studio and placeholder checks. It creates labelled
guide coverage with exact channel bindings, not inferred player matchups. Individual
tennis matching and scoreboard state are unchanged. Named skating sessions can use
an explicit skating genre tag when their title is localised. The earlier snapshot
recovered that skating broadcast; it had ended before the fresh capture.

On the fresh capture, guide cards increased **29 to 48**, retaining every old card.
The 19 additional cards contain 21 distinct guide-slot bindings across tennis and golf;
these are coverage listings, not 19 distinct score-backed matches. Different courts,
rounds and insufficiently identified feeds remain separate. Every one of the 48 cards
had an exact guide-channel choice without additional queries. All 724 existing ranked
fixture results remained identical across both versions and every device run.

A first implementation increased median guide-discovery time from 6.704 to 7.048 s.
Moving the existing unconditional empty-numbered-PPV exclusion ahead of classification
removed wasted work; 7,618 rows in the full capture had this shape. The final three-run
ARM32 TV comparison used the same frozen data and clock, in worker isolates:

| Median measurement | Before | Final |
|---|---:|---:|
| Guide discovery | 6.704 s | 5.061 s |
| Cached discovery | 31 µs | 28 µs |
| Match 724 score-feed events | 7.770 s | 7.719 s |
| Channel indexing | 2.184 s | 1.992 s |
| Guide queries | 1 | 1 |
| Additional guide-binding queries | — | 0 |
| Whole-process RSS after audit | 294.7 MiB | 279.0 MiB |

Discovery was about 25% faster under this workload while returning more coverage.
These timings exclude live network and SQLite latency and do not measure first-card
latency. Cached score-fixture repeats were variable: 27–30 ms before and 27–58 ms
in the final runs (median 53 ms); the fixture-cache path itself is unchanged. RSS
includes app caches, diagnostic allocations and GC, so it is not an isolated memory
saving. No blanket claim of faster rendering or uniformly faster cached operations
is made.

Validation: 401 matching tests, 150 discovery/tennis/replay/coverage tests and the
optional full-snapshot binding audit passed (552 checks); seven unrelated external
fixtures were skipped. Static analysis passed. Remote navigation confirmed the new
golf cards and their channel labels in Events; the All sports filter was restored.
Regression cases include recordings
with stale live flags, studio shows, ambiguous sports, expired slots, empty PPV
labels, progressive publication and corrected guide descriptions. The normal APK
replaces the diagnostic build after device checks; no provider streams are opened.

## Follow-up: basketball competition coverage

The remaining-guide review found a live Tauihi broadcast whose title and synopsis
agreed, but whose competition was absent from the classification vocabulary. Tauihi
now has an explicit basketball guide identity. Explicit EuroLeague Women and EuroCup
Women labels also retain separate competition IDs instead of falling into the generic
EuroLeague / EuroCup labels. A title's competition wins over another league mentioned
in the synopsis. Synopsis-only basketball detection now rejects conflicting sport
labels, just like title-based detection.

These three catalogue entries are guide-only. They reuse the existing live evidence,
programme windows, channel bindings and league visibility preferences; they do not
request scores, schedules or team directories. The original 232-entry directory audit
above predates these additions. Official sources are the [Tauihi league](https://tauihi.basketball/)
and [FIBA competition directory](https://about.fiba.basketball/en/regions/europe/competitions/clubs).

The frozen real TV guide increased from **48 to 49 coverage cards**, recovering
Tauihi: Kahu v Pouakai with one exact guide-channel binding. Every previous card and
all 724 ranked fixture results were unchanged across three runs per version. All 49
cards had exact guide bindings, with no additional guide queries. The women's league
routing is covered by controlled tests, not claimed as an extra observed broadcast
in this capture. Other reviewed listings with conflicting opponents were not used
to broaden discovery.

| Median TV measurement | Before | After |
|---|---:|---:|
| Guide discovery | 5.062 s | 5.143 s |
| Cached discovery | 38 µs | 34 µs |
| Match 724 score-feed events | 7.770 s | 7.774 s |
| Channel indexing | 2.102 s | 2.122 s |
| Cached fixture repeat | 28.595 ms | 43.548 ms |
| Guide queries | 1 | 1 |
| Whole-process RSS after audit | 287.2 MiB | 284.9 MiB |

Discovery samples ranged 4.996–5.174 s before and 5.049–5.271 s after. This small
change is within the observed run variation; no speedup is claimed. Cached fixture
repeats remain variable (28–53 ms before; 33–56 ms after), and process RSS includes
app caches and GC. These worker measurements exclude network/SQLite and first-frame
latency. Existing individual tennis matching is unchanged.

Validation: 401 matching tests, 170 discovery/tennis/replay/coverage/picker/favourites
tests and the full-snapshot binding audit passed (572 checks); seven optional
external-data checks were skipped. Static analysis passed. Tests include hidden-league
preferences, no new scoreboard/schedule requests, title/synopsis precedence, spelling
variants, conflicting sports, recordings and empty numbered slots. Normal APK
installation replaces the diagnostic build after testing; no provider stream is played.

## Follow-up: explicitly identified Test cricket

A fresh TV capture contained five live-marked Afghanistan v Zimbabwe Test cricket
listings that discovery excluded under its blanket cricket guard. Discovery now
accepts only explicitly identified international Test fixtures with cricket context,
named opponents and consistent title/synopsis evidence. Generic cricket, unknown
opponents, reviews, replays, conflicting sports and expired/empty advertised slots
remain excluded. Rugby discovery and individual tennis matching are unchanged.
The national-name vocabulary uses the [ICC full members](https://www.icc-cricket.com/about/members/full-members).
This guide-only competition adds no scoreboard, schedule or team-directory requests.

The fresh snapshot contains 19,101 channels, 29,172 current/next guide rows and 724
score-feed events. Coverage increased from **50 to 54 cards**, representing the same
Test fixture across five guide listings; two identical listings combine. These are
broadcast coverage cards, not four new fixtures or independently verified live video.
All 50 previous cards and every ranked fixture result remained identical across
three runs per version. All 54 cards had exact channel bindings with zero additional
guide queries, and warm discovery reused its cached result.

| Median TV measurement | Before | After |
|---|---:|---:|
| Guide discovery | 5.071 s | 5.033 s |
| Cached discovery | 29 µs | 29 µs |
| Match 724 score-feed events | 7.872 s | 7.667 s |
| Channel indexing | 2.200 s | 2.099 s |
| Cached fixture repeat | 29.570 ms | 27.304 ms |
| Guide queries | 1 | 1 |
| Whole-process RSS after audit | 294.9 MiB | 289.0 MiB |

No measurable slowdown appeared in this sample; no speedup or memory saving is
claimed. Discovery ranged 5.066–5.080 seconds before and 5.021–5.210 seconds after.
These are worker measurements on a frozen snapshot, excluding network/SQLite and
first-frame latency; process RSS includes unrelated caches and GC.

Validation passed 575 distinct checks across matching, guide discovery, tennis,
replays, publication, coverage, pickers, favourites and the private snapshot audit;
seven optional external-data checks were skipped. Direct and worker tests cover
exact channel binding, cache reuse, hidden-league preferences, absent score/schedule
requests, misleading live reviews, missing/unknown/conflicting opponents and
expired listings. Focused static analysis and formatting checks passed. TV testing
disabled autoplay; the normal APK replaces the diagnostic build afterward.

## Follow-up: regional European club spellings

The saved guide contains regional names including FC Bayern Monachium and
Internazionale. Added a contextual dictionary for Bayern Munich/München/Muenchen/
Monachium, Internazionale/Inter Milan and FC Cologne/1. FC Köln. The dictionary
requires an exact known team identity, named competition and explicit opponent
pair. Bare city/club fragments, reserve suffixes, wrong opponents, conflicting
sports, youth/women mismatches, prose mentions and replays remain excluded for
these new spellings. Sources are linked in the development notes. No global
translation expressions or runtime directory requests were added.

Eight controlled spelling cases failed before the change and pass afterward,
including reverse naming directions and domestic/European competitions. Both
direct and background-worker paths pass the same positive and negative cases.
These are controlled fixtures using observed naming formats, not eight newly
verified broadcasts. The unchanged real capture retains all **724 score-fixture
results and 54 guide cards**, with exact bindings and zero additional guide queries.
It does not contain a current score fixture for these three clubs, so no extra
real-capture match is claimed. Tennis and discovery rules are unchanged.

Off-device benchmark: 20,000 channels, 5,000 guide rows and 27 fixtures, including
the affected clubs. Six measured runs followed one warm-up run per version.

| Median measurement | Before | After |
|---|---:|---:|
| Channel indexing | 144.436 ms | 140.669 ms |
| Fixture matching | 24.971 ms | 24.669 ms |
| Cached repeat | 0.214 ms | 0.229 ms |
| Guide queries | 1 | 1 |

Matching samples overlapped (21.577–26.465 ms before; 22.017–27.492 ms after).
No material slowdown appeared in this local sample; these are not TV measurements
or evidence of a speedup. Validation passed 509 checks, with three optional
external-data checks skipped. Static analysis and formatting passed. No device
connection, installation or playback occurred during this pass.

## Follow-up: Sambo coverage and a college guide abbreviation

The remaining-guide review identified two explicitly named Sambo World Championship
broadcasts absent from the sport catalogue. `guide.sambo` now participates in the
sport/league picker and guide visibility preferences, using exact programme-channel
bindings. Discovery requires a named competition in the title and live evidence;
generic mentions, conflicting sports, training, reviews, documentaries, recordings,
expired slots and empty numbered advertisements remain excluded. It adds no score,
schedule or team-directory requests. FIAS identity sources are in the development
notes; guide metadata is not used to invent athlete fixtures or live scores.

The frozen capture increased from **54 to 56 coverage cards**. Both new cards are
correctly labelled **Starting soon · guide** at the captured time, rather than being
presented as already live. All 54 prior cards and every ranked result for the 724
score-feed fixtures remained identical across three comparisons. All 56 cards have
exact guide bindings, zero additional guide queries and cached discovery reuse.

The captured college listing uses `N'Western St` against Mississippi State. Exact
college aliases now recognise this and its joined spelling, retaining the State
qualifier. Direct and worker tests reject Northwestern University, wrong opponents,
other sports, women's-division conflicts and replays. This is a controlled matching
improvement using an observed format; no additional current score-fixture match is
claimed in the frozen capture, and stale listings are not reclassified as live.

| Median local snapshot measurement | Before | After |
|---|---:|---:|
| Channel indexing | 326.011 ms | 323.446 ms |
| Fixture matching | 1,143.032 ms | 1,150.733 ms |
| Cached fixture repeat | 12.190 ms | 11.384 ms |
| Guide discovery | 701.562 ms | 735.155 ms |
| Cached discovery | 0.304 ms | 0.377 ms |

Discovery ranged 635–749 ms before and 653–749 ms after. A separate alternating,
warmed classification check over all 29,172 rows measured medians of 1,164 ms before
and 1,128 ms after across seven trials per version, also with overlapping ranges.
The samples do not show a clear regression or establish a speedup. These are
off-device measurements, not TV startup or first-frame timings.

Validation passed 427 distinct checks, including guide discovery, exact bindings,
college identities, tennis, replays, progressive publication, caches, sport/league
pickers and favourites. Seven optional external-data checks were skipped. Focused
static analysis and formatting passed. No TV connection, installation or playback
occurred during this pass.

## Follow-up: duplicate F1 and ONE guide coverage

Local validation on 7 November 2026; no TV connection, install or playback.

- Motorsports grouping now folds Latin accents in venue names and recognises
  explicit practice numbers across FP1, P1, First Practice and Practice One.
  Separate practices, sprint qualifying, sprint, qualifying, races and series
  remain separate. Scored-session attachment retains its exact session checks.
- ONE Friday Fights grouping recognises the provider's `2026: OFF 177` season/card
  form and the `ONE Championship: Friday Fights` label. Only a season matching
  the slot's year and a synopsis date matching the exact UTC airing day are
  redundant. Other dates, numbered cards, phases and named bouts remain distinct.
- Provider `LIVE EVENT N - [time]` prefixes no longer split otherwise identical
  coverage, and are omitted from compact card titles. Original programme titles
  and every exact channel alternative are preserved.
- Direct and worker tests combine six synthetic broadcasts into two cards with
  all six confident channel alternatives, identical cached coverage and no SQL
  lookups. Additional grouping tests cover input reversal, removing simulcasts,
  score attachment and false-merge boundaries.
- Replayed the saved 19,101-channel / 29,172-row snapshot three times before and
  after: all 724 score-event match lists and the complete guide-evidence set are
  unchanged; all 56 guide cards bind, warm discovery is reused and exact bindings
  issue zero queries. This older snapshot does not contain the current F1 session;
  the new duplicate cases above are synthetic regressions, not a live-TV claim.
- Snapshot median discovery: 667.859 → 676.016 ms; cached discovery:
  0.358 → 0.311 ms. Overall match medians varied 1066.554 → 1131.731 ms with
  unchanged match results and scorer code. These desktop debug samples do not
  establish a device-wide speed improvement.
- Alternating before/after grouping benchmark: 1,440 synthetic F1/ONE broadcasts,
  seven measured samples after two warm-ups. The same evidence produces 600 → 120
  cards; median cold grouping 49.003 → 42.890 ms and warm grouping
  2.154 → 1.205 ms. Existing weak identity caches and bucketed grouping remain.

## Follow-up: category footers, coverage subtitles and cricket layouts

Validated on 7 November 2026 with a fresh TV capture, autoplay disabled and no
stream playback. The ARM32 diagnostic compared the same frozen 19,101-channel /
29,204-programme snapshot and all 901 score-feed events before and after.

- Recognised trailing XMLTV genre labels and an exact airing-day metadata stamp
  no longer split otherwise identical guide broadcasts. Historical dates, bare
  years and unknown parenthesised details remain significant.
- A short first synopsis line with a stage/number can carry the exact subtitle
  another source puts in its title. No words are inferred or discarded; the
  merged card prefers an existing informative title over a generic show heading.
- Named golf tournaments normalise explicit ordinal rounds, while retaining
  featured-group, hole and session distinctions. Test cricket uses the same
  validated national opponents as discovery plus an unambiguous Test number/day.
- The fresh TV capture goes from **42 to 40 cards**, combining the duplicate
  tennis coverage show and a World Poker Tour listing. Every original guide slot
  remains, all 40 cards have exact channel bindings, and all 901 fixture match
  lists are identical across all three runs. No extra binding queries were made.
- Replaying the earlier 29,172-row / 724-fixture snapshot goes from **56 to 52
  cards**: golf round, Test cricket and the tennis coverage show. Every guide slot
  and all fixture matches are unchanged. Remaining different courts, programme
  windows, recorded dates and insufficiently identified broadcasts stay separate.
- TV median complete discovery: 7,677.116 → 7,511.252 ms; cached discovery:
  0.032 → 0.028 ms. Full fixture matching: 9,856.853 → 9,436.697 ms. The unchanged
  901-event cached scorer varied 33.149 → 63.120 ms; these few device samples do
  not establish an overall speed improvement. Median post-run process RSS:
  318,545,920 → 303,595,520 bytes, also subject to GC/startup variation.
- 135 focused local tests pass, including direct/worker exact bindings, retained
  channel alternatives, cache reuse, progressive publication, fixed-slot expiry,
  and negative cases for dates, rounds, courts, opponents and malformed Test
  numbers. Changed-file static analysis is clean. The TV Sports view was checked
  with an empty preview; its normal build is restored after diagnostic testing.

## Every catalogue entry

“Other adapter” means the directory test does not exercise that source. “No team
directory” is expected for racing, golf, tennis, fights and guide-derived competitions.
Scoreboard counts are the returned records for the captured date, not a completeness
rating; empty responses can mean no scheduled games or unavailable source coverage.
Full/short columns count recognised synthetic fixtures, with the denominator shown.

| League | Kind / source | Directory | Full / short | Captured events |
|---|---|---|---|---:|
| NHL (`nhl`) | team / ESPN | 32 team records | 16/16 · 16/16 | 3 |
| NFL (`nfl`) | team / ESPN | 32 team records | 16/16 · 16/16 | 0 |
| NBA (`nba`) | team / ESPN | 30 team records | 15/15 · 15/15 | 9 |
| MLB (`mlb`) | team / ESPN | 30 team records | 15/15 · 15/15 | 0 |
| College Football (`college-football`) | team / ESPN | 762 team records | 381/381 · 381/381 | 5 |
| WNBA (`wnba`) | team / ESPN | 15 team records | 7/7 · 7/7 | 0 |
| MLS (`usa.1`) | team / ESPN | 30 team records | 15/15 · 15/15 | 0 |
| Premier League (`eng.1`) | team / ESPN | 20 team records | 10/10 · 10/10 | 1 |
| Champions League (`uefa.champions`) | team / ESPN | 36 team records | 18/18 · 18/18 | 0 |
| LaLiga (`esp.1`) | team / ESPN | 20 team records | 10/10 · 10/10 | 1 |
| Bundesliga (`ger.1`) | team / ESPN | 18 team records | 9/9 · 9/9 | 1 |
| Serie A (`ita.1`) | team / ESPN | 20 team records | 10/10 · 10/10 | 1 |
| Ligue 1 (`fra.1`) | team / ESPN | 18 team records | 9/9 · 9/9 | 1 |
| EuroLeague on TV (`guide.euroleague`) | broadcast / Channel guide | No team directory | Not exercised | Not queried |
| EuroCup basketball on TV (`guide.eurocup`) | broadcast / Channel guide | No team directory | Not exercised | Not queried |
| American Hockey League on TV (`guide.ahl`) | broadcast / Channel guide | No team directory | Not exercised | Not queried |
| AFL Women’s on TV (`guide.aflw`) | broadcast / Channel guide | No team directory | Not exercised | Not queried |
| Polish Ekstraklasa on TV (`guide.ekstraklasa`) | broadcast / Channel guide | No team directory | Not exercised | Not queried |
| WWE on TV (`guide.wwe`) | broadcast / Channel guide | No team directory | Not exercised | Not queried |
| All Elite Wrestling on TV (`guide.aew`) | broadcast / Channel guide | No team directory | Not exercised | Not queried |
| TNA Wrestling on TV (`guide.tna`) | broadcast / Channel guide | No team directory | Not exercised | Not queried |
| Sport climbing on TV (`guide.climbing`) | broadcast / Channel guide | No team directory | Not exercised | Not queried |
| Gymnastics on TV (`guide.gymnastics`) | broadcast / Channel guide | No team directory | Not exercised | Not queried |
| Cyclocross on TV (`guide.cyclocross`) | broadcast / Channel guide | No team directory | Not exercised | Not queried |
| Motorsport · live TV coverage (`guide.racing`) | broadcast / Channel guide | No team directory | Not exercised | Not queried |
| MMA events (`guide.mma`) | broadcast / Channel guide | No team directory | Not exercised | Not queried |
| ONE Championship (`guide.one`) | broadcast / Channel guide | No team directory | Not exercised | Not queried |
| Muay Thai & kickboxing (`guide.muay-thai`) | broadcast / Channel guide | No team directory | Not exercised | Not queried |
| Boxing (`guide.boxing`) | broadcast / Channel guide | No team directory | Not exercised | Not queried |
| Poker (`guide.poker`) | broadcast / Channel guide | No team directory | Not exercised | Not queried |
| NPB · Japanese baseball (`guide.npb`) | broadcast / Channel guide | No team directory | Not exercised | Not queried |
| KBO · Korean baseball (`guide.kbo`) | broadcast / Channel guide | No team directory | Not exercised | Not queried |
| CPBL · Taiwanese baseball (`guide.cpbl`) | broadcast / Channel guide | No team directory | Not exercised | Not queried |
| Darts on TV (`guide.darts`) | broadcast / Channel guide | No team directory | Not exercised | Not queried |
| Esports on TV (`guide.esports`) | broadcast / Channel guide | No team directory | Not exercised | Not queried |
| Action sports on TV (`guide.action-sports`) | broadcast / Channel guide | No team directory | Not exercised | Not queried |
| Snooker & pool on TV (`guide.billiards`) | broadcast / Channel guide | No team directory | Not exercised | Not queried |
| Bowling on TV (`guide.bowling`) | broadcast / Channel guide | No team directory | Not exercised | Not queried |
| Badminton on TV (`guide.badminton`) | broadcast / Channel guide | No team directory | Not exercised | Not queried |
| Table tennis on TV (`guide.table-tennis`) | broadcast / Channel guide | No team directory | Not exercised | Not queried |
| Asian baseball on TV (`guide.baseball`) | broadcast / Channel guide | No team directory | Not exercised | Not queried |
| Netball on TV (`guide.netball`) | broadcast / Channel guide | No team directory | Not exercised | Not queried |
| Handball on TV (`guide.handball`) | broadcast / Channel guide | No team directory | Not exercised | Not queried |
| Squash on TV (`guide.squash`) | broadcast / Channel guide | No team directory | Not exercised | Not queried |
| Padel on TV (`guide.padel`) | broadcast / Channel guide | No team directory | Not exercised | Not queried |
| Pickleball on TV (`guide.pickleball`) | broadcast / Channel guide | No team directory | Not exercised | Not queried |
| Taekwondo on TV (`guide.taekwondo`) | broadcast / Channel guide | No team directory | Not exercised | Not queried |
| Sailing on TV (`guide.sailing`) | broadcast / Channel guide | No team directory | Not exercised | Not queried |
| Triathlon on TV (`guide.triathlon`) | broadcast / Channel guide | No team directory | Not exercised | Not queried |
| Cycling on TV (`guide.cycling`) | broadcast / Channel guide | No team directory | Not exercised | Not queried |
| Field hockey on TV (`guide.field-hockey`) | broadcast / Channel guide | No team directory | Not exercised | Not queried |
| Sumo on TV (`guide.sumo`) | broadcast / Channel guide | No team directory | Not exercised | Not queried |
| Ice skating on TV (`guide.skating`) | broadcast / Channel guide | No team directory | Not exercised | Not queried |
| Skiing on TV (`guide.skiing`) | broadcast / Channel guide | No team directory | Not exercised | Not queried |
| FIBA 3×3 basketball on TV (`guide.basketball`) | broadcast / Channel guide | No team directory | Not exercised | Not queried |
| Rugby · live matches (`rugby.live`) | team / ESPN | http-404 | Not exercised | Not queried |
| Supercars Championship (`racing.supercars`) | racing / RaceTV Guide | No team directory | Not exercised | Not queried |
| MotoGP (`racing.motogp`) | racing / RaceTV Guide | No team directory | Not exercised | Not queried |
| Moto2 (`racing.moto2`) | racing / RaceTV Guide | No team directory | Not exercised | Not queried |
| Moto3 (`racing.moto3`) | racing / RaceTV Guide | No team directory | Not exercised | Not queried |
| World Endurance Championship (`racing.wec`) | racing / RaceTV Guide | No team directory | Not exercised | Not queried |
| IMSA SportsCar Championship (`racing.imsa`) | racing / RaceTV Guide | No team directory | Not exercised | Not queried |
| World Superbike (`racing.worldsbk`) | racing / RaceTV Guide | No team directory | Not exercised | Not queried |
| Formula E (`racing.formula-e`) | racing / RaceTV Guide | No team directory | Not exercised | Not queried |
| GT World Challenge Europe (`racing.gtwc`) | racing / RaceTV Guide | No team directory | Not exercised | Not queried |
| NASCAR O’Reilly Auto Parts Series (`racing.nascar-xfinity`) | racing / ESPN | No team directory | Not exercised | 0 |
| NASCAR Truck Series (`racing.nascar-trucks`) | racing / ESPN | No team directory | Not exercised | 1 |
| Formula 2 (`racing.f2`) | racing / RaceTV Guide | No team directory | Not exercised | Not queried |
| Formula 3 (`racing.f3`) | racing / RaceTV Guide | No team directory | Not exercised | Not queried |
| F1 Academy (`racing.f1-academy`) | racing / RaceTV Guide | No team directory | Not exercised | Not queried |
| Intercontinental GT Challenge (`racing.igtc`) | racing / RaceTV Guide | No team directory | Not exercised | Not queried |
| European Le Mans Series (`racing.elms`) | racing / RaceTV Guide | No team directory | Not exercised | Not queried |
| GT World Challenge America (`racing.gtwc-america`) | racing / RaceTV Guide | No team directory | Not exercised | Not queried |
| GT World Challenge Asia (`racing.gtwc-asia`) | racing / RaceTV Guide | No team directory | Not exercised | Not queried |
| GT World Challenge Australia (`racing.gtwc-australia`) | racing / RaceTV Guide | No team directory | Not exercised | Not queried |
| Super GT (`racing.super-gt`) | racing / RaceTV Guide | No team directory | Not exercised | Not queried |
| DTM (`racing.dtm`) | racing / RaceTV Guide | No team directory | Not exercised | Not queried |
| World Rally Championship (`racing.wrc`) | racing / RaceTV Guide | No team directory | Not exercised | Not queried |
| European Rally Championship (`racing.erc`) | racing / RaceTV Guide | No team directory | Not exercised | Not queried |
| Super Formula (`racing.super-formula`) | racing / RaceTV Guide | No team directory | Not exercised | Not queried |
| Indy NXT (`racing.indy-nxt`) | racing / RaceTV Guide | No team directory | Not exercised | Not queried |
| World Supersport (`racing.worldssp`) | racing / RaceTV Guide | No team directory | Not exercised | Not queried |
| British Superbike Championship (`racing.bsb`) | racing / RaceTV Guide | No team directory | Not exercised | Not queried |
| NHRA Drag Racing (`racing.nhra`) | racing / RaceTV Guide | No team directory | Not exercised | Not queried |
| Porsche Carrera Cup North America (`racing.porsche-carrera-cup-na`) | racing / RaceTV Guide | No team directory | Not exercised | Not queried |
| TCR World Tour (`racing.tcr-world-tour`) | racing / RaceTV Guide | No team directory | Not exercised | Not queried |
| Asian / Winter Le Mans Series (`racing.asian-le-mans`) | racing / TheSportsDB | No team directory | Not exercised | Not queried |
| Michelin Le Mans Cup (`racing.le-mans-cup`) | racing / TheSportsDB | No team directory | Not exercised | Not queried |
| 24H Series (`racing.24h-series`) | racing / TheSportsDB | No team directory | Not exercised | Not queried |
| Nürburgring Endurance Series (`racing.nls`) | racing / TheSportsDB | No team directory | Not exercised | Not queried |
| Super Taikyu (`racing.super-taikyu`) | racing / TheSportsDB | No team directory | Not exercised | Not queried |
| International GT Open (`racing.gt-open`) | racing / TheSportsDB | No team directory | Not exercised | Not queried |
| British GT Championship (`racing.british-gt`) | racing / TheSportsDB | No team directory | Not exercised | Not queried |
| FIM Endurance World Championship (`racing.ewc`) | racing / TheSportsDB | No team directory | Not exercised | Not queried |
| IMSA Michelin Pilot Challenge (`racing.imsa-pilot`) | racing / TheSportsDB | No team directory | Not exercised | Not queried |
| Six Nations (`rugby.180659`) | team / ESPN | 6 team records | 3/3 · 3/3 | 0 |
| The Rugby Championship (`rugby.244293`) | team / ESPN | 4 team records | 2/2 · 2/2 | 0 |
| European Rugby Champions Cup (`rugby.271937`) | team / ESPN | 24 team records | 12/12 · 12/12 | 0 |
| European Rugby Challenge Cup (`rugby.272073`) | team / ESPN | 18 team records | 9/9 · 9/9 | 0 |
| Gallagher Prem (`rugby.267979`) | team / ESPN | 10 team records | 5/5 · 5/5 | 0 |
| French Top 14 (`rugby.270559`) | team / ESPN | 14 team records | 7/7 · 7/7 | 0 |
| Nations Championship (`rugby.17567`) | team / ESPN | 12 team records | 6/6 · 6/6 | 1 |
| Super Rugby Pacific (`rugby.242041`) | team / ESPN | 12 team records | 6/6 · 6/6 | 0 |
| New Zealand NPC (`rugby.270563`) | team / ESPN | 14 team records | 7/7 · 7/7 | 0 |
| Women's Rugby World Cup (`rugby.289237`) | team / ESPN | 12 team records | 6/6 · 6/6 | 0 |
| Major League Rugby (`rugby.289262`) | team / ESPN | 12 team records | 6/6 · 6/6 | 0 |
| International Test Match (`rugby.289234`) | team / ESPN | 20 team records | 10/10 · 10/10 | 0 |
| British and Irish Lions Tour (`rugby.268565`) | team / ESPN | 9 team records | 4/4 · 4/4 | 0 |
| PGA Tour (`golf.pga`) | golf / ESPN | No team directory | Not exercised | 1 |
| LPGA Tour (`golf.lpga`) | golf / ESPN | No team directory | Not exercised | 1 |
| DP World Tour (`golf.eur`) | golf / ESPN | No team directory | Not exercised | 1 |
| LIV Golf (`golf.liv`) | golf / ESPN | No team directory | Not exercised | 0 |
| UFC (`mma.ufc`) | fight / ESPN | No team directory | Not exercised | 0 |
| PFL (`mma.pfl`) | fight / ESPN | No team directory | Not exercised | 0 |
| Formula 1 (`racing.f1`) | racing / ESPN | No team directory | Not exercised | 5 |
| NASCAR Cup Series (`racing.nascar-premier`) | racing / ESPN | No team directory | Not exercised | 0 |
| IndyCar (`racing.irl`) | racing / ESPN | No team directory | Not exercised | 0 |
| ATP Tour (`tennis.atp`) | tennis / ESPN | No team directory | Not exercised | 55 |
| WTA Tour (`tennis.wta`) | tennis / ESPN | No team directory | Not exercised | 124 |
| NCAA Men's Soccer (`usa.ncaa.m.1`) | team / ESPN | 273 team records | 136/136 · 136/136 | 20 |
| NCAA Women's Soccer (`usa.ncaa.w.1`) | team / ESPN | 420 team records | 210/210 · 210/210 | 8 |
| 2. Bundesliga (`ger.2`) | team / ESPN | 18 team records | 9/9 · 9/9 | 2 |
| EFL Championship (`eng.2`) | team / ESPN | 24 team records | 12/12 · 12/12 | 1 |
| EFL League One (`eng.3`) | team / ESPN | 24 team records | 12/12 · 12/12 | 0 |
| EFL League Two (`eng.4`) | team / ESPN | 24 team records | 12/12 · 12/12 | 0 |
| National League (`eng.5`) | team / ESPN | 24 team records | 12/12 · 12/12 | 0 |
| LALIGA 2 (`esp.2`) | team / ESPN | 22 team records | 11/11 · 11/11 | 1 |
| Serie B (`ita.2`) | team / ESPN | 20 team records | 10/10 · 10/10 | 1 |
| Ligue 2 (`fra.2`) | team / ESPN | 18 team records | 9/9 · 9/9 | 6 |
| Eredivisie (`ned.1`) | team / ESPN | 18 team records | 9/9 · 9/9 | 1 |
| Primeira Liga (`por.1`) | team / ESPN | 18 team records | 9/9 · 9/9 | 1 |
| Turkish Super Lig (`tur.1`) | team / ESPN | 18 team records | 9/9 · 9/9 | 1 |
| Scottish Premiership (`sco.1`) | team / ESPN | 12 team records | 6/6 · 6/6 | 0 |
| Belgian Pro League (`bel.1`) | team / ESPN | 18 team records | 9/9 · 9/9 | 1 |
| Austrian Bundesliga (`aut.1`) | team / ESPN | 12 team records | 6/6 · 6/6 | 1 |
| Greek Super League (`gre.1`) | team / ESPN | 14 team records | 7/7 · 7/7 | 0 |
| Russian Premier League (`rus.1`) | team / ESPN | 16 team records | 8/8 · 8/8 | 1 |
| Danish Superliga (`den.1`) | team / ESPN | 12 team records | 6/6 · 6/6 | 1 |
| Norwegian Eliteserien (`nor.1`) | team / ESPN | 16 team records | 8/8 · 8/8 | 0 |
| Swedish Allsvenskan (`swe.1`) | team / ESPN | 16 team records | 8/8 · 8/8 | 1 |
| Liga MX (`mex.1`) | team / ESPN | 18 team records | 9/9 · 9/9 | 3 |
| Liga Profesional (ARG) (`arg.1`) | team / ESPN | 30 team records | 15/15 · 15/15 | 6 |
| Brasileirão Série A (`bra.1`) | team / ESPN | 20 team records | 10/10 · 10/10 | 1 |
| J1 League (`jpn.1`) | team / ESPN | 20 team records | 10/10 · 10/10 | 1 |
| Chinese Super League (`chn.1`) | team / ESPN | 16 team records | 8/8 · 8/8 | 0 |
| A-League Men (`aus.1`) | team / ESPN | 12 team records | 6/6 · 6/6 | 2 |
| Indian Super League (`ind.1`) | team / ESPN | 13 team records | 6/6 · 6/6 | 1 |
| South African Premiership (`rsa.1`) | team / ESPN | 16 team records | 8/8 · 8/8 | 0 |
| UEFA Europa League (`uefa.europa`) | team / ESPN | 36 team records | 18/18 · 18/18 | 0 |
| UEFA Conference League (`uefa.europa.conf`) | team / ESPN | 36 team records | 18/18 · 18/18 | 0 |
| UEFA Champions League Qualifying (`uefa.champions_qual`) | team / ESPN | 52 team records | 26/26 · 26/26 | 0 |
| UEFA Super Cup (`uefa.super_cup`) | team / ESPN | 2 team records | 1/1 · 1/1 | 0 |
| UEFA EURO (`uefa.euro`) | team / ESPN | 24 team records | 12/12 · 12/12 | 0 |
| UEFA Nations League (`uefa.nations`) | team / ESPN | 54 team records | 27/27 · 27/27 | 0 |
| English FA Cup (`eng.fa`) | team / ESPN | 80 team records | 40/40 · 39/40 | 2 |
| Carabao Cup (`eng.league_cup`) | team / ESPN | 92 team records | 46/46 · 46/46 | 0 |
| DFB-Pokal (`ger.dfb_pokal`) | team / ESPN | 64 team records | 32/32 · 32/32 | 0 |
| Spanish Copa del Rey (`esp.copa_del_rey`) | team / ESPN | 122 team records | 61/61 · 61/61 | 0 |
| Coppa Italia (`ita.coppa_italia`) | team / ESPN | 46 team records | 23/23 · 23/23 | 0 |
| Spanish Supercopa (`esp.super_cup`) | team / ESPN | 4 team records | 2/2 · 2/2 | 0 |
| Italian Supercoppa (`ita.super_cup`) | team / ESPN | 2 team records | 1/1 · 1/1 | 0 |
| Coupe de France (`fra.coupe_de_france`) | team / ESPN | 181 team records | 90/90 · 90/90 | 1 |
| FIFA World Cup (`fifa.world`) | team / ESPN | 48 team records | 24/24 · 24/24 | 0 |
| FIFA Women's World Cup (`fifa.wwc`) | team / ESPN | 32 team records | 16/16 · 16/16 | 0 |
| World Cup Qualifying (Concacaf) (`fifa.worldq.concacaf`) | team / ESPN | 32 team records | 16/16 · 16/16 | 0 |
| AFC Champions League Elite (`afc.champions`) | team / ESPN | 32 team records | 16/16 · 16/16 | 0 |
| CAF Champions League (`caf.champions`) | team / ESPN | 61 team records | 30/30 · 30/30 | 0 |
| AFC Asian Cup (`afc.asian.cup`) | team / ESPN | 24 team records | 12/12 · 12/12 | 0 |
| Africa Cup of Nations (`caf.nations`) | team / ESPN | 24 team records | 12/12 · 12/12 | 0 |
| Concacaf Champions Cup (`concacaf.champions`) | team / ESPN | 27 team records | 13/13 · 13/13 | 0 |
| Concacaf Gold Cup (`concacaf.gold`) | team / ESPN | 16 team records | 8/8 · 8/8 | 0 |
| CONMEBOL Libertadores (`conmebol.libertadores`) | team / ESPN | 44 team records | 22/22 · 22/22 | 0 |
| U.S. Open Cup (`usa.open`) | team / ESPN | 80 team records | 40/40 · 38/40 | 0 |
| Women's Super League (`eng.w.1`) | team / ESPN | 14 team records | 7/7 · 7/7 | 0 |
| Liga F (`esp.w.1`) | team / ESPN | 16 team records | 8/8 · 8/8 | 0 |
| Première Ligue (women) (`fra.w.1`) | team / ESPN | 12 team records | 6/6 · 6/6 | 3 |
| NWSL (`usa.nwsl`) | team / ESPN | 16 team records | 8/8 · 8/8 | 1 |
| UEFA Women's Champions League (`uefa.wchampions`) | team / ESPN | 18 team records | 9/9 · 9/9 | 0 |
| NCAA Men's Basketball (`basketball.mens-college-basketball`) | team / ESPN | 362 team records | 181/181 · 181/181 | 72 |
| NCAA Women's Basketball (`basketball.womens-college-basketball`) | team / ESPN | 362 team records | 181/181 · 181/181 | 2 |
| NCAA Baseball (`baseball.college-baseball`) | team / ESPN | 437 team records | 216/218 · 216/218 | 0 |
| NCAA Men's Ice Hockey (`hockey.mens-college-hockey`) | team / ESPN | 116 team records | 57/58 · 57/58 | 27 |
| NCAA Women's Hockey (`hockey.womens-college-hockey`) | team / ESPN | 47 team records | 23/23 · 23/23 | 18 |
| AFL (`australian-football.afl`) | team / ESPN | 19 team records | 9/9 · 9/9 | 0 |
| United Rugby Championship (`rugby.270557`) | team / ESPN | 16 team records | 8/8 · 8/8 | 0 |
| Rugby World Cup (`rugby.164205`) | team / ESPN | 20 team records | 10/10 · 10/10 | 0 |
| NCAA Women's Volleyball (`volleyball.womens-college-volleyball`) | team / ESPN | 351 team records | 174/175 · 174/175 | 121 |
| National Basketball League (`basketball.nbl`) | team / ESPN | 10 team records | 5/5 · 5/5 | 1 |
| USL Championship (`usa.usl.1`) | team / ESPN | 25 team records | 12/12 · 12/12 | 0 |
| Saudi Pro League (`ksa.1`) | team / ESPN | 18 team records | 9/9 · 9/9 | 3 |
| KNVB Beker (`ned.cup`) | team / ESPN | 110 team records | 55/55 · 55/55 | 0 |
| Women's FA Cup (`eng.w.fa`) | team / ESPN | 97 team records | 48/48 · 46/48 | 0 |
| PGA Tour Champions (`golf.champions-tour`) | golf / ESPN | No team directory | Not exercised | 0 |
| NCAA Women's Field Hockey (`field-hockey.womens-college-field-hockey`) | team / ESPN | empty | Not exercised | 10 |
| AFC Champions League Two (`afc.cup`) | team / ESPN | 32 team records | 16/16 · 16/16 | 0 |
| K League 1 (`kor.1`) | team / K League | Other adapter | Not exercised | 22 |
| K League 2 (`kor.2`) | team / K League | Other adapter | Not exercised | 28 |
| Japan B.League (`basketball.bleague`) | team / B.League | Other adapter | Not exercised | 0 |
| Nippon Professional Baseball (`baseball.npb`) | team / NPB | Other adapter | Not exercised | 0 |
| KBO League (`baseball.kbo`) | team / KBO | Other adapter | Not exercised | 1 |
| Australian Baseball League (`baseball.abl`) | team / ABL | Other adapter | Not exercised | 78 |
| East Asia Super League (`basketball.easl`) | team / EASL | Other adapter | Not exercised | 36 |
| A-League Women (`aus.w.1`) | team / ESPN | 11 team records | 5/5 · 5/5 | 2 |
| Saudi King’s Cup (`ksa.kings.cup`) | team / ESPN | 32 team records | 16/16 · 16/16 | 0 |
| Indian I-League (`ind.2`) | team / ESPN | 11 team records | 5/5 · 5/5 | 2 |
| International friendlies (`fifa.friendly`) | team / ESPN | 198 team records | 99/99 · 99/99 | 0 |
| Women’s international friendlies (`fifa.friendly.w`) | team / ESPN | 73 team records | 36/36 · 36/36 | 0 |
| Scottish League Cup (`sco.cis`) | team / ESPN | 45 team records | 22/22 · 22/22 | 0 |
| Scottish Cup (`sco.tennents`) | team / ESPN | 90 team records | 45/45 · 45/45 | 0 |
| Concacaf Central American Cup (`concacaf.central.american.cup`) | team / ESPN | 20 team records | 10/10 · 10/10 | 0 |
| Scottish Championship (`sco.2`) | team / ESPN | 10 team records | 5/5 · 5/5 | 1 |
| USL Super League (`usa.w.usl.1`) | team / ESPN | 8 team records | 4/4 · 4/4 | 2 |
| FIFA Under-17 Women’s World Cup (`fifa.wworld.u17`) | team / ESPN | 24 team records | 12/12 · 12/12 | 0 |
| Liga MX Femenil (`mex.w.1`) | team / ESPN | 18 team records | 9/9 · 9/9 | 5 |
| Colombian Primera A (`col.1`) | team / ESPN | 20 team records | 10/10 · 10/10 | 2 |
| Peruvian Liga 1 (`per.1`) | team / ESPN | 18 team records | 9/9 · 9/9 | 1 |
| CONMEBOL Sudamericana (`conmebol.sudamericana`) | team / ESPN | 56 team records | 28/28 · 28/28 | 0 |
| EFL Trophy (`eng.trophy`) | team / ESPN | 64 team records | 32/32 · 31/32 | 0 |
| United Football League (`football.ufl`) | team / ESPN | 8 team records | 4/4 · 4/4 | 0 |
| NBA G League (`basketball.nba-development`) | team / ESPN | 34 team records | 17/17 · 16/17 | 10 |
| NCAA Softball (`baseball.college-softball`) | team / ESPN | 446 team records | 221/223 · 221/223 | 0 |
| NCAA Men’s Lacrosse (`lacrosse.mens-college-lacrosse`) | team / ESPN | empty | Not exercised | 0 |
| NCAA Women’s Lacrosse (`lacrosse.womens-college-lacrosse`) | team / ESPN | empty | Not exercised | 0 |
| NCAA Men’s Volleyball (`volleyball.mens-college-volleyball`) | team / ESPN | 83 team records | 40/41 · 40/41 | 0 |
| Korn Ferry Tour (`golf.ntw`) | golf / ESPN | No team directory | Not exercised | 0 |
| Uruguayan Primera División (`uru.1`) | team / ESPN | 16 team records | 8/8 · 8/8 | 0 |
| Chilean Primera División (`chi.1`) | team / ESPN | 16 team records | 8/8 · 8/8 | 0 |
| Ecuadorian LigaPro (`ecu.1`) | team / ESPN | 16 team records | 8/8 · 8/8 | 0 |
| Costa Rican Primera División (`crc.1`) | team / ESPN | 10 team records | 5/5 · 5/5 | 0 |
| Venezuelan Primera División (`ven.1`) | team / ESPN | 12 team records | 6/6 · 6/6 | 0 |
| Bolivian Primera División (`bol.1`) | team / ESPN | 16 team records | 8/8 · 8/8 | 1 |
| Paraguayan Primera División (`par.1`) | team / ESPN | 12 team records | 6/6 · 6/6 | 0 |

## Live guide audit — 7 November 2026

The diagnostic now captures Events' local-day and carryover request window rather
than a single literal scoreboard date. The earlier single-date snapshots miss some
US games playing on Australia's following day; their totals should not be treated
as current-live recall measurements. This is a diagnostic correction, not an app
feed-window change.

The corrected capture queried all 152 scoreboard-capable leagues and contained
19,101 channels, 6,395 current/next programme rows and 424 fixtures: 173 live,
95 upcoming and 156 finished. All live NBA (7), NHL (3) and college-football (3)
fixtures had exact guide evidence. Many other live fixtures were college sports
without matching programme evidence in this capture. That does not prove no channel
carries them, and generic shared school/mascot names must not be accepted as proof.

Changes retained:

- Six explicitly live OHL fixtures now appear as guide events, each bound to its
  actual programme channel. OHL has its own league filter; existing AHL coverage
  remains separate. No scoreboard/network requests were added. Competition names
  were checked against the [official OHL directory](https://chl.ca/ohl/ohl-team-directory/).
- The replay guard no longer rejects “Classic” inside an exact, feed-supplied golf
  tournament identity, such as the [TOTO Japan Classic](https://www.lpga.com/tournaments/toto-japan-classic/overview).
  Separate replay/highlight labels, earlier years and wrong rounds remain excluded.
  Round labels now understand numeric, ordinal and day formats. The captured
  round-three broadcasts start later than the snapshot; a clock-controlled test at
  their airing time returns eight exact choices. This is a simulation against guide
  metadata, not a playback verification. Before that boundary the current programme
  remains authoritative, so a later round is not presented as currently airing.
- The discovery fast gate scans ASCII tokens without allocating a regex match for
  each synopsis word. Native-script vocabulary and subsequent classification rules
  are unchanged. A private equivalence probe checked 86,496 captured and boundary
  inputs with zero differences. A larger combined-regex experiment was slower and
  was discarded.

Three fresh worker runs per version on ARM32 TV, frozen data and fixed clock:

| Measurement (median) | Before | Revised | Before repeated last |
|---|---:|---:|---:|
| Channel index | 2.213 s | 2.058 s | 2.089 s |
| Score all 424 fixtures | 3.213 s | 3.089 s | 3.111 s |
| Cached fixture repeat | 18.111 ms | 16.882 ms | 18.665 ms |
| Guide discovery | 3.060 s | 2.741 s | 3.016 s |
| Exact fixture matches | 46 | 46 | 46 |
| Discovered/bound guide events | 33 | 39 | 33 |
| Additional guide-binding queries | 0 | 0 | 0 |

Discovery improved by roughly 9–10%; fixture timing differences are small and should
be treated as normal variability. All three runs within each version produced
identical ranked results. All previous guide cards and bindings remained identical.
Of the 424 fixture result lists, 423 were unchanged; the LPGA list lost two generic
suggestions whose current guide explicitly named a previous year's golf coverage.
The existing 46 exact fixture matches were all retained. Every cold fixture run
made one title query; cached discovery reused its result without additional work.

CPU samples placed the matching load on Dart worker threads, with raster usage
around 2% during quiet matching. Process RSS medians varied from 237 to 255 MiB
across the runs; these are whole-process samples with different cache/GC histories,
not evidence of a memory reduction. The benchmark uses in-memory frozen guide
retrieval, so it is not a network/SQLite or input-to-screen latency measurement.

598 automated tests passed (four optional private-data tests skipped), including
wrong-opponent, college, Asian/native-language, tennis, replay, cache/progression,
round-conflict and discovery tests. Separate snapshot and projected-airing checks
passed. Two 90-input TV navigation runs and an additional 46-input mixed
sport/league/favourite-filter sequence reported no Flutter errors or playback.
The six OHL cards and their league filter were also checked visually and with the
remote. Some transitions still exceeded 100 ms; this pass does not claim to remove
all UI stalls. The initial navigation runs had different feed-cache warmness and
are not a controlled navigation speed comparison.


## Live-guide duplicate audit — 7 November 2026

A second frozen capture contained 19,101 channels and 6,395 current/next guide rows.
This comparison isolates guide discovery with no scoreboard fixtures. Three fresh
worker runs per version on the same ARM32 TV reduced discovered cards from 41 to
38: ONE Fight Night coverage combined from three cards to one, and the current
Supercars support coverage from two to one. All 44 original programme slots were
retained; the other 36 cards were unchanged. Results were identical across all
three runs within each version.

Median discovery time was 2.886 seconds before and 2.893 seconds after, effectively
unchanged within measurement noise. Cached discovery took about 0.03 milliseconds;
discovery and binding made no additional SQL/network queries. This is a frozen-data
worker measurement, not end-to-end cold-start latency or a claimed speed increase.

The ONE card and its alternative-channel menu were checked visually on TV with
remote navigation and playback disabled. Automated direct/worker tests retain all
18 channels even when the card shortlist is eight, including a saved selection.
Safety cases cover ambiguous card numbers, explicit bouts, partial broadcasts,
different race numbers, support series, support days and combined sessions.
The broader targeted suite passed 166 tests; the final stricter opponent-description
guard passed a further 95-test run and reproduced the same frozen guide results.

## Possible-match review — 7 November 2026

Reviewed a frozen capture of 424 fixtures against 19,101 channels and 6,438
current/next guide rows. Broad candidate searches included every unresolved
non-final fixture; individual broadcast and club-identity research covered college
basketball, football, soccer, hockey and volleyball, NASCAR, G League, NBL, J1 and
K League. A fresh, read-only provider catalogue download returned the same 19,101
channel names, including old dated event slots. Refreshing the catalogue did not
provide newer names. Do not reinterpret an old event slot as current coverage.

Verified examples and decisions:

| Fixture | Official evidence | Decision |
| --- | --- | --- |
| UConn–Michigan | [UConn preview](https://uconnhuskies.com/news/2026/11/5/mens-basketball-no-4-huskies-head-to-boston-for-title-game-rematch): TNT/truTV | Current generic college-basketball synopsis names both opponents; recover eight TNT variants through bounded synopsis matching. |
| Kansas State–CSUN | [K-State preview](https://www.kstatesports.com/news/2026/11/5/mens-basketball-k-state-continues-homestand-friday-night-vs-csun): ESPN+ | No current named provider slot; do not substitute ESPN. |
| Arizona State–Northern Colorado | [ASU preview](https://thesundevils.com/news/2026/11/05/asu-mens-basketball-hosts-northern-colorado): ESPN+ | Same streaming-versus-linear distinction. |
| Stanford–Oakland | [Stanford preview](https://gostanford.com/news/2026/11/4/homestand-continues-with-oakland): ACC Network Extra | Do not substitute the linear ACC channel. |
| Ole Miss–Central Arkansas | [Ole Miss preview](https://olemisssports.com/news/2026/11/4/mens-basketball-to-face-central-arkansas1): SECN+ | Do not substitute the linear SEC channel. |
| Wyoming–Idaho State | [Wyoming preview](https://gowyo.com/news/2026/11/4/mens-basketball-cowboys-host-idaho-state-in-dome-of-doom-on-friday): MW+ | No corroborating current guide fixture. |
| St. Thomas–Alaska Anchorage | [St. Thomas preview](https://tommiesports.com/news/2026/11/5/mens-hockey-home-sweet-home-mens-hockey-hosts-alaska-anchorage): NCHC.tv | Radio coverage is not television evidence. |
| North Dakota–Western Michigan | [UND preview](https://fightinghawks.com/news/2026/11/5/mens-hockey-notes-no-10-und-opens-nchc-play-at-home-against-no-5-western-michigan.aspx): Midco Sports/NCHC.tv | No corroborating current provider listing. |
| Air Force–Army hockey | [Air Force preview](https://goairforcefalcons.com/news/2026/11/3/mens-ice-hockey-falcons-host-no-19-army-nov-6-7): FloHockey; no television | Old dated Flo slots cannot confirm the current fixture. |
| Washington–Northwestern volleyball | [Washington preview](https://gohuskies.com/news/2026/11/5/volleyball-home-season-wraps-with-northwestern-1-nebraska): B1G+ | Do not substitute Big Ten Network. |
| Coachella Valley–Salt Lake City | [Official Lakers schedule](https://coachellavalley.gleague.nba.com/schedule): NBA App/Roku | No named current guide slot; do not substitute NBA TV. |
| Adelaide–Illawarra | [Official 36ers fixture](https://www.adelaide36ers.com/games/adelaide-36ers-v-illawarra-hawks-men-07-11-2026): ESPN on Disney | Fixture is upcoming; no matching current/next programme in this capture. |
| NASCAR Trucks at Miami | [NASCAR weekend schedule](https://www.nascar.com/news-media/2026/11/06/nascar-at-homestead-miami-key-info-links-results-for-championship-weekend/): FS1 | Retain replay/session guards: captured NASCAR guide candidates include old full-race replays and classics. |

Seven upcoming K League fixtures exposed nine missing full club identities:
Jeju SK, Anyang, Seongnam, Daegu, Suwon FC, Ansan Greeners, Gimhae FC2008,
Seoul E-Land and Jeonnam Dragons. Verified English/native identities use the
existing lazy league-scoped alias index for `kor.1`/`kor.2`; there are no new
requests or global native-name transformations. Sources include the
[official club directory](https://www.kleague.com/club/club.do?teamId=K04),
[Seongnam/Daegu club news](https://www.kleague.com/news_view.do?category=club&orderBy=seq&page=1&seq=96760&viewOption=album),
[Gimhae/Jeonnam club news](https://www.kleague.com/news_view.do?orderBy=seq&page=1&seq=95307&viewOption=album),
[Anyang](https://www.fc-anyang.com/), [Ansan](https://www.greenersfc.com/) and
[Seoul E-Land](https://www.seoulelandfc.com/index).
Before the change all seven native-fixture tests failed; afterwards both opponent
orders match in guide titles and named channels. Wrong opponents, the other
Suwon/Seoul clubs, women's/youth fixtures, other sports and replays remain excluded.
The private capture has no corresponding Korean guide coverage, so these are
verified compatibility improvements, not additional live confirmations on this
provider. J1's Tokyo Verdy historical name already has a usable API short name;
no redundant alias or broader matching rule was added.

Validation: 382 targeted tests passed, with one pre-existing optional test skipped;
the seven native-fixture cases were then strengthened to exercise named channels
as well as guide titles (all 15 Asian tests passed). Static analysis and repository
privacy checks were clean. Three final frozen TV runs preserved all other 423
fixture result lists and all 40 guide cards. Performance validation uses frozen data and excludes network/SQLite latency.
Initial alternating diagnostic timings were discarded after detecting separate
Dart library instances in the harness's toggle imports. The corrected harness
uses package imports and records both the active dictionary flag and the native
query-term count to verify that each comparison actually changes matching inputs.
All TV tests disabled
playback; the fresh catalogue probe did not save changes to playlist settings.

### Extended guide and Japanese basketball follow-up

A second TV capture at 03:50 UTC included 18,056 programme rows, using a diagnostic
title lookup extending 18 hours ahead. Its 424 fixtures contained 66 unresolved
non-final games across 22 competitions. The matcher already found 62 exact
name/guide fixtures with this larger input; this is broader diagnostic coverage,
not a claimed improvement from changing the matcher. Searches of unresolved
opponent pairs found no additional valid current fixture: the South Florida–East
Carolina guide slot had ended, and a later airing was not current coverage.
The capture contains no Japanese/Korean programme titles. Numbered Coupang Play
feeds exist, but lack fixture-specific names/guide data; assigning games to those
slots would be guesswork. Future tennis semi-final coverage likewise cannot
establish which individual match is currently on a shared channel.

The [official bilingual B.League directory](https://www.bleague.jp/en/club/)
provides 26 full English/Japanese club identities. These now use the existing
league-scoped alias index. All 26 native pair tests failed before the addition;
the new cases cover both opponent orders, Japanese `対`, named channels, guide
queries, wrong opponents, other sports, women and replay listings. A separate
worker test checks native identities across isolate transfer. The tests exposed
an existing senior/youth distinction missing for B.League; its explicit age
qualifiers now use the existing soccer age check, scoped to this competition.

The [official schedule](https://www.bleague.jp/en/schedule/?year=2026&mon=11&day=7)
also embeds per-game broadcast panels already downloaded by the scoreboard.
The parser now retains only panels explicitly labelled live and services marked
terrestrial, BS or CS television. Streaming products, recorded broadcasts,
unrelated game IDs, ambiguous duplicate panels and malformed optional markup
cannot supply TV evidence or prevent valid fixtures from loading. No additional
requests are made. The captured page lists five fixtures, with Tochigi TV, NHK(BS)
and J SPORTS 3 attached only to Utsunomiya–Ryukyu. Region checks recognise Japan's
JP/JPN tags; tests preserve NHK BS versus NHK/World and J Sports channel numbers.

The corrected six-run comparison alternates the Korean/Japanese identities and
B.League age guard together. Package-import identity is verified in each run:
the alias lookup toggles false/true, and native query terms change from 1 to 19.
All six runs preserve the original 424 fixture result lists and 36 guide cards,
including after enriching the five B.League games with their actual broadcast
metadata. This provider lacks the listed Japanese linear services; no substitute
NHK service is asserted to carry the game.

| Corrected ARM32 median | Rules disabled | Rules enabled |
| --- | ---: | ---: |
| Channel indexing | 2.070 s | 2.088 s |
| Cold fixture matching | 4.823 s | 4.875 s |
| Cached matching | 30.5 ms | 35.7 ms |
| Whole-process RSS after matching | 269.9 MiB | 271.1 MiB |
| Title queries / additional guide-binding queries | 1 / 0 | 1 / 0 |

Cold matching differs by about 1.1%; these small samples do not demonstrate a
material slowdown or a speedup. Cached-call timings vary, and the unchanged
cache path has no added per-channel matching work. On the same TV, parsing the
real five-game schedule took 29.1 ms without broadcast panels and 34.8 ms with
them: about 5.7 ms extra in the existing background parser, with no new request.
574 targeted tests passed, two optional private-data tests were skipped, and a
separate real-page parser test passed. Static analysis, source privacy checks,
APK inspection and signature verification were clean. The normal production APK
was restored on TV; diagnostic captures were removed and playback remained off.

### Possible-match review with calendar and broadcaster metadata

The 04:28 UTC capture on 7 November contains 440 scoreboard/calendar events,
19,101 visible channels and 17,760 current, next and extended-guide rows. This
includes optional calendar and broadcast metadata and counts all confident
match reasons, rather than only exact name/guide matches. Among non-final
fixtures, 31 have confident matches, 31 have only possible matches (12 live and
19 upcoming), and 22 have no candidates. The all-league diagnostic scope is
broader than an individual filtered Events view; manual channel picks are omitted.
Optional Sky tennis-channel enrichment was not configured in this capture.

All 31 possible events were reviewed against channel names, programme titles,
descriptions and available broadcaster metadata. The groups comprise five
women's tennis fixtures, fifteen soccer fixtures, eight basketball fixtures and
three motorsport sessions. Remaining limitations include:

- Hong Kong/Chennai tennis listings identify shared tournament blocks without
  naming the individual match. No specific Angola fixture is identified.
- NCAA streaming listings do not identify numbered provider feeds; ESPN+,
  ACCNX, MW+ and Summit League Network are not interchangeable with linear
  ESPN/ACC channels. Several provider event names still refer to earlier dates.
- [Portland's official preview](https://portlandpilots.com/story.aspx?file_date=11%2F5%2F2026&filename=mens-basketball-pilots-open-rainbow-classic-friday-versus-ut-arlington)
  explicitly says its UT Arlington game has no live video coverage.
  [Hawai‘i lists K5/MW+](https://hawaiiathletics.com/sports/mens-basketball/schedule)
  for Bethesda, but the captured playlist has no identified K5 service or
  corresponding fixture-specific guide slot. KHNL, KGMB and other Honolulu
  services are not substitutes for K5.
- The exact Salt Lake City–Coachella Valley title is a later Sportsnet LA airing,
  not coverage overlapping the live game. Portsmouth–Stoke appears only in
  off-air “Next Game” placeholder slots ending before kickoff.
- Other unresolved soccer listings lack both opponents or fixture-specific
  broadcast evidence; generic sport/league coverage cannot establish a match.
- WEC guide material does not identify the scheduled Monza practice.
  [Super GT's official Motegi listing](https://supergt.net/races/round8-motegi-2)
  identifies a 250 km race, while the available guide names a 300 km race.
  These remain unconfirmed.

One recoverable gap is the scheduled Qatar motorcycle session. The calendar
supplies “Qatar Grand Prix” and “Lusail International Circuit”; the guide uses
“MotoGP: Qatar Practice 3”. The
[official MotoGP timetable](https://www.motogp.com/en/news/2026/11/04/le-programme-du-gp-du-qatar/1183614)
confirms the venue and Saturday practice. Normalised Qatar/Lusail/Losail aliases
now require an explicit calendar venue identity and are scoped to MotoGP,
Moto2 and Moto3. The existing separate series-name group and session, replay,
programme-time and channel eligibility checks remain mandatory. Alias expansion
runs once per event in the existing cached name-group construction; it adds no
network requests, new channel scan, or UI work. Matching semantics version 20
invalidates prior result decisions while preserving channel-text caches.

The frozen ARM32 TV replay adds eight exact guide/channel entries across four
Qatar sessions (Moto3 practice, Moto2 practice, MotoGP practice and qualifying).
MotoGP practice moves from possible-only to confident; the other three sessions
already had a confident option and gain exact alternatives. All other 436 event
result lists, 31 generated guide cards and every guide classification are
unchanged. Three runs per build produce identical matching decisions.

| ARM32 median, three runs per build | Before | After |
| --- | ---: | ---: |
| Channel indexing | 2.201 s | 2.129 s |
| Cold matching, 440 events | 5.021 s | 5.005 s |
| Cached matching | 18.6 ms | 31.5 ms |
| Guide discovery | 3.115 s | 3.063 s |
| Whole-process RSS after matching | 279.7 MiB | 257.6 MiB |
| Title queries / additional guide-binding queries | 1 / 0 | 1 / 0 |

These are frozen metadata/worker timings, excluding network and SQLite latency.
They show no cold-matching slowdown; they do not establish a speed or memory
improvement. Cached calls vary from 17.7–35.8 ms, with a higher after-build median;
the venue expansion itself is retained in the existing event-name cache and does
not run again on cached calls. The small samples are insufficient to attribute
that variance to the change. There are no added requests or full-list scans.
428 focused matching, motorsport, worker/cache and alias tests pass, including
three new regression cases that failed before the change. Static analysis,
repository privacy checks and diff whitespace checks pass. Playback was blocked
throughout the TV diagnostic runs.

A follow-up six-run, single-build comparison alternates just the venue alias
expansion and records its actual enabled state. Each fresh worker performs twelve
additional warmed calls (36 per condition). Disabled runs reproduce every
before-build decision; enabled runs reproduce every after-build decision. Guide
cards and query counts also remain identical. The toggle exists only in the
external diagnostic checkout and is absent from production sources/APK.

| Alternating comparison | Aliases disabled | Aliases enabled |
| --- | ---: | ---: |
| Median cold matching | 4.921 s | 4.916 s |
| Median warmed matching, 36 calls | 18.15 ms | 18.49 ms |
| Median guide discovery | 3.091 s | 3.020 s |

The warmed difference is 0.34 ms, and the earlier 13 ms median difference is not
reproduced by this controlled comparison. These measurements do not indicate a
meaningful regression. The normal signed APK passed inspection and signature
verification, was restored to TV with its installed checksum verified, and was
left stopped. All 13 temporary device diagnostic files were removed.


### Whole-guide coverage review — 7 November 2026

The fresh 05:02 UTC TV capture contains 17,405 programme rows for 19,101 visible
channels. It includes every cached current/next programme, regardless of sport,
and an extended sports-title lookup. It is not a dump of every stored future day.
The earlier 440-fixture metadata snapshot is retained solely to compare matching
decisions on fixed inputs; fixtures were not refetched for this guide audit.
Playback is blocked at both the Dart service and native-player entry point.

Review covered explicit live labels, sports genres, named fixtures, competition
names and sports-channel context. The broad first-pass triage included 808 unique
current/soon slots, including news and entertainment negatives. Many apparently
missing standard-league broadcasts already have scoreboard events; others are
studio shows, highlights, rolling channel advertisements or unmarked recordings.
Four gaps have sufficient evidence for conservative guide-only coverage:

- Australian Championship soccer: an explicit competition, named opponents and
  soccer/club evidence. The [official Round 4 preview](https://australianchampionship.com.au/news/2026-australian-championship-round-4-preview)
  and [Marconi fixture page](https://www.clubmarconi.com.au/events/australian-championship/)
  corroborate Marconi–Bayswater. [Football West](https://footballwest.com.au/news/australian-championship-baysie-home-in-on-fast-start/)
  describes the Saturday SBS broadcasts.
- US high-school football: an explicit school-football title and named fixture,
  excluding score roundups and previews. Captured examples include Apple Valley–
  Villa Park and Waipahu–Aiea.
- Horse racing: explicit horse/thoroughbred coverage or a racing programme on a
  narrowly recognised horse-racing channel. Generic motor-racing channels do not
  supply that context. The [VRC calendar](https://www.vrc.com.au/tickets/?date=2026-11-07)
  corroborates Champions Stakes Day; betting-tip shows, auctions, films and
  replays remain excluded.
- Rodeo/bull riding: explicit programme or competitive-synopsis evidence, with
  live evidence required. The [Columbia River Circuit](https://columbiarivercircuit.com/)
  confirms the November 5–7 finals; its second performance appears in the guide.

All four use the existing guide snapshot, background classifier, cached discovery
and exact programme bindings. No new API, guide download, polling, full-playlist
scan during rendering, standings request or fuzzy channel-matching pass is added.
Known catalogue entries make them selectable in the existing sport/league UI.

The initial device pass found three duplicate layout pairs. Australian
Championship episode prefixes are retained as qualifiers while its fixture
heading is normalised across title/synopsis layouts. Football, horse-racing and
rodeo category footers are recognised. For already-admitted, explicitly live
broadcasts in those three guide categories only, a footer date consistent with
a local date in UTC−12 through UTC+14 is cosmetic grouping evidence. Dates in
titles/prose, older dates, different opponents/episodes, later slots and unmarked
recordings remain distinct. This never changes discovery eligibility, replay
checks, stored timestamps or programme-to-channel bindings.

Remaining gaps include limited-overs cricket (the existing guide fallback is
specifically international Tests) and some wrestling/bowling coverage without
live evidence. ODI/WBBL cannot simply reuse Test-match format/day identity rules.
No broad “sport mentioned” or “sports channel” fallback was enabled to fill those
gaps. Such a fallback would also surface the many studio and recorded programmes
observed in this capture.

Final device validation uses three baseline and three changed-build runs against
that same snapshot and clock, with a fresh worker per run. Guide discovery grows
from **32 to 43 cards**: seven horse-racing broadcasts, two school-football
fixtures, one Australian Championship fixture and one rodeo performance. Three
new duplicate pairs coalesce; every underlying programme/channel alternative is
retained. All 32 original cards and all 440 fixture match-result lists remain
identical in every run. Guide binding performs zero additional queries and warm
discovery reuses its cached result.

| Median on TV, three runs each | Before | After |
| --- | ---: | ---: |
| Guide discovery | 2.798 s | 2.695 s |
| Cached discovery | 34 µs | 34 µs |
| Fixture matching | 5.113 s | 4.625 s |
| Warm fixture matching | 18.53 ms | 19.08 ms |
| Process RSS after diagnostic run | 277.0 MiB | 252.6 MiB |

These separate-build observations show no material regression; the lower cold
measurements/RSS are not claimed as a causal speed or memory improvement. The
matching algorithm and worker lifecycle are unchanged. This is a frozen-input
classifier/matcher comparison, not an end-to-end launch or frame-latency benchmark.

Validation: 306 distinct related tests passed, with two optional private-fixture
tests skipped. Coverage includes foreground/background discovery, false-positive
and replay exclusions, exact channel bindings, duplicate separation, existing
matching, league presentation, and an 80,000-channel cached-discovery regression.
Targeted static analysis reports no issues and the whitespace check passes.

The normal 25.04 MiB ARM32 release APK passed package inspection and signature
verification. It was installed back on TV, its installed checksum was verified,
and the app was left stopped without playing a stream. All 11 temporary device
diagnostic files were removed. The source privacy scan checked 704 files with
zero findings. No repository push or public release was performed in this pass.


### Korean and Japanese baseball guide review — 7 November 2026

The read-only TV audit walked all 140,854 stored programme rows, not just the
sports search results or visible current/next slots. It examined titles and full
descriptions for baseball, regional competition names, native-script terms and
club names; it also retained every stored row for regional channel candidates.
The audit produced 617 candidate rows, including false positives, and 116 distinct
baseball-related programme titles. The enabled catalogue contains 19,101 channels.
No identifiable Samsung–KT or NPB broadcast was found. The Korean PPV/SPOTV
candidates have only expired channel-name placeholders, not current programme
listings. MLB/WBC archive games, studio coverage and unrelated entertainment do
not justify a confirmed KBO match. This cannot establish what an unlabelled stream
actually carries; playback was blocked throughout the investigation.

The existing [official KBO scoreboard](https://eng.koreabaseball.com/Schedule/Scoreboard.aspx?searchDate=2026-11-07)
contains Samsung Lions–KT Wiz at 05:00 UTC. The app already requests this feed.
The [NPB November league schedule](https://npb.jp/games/2026/schedule_11_detail.html)
has no November 7 fixture. NPB is already a supported selectable event source;
national-team exhibitions are separate from that league schedule.

A reproducible matching gap was found independently of today's missing guide:
complete Japanese/Korean baseball club names were absent from the native-language
vocabulary. Verified full identities for all 12 NPB and 10 KBO clubs now use the
existing translation fallback and bounded cache. Sources:
[NPB bilingual club directory](https://npb.jp/teams/),
[KBO Korean club directory](https://www.koreabaseball.com/Kbo/League/TeamInfo.aspx),
and [KBO English directory](https://eng.koreabaseball.com/Teams/TeamInformation.aspx).
Korean spaced/unspaced renderings retain every identifying word. Shared sponsors,
cities, mascots and ambiguous two-letter abbreviations are not promoted to global
identities. Short forms such as bare Samsung, KT, Hanshin or Giants retain the
existing contextual rules rather than bypassing them.

Senior NPB/KBO fixtures additionally reject explicit youth, farm/reserve and
Korean Futures qualifiers, including native script. Reserve teams can use the
same complete club names; see [NPB farm competition](https://www.npb.or.jp/campaign/2026/farm/)
and KBO's separately listed Futures competition. Other leagues' matching is
unchanged. There are no new runtime requests, guide scans, timers or UI work.
Matching semantics version 21 invalidates old decisions. Channel-text cache
version 3 drops old native-script derivations from versions 1/2 while retaining
unaffected ASCII/accented names and decorative flags, protecting startup reuse.


Validation: 474 matching, language, cache, discovery and regional-feed tests pass,
including two checks against the captured official public HTML responses. Native
pair tests cover all 22 clubs, spaced/unspaced Korean names, Japanese/Korean
connectors, mixed English/native names, wrong opponents/sports, replay/highlight
and stale-date exclusions, youth/reserve exclusions, and worker/cache reuse.
Targeted static analysis reports no issues.

The TV comparison retains 440 fixture models, 19,101 channels and 17,696 current
or extended guide rows at the same captured clock. All fixture result lists and
51 discovered guide cards remain identical in all baseline/updated runs. A
separate on-TV synthetic check recognizes all 11 native fixture pairs (22 clubs),
in both programme and channel-name evidence, while rejecting wrong opponents,
replays, farm/Futures and youth listings. The baseline recognizes none of those
native pairs. This is tested vocabulary coverage, not additional confirmed
broadcasts found in the user's current guide.

Initial one-call cached timings varied, so a follow-up uses three fresh workers
per build and twelve warmed calls per worker (36 per version):

| TV median | Before | After |
| --- | ---: | ---: |
| Channel index preparation | 2.115 s | 2.066 s |
| Cold fixture matching | 4.707 s | 4.469 s |
| Cached fixture matching, 36 calls | 19.10 ms | 18.30 ms |
| Guide discovery | 3.116 s | 3.081 s |
| Cached guide discovery | 30 µs | 31 µs |

Query counts stay unchanged (one shared guide search, zero extra guide-binding
queries). These frozen-input comparisons show no material slowdown; separate
build timings and allocator-dependent RSS do not establish a causal speed or
memory gain. No frame-latency or end-to-end cold-launch claim is made.

The normal signed ARM32 APK from this verification passed APK inspection and
signature verification and was restored to the TV.
Its installed checksum was verified and the app was left stopped. All 17
pass-specific device diagnostic files were removed. No subscription or test
stream was played. The source scan checked 705 files with zero findings; no
repository push or public release was performed.
