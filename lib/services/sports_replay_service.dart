import 'dart:async';
import 'dart:isolate';
import '../utils/sports_language.dart';
import 'package:flutter/foundation.dart';
import '../models/channel.dart';
import '../utils/extended_sports.dart';
import '../models/epg_program.dart';
import '../utils/replay_event_date.dart';
import '../utils/replay_presentation.dart';
import 'epg_service.dart';

enum ReplayEvidence { labelled, historical, likely }

class ReplayClassification {
  const ReplayClassification(
      this.sport, this.title, this.evidence, this.reason);
  final String sport, title, reason;
  final ReplayEvidence evidence;
}

/// A replay identified by its current guide slot and/or dedicated channel.
/// It never borrows an opponent, result or channel match from a live scoreboard.
class SportsReplay {
  const SportsReplay(
      {required this.sport,
      required this.title,
      required this.broadcasts,
      this.eventDate,
      this.evidence = ReplayEvidence.labelled,
      this.reason = 'Guide replay label'});
  final String sport;
  final String title;
  final List<ReplayBroadcast> broadcasts;
  final ReplayEvidence evidence;
  final ReplayEventDate? eventDate;
  final String reason;
  String get id => broadcasts.first.id;
}

class ReplayBroadcast {
  const ReplayBroadcast(this.channel, this.programme);
  final Channel channel;
  final EpgProgram programme;
  String get id => '${channel.id}:${programme.start.millisecondsSinceEpoch}';
}

class ReplaySnapshot {
  const ReplaySnapshot(this.events, this.channelsWithGuide,
      {this.unscheduled = const [], this.highlights = const []});
  final List<SportsReplay> events;

  /// Explicit highlight programmes from the same current-guide scan.
  final List<SportsReplay> highlights;
  final int channelsWithGuide;

  /// Dedicated replay channels with no usable event in the current guide.
  /// These are a directory, never advertised as confirmed events airing now.
  final List<ReplayChannel> unscheduled;
}

class ReplayScanProgress {
  const ReplayScanProgress(this.snapshot, this.checked, this.total);
  final ReplaySnapshot snapshot;
  final int checked, total;
}

class ReplayChannel {
  const ReplayChannel(this.channel, this.sport);
  final Channel channel;
  final String sport;
}

// These caches analyse programme content without a channel argument. Identical
// simulcast listings can share that work; channel-specific fallback analysis
// remains separate. Classification uses the start date, not the slot's end;
// expiry still checks each broadcast's own stop time on every projection.
typedef _ProgrammeKey = (DateTime, String, String?, bool);
_ProgrammeKey _programmeKey(EpgProgram p) =>
    (p.start, p.title, p.description, p.isLive);

/// Retain analysis for the current working set, including negative results.
/// Stop times and channel identity are checked separately on every projection.
class _ReplayEligibility {
  bool channelMayHelp = false;
}

class _ReplayProgrammeFacts {
  _ReplayProgrammeFacts(this.programme);
  final EpgProgram programme;
  bool prepared = false;
  void prepare() {
    classification;
    copyKey;
    highlights;
    prepared = true;
  }

  final eligibility = _ReplayEligibility();
  late final classification = _analyseSportsReplay(programme,
      allowLikely: true, eligibility: eligibility);
  late final copyKey = _guideCopyKey(programme);
  late final fixture = _fixtureKey(programme.title);
  late final liveFixture =
      fixture != null && isLiveSportsProgramme(programme) ? fixture : null;
  final highlightEligibility = _ReplayEligibility();
  late final highlights = _findHighlights();
  late final eventDate = replayEventDate(programme);
  (bool, ReplayClassification?) _findHighlights() {
    final candidate = _highlightLabel.hasMatch(programme.title) ||
        _highlightIntro.hasMatch(programme.description ?? '') ||
        _knownHighlights(programme);
    return (
      candidate,
      candidate
          ? _analyseSportsHighlights(programme,
              eligibility: highlightEligibility)
          : null
    );
  }
}

// One worker per large cold scan, with at most one 64-programme batch in
// flight. No channel URLs, database handles or full catalogue copies cross it.
class _ReplayAnalysisWorker {
  Isolate? _isolate;
  ReceivePort? _messages, _errors;
  StreamSubscription<dynamic>? _subscription, _errorSubscription;
  Completer<Object?>? _pending;
  SendPort? _send;
  Future<List<_ReplayProgrammeFacts>> analyse(
      List<_ReplayProgrammeFacts> facts) async {
    if (_send == null) {
      _messages = ReceivePort();
      _errors = ReceivePort();
      _pending = Completer<Object?>();
      _subscription = _messages!.listen((value) {
        final pending = _pending;
        if (pending != null && !pending.isCompleted) pending.complete(value);
      });
      _errorSubscription = _errors!.listen((_) {
        final pending = _pending;
        if (pending != null && !pending.isCompleted) {
          pending.completeError(StateError('Replay analysis worker stopped'));
        }
      });
      _isolate = await Isolate.spawn(_replayAnalysisMain, _messages!.sendPort,
          onError: _errors!.sendPort,
          onExit: _errors!.sendPort,
          debugName: 'Recorded guide analysis');
      _send = await _pending!.future.timeout(const Duration(seconds: 10))
          as SendPort;
    }
    _pending = Completer<Object?>();
    _send!.send(facts);
    return (await _pending!.future.timeout(const Duration(seconds: 10)))
        as List<_ReplayProgrammeFacts>;
  }

  void close() {
    _isolate?.kill(priority: Isolate.immediate);
    _subscription?.cancel();
    _errorSubscription?.cancel();
    _messages?.close();
    _errors?.close();
    _pending = null;
  }
}

void _replayAnalysisMain(SendPort reply) {
  final requests = ReceivePort();
  reply.send(requests.sendPort);
  requests.listen((dynamic message) {
    final facts = message as List<_ReplayProgrammeFacts>;
    for (final fact in facts) {
      fact.prepare();
    }
    reply.send(facts);
  });
}

/// Lazy facts tied to one immutable channel name, discarded with its index.
/// Large catalogues must not repeatedly evict/reparse unchanged channel facts.
class _ReplayChannelEntry {
  _ReplayChannelEntry(this.channel);
  final Channel channel;
  bool? _sportContext, _excluded;
  _ProgrammeKey? _replayKey, _highlightKey;
  ReplayClassification? _replay, _highlight;
  ReplayClassification? replay(EpgProgram p, String? dedicatedSport) {
    final key = _programmeKey(p);
    if (_replayKey != key) {
      _replay = classifySportsReplay(p,
          channel: channel, dedicatedSport: dedicatedSport, allowLikely: true);
      _replayKey = key;
    }
    return _replay;
  }

  ReplayClassification? highlight(EpgProgram p) {
    final key = _programmeKey(p);
    if (_highlightKey != key) {
      _highlight = classifySportsHighlights(p, channel: channel);
      _highlightKey = key;
    }
    return _highlight;
  }

  bool get excluded => _excluded ??= _excludedChannel(channel);
  bool get hasSportContext {
    final cached = _sportContext;
    if (cached != null) return cached;
    final sports = _channelSports(channel.name);
    if (sports.contains('table-tennis')) sports.remove('tennis');
    if (sports.contains('field-hockey')) sports.remove('hockey');
    return _sportContext =
        sports.length == 1 || _collegeNetwork.hasMatch(channel.name);
  }
}

/// Conservative, local-only discovery. Index once per playlist revision and
/// scan the already loaded current guide, never 80k channel queries or streams.
class SportsReplayService {
  SportsReplayService(this.epg, {this.backgroundAnalysis = true});
  final bool backgroundAnalysis;
  final EpgService epg;
  static final _shared = Expando<SportsReplayService>();
  static SportsReplayService shared(EpgService epg) =>
      _shared[epg] ??= SportsReplayService(epg);

  Map<String, List<_ReplayChannelEntry>> _channels = {};
  Map<String, ReplayChannel> _dedicated = {};
  final _eventSlots = <String, bool>{};
  Object? _revision;
  final _facts = <_ProgrammeKey, _ReplayProgrammeFacts>{};
  int _analysisMisses = 0;
  @visibleForTesting
  int workerBatches = 0;
  @visibleForTesting
  int workerFailures = 0;
  @visibleForTesting
  int get analysisEntries => _facts.length;
  @visibleForTesting
  int get analysisMisses => _analysisMisses;
  _ReplayProgrammeFacts _factsFor(EpgProgram p) {
    final key = _programmeKey(p);
    final existing = _facts[key];
    if (existing != null) return existing;
    // A bounded current working set, not an ever-growing programme history.
    if (_facts.length >= 32768) _trimOldest(_facts, 24576);
    _analysisMisses++;
    return _facts[key] = _ReplayProgrammeFacts(p);
  }

  ReplayEventDate? _eventDate(EpgProgram p) => _factsFor(p).eventDate;

  ReplaySnapshot? _cached;
  ReplayScanProgress? _partial;
  Object? _partialRevision;
  (int, int)? _partialGuide;
  DateTime? _partialAt, _partialUntil;

  int _guideRevision = -1;
  int _currentGuideRevision = -1;
  DateTime? _builtAt;
  DateTime? _expires;
  Future<void> _queue = Future.value();
  Future<void>? _warming;
  Object? _warmedGuide;
  DateTime? _warmedAt;

  /// Idle preparation shares the same queue/result as opening either tab.
  /// Only one warmup may be queued; navigation can cancel it at the next yield.
  Future<void> warm(List<Channel> channels,
      {required Object revision, required bool Function() cancelled}) {
    if (_warming != null) return _warming!;
    final result = _queue.then((_) async {
      if (cancelled() || peek(revision: revision) != null) return;
      final now = DateTime.now();
      final key = (revision, epg.changeRevision, epg.currentGuideRevision);
      // Minute-by-minute guide turnover must not turn idle preparation into
      // a continuous background scan. Foreground loads never use this limit.
      if (_warmedGuide == key &&
          _warmedAt != null &&
          !now.isBefore(_warmedAt!) &&
          now.difference(_warmedAt!) < const Duration(minutes: 5)) {
        return;
      }
      await _load(channels, revision, now, false, cancelled);
      _warmedGuide = key;
      _warmedAt = now;
    }).catchError((Object _) {
      // Optional work. An on-demand load still surfaces errors and retries.
    });
    _queue = result;
    return _warming = result.whenComplete(() => _warming = null);
  }

  /// A completed result only, valid for the same catalogue and current guide.
  /// Full timeline loads do not invalidate unchanged current/next evidence.
  ReplaySnapshot? peek({required Object revision, DateTime? at}) {
    final now = at ?? DateTime.now();
    if (_revision != revision ||
        _guideRevision != epg.changeRevision ||
        _currentGuideRevision != epg.currentGuideRevision ||
        _builtAt == null ||
        now.isBefore(_builtAt!) ||
        _expires == null ||
        !now.isBefore(_expires!)) {
      return null;
    }
    return _cached;
  }

  Future<ReplaySnapshot> load(List<Channel> channels,
      {required Object revision,
      DateTime? at,
      bool force = false,
      bool Function()? cancelled,
      void Function(ReplayScanProgress)? onProgress}) {
    final now = at ?? DateTime.now();
    if (!(cancelled?.call() ?? false) &&
        !force &&
        _partial != null &&
        _partialRevision == revision &&
        _partialGuide == (epg.changeRevision, epg.currentGuideRevision) &&
        _partialAt != null &&
        !now.isBefore(_partialAt!) &&
        _partialUntil != null &&
        now.isBefore(_partialUntil!)) {
      onProgress?.call(_partial!);
    }
    final result = _queue.then((_) => _load(channels, revision,
        at ?? DateTime.now(), force, cancelled, onProgress));
    _queue = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  // Collect the oldest keys once. Repeated keys.first calls restart iteration
  // over deleted map slots, making a large eviction unnecessarily expensive.
  static void _trimOldest<K, V>(Map<K, V> cache, int limit) {
    final excess = cache.length - limit;
    if (excess <= 0) return;
    for (final key in cache.keys.take(excess).toList(growable: false)) {
      cache.remove(key);
    }
  }

  Future<ReplaySnapshot> _load(
      List<Channel> channels, Object revision, DateTime now, bool force,
      [bool Function()? cancelled,
      void Function(ReplayScanProgress)? onProgress]) async {
    void checkActive() {
      if (cancelled?.call() ?? false) {
        throw StateError('Replay scan cancelled');
      }
    }

    checkActive();
    final watch = Stopwatch()..start();
    final slice = Stopwatch()..start();
    final missesBefore = _analysisMisses;
    final phases = <String, int>{};
    if (_revision != revision) {
      final index = <String, List<_ReplayChannelEntry>>{};
      final dedicated = <String, ReplayChannel>{};
      for (var i = 0; i < channels.length; i++) {
        final c = channels[i];
        if (Channel.isLiveId(c.rawId) && !c.name.trimLeft().startsWith('###')) {
          (index[normalizeEpgId(c.epgId)] ??= []).add(_ReplayChannelEntry(c));
          final sport = replayChannelSport(c);
          if (sport != null) dedicated[c.id] = ReplayChannel(c, sport);
        }
        if (i % 16 == 0 && slice.elapsedMilliseconds >= 3) {
          await Future<void>.delayed(Duration.zero);
          checkActive();
          slice.reset();
        }
      }
      _channels = index;
      _dedicated = dedicated;
      _eventSlots.clear();
      _revision = revision;
      _cached = null;
    }
    phases['index'] = watch.elapsedMilliseconds;
    final guideRevision = epg.changeRevision;
    final currentGuideRevision = epg.currentGuideRevision;
    if (!force) {
      final cached = peek(revision: revision, at: now);
      if (cached != null) {
        if (const bool.fromEnvironment('IPTV_PROFILE_SPORTS')) {
          debugPrint(
              'IPTV_RECORDED cached=true ms=${watch.elapsedMilliseconds}');
        }
        return cached;
      }
    }
    final groups = <String, List<ReplayBroadcast>>{};
    final highlightGroups = <String, List<ReplayBroadcast>>{};
    final highlightLabels = <String, ReplayClassification>{};
    final labels = <String, ReplayClassification>{};
    final unscheduled = Map<String, ReplayChannel>.of(_dedicated);
    var withGuide = 0;
    var expires = now.add(const Duration(minutes: 5));
    var boundaries = 0;
    for (final programme in epg.cachedUpcomingProgrammes(now)) {
      if (programme.start.isAfter(now) && programme.start.isBefore(expires)) {
        expires = programme.start;
      }
      if (++boundaries % 256 == 0 && slice.elapsedMilliseconds >= 3) {
        await Future<void>.delayed(Duration.zero);
        checkActive();
        slice.reset();
      }
    }
    final current = <EpgProgram>[];
    final labelled = <EpgProgram>[];
    final liveFixtures = <String>{};
    for (final programme in epg.cachedCurrentProgrammes(now)) {
      if (_replayTitle.hasMatch(programme.title) ||
          _highlightLabel.hasMatch(programme.title) ||
          _recordedSportBrand.hasMatch(programme.title)) {
        labelled.add(programme);
      } else {
        current.add(programme);
      }
      if (_channels.containsKey(normalizeEpgId(programme.channelId)) &&
          programme.stop.isBefore(expires)) {
        expires = programme.stop;
      }
      final key = _factsFor(programme).liveFixture;
      if (key != null) {
        liveFixtures.add(key);
        // Unmapped live simulcasts still suppress misleading replay evidence.
        if (programme.stop.isBefore(expires)) {
          expires = programme.stop;
        }
      }
      if (slice.elapsedMilliseconds >= 3) {
        await Future<void>.delayed(Duration.zero);
        checkActive();
        slice.reset();
      }
    }
    // Clearly labelled programmes reach the screen first. Every other slot
    // is still analysed with exactly the same rules.
    current.insertAll(0, labelled);
    phases['boundaries'] = watch.elapsedMilliseconds;
    final copySports = <String, Set<String>>{};
    final deferred = <EpgProgram>[];
    var checked = 0, lastPublish = -900, publishedGroups = -1;
    ReplaySnapshot? progressiveSnapshot;
    void publish() {
      final count = groups.length + highlightGroups.length;
      final changed = count != publishedGroups;
      if (watch.elapsedMilliseconds - lastPublish < (changed ? 400 : 900)) {
        return;
      }
      checkActive();
      // A correction arriving during the scan must not publish old evidence.
      if (epg.changeRevision != guideRevision ||
          epg.currentGuideRevision != currentGuideRevision) {
        return;
      }
      final snapshot = progressiveSnapshot =
          changed || progressiveSnapshot == null
              ? _project(groups, labels, highlightGroups, highlightLabels,
                  const {}, withGuide)
              : progressiveSnapshot!;
      final update = ReplayScanProgress(snapshot, checked, current.length);
      _partial = update;
      _partialRevision = revision;
      _partialGuide = (guideRevision, currentGuideRevision);
      _partialAt = now;
      _partialUntil = expires;
      lastPublish = watch.elapsedMilliseconds;
      publishedGroups = count;
      if (const bool.fromEnvironment('IPTV_PROFILE_SPORTS')) {
        debugPrint('IPTV_RECORDED progress=$checked/${current.length} '
            'results=$count ms=${watch.elapsedMilliseconds}');
      }
      onProgress?.call(update);
    }

    Future<void> collect(
        EpgProgram programme, ReplayClassification? explicit) async {
      final mapped = _channels[normalizeEpgId(programme.channelId)];
      if (mapped == null || !programme.isNowPlaying(now)) return;
      withGuide += mapped.length;
      final (highlightCandidate, highlight) = _factsFor(programme).highlights;
      final fallbacks = <(String, String?), ReplayClassification?>{};
      for (final entry in mapped) {
        final channel = entry.channel;
        if (slice.elapsedMilliseconds >= 3) {
          await Future<void>.delayed(Duration.zero);
          checkActive();
          slice.reset();
        }
        final clip = highlight ??
            (highlightCandidate &&
                    _factsFor(programme).highlightEligibility.channelMayHelp &&
                    entry.hasSportContext
                ? entry.highlight(programme)
                : null);
        if (clip != null &&
            !_information.hasMatch(channel.name) &&
            !_unavailable.hasMatch(channel.name)) {
          final key =
              '${clip.sport}|${_normalize(clip.title)}|${_normalize(programme.description ?? '')}';
          highlightLabels[key] = clip;
          (highlightGroups[key] ??= [])
              .add(ReplayBroadcast(channel, programme));
          unscheduled.remove(channel.id);
          continue;
        }
        // Information/highlight channels and explicitly inactive slots never
        // become replay suggestions, even when their guide mentions a sport.
        if (entry.excluded || _unavailable.hasMatch(programme.title)) {
          unscheduled.remove(channel.id);
          continue;
        }
        final dedicatedSport = _dedicated[channel.id]?.sport;
        if (explicit == null &&
            dedicatedSport == null &&
            (!_factsFor(programme).eligibility.channelMayHelp ||
                !entry.hasSportContext)) {
          continue;
        }
        final classification = dedicatedSport == null && explicit != null
            ? explicit
            : fallbacks.putIfAbsent((channel.name, dedicatedSport),
                () => entry.replay(programme, dedicatedSport));
        if (classification == null) {
          // Missing/generic guide: keep the dedicated channel in the clearly
          // labelled directory. A real non-replay programme takes it out.
          if (!_genericProgramme(programme, channel)) {
            unscheduled.remove(channel.id);
          }
          continue;
        }
        // Event slots often retain yesterday's fixture in a rolling guide.
        // An old date or missing LIVE flag is not evidence of replay playback.
        if (classification.evidence != ReplayEvidence.labelled &&
            _eventSlots.putIfAbsent(channel.id, () => _eventSlot(channel))) {
          unscheduled.remove(channel.id);
          continue;
        }
        // A missing live flag on a simulcast must not turn it into a replay.
        if (classification.evidence == ReplayEvidence.likely &&
            liveFixtures.contains(_factsFor(programme).fixture)) {
          continue;
        }
        unscheduled.remove(channel.id);
        // Exact programme identity only. Keep different dates, divisions and
        // descriptions separate rather than guessing which fixture they mean.
        final key =
            '${classification.sport}|${_normalize(classification.title)}|'
            '${_normalize(programme.description ?? '')}';
        if (labels[key] == null ||
            labels[key]!.evidence.index > classification.evidence.index) {
          labels[key] = classification;
        }
        final broadcasts = groups[key] ??= [];
        broadcasts.add(ReplayBroadcast(channel, programme));
      }
    }

    // Analyse and project each programme together. Only entries borrowing
    // sport identity from a guide copy require the complete evidence set.
    _ReplayAnalysisWorker? worker;
    var useWorker = backgroundAnalysis &&
        !kIsWeb &&
        current.length >= 512 &&
        current.where((p) => !_factsFor(p).prepared).take(257).length > 256;
    try {
      for (var offset = 0; offset < current.length; offset += 64) {
        final batch = current.skip(offset).take(64);
        final missing = <_ProgrammeKey, _ReplayProgrammeFacts>{};
        for (final p in batch) {
          final facts = _factsFor(p);
          if (!facts.prepared &&
              _channels.containsKey(normalizeEpgId(p.channelId))) {
            missing[_programmeKey(p)] = facts;
          }
        }
        if (missing.isNotEmpty && useWorker) {
          try {
            worker ??= _ReplayAnalysisWorker();
            final ready =
                await worker.analyse(missing.values.toList(growable: false));
            workerBatches++;
            for (final facts in ready) {
              _facts[_programmeKey(facts.programme)] = facts;
            }
          } catch (_) {
            workerFailures++;
            // A worker failure changes execution only, never the matching rules.
            worker?.close();
            worker = null;
            useWorker = false;
          }
          checkActive();
        }
        for (final programme in batch) {
          if (_channels.containsKey(normalizeEpgId(programme.channelId))) {
            if (programme.stop.isBefore(expires)) {
              expires = programme.stop;
            }
            final facts = _factsFor(programme);
            facts.prepare();
            final value = facts.classification;
            final key = facts.copyKey;
            if (value != null && key.isNotEmpty) {
              (copySports[key] ??= {}).add(value.sport);
            }
            if (value == null && key.isNotEmpty) {
              deferred.add(programme);
            } else {
              await collect(programme, value);
            }
          }
          checked++;
          publish();
          if (slice.elapsedMilliseconds >= 3) {
            await Future<void>.delayed(Duration.zero);
            checkActive();
            slice.reset();
          }
        }
      }
    } finally {
      worker?.close();
    }
    phases['classify'] = watch.elapsedMilliseconds;
    for (final programme in deferred) {
      final sports = copySports[_factsFor(programme).copyKey];
      final explicit = sports?.length == 1
          ? classifySportsReplay(programme,
              matchingGuideSport: sports!.single, allowLikely: true)
          : null;
      await collect(programme, explicit);
      publish();
    }
    phases['project'] = watch.elapsedMilliseconds;
    final active = current.map(_programmeKey).toSet();
    _facts.removeWhere((key, _) => !active.contains(key));
    checkActive();
    final result = _project(groups, labels, highlightGroups, highlightLabels,
        unscheduled, withGuide);
    _guideRevision = guideRevision;
    _currentGuideRevision = currentGuideRevision;
    _builtAt = now;
    _expires = expires;
    _partial = null;
    if (const bool.fromEnvironment('IPTV_PROFILE_SPORTS')) {
      debugPrint('IPTV_RECORDED cached=false warm=${cancelled != null} '
          'channels=${channels.length} programmes=${current.length} '
          'replays=${result.events.length} highlights=${result.highlights.length} '
          'ms=${watch.elapsedMilliseconds} misses=${_analysisMisses - missesBefore} phases=$phases');
    }
    return _cached = result;
  }

  ReplaySnapshot _project(
      Map<String, List<ReplayBroadcast>> groups,
      Map<String, ReplayClassification> labels,
      Map<String, List<ReplayBroadcast>> highlightGroups,
      Map<String, ReplayClassification> highlightLabels,
      Map<String, ReplayChannel> unscheduled,
      int withGuide) {
    final events = <SportsReplay>[];
    for (final entry in groups.entries) {
      final broadcasts = List<ReplayBroadcast>.of(entry.value)
        ..sort((a, b) {
          if (a.channel.isFavorite != b.channel.isFavorite) {
            return a.channel.isFavorite ? -1 : 1;
          }
          final start = b.programme.start.compareTo(a.programme.start);
          return start != 0 ? start : a.channel.name.compareTo(b.channel.name);
        });
      final label = labels[entry.key]!;
      events.add(SportsReplay(
          sport: label.sport,
          title: label.title,
          evidence: label.evidence,
          reason: label.reason,
          eventDate: _eventDate(broadcasts.first.programme),
          broadcasts: List.unmodifiable(broadcasts)));
    }
    events.sort((a, b) {
      final sport = a.sport.compareTo(b.sport);
      if (sport != 0) return sport;
      final start = b.broadcasts.first.programme.start
          .compareTo(a.broadcasts.first.programme.start);
      return start != 0 ? start : a.title.compareTo(b.title);
    });
    // Providers sometimes append different category/premiere metadata to the
    // same detailed synopsis. Share dates only across an exact event title
    // and narrative, and only when the dated copies agree.
    String narrativeKey(SportsReplay event) {
      final narrative = replaySynopsisForDisplay(
          event.broadcasts.first.programme.description ?? '');
      final explicitFixtureDate = _matchup.hasMatch(event.title) &&
          event.eventDate?.day != null &&
          !event.eventDate!.isGuideDate &&
          !event.eventDate!.isPossible &&
          narrative.length >= 12;
      return narrative.length < 60 && !explicitFixtureDate
          ? ''
          : '${event.sport}|${_normalTitle(event.title)}|${_normalize(narrative)}';
    }

    final dated = <String, Map<String, ReplayEventDate>>{};
    for (final event in events) {
      final date = event.eventDate;
      final key = narrativeKey(event);
      if (key.isNotEmpty && date?.day != null && !date!.isPossible) {
        (dated[key] ??= {})[date.day!.toIso8601String()] = date;
      }
    }
    for (var i = 0; i < events.length; i++) {
      final event = events[i];
      final dates = dated[narrativeKey(event)];
      if (event.eventDate != null || dates?.length != 1) continue;
      final date = dates!.values.single;
      events[i] = SportsReplay(
          sport: event.sport,
          title: event.title,
          broadcasts: event.broadcasts,
          evidence: event.evidence,
          reason: event.reason,
          eventDate: ReplayEventDate(date.precision, date.label,
              '${date.source}. Same event title and detailed synopsis on another guide listing.',
              day: date.day, year: date.year, isGuideDate: date.isGuideDate));
    }
    // Consolidate alternate guide copies only when the exact detailed
    // narrative and full calendar date agree. Unknown dates stay separate.
    final merged = <String, SportsReplay>{};
    for (final event in events) {
      final narrative = narrativeKey(event);
      final key = narrative.isNotEmpty &&
              event.eventDate?.day != null &&
              !event.eventDate!.isPossible
          ? '$narrative|${event.eventDate!.day}'
          : event.id;
      final previous = merged[key];
      if (previous == null) {
        merged[key] = event;
        continue;
      }
      final broadcasts = [...previous.broadcasts, ...event.broadcasts]
        ..sort((a, b) {
          if (a.channel.isFavorite != b.channel.isFavorite) {
            return a.channel.isFavorite ? -1 : 1;
          }
          final start = b.programme.start.compareTo(a.programme.start);
          return start != 0 ? start : a.channel.name.compareTo(b.channel.name);
        });
      final strongest =
          event.evidence.index < previous.evidence.index ? event : previous;
      merged[key] = SportsReplay(
          sport: strongest.sport,
          title: strongest.title,
          broadcasts: List.unmodifiable(broadcasts),
          evidence: strongest.evidence,
          reason: strongest.reason,
          eventDate: strongest.eventDate);
    }
    // Preserve the provider's numeric channel/league order within each sport.
    final directory = unscheduled.values.indexed.toList()
      ..sort((a, b) {
        final sport = a.$2.sport.compareTo(b.$2.sport);
        return sport != 0 ? sport : a.$1.compareTo(b.$1);
      });
    return ReplaySnapshot(List.unmodifiable(merged.values), withGuide,
        unscheduled: List.unmodifiable(directory.map((e) => e.$2)),
        highlights: List.unmodifiable([
          for (final entry in highlightGroups.entries)
            SportsReplay(
                sport: highlightLabels[entry.key]!.sport,
                title: highlightLabels[entry.key]!.title,
                reason: highlightLabels[entry.key]!.reason,
                // Roundups can cover multiple games. Never invent a single
                // fixture date or send these programmes to score matching.
                broadcasts: List.unmodifiable(
                    List<ReplayBroadcast>.of(entry.value)
                      ..sort((a, b) =>
                          a.channel.isFavorite != b.channel.isFavorite
                              ? (a.channel.isFavorite ? -1 : 1)
                              : a.channel.name.compareTo(b.channel.name)))),
        ]));
  }
}

String _normalize(String value) =>
    value.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();

String _normalTitle(String title) =>
    _normalize(title).replaceAll(RegExp(r'\s*:\s*|\s+[-–—]\s+'), ':');

String _guideCopyKey(EpgProgram programme) {
  if (!_matchup.hasMatch(programme.title) &&
      !_eventForm.hasMatch(programme.title)) {
    return '';
  }
  final narrative = replaySynopsisForDisplay(programme.description ?? '');
  return narrative.length < 60
      ? ''
      : '${_normalTitle(programme.title)}|${_normalize(narrative)}';
}

final _replayTitle = RegExp(
    r'\b(nba playback|replay|replays|repeat|repeated|rerun|re-run|rebroadcast|re-broadcast|re[ -]?airs?|encore|wiederholung|rediffusion)\b|\[(?:r|rpt)\]|\((?:r|rpt)\)|ย้อนหลัง|รีรัน|บันทึกการแข่งขัน|เทปบันทึก',
    caseSensitive: false);
final _replayDescription = RegExp(
    r'^(?:watch (?:a |the )?)?(?:(?:a |the |full |match |game |race |event |extended )*)(?:replay|repeat|rebroadcast|re-broadcast|rerun|encore)\b|\b(?:full|match|game|race|event) replay (?:of|from)\b|^(?:(?:รับชม|ชม)\s*)?(?:ย้อนหลัง|รีรัน|บันทึกการแข่งขัน|เทปบันทึก)',
    caseSensitive: false);
final _notEvent = RegExp(
    r'\b(movie|film|sitcom|highlights?|hlts|hls|h/l|final score|soccer saturday|news|previews?|podcast|breakdown|bloopers|award show|round-up|pre-game|pregame|post-game|postgame|magazine|documentary|documentaries|analysis|press conference|sportscenter|sports centre|sportscentre|talk show)\b',
    caseSensitive: false);
final _live = RegExp(r'(^|[\s:\[\(])live([\s:\]\)]|$)', caseSensitive: false);
final _unavailable = RegExp(
    r'\b(off[ -]?air|offline|no (?:event|game|match|broadcast)|not (?:broadcasting|available)|stream (?:ended|offline)|event (?:ended|finished|over)|coming soon|to be announced|tba|test (?:card|channel))\b|(?:^|[\s|:\[(])(?:end|ended|finished|next|upcoming)(?=\s*(?:[|:\]\)–-]|$))',
    caseSensitive: false);
final _eventSlotName = RegExp(
    r'\b(?:ppv|pay[ -]per[ -]view)\b|\b(?:event|match|game)\s*\d+\b|\b(?:espn\s*\+|btn\s*\+|flsp)\s*\d+\b|^\s*ufc\s+\d{1,2}\s*:',
    caseSensitive: false);
bool _eventSlot(Channel c) =>
    _eventSlotName.hasMatch('${c.name} ${c.group}') ||
    _matchup.hasMatch(c.name);
final _information = RegExp(r'\b(info|information|channel guide|schedule)\b',
    caseSensitive: false);
// A dedicated service name, not a dated PPV listing that happens to contain
// "full event replay". Those stale names cannot establish what's on now.
final _dedicatedName = RegExp(
    r'\b(?:replay|replays|repeat|rebroadcast)(?:\s+(?:(?:channel|english|spanish)\s*)?\d+|\s+24\s*/\s*7)?(?:\s+(?:hd|fhd|uhd|sd|4k|raw|ᴿᴬᵂ))*\s*$',
    caseSensitive: false);
final _genericTitle = RegExp(
    r'^(?:sports?|program(?:me)?(?: information)?|no (?:epg|guide|program(?:me)?)(?: (?:data|information|available))?|no information|unknown|to be announced|tba|replays?|repeat|encore|\-+)$',
    caseSensitive: false);
final _genericReplayTitle = RegExp(
    r'^(?:(?:nfl|nba|nhl|pl|efl[ -]?(?:l1|l2|ch)|laliga|seriea|spfl|national league|sports?|soccer|tennis)\s+)?(?:replays?|repeat|encore)(?:\s+(?:channel\s*)?\d+)?(?:\s+(?:hd|fhd|uhd|sd|4k|raw|ᴿᴬᵂ))*\s*$',
    caseSensitive: false);
final _baseReplaySports = <String, RegExp>{
  'volleyball':
      RegExp(r'\b(volleyball|volley ball|vnl|cev)\b', caseSensitive: false),
  'basketball': RegExp(
      r'\b(basketball|nba|wnba|nbl|euroleague|fiba|raptors in 30)\b',
      caseSensitive: false),
  'football': RegExp(
      r'\b(american football|college football|high school football|nfl|ncaaf|cfl|gridiron)\b',
      caseSensitive: false),
  'soccer': RegExp(
      r'\b(soccer|fútbol|conmebol|sudamericana|libertadores|s[uü]per lig|premier league|la liga|laliga|bundesliga|serie ?a|ligue 1|uefa|fifa|mls|a-league|nwsl|champions league|europa league|fa cup|efl|spfl|scottish premiership|ucl|eredivisie|women.s super league|liverpool.*the match)\b',
      caseSensitive: false),
  'tennis': RegExp(
      r'\b(tennis|atp|wta|wimbledon|davis cup|billie jean king cup)\b',
      caseSensitive: false),
  'hockey': RegExp(r'\b(ice hockey|hockey|nhl|ahl|whl|ohl|iihf)\b',
      caseSensitive: false),
  'cricket': RegExp(r'\b(cricket|ashes|wbbl|ipl|bbl|t20|odi|test match)\b',
      caseSensitive: false),
  'rugby': RegExp(r'\b(rugby|nrl|epcr|urc|six nations|state of origin)\b',
      caseSensitive: false),
  'australian-football': RegExp(
      r'\b(afl|aflw|aussie rules|australian football)\b',
      caseSensitive: false),
  'golf': RegExp(r'\b(golf|pga|lpga|ryder cup|dp world tour)\b',
      caseSensitive: false),
  'racing': RegExp(
      '${motorsportGuidePattern.pattern}|\\b(?:trans am (?:racing|series|highlights|championship)|motorracing)\\b',
      caseSensitive: false),
  'pickleball': RegExp(r'\bpickleball\b', caseSensitive: false),
  'climbing': RegExp(
      r'\b(?:ifsc|sport climbing|climbing world (?:cup|series|championship))\b',
      caseSensitive: false),
  'mma': RegExp(r'\b(mma|ufc|pfl|bellator|one championship)\b',
      caseSensitive: false),
  'boxing': RegExp(r'\bboxing\b', caseSensitive: false),
  'cycling': RegExp(r'\b(cycling|tour de france|giro d.italia|vuelta)\b',
      caseSensitive: false),
  'netball': RegExp(r'\bnetball\b', caseSensitive: false),
  'horse-racing':
      RegExp(r'\b(horse racing|racing replay)\b', caseSensitive: false),
  'billiards': RegExp(
      r'\b(billiards?|snooker|ultimate pool|(?:national|world|us open) pool championships?|(?:9|10|nine|ten)[ -]ball)\b',
      caseSensitive: false),
  'lacrosse': RegExp(r'\blacrosse\b', caseSensitive: false),
  'softball': RegExp(r'\bsoftball\b', caseSensitive: false),
  'table-tennis': RegExp(r'\btable tennis\b', caseSensitive: false),
  'triathlon': RegExp(r'\btriathlon\b', caseSensitive: false),
  'rodeo': RegExp(r'\brodeo\b', caseSensitive: false),
  'wrestling': RegExp(r'\b(wrestling|wwe|aew)\b', caseSensitive: false),
  'baseball': RegExp(r'\b(baseball|mlb|npb|kbo)\b', caseSensitive: false),
};

// Add discovery vocabulary without replacing established replay aliases (IPL,
// T20, Vuelta, MLB, etc.). Build the small union once, never per programme.
final _sports = <String, RegExp>{
  ..._baseReplaySports,
  for (final e in extendedSportsPatterns.entries)
    e.key: _baseReplaySports.containsKey(e.key)
        ? RegExp(
            '(?:${_baseReplaySports[e.key]!.pattern})|(?:${e.value.pattern})',
            caseSensitive: false)
        : e.value,
};

Set<String> _sportsIn(String text) {
  text = sportsLanguageText(text);
  final sports = {
    for (final e in _sports.entries)
      if (e.value.hasMatch(text)) e.key,
  };
  // Padel listings commonly say "Padel Tennis". The specific sport wins.
  if (sports.contains('padel') || sports.contains('table-tennis')) {
    sports.remove('tennis');
  }
  return sports;
}

// Dedicated channel brands can disambiguate generic programme titles, but a
// broad sports category cannot establish which sport a programme covers.
final _soccerChannel = RegExp(
    r'\b(?:sky sports football|lfc\s*tv|mutv|chelsea tv|barca tv)\b',
    caseSensitive: false);
final _collegeNetwork = RegExp(
    r'\b(?:acc(?: digital)? network|sec network|big ten network|pac[ -]?12 network)\b',
    caseSensitive: false);
Set<String> _channelSports(String name) {
  final sports = _sportsIn(name);
  if (sports.isEmpty && _soccerChannel.hasMatch(name)) sports.add('soccer');
  return sports;
}

final _retrospectiveCoverage = RegExp(
    r'^(?:a chance to relive|another chance to (?:watch|see)|relive\b|replays of\b|revisit (?:the )?bare knuckle fighting championship)',
    caseSensitive: false);
final _recordedSportBrand = RegExp(
    r'^(?:pl retro\b|retro c[’\x27]?ship\b|ufc reloaded\b|bkfc rewind\b|test mini\b|race in ?30\b)',
    caseSensitive: false);

bool _excludedChannel(Channel channel) =>
    !Channel.isLiveId(channel.rawId) ||
    channel.name.trimLeft().startsWith('###') ||
    _notEvent.hasMatch(channel.name) ||
    _information.hasMatch(channel.name) ||
    _unavailable.hasMatch(channel.name);

/// Sport context is only borrowed from a clearly dedicated replay service.
/// A generic sports group, an entertainment Encore channel, or a past event
/// in a dated PPV channel name cannot create a replay event.
String? replayChannelSport(Channel channel) {
  if (!_dedicatedName.hasMatch(channel.name) || _excludedChannel(channel)) {
    return null;
  }
  var sports = _sportsIn(channel.name);
  if (sports.isEmpty) sports = _sportsIn(channel.group);
  return sports.length == 1 ? sports.single : null;
}

bool _genericProgramme(EpgProgram programme, Channel? channel) {
  final title = programme.title.trim();
  return title.isEmpty ||
      _genericTitle.hasMatch(title) ||
      _genericReplayTitle.hasMatch(title) ||
      (channel != null && _normalize(title) == _normalize(channel.name));
}

bool isUnscheduledReplayChannel(Channel channel, EpgProgram? current) =>
    replayChannelSport(channel) != null &&
    (current == null ||
        (!_unavailable.hasMatch(current.title) &&
            _genericProgramme(current, channel)));

String _plainGuideText(String text) =>
    text.replaceAll('ᴸᶦᵛᵉ', ' Live ').replaceAll('ᴺᵉʷ', '').trim();

final _liveDescription = RegExp(
    r'(?:^|\n)\s*live\s+(?:coverage|action|broadcast|from|at)\b|^ถ่ายทอดสด',
    caseSensitive: false);
final _localLiveTitle = RegExp(r'ถ่ายทอดสด|(?:^|[\s\[(])สด(?:$|[\s:\])])');
final _localRecordedTitle =
    RegExp(r'ย้อนหลัง|รีรัน|บันทึกการแข่งขัน|เทปบันทึก|ไฮไล[ทต]์');
final _localRecordedIntro = RegExp(
    r'^(?:(?:รับชม|ชม)\s*)?(?:ย้อนหลัง|รีรัน|บันทึกการแข่งขัน|เทปบันทึก|ไฮไล[ทต]์)');

final _translatedLiveIntro = RegExp(r'^live(?:\s|:|$)', caseSensitive: false);

bool isLiveSportsProgramme(EpgProgram programme) {
  final title = sportsLanguageText(programme.title);
  final description =
      sportsLanguageText((programme.description ?? '').trim()).trim();
  // Recorded labels take precedence over stale flags; incidental links to
  // catch-up viewing later in a live synopsis do not change its state.
  if (_replayTitle.hasMatch(title) ||
      _highlightLabel.hasMatch(title) ||
      _replayDescription.hasMatch(description) ||
      _highlightIntro.hasMatch(description) ||
      _localRecordedTitle.hasMatch(programme.title) ||
      _localRecordedIntro.hasMatch(description)) {
    return false;
  }
  return programme.isLive ||
      _live.hasMatch(_plainGuideText(title)) ||
      _localLiveTitle.hasMatch(programme.title) ||
      _liveDescription.hasMatch(description) ||
      _translatedLiveIntro.hasMatch(description);
}

final _matchup =
    RegExp(r'\s(?:v\.?|vs\.?|versus|at|@|c\.)\s', caseSensitive: false);
final _eventForm = RegExp(
    r'\b(finals?|semi[ -]?finals?|quarter[ -]?finals?|demi[ -]?finale|grand prix|round \d|(?:first|second|third|fourth|final) round|practice [123]|qualifying|\d\w* test|game \d|fight night|(?:ufc|glory|lion fight|lfa|bkfc|cage warriors) \d+|classics?|championship|nationals|gala)\b',
    caseSensitive: false);
final _participants = RegExp(r'\b(?:faces?|hosts?|meets?|take on|takes on)\b',
    caseSensitive: false);
final _futureSlot = RegExp(
    r'^(?:upcoming|next (?:game|event|match)|sign off|this is\b)|\bno streams? available\b',
    caseSensitive: false);

String? _fixtureKey(String title) {
  var value = _plainGuideText(title).replaceAll(_live, '').trim();
  if (!_matchup.hasMatch(value)) return null;
  // Strip competition prefixes only; preserve all team/division/date words.
  final match = _matchup.firstMatch(value)!;
  final prefix = value.substring(0, match.start);
  final separators = RegExp(r':\s*|\s[-–]\s').allMatches(prefix).toList();
  if (separators.isNotEmpty) value = value.substring(separators.last.end);
  value = value.replaceAll(_matchup, ' v ');
  return _normalize(value.replaceAll(RegExp(r'[^\w\s]'), ' '));
}

DateTime? _validDate(int year, int month, int day) {
  final d = DateTime.utc(year, month, day);
  return d.year == year && d.month == month && d.day == day ? d : null;
}

/// Only dates referring to this programme, not arbitrary dates mentioned in
/// a team's history. A 36-hour margin admits yesterday's completed coverage
/// after midday UTC, without treating an overnight live match as a replay.
String? _historicalEvidence(EpgProgram p, String title, String description) {
  final airing = p.start.toUtc();
  bool old(DateTime? date) =>
      date != null && airing.difference(date) >= const Duration(hours: 36);
  final date = replayEventDate(p);
  if (date != null && !date.isPossible) {
    if (old(date.day)) return 'Guide event date: ${date.label}';
    if (date.day == null &&
        date.year != null &&
        (date.seasonEnd ?? date.year!) < airing.year) {
      return 'Event from ${date.label}';
    }
  }
  // UK guide descriptions use an event-date suffix such as (23.08).
  // Require an unambiguous day (>12); don't guess US vs UK date ordering.
  final short = RegExp(r'\((\d{2})\.(\d{2})\)\s*$').firstMatch(description);
  if (short != null &&
      int.parse(short[1]!) > 12 &&
      old(_validDate(
          airing.year, int.parse(short[2]!), int.parse(short[1]!)))) {
    return 'Guide event date: ${short[1]}.${short[2]}';
  }
  if (RegExp(r'\bclassics?\b', caseSensitive: false).hasMatch(title) ||
      description.toLowerCase().contains('classic sport event')) {
    return 'Classic event in the guide';
  }
  return null;
}

/// Evaluate the current programme itself across every visible live channel.
/// Missing LIVE alone is never sufficient: inferred entries also need a sport
/// and a recognisable match/session, and remain visibly marked as likely.
ReplayClassification? _classifySportsReplay(EpgProgram programme,
    {_ReplayEligibility? eligibility,
    Channel? channel,
    String? dedicatedSport,
    String? matchingGuideSport,
    bool allowLikely = false}) {
  final title = _plainGuideText(programme.title);
  if (extendedSportsPatterns['poker']!.hasMatch(title) &&
      isExtendedSportFiction(title, programme.description ?? '')) {
    return null;
  }
  final description = (programme.description ?? '').trim();
  final lineEnd = description.indexOf('\n');
  final firstLine =
      lineEnd < 0 ? description : description.substring(0, lineEnd);
  final generic = _genericProgramme(programme, channel);
  final describedEvent = generic &&
      (_matchup.hasMatch(firstLine) ||
          _eventForm.hasMatch(firstLine) ||
          _datedSubtitle.hasMatch(firstLine)) &&
      _sportsIn(title).isNotEmpty;
  // A generic replay label can still carry a specific match in its synopsis.
  // Ordinary "no guide"/channel-name placeholders remain unavailable.
  final describedReplay = _replayTitle.hasMatch(title) &&
      replaySynopsisMatch(title, description) != null;
  if (_knownHighlights(programme) ||
      _highlightLabel.hasMatch(title) ||
      _notEvent.hasMatch(title) ||
      _information.hasMatch(title) ||
      _unavailable.hasMatch(title) ||
      _futureSlot.hasMatch(title) ||
      isLiveSportsProgramme(programme) ||
      (generic && !describedReplay && !describedEvent)) {
    return null;
  }
  if (RegExp(r'^(?:(?:a|the) )?(?:preview|pre[ -]?game|post[ -]?game|studio discussion|analysis)\b',
              caseSensitive: false)
          .hasMatch(description) ||
      RegExp(r'\bif necessary\b', caseSensitive: false).hasMatch(description) ||
      RegExp(r'^(?:extended |match |game |race )?highlights\b',
              caseSensitive: false)
          .hasMatch(description) ||
      RegExp(r'\bhighlights,? reaction and analysis\b', caseSensitive: false)
          .hasMatch(description) ||
      RegExp(r'\b(?:explore|look back (?:at|on))\b.*\b(?:best races|career|greatest moments)\b',
              caseSensitive: false)
          .hasMatch(description)) {
    return null;
  }
  // Channel-branded poker episodes are the one shape decision that can
  // change when a channel is supplied. Preserve that fallback explicitly.
  if (eligibility != null &&
      _pokerEpisode.hasMatch('$title $description') &&
      _pokerPlay.hasMatch(description)) {
    eligibility.channelMayHelp = true;
  }
  final recordedPoker =
      _recordedPokerEpisode(title, description, channel?.name);
  final explicit = recordedPoker ||
      _recordedSportBrand.hasMatch(title) ||
      _replayTitle.hasMatch(title) ||
      (_replayTitle.hasMatch(firstLine) &&
          RegExp(r'^(?:(?:19|20)\d{2}:|S\d+\s+E\d+|(?:Day|Round|Game) \d+)',
                  caseSensitive: false)
              .hasMatch(firstLine)) ||
      (isCondensedReplay(title, description) &&
          (_matchup.hasMatch(title) ||
              _eventForm.hasMatch(title) ||
              replaySynopsisMatch(title, description) != null)) ||
      _replayDescription.hasMatch(description) ||
      _retrospectiveCoverage.hasMatch(description);
  dedicatedSport ??= channel == null ? null : replayChannelSport(channel);
  final titleEvent = _matchup.hasMatch(title) || _eventForm.hasMatch(title);
  final datedSession = RegExp(r'^(?:19|20)\d{2}:\s*\S').hasMatch(firstLine);
  final synopsisEvent = _matchup.hasMatch(description) ||
      _eventForm.hasMatch(description) ||
      _participants.hasMatch(description) ||
      datedSession ||
      recordedPoker;
  // A host mentioning a game/final is not itself event coverage. Providers
  // often append an old series-premiere date to these studio programmes.
  if (!titleEvent &&
      (_nonCoverage.hasMatch(description) ||
          _notEvent.hasMatch(description) ||
          RegExp(r'\b(countdown|sports talk|behind.the.scenes|round.up)\b',
                  caseSensitive: false)
              .hasMatch(description))) {
    return null;
  }
  if (!explicit && dedicatedSport == null && !titleEvent && !synopsisEvent) {
    return null;
  }
  if (eligibility != null) eligibility.channelMayHelp = true;
  var sports = _sportsIn(title);
  final sportInTitle = sports.isNotEmpty;
  if (sports.isEmpty) {
    sports = _sportsIn(
        description.length > 600 ? description.substring(0, 600) : description);
  }
  // This provider labels some Big 12 condensed games simply "Football".
  // Require both the sport and a named college conference; bare football
  // remains ambiguous internationally and must not turn soccer into NFL.
  if (sports.isEmpty &&
      RegExp(r'\bfootball\b', caseSensitive: false).hasMatch(description) &&
      RegExp(r'\b(?:big 12|big ten|acc|sec)\b', caseSensitive: false)
          .hasMatch('$title $description')) {
    sports = {'football'};
  }
  if (sports.contains('table-tennis')) sports.remove('tennis');
  if (sports.contains('field-hockey')) sports.remove('hockey');
  if (sports.isEmpty && channel != null) sports = _channelSports(channel.name);
  if (sports.isEmpty &&
      channel != null &&
      _collegeNetwork.hasMatch(channel.name) &&
      RegExp(r'\bfootball\b', caseSensitive: false).hasMatch(title)) {
    sports = {'football'};
  }
  if (sports.isEmpty && matchingGuideSport != null) {
    sports = {matchingGuideSport};
  }
  if (sports.isEmpty && dedicatedSport != null) sports = {dedicatedSport};
  if (sports.length != 1) return null;
  if (!explicit && dedicatedSport != null && dedicatedSport != sports.single) {
    return null;
  }
  final historical = explicit || dedicatedSport != null
      ? null
      : _historicalEvidence(programme, title, description);
  final eventShape = titleEvent ||
      recordedPoker ||
      ((sportInTitle || describedEvent) && synopsisEvent);
  final ReplayEvidence evidence;
  final String reason;
  if (explicit || dedicatedSport != null) {
    evidence = ReplayEvidence.labelled;
    reason = recordedPoker
        ? 'Recorded poker episode listed in the guide'
        : explicit
            ? 'Replay identified in the guide'
            : 'Dedicated replay channel';
  } else if (historical != null && eventShape) {
    evidence = ReplayEvidence.historical;
    reason = historical;
  } else if ((channel != null || allowLikely) && eventShape) {
    evidence = ReplayEvidence.likely;
    reason =
        'Sports event with no live marker in the guide; replay unconfirmed';
  } else {
    return null;
  }
  final cleaned = title
      .replaceFirst(
          RegExp(r'^\s*(?:replay|repeat|rebroadcast|encore)\s*[:\-–]\s*',
              caseSensitive: false),
          '')
      .replaceAll(
          RegExp(r'\s*[\[(](?:replay|repeat|r|rpt)[\])]\s*',
              caseSensitive: false),
          ' ')
      .trim();
  return ReplayClassification(
      sports.single, cleaned.isEmpty ? title : cleaned, evidence, reason);
}

final _highlightLabel = RegExp(
    r'\b(highlights?|hlts|hls|h/l|recaps?|round[ -]?up|best of|greatest hits|hoogtepunten|resumen|résumé|melhores momentos)\b|ไฮไล[ทต]์',
    caseSensitive: false);
final _highlightExcluded = RegExp(
    r'\b(movie|film|sitcom|news|sportscenter|sports ?centre|previews?|podcast|documentar(?:y|ies)|press conference|talk show)\b',
    caseSensitive: false);
final _highlightIntro = RegExp(
    r'^(?:(?:watch |catch |all |the |latest |extended |match |game |race |daily |weekly |best |action[ -]packed )*)highlights\b|^(?:recapping|catch up on)\b.{0,120}\b(?:action|recap)\b.{0,80}\bhighlights?\b|^[^.!?]{0,65}\bfeatures? (?:action[ -]packed |match |game |the |best |weekly )*highlights\b|^catch up on.{0,100}\bcondensed,? highlight[ -]driven version of the game\b|^(?:(?:รับชม|ชม)\s*)?ไฮไล[ทต]์',
    caseSensitive: false);

final _quickPitch = RegExp(r'^quick pitch(?:\s*[-:]|$)', caseSensitive: false);
final _baseballHighlight =
    RegExp(r'\b(baseball|mlb|major league)\b', caseSensitive: false);
final _matchOfTheDay =
    RegExp(r'^match of the day(?: 2)?(?:\s*[-:]|$)', caseSensitive: false);
final _tourReview = RegExp(r'^(?:ATP|WTA)(?: Tour)? Review(?:\s*[:–-]|$)',
    caseSensitive: false);
final _collegeFinal =
    RegExp(r'^College Football Final(?:\s|$)', caseSensitive: false);
final _highlightRecap = RegExp(
    r'\b(?:looks? back (?:at|on)|recaps?|recapping|breaks? down)\b[^.!?]{0,160}\bhighlights?\b',
    caseSensitive: false);
final _nonCoverage = RegExp(
    r'\b(?:showcasing|explores?|rediscovers?|tours?)\b[^.!?]{0,120}\b(?:golf club|course|layout|history|career)\b|\b(?:championship (?:golf )?(?:course|layout)|instruction|golf lessons)\b',
    caseSensitive: false);
final _datedSubtitle = RegExp(r'^(?:19|20)\d{2}:\s*\S');
final _pokerEpisode =
    RegExp(r'\bS\d{1,4}\s*E\d+\b|\bSeason \d+\b', caseSensitive: false);
final _pokerShow = RegExp(
    r'\b(?:poker after dark|high stakes poker|world poker tour|world series of poker|triton poker|poker masters|pokerstars)\b',
    caseSensitive: false);
final _pokerPlay = RegExp(
    r'\b(?:cash games?|final table|main event|poker players|no[ -]?limit|NLH)\b',
    caseSensitive: false);
bool _recordedPokerEpisode(String title, String description, String? channel) =>
    _pokerShow.hasMatch('$title ${channel ?? ''}') &&
    _pokerEpisode.hasMatch('$title $description') &&
    _pokerPlay.hasMatch(description) &&
    !isExtendedSportFiction(title, description);

bool _mixedSportsHighlights(EpgProgram p) =>
    RegExp(r'^Gotta See It$', caseSensitive: false).hasMatch(p.title.trim()) &&
    RegExp(r'^must[ -]see moments from the world of sports',
            caseSensitive: false)
        .hasMatch((p.description ?? '').trim());

bool _knownHighlights(EpgProgram p) =>
    _mixedSportsHighlights(p) ||
    _tourReview.hasMatch(_plainGuideText(p.title)) ||
    (_collegeFinal.hasMatch(p.title) &&
        RegExp(r'\bpostgame highlights\b', caseSensitive: false)
            .hasMatch(p.description ?? '')) ||
    (_highlightRecap.hasMatch(p.description ?? '') &&
        !isLiveSportsProgramme(p)) ||
    (_quickPitch.hasMatch(p.title) &&
        _baseballHighlight.hasMatch(p.description ?? '')) ||
    _matchOfTheDay.hasMatch(p.title);

/// Explicit highlight coverage only, never a passing mention in a live match,
/// general news or a channel name. Dates of compilation shows are not game dates.
ReplayClassification? _classifySportsHighlights(EpgProgram programme,
    {Channel? channel, _ReplayEligibility? eligibility}) {
  final title = _plainGuideText(programme.title);
  if (extendedSportsPatterns['poker']!.hasMatch(title) &&
      isExtendedSportFiction(title, programme.description ?? '')) {
    return null;
  }
  final description = (programme.description ?? '').trim();
  if (title.isEmpty ||
      _highlightExcluded.hasMatch(title) ||
      _information.hasMatch(title) ||
      _unavailable.hasMatch(title) ||
      _futureSlot.hasMatch(title) ||
      _genericProgramme(programme, channel)) {
    return null;
  }
  final labelled =
      _highlightLabel.hasMatch(title) || _knownHighlights(programme);
  // An explicit highlights synopsis outweighs a stale provider LIVE flag.
  // The anchored pattern does not match incidental "includes highlights"
  // prose inside an otherwise live competition description.
  if (!labelled && !_highlightIntro.hasMatch(description)) {
    return null;
  }
  var sports = _sportsIn(title);
  if (sports.isEmpty && _tourReview.hasMatch(title)) sports = {'tennis'};
  if (sports.isEmpty) {
    sports =
        _sportsIn(description.substring(0, description.length.clamp(0, 600)));
  }
  if (sports.isEmpty && eligibility != null) eligibility.channelMayHelp = true;
  if (sports.isEmpty && channel != null) sports = _channelSports(channel.name);
  // These sports are also common dedicated highlight shows in the guide.
  for (final sport in ['archery']) {
    if (RegExp('\\b$sport\\b', caseSensitive: false)
        .hasMatch('$title $description')) {
      sports.add(sport);
    }
  }
  if (sports.contains('table-tennis')) sports.remove('tennis');
  if (sports.contains('field-hockey')) sports.remove('hockey');
  if (sports.isEmpty && _mixedSportsHighlights(programme)) sports = {'sports'};
  if (sports.length != 1) return null;
  return ReplayClassification(
      sports.single,
      title,
      ReplayEvidence.labelled,
      labelled
          ? 'Highlights listed in the current guide'
          : 'Guide describes a highlights roundup');
}

// Translate evidence only. Keep original provider text and programme identity
// for display, playback, rejection tracking and event-date extraction.
EpgProgram _languageProgramme(EpgProgram p) {
  final title = sportsLanguageText(p.title);
  final raw = p.description;
  final description = raw == null
      ? null
      : raw.length <= 640
          ? sportsLanguageText(raw)
          : '${sportsLanguageText(raw.substring(0, 640))}${raw.substring(640)}';
  if (title == p.title && description == p.description) return p;
  return EpgProgram(
      channelId: p.channelId,
      title: title,
      description: description,
      start: p.start,
      stop: p.stop,
      isLive: p.isLive);
}

ReplayClassification? _originalClassification(ReplayClassification? result,
        EpgProgram original, EpgProgram analysed) =>
    result == null || original.title == analysed.title
        ? result
        : ReplayClassification(result.sport, _plainGuideText(original.title),
            result.evidence, result.reason);

ReplayClassification? _analyseSportsReplay(EpgProgram programme,
    {_ReplayEligibility? eligibility,
    Channel? channel,
    String? dedicatedSport,
    String? matchingGuideSport,
    bool allowLikely = false}) {
  final analysed = _languageProgramme(programme);
  // Keep contradictory LIVE/replay listings out of the replay list. Retain
  // the established explicit local recorded-marker exception.
  if ((programme.isLive ||
          _live.hasMatch(analysed.title) ||
          _liveDescription.hasMatch((analysed.description ?? '').trim())) &&
      !_localRecordedTitle.hasMatch(programme.title) &&
      !_localRecordedIntro.hasMatch((programme.description ?? '').trim())) {
    return null;
  }
  return _originalClassification(
      _classifySportsReplay(analysed,
          eligibility: eligibility,
          channel: channel,
          dedicatedSport: dedicatedSport,
          matchingGuideSport: matchingGuideSport,
          allowLikely: allowLikely),
      programme,
      analysed);
}

ReplayClassification? _analyseSportsHighlights(EpgProgram programme,
    {Channel? channel, _ReplayEligibility? eligibility}) {
  final analysed = _languageProgramme(programme);
  return _originalClassification(
      _classifySportsHighlights(analysed,
          channel: channel, eligibility: eligibility),
      programme,
      analysed);
}

ReplayClassification? classifySportsReplay(EpgProgram programme,
        {Channel? channel,
        String? dedicatedSport,
        String? matchingGuideSport,
        bool allowLikely = false}) =>
    _analyseSportsReplay(programme,
        channel: channel,
        dedicatedSport: dedicatedSport,
        matchingGuideSport: matchingGuideSport,
        allowLikely: allowLikely);

ReplayClassification? classifySportsHighlights(EpgProgram programme,
        {Channel? channel}) =>
    _analyseSportsHighlights(programme, channel: channel);
