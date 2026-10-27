part of 'sports_channel_matcher.dart';

/// One reusable worker owns the expensive index and scoring caches. The UI
/// keeps original channel objects; only metadata crosses the isolate boundary.
/// Guide queries remain on the platform side, never stream/provider requests.
class _BackgroundSportsMatcher extends SportsChannelMatcher
    with WidgetsBindingObserver {
  _BackgroundSportsMatcher(this._source, {super.clock}) : super(_source) {
    WidgetsBinding.instance.addObserver(this);
  }
  final EpgService _source;
  Isolate? _worker;
  ReceivePort? _messages, _faults;
  SendPort? _send;
  Completer<SendPort>? _ready;
  final _pending = <int, Completer<Object?>>{};
  final _progress = <int, void Function(Map<String, List<ChannelMatch>>)>{};
  final _statuses = <int, void Function(SportsWorkProgress)>{};
  final _alternativeChunks = <int, List<ChannelMatch>>{};
  Future<void> _jobs = Future.value();
  Timer? _idle;
  int _nextRequest = 0;
  bool _closed = false, _workerPrepared = false, _trimAfterJob = false;
  bool _running = false;
  Object? _snapshotKey;
  DateTime? _snapshotUntil;
  List<String> _guideIds = const [];
  int _snapshotGeneration = 0;
  List<Channel> _sky = const [];
  final _guideStatuses = <String, String?>{};

  Future<T> _run<T>(Future<T> Function() job) {
    _idle?.cancel();
    final result = _jobs.then((_) async {
      if (_closed) throw StateError('Sports matcher disposed');
      _idle?.cancel();
      _running = true;
      try {
        return await job();
      } finally {
        _running = false;
        if (!_closed) {
          if (_trimAfterJob) {
            _stop();
          } else {
            _idle = Timer(const Duration(minutes: 2), _stop);
          }
        }
      }
    });
    _jobs = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  Future<void> _start() async {
    if (_send != null) return;
    _ready = Completer<SendPort>();
    unawaited(_ready!.future
        .then<void>((_) {}, onError: (Object _, StackTrace __) {}));
    _messages = ReceivePort();
    _faults = ReceivePort();
    _faults!
        .listen((error) => _stop(StateError('Sports worker stopped: $error')));
    _messages!.listen((dynamic message) {
      if (message is SendPort) {
        _ready?.complete(message);
      } else if (message is (int, String, Object?)) {
        final (id, kind, value) = message;
        if (kind == 'guide') {
          unawaited(_queryGuide(id, value));
        } else if (kind == 'progress') {
          _progress[id]?.call(_restoreMatches(value));
        } else if (kind == 'alternativesChunk') {
          _alternativeChunks[id]
              ?.addAll((value as List<ChannelMatch>).map(_restore));
        } else if (kind == 'status') {
          _statuses[id]?.call(value as SportsWorkProgress);
        } else if (kind == 'error') {
          _pending.remove(id)?.completeError(StateError(value.toString()));
        } else {
          _pending.remove(id)?.complete(_alternativeChunks.remove(id) ?? value);
        }
      }
    });
    try {
      _worker = await Isolate.spawn(_sportsWorkerMain, _messages!.sendPort,
          onError: _faults!.sendPort,
          onExit: _faults!.sendPort,
          debugName: 'Sports matching');
      _send = await _ready!.future.timeout(const Duration(seconds: 15));
    } catch (error) {
      _stop(error);
      rethrow;
    }
  }

  Future<Object?> _request(String kind, Object? value,
      {void Function(Map<String, List<ChannelMatch>>)? progress,
      void Function(SportsWorkProgress)? onStatus}) async {
    final id = ++_nextRequest;
    final audit = const bool.fromEnvironment('IPTV_PROFILE_SPORTS')
        ? (Stopwatch()..start())
        : null;
    final done = Completer<Object?>();
    _pending[id] = done;
    if (kind == 'alternatives') _alternativeChunks[id] = [];
    if (progress != null) _progress[id] = progress;
    if (onStatus != null) _statuses[id] = onStatus;
    _send!.send((id, kind, value));
    try {
      return await done.future.timeout(const Duration(minutes: 2),
          onTimeout: () {
        final error = TimeoutException('Sports matching timed out');
        _stop(error);
        throw error;
      });
    } finally {
      if (audit != null && audit.elapsedMilliseconds > 100) {
        debugPrint('IPTV_SPORTS worker=$kind ms=${audit.elapsedMilliseconds}');
      }
      _progress.remove(id);
      _statuses.remove(id);
      _alternativeChunks.remove(id);
    }
  }

  Future<void> _queryGuide(int id, Object? request) async {
    final reply = _send;
    if (reply == null) return;
    try {
      final audit = const bool.fromEnvironment('IPTV_PROFILE_SPORTS')
          ? (Stopwatch()..start())
          : null;
      final (kind, from, to, terms) =
          request as (String, DateTime, DateTime, List<String>);
      final rows = kind == 'titles'
          ? await _source.findProgrammesByTitle(from, to, terms,
              channelIds: _guideIds)
          : await _source.findSportsProgrammesForChannels(terms, from, to);
      if (audit != null) {
        debugPrint(
            'IPTV_SPORTS guide=$kind terms=${terms.length} rows=${rows.length} hours=${to.difference(from).inHours} ms=${audit.elapsedMilliseconds}');
      }
      for (var i = 0; i < rows.length && identical(reply, _send); i += 512) {
        reply.send((id, 'guideChunk', rows.skip(i).take(512).toList()));
        await Future<void>.delayed(Duration.zero);
      }
      if (identical(reply, _send)) {
        reply.send((id, 'guideResult', const <EpgProgram>[]));
      }
    } catch (error) {
      if (identical(reply, _send)) {
        reply.send((id, 'guideError', error.toString()));
      }
    }
  }

  void _stop([Object? error]) {
    _idle?.cancel();
    _idle = null;
    _worker?.kill(priority: Isolate.immediate);
    _worker = null;
    _messages?.close();
    _faults?.close();
    _messages = _faults = null;
    _send = null;
    _workerPrepared = false;
    _snapshotKey = null;
    _trimAfterJob = false;
    final failure = error ?? StateError('Sports worker released');
    if (_ready != null && !_ready!.isCompleted) _ready!.completeError(failure);
    _ready = null;
    for (final pending in _pending.values) {
      pending.completeError(failure);
    }
    _pending.clear();
    _progress.clear();
    _statuses.clear();
    _alternativeChunks.clear();
  }

  @override
  void didHaveMemoryPressure() {
    if (!_running) {
      _stop();
    } else {
      _trimAfterJob = true;
    }
  }

  @override
  void dispose() {
    _closed = true;
    WidgetsBinding.instance.removeObserver(this);
    _stop();
  }

  @override
  Iterable<Channel> get skyTennisChannels => _sky;
  @override
  String? guideStatusFor(SportsGame game) =>
      _guideStatuses[SportsChannelPicks.eventKey(game)];

  @override
  Future<void> prepare(List<Channel> channels,
          {void Function(SportsWorkProgress)? onStatus}) =>
      _run(() async {
        var hash = channels.length;
        final slice = Stopwatch()..start();
        for (var i = 0; i < channels.length; i++) {
          final c = channels[i];
          hash = Object.hash(hash, identityHashCode(c), c.epgId);
          if (i % 256 == 0 && slice.elapsedMilliseconds >= 2) {
            await Future<void>.delayed(Duration.zero);
            slice.reset();
          }
        }
        final signature = '$hash|${channels.length}';
        if (signature != _preparedFor) {
          _channels = List.of(channels);
          _byId = {};
          final guideIds = <String>{};
          for (var i = 0; i < channels.length; i++) {
            _byId[channels[i].id] = i;
            guideIds.add(normalizeEpgId(channels[i].epgId));
            if (i % 256 == 0 && slice.elapsedMilliseconds >= 2) {
              await Future<void>.delayed(Duration.zero);
              slice.reset();
            }
          }
          _guideIds = guideIds.toList();
          _preparedFor = signature;
          _workerPrepared = false;
          _snapshotKey = null;
          _guideStatuses.clear();
          _searchCache.clear();
        }
        await _ensureIndex(onStatus);
      });

  Future<void> _ensureIndex(
      [void Function(SportsWorkProgress)? onStatus]) async {
    final progress = SportsProgressReporter(onStatus);
    await _start();
    if (_workerPrepared) return;
    progress.report(SportsWorkStage.channels, total: _channels.length);
    await _request('beginIndex', null);
    // Bounded copies avoid a single 80k-object send pausing the UI isolate.
    for (var i = 0; i < _channels.length; i += 512) {
      progress.report(SportsWorkStage.channels,
          completed: i, total: _channels.length);
      await _request('indexChunk', [
        for (final c in _channels.skip(i).take(512))
          Channel(
              id: c.id,
              rawId: c.rawId,
              playlistId: '',
              name: c.name,
              group: c.group,
              url: '',
              epgIdOverride: c.epgId)
      ]);
      await Future<void>.delayed(Duration.zero);
    }
    final ids =
        (await _request('finishIndex', onStatus != null, onStatus: onStatus)
                as List)
            .cast<String>();
    _sky = [
      for (final id in ids)
        if (channelById(id) case final channel?) channel
    ];
    _workerPrepared = true;
  }

  @override
  Future<void> primeGuide({void Function(SportsWorkProgress)? onStatus}) =>
      _run(() async {
        await _ensureIndex(onStatus);
        await _syncGuide(onStatus);
      });

  Future<void> _syncGuide([void Function(SportsWorkProgress)? onStatus]) async {
    final progress = SportsProgressReporter(onStatus);
    final now = _clock();
    final key = (
      _source.changeRevision,
      _source.guideRowsLoaded.value,
      _source.lastUpdated,
    );
    if (key == _snapshotKey &&
        _snapshotUntil != null &&
        now.isBefore(_snapshotUntil!)) {
      return;
    }
    var until = now.add(const Duration(minutes: 5));
    void boundary(DateTime at) {
      if (at.isAfter(now) && at.isBefore(until)) until = at;
    }

    final current = <String, EpgProgram>{}, next = <String, EpgProgram>{};
    final slice = Stopwatch()..start();
    progress.report(SportsWorkStage.guideSnapshot, total: _guideIds.length);
    var read = 0;
    for (final id in _guideIds) {
      if (++read % 256 == 0) {
        progress.report(SportsWorkStage.guideSnapshot,
            completed: read, total: _guideIds.length);
      }
      final a = _source.getCurrentProgram(id), b = _source.getNextProgram(id);
      if (a != null) {
        current[id] = _snapshotProgramme(a);
        boundary(a.stop);
      }
      if (b != null) {
        next[id] = _snapshotProgramme(b);
        boundary(b.start);
      }
      if (slice.elapsedMilliseconds >= 2) {
        await Future<void>.delayed(Duration.zero);
        slice.reset();
      }
    }
    await _request('beginGuideSnapshot',
        (++_snapshotGeneration, _source.changeRevision, _source.lastUpdated));
    for (final (isCurrent, rows) in [(true, current), (false, next)]) {
      final entries = rows.entries.toList();
      for (var i = 0; i < entries.length; i += 256) {
        await _request('guideSnapshotChunk', (
          isCurrent,
          Map<String, EpgProgram>.fromEntries(entries.skip(i).take(256))
        ));
        await Future<void>.delayed(Duration.zero);
      }
    }
    _snapshotKey = key;
    _snapshotUntil = until;
  }

  // The scorer already reads at most 640 synopsis characters. Avoid copying
  // longer provider descriptions into its private cache; UI details stay intact.
  EpgProgram _snapshotProgramme(
          EpgProgram p) =>
      (p.description?.length ?? 0) <= 640
          ? p
          : EpgProgram(
              channelId: p.channelId,
              title: p.title,
              start: p.start,
              stop: p.stop,
              isLive: p.isLive,
              description: _guideDescription(p));

  ChannelMatch _restore(ChannelMatch match) => ChannelMatch(
      channelById(match.channel.id) ?? match.channel, match.reason, match.score,
      detail: match.detail,
      programme: match.programme,
      supportingBroadcasts: match.supportingBroadcasts);
  Map<String, List<ChannelMatch>> _restoreMatches(Object? value) =>
      (value as Map<String, List<ChannelMatch>>)
          .map((key, matches) => MapEntry(key, matches.map(_restore).toList()));

  @override
  Future<List<SportsGame>> discoverGuideEvents(
          {void Function(SportsWorkProgress)? onStatus}) =>
      _run(() async {
        await _ensureIndex(onStatus);
        await _syncGuide(onStatus);
        return (await _request('guideEvents', _clock())) as List<SportsGame>;
      });

  @override
  Future<Map<String, List<ChannelMatch>>> matchDay(
          List<SportsGame> games, SportsMatchPicks picks,
          {int limit = 8,
          bool includeGuide = true,
          bool includePossible = false,
          void Function(Map<String, List<ChannelMatch>>)? onProgress,
          void Function(SportsWorkProgress)? onStatus}) =>
      _run(() async {
        await _ensureIndex(onStatus);
        await _syncGuide(onStatus);
        final choices = {
          for (final game in games)
            if (picks.channelIdFor(game) case final id?)
              SportsChannelPicks.eventKey(game): id
        };
        final response = await _request(
            'match',
            (
              games,
              choices,
              limit,
              includeGuide,
              includePossible,
              _clock(),
              onStatus != null
            ),
            progress: onProgress,
            onStatus: onStatus);
        final (matches, statuses) =
            response as (Map<String, List<ChannelMatch>>, Map<String, String?>);
        _guideStatuses.addAll(statuses);
        if (_guideStatuses.length > 2048) {
          _guideStatuses.removeWhere((key, _) => !statuses.containsKey(key));
        }
        return _restoreMatches(matches);
      });

  @override
  List<Channel> search(String query, {int limit = 200}) {
    if (limit <= 0) return const [];
    final key = '${sportsNormalize(query)}|$limit';
    return _searchCache.putIfAbsent(key, () {
      if (_searchCache.length >= 24) {
        _searchCache.remove(_searchCache.keys.first);
      }
      final words = sportsNormalize(query)
          .trim()
          .split(' ')
          .where((w) => w.isNotEmpty)
          .toList();
      return _channels
          .where((c) =>
              !c.name.trimLeft().startsWith('###') &&
              Channel.isLiveId(c.rawId) &&
              words.every(sportsNormalize(c.name).contains))
          .take(limit)
          .toList();
    });
  }

  @override
  Future<List<ChannelMatch>> alternativesFor(SportsGame game,
          {List<ChannelMatch> matches = const [],
          bool Function()? isCancelled}) =>
      _run(() async {
        if (isCancelled?.call() == true) return const [];
        await _ensureIndex();
        await _syncGuide();
        if (isCancelled?.call() == true) return const [];
        final rows = await _request('alternatives', (game, matches, _clock()));
        return isCancelled?.call() == true
            ? const []
            : rows as List<ChannelMatch>;
      });

  @override
  Future<List<ChannelSearchResult>> searchWithGuide(String query,
          {List<ChannelMatch> matches = const [],
          int limit = 200,
          bool Function()? isCancelled}) =>
      _run(() async {
        if (isCancelled?.call() == true) return const [];
        await _ensureIndex();
        await _syncGuide();
        if (isCancelled?.call() == true) return const [];
        final rows = (await _request('search', (query, matches, limit)) as List)
            .cast<ChannelSearchResult>();
        if (isCancelled?.call() == true) return const [];
        return [
          for (final row in rows)
            ChannelSearchResult(channelById(row.channel.id) ?? row.channel,
                match: row.match == null ? null : _restore(row.match!),
                programme: row.programme,
                programmeSearchHit: row.programmeSearchHit)
        ];
      });
}

class _WorkerPicks implements SportsMatchPicks {
  _WorkerPicks(this.choices);
  final Map<String, String> choices;
  @override
  String? channelIdFor(SportsGame game) =>
      choices[SportsChannelPicks.eventKey(game)];
}

class _WorkerGuide implements SportsMatchGuide {
  _WorkerGuide(this.host);
  final SendPort host;
  final pending = <int, Completer<List<EpgProgram>>>{};
  final chunks = <int, List<EpgProgram>>{};
  int sequence = 0;
  @override
  int changeRevision = 0;
  // Snapshot turnover changes current-programme evidence, not the stored
  // schedule. SQL result caches can survive that turnover within their window.
  int queryRevision = 0;
  @override
  DateTime? lastUpdated;
  Map<String, EpgProgram> current = {}, next = {};
  @override
  EpgProgram? getCurrentProgram(String id) => current[normalizeEpgId(id)];
  @override
  EpgProgram? getNextProgram(String id) => next[normalizeEpgId(id)];
  Future<List<EpgProgram>> query(
      String kind, DateTime from, DateTime to, List<String> terms) {
    final id = ++sequence;
    final done = Completer<List<EpgProgram>>();
    pending[id] = done;
    chunks[id] = [];
    host.send((id, 'guide', (kind, from, to, terms)));
    return done.future;
  }

  @override
  Future<List<EpgProgram>> findProgrammesByTitle(
          DateTime from, DateTime to, List<String> terms) =>
      query('titles', from, to, terms);
  @override
  Future<List<EpgProgram>> findSportsProgrammesForChannels(
          List<String> ids, DateTime from, DateTime to) =>
      query('channels', from, to, ids);
}

void _sportsWorkerMain(SendPort host) {
  final port = ReceivePort();
  final guide = _WorkerGuide(host);
  var now = DateTime.now();
  final matcher = SportsChannelMatcher(guide, clock: () => now);
  var channels = <Channel>[];
  Future<void> chain = Future.value();
  host.send(port.sendPort);
  port.listen((dynamic message) {
    final (id, kind, value) = message as (int, String, Object?);
    if (kind == 'guideChunk') {
      guide.chunks[id]?.addAll(value as List<EpgProgram>);
      return;
    }
    if (kind == 'guideResult' || kind == 'guideError') {
      final pending = guide.pending.remove(id);
      final chunks = guide.chunks.remove(id) ?? <EpgProgram>[];
      if (kind == 'guideError') {
        pending?.completeError(StateError(value.toString()));
      } else {
        pending?.complete(chunks..addAll(value as List<EpgProgram>));
      }
      return;
    }
    chain = chain.then((_) async {
      Object? result;
      try {
        switch (kind) {
          case 'beginIndex':
            channels = [];
          case 'indexChunk':
            channels.addAll(value as List<Channel>);
          case 'finishIndex':
            await matcher.prepare(channels,
                onStatus: value == true
                    ? (status) => host.send((id, 'status', status))
                    : null);
            result = matcher.skyTennisChannels.map((c) => c.id).toList();
            channels = [];
          case 'beginGuideSnapshot':
            final (revision, queryRevision, updated) =
                value as (int, int, DateTime?);
            guide.changeRevision = revision;
            guide.queryRevision = queryRevision;
            guide.lastUpdated = updated;
            guide.current = {};
            guide.next = {};
          case 'guideSnapshotChunk':
            final (current, rows) = value as (bool, Map<String, EpgProgram>);
            (current ? guide.current : guide.next).addAll(rows);
          case 'guideEvents':
            now = value as DateTime;
            result = await matcher.discoverGuideEvents();
          case 'match':
            final (games, choices, limit, full, possible, at, reportStatus) =
                value as (
              List<SportsGame>,
              Map<String, String>,
              int,
              bool,
              bool,
              DateTime,
              bool
            );
            now = at;
            final sent = <String>{};
            final matches = await matcher.matchDay(games, _WorkerPicks(choices),
                limit: limit,
                includeGuide: full,
                includePossible: possible,
                onStatus: reportStatus
                    ? (status) => host.send((id, 'status', status))
                    : null, onProgress: (partial) {
              final delta = {
                for (final entry in partial.entries)
                  if (sent.add(entry.key)) entry.key: entry.value
              };
              if (delta.isNotEmpty) host.send((id, 'progress', delta));
            });
            result = (
              matches,
              {
                for (final g in games)
                  SportsChannelPicks.eventKey(g): matcher.guideStatusFor(g)
              }
            );
          case 'alternatives':
            final (game, matches, at) =
                value as (SportsGame, List<ChannelMatch>, DateTime);
            now = at;
            final rows = await matcher.alternativesFor(game, matches: matches);
            // Bound host-side decoding/restoration work, even for unusually
            // large sport categories. The list itself remains lazily rendered.
            for (var i = 0; i < rows.length; i += 128) {
              host.send(
                  (id, 'alternativesChunk', rows.skip(i).take(128).toList()));
              await Future<void>.delayed(Duration.zero);
            }
            result = null;
          case 'search':
            final (query, matches, limit) =
                value as (String, List<ChannelMatch>, int);
            result = await matcher.searchWithGuide(query,
                matches: matches, limit: limit);
          default:
            throw StateError('Unknown sports task');
        }
        host.send((id, 'result', result));
      } catch (error) {
        host.send((id, 'error', error.toString()));
      }
    });
  });
}
