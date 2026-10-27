import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:nox_iptv/models/channel.dart';
import 'package:nox_iptv/models/epg_program.dart';
import 'package:nox_iptv/models/sports.dart';
import 'package:nox_iptv/services/app_preferences.dart';
import 'package:nox_iptv/services/epg_service.dart';
import 'package:nox_iptv/services/storage_service.dart';
import 'package:nox_iptv/services/sports_channel_matcher.dart';
import 'package:nox_iptv/utils/sports_channel_filter.dart';
import 'package:nox_iptv/widgets/sports_channel_picker.dart';

Channel channel(String id) => Channel(
    id: id,
    rawId: id,
    playlistId: 'test',
    name: id,
    group: 'Tennis',
    url: 'https://example.invalid/never-open');

class _Matcher extends SportsChannelMatcher {
  _Matcher(super.guide);
  final pending = <Completer<List<ChannelMatch>>>[];
  final searches = <Completer<List<ChannelSearchResult>>>[];
  @override
  Future<List<ChannelSearchResult>> searchWithGuide(String query,
      {List<ChannelMatch> matches = const [],
      int limit = 200,
      bool Function()? isCancelled}) {
    final work = Completer<List<ChannelSearchResult>>();
    searches.add(work);
    return work.future;
  }

  @override
  Future<List<ChannelMatch>> alternativesFor(SportsGame game,
      {List<ChannelMatch> matches = const [], bool Function()? isCancelled}) {
    final work = Completer<List<ChannelMatch>>();
    pending.add(work);
    return work.future;
  }
}

void main() {
  final stan = ChannelMatch(channel('Stan Sport'), MatchReason.tournament, 200);
  final guide = ChannelMatch(channel('Specific event'), MatchReason.guide, 500);
  final tile = ChannelMatch(channel('Tile channel'), MatchReason.sport, 80);
  final saved = ChannelMatch(channel('Saved channel'), MatchReason.pick, 1000);

  test(
      'enrichment replaces downgraded evidence and preserves tied alternatives',
      () {
    final tied =
        ChannelMatch(channel('Tied channel'), MatchReason.tournament, 200);
    final downgrade = ChannelMatch(guide.channel, MatchReason.sport, 40);
    final fresh =
        ChannelMatch(channel('New exact match'), MatchReason.guide, 500);
    final before = [saved, guide, stan, tied, tile];
    final result = mergeChannelSuggestions(before, [downgrade, fresh]);
    expect(result, [fresh, stan, tied, tile, downgrade]);
    expect(before, [saved, guide, stan, tied, tile]);
    expect(result.where((m) => m.channel.id == guide.channel.id).single,
        same(downgrade));
  });

  for (final fails in [false, true]) {
    testWidgets('empty picker stops waiting after enrichment, failure=$fails',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      final storage = StorageService();
      await storage.init();
      final prefs = AppPreferences(storage);
      await prefs.init();
      final epg = EpgService(storage), online = Completer<List<ChannelMatch>>();
      final matcher = _Matcher(epg);
      final game = SportsGame(
          id: 'empty',
          league: sportsLeagueById('nhl')!,
          start: DateTime.now(),
          state: GameState.live,
          statusText: 'Live',
          home: const SportsTeam(
              id: 'a', name: 'Alpha', shortName: 'A', abbreviation: 'A'),
          away: const SportsTeam(
              id: 'b', name: 'Beta', shortName: 'B', abbreviation: 'B'));
      await tester.pumpWidget(MultiProvider(
          providers: [
            ChangeNotifierProvider.value(value: prefs),
            ChangeNotifierProvider<EpgService>.value(value: epg),
          ],
          child: MaterialApp(
              home: Scaffold(
                  body: SportsChannelPickerDialog(
                      game: game,
                      matches: const [],
                      matcher: matcher,
                      matching: true,
                      onlineMatches: online.future)))));
      await tester.pump();
      matcher.pending.single.complete([]);
      await tester.pumpAndSettle();
      expect(find.text('Looking for channel suggestions…'), findsOneWidget);
      if (fails) {
        online.completeError(StateError('offline'));
      } else {
        online.complete([]);
      }
      await tester.pumpAndSettle();
      expect(find.text('Looking for channel suggestions…'), findsNothing);
      expect(
          find.textContaining(
              fails ? 'Could not finish' : 'No matched channels'),
          findsOneWidget);
      expect(find.text('Find another channel'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      matcher.dispose();
      epg.dispose();
      prefs.dispose();
    });
  }

  for (final television in [false, true]) {
    testWidgets(
        'search keeps position and focus during enrichment, TV=$television',
        (tester) async {
      tester.view.physicalSize =
          television ? const Size(960, 540) : const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({});
      final storage = StorageService();
      await storage.init();
      final prefs = AppPreferences(storage);
      await prefs.init();
      prefs.isTelevision = television;
      final epg = EpgService(storage);
      final matcher = _Matcher(epg);
      final online = Completer<List<ChannelMatch>>();
      final now = DateTime.now();
      final game = SportsGame(
          id: 'search',
          league: sportsLeagueById('tennis.atp')!,
          start: now,
          state: GameState.live,
          statusText: 'Live',
          home: const SportsTeam(
              id: 'a', name: 'Player A', shortName: 'A', abbreviation: ''),
          away: const SportsTeam(
              id: 'b', name: 'Player B', shortName: 'B', abbreviation: ''));
      final channels = [for (var i = 0; i < 30; i++) channel('Tennis $i')];
      final programme = EpgProgram(
          channelId: channels.first.id,
          title: 'Search programme',
          start: now,
          stop: now.add(const Duration(hours: 1)));
      final results = [
        for (final c in channels)
          ChannelSearchResult(c, programme: programme, programmeSearchHit: true)
      ];
      await tester.pumpWidget(MultiProvider(
          providers: [
            ChangeNotifierProvider.value(value: prefs),
            ChangeNotifierProvider<EpgService>.value(value: epg),
          ],
          child: MaterialApp(
              home: Scaffold(
                  body: SportsChannelPickerDialog(
                      game: game,
                      matches: [tile],
                      matcher: matcher,
                      onlineMatches: online.future)))));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Find another channel'));
      await tester.pump();
      expect(matcher.searches, hasLength(1));
      matcher.searches.first.complete(results);
      await tester.pumpAndSettle();
      final list = find.byType(SportsChannelList);
      final scroll =
          find.descendant(of: list, matching: find.byType(Scrollable));
      if (television) {
        tester
            .widget<InkWell>(
                find.byKey(ValueKey('game-channel:${channels.first.id}')))
            .focusNode!
            .requestFocus();
        await tester.pump();
        for (var i = 0; i < 10; i++) {
          await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
          await tester.pumpAndSettle();
        }
      } else {
        await tester.drag(list, const Offset(0, -600));
        await tester.pumpAndSettle();
      }
      final offset = tester.state<ScrollableState>(scroll).position.pixels;
      final focused = FocusManager.instance.primaryFocus;
      expect(offset, greaterThan(200));
      final evidence = ChannelMatch(channels.first, MatchReason.guide, 500);
      online.complete([evidence]);
      await tester.pumpAndSettle();
      matcher.pending.last.complete([evidence]);
      matcher.pending.first.complete([tile]); // Superseded work cannot undo it.
      await tester.pumpAndSettle();
      expect(matcher.searches, hasLength(1),
          reason: 'no repeated playlist scan');
      expect(tester.state<ScrollableState>(scroll).position.pixels,
          closeTo(offset, 1));
      if (television) expect(FocusManager.instance.primaryFocus, same(focused));
      final updated = tester.widget<SportsChannelList>(list).rows;
      expect(updated.map((r) => r.channel.id), channels.map((c) => c.id));
      expect(updated.first.match, same(evidence));
      expect(updated.first.programme, same(programme));
      expect(updated.first.programmeSearchHit, true);

      // New queries still reset position; out-of-order replies cannot replace them.
      final field = find.byKey(const ValueKey('sports-channel-search'));
      if (television) {
        tester.widget<TextField>(field).focusNode!.requestFocus();
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.select);
        await tester.pump();
      }
      await tester.enterText(field, 'older');
      await tester.pump(const Duration(milliseconds: 200));
      await tester.enterText(field, 'newer');
      await tester.pump(const Duration(milliseconds: 200));
      expect(matcher.searches, hasLength(3));
      matcher.searches.last.complete(results.reversed.toList());
      await tester.pumpAndSettle();
      matcher.searches[1].complete(results);
      await tester.pumpAndSettle();
      expect(tester.widget<SportsChannelList>(list).rows.first.channel.id,
          channels.last.id);
      expect(tester.state<ScrollableState>(scroll).position.pixels, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      matcher.dispose();
      epg.dispose();
      prefs.dispose();
    });
  }

  test('playback and tile context remain first without upgrading confidence',
      () {
    final evidence = [saved, guide, stan, tile];
    final result = pinChannelSuggestions(evidence,
        playingId: stan.channel.id,
        playingChannel: stan.channel,
        selectedId: saved.channel.id,
        tileMatch: tile);
    expect(result, [stan, saved, tile, guide]);
    expect(stan.isConfident, false);
    expect(tile.isConfident, false);
    expect(evidence, [saved, guide, stan, tile]);
    expect(
        pinChannelSuggestions(evidence,
                playingId: stan.channel.id, tileMatch: stan)
            .where((m) => m.channel.id == stan.channel.id)
            .length,
        1);
  });
  test('a broad alternative for another event cannot become the playing pin',
      () {
    expect(
        pinChannelSuggestions([guide, stan, tile],
            playingId: stan.channel.id, tileMatch: guide),
        [guide, stan, tile]);
    expect(
        pinChannelSuggestions([guide, stan, tile], playingId: stan.channel.id),
        [guide, stan, tile]);
  });

  testWidgets('playback badges follow event context, including manual search',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    final storage = StorageService();
    await storage.init();
    final prefs = AppPreferences(storage);
    await prefs.init();
    prefs.isTelevision = false;
    final epg = EpgService(storage);
    final matcher = _Matcher(epg);
    final game = SportsGame(
        id: 'different-match',
        league: sportsLeagueById('tennis.atp')!,
        start: DateTime.now(),
        state: GameState.live,
        statusText: 'Live',
        home: const SportsTeam(
            id: 'c', name: 'Player C', shortName: 'C', abbreviation: ''),
        away: const SportsTeam(
            id: 'd', name: 'Player D', shortName: 'D', abbreviation: ''));
    Widget app({bool forThisGame = false, ChannelMatch? recommendation}) =>
        MultiProvider(
            providers: [
              ChangeNotifierProvider.value(value: prefs),
              ChangeNotifierProvider<EpgService>.value(value: epg)
            ],
            child: MaterialApp(
                home: Scaffold(
                    body: SportsChannelPickerDialog(
                        game: game,
                        matcher: matcher,
                        matches: [guide, stan, tile],
                        tileMatch: recommendation ?? guide,
                        playingId: stan.channel.id,
                        playingChannel: forThisGame ? stan.channel : null))));
    SportsChannelList list() =>
        tester.widget<SportsChannelList>(find.byType(SportsChannelList));
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    expect(list().rows.first.channel.id, guide.channel.id);
    expect(list().playingId, isNull);
    expect(find.textContaining('Playing'), findsNothing);
    matcher.pending.single.complete([guide, stan, tile]);
    await tester.pumpAndSettle();
    expect(list().rows.first.channel.id, guide.channel.id);
    expect(list().playingId, isNull);

    await tester.tap(find.text('Find another channel'));
    await tester.pump();
    matcher.searches.single.complete([ChannelSearchResult(stan.channel)]);
    await tester.pumpAndSettle();
    expect(list().rows.single.channel.id, stan.channel.id);
    expect(list().playingId, isNull);
    expect(find.textContaining('Playing'), findsNothing);

    // The same actual channel can become relevant without its ID changing.
    await tester.pumpWidget(app(forThisGame: true));
    await tester.pumpAndSettle();
    expect(list().playingId, stan.channel.id);
    expect(find.textContaining('Playing'), findsOneWidget);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    expect(list().playingId, isNull);
    expect(find.textContaining('Playing'), findsNothing);

    // A different event may still recommend the channel already playing.
    await tester.pumpWidget(app(recommendation: stan));
    await tester.pumpAndSettle();
    expect(list().playingId, stan.channel.id);
    expect(find.textContaining('Playing'), findsOneWidget);
    expect(matcher.pending, hasLength(1),
        reason: 'context changes need no scan');
    expect(matcher.searches, hasLength(1));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    matcher.dispose();
    epg.dispose();
    prefs.dispose();
  });

  testWidgets(
      'partial enrichment cannot put weak evidence above a strong match',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final storage = StorageService();
    await storage.init();
    final prefs = AppPreferences(storage);
    await prefs.init();
    final epg = EpgService(storage);
    final matcher = _Matcher(epg);
    final online = Completer<List<ChannelMatch>>();
    final game = SportsGame(
        id: 'enrichment',
        league: sportsLeagueById('tennis.atp')!,
        start: DateTime.now(),
        state: GameState.live,
        statusText: 'Live',
        home: const SportsTeam(
            id: 'a', name: 'Player A', shortName: 'A', abbreviation: ''),
        away: const SportsTeam(
            id: 'b', name: 'Player B', shortName: 'B', abbreviation: ''));
    await tester.pumpWidget(MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: prefs),
          ChangeNotifierProvider<EpgService>.value(value: epg)
        ],
        child: MaterialApp(
            home: Scaffold(
                body: SportsChannelPickerDialog(
                    game: game,
                    matcher: matcher,
                    matches: [guide, stan],
                    playingId: stan.channel.id,
                    onlineMatches: online.future)))));
    await tester.pumpAndSettle();
    matcher.pending.first.complete([guide, stan]);
    await tester.pumpAndSettle();
    online.complete([tile]);
    await tester.pumpAndSettle();
    var list = tester.widget<SportsChannelList>(find.byType(SportsChannelList));
    expect(list.rows.map((r) => r.channel.id),
        [guide.channel.id, stan.channel.id, tile.channel.id]);
    expect(list.playingId, isNull);
    // Actual new evidence can make the playing channel the top suggestion.
    matcher.pending.last.complete([stan, tile]);
    await tester.pumpAndSettle();
    list = tester.widget<SportsChannelList>(find.byType(SportsChannelList));
    expect(list.rows.first.channel.id, stan.channel.id);
    expect(list.playingId, stan.channel.id);
    expect(list.rows.first.match!.isConfident, false);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    matcher.dispose();
    epg.dispose();
    prefs.dispose();
  });
  test('unrelated playback is not injected; missing evidence stays provisional',
      () {
    expect(pinChannelSuggestions([guide], playingId: 'Comedy'), [guide]);
    final result = pinChannelSuggestions([guide],
        playingId: stan.channel.id,
        playingChannel: stan.channel,
        tileMatch: tile);
    expect(result.map((m) => m.channel.id),
        [stan.channel.id, tile.channel.id, guide.channel.id]);
    expect(result.take(2).every((m) => !m.isConfident), true);
    expect(result[1].detail, contains('unverified'));
    expect(
        SportsChannelFilter.matched
            .accepts(result.take(2).toList(), pending: false),
        false);
  });
  test('tile follows actual playback while match updates are pending', () {
    expect(
        displayedSportsChannel([guide, stan], SportsChannelFilter.possible,
            playing: stan.channel),
        same(stan));
    final pending = displayedSportsChannel([guide], SportsChannelFilter.matched,
        playing: stan.channel)!;
    expect(pending.channel, same(stan.channel));
    expect(pending.isConfident, false);
    expect(displayedSportsChannel([guide], SportsChannelFilter.matched),
        same(guide));
    expect(
        displayedSportsChannel([guide], SportsChannelFilter.possible,
                playing: stan.channel, savedId: stan.channel.id)!
            .reason,
        MatchReason.pick);
  });

  testWidgets(
      'playing channel stays first through discovery, enrichment and reopening',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    final storage = StorageService();
    await storage.init();
    final prefs = AppPreferences(storage);
    await prefs.init();
    prefs.isTelevision = false;
    final epg = EpgService(storage);
    final matcher = _Matcher(epg);
    final online = Completer<List<ChannelMatch>>();
    final game = SportsGame(
        id: 'tennis',
        league: sportsLeagueById('tennis.atp')!,
        start: DateTime.now(),
        state: GameState.live,
        statusText: 'Live',
        home: const SportsTeam(
            id: 'a', name: 'Player A', shortName: 'A', abbreviation: 'A'),
        away: const SportsTeam(
            id: 'b', name: 'Player B', shortName: 'B', abbreviation: 'B'));
    Widget app(Channel playing, {String key = 'open'}) => MultiProvider(
            providers: [
              ChangeNotifierProvider.value(value: prefs),
              ChangeNotifierProvider<EpgService>.value(value: epg)
            ],
            child: MaterialApp(
                home: Scaffold(
                    body: SportsChannelPickerDialog(
                        key: ValueKey(key),
                        game: game,
                        matcher: matcher,
                        matches: [tile, stan],
                        tileMatch: tile,
                        playingId: playing.id,
                        playingChannel: playing,
                        onlineMatches: online.future))));
    List<ChannelSearchResult> rows() =>
        tester.widget<SportsChannelList>(find.byType(SportsChannelList)).rows;
    await tester.pumpWidget(app(stan.channel));
    await tester.pumpAndSettle();
    expect(rows().first.channel.id, stan.channel.id);
    expect(find.textContaining('Playing'), findsOneWidget);
    matcher.pending[0].complete([guide, stan, tile]);
    await tester.pumpAndSettle();
    expect(rows().map((r) => r.channel.id),
        [stan.channel.id, tile.channel.id, guide.channel.id]);
    online.complete([guide, stan]);
    await tester.pumpAndSettle();
    expect(rows().first.channel.id, stan.channel.id);
    matcher.pending[1].complete([guide]);
    await tester.pumpAndSettle();
    expect(rows().first.channel.id, stan.channel.id);
    expect(rows().first.match!.isConfident, false);
    expect(rows()[1].channel.id, tile.channel.id);
    expect(rows()[1].match!.isConfident, false);
    // Playback changes: old pinned positions must not become evidence ranks.
    await tester.pumpWidget(app(guide.channel));
    await tester.pumpAndSettle();
    expect(
        rows().map((r) => r.channel.id), [guide.channel.id, tile.channel.id]);
    await tester.pumpWidget(app(stan.channel, key: 'reopen'));
    await tester.pumpAndSettle();
    expect(rows().first.channel.id, stan.channel.id);
    // Completed online work can supersede the initial expansion on reopening.
    for (final request in matcher.pending.skip(2)) {
      request.complete([guide, tile, stan]);
    }
    await tester.pumpAndSettle();
    expect(rows().first.channel.id, stan.channel.id);
    expect(rows().where((r) => r.channel.id == stan.channel.id).length, 1);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    matcher.dispose();
    epg.dispose();
    prefs.dispose();
  });
}
