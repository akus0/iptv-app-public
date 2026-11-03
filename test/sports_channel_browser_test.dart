import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:nox_iptv/models/channel.dart';
import 'package:nox_iptv/models/sports.dart';
import 'package:nox_iptv/models/sports_channel_filters.dart';
import 'package:nox_iptv/services/app_preferences.dart';
import 'package:nox_iptv/services/epg_service.dart';
import 'package:nox_iptv/services/storage_service.dart';
import 'package:nox_iptv/services/sports_channel_matcher.dart';
import 'package:nox_iptv/services/sports_channel_attempts.dart';
import 'package:nox_iptv/utils/sports_channel_browser.dart';
import 'package:nox_iptv/widgets/sports_channel_picker.dart';
import 'package:nox_iptv/widgets/sports_channel_options.dart';

ChannelSearchResult row(String id, String name, String group,
    {String playlist = 'one', MatchReason reason = MatchReason.guide}) {
  final channel = Channel(
      id: id,
      rawId: id,
      playlistId: playlist,
      name: name,
      group: group,
      url: 'https://example.invalid/never-play');
  return ChannelSearchResult(channel,
      match: ChannelMatch(channel, reason, 500));
}

class BrowserMatcher extends SportsChannelMatcher {
  BrowserMatcher(super.guide, this.rows);
  final List<ChannelSearchResult> rows;
  var discoveries = 0, searches = 0;
  bool failSearch = false;
  @override
  Future<List<ChannelMatch>> alternativesFor(SportsGame game,
      {List<ChannelMatch> matches = const [],
      bool Function()? isCancelled}) async {
    discoveries++;
    return rows.map((r) => r.match!).toList();
  }

  @override
  Future<List<ChannelSearchResult>> searchWithGuide(String query,
      {List<ChannelMatch> matches = const [],
      int limit = 200,
      bool Function()? isCancelled}) async {
    searches++;
    if (failSearch) throw StateError('Synthetic search failure');
    return rows;
  }
}

void main() {
  for (final config in [
    (const Size(320, 568), 1.6),
    (const Size(844, 390), 2.0),
    (const Size(960, 540), 1.6)
  ]) {
    testWidgets(
        'compact channel filters keep footer reachable with enlarged text at ${config.$1}',
        (tester) async {
      tester.view.physicalSize = config.$1;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({});
      final storage = StorageService();
      await storage.init();
      final prefs = AppPreferences(storage);
      await prefs.init();
      prefs.isTelevision = config.$1.width >= 960;
      addTearDown(prefs.dispose);
      await tester.pumpWidget(ChangeNotifierProvider.value(
          value: prefs,
          child: MaterialApp(
              builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(context)
                      .copyWith(textScaler: TextScaler.linear(config.$2)),
                  child: child!),
              home: Scaffold(
                  body: Builder(
                      builder: (context) => TextButton(
                          onPressed: () => showDialog<void>(
                              context: context,
                              builder: (_) => SportsChannelOptionsDialog(
                                  initial: const SportsChannelFilters(),
                                  playlistNames: const {
                                    'one': 'Main',
                                    'two': 'Other'
                                  },
                                  choices: Future.value((
                                    regions: <String>['UK', 'US'],
                                    playlists: <String>['one', 'two']
                                  )))),
                          child: const Text('Open')))))));
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      final surface = tester
          .getSize(find.byKey(const ValueKey('sports-compact-dialog-surface')));
      expect(surface.width, lessThanOrEqualTo(440));
      expect(surface.height, lessThanOrEqualTo(440));
      expect(find.byKey(const ValueKey('channel-filters-done')).hitTestable(),
          findsOneWidget);
      await tester
          .ensureVisible(find.byKey(const ValueKey('channel-untried-filter')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('channel-untried-filter')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('channel-filters-done')).hitTestable(),
          findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const ValueKey('channel-filters-done')));
      await tester.pumpAndSettle();
      expect(find.text('Open'), findsOneWidget);
    });
  }

  final rows = [
    row('a', 'UK | Zebra Sports', 'UK | Sports'),
    row('b', 'US | Alpha Sports', 'US | Sports', playlist: 'two'),
    row('c', 'AU | Beta Sports', 'AU | Sports', reason: MatchReason.pick),
    row('d', 'UK | Conflict', 'US | Sports', reason: MatchReason.tournament),
    row('e', 'No region', 'Sports', reason: MatchReason.network),
  ];
  test(
      'local filters use conservative labels and never treat a pick as evidence',
      () async {
    final browser = SportsChannelBrowser();
    Future<List<String>> apply(SportsChannelFilters filters) async =>
        (await browser.apply(
                rows, filters, {'b'}, {'one': 'Main', 'two': 'Other'},
                cancelled: () => false))
            .map((r) => r.channel.id)
            .toList();
    expect(
        await apply(const SportsChannelFilters()), ['a', 'b', 'c', 'd', 'e']);
    expect(await apply(const SportsChannelFilters(region: 'uk')), ['a']);
    expect(await apply(const SportsChannelFilters(region: '?')), ['d', 'e']);
    expect(
        await apply(const SportsChannelFilters(
            evidence: SportsChannelEvidence.specific)),
        ['a', 'b']);
    expect(
        await apply(
            const SportsChannelFilters(evidence: SportsChannelEvidence.likely)),
        ['a', 'b', 'e']);
    expect(await apply(const SportsChannelFilters(untriedOnly: true)),
        ['a', 'c', 'd', 'e']);
    expect(await apply(const SportsChannelFilters(playlist: 'two')), ['b']);
    expect(
        await apply(const SportsChannelFilters(sort: SportsChannelSort.name)),
        ['c', 'e', 'd', 'a', 'b']);
    expect(
        await apply(const SportsChannelFilters(sort: SportsChannelSort.region)),
        ['c', 'a', 'b', 'e', 'd']);
    final choices = await browser.choices(rows, cancelled: () => false);
    expect(choices.regions.toSet(), {'uk', 'us', 'au', '?'});
    expect(choices.playlists, ['one', 'two']);
    expect(rows.first.channel.id, 'a');
  });
  test('large sorting yields and obsolete work can cancel', () async {
    final browser = SportsChannelBrowser();
    final many = [
      for (var i = 8000; i > 0; i--)
        row('$i', 'UK | Channel ${i.toString().padLeft(5, '0')}', 'UK | Sports')
    ];
    var turns = 0, done = false;
    Future<void> heartbeat() async {
      while (!done) {
        await Future<void>.delayed(Duration.zero);
        turns++;
      }
    }

    final beat = heartbeat();
    final result = await browser.apply(many,
        const SportsChannelFilters(sort: SportsChannelSort.name), {}, const {},
        cancelled: () => false);
    done = true;
    await beat;
    expect(result.first.channel.id, '1');
    expect(result.last.channel.id, '8000');
    expect(turns, greaterThan(0));
    expect(
        await browser.apply(
            many, const SportsChannelFilters(region: 'uk'), {}, const {},
            cancelled: () => true),
        isEmpty);
  });
  test('event preferences are isolated and bounded', () {
    final session = SportsChannelBrowseSession();
    const choice =
        SportsChannelFilters(sort: SportsChannelSort.name, region: 'uk');
    session.write('event', choice);
    expect(session.read('event'), same(choice));
    expect(session.read('other').isDefault, isTrue);
    for (var i = 0; i < 25; i++) {
      session.write(i, choice);
    }
    expect(session.read('event').isDefault, isTrue);
    session.write(24, const SportsChannelFilters());
    expect(session.read(24).isDefault, isTrue);
  });
  testWidgets('TV keeps nearest row focused when a visible result disappears',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final storage = StorageService();
    await storage.init();
    final prefs = AppPreferences(storage);
    await prefs.init();
    prefs.isTelevision = true;
    addTearDown(prefs.dispose);
    final epg = EpgService(storage);
    addTearDown(epg.dispose);
    Widget app(List<ChannelSearchResult> visible) => MultiProvider(
            providers: [
              ChangeNotifierProvider.value(value: prefs),
              ChangeNotifierProvider<EpgService>.value(value: epg)
            ],
            child: MaterialApp(
                home: Scaffold(
                    body: SportsChannelList(
              rows: visible,
              onChoose: (_) {},
            ))));
    await tester.pumpWidget(app(rows.take(3).toList()));
    await tester.pumpAndSettle();
    tester
        .widget<InkWell>(find.byKey(const ValueKey('game-channel:b')))
        .focusNode!
        .requestFocus();
    await tester.pump();
    await tester.pumpWidget(app([rows[0], rows[2]]));
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<InkWell>(find.byKey(const ValueKey('game-channel:c')))
            .focusNode!
            .hasFocus,
        isTrue);
    expect(tester.takeException(), isNull);
  });
  for (final size in [
    const Size(320, 568),
    const Size(844, 390),
    const Size(960, 540)
  ]) {
    testWidgets('filters, reset, search and reopening stay local at $size',
        (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({});
      final storage = StorageService();
      await storage.init();
      final prefs = AppPreferences(storage);
      await prefs.init();
      prefs.isTelevision = size.width >= 960;
      final epg = EpgService(storage);
      final matcher = BrowserMatcher(epg, rows);
      addTearDown(prefs.dispose);
      addTearDown(epg.dispose);
      addTearDown(matcher.dispose);
      final session = SportsChannelBrowseSession();
      final game = SportsGame(
          id: 'browser',
          league: sportsLeagueById('eng.1')!,
          start: DateTime(2026, 11, 1),
          state: GameState.live,
          statusText: 'Live',
          home: const SportsTeam(
              id: 'a', name: 'Team A', shortName: 'A', abbreviation: 'A'),
          away: const SportsTeam(
              id: 'b', name: 'Team B', shortName: 'B', abbreviation: 'B'));
      Widget app(String key) => MultiProvider(
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
                          matches: rows.map((r) => r.match!).toList(),
                          browseSession: session,
                          playlistNames: const {
                            'one': 'Main playlist',
                            'two': 'Other playlist'
                          },
                          attempts: SportsChannelAttempts()))));
      List<String> ids() => tester
          .widget<SportsChannelList>(find.byType(SportsChannelList))
          .rows
          .map((r) => r.channel.id)
          .toList();
      await tester.pumpWidget(app('first'));
      await tester.pumpAndSettle();
      final initial = ids();
      expect(find.text('Main playlist · UK | Sports'), findsWidgets);
      if (size.width == 320) {
        tester.platformDispatcher.textScaleFactorTestValue = 1.4;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        await tester.pumpAndSettle();
      }

      await tester
          .tap(find.byKey(const ValueKey('sports-channel-sort-filter')));
      await tester.pumpAndSettle();
      if (prefs.isTelevision) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      } else {
        await tester.tap(find.byKey(const ValueKey('channel-sort-name')));
      }
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('channel-filters-done')));
      await tester.pumpAndSettle();
      expect(ids(), ['c', 'e', 'd', 'a', 'b']);
      expect(matcher.discoveries, 1);
      expect(matcher.searches, 0);
      await tester.pumpWidget(app('reopen'));
      await tester.pumpAndSettle();
      expect(ids(), ['c', 'e', 'd', 'a', 'b']);
      // Cancelling edits leaves both order and the remembered settings intact.
      await tester
          .tap(find.byKey(const ValueKey('sports-channel-sort-filter')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('channel-sort-playlist')));
      await tester.tap(find.byTooltip('Cancel filters'));
      await tester.pumpAndSettle();
      expect(ids(), ['c', 'e', 'd', 'a', 'b']);
      await tester
          .tap(find.byKey(const ValueKey('sports-channel-sort-filter')));
      await tester.pumpAndSettle();
      await tester
          .ensureVisible(find.byKey(const ValueKey('channel-country-filter')));
      await tester.tap(find.byKey(const ValueKey('channel-country-filter')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('UK'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('channel-filters-done')));
      await tester.pumpAndSettle();
      expect(ids(), ['a']);
      expect(find.textContaining('Channel A–Z · UK'), findsOneWidget);
      await tester
          .tap(find.byKey(const ValueKey('sports-channel-sort-filter')));
      await tester.pumpAndSettle();
      await tester
          .ensureVisible(find.byKey(const ValueKey('channel-country-filter')));
      await tester.tap(find.byKey(const ValueKey('channel-country-filter')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('All countries / regions'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('channel-filters-done')));
      await tester.pumpAndSettle();
      expect(ids().length, 5);

      await tester
          .tap(find.byKey(const ValueKey('sports-channel-sort-filter')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Reset all'));
      await tester.pumpAndSettle();
      expect(ids(), initial);
      await tester.tap(find.text('Find another channel'));
      await tester.pumpAndSettle();
      expect(matcher.searches, 1);
      await tester
          .tap(find.byKey(const ValueKey('sports-channel-sort-filter')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(
          find.byKey(const ValueKey('channel-evidence-specific')));
      await tester.tap(find.byKey(const ValueKey('channel-evidence-specific')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('channel-filters-done')));
      await tester.pumpAndSettle();
      expect(ids().toSet(), {'a', 'b'});
      await tester.tap(find.byTooltip('Back to suggested channels'));
      await tester.pumpAndSettle();
      expect(ids().toSet(), {'a', 'b'});
      expect(matcher.discoveries, 1);
      expect(matcher.searches, 1);
      expect(tester.takeException(), isNull);
      if (!prefs.isTelevision) {
        await tester.tap(find.text('Find another channel'));
        await tester.pumpAndSettle();
        expect(ids().toSet(), {'a', 'b'});
        matcher.failSearch = true;
        await tester.enterText(
            find.byKey(const ValueKey('sports-channel-search')), 'New query');
        await tester.pumpAndSettle();
        expect(find.byType(SportsChannelList), findsNothing);
        expect(find.text('Search unavailable. Try another keyword.'),
            findsOneWidget);
        matcher.failSearch = false;
        await tester.enterText(
            find.byKey(const ValueKey('sports-channel-search')), 'Recovered');
        await tester.pumpAndSettle();
        expect(ids().toSet(), {'a', 'b'});
        expect(tester.takeException(), isNull);
      }
      if (prefs.isTelevision) {
        await tester.tap(find.byTooltip('Back to top'));
        await tester.pumpAndSettle();
        await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
        await tester.pumpAndSettle();
        expect(find.text('Sort & filter channels'), findsOneWidget);
      }
    });
  }
  testWidgets('repeated Reset all cannot close the screen below the filters',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: Builder(
            builder: (context) => Scaffold(
                body: TextButton(
                    onPressed: () =>
                        Navigator.of(context).push(MaterialPageRoute<void>(
                            builder: (context) => Scaffold(
                                    body: TextButton(
                                  onPressed: () => showDialog<void>(
                                      context: context,
                                      builder: (_) =>
                                          SportsChannelOptionsDialog(
                                              initial:
                                                  const SportsChannelFilters(),
                                              playlistNames: const {},
                                              choices: Future.value((
                                                regions: <String>[],
                                                playlists: <String>[]
                                              )))),
                                  child: const Text('Open filters'),
                                )))),
                    child: const Text('Open channels'))))));
    await tester.tap(find.text('Open channels'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open filters'));
    await tester.pumpAndSettle();
    final reset = tester
        .widget<TextButton>(find.widgetWithText(TextButton, 'Reset all'))
        .onPressed!;
    reset();
    reset();
    await tester.pumpAndSettle();
    expect(find.text('Open filters'), findsOneWidget);
    expect(find.text('Open channels'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
