import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:nox_iptv/services/app_preferences.dart';
import 'package:nox_iptv/models/channel.dart';
import 'package:nox_iptv/models/epg_program.dart';
import 'package:nox_iptv/models/sports.dart';
import 'package:nox_iptv/services/epg_service.dart';
import 'package:nox_iptv/services/storage_service.dart';
import 'package:nox_iptv/utils/sports_presentation.dart';
import 'package:nox_iptv/widgets/channel_now_label.dart';
import 'package:nox_iptv/widgets/compact_choice_list.dart';
import 'package:nox_iptv/widgets/sports_filter_picker.dart';

class _Epg extends EpgService {
  _Epg() : super(StorageService());
  EpgProgram? programme;
  String? lookup;
  @override
  EpgProgram? getCurrentProgram(String channelId) {
    lookup = channelId;
    return programme;
  }
}

SportsGame game(String id, String league) => SportsGame(
    id: id,
    league: sportsLeagueById(league)!,
    start: DateTime.utc(2026, 10, 21),
    state: GameState.live,
    statusText: 'Live',
    home: const SportsTeam(
        id: 'h', name: 'Home', shortName: 'Home', abbreviation: 'H'),
    away: const SportsTeam(
        id: 'a', name: 'Away', shortName: 'Away', abbreviation: 'A'));

void main() {
  test(
      'picker ranks groups by activity, keeps All pinned and sorts inside groups',
      () {
    const options = [
      SportsFilterOption('college', 'A College', Icons.sports,
          group: 'Football', priority: 20, live: 8, upcoming: 0),
      SportsFilterOption('nfl', 'NFL', Icons.sports,
          group: 'Football', priority: 2, live: 0, upcoming: 6),
      SportsFilterOption('', 'All leagues', Icons.sports),
      SportsFilterOption('nba', 'NBA', Icons.sports,
          group: 'Basketball', priority: 2, live: 1, upcoming: 1),
    ];
    List<String> ids(SportsPickerSort sort) =>
        sortSportsOptions(options, sort).map((o) => o.id).toList();
    expect(ids(SportsPickerSort.top), ['', 'nba', 'nfl', 'college']);
    expect(ids(SportsPickerSort.live), ['', 'college', 'nfl', 'nba']);
    expect(ids(SportsPickerSort.upcoming), ['', 'nfl', 'college', 'nba']);
    expect(ids(SportsPickerSort.name), ['', 'nba', 'college', 'nfl']);
    expect(options.first.id, 'college');
  });

  test('major competitions lead consistently in event rows and league picker',
      () {
    for (final ids in [
      [
        'fifa.world',
        'uefa.champions',
        'uefa.euro',
        'eng.1',
        'esp.1',
        'ita.1',
        'ger.1',
        'fra.1',
        'uefa.europa',
        'fifa.wwc',
        'uefa.wchampions'
      ],
      [
        'nba',
        'basketball.mens-college-basketball',
        'wnba',
        'basketball.womens-college-basketball'
      ],
      ['golf.pga', 'golf.eur', 'golf.liv', 'golf.lpga'],
      ['tennis.atp', 'tennis.wta'],
      ['nfl', 'college-football'],
      ['rugby.164205', 'rugby.270557'],
    ]) {
      final reversed = ids.reversed;
      expect(
          orderSportsGames(reversed.map((id) => game(id, id)),
              followed: (_) => false).map((g) => g.league.id),
          ids);
      expect(
          sortSportsOptions([
            for (final id in reversed)
              SportsFilterOption(id, sportsLeagueById(id)!.name, Icons.sports,
                  priority: leagueDisplayPriority(sportsLeagueById(id)!)),
          ], SportsPickerSort.top)
              .map((o) => o.id),
          ids);
    }
  });

  test(
      'activity sorting keeps groups whole and handles zero and missing counts',
      () {
    const options = [
      SportsFilterOption('', 'All leagues', Icons.sports, live: 100),
      SportsFilterOption('a0', 'A idle', Icons.sports, group: 'A', priority: 1),
      SportsFilterOption('a1', 'A live', Icons.sports, group: 'A', live: 2),
      SportsFilterOption('b0', 'B idle', Icons.sports, group: 'B', live: 0),
      SportsFilterOption('b1', 'B live', Icons.sports, group: 'B', live: 4),
      SportsFilterOption('c1', 'C live', Icons.sports, group: 'C', live: 2),
    ];
    expect(sortSportsOptions(options, SportsPickerSort.live).map((o) => o.id),
        ['', 'b1', 'b0', 'a1', 'a0', 'c1']);
    expect(
        sortSportsOptions(options, SportsPickerSort.upcoming).map((o) => o.id),
        ['', 'a0', 'a1', 'b0', 'b1', 'c1']);
    // Without groups, the sport picker still ranks individual sport counts.
    expect(
        sortSportsOptions([
          for (final o in options)
            SportsFilterOption(o.id, o.label, o.icon, live: o.live)
        ], SportsPickerSort.live)
            .map((o) => o.id),
        ['', 'b1', 'a1', 'c1', 'a0', 'b0']);
  });

  testWidgets(
      'league picker buttons reorder groups and leagues on phone and TV',
      (tester) async {
    for (final size in [const Size(390, 844), const Size(1280, 720)]) {
      await tester.binding.setSurfaceSize(size);
      SharedPreferences.setMockInitialValues({});
      final storage = StorageService();
      await storage.init();
      final prefs = AppPreferences(storage);
      await prefs.init();
      prefs.isTelevision = size.width >= 960;
      await tester.pumpWidget(ChangeNotifierProvider.value(
          value: prefs,
          child: MaterialApp(
              theme: ThemeData.dark(),
              home: Builder(
                  builder: (context) => Scaffold(
                      body: TextButton(
                          onPressed: () => showSportsFilterPicker(context,
                                  title: 'Choose league',
                                  selected: '',
                                  topFirst: true,
                                  options: const [
                                    SportsFilterOption(
                                        '', 'All leagues', Icons.sports),
                                    SportsFilterOption(
                                        'nfl', 'NFL', Icons.sports,
                                        group: 'American football',
                                        priority: 2,
                                        upcoming: 8),
                                    SportsFilterOption(
                                        'wnba', 'WNBA', Icons.sports,
                                        group: 'Basketball',
                                        priority: 4,
                                        live: 3),
                                    SportsFilterOption(
                                        'nba', 'NBA', Icons.sports,
                                        group: 'Basketball',
                                        priority: 2,
                                        live: 1,
                                        upcoming: 2),
                                  ]),
                          child: const Text('Open')))))));
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      List<String> ids() => tester
          .widget<CompactChoiceList>(find.byType(CompactChoiceList))
          .choices
          .map((c) => c.id)
          .toList();
      expect(ids(), ['', 'nfl', 'nba', 'wnba']);
      await tester.tap(find.byKey(const ValueKey('sports-sort-live')));
      await tester.pumpAndSettle();
      expect(ids(), ['', 'wnba', 'nba', 'nfl']);
      expect(tester.getTopLeft(find.text('Basketball')).dy,
          lessThan(tester.getTopLeft(find.text('American football')).dy));
      await tester.tap(find.byKey(const ValueKey('sports-sort-upcoming')));
      await tester.pumpAndSettle();
      expect(ids(), ['', 'nfl', 'nba', 'wnba']);
      await tester.tap(find.byKey(const ValueKey('sports-sort-name')));
      await tester.pumpAndSettle();
      expect(ids(), ['', 'nfl', 'nba', 'wnba']);
      await tester.tap(find.byKey(const ValueKey('sports-sort-top')));
      await tester.pumpAndSettle();
      expect(ids(), ['', 'nfl', 'nba', 'wnba']);
      final beforeSearch = tester.getRect(find.byType(Dialog));
      final searchHeight = tester.getSize(find.byType(TextField)).height;
      if (prefs.isTelevision) {
        tester
            .widget<TextField>(find.byType(TextField))
            .focusNode!
            .requestFocus();
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.select);
        await tester.pump();
      }
      await tester.enterText(find.byType(TextField), 'NBA');
      await tester.pumpAndSettle();
      expect(ids(), ['nba', 'wnba']);
      expect(tester.getSize(find.byType(TextField)).height, searchHeight);
      expect(tester.getRect(find.byType(Dialog)), beforeSearch);
      await tester.enterText(find.byType(TextField), 'no such league');
      await tester.pumpAndSettle();
      expect(find.text('No matches'), findsOneWidget);
      expect(tester.getRect(find.byType(Dialog)), beforeSearch);
      await tester.tap(find.byTooltip('Clear search'));
      await tester.pumpAndSettle();
      expect(ids(), ['', 'nfl', 'nba', 'wnba']);
      expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
          isEmpty);
      expect(tester.getRect(find.byType(Dialog)), beforeSearch);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      prefs.dispose();
    }
    await tester.binding.setSurfaceSize(null);
  });

  test('league labels distinguish college soccer from American football', () {
    expect(
        leagueDescription(sportsLeagueById('usa.ncaa.m.1')!), 'College soccer');
    expect(leagueDescription(sportsLeagueById('college-football')!),
        'College football');
    expect(
        leagueDescription(
            sportsLeagueById('basketball.womens-college-basketball')!),
        'Women’s college basketball');
    expect(
        leagueDescription(sportsLeagueById('tennis.wta')!), 'Women’s tennis');
  });

  test(
      'top leagues lead; equal-priority followed teams and original order stay stable',
      () {
    final games = [
      game('college', 'usa.ncaa.m.1'),
      game('local', 'usa.1'),
      game('premier-first', 'eng.1'),
      game('champions', 'uefa.champions'),
      game('premier-followed', 'eng.1'),
      game('premier-last', 'eng.1')
    ];
    final sorted =
        orderSportsGames(games, followed: (g) => g.id.endsWith('followed'));
    expect(sorted.map((g) => g.id), [
      'champions',
      'premier-followed',
      'premier-first',
      'premier-last',
      'local',
      'college'
    ]);
    expect(
        games.first.id, 'college'); // The shared service snapshot is untouched.
  });

  test(
      'EPG labels use mapped channel IDs and never mislabel a stale/future slot',
      () {
    final epg = _Epg();
    final now = DateTime.now();
    final channel = Channel(
        id: 'p::1',
        rawId: '1',
        playlistId: 'p',
        name: 'Sports HD',
        group: 'Sport',
        url: 'https://example.test/live',
        epgIdOverride: 'mapped');
    epg.programme = EpgProgram(
        channelId: 'mapped',
        title: 'Live final',
        start: now.subtract(const Duration(minutes: 10)),
        stop: now.add(const Duration(minutes: 30)));
    expect(channelNowText(epg, channel), contains(' · Live final'));
    expect(epg.lookup, 'mapped');
    epg.programme = EpgProgram(
        channelId: 'mapped',
        title: 'Tomorrow’s game',
        start: now.add(const Duration(days: 1)),
        stop: now.add(const Duration(days: 2)));
    expect(channelNowText(epg, channel), 'No current programme data');
    epg.programme = EpgProgram(
        channelId: 'mapped',
        title: 'Yesterday’s game',
        start: now.subtract(const Duration(days: 2)),
        stop: now.subtract(const Duration(days: 1)));
    expect(channelNowText(epg, channel), 'No current programme data');
    epg.dispose();
  });

  testWidgets(
      'compact grouped picker stays lazy and remote focus crosses offscreen groups',
      (tester) async {
    String? picked;
    await tester.pumpWidget(MaterialApp(
        theme: ThemeData.dark(),
        home: Scaffold(
            body: Center(
                child: SizedBox(
                    width: 340,
                    height: 260,
                    child: CompactChoiceList(selected: 'league-35', choices: [
                      for (var i = 0; i < 1000; i++)
                        CompactChoice(
                            id: 'league-$i',
                            title: 'League $i',
                            subtitle: 'Short explanation',
                            group: 'Sport ${i ~/ 10}',
                            onTap: () => picked = '$i'),
                    ]))))));
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'choice-league-35');
    expect(find.byType(InkWell).evaluate().length, lessThan(20));
    for (var i = 0; i < 25; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
    }
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'choice-league-60');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(picked, '60');
    final dynamic listState = tester.state(find.byType(CompactChoiceList));
    expect(listState.mountedFocusNodeCount, lessThan(22));

    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
