import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:nox_iptv/models/channel.dart';
import 'package:nox_iptv/models/epg_program.dart';
import 'package:nox_iptv/models/sports.dart';
import 'package:nox_iptv/models/sports_progress.dart';
import 'package:nox_iptv/services/epg_service.dart';
import 'package:nox_iptv/services/sports_channel_matcher.dart';
import 'package:nox_iptv/services/storage_service.dart';

class _Guide extends EpgService {
  _Guide(super.storage);
  @override
  int get currentGuideRevision => guideRowsLoaded.value;
  final current = <String, EpgProgram>{};
  Completer<void>? initialLoad;
  @override
  Future<void> get initialCacheReady =>
      initialLoad?.future ?? Future<void>.value();
  @override
  EpgProgram? getCurrentProgram(String id) => current[id];
  int searches = 0;
  final queries = <List<String>>[];
  Completer<List<EpgProgram>>? pending;
  int channelSearches = 0;
  @override
  Future<List<EpgProgram>> findSportsProgrammesForChannels(
      List<String> ids, DateTime from, DateTime to) async {
    channelSearches++;
    final wanted = ids.toSet();
    return (await pending?.future ?? const <EpgProgram>[])
        .where((p) =>
            wanted.contains(p.channelId) &&
            p.start.isBefore(to) &&
            p.stop.isAfter(from))
        .toList();
  }

  @override
  Future<List<EpgProgram>> findProgrammesByTitle(
      DateTime from, DateTime to, List<String> terms,
      {List<String>? channelIds}) async {
    searches++;
    queries.add(List.of(terms));
    if (pending == null) return [];
    return pending!.future;
  }
}

class _CountingGuide extends _Guide {
  _CountingGuide(super.storage);
  int reads = 0;
  void Function()? onRead;
  @override
  EpgProgram? getCurrentProgram(String id) {
    reads++;
    onRead?.call();
    return super.getCurrentProgram(id);
  }
}

Channel channel(int i, [String? name]) => Channel(
    id: 'p::$i',
    rawId: '$i',
    playlistId: 'p',
    name: name ?? 'UK: Entertainment Channel $i HD',
    group: 'Live',
    url: 'https://example.test/$i');
SportsGame game(
        {String score = '1', List<String> broadcasts = const ['ESPN']}) =>
    SportsGame(
        id: 'game',
        league: kSportsLeagues.first,
        start: DateTime.utc(2026, 10, 21, 12),
        state: GameState.live,
        statusText: 'Live',
        broadcasts: broadcasts,
        home: SportsTeam(
            id: 'h',
            name: 'Boston Bruins',
            shortName: 'Bruins',
            abbreviation: 'BOS',
            score: score),
        away: const SportsTeam(
            id: 'a',
            name: 'Toronto Maple Leafs',
            shortName: 'Maple Leafs',
            abbreviation: 'TOR'));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late StorageService storage;
  late _Guide guide;
  late SportsChannelMatcher matcher;
  late SportsChannelPicks picks;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    storage = StorageService();
    await storage.init();
    guide = _Guide(storage);
    matcher = SportsChannelMatcher(guide);
    picks = SportsChannelPicks.load(storage);
  });
  tearDown(() => guide.dispose());

  test('worker publishes guide events during SQL and preserves exact matches',
      () async {
    final now = DateTime.utc(2026, 10, 21, 12, 30);
    final programme = EpgProgram(
        channelId: '1',
        title: 'Boston Bruins vs Toronto Maple Leafs',
        start: now.subtract(const Duration(minutes: 30)),
        stop: now.add(const Duration(hours: 2)),
        isLive: true);
    guide.current['1'] = programme;
    guide.current['2'] = EpgProgram(
        channelId: '2',
        title: 'Live Badminton World Tour',
        start: now.subtract(const Duration(minutes: 10)),
        stop: now.add(const Duration(hours: 2)),
        isLive: true);
    guide.pending = Completer<List<EpgProgram>>();
    final channels = [channel(1, 'ESPN'), channel(2, 'Sports Extra')];
    final worker = SportsChannelMatcher.background(guide, clock: () => now);
    addTearDown(worker.dispose);
    await worker.prepare(channels);
    final discovered = Completer<List<SportsGame>>();
    var completed = false;
    final partial = Completer<SportsGuideDiscovery>();
    final matching = worker.matchDay([game()], picks, includePossible: true,
        onGuideProgress: (update) {
      if (!update.complete && !partial.isCompleted) partial.complete(update);
    }, onGuideEvents: discovered.complete).then((value) {
      completed = true;
      return value;
    });
    final first = await partial.future.timeout(const Duration(seconds: 5));
    expect(
        first.matches.values.expand((rows) => rows).any((m) => m.isConfident),
        isTrue);
    expect(completed, isFalse);
    final events = await discovered.future.timeout(const Duration(seconds: 5));
    expect(events.map((g) => g.title), contains('Live Badminton World Tour'));
    expect(completed, isFalse);
    expect(guide.pending!.isCompleted, isFalse);
    guide.pending!.complete([programme]);
    final result = await matching;
    final reference = SportsChannelMatcher(guide, clock: () => now);
    addTearDown(reference.dispose);
    await reference.prepare(channels);
    final expected =
        await reference.matchDay([game()], picks, includePossible: true);
    for (final key in expected.keys) {
      expect([for (final m in result[key]!) (m.channel.id, m.reason, m.score)],
          [for (final m in expected[key]!) (m.channel.id, m.reason, m.score)]);
    }
    final reads = guide.searches;
    await worker.matchDay([game()], picks,
        includePossible: true,
        onGuideEvents: (again) =>
            expect(again.map((g) => g.id), events.map((g) => g.id)));
    expect(guide.searches, reads,
        reason:
            'Discovery must not replace or invalidate scored fixture caches');
  });

  for (final condition in ['refreshing', 'failed', 'uninitialised']) {
    test('early hints cannot persist an $condition guide snapshot', () async {
      final now = DateTime.utc(2026, 10, 21, 12, 30);
      final dir = await Directory.systemTemp.createTemp('sports-cache-policy-');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/matches.json');
      guide.lastUpdated = condition == 'uninitialised' ? null : now;
      guide.isLoading = condition == 'refreshing';
      guide.error = condition == 'failed' ? 'Unavailable' : null;
      final worker = SportsChannelMatcher.background(guide,
          clock: () => now, cachePath: file.path);
      addTearDown(worker.dispose);
      await worker.prepare([channel(1, 'ESPN')]);
      await worker.matchDay([game()], picks,
          includeGuide: false, includePossible: true);
      await worker.matchDay([game()], picks, includePossible: true);
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(await file.exists(), isFalse);
    });
  }

  test('refresh starting during snapshot transfer prevents disk persistence',
      () async {
    final now = DateTime.utc(2026, 10, 21, 12, 30);
    final dir = await Directory.systemTemp.createTemp('sports-cache-policy-');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/matches.json');
    final changing = _CountingGuide(storage)..lastUpdated = now;
    changing.onRead = () => changing.isLoading = true;
    addTearDown(changing.dispose);
    final worker = SportsChannelMatcher.background(changing,
        clock: () => now, cachePath: file.path);
    addTearDown(worker.dispose);
    await worker.prepare([channel(1, 'ESPN')]);
    await worker.matchDay([game()], picks, includePossible: true);
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(await file.exists(), isFalse);
  });

  test('early hints promote an unchanged snapshot to persistent full matching',
      () async {
    final now = DateTime.utc(2026, 10, 21, 12, 30);
    final dir = await Directory.systemTemp.createTemp('sports-cache-policy-');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/matches.json');
    final counted = _CountingGuide(storage)..lastUpdated = now;
    addTearDown(counted.dispose);
    final channels = [channel(1, 'ESPN')];
    final p = EpgProgram(
        channelId: channels.single.epgId,
        title: 'Boston Bruins vs Toronto Maple Leafs',
        start: now.subtract(const Duration(hours: 1)),
        stop: now.add(const Duration(hours: 1)));
    counted.current[p.channelId] = p;
    counted.pending = Completer<List<EpgProgram>>()..complete([p]);
    SportsChannelMatcher worker() => SportsChannelMatcher.background(counted,
        clock: () => now, cachePath: file.path);
    final first = worker();
    addTearDown(first.dispose);
    await first.prepare(channels);
    await first
        .matchDay([game()], picks, includeGuide: false, includePossible: true);
    final reads = counted.reads;
    final result = await first.matchDay([game()], picks, includePossible: true);
    expect(counted.reads, reads,
        reason: 'Policy promotion must not copy the guide again');
    expect(result.values.single, isNotEmpty);
    for (var i = 0; i < 30 && !await file.exists(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 30));
    }
    expect(await file.exists(), isTrue,
        reason: 'Full results must survive a worker/process restart');
    expect(
        (jsonDecode(await file.readAsString()) as Map)['entries'], isNotEmpty);
    first.dispose();
    final searches = counted.searches;
    final second = worker();
    addTearDown(second.dispose);
    await second.prepare(channels);
    final restored =
        await second.matchDay([game()], picks, includePossible: true);
    expect(restored.values.single.first.channel.id,
        result.values.single.first.channel.id);
    expect(counted.searches, searches,
        reason: 'Fresh saved matches avoid another SQL search');
  });

  test('worker joins initial guide preload before querying or snapshotting',
      () async {
    guide.initialLoad = Completer<void>();
    final worker = SportsChannelMatcher.background(guide);
    addTearDown(worker.dispose);
    await worker.prepare([channel(1, 'NHL Network')]);
    final pending = worker.matchDay([game()], picks);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(guide.searches, 0);
    expect(guide.channelSearches, 0);
    guide.initialLoad!.complete();
    await pending.timeout(const Duration(seconds: 5));
    expect(guide.searches, 1);
  });

  test(
      'current guide suggestions arrive before SQL and cannot replace full results',
      () async {
    final now = DateTime.now().toUtc();
    final g = SportsGame(
        id: 'early',
        league: sportsLeagueById('nhl')!,
        start: now.subtract(const Duration(minutes: 10)),
        state: GameState.live,
        statusText: 'Live',
        home: game().home,
        away: game().away);
    final channels = [channel(1, 'Sports Feed'), channel(2, 'Another Feed')];
    final p = EpgProgram(
        channelId: channels.first.epgId,
        title: 'NHL: Boston Bruins vs Toronto Maple Leafs',
        start: now.subtract(const Duration(minutes: 20)),
        stop: now.add(const Duration(hours: 2)));
    guide.current[p.channelId] = p;
    guide.pending = Completer<List<EpgProgram>>();
    final worker = SportsChannelMatcher.background(guide, clock: () => now);
    addTearDown(worker.dispose);
    await worker.prepare(channels);
    final early = Completer<Map<String, List<ChannelMatch>>>();
    final completed =
        worker.matchDay([g], picks, includePossible: true, onProgress: (rows) {
      if (!early.isCompleted && rows.values.any((v) => v.isNotEmpty)) {
        early.complete(rows);
      }
    });
    final preview = await early.future.timeout(const Duration(seconds: 5));
    expect(guide.pending!.isCompleted, isFalse);
    expect(guide.searches, 1,
        reason: 'Full guide reads start before provisional scoring finishes');
    final suggestions = preview[SportsChannelPicks.eventKey(g)]!;
    expect(suggestions.first.channel.id, channels.first.id);
    expect(suggestions.first.isConfident, isFalse,
        reason:
            'A current-guide preview is not a completed full-schedule check');
    guide.pending!.complete([p]);
    final result = await completed;
    expect(result[SportsChannelPicks.eventKey(g)]!.first.isConfident, isTrue);
    final reference = SportsChannelMatcher(guide, clock: () => now);
    addTearDown(reference.dispose);
    await reference.prepare(channels);
    final expected =
        await reference.matchDay([g], picks, includePossible: true);
    Object signature(Map<String, List<ChannelMatch>> rows) => {
          for (final entry in rows.entries)
            entry.key: [
              for (final m in entry.value)
                (
                  m.channel.id,
                  m.reason,
                  m.score,
                  m.detail,
                  m.programme?.title,
                  m.programme?.start
                )
            ]
        };
    expect(signature(result), signature(expected));
    expect(signature(await worker.matchDay([g], picks, includePossible: true)),
        signature(expected),
        reason: 'The preview must not poison the full cache');
  });

  test('failed overlapping guide read remains retryable after preview',
      () async {
    final now = DateTime.utc(2026, 10, 21, 12, 30);
    final channels = [channel(1, 'Sports Feed')];
    final programme = EpgProgram(
        channelId: channels.single.epgId,
        title: 'NHL: Boston Bruins vs Toronto Maple Leafs',
        start: now.subtract(const Duration(hours: 1)),
        stop: now.add(const Duration(hours: 1)));
    guide.current[programme.channelId] = programme;
    guide.pending = Completer<List<EpgProgram>>();
    final worker = SportsChannelMatcher.background(guide, clock: () => now);
    addTearDown(worker.dispose);
    await worker.prepare(channels);
    final early = Completer<void>();
    final failed = worker.matchDay([game()], picks, includePossible: true,
        onProgress: (rows) {
      if (!early.isCompleted && rows.values.any((v) => v.isNotEmpty)) {
        early.complete();
        guide.pending!.completeError(StateError('Guide read failed'));
      }
    });
    await expectLater(failed,
        throwsA(predicate((e) => e.toString().contains('Guide read failed'))));
    expect(early.isCompleted, isTrue);
    guide.pending = Completer<List<EpgProgram>>()..complete([programme]);
    final retried = await worker
        .matchDay([game()], picks, includePossible: true, onProgress: (_) {});
    expect(guide.searches, 2,
        reason: 'A failed read cannot remain in the query cache');
    expect(retried.values.single.first.isConfident, isTrue);
    expect(retried.values.single.first.programme?.title, programme.title);
  });

  test('tennis coverage lookup starts while the title query is pending',
      () async {
    await matcher.prepare([channel(1, 'UK: Sky Sports Tennis HD')]);
    guide.pending = Completer<List<EpgProgram>>();
    final tennis = SportsGame(
        id: 'tennis',
        league: sportsLeagueById('tennis.atp')!,
        start: game().start,
        state: GameState.live,
        statusText: 'Live',
        home: game().home,
        away: game().away);
    final matching = matcher.matchDay([tennis], picks, includePossible: true);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(guide.searches, 1);
    expect(guide.channelSearches, 1,
        reason: 'independent coverage reads must not wait for title results');
    guide.pending!.complete([]);
    await matching;
    await matcher.matchDay([tennis], picks, includePossible: true);
    expect(guide.searches, 1);
    expect(guide.channelSearches, 1);
  });

  test(
      'background worker preserves scoring, original channels, picks and restart',
      () async {
    final worker = SportsChannelMatcher.background(guide);
    addTearDown(worker.dispose);
    final channels = [
      channel(1, 'ESPN'),
      channel(2, 'Boston Bruins vs Toronto Maple Leafs')
    ];
    await matcher.prepare(channels);
    await worker.prepare(channels);
    final direct =
        await matcher.matchDay([game()], picks, includePossible: true);
    final background =
        await worker.matchDay([game()], picks, includePossible: true);
    List<Object?> signature(Map<String, List<ChannelMatch>> result) => [
          for (final m in result['nhl:game']!)
            [m.channel.id, m.reason, m.score, m.programme?.title]
        ];
    expect(signature(background), signature(direct));
    expect(background['nhl:game']!.first.channel, same(channels[1]));
    final queries = guide.searches;
    await worker.matchDay([game(score: '9')], picks, includePossible: true);
    expect(guide.searches, queries);
    await picks.pickForGame(game(), channels[0].id);
    final picked = await worker.matchDay([game()], picks);
    expect(picked['nhl:game']!.first.reason, MatchReason.pick);
    expect(picked['nhl:game']!.first.channel, same(channels[0]));
    final search =
        await worker.searchWithGuide('Boston', matches: picked['nhl:game']!);
    expect(search.single.channel, same(channels[1]));
    (worker as WidgetsBindingObserver).didHaveMemoryPressure();
    final restarted = await worker.matchDay([game()], picks);
    expect(restarted['nhl:game']!.first.channel, same(channels[0]));
    expect(restarted['nhl:game']!.first.reason, MatchReason.pick);
  });

  test('worker refreshes current-guide evidence in bounded snapshot batches',
      () async {
    final worker = SportsChannelMatcher.background(guide);
    addTearDown(worker.dispose);
    final channels = List.generate(1100, channel);
    channels[0] = channel(0, 'ESPN');
    await worker.prepare(channels);
    final first = await worker.matchDay([game()], picks);
    expect(first['nhl:game']!.first.channel, same(channels[0]));
    for (var i = 0; i < channels.length; i++) {
      guide.current['$i'] = EpgProgram(
          channelId: '$i',
          title: 'WTA Tennis',
          description: 'Coverage ${'notes ' * 200}',
          start: game().start.subtract(const Duration(hours: 1)),
          stop: game().start.add(const Duration(hours: 3)));
    }
    guide.guideRowsLoaded.value++;
    final refreshed = await worker.matchDay([game()], picks);
    expect(refreshed['nhl:game'], isEmpty,
        reason:
            'new cached guide evidence overrides broad broadcaster coverage');
    expect(guide.searches, 1,
        reason: 'new current-guide evidence does not change stored SQL rows');
  });

  test(
      'guide snapshots deduplicate feeds and survive minute ticks until evidence changes',
      () async {
    final counted = _CountingGuide(storage);
    addTearDown(counted.dispose);
    var now = game().start.add(const Duration(seconds: 10));
    final worker = SportsChannelMatcher.background(counted, clock: () => now);
    addTearDown(worker.dispose);
    counted.current['shared0'] = EpgProgram(
        channelId: 'shared0',
        title: 'Boston Bruins vs Toronto Maple Leafs',
        start: game().start,
        stop: game().start.add(const Duration(minutes: 3)));
    final channels = [
      for (var i = 0; i < 600; i++)
        Channel(
            id: 'copy$i',
            rawId: 'copy$i',
            playlistId: 'p',
            name: 'ESPN',
            group: 'Sport',
            epgIdOverride: 'shared${i % 20}',
            url: 'https://example.invalid')
    ];
    await worker.prepare(channels);
    await Future.wait([worker.primeGuide(), worker.primeGuide()]);
    expect(counted.reads, 20,
        reason: 'overlapping preparation shares one snapshot');
    expect(counted.searches, 0,
        reason: 'no speculative searches before events');
    await worker.matchDay([game()], picks);
    expect(counted.reads, 20, reason: 'matching reuses the prepared snapshot');
    now = now.add(const Duration(minutes: 1));
    await worker.matchDay([game()], picks);
    expect(counted.reads, 20, reason: 'minute rollover is not a guide change');
    now = game().start.add(const Duration(minutes: 3));
    counted.current['shared0'] = EpgProgram(
        channelId: 'shared0',
        title: 'WTA Tennis',
        start: now,
        stop: now.add(const Duration(hours: 1)));
    await worker.matchDay([game()], picks);
    expect(counted.reads, 40, reason: 'programme boundary refreshes snapshot');
    expect(counted.searches, 1,
        reason: 'same query window survives current-programme turnover');
    counted.guideRowsLoaded.value++;
    await worker.matchDay([game()], picks);
    expect(counted.reads, 60, reason: 'new guide rows invalidate immediately');
    expect(counted.searches, 1);
    counted.notifyListeners();
    await worker.matchDay([game()], picks);
    expect(counted.searches, 2,
        reason: 'a stored guide update must requery immediately');
  });

  test('disposing a worker releases an in-flight guide request without hanging',
      () async {
    final worker = SportsChannelMatcher.background(guide);
    await worker.prepare([channel(1, 'ESPN')]);
    guide.pending = Completer<List<EpgProgram>>();
    final running = worker.matchDay([game()], picks);
    final failed = expectLater(running, throwsStateError);
    while (guide.searches == 0) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    worker.dispose();
    await failed;
    guide.pending!.complete([]);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    final replacement = SportsChannelMatcher.background(guide);
    addTearDown(replacement.dispose);
    await replacement.prepare([channel(1, 'ESPN')]);
    expect(
        (await replacement.matchDay([game()], picks))['nhl:game'], isNotEmpty);
  });

  test(
      '80k channel indexing yields to input and concurrent callers see a complete index',
      () async {
    final channels = List.generate(80000, channel);
    channels[40000] = channel(40000, 'US: ESPN HD');
    var ticks = 0;
    final heartbeat =
        Timer.periodic(const Duration(milliseconds: 1), (_) => ticks++);
    final watch = Stopwatch()..start();
    await Future.wait([matcher.prepare(channels), matcher.prepare(channels)]);
    final cold = watch.elapsedMilliseconds;
    final result = await matcher.matchDay([game()], picks, includeGuide: false);
    expect(result['nhl:game']!.first.channel.id, 'p::40000');
    expect(ticks, greaterThan(1));
    watch.reset();
    await matcher.prepare(List.of(channels));
    final warm = watch.elapsedMilliseconds;
    heartbeat.cancel();
    // Timings are diagnostics, not a machine-dependent pass/fail threshold.
    debugPrint(
        '80k channels: cold index ${cold}ms; unchanged index ${warm}ms; event-loop ticks $ticks');
  });
  test(
      'progressive batches reuse unchanged events and invalidate on guide changes',
      () async {
    await matcher.prepare([channel(1, 'ESPN'), channel(2, 'NHL Network')]);
    final firstGame = game();
    final secondGame = SportsGame(
        id: 'second',
        league: firstGame.league,
        start: firstGame.start,
        state: firstGame.state,
        statusText: 'Live',
        home: const SportsTeam(
            id: 'oil',
            name: 'Edmonton Oilers',
            shortName: 'Oilers',
            abbreviation: 'EDM'),
        away: const SportsTeam(
            id: 'can',
            name: 'Vancouver Canucks',
            shortName: 'Canucks',
            abbreviation: 'VAN'));
    final first = await matcher.matchDay([firstGame], picks);
    final both = await matcher.matchDay([firstGame, secondGame], picks);
    expect(identical(first['nhl:game'], both['nhl:game']), true);
    expect(guide.searches, 2);
    expect(
        guide.queries.last
            .any((t) => t.contains('boston') || t.contains('bruins')),
        false);
    await matcher.matchDay([secondGame], picks);
    expect(guide.searches, 2);
    guide.lastUpdated = DateTime.now();
    await matcher.matchDay([firstGame, secondGame], picks);
    expect(guide.searches, 3);
  });

  test(
      'possible coverage is opt-in, separately labelled and below event evidence',
      () async {
    await matcher.prepare([channel(1, 'NHL Network'), channel(2, 'ESPN')]);
    final strict = await matcher.matchDay([game()], picks);
    expect(strict.values.single.map((m) => m.channel.rawId), ['2']);
    final possible =
        await matcher.matchDay([game()], picks, includePossible: true);
    expect(possible.values.single.first.channel.rawId, '2');
    expect(possible.values.single.first.isConfident, true);
    expect(possible.values.single.last.channel.rawId, '1');
    expect(possible.values.single.last.isConfident, false);
    expect((await matcher.matchDay([game()], picks)).values.single.length, 1);
  });

  test('background catalogue changes invalidate scoped guide search results',
      () async {
    final worker = SportsChannelMatcher.background(guide);
    addTearDown(worker.dispose);
    await worker.prepare([channel(1, 'ESPN')]);
    await worker.matchDay([game()], picks);
    expect(guide.searches, 1);
    await worker.prepare([channel(1, 'ESPN'), channel(2, 'Sports')]);
    await worker.matchDay([game()], picks);
    expect(guide.searches, 2,
        reason: 'newly enabled guide IDs were absent from the previous search');
  });

  test('a middle channel replacement invalidates the index and match cache',
      () async {
    final channels = [channel(1), channel(2, 'ESPN'), channel(3)];
    await matcher.prepare(channels);
    expect((await matcher.matchDay([game()], picks))['nhl:game'], isNotEmpty);
    channels[1] = channel(2, 'Discovery');
    await matcher.prepare(channels);
    expect((await matcher.matchDay([game()], picks))['nhl:game'], isEmpty);
  });
  test(
      'quick matches do not wait for the guide and score changes reuse full matches',
      () async {
    await matcher.prepare([channel(1, 'ESPN'), channel(2, 'Sky Sports')]);
    guide.pending = Completer();
    final quick = await matcher.matchDay([game()], picks, includeGuide: false);
    expect(quick['nhl:game']!.first.channel.name, 'ESPN');
    expect(guide.searches, 0);
    final fullFuture = matcher.matchDay([game()], picks);
    await Future<void>.delayed(Duration.zero);
    expect(guide.searches, 1);
    guide.pending!.complete([]);
    final full = await fullFuture;
    final refreshed = await matcher.matchDay([game(score: '2')], picks);
    expect(identical(refreshed, full), true);
    expect(guide.searches, 1);
    await picks.pickForGame(game(), 'p::2');
    final changed = await matcher.matchDay([game()], picks);
    expect(changed['nhl:game']!.first.channel.name, 'Sky Sports');
    expect(changed['nhl:game']!.first.reason, MatchReason.pick);
  });

  test('new tennis tournaments do not invalidate completed team-sport checks',
      () async {
    await matcher.prepare([channel(1, 'ESPN')]);
    final teamGame = game();
    final first = await matcher.matchDay([teamGame], picks);
    final tennis = SportsGame(
        id: 'tennis-extra',
        league: sportsLeagueById('tennis.atp')!,
        start: teamGame.start,
        state: GameState.live,
        statusText: 'Live',
        home: teamGame.home,
        away: teamGame.away,
        event: const SportsEventInfo(title: 'European Open'));
    final progress = <Map<String, List<ChannelMatch>>>[];
    final result = await matcher
        .matchDay([teamGame, tennis], picks, onProgress: progress.add);
    expect(identical(first['nhl:game'], result['nhl:game']), true);
    expect(progress, isNotEmpty);
    // Cached final matches stay identical. During a new batch, weak network
    // evidence remains provisional until shared-feed conflicts are checked.
    expect(progress.first['nhl:game']!.single.channel,
        same(first['nhl:game']!.single.channel));
    expect(progress.first['nhl:game']!.single.isConfident, false);
    // The cached event is selectable before the extra fixture is checked.
    expect(progress.first.keys, contains('nhl:game'));
  });

  test('first tennis channel is published before the next fixture is scored',
      () async {
    final now = DateTime.now().toUtc();
    SportsGame tennis(String id, String home, String away) => SportsGame(
        id: id,
        league: sportsLeagueById('tennis.atp')!,
        start: now,
        state: GameState.live,
        statusText: 'Live',
        home:
            SportsTeam(id: home, name: home, shortName: home, abbreviation: ''),
        away:
            SportsTeam(id: away, name: away, shortName: away, abbreviation: ''),
        event: const SportsEventInfo(title: 'European Open'));
    final first = tennis('first', 'Casper Ruud', 'Novak Djokovic');
    final second = tennis('second', 'Jannik Sinner', 'Carlos Alcaraz');
    final worker = SportsChannelMatcher.background(guide);
    addTearDown(worker.dispose);
    for (final engine in [matcher, worker]) {
      await engine.prepare([
        channel(1, 'Tennis: Casper Ruud vs Novak Djokovic'),
        channel(2, 'Tennis: Jannik Sinner vs Carlos Alcaraz')
      ]);
      final batches = <Map<String, List<ChannelMatch>>>[];
      final result = await engine.matchDay([first, second], picks,
          includeGuide: false, includePossible: true, onProgress: batches.add);
      expect(batches, isNotEmpty);
      expect(batches.first['tennis.atp:first'], isNotEmpty);
      expect(batches.first.containsKey('tennis.atp:second'), isFalse);
      expect(batches.first['tennis.atp:first']!.first.isConfident, isFalse,
          reason: 'Shared-feed conflicts have not all been checked yet');
      expect(result['tennis.atp:first']!.first.isConfident, isTrue);
      expect(result['tennis.atp:second']!.first.isConfident, isTrue);
    }
  });

  test(
      'busy tournament and large guide stay responsive and reuse cached results',
      () async {
    final channels = List.generate(80000, channel);
    final league = sportsLeagueById('tennis.atp')!;
    final start = DateTime.now().toUtc().subtract(const Duration(minutes: 20));
    final games = [
      for (var i = 0; i < 60; i++)
        SportsGame(
            id: '$i',
            league: league,
            start: start,
            state: GameState.live,
            statusText: 'Live',
            home: SportsTeam(
                id: 'a$i',
                name: 'Player Alpha$i',
                shortName: 'Alpha$i',
                abbreviation: ''),
            away: SportsTeam(
                id: 'b$i',
                name: 'Player Beta$i',
                shortName: 'Beta$i',
                abbreviation: ''),
            event: const SportsEventInfo(title: 'Shanghai Masters')),
    ];
    for (var i = 0; i < games.length; i++) {
      channels[i] = channel(i, 'ATP Shanghai: Alpha$i vs Beta$i');
    }
    await matcher.prepare(channels);
    guide.pending = Completer()
      ..complete([
        for (var i = 0; i < 10000; i++)
          EpgProgram(
              channelId: '$i',
              title: i < 60
                  ? 'ATP: Alpha$i vs Beta$i'
                  : i.isEven
                      ? 'ATP Shanghai Tennis: Court $i'
                      : 'Tennis interviews $i',
              start: start,
              stop: start.add(const Duration(hours: 3))),
      ]);
    var ticks = 0;
    final heartbeat =
        Timer.periodic(const Duration(milliseconds: 1), (_) => ticks++);
    final clock = Stopwatch()..start();
    final result = await matcher.matchDay(games, picks, includePossible: true);
    final coldMs = clock.elapsedMilliseconds;
    heartbeat.cancel();
    for (var i = 0; i < games.length; i++) {
      expect(result['tennis.atp:$i']!.first.channel.id, 'p::$i');
      expect(result['tennis.atp:$i']!.first.reason, MatchReason.guide);
    }
    expect(ticks, greaterThan(1));
    expect(guide.searches, 1);
    clock.reset();
    expect(
        identical(await matcher.matchDay(games, picks, includePossible: true),
            result),
        isTrue);
    expect(guide.searches, 1);
    expect(guide.channelSearches, 1);
    debugPrint('80k channels / 10k guide rows / 60 games: match ${coldMs}ms; '
        'cached ${clock.elapsedMicroseconds}us; event-loop ticks $ticks');
    final background = SportsChannelMatcher.background(guide);
    addTearDown(background.dispose);
    clock.reset();
    final statuses = <SportsWorkProgress>[];
    await background.prepare(channels, onStatus: statuses.add);
    final indexMs = clock.elapsedMilliseconds;
    final gaps = <int>[];
    final pulseClock = Stopwatch()..start();
    var previous = 0;
    final pulse = Timer.periodic(const Duration(milliseconds: 2), (_) {
      final current = pulseClock.elapsedMicroseconds;
      gaps.add(current - previous);
      previous = current;
    });
    clock.reset();
    await background.primeGuide(onStatus: statuses.add);
    final primeMs = clock.elapsedMilliseconds;
    clock.reset();
    final offThread = await background.matchDay(games, picks,
        includePossible: true, onStatus: statuses.add);
    final workerMs = clock.elapsedMilliseconds;
    expect(statuses.any((s) => s.stage == SportsWorkStage.verifying), true);
    expect(statuses.length, lessThan(40),
        reason: 'Progress sends bounded metadata, not per-channel messages');
    pulse.cancel();
    for (final key in result.keys) {
      expect([
        for (final m in offThread[key]!) [m.channel.id, m.reason, m.score]
      ], [
        for (final m in result[key]!) [m.channel.id, m.reason, m.score]
      ]);
      for (final m in offThread[key]!) {
        expect(channels.contains(m.channel), true);
      }
    }
    gaps.sort();
    expect(gaps.length, greaterThan(10));
    debugPrint(
        'Background 80k / 10k / 60: index ${indexMs}ms; prepare guide ${primeMs}ms; match ${workerMs}ms; '
        'UI heartbeat p95 ${gaps[(gaps.length * .95).floor()]}us; max ${gaps.last}us; ticks ${gaps.length}');
  });
}
