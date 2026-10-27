import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:nox_iptv/models/channel.dart';
import 'package:nox_iptv/models/epg_program.dart';
import 'package:nox_iptv/models/sports.dart';
import 'package:nox_iptv/models/sports_progress.dart';
import 'package:nox_iptv/screens/sports_live_list_screen.dart';
import 'package:nox_iptv/services/app_preferences.dart';
import 'package:nox_iptv/services/sports_channel_matcher.dart';
import 'package:nox_iptv/services/sports_follows.dart';
import 'package:nox_iptv/services/sports_service.dart';
import 'package:nox_iptv/services/storage_service.dart';
import 'package:nox_iptv/utils/sports_channel_filter.dart';

class _Scores extends SportsService {
  _Scores()
      : super.withClient(MockClient((_) async => http.Response('{}', 200)));
  final requests = <Completer<List<SportsGame>>>[];
  int prefetches = 0;
  @override
  void prefetchSummary(SportsGame game) {
    prefetches++;
  }

  @override
  Future<List<SportsGame>> gamesForDay(List<SportsLeague> leagues, DateTime day,
      {void Function(List<SportsGame>)? onProgress,
      bool forceRefresh = false,
      void Function(SportsWorkProgress)? onStatus}) {
    final result = Completer<List<SportsGame>>();
    requests.add(result);
    return result.future;
  }
}

void main() {
  final now = DateTime.now();
  final league = sportsLeagueById('nhl')!;
  SportsGame game(String id, {GameState state = GameState.live}) => SportsGame(
      id: id,
      league: league,
      start: now,
      state: state,
      statusText: 'Live',
      home: SportsTeam(
          id: id, name: 'Home $id', shortName: 'Home $id', abbreviation: 'H'),
      away: const SportsTeam(
          id: 'away', name: 'Away', shortName: 'Away', abbreviation: 'A'));
  final games = [
    game('confirmed'),
    game('possible'),
    game('unmatched'),
    for (var i = 0; i < 200; i++) game('later-$i', state: GameState.pre)
  ];
  final channel = Channel(
      id: 'feed',
      rawId: 'feed',
      playlistId: 'test',
      name: 'Sports Feed',
      group: 'Sports',
      url: 'https://example.invalid/never-play');
  final matches = {
    'nhl:confirmed': [ChannelMatch(channel, MatchReason.guide, 500)],
    'nhl:possible': [ChannelMatch(channel, MatchReason.sport, 80)],
    'nhl:unmatched': <ChannelMatch>[],
  };
  late StorageService storage;
  late AppPreferences prefs;
  late _Scores scores;
  late DateTime clock;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    storage = StorageService();
    await storage.init();
    prefs = AppPreferences(storage);
    await prefs.init();
    prefs.isTelevision = false;
    scores = _Scores();
    clock = now;
  });
  tearDown(() {
    prefs.dispose();
  });
  Widget app(
          SportsChannelFilter filter,
          Future<Map<String, List<ChannelMatch>>> Function(List<SportsGame>)
              match,
          {bool empty = false,
          Map<String, List<ChannelMatch>>? initialMatches}) =>
      ChangeNotifierProvider.value(
          value: prefs,
          child: MaterialApp(
              home: SportsLiveListScreen(
                  leagues: [league],
                  day: now,
                  follows: SportsFollows.load(storage),
                  hideScores: true,
                  channelFilter: filter,
                  scores: scores,
                  clock: () => clock,
                  initialGames: empty
                      ? []
                      : games
                          .where((g) =>
                              g.state == GameState.live &&
                              filter.accepts(matches['nhl:${g.id}'] ?? [],
                                  pending: false))
                          .toList(),
                  initialMatches: initialMatches ?? matches,
                  matchGames: match,
                  onWatch: (_) async {},
                  onMenu: (_, __, ___) async {})));
  List<String?> rows(WidgetTester tester) => tester
      .widgetList<InkWell>(find.byType(InkWell))
      .map((w) => w.focusNode?.debugLabel)
      .where((s) => s?.startsWith('sports-live-') ?? false)
      .toList();

  for (final filter in SportsChannelFilter.values) {
    testWidgets('stats list preserves ${filter.name} filter after refreshing',
        (tester) async {
      final inputs = <List<SportsGame>>[];
      await tester.pumpWidget(app(filter, (g) async {
        inputs.add(g);
        return matches;
      }));
      await tester.pump();
      final before = rows(tester);
      scores.requests.first.complete(games);
      await tester.pumpAndSettle();
      expect(rows(tester), before);
      expect(
          rows(tester),
          hasLength(switch (filter) {
            SportsChannelFilter.matched => 1,
            SportsChannelFilter.possible => 2,
            SportsChannelFilter.all => 3,
          }));
      if (filter != SportsChannelFilter.all) {
        expect(inputs.single.map((g) => g.id),
            ['confirmed', 'possible', 'unmatched'],
            reason: 'upcoming games do not consume matching work');
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('guide programme expiry rechecks just the affected live game',
      (tester) async {
    final checks = <List<SportsGame>>[];
    final expiredSoon = ChannelMatch(channel, MatchReason.guide, 500,
        programme: EpgProgram(
            channelId: channel.id,
            title: 'Live game',
            start: now.subtract(const Duration(hours: 1)),
            stop: now.add(const Duration(seconds: 30))));
    await tester.pumpWidget(app(SportsChannelFilter.all, (games) async {
      checks.add(games);
      return {'nhl:confirmed': matches['nhl:confirmed']!};
    }, initialMatches: {
      ...matches,
      'nhl:confirmed': [expiredSoon]
    }));
    await tester.pump();
    scores.requests.first.complete(games);
    await tester.pumpAndSettle();
    expect(checks, isEmpty);
    clock = now.add(const Duration(seconds: 31));
    await tester.pump(const Duration(seconds: 31));
    scores.requests.last.complete(games);
    await tester.pumpAndSettle();
    expect(checks.single.map((g) => g.id), ['confirmed']);
    expect(rows(tester), hasLength(3));
    clock = clock.add(const Duration(seconds: 31));
    await tester.pump(const Duration(seconds: 31));
    scores.requests.last.complete(games);
    await tester.pumpAndSettle();
    expect(checks, hasLength(1));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'all-events list rechecks old and empty matches without repeated work',
      (tester) async {
    final checks = <List<SportsGame>>[];
    await tester.pumpWidget(app(SportsChannelFilter.all, (games) async {
      checks.add(games);
      return matches;
    }));
    await tester.pump();
    scores.requests.first.complete(games);
    await tester.pumpAndSettle();
    expect(checks, isEmpty, reason: 'fresh hub matches are reused');
    clock = now.add(const Duration(minutes: 5));
    await tester.pump(const Duration(seconds: 31));
    scores.requests.last.complete(games);
    await tester.pumpAndSettle();
    expect(
        checks.single.map((g) => g.id), ['confirmed', 'possible', 'unmatched']);
    expect(rows(tester), hasLength(3));
    clock = clock.add(const Duration(seconds: 31));
    await tester.pump(const Duration(seconds: 31));
    scores.requests.last.complete(games);
    await tester.pumpAndSettle();
    expect(checks, hasLength(1));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'slow polling coalesces, pauses in background and recovers from failure',
      (tester) async {
    final matching = <Completer<Map<String, List<ChannelMatch>>>>[];
    await tester.pumpWidget(app(SportsChannelFilter.possible, (_) {
      final result = Completer<Map<String, List<ChannelMatch>>>();
      matching.add(result);
      return result.future;
    }));
    await tester.pump();
    final before = rows(tester);
    await tester.pump(const Duration(seconds: 91));
    expect(scores.requests, hasLength(1));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    final prefetches = scores.prefetches;
    scores.requests.first.complete(games);
    await tester.pump();
    await tester.pump(const Duration(seconds: 91));
    expect(scores.requests, hasLength(1));
    expect(matching, isEmpty);
    expect(scores.prefetches, prefetches);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(scores.requests, hasLength(2));
    scores.requests.last.complete(games);
    await tester.pump();
    expect(matching, hasLength(1));
    await tester.pump(const Duration(seconds: 91));
    expect(scores.requests, hasLength(2),
        reason: 'poll waits for the active channel check');
    matching.single.complete(matches);
    await tester.pump();
    expect(scores.requests, hasLength(3));
    scores.requests.last.completeError(StateError('temporary failure'));
    await tester.pumpAndSettle();
    expect(rows(tester), before);
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(seconds: 31));
    scores.requests.last.complete(games);
    await tester.pump();
    matching.last.complete(matches);
    await tester.pumpAndSettle();
    expect(rows(tester), before);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('initial score failure stops loading and offers a working retry',
      (tester) async {
    await tester.pumpWidget(
        app(SportsChannelFilter.all, (_) async => matches, empty: true));
    await tester.pump();
    scores.requests.first.completeError(StateError('temporary failure'));
    await tester.pumpAndSettle();
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('Retry'), findsOneWidget);
    await tester.tap(find.text('Retry'));
    await tester.pump();
    scores.requests.last.complete(games);
    await tester.pumpAndSettle();
    expect(rows(tester), hasLength(3));
    expect(find.text('Retry'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
