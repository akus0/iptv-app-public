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
import 'package:nox_iptv/services/sports_channel_attempts.dart';
import 'package:nox_iptv/services/sports_channel_matcher.dart';
import 'package:nox_iptv/services/storage_service.dart';
import 'package:nox_iptv/utils/sports_channel_variants.dart';
import 'package:nox_iptv/widgets/sports_channel_picker.dart';

final start = DateTime.utc(2026, 10, 28, 12);
SportsGame game([String id = 'match', DateTime? at]) => SportsGame(
    id: id,
    league: sportsLeagueById('tennis.atp')!,
    start: at ?? start,
    state: GameState.live,
    statusText: 'Live',
    home: const SportsTeam(
        id: 'a', name: 'Player One', shortName: 'One', abbreviation: 'ONE'),
    away: const SportsTeam(
        id: 'b', name: 'Player Two', shortName: 'Two', abbreviation: 'TWO'));
ChannelSearchResult row(String id, String name,
    {String playlist = 'test',
    String group = 'UK Sports',
    EpgProgram? programme}) {
  final channel = Channel(
      id: id,
      rawId: id,
      playlistId: playlist,
      name: name,
      group: group,
      url: 'https://example.invalid/$id');
  return ChannelSearchResult(channel,
      match:
          ChannelMatch(channel, MatchReason.sport, 100, programme: programme),
      programme: programme);
}

class _Matcher extends SportsChannelMatcher {
  _Matcher(super.epg);
  int calls = 0;
  @override
  Future<List<ChannelMatch>> alternativesFor(SportsGame game,
      {List<ChannelMatch> matches = const [],
      bool Function()? isCancelled}) async {
    calls++;
    return matches;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
      'quality versions retain rank; regions, feeds and providers stay separate',
      () {
    final rows = [
      row('a', 'UK: Sky Sports Tennis UHD'),
      row('b', 'UK: Sky Sports Tennis HD'),
      row('c', 'UK: Sky Sports Tennis FHD HEVC 50fps'),
      row('d', 'DE: Sky Sports Tennis HD'),
      row('e', 'UK: Sky Sports Tennis HD', playlist: 'other'),
      row('f', 'UK: Sky Sports Tennis HD', group: 'US Sports'),
      row('g', 'UK: Sky Sports Tennis 2 HD'),
      row('h', 'UK: Sky Sports Tennis + HD'),
      row('i', 'UK: Sky Sports Tennis Backup HD'),
      row('j', 'UK: Sky Sports Tennis 1080p25'),
      row('k', 'UK: Sky Sports Tennis 1080p50'),
      row('l', 'UK: Sky Sports Tennis 720p60fps'),
      row('m', 'UK: Sky Sports Tennis 576p25'),
      row('n', 'UK: Sky Sports Tennis 480i30'),
    ];
    final groups = groupSportsChannelVariants(rows);
    expect(groups, hasLength(7));
    expect(groups.first.rows.map((r) => r.channel.id),
        ['a', 'b', 'c', 'j', 'k', 'l', 'm', 'n']);
    expect(groups.first.rows.first, same(rows.first));
    expect(rows, hasLength(14));
  });

  test('conflicting guide slots are never hidden as quality versions', () {
    EpgProgram programme(String title, [int offset = 0]) => EpgProgram(
        channelId: 'guide',
        title: title,
        start: start.add(Duration(hours: offset)),
        stop: start.add(Duration(hours: offset + 2)));
    expect(
        groupSportsChannelVariants([
          row('a', 'Tennis HD', programme: programme('First match')),
          row('b', 'Tennis FHD', programme: programme('Second match')),
          row('c', 'Tennis UHD', programme: programme('First match', 2)),
          row('d', 'Tennis SD'),
        ]),
        hasLength(3));
  });

  test('same regional channel groups across guide and sports categories', () {
    EpgProgram programme(String title) => EpgProgram(
        channelId: 'guide',
        title: title,
        start: start,
        stop: start.add(const Duration(hours: 2)));
    final rows = [
      row('saved', 'Sky Sports Tennis 1080p25', group: 'UK | Sky Sports'),
      row('guide', 'Sky Sports Tennis',
          group: 'TV Guide (UK)', programme: programme('WTA Guangzhou ᴸᶦᵛᵉ')),
      row('hd', 'UK: Sky Sports Tennis 1080p25',
          group: 'UK | Sky Sports',
          programme: programme('Live: WTA Guangzhou')),
      row('fhd', 'Sky Sports Tennis 1080p50',
          group: 'UK | Sports', programme: programme('WTA Guangzhou LIVE')),
      row('sd', 'Sky Sports Tennis 576p25',
          group: 'UK | Sky Sports', programme: programme('WTA Guangzhou LIVE')),
      row('de', 'DE: Sky Sports Tennis HD',
          group: 'Germany | Sport',
          programme: programme('Live: WTA Guangzhou')),
      row('raw', 'WWE RAW', group: 'UK Sports'),
      row('wwe', 'WWE', group: 'UK Sports'),
    ];
    final groups = groupSportsChannelVariants(rows);
    expect(groups, hasLength(4));
    expect(groups.first.rows.map((r) => r.channel.id),
        ['saved', 'guide', 'hd', 'fhd', 'sd']);
    expect(groups.first.rows.first, same(rows.first));
  });

  test('unknown regions need matching guide evidence across categories', () {
    final programme = EpgProgram(
        channelId: 'guide',
        title: 'Tokyo tennis',
        start: start,
        stop: start.add(const Duration(hours: 2)));
    final rows = [
      row('a', 'Tennis Channel 2', group: 'Platform One', programme: programme),
      row('b', 'Tennis Channel 2 HD',
          group: 'Platform Two', programme: programme),
      row('c', 'Tennis Channel 2 UHD', group: 'Platform Three'),
    ];
    final groups = groupSportsChannelVariants(rows);
    expect(groups, hasLength(2));
    expect(groups.first.rows.map((r) => r.channel.id), ['a', 'b']);
    expect(groups.last.rows.single.channel.id, 'c');
  });

  test(
      'attempt history is event-scoped, bounded and expires without affecting picks',
      () {
    var now = start;
    final history = SportsChannelAttempts(clock: () => now);
    history.record(game(), 'first');
    final snapshot = history.forGame(game());
    history.record(game(), 'second');
    expect(snapshot, {'first'});
    expect(history.forGame(game()), {'first', 'second'});
    expect(
        history.forGame(game('match', start.add(const Duration(minutes: 45)))),
        {'first', 'second'});
    expect(history.forGame(game('other')), isEmpty);
    expect(history.forGame(game('match', start.add(const Duration(days: 1)))),
        isEmpty);
    for (var i = 0; i < 200; i++) {
      history.record(game(), 'channel$i');
    }
    expect(history.forGame(game()), hasLength(128));
    now = now.add(const Duration(hours: 12));
    expect(history.forGame(game()), isEmpty);
    for (var i = 0; i < 81; i++) {
      history.record(game('$i'), 'channel');
    }
    expect(history.forGame(game('0')), isEmpty);
    expect(history.forGame(game('80')), {'channel'});
  });

  test('large variant lists group in one pass without dropping choices', () {
    final rows = [
      for (var i = 0; i < 4000; i++)
        row('$i', 'UK: Sports ${i ~/ 4} ${['SD', 'HD', 'FHD', 'UHD'][i % 4]}')
    ];
    final clock = Stopwatch()..start();
    final groups = groupSportsChannelVariants(rows);
    expect(groups, hasLength(1000));
    expect(groups.expand((g) => g.rows), hasLength(4000));
    // Diagnostic only: avoid machine-dependent speed assertions.
    debugPrint(
        'SPORTS_VARIANTS rows=4000 groups=1000 us=${clock.elapsedMicroseconds}');
  });

  for (final size in [
    const Size(390, 844),
    const Size(844, 390),
    const Size(1280, 720)
  ]) {
    testWidgets('versions and trial history work across reopen at $size',
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
      final epg = EpgService(storage);
      final matcher = _Matcher(epg);
      final history = SportsChannelAttempts();
      final matches = [
        row('hd', 'UK: Sky Sports Tennis HD').match!,
        row('uhd', 'UK: Sky Sports Tennis UHD').match!,
        row('other', 'Tennis Channel HD').match!,
      ];
      SportsChannelChoice? choice;
      await tester.pumpWidget(MultiProvider(
          providers: [
            ChangeNotifierProvider.value(value: prefs),
            ChangeNotifierProvider.value(value: epg),
          ],
          child: MaterialApp(
              theme: ThemeData.dark(),
              home: Builder(
                  builder: (context) => Scaffold(
                      body: TextButton(
                          onPressed: () async {
                            choice = await showDialog<SportsChannelChoice>(
                                context: context,
                                builder: (_) => SportsChannelPickerDialog(
                                    game: game(),
                                    matches: matches,
                                    matcher: matcher,
                                    attempts: history));
                          },
                          child: const Text('Open')))))));
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(find.text('UK: Sky Sports Tennis HD'), findsOneWidget);
      expect(find.text('UK: Sky Sports Tennis UHD'), findsNothing);
      if (prefs.isTelevision) {
        tester
            .widget<InkWell>(find.byKey(const ValueKey('game-channel:hd')))
            .focusNode!
            .requestFocus();
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      } else {
        await tester.tap(find.textContaining('2 versions'));
      }
      await tester.pumpAndSettle();
      expect(find.text('Channel versions'), findsOneWidget);
      if (prefs.isTelevision) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.sendKeyEvent(LogicalKeyboardKey.select);
      } else {
        await tester
            .ensureVisible(find.byKey(const ValueKey('game-channel:uhd')));
        await tester.tap(find.byKey(const ValueKey('game-channel:uhd')));
      }
      await tester.pumpAndSettle();
      expect(choice?.channel?.id, 'uhd');
      expect(history.forGame(game()), {'uhd'});
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(matcher.calls, 1);
      expect(
          find.byWidgetPredicate((w) =>
              w is Text &&
              (w.textSpan?.toPlainText().contains('1 tried') ?? false)),
          findsOneWidget);
      await tester.tap(find.textContaining('2 versions'));
      await tester.pumpAndSettle();
      expect(
          find.byWidgetPredicate((w) =>
              w is Text &&
              (w.textSpan?.toPlainText().contains('Tried') ?? false)),
          findsOneWidget);
      await tester.tap(find.byTooltip('Back to suggestions'));
      await tester.pumpAndSettle();
      expect(find.text('Channel versions'), findsNothing);
      expect(choice?.channel?.id, 'uhd');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      epg.dispose();
      prefs.dispose();
    });
  }
}
