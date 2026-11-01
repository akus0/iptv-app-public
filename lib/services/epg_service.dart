import 'guide_programme_cache.dart';
import '../utils/epg_timeline.dart';
import '../utils/guide_enrichment.dart';
import '../utils/thai_epg.dart';
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../models/epg_program.dart';
import '../utils/constants.dart';
import 'epg_database.dart';
import 'xmltv_parser.dart';
import 'sports_match_inputs.dart';
import 'storage_service.dart';
import '../l10n/l10n.dart';

/// One playlist's EPG URL plus the channel ids it's allowed to populate
/// programmes for — see [EpgService.refresh]'s doc comment.
typedef EpgSource = ({String url, Set<String> knownChannelIds});

/// Normalize all guide identifiers before map lookup: feed ids, provider ids, manual
/// overrides and M3U tvg-id values may differ only in case.
String normalizeEpgId(String id) => id.trim().toLowerCase();

EpgProgram _toProgram(EpgRow r) => EpgProgram(
      channelId: r.channelId,
      title: r.title,
      description: r.description,
      isLive: r.isLive,
      start: DateTime.fromMillisecondsSinceEpoch(r.startMs),
      stop: DateTime.fromMillisecondsSinceEpoch(r.stopMs),
    );

Map<String, List<EpgProgram>> _toPrograms(Map<String, List<EpgRow>> rows) =>
    rows.map((id, list) => MapEntry(id, _untangle(list)));

/// One channel's rows as a clean timeline. Some providers' XMLTV lists two
/// programmes for the same time slot (RDS showed two
/// titles drawn on top of each other in the Timeline guide). By start
/// time, the earlier programme keeps its slot; a later one that starts
/// inside it is trimmed to begin when it ends, or dropped if it ends
/// inside it too.
List<EpgProgram> _untangle(List<EpgRow> rows) {
  final sorted = [...rows]..sort((a, b) => a.startMs.compareTo(b.startMs));
  final out = <EpgProgram>[];
  var lastStop = -1;
  for (final r in sorted) {
    if (r.stopMs <= lastStop) continue;
    final p = _toProgram(r);
    out.add(r.startMs < lastStop
        ? EpgProgram(
            channelId: p.channelId,
            title: p.title,
            description: p.description,
            isLive: p.isLive,
            start: DateTime.fromMillisecondsSinceEpoch(lastStop),
            stop: p.stop,
          )
        : p);
    lastStop = r.stopMs;
  }
  return out;
}

/// Fetches and parses XMLTV EPG data into [EpgDatabase], and serves it.
///
/// Programmes live on disk in [EpgDatabase] and are only ever *queried* —
/// the old design decoded one big JSON cache of every programme into memory
/// on each cold start (measured on a Formuler: 24.8 s for 167k programmes,
/// after the splash) and rewrote the whole file after every refresh (20 s,
/// and the step that ran Fire Sticks out of memory).
///
/// The getters stay synchronous so no caller had to change:
/// - [getCurrentProgram]/[getNextProgram] read [_soon] — every channel's
///   programmes for the next few hours, preloaded at startup in one query.
/// - [getPrograms] (the Timeline guide) returns a cached full window for a
///   channel, or queues a batched load for the channels being built and
///   returns the [_soon] slice meanwhile; [guideRowsLoaded] ticks when the
///   rows arrive.
/// - [hasPrograms] reads [_withData].
class EpgService extends ChangeNotifier implements SportsMatchGuide {
  EpgService(this._storage, {EpgDatabase? database})
      : _db = database ?? EpgDatabase();

  // Full timeline rows can load without changing matching evidence.
  int _currentGuideRevision = 0;
  int get currentGuideRevision => _currentGuideRevision;

  int _changeRevision = 0;
  @override
  int get changeRevision => _changeRevision;
  @override
  void notifyListeners() {
    if (_disposed) return;
    _changeRevision++;
    super.notifyListeners();
  }

  // Starting a download or clearing its error changes status, not guide
  // evidence. Do not discard in-flight sports matches before any data arrives.
  void _notifyStatus() {
    if (!_disposed) super.notifyListeners();
  }

  final StorageService _storage;
  final EpgDatabase _db;

  Future<void> warmSportsSearch({bool Function()? cancelled}) =>
      _db.warmSportsSearch(cancelled: cancelled);
  bool _disposed = false;

  /// How far ahead [_soon] reaches — comfortably past "next" for any
  /// channel, and reloaded every [_soonReloadEvery] so it never runs dry.
  static const _soonAhead = Duration(hours: 4);
  static const _soonReloadEvery = Duration(minutes: 15);

  static const _minFirstRefreshDelay = Duration(seconds: 30);

  Map<String, List<EpgProgram>> _soon = {};
  final _full = GuideProgrammeCache();
  Set<String> _withData = {};

  final Set<String> _pendingLoads = {};
  final Set<String> _inFlightLoads = {};
  bool _loadScheduled = false;
  bool _loadingRows = false;

  /// Bumped whenever the database changes under the caches, so a load that
  /// was in flight across a refresh doesn't put old rows back into [_full].
  int _cacheEpoch = 0;

  Timer? _soonTimer;
  Future<void>? _initFuture;

  /// Ticks when [getPrograms] rows finish loading — see [_loadPending].
  final ValueNotifier<int> guideRowsLoaded = ValueNotifier(0);
  Set<String>? lastLoadedGuideChannelIds;

  /// Every `<channel id>` -> its first `<display-name>` this session has
  /// seen, across every source refreshed so far — *not* scoped to any one
  /// playlist's [EpgSource.knownChannelIds] the way stored programmes are
  /// (see [refresh]'s doc comment): the whole point is letting "Assign
  /// EPG channel" browse the *feed's* full channel directory to search
  /// for a match, independent of which ids a given playlist happens to
  /// already own. Small either way (a few thousand short strings, not
  /// full programme data) so keeping every source's entries around at
  /// once costs nothing worth guarding. Rebuilt fresh each app launch
  /// (not stored in [EpgDatabase]) — "Update EPG Now" is right there in
  /// the same settings screen that would use this.
  final Map<String, String> _channelCatalog = {};
  Map<String, String> get channelCatalog => Map.unmodifiable(_channelCatalog);

  /// Current programmes for candidate guide ids, unfiltered by playlist membership, help
  /// distinguish similarly named entries in the manual matching picker.
  final Map<String, EpgProgram> _nowPlayingCatalog = {};
  EpgProgram? currentProgramInCatalog(String id) =>
      _nowPlayingCatalog[normalizeEpgId(id)];

  @override
  DateTime? lastUpdated;
  bool isLoading = false;
  String? error;

  Timer? _refreshTimer;

  /// Evaluated fresh on every auto-refresh tick (not a frozen snapshot
  /// taken once at `startAutoRefresh` time) — playlists can be
  /// added/removed/enabled/disabled while the timer is running, and the
  /// next tick should reflect whichever playlists are enabled *then*, not
  /// whatever was true when the timer was first started.
  List<EpgSource> Function()? _sourcesProvider;

  /// Opens the database and preloads the small always-in-memory slices.
  /// Idempotent: `main.dart` starts it during the splash (cheap — a few
  /// thousand rows, and SQLite does the work on its own thread) and awaits
  /// the same future after the splash.
  Future<void> init() => _initFuture ??= _init();

  /// Join an initial cache load already started by app startup. This never
  /// opens a database or starts a download on behalf of a metadata reader.
  Future<void> get initialCacheReady => _initFuture ?? Future<void>.value();

  Future<void> _init() async {
    lastUpdated = _storage.getEpgLastUpdated();
    // Leftover from the pre-database JSON cache — tens of MB on a big feed.
    unawaited(_storage
        .deleteCacheFile(AppConstants.cacheFileEpgPrograms)
        .catchError((_) {}));
    try {
      await _db.open();
      await _reloadCaches();
    } catch (e) {
      debugPrint('EpgService.init: ${e.runtimeType}');
    }
    if (_disposed) return;
    _soonTimer = Timer.periodic(_soonReloadEvery, (_) async {
      await _reloadCaches();
      notifyListeners();
    });
    notifyListeners();
  }

  /// Reloads [_soon]/[_withData] from the database and drops [_full], so
  /// every guide row re-queries on its next build.
  Future<void> _reloadCaches() async {
    final now = DateTime.now();
    final soon = await _db.programmesBetween(
        now.millisecondsSinceEpoch, now.add(_soonAhead).millisecondsSinceEpoch);
    final withData = await _db.channelIdsWithData(now.millisecondsSinceEpoch);
    final converted = soon.length < 128
        ? _toPrograms(soon)
        : await compute(_toPrograms, soon);
    if (_disposed) return;
    _soon = converted;
    _withData = withData;
    _full.clear();
    _cacheEpoch++;
  }

  /// (Re)starts auto-refresh every [minutes], refreshing every source
  /// [sourcesProvider] returns (one per enabled playlist with a non-empty
  /// EPG URL — see [EpgSource]). The first tick is due when the stored data
  /// reaches [minutes] old — immediately if it already is, or if the
  /// database is empty (first launch after upgrading from the JSON cache) —
  /// so a box that was off for a day refreshes at launch instead of waiting
  /// a full interval. Call again whenever the interval changes.
  ///
  /// Never sooner than [_minFirstRefreshDelay]: a refresh parses on the UI
  /// isolate for ~30 s on a Formuler, and the first seconds after the
  /// splash are when weak boxes used to crash under load (see main.dart's
  /// splash comments). The stored guide is already on screen meanwhile.
  void startAutoRefresh(
      int minutes, List<EpgSource> Function() sourcesProvider) {
    _refreshTimer?.cancel();
    _sourcesProvider = sourcesProvider;
    final interval = Duration(minutes: minutes);
    final age = lastUpdated == null
        ? interval
        : DateTime.now().difference(lastUpdated!);
    var firstDelay = _withData.isEmpty ? Duration.zero : interval - age;
    if (firstDelay < _minFirstRefreshDelay) {
      firstDelay = _minFirstRefreshDelay;
    }
    _refreshTimer = Timer(firstDelay, () {
      refreshAll();
      _refreshTimer = Timer.periodic(interval, (_) => refreshAll());
    });
  }

  void stopAutoRefresh() {
    _refreshTimer?.cancel();
    _refreshTimer = null;
  }

  Future<List<EpgSource>> Function()? supplementarySources;
  Future<void> Function()? onSupplementaryGuidesUpdated;
  Future<void>? _activeRefresh;
  String? refreshStatus;

  Future<void> _serialRefresh(List<EpgSource> sources) async {
    while (_activeRefresh != null) {
      await _activeRefresh;
    }
    if (_disposed) return;
    // Reserve the slot before notifying listeners inside the update. A
    // reentrant single-source request must queue behind this one as well.
    final completion = Completer<void>();
    _activeRefresh = completion.future;
    try {
      await _runRefresh(sources);
    } finally {
      _activeRefresh = null;
      completion.complete();
    }
  }

  /// Refreshes every source [_sourcesProvider] currently returns, one at a
  /// time — each source only ever replaces its own rows (see
  /// [EpgDatabase.deleteStaleFromSource]), and running them sequentially
  /// keeps `isLoading`/`error` meaningful for whichever one is in flight.
  /// Skipped while another refresh is already running.
  Future<void> refreshAll() async {
    if (isLoading) return;
    final sources = _sourcesProvider?.call() ?? const [];
    if (sources.isEmpty && supplementarySources == null) return;
    await _serialRefresh(sources);
  }

  /// Refreshes one EPG source — the entry point for every *single*-playlist
  /// caller (adding a playlist).
  Future<void> refresh(String url,
      {required Set<String> knownChannelIds}) async {
    await _serialRefresh([(url: url, knownChannelIds: knownChannelIds)]);
  }

  Future<void> _runRefresh(List<EpgSource> sources) async {
    isLoading = true;
    refreshStatus = 'Updating playlist guides…';
    _notifyStatus();
    try {
      await init();
      var anySucceeded = false;
      final failures = <String>[];
      for (final source in sources) {
        final count = await _refreshOne(source.url,
            knownChannelIds: source.knownChannelIds);
        if (count != null) anySucceeded = true;
        if (error != null) failures.add(error!);
      }
      await _reloadCaches();
      final extras = await supplementarySources?.call() ?? const <EpgSource>[];
      for (var i = 0; i < extras.length; i++) {
        final source = extras[i];
        refreshStatus = 'Filling guide gaps · ${i + 1}/${extras.length}';
        notifyListeners();
        final count = await _refreshOne(source.url,
            knownChannelIds: source.knownChannelIds);
        if (count != null) anySucceeded = true;
        if (error != null) failures.add(error!);
      }
      if (extras.isNotEmpty) await _reloadCaches();
      await onSupplementaryGuidesUpdated?.call();
      error = failures.isEmpty ? null : failures.first;
      if (anySucceeded) {
        await _db.deleteEndedBefore(DateTime.now()
            .subtract(AppConstants.epgPastRetention)
            .millisecondsSinceEpoch);
        lastUpdated = DateTime.now();
        await _storage.setEpgLastUpdated(lastUpdated!);
      }
    } catch (_) {
      error =
          'The guide update could not finish. Existing listings have been kept.';
    } finally {
      refreshStatus = null;
      isLoading = false;
      notifyListeners();
    }
  }

  /// Wipes every stored programme ("Clear Cache" in EPG settings).
  Future<void> clearAll() async {
    await _db.clearAll();
    await _storage.clearGuideEnrichmentRefreshes();
    lastUpdated = null;
    _soon = {};
    _withData = {};
    _full.clear();
    _cacheEpoch++;
    notifyListeners();
  }

  /// Downloads and parses one EPG source, writing its programmes into
  /// [EpgDatabase] in small batches *while* parsing — the full feed is
  /// never held in memory. Returns how many programmes were stored, or null
  /// on failure. A failed/aborted refresh leaves that source's previous
  /// rows alone (stale-removal only runs after a complete parse), so a
  /// network error never empties the guide.
  ///
  /// [knownChannelIds] scopes the stored programmes — a shared
  /// multi-provider EPG source can cover vastly more channels than one
  /// playlist actually has. Empty [knownChannelIds] disables filtering
  /// entirely rather than risking an empty guide if this ever races ahead
  /// of the playlist's own channels finishing their load.
  Future<int?> _refreshOne(String url,
      {required Set<String> knownChannelIds}) async {
    if (url.isEmpty) return null;
    final supplemental =
        guideEnrichmentNamespace(url).isNotEmpty || url == thaiEpgSourceUrl;
    error = null;
    final refreshed =
        supplemental ? _storage.getGuideEnrichmentRefresh(url) : null;
    if (supplemental &&
        refreshed != null &&
        DateTime.now().difference(refreshed) < const Duration(hours: 12) &&
        knownChannelIds.isNotEmpty &&
        (knownChannelIds.every(hasPrograms) ||
            _storage
                .getGuideEnrichmentRequestedIds(url)
                .containsAll(knownChannelIds))) {
      return 0;
    }
    error = null;
    _notifyStatus();

    final client = http.Client();
    try {
      final request = http.Request('GET', Uri.parse(url).replace(fragment: ''));
      final streamedResponse =
          await client.send(request).timeout(const Duration(seconds: 30));
      if (streamedResponse.statusCode != 200) {
        throw Exception(tr('Failed to load EPG (HTTP {code})',
            {'code': streamedResponse.statusCode}));
      }

      // Normalized the same way the parser normalizes the feed's own ids
      // (see [normalizeEpgId]) — these are Channel.epgId values (rawId or
      // a manual override), compared against the feed's <channel>/
      // <programme channel="..."> ids below, and a caller's casing
      // convention won't generally match the feed's own.
      final effectiveFilter = knownChannelIds.isEmpty
          ? null
          : knownChannelIds.map(normalizeEpgId).toSet();
      // Unique per refresh across app restarts — see
      // [EpgDatabase.deleteStaleFromSource].
      final gen = DateTime.now().millisecondsSinceEpoch;
      final result = await parseXmltvInBackground(
        streamedResponse.stream,
        noTitle: tr('No Title'),
        knownChannelIds: effectiveFilter,
        namespace: url == thaiEpgSourceUrl
            ? thaiEpgPrefix
            : guideEnrichmentNamespace(url),
        onRows: (rows) => _db.insertBatch(rows, url, gen),
      );
      // First-seen wins on a duplicate id across sources — an arbitrary
      // but harmless tie-break; these are just display labels for a
      // picker, not something correctness depends on.
      for (final entry in result.channelNames.entries) {
        _channelCatalog.putIfAbsent(entry.key, () => entry.value);
      }
      // Overwrite (not putIfAbsent) — unlike a channel's name, "what's on
      // right now" for a given id goes stale, so a fresh refresh's answer
      // should replace whatever an earlier one found.
      _nowPlayingCatalog.addAll(result.nowPlaying);

      // Only this URL's own rows from earlier refreshes that it didn't
      // re-send (channel dropped, programme rescheduled) — never another
      // source's, which used to wrongly wipe a manual override pointing at
      // a different playlist's feed.
      await _db.deleteStaleFromSource(url, gen);
      if (supplemental) {
        await _storage.setGuideEnrichmentRequestedIds(url, knownChannelIds);
        await _storage.setGuideEnrichmentRefresh(url);
      }
      return result.stored;
    } catch (e) {
      error = e.toString();
      debugPrint('EpgService error: ${e.runtimeType}');
      return null;
    } finally {
      client.close();
    }
  }

  List<EpgProgram>? _cached(String id) => _full[id] ?? _soon[id];

  /// A read-only walk over the already loaded guide. No database loads or
  /// provider requests; used by replay discovery once per refresh, not build.
  Iterable<EpgProgram> cachedCurrentProgrammes(DateTime now) sync* {
    // Replay scanning yields between batches. Snapshot the small full-row
    // cache so background guide loads cannot mutate its iterator mid-scan.
    final soon = _soon;
    final full = _full.snapshot();
    for (final entry in soon.entries) {
      final current = programmeAt(full[entry.key] ?? entry.value, now);
      if (current != null) yield current;
    }
    for (final entry in full.entries) {
      if (soon.containsKey(entry.key)) continue;
      final current = programmeAt(entry.value, now);
      if (current != null) yield current;
    }
  }

  /// Next starts in the loaded guide, including channels currently in a gap.
  /// No SQL: consumers use these boundaries to expire their current listings.
  Iterable<EpgProgram> cachedUpcomingProgrammes(DateTime now) sync* {
    final soon = _soon;
    final full = _full.snapshot();
    for (final entry in soon.entries) {
      final next = nextProgrammeAfter(full[entry.key] ?? entry.value, now);
      if (next != null) yield next;
    }
    for (final entry in full.entries) {
      if (soon.containsKey(entry.key)) continue;
      final next = nextProgrammeAfter(entry.value, now);
      if (next != null) yield next;
    }
  }

  @override
  EpgProgram? getCurrentProgram(String channelId) {
    final list = _cached(normalizeEpgId(channelId));
    if (list == null) return null;
    return programmeAt(list, DateTime.now());
  }

  @override
  EpgProgram? getNextProgram(String channelId) {
    final list = _cached(normalizeEpgId(channelId));
    if (list == null) return null;
    return nextProgrammeAfter(list, DateTime.now());
  }

  /// Programmes overlapping [from] and [to] whose title contains any
  /// of [terms] — see [EpgDatabase.programmesStartingWithTitle]. Channel ids
  /// come back normalized (see [normalizeEpgId]).
  @override
  Future<List<EpgProgram>> findProgrammesByTitle(
      DateTime from, DateTime to, List<String> terms,
      {List<String>? channelIds}) async {
    try {
      final rows = await _db.programmesStartingWithTitle(
          from.millisecondsSinceEpoch, to.millisecondsSinceEpoch, terms,
          channelIds: channelIds);
      final programmes = <EpgProgram>[];
      final slice = Stopwatch()..start();
      for (final row in rows) {
        programmes.add(_toProgram(row));
        if (slice.elapsedMilliseconds >= 2) {
          await Future<void>.delayed(Duration.zero);
          slice.reset();
        }
      }
      return programmes;
    } catch (e) {
      debugPrint('EpgService: title search failed: ${e.runtimeType}');
      rethrow; // A failed lookup is not evidence that a channel disappeared.
    }
  }

  /// Whether [channelId] has any programme that hasn't ended — without
  /// loading its rows.
  bool hasPrograms(String channelId) =>
      _withData.contains(normalizeEpgId(channelId));

  @override
  Future<List<EpgProgram>> findSportsProgrammesForChannels(
      List<String> ids, DateTime from, DateTime to) async {
    if (ids.isEmpty) return const [];
    final rows = await _db.programmesForSportsChannels(
        ids, from.millisecondsSinceEpoch, to.millisecondsSinceEpoch);
    return rows.map(_toProgram).toList();
  }

  /// Every stored programme for [channelId], ordered by start. Served from
  /// memory when loaded; otherwise queues a batched database load (every
  /// channel requested in the same frame shares one query) and returns the
  /// preloaded next-few-hours slice meanwhile — [guideRowsLoaded] ticks when
  /// the full rows arrive. Safe to call from `build`: the load and its
  /// notification always happen after the current frame.
  /// Fast browsing can read existing data without queuing disk work for rows
  /// the viewer will pass before a database load completes.
  List<EpgProgram> peekPrograms(String channelId) {
    final id = normalizeEpgId(channelId);
    return _full[id] ?? _soon[id] ?? const [];
  }

  List<EpgProgram> getPrograms(String channelId) {
    final id = normalizeEpgId(channelId);
    final full = _full[id];
    if (full != null) return full;
    if (!_withData.contains(id)) return _soon[id] ?? const [];
    if (!_inFlightLoads.contains(id)) {
      _pendingLoads.add(id);
      if (!_loadScheduled) {
        _loadScheduled = true;
        Timer.run(_loadPending);
      }
    }
    return _soon[id] ?? const [];
  }

  Future<void> _loadPending() async {
    _loadScheduled = false;
    if (_disposed || _loadingRows || _pendingLoads.isEmpty) return;
    _loadingRows = true;
    final ids = _pendingLoads.take(32).toList(growable: false);
    _pendingLoads.removeAll(ids);
    _inFlightLoads.addAll(ids);
    final epoch = _cacheEpoch;
    try {
      final rows = await _db.programmesFor(
          ids,
          DateTime.now()
              .subtract(AppConstants.epgPastRetention)
              .millisecondsSinceEpoch);
      if (_disposed) return;
      final count = rows.values.fold<int>(0, (sum, list) => sum + list.length);
      final programmes =
          count < 512 ? _toPrograms(rows) : await compute(_toPrograms, rows);
      if (_disposed) return;
      if (epoch != _cacheEpoch) {
        // The refresh notified while these IDs were still in flight. Let
        // mounted rows request the replacement data after they are released.
        _inFlightLoads.removeAll(ids);
        lastLoadedGuideChannelIds = ids.toSet();
        guideRowsLoaded.value++;
        return;
      }
      final now = DateTime.now();
      Object? evidence(EpgProgram? p) => p == null
          ? null
          : (p.title, p.description, p.start, p.stop, p.isLive);
      var evidenceChanged = false;
      for (final id in ids) {
        final before = _cached(id) ?? const <EpgProgram>[];
        final after = programmes[id] ?? const <EpgProgram>[];
        evidenceChanged |= evidence(programmeAt(before, now)) !=
                evidence(programmeAt(after, now)) ||
            evidence(nextProgrammeAfter(before, now)) !=
                evidence(nextProgrammeAfter(after, now));
        _full[id] = after;
      }
      if (evidenceChanged) _currentGuideRevision++;
      // Mounted rows inspect these IDs; unrelated channels keep their elements.
      lastLoadedGuideChannelIds = ids.toSet();
      guideRowsLoaded.value++;
    } catch (e) {
      debugPrint('EpgService: guide load failed: ${e.runtimeType}');
    } finally {
      _inFlightLoads.removeAll(ids);
      _loadingRows = false;
      if (!_disposed && _pendingLoads.isNotEmpty && !_loadScheduled) {
        _loadScheduled = true;
        Timer.run(_loadPending);
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _pendingLoads.clear();
    _refreshTimer?.cancel();
    _soonTimer?.cancel();
    guideRowsLoaded.dispose();
    super.dispose();
  }
}
