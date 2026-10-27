import 'dart:io';
import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:nox_iptv/models/channel.dart';
import 'package:nox_iptv/models/epg_program.dart';
import 'package:nox_iptv/models/sports.dart';
import 'package:nox_iptv/services/app_preferences.dart';
import 'package:nox_iptv/services/epg_service.dart';
import 'package:nox_iptv/services/sports_channel_matcher.dart';
import 'package:nox_iptv/services/storage_service.dart';
import 'package:nox_iptv/utils/tv_theme.dart';
import 'package:nox_iptv/utils/sports_programme_excerpt.dart';
import 'package:nox_iptv/widgets/sports_channel_picker.dart';

class _Guide extends EpgService {
  _Guide(super.storage);
  final now = DateTime.now();
  @override
  EpgProgram? getCurrentProgram(String id) => EpgProgram(
      channelId: id,
      title:
          'Yunchaokete Bu vs Casper Ruud · Shanghai Masters, centre court — live coverage from the afternoon session',
      description:
          'Live tennis from Shanghai. Yunchaokete Bu faces Casper Ruud in the afternoon session on centre court.',
      start: now.subtract(const Duration(minutes: 40)),
      stop: now.add(const Duration(hours: 2)));
  @override
  EpgProgram? getNextProgram(String id) => EpgProgram(
      channelId: id,
      title: 'Evening tennis: tournament highlights and analysis',
      start: now.add(const Duration(hours: 2)),
      stop: now.add(const Duration(hours: 3)));
}

class _ScheduleGuide extends EpgService {
  _ScheduleGuide() : super(StorageService());
  EpgProgram? current, next;
  String? lookedUp;
  @override
  EpgProgram? getCurrentProgram(String id) {
    lookedUp = id;
    return current;
  }

  @override
  EpgProgram? getNextProgram(String id) => next;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    const dir = String.fromEnvironment('LAYOUT_FONT_DIR');
    if (dir.isEmpty) return;
    for (final entry in {
      'Roboto': 'Roboto-Regular.ttf',
      'MaterialIcons': 'MaterialIcons-Regular.otf'
    }.entries) {
      final loader = FontLoader(entry.key)
        ..addFont(File('$dir/${entry.value}')
            .readAsBytes()
            .then((b) => ByteData.sublistView(b)));
      await loader.load();
    }
  });
  test('suggestions prioritize saved picks and event evidence over raw scores',
      () {
    Channel channel(String id) => Channel(
        id: id,
        rawId: id,
        playlistId: 'test',
        name: id,
        group: '',
        url: 'https://example.invalid/never-play');
    final possible =
        ChannelMatch(channel('possible'), MatchReason.tournament, 500);
    final listed = ChannelMatch(channel('listed'), MatchReason.network, 180);
    final guide = ChannelMatch(channel('guide'), MatchReason.guide, 520);
    final saved = ChannelMatch(channel('saved'), MatchReason.pick, 100);
    final tied = ChannelMatch(channel('tied'), MatchReason.guide, 520);
    final input = [possible, listed, guide, saved, tied];
    expect(
        rankChannelSuggestions(input), [saved, guide, tied, listed, possible]);
    expect(input.first, same(possible)); // Caller/cache order is not mutated.
  });
  for (final size in [
    const Size(390, 844),
    const Size(844, 390),
    const Size(960, 540),
    const Size(1280, 720)
  ]) {
    testWidgets(
        'readable suggestions and manual search fit $size and preserve Back',
        (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      SharedPreferences.setMockInitialValues({});
      final storage = StorageService();
      await storage.init();
      final prefs = AppPreferences(storage);
      await prefs.init();
      prefs.isTelevision = size.width >= 960;
      final guide = _Guide(storage);
      final matcher = SportsChannelMatcher(guide);
      final channels = [
        for (var i = 0; i < (size.width >= 960 ? 1000 : 40); i++)
          Channel(
            id: 'test::$i',
            rawId: '$i',
            playlistId: 'test',
            name: i == 0
                ? 'UK: Sky Sports Tennis UHD · Centre Court · Yunchaokete Bu vs Casper Ruud (English commentary)'
                : 'Tennis Channel ${i + 1} HD · Shanghai Masters · Centre Court',
            group: i.isEven ? 'UK · Sports · Tennis' : 'International · Sports',
            url: 'https://example.invalid/never-play',
          )
      ];
      await tester.runAsync(() => matcher.prepare(channels));
      final game = SportsGame(
          id: 'test',
          league: sportsLeagueById('tennis.atp')!,
          start: DateTime.now(),
          state: GameState.live,
          statusText: 'Live',
          home: const SportsTeam(
              id: 'home',
              name: 'Yunchaokete Bu',
              shortName: 'Bu',
              abbreviation: 'BU'),
          away: const SportsTeam(
              id: 'away',
              name: 'Casper Ruud',
              shortName: 'Ruud',
              abbreviation: 'RUU'));
      SportsChannelChoice? chosen;
      final enrichment = Completer<List<ChannelMatch>>();
      await tester.pumpWidget(RepaintBoundary(
          key: const ValueKey('capture-picker'),
          child: MultiProvider(
            providers: [
              ChangeNotifierProvider.value(value: prefs),
              ChangeNotifierProvider<EpgService>.value(value: guide)
            ],
            child: MaterialApp(
                debugShowCheckedModeBanner: false,
                theme: buildAppTheme(prefs.palette),
                home: Builder(
                    builder: (context) => Scaffold(
                            body: Center(
                          child: TextButton(
                              child: const Text('Open'),
                              onPressed: () async {
                                chosen = await showDialog<SportsChannelChoice>(
                                    context: context,
                                    builder: (_) => SportsChannelPickerDialog(
                                          allowMultiview: true,
                                          game: game,
                                          matcher: matcher,
                                          onlineMatches: enrichment.future,
                                          matches: [
                                            ChannelMatch(channels[1],
                                                MatchReason.sport, 80),
                                            ChannelMatch(channels[0],
                                                MatchReason.guide, 500),
                                            for (final c in channels.skip(2))
                                              ChannelMatch(c,
                                                  MatchReason.tournament, 280),
                                          ],
                                        ));
                              }),
                        )))),
          )));
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(
          tester
              .widgetList<SportsChannelRow>(find.byType(SportsChannelRow))
              .first
              .result
              .channel
              .id,
          channels.first.id);
      expect(find.text(channels.first.name), findsOneWidget);
      expect(find.textContaining('High confidence'), findsOneWidget);
      expect(find.textContaining('Possible'), findsWidgets);
      for (final text in [
        channels.first.name,
        guide.getCurrentProgram('0')!.title
      ]) {
        final finder = find.text(text).first;
        final paragraph = tester.renderObject<RenderParagraph>(finder);
        expect(paragraph.didExceedMaxLines, isFalse);
      }
      expect(tester.takeException(), isNull);
      if (const bool.fromEnvironment('CAPTURE_LAYOUT') && size.width != 844) {
        await tester.runAsync(() async {
          final boundary = tester.renderObject<RenderRepaintBoundary>(
              find.byKey(const ValueKey('capture-picker')));
          final image = await boundary.toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await File('/tmp/iptv-channel-detail-${size.width.toInt()}.png')
              .writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
      // Screenshot work yields to real async discovery; settle its ranking first.
      await tester.pumpAndSettle();
      String? browsedId;
      if (size.width >= 960) {
        final first = tester.widget<InkWell>(
            find.byKey(const ValueKey('game-channel:test::0')));
        first.focusNode!.requestFocus();
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
        await tester.pump();
        expect(FocusManager.instance.primaryFocus?.debugLabel,
            'sports-channel-find');
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
        await tester.pump();
        expect(FocusManager.instance.primaryFocus?.debugLabel,
            'sports-channel-watch');
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.pump();
        expect(FocusManager.instance.primaryFocus?.debugLabel,
            'sports-channel-multiview');
        await tester.sendKeyEvent(LogicalKeyboardKey.select);
        await tester.pumpAndSettle();
        expect(find.text('Choose for multiview'), findsOneWidget);
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.select);
        await tester.pumpAndSettle();
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pump();
        expect(FocusManager.instance.primaryFocus?.debugLabel,
            'sports-channel-find');
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pump();
        expect(first.focusNode!.hasFocus, true);
        for (var i = 0; i < 14; i++) {
          await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
          await tester.pumpAndSettle();
        }
        expect(FocusManager.instance.primaryFocus?.context, isNotNull);
        final visibleRows = tester
            .widget<SportsChannelList>(find.byType(SportsChannelList))
            .rows;
        browsedId = visibleRows[14].channel.id;
        expect(find.byKey(ValueKey('game-channel:$browsedId')), findsOneWidget);
        final before = FocusManager.instance.primaryFocus;
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.pumpAndSettle();
        expect(FocusManager.instance.primaryFocus?.debugLabel,
            'sports-channel-find');
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pumpAndSettle();
        expect(FocusManager.instance.primaryFocus, same(before));
        expect(find.byType(SportsChannelRow).evaluate().length, lessThan(15));
      }
      if (!prefs.isTelevision) {
        await tester.drag(
            find.byType(SportsChannelList), const Offset(0, -600));
        await tester.pumpAndSettle();
      }
      // Existing matches render and remain navigable while online work waits.
      expect(enrichment.isCompleted, false);
      enrichment.complete([
        // A high-scoring but downgraded feed must not beat event evidence.
        ChannelMatch(channels[2], MatchReason.tournament, 550),
        ChannelMatch(channels[0], MatchReason.guide, 500),
        ChannelMatch(channels[1], MatchReason.listing, 360,
            supportingBroadcasts: [
              'Tennis Channel · TheSportsDB · United Kingdom'
            ]),
        for (final c in channels.skip(3))
          ChannelMatch(c, MatchReason.tournament, 280),
      ]);
      await tester.pumpAndSettle();
      final updated =
          tester.widget<SportsChannelList>(find.byType(SportsChannelList)).rows;
      expect(updated.take(3).map((r) => r.channel.id),
          [channels[0].id, channels[1].id, channels[2].id]);
      if (!prefs.isTelevision) {
        final scrollable = find.descendant(
            of: find.byType(SportsChannelList),
            matching: find.byType(Scrollable));
        expect(tester.state<ScrollableState>(scrollable).position.pixels,
            greaterThan(200));
      }
      if (prefs.isTelevision) {
        expect(
            tester
                .widget<InkWell>(
                    find.byKey(ValueKey('game-channel:$browsedId')))
                .focusNode!
                .hasFocus,
            isTrue);
        final nextId =
            updated[updated.indexWhere((r) => r.channel.id == browsedId) + 1]
                .channel
                .id;
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pumpAndSettle();
        expect(
            tester
                .widget<InkWell>(find.byKey(ValueKey('game-channel:$nextId')))
                .focusNode!
                .hasFocus,
            isTrue);
        browsedId = nextId;
      }
      await tester.runAsync(() async {
        await tester.tap(find.text('Find another channel'));
        await Future<void>.delayed(const Duration(milliseconds: 30));
      });
      await tester.pumpAndSettle();
      expect(find.text('Find a channel'), findsOneWidget);
      if (prefs.isTelevision) {
        tester
            .widget<TextField>(
                find.byKey(const ValueKey('sports-channel-search')))
            .focusNode!
            .requestFocus();
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pump();
        expect(
            tester
                .widget<ActionChip>(find.byType(ActionChip).first)
                .focusNode!
                .hasFocus,
            isTrue);
        tester
            .widget<TextField>(
                find.byKey(const ValueKey('sports-channel-search')))
            .focusNode!
            .requestFocus();
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.select);
        await tester.pump();
      }
      await tester.enterText(
          find.byKey(const ValueKey('sports-channel-search')), 'Evening');
      await tester.pump(const Duration(milliseconds: 200));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pumpAndSettle();
      expect(
          tester
              .widget<SportsChannelList>(find.byType(SportsChannelList))
              .rows
              .first
              .channel
              .id,
          channels[0].id);
      expect(find.text('NEXT'), findsWidgets);
      expect(find.text('Search match'), findsWidgets);
      expect(tester.takeException(), isNull);
      if (const bool.fromEnvironment('CAPTURE_LAYOUT') && size.width != 844) {
        await tester.runAsync(() async {
          final boundary = tester.renderObject<RenderRepaintBoundary>(
              find.byKey(const ValueKey('capture-picker')));
          final image = await boundary.toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await File(
                  '/tmp/iptv-sports-channel-search-${size.width.toInt()}.png')
              .writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
      // System Back goes to suggestions; query and results are preserved.
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('Watch on…'), findsOneWidget);
      if (prefs.isTelevision) {
        expect(
            tester
                .widget<InkWell>(
                    find.byKey(ValueKey('game-channel:$browsedId')))
                .focusNode!
                .hasFocus,
            isTrue);
      }

      await tester.runAsync(() async {
        await tester.tap(find.text('Find another channel'));
        await Future<void>.delayed(const Duration(milliseconds: 30));
      });
      await tester.pumpAndSettle();
      expect(
          tester
              .widget<TextField>(
                  find.byKey(const ValueKey('sports-channel-search')))
              .controller!
              .text,
          'Evening');
      // Keyboard inset in a short landscape viewport must leave a usable list.
      tester.view.viewInsets = const FakeViewPadding(bottom: 180);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      tester.view.resetViewInsets();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Multiview'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      // Return to the first result through the search field's submit action.
      // Reopening the same query intentionally preserves its scroll position.
      tester
          .widget<TextField>(
              find.byKey(const ValueKey('sports-channel-search')))
          .onSubmitted!('Evening');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('game-channel:test::0')));
      await tester.pumpAndSettle();
      expect(chosen?.multiview, true);
      expect(chosen?.channel?.id, channels.first.id);
      expect(chosen?.manual, isTrue);
      expect(find.byKey(const ValueKey('sports-channel-dialog')), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      guide.dispose();
      prefs.dispose();
    });
  }
  testWidgets(
      'guide hierarchy distinguishes Now, Next and later event evidence',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final guide = _ScheduleGuide();
    final now = DateTime.now();
    EpgProgram slot(String title, int start, int stop) => EpgProgram(
        channelId: 'mapped',
        title: title,
        start: now.add(Duration(hours: start)),
        stop: now.add(Duration(hours: stop)));
    final current = slot('Live centre court coverage', -1, 1);
    final next = slot('Tennis studio analysis', 1, 2);
    final later = slot('Evening final — event coverage', 2, 4);
    final channel = Channel(
        id: 'p::1',
        rawId: '1',
        playlistId: 'p',
        epgIdOverride: 'mapped',
        name: 'Tennis HD',
        group: 'UK Sports',
        url: 'https://example.invalid/never-play');
    guide.current = current;
    guide.next = next;
    Future<void> show(ChannelSearchResult result, {bool search = false}) async {
      await tester.pumpWidget(ChangeNotifierProvider<EpgService>.value(
          value: guide,
          child: MaterialApp(
              theme: ThemeData.dark(),
              home: Scaffold(
                  body: SingleChildScrollView(
                      child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: MediaQuery(
                              data: const MediaQueryData(
                                  textScaler: TextScaler.linear(1.4)),
                              child: SportsChannelRow(
                                  result: result,
                                  rank: 1,
                                  search: search,
                                  selected: true))))))));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }

    await show(ChannelSearchResult(channel,
        programme: later,
        match: ChannelMatch(channel, MatchReason.guide, 500,
            programme: later, detail: later.title)));
    expect(guide.lookedUp, 'mapped');
    expect(find.text('NOW'), findsOneWidget);
    expect(find.text('NEXT'), findsOneWidget);
    expect(find.text('LATER'), findsOneWidget);
    expect(find.text('Event match'), findsOneWidget);
    expect(find.text(later.title), findsOneWidget); // No repeated match detail.
    expect(tester.getTopLeft(find.text(current.title)).dy,
        lessThan(tester.getTopLeft(find.text(next.title)).dy));
    expect(tester.getTopLeft(find.text(next.title)).dy,
        greaterThan(tester.getTopLeft(find.text(later.title)).dy));
    final nowStyle = tester.widget<Text>(find.text(current.title)).style!;
    final nextStyle = tester.widget<Text>(find.text(next.title)).style!;
    expect(nowStyle.color!.computeLuminance(),
        greaterThan(nextStyle.color!.computeLuminance()));
    expect(find.textContaining('left'), findsOneWidget);

    // A search hit in Next is distinct from event evidence in Now.
    await show(
        ChannelSearchResult(channel,
            programme: next,
            programmeSearchHit: true,
            match: ChannelMatch(channel, MatchReason.guide, 500,
                programme: current)),
        search: true);
    expect(find.text('Search match'), findsOneWidget);
    expect(find.text('Event match'), findsOneWidget);
    expect(find.text('LATER'), findsNothing);
    expect(find.text(current.title), findsOneWidget);
    await show(
        ChannelSearchResult(channel,
            programme: current,
            match: ChannelMatch(channel, MatchReason.guide, 500,
                programme: current)),
        search: true);
    expect(find.text('Search match'), findsNothing);
    expect(find.text('Event + search match'), findsNothing);

    // Stale guide data must not be presented as the current broadcast.
    final old = slot('Yesterday’s match', -3, -2);
    guide.current = old;
    guide.next = old;
    await show(ChannelSearchResult(channel,
        programme: old,
        match: ChannelMatch(channel, MatchReason.guide, 500, programme: old)));
    expect(find.text('NOW'), findsNothing);
    expect(find.text('NEXT'), findsNothing);
    expect(find.text('EARLIER'), findsOneWidget);
    expect(find.text('Now · No programme information'), findsOneWidget);
    expect(find.textContaining('left'), findsNothing);
    for (final entry in {
      MatchReason.pick: 'Your pick',
      MatchReason.name: 'High confidence',
      MatchReason.network: 'Likely',
      MatchReason.listing: 'Likely',
      MatchReason.tournament: 'Possible',
      MatchReason.league: 'Possible',
      MatchReason.sport: 'Possible',
    }.entries) {
      await show(ChannelSearchResult(channel,
          match: ChannelMatch(channel, entry.key, 500)));
      expect(find.textContaining(entry.value), findsWidgets);
    }
    await show(ChannelSearchResult(channel), search: true);
    expect(find.textContaining('Unverified'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    guide.dispose();
  });
  testWidgets(
      'synopsis uses richer same-slot evidence without false match labels',
      (tester) async {
    final guide = _ScheduleGuide();
    final now = DateTime.now();
    final channel = Channel(
        id: '1',
        rawId: '1',
        playlistId: 'test',
        name: 'Tennis',
        group: '',
        url: 'https://example.invalid');
    EpgProgram slot(String title, String? description, {int offset = 0}) =>
        EpgProgram(
            channelId: '1',
            title: title,
            description: description,
            start: now
                .subtract(const Duration(minutes: 30))
                .add(Duration(hours: offset)),
            stop: now
                .add(const Duration(minutes: 30))
                .add(Duration(hours: offset)));
    guide.current = slot('Centre court', null);
    guide.next =
        slot('Studio recap', 'NEXT SYNOPSIS SHOULD NOT DISTRACT', offset: 1);
    final evidence = slot(
        'Centre court', 'Casper Ruud faces Bu in live tennis from Shanghai.');
    Future<void> show(MatchReason reason, EpgProgram programme) async {
      await tester.pumpWidget(ChangeNotifierProvider<EpgService>.value(
          value: guide,
          child: MaterialApp(
              home: Scaffold(
                  body: SportsChannelRow(
                      result: ChannelSearchResult(channel,
                          match: ChannelMatch(channel, reason, 90,
                              programme: programme)),
                      rank: 1,
                      highlighter: SportsProgrammeHighlighter(['tennis'],
                          names: ['Casper Ruud']))))));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }

    await show(MatchReason.sport, evidence);
    expect(find.text('Guide context'), findsOneWidget);
    expect(find.text('Event match'), findsNothing);
    expect(find.textContaining('exact event unverified'), findsOneWidget);
    expect(find.text(evidence.description!, findRichText: true), findsWidgets);
    expect(find.text('NEXT SYNOPSIS SHOULD NOT DISTRACT', findRichText: true),
        findsNothing);
    final synopsis = tester.widget<Text>(find
        .byWidgetPredicate((w) =>
            w is Text && w.textSpan?.toPlainText() == evidence.description)
        .first);
    expect(
        (synopsis.textSpan! as TextSpan).children!.whereType<TextSpan>().any(
            (s) =>
                s.text == 'Casper Ruud' &&
                s.style?.fontWeight == FontWeight.w600),
        isTrue);
    await show(MatchReason.guide, evidence);
    expect(find.text('Event match'), findsOneWidget);
    // A different programme must never supply the current show's synopsis.
    await show(MatchReason.sport,
        slot('Another programme', 'Different show synopsis', offset: 2));
    expect(find.text('NOW'), findsOneWidget);
    expect(find.text('LATER'), findsOneWidget);
    expect(find.text(evidence.description!, findRichText: true), findsNothing);
    expect(
        tester
            .getTopLeft(
                find.text('Different show synopsis', findRichText: true).first)
            .dy,
        greaterThan(tester.getTopLeft(find.text('LATER')).dy));
    await tester.pumpWidget(const SizedBox());
    guide.dispose();
  });
  for (final size in [const Size(390, 844), const Size(960, 540)]) {
    testWidgets('single suggestion uses its full content height: $size',
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
      final guide = _Guide(storage);
      final matcher = SportsChannelMatcher(guide);
      final channel = Channel(
          id: 'single',
          rawId: 'single',
          playlistId: 'test',
          name: 'Sky Sports Tennis HD',
          group: 'Sports',
          url: 'https://example.invalid/never-play');
      await tester.runAsync(() => matcher.prepare([channel]));
      final game = SportsGame(
          id: 'single',
          league: sportsLeagueById('tennis.atp')!,
          start: DateTime.now(),
          state: GameState.live,
          statusText: 'Live',
          home: const SportsTeam(
              id: 'a',
              name: 'Yunchaokete Bu',
              shortName: 'Bu',
              abbreviation: 'BU'),
          away: const SportsTeam(
              id: 'b',
              name: 'Casper Ruud',
              shortName: 'Ruud',
              abbreviation: 'RUU'));
      await tester.pumpWidget(MultiProvider(
          providers: [
            ChangeNotifierProvider.value(value: prefs),
            ChangeNotifierProvider<EpgService>.value(value: guide),
          ],
          child: MaterialApp(
              home: Scaffold(
                  body: SportsChannelPickerDialog(
                      game: game,
                      matcher: matcher,
                      allowMultiview: true,
                      matches: [
                ChannelMatch(channel, MatchReason.guide, 500)
              ])))));
      await tester.pumpAndSettle();
      final row =
          tester.getRect(find.byKey(const ValueKey('game-channel:single')));
      final viewport = tester.getRect(find.byType(ListView));
      expect(row.top, greaterThanOrEqualTo(viewport.top - .1));
      expect(row.bottom, lessThanOrEqualTo(viewport.bottom + .1),
          reason:
              'One suggestion should fit without a prematurely clipped bottom');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      prefs.dispose();
      guide.dispose();
    });
  }
  testWidgets('long remote browsing bounds focus nodes and cancels old jumps',
      (tester) async {
    tester.view.physicalSize = const Size(960, 540);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    final storage = StorageService();
    await storage.init();
    final prefs = AppPreferences(storage);
    await prefs.init();
    prefs.isTelevision = true;
    final guide = _Guide(storage);
    final rows = [
      for (var i = 0; i < 1000; i++)
        ChannelSearchResult(Channel(
            id: 'row$i',
            rawId: 'row$i',
            playlistId: 'test',
            name: i.isEven
                ? 'Channel $i'
                : 'Channel $i with a much longer station name and extra regional information',
            group: 'Sports',
            url: 'https://example.invalid/never-play'))
    ];
    final revision = ValueNotifier(0);
    final outside = FocusNode();
    await tester.pumpWidget(MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: prefs),
          ChangeNotifierProvider<EpgService>.value(value: guide),
        ],
        child: MaterialApp(
            home: Scaffold(
                body: Column(children: [
          TextButton(
              focusNode: outside,
              onPressed: () {},
              child: const Text('Search')),
          Expanded(
              child: ValueListenableBuilder<int>(
                  valueListenable: revision,
                  builder: (context, value, _) => SportsChannelList(
                      rows: value == 0 ? rows : rows.take(20).toList(),
                      search: value != 0,
                      searchKey: '$value',
                      onChoose: (_) {}))),
        ])))));
    await tester.pumpAndSettle();
    for (var i = 0; i < 160; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
    }
    FocusNode rowNode(int i) => tester
        .widget<InkWell>(find.byKey(ValueKey('game-channel:row$i')))
        .focusNode!;
    expect(rowNode(160).hasFocus, isTrue);
    final dynamic list = tester.state(find.byType(SportsChannelList));
    expect(list.mountedFocusNodeCount, lessThan(30),
        reason: 'Keep only visible/cached rows, not every row visited');
    for (var i = 0; i < 5; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    }
    await tester.pumpAndSettle();
    expect(rowNode(165).hasFocus, isTrue);
    for (var i = 164; i >= 140; i--) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pumpAndSettle();
      expect(rowNode(i).hasFocus, isTrue);
      final row = tester.getRect(find.byKey(ValueKey('game-channel:row$i')));
      final viewport = tester.getRect(find.byType(ListView));
      expect(row.top, greaterThanOrEqualTo(viewport.top - .1),
          reason: 'Upward navigation must keep the focused row visible');
      expect(row.bottom, lessThanOrEqualTo(viewport.bottom + .1));
    }
    // A pending offscreen seek must not reclaim focus from a new search.
    list.focusFirst();
    revision.value = 1;
    outside.requestFocus();
    await tester.pumpAndSettle();
    expect(outside.hasFocus, isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    revision.dispose();
    outside.dispose();
    prefs.dispose();
    guide.dispose();
  });
}
