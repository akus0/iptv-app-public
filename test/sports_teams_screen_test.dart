import 'package:nox_iptv/widgets/sports_header_controls.dart';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:nox_iptv/widgets/compact_choice_list.dart';
import 'package:nox_iptv/widgets/standings_team_tile.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:nox_iptv/models/sports.dart';
import 'package:nox_iptv/utils/sports_presentation.dart';
import 'package:nox_iptv/screens/sports_teams_screen.dart';
import 'package:nox_iptv/services/app_preferences.dart';
import 'package:nox_iptv/services/storage_service.dart';
import 'package:nox_iptv/services/sports_follows.dart';
import 'package:nox_iptv/services/sports_standings_service.dart';
import 'sports_standings_service_test.dart' show table;

class RecordingStandings extends SportsStandingsService {
  RecordingStandings({this.data = const LeagueStandings()});
  final LeagueStandings data;
  int loads = 0;
  SportsLeague? requested;
  @override
  Future<LeagueStandings> load(SportsLeague league,
      {bool refresh = false, bool rememberSelection = true}) async {
    requested = league;
    loads++;
    return data;
  }
}

void main() {
  late StorageService storage;
  late SportsFollows follows;
  late AppPreferences prefs;
  late SportsStandingsService service;
  var calls = 0;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    storage = StorageService();
    await storage.init();
    follows = SportsFollows.load(storage);
    prefs = AppPreferences(storage);
    await prefs.init();
    calls = 0;
    service = SportsStandingsService(client: MockClient((r) async {
      calls++;
      return http.Response(table(teams: 500), 200);
    }));
  });
  tearDown(() {
    service.close();
    prefs.dispose();
  });
  Future<void> open(WidgetTester tester,
      {bool favorites = false, Size size = const Size(960, 540)}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    if (!favorites) {
      await tester.runAsync(() => service.load(sportsLeagueById('eng.1')!));
    }
    await tester.pumpWidget(ChangeNotifierProvider.value(
        value: prefs,
        child: MaterialApp(
            home: SportsTeamsScreen(
                follows: follows,
                service: service,
                favorites: favorites,
                initialLeague: sportsLeagueById('eng.1')))));
    if (!favorites) {
      await tester.runAsync(() => service.load(sportsLeagueById('eng.1')!));
    }
    await tester.pumpAndSettle();
  }

  testWidgets(
      'Add team stays at top; favourite list starts without sports requests',
      (tester) async {
    await tester
        .runAsync(() => follows.follow('eng.1', '1', name: 'Saved Team'));
    await open(tester, favorites: true);
    expect(calls, 0);
    expect(tester.getTopLeft(find.byKey(const ValueKey('add-team'))).dy,
        lessThan(tester.getTopLeft(find.text('Saved Team')).dy));
    await tester.tap(find.byTooltip('Remove favourite'));
    await tester.pumpAndSettle();
    expect(follows.isEmpty, isTrue);
    expect(storage.getSportsFollowedTeams(), isEmpty);
  });
  for (final size in [
    const Size(320, 568),
    const Size(844, 390),
    const Size(960, 540)
  ]) {
    testWidgets(
        'large table is lazy, searchable and usable with keyboard at $size',
        (tester) async {
      await open(tester, size: size);
      expect(calls, 1);
      expect(find.byType(StandingsTeamTile).evaluate().length, lessThan(30));
      await tester.enterText(find.byType(TextField), 'Team 499');
      tester.view.viewInsets =
          FakeViewPadding(bottom: size.width > size.height ? 180 : 280);
      await tester.pumpAndSettle();
      expect(
          tester.widget<TextField>(find.byType(TextField)).focusNode!.hasFocus,
          isTrue);
      expect(find.text('Team 499', findRichText: true).last.hitTestable(),
          findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const ValueKey('follow-499')));
      await tester.pumpAndSettle();
      expect(follows.isFollowed('eng.1', '499'), isTrue);
      final restored = SportsFollows.load(storage);
      expect(restored.nameOf(restored.teams.single), 'Team 499');
      expect(calls, 1);
    });
  }
  testWidgets(
      'team details retain full record without reloading standings or toggling favourites',
      (tester) async {
    await open(tester, size: const Size(320, 568));
    expect(find.text('PTS'), findsOneWidget);
    await tester.tap(find.text('Team 1'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Standings breakdown'));
    await tester.pumpAndSettle();
    expect(
        find.descendant(
            of: find.byType(SportsCompactDialog),
            matching: find.text('Position')),
        findsOneWidget);
    expect(
        find.descendant(
            of: find.byType(SportsCompactDialog),
            matching: find.text('Points')),
        findsOneWidget);
    expect(follows.isEmpty, isTrue);
    expect(calls, 1);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Close').first);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('sport and league browsing is local; cancel preserves search',
      (tester) async {
    await open(tester);
    await tester.enterText(find.byType(TextField), 'Team 499');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('standings-sport')));
    await tester.pumpAndSettle();
    final search = find.descendant(
        of: find.byType(Dialog), matching: find.byType(TextField));
    await tester.enterText(search, 'basketball');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Basketball'));
    await tester.pumpAndSettle();
    expect(find.text('Basketball leagues'), findsOneWidget);
    expect(find.byKey(const ValueKey('sports-sort-live')), findsNothing);
    expect(find.byKey(const ValueKey('sports-sort-upcoming')), findsNothing);
    final choices = tester
        .widget<CompactChoiceList>(find.byType(CompactChoiceList))
        .choices;
    expect(choices.any((c) => c.id == 'nba'), isTrue);
    expect(choices.every((c) => c.group == null), isTrue);
    expect(find.byType(ChoiceChip), findsNothing);
    expect(find.byKey(const ValueKey('sports-sort-top')), findsNothing);
    expect(calls, 1);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsNothing);
    expect(find.text('Team 499'), findsWidgets);
    expect(calls, 1);
  });

  testWidgets('league picker stays scoped and cancelling does not fetch',
      (tester) async {
    tester.view.physicalSize = const Size(960, 540);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    // This is a UI request-boundary test; cache timing is tested by the service.
    final recording = RecordingStandings(
        data: const LeagueStandings(tables: [
      StandingTable('League', [
        StandingTeam(
            SportsTeam(
                id: '1',
                name: 'Team One',
                shortName: 'Team One',
                abbreviation: 'ONE'),
            {'points': '9'},
            1)
      ]),
    ]));
    addTearDown(recording.close);
    await tester.pumpWidget(ChangeNotifierProvider.value(
        value: prefs,
        child: MaterialApp(
            home: SportsTeamsScreen(
                follows: follows,
                service: recording,
                initialLeague: sportsLeagueById('eng.1')))));
    await tester.pumpAndSettle();
    expect(recording.loads, 1);
    await tester.tap(find.byKey(const ValueKey('standings-league')));
    await tester.pumpAndSettle();
    expect(find.text('Football / Soccer leagues'), findsOneWidget);
    final choices = tester
        .widget<CompactChoiceList>(find.byType(CompactChoiceList))
        .choices;
    expect(
        choices.every(
            (c) => sportsLeagueById(c.id)!.espnPath.startsWith('soccer/')),
        isTrue);
    final priorities = choices
        .map((c) => leagueDisplayPriority(sportsLeagueById(c.id)!))
        .toList();
    expect(priorities, orderedEquals([...priorities]..sort()),
        reason: 'Top leagues remain the default order');
    expect(choices.every((c) => c.group == null), isTrue);
    expect(find.byType(ChoiceChip), findsNothing);
    expect(find.byKey(const ValueKey('sports-sort-top')), findsNothing);
    final search = find.descendant(
        of: find.byType(Dialog), matching: find.byType(TextField));
    await tester.enterText(search, 'NBA');
    await tester.pumpAndSettle();
    expect(find.text('No matches'), findsOneWidget);
    expect(find.text('Search all sports'), findsNothing);
    expect(recording.loads, 1);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(recording.loads, 1);
    expect(find.text('Premier League'), findsOneWidget);
  });

  testWidgets('favourites add still offers leagues across every sport',
      (tester) async {
    await open(tester, favorites: true);
    await tester.tap(find.byKey(const ValueKey('add-team')));
    await tester.pumpAndSettle();
    final choices = tester
        .widget<CompactChoiceList>(find.byType(CompactChoiceList))
        .choices;
    expect(choices.any((c) => c.id == 'nba'), isTrue);
    expect(choices.any((c) => c.id == 'eng.1'), isTrue);
    expect(calls, 0);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(calls, 0);
  });

  testWidgets('conference and favourites filters clear without refetching',
      (tester) async {
    service.close();
    final fixture = jsonDecode(table(teams: 4)) as Map<String, dynamic>;
    final groups = fixture['children'] as List;
    groups.add({
      'name': 'Conference B',
      'standings': {
        'entries': [
          {
            'team': {'id': '500', 'displayName': 'Other Team'},
            'stats': [
              {'name': 'points', 'displayValue': '12'}
            ]
          }
        ]
      }
    });
    service = SportsStandingsService(client: MockClient((r) async {
      calls++;
      return http.Response(jsonEncode(fixture), 200);
    }));
    await follows.follow('eng.1', '500', name: 'Other Team');
    await open(tester);
    await tester.tap(find.text('All conferences'));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(
        of: find.byType(Dialog), matching: find.text('Conference B')));
    await tester.pumpAndSettle();
    expect(find.text('Other Team'), findsOneWidget);
    expect(find.text('Team 1'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('standings-favourites-only')));
    await tester.pumpAndSettle();
    expect(find.text('Other Team'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('follow-500')));
    await tester.pumpAndSettle();
    expect(find.text('Clear filters'), findsOneWidget);
    await tester.tap(find.text('Clear filters'));
    await tester.pumpAndSettle();
    expect(find.text('Team 1'), findsOneWidget);
    expect(calls, 1);
  });

  testWidgets('removing a favourite can undo to its original position',
      (tester) async {
    for (var i = 1; i <= 3; i++) {
      await follows.follow('eng.1', '$i', name: 'Saved $i');
    }
    await open(tester, favorites: true);
    await tester.tap(find.byTooltip('Remove favourite').at(1));
    await tester.pumpAndSettle();
    expect(follows.teams.map((t) => t.teamId), ['1', '3']);
    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(follows.teams.map((t) => t.teamId), ['1', '2', '3']);
    expect(calls, 0);
  });

  test('saved favourite logos survive restart and removal', () async {
    await follows.follow('eng.1', '1',
        name: 'One', logoUrl: 'https://a.espncdn.com/logo.png');
    final restored = SportsFollows.load(storage);
    expect(restored.logoOf(restored.teams.single),
        'https://a.espncdn.com/logo.png');
    await restored.unfollow('eng.1', '1');
    expect(storage.getSportsTeamLogos(), isEmpty);
  });

  test('phone columns keep points and avoid duplicate racing points', () {
    expect(
        visibleStandingsColumns({'wins', 'points', 'gamesPlayed'}, 320)
            .map((c) => c.key),
        ['points']);
    expect(
        visibleStandingsColumns({'points', 'championshipPts'}, 960)
            .map((c) => c.key),
        ['championshipPts']);
  });

  test('AFL percentage and constructor championship points stay meaningful',
      () {
    expect(
        visibleStandingsColumns({'points', 'percentage', 'wins'}, 400,
                sport: 'australian-football')
            .map((c) => c.key),
        ['percentage', 'points']);
    const constructor = StandingTeam(
        SportsTeam(
            id: 'c', name: 'Constructor', shortName: 'C', abbreviation: 'C'),
        {'points': '607'},
        1);
    final mixed = visibleStandingsColumns({'points', 'championshipPts'}, 960,
        sport: 'racing');
    expect(mixed, hasLength(1));
    expect(standingColumnValue(constructor, mixed.single), '607');
    expect(
        visibleStandingsColumns({'wins', 'losses', 'points'}, 320,
                sport: 'volleyball')
            .single
            .key,
        'winLossRecord');
    expect(
        visibleStandingsColumns({'rankingPoints', 'points'}, 320,
                sport: 'rugby', rankings: true)
            .single
            .key,
        'rankingPoints');
  });

  test('college tables distinguish supplied conference and overall records',
      () {
    const stats = {
      'wins',
      'overall',
      'vs. Conf.',
      'gamesBehind',
      'pointDifferential'
    };
    final columns = visibleStandingsColumns(stats, 960,
        sport: 'football', leagueId: 'college-football');
    expect(columns.map((c) => c.key),
        ['vs. Conf.', 'overall', 'pointDifferential']);
    const row = StandingTeam(
        SportsTeam(id: '1', name: 'Team', shortName: 'Team', abbreviation: 'T'),
        {'wins': '7', 'overall': '7-1', 'vs. Conf.': '4-0'},
        1);
    expect(standingColumnValue(row, columns.first), '4-0');
    expect(standingColumnValue(row, columns[1]), '7-1');
    expect(
        visibleStandingsColumns(stats, 320,
                sport: 'football', leagueId: 'college-football')
            .single
            .label,
        'CONF');
  });

  testWidgets('column headings remain visible while a large table scrolls',
      (tester) async {
    await open(tester);
    final heading = find.byType(StandingsTableHeader);
    final position = tester.getTopLeft(heading);
    final list = tester.widget<ListView>(find.byType(ListView));
    list.controller!.jumpTo(900);
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(heading), position);
    expect(find.text('Team 1'), findsNothing);
    expect(find.text('PTS'), findsOneWidget);
    expect(find.byType(StandingsTeamTile).evaluate().length, lessThan(30));
    expect(calls, 1);
  });

  testWidgets(
      'TV table starts promptly below compact controls and focus is stable',
      (tester) async {
    await open(tester);
    final first = find.byType(StandingsTeamTile).first;
    final bounds = tester.getRect(first);
    expect(bounds.top, lessThan(215));
    expect(bounds.height, inInclusiveRange(44, 56));
    final seventh = find.byType(StandingsTeamTile).at(6);
    expect(tester.getRect(seventh).top, lessThan(540));
    final title = tester.widget<Text>(find.text('Team 1'));
    tester
        .widget<Focus>(
            find.descendant(of: first, matching: find.byType(Focus)).first)
        .onFocusChange!(true);
    await tester.pump();
    expect(tester.getRect(first), bounds);
    expect(tester.widget<Text>(find.text('Team 1')), same(title),
        reason: 'Focus decoration keeps the row contents unchanged');
    final rowPoint = find.descendant(of: first, matching: find.text('9'));
    final headerPoint = find.text('PTS');
    expect(tester.getTopRight(rowPoint).dx,
        closeTo(tester.getTopRight(headerPoint).dx, .1));
    FocusManager.instance.rootScope.traversalDescendants
        .firstWhere((node) =>
            node.context?.findAncestorWidgetOfExactType<InkWell>()?.key ==
            const ValueKey('record-1'))
        .requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('standings-search')))
            .focusNode!
            .hasFocus,
        isTrue);
    expect(calls, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'national polls show their source, record and existing favourite ID',
      (tester) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final recording = RecordingStandings(
        data: LeagueStandings(
            rankings: true,
            rankingTitle: 'National rankings',
            sourceName: 'United Soccer Coaches',
            updatedAt: DateTime(2026, 10, 25),
            tables: const [
          StandingTable('Division I national rankings', [
            StandingTeam(
                SportsTeam(
                    id: '100',
                    name: 'School Tigers',
                    shortName: 'Tigers',
                    abbreviation: 'ST'),
                {'wins': '12', 'losses': '2', 'ties': '1', 'pollPoints': '637'},
                1,
                nameAliases: {'School University'})
          ]),
          StandingTable('Other available teams', []),
        ]));
    addTearDown(recording.close);
    await tester.pumpWidget(ChangeNotifierProvider.value(
        value: prefs,
        child: MaterialApp(
            home: SportsTeamsScreen(
                follows: follows,
                service: recording,
                initialLeague: sportsLeagueById('usa.ncaa.m.1')))));
    await tester.pumpAndSettle();
    expect(find.textContaining('National rankings · United Soccer Coaches'),
        findsOneWidget);
    expect(find.textContaining('World rankings'), findsNothing);
    expect(find.text('All groups'), findsOneWidget);
    expect(find.text('All divisions'), findsNothing);
    expect(find.text('12-2-1'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'School University');
    await tester.pumpAndSettle();
    expect(find.text('School Tigers'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('follow-100')));
    await tester.pumpAndSettle();
    expect(follows.isFollowed('usa.ncaa.m.1', '100'), isTrue);
    expect(recording.loads, 1);
    expect(tester.takeException(), isNull);
  });

  for (final id in ['kor.1', 'basketball.easl']) {
    testWidgets('$id standings retain their provider identity in the picker',
        (tester) async {
      final recording = RecordingStandings();
      addTearDown(recording.close);
      final league = sportsLeagueById(id)!;
      await tester.pumpWidget(ChangeNotifierProvider.value(
          value: prefs,
          child: MaterialApp(
              home: SportsTeamsScreen(
                  follows: follows,
                  service: recording,
                  initialLeague: league))));
      await tester.pumpAndSettle();
      expect(recording.requested?.id, id);
      expect(recording.loads, 1);
      expect(find.text(league.name), findsOneWidget);
    });
  }

  for (final size in [
    const Size(320, 568),
    const Size(844, 390),
    const Size(960, 540)
  ]) {
    testWidgets(
        'F1 drivers and constructors are independent local views at $size',
        (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final recording = RecordingStandings(
          data: const LeagueStandings(season: '2026', tables: [
        StandingTable('Driver Standings', [
          StandingTeam(
              SportsTeam(
                  id: 'd',
                  name: 'Driver One',
                  shortName: 'Driver',
                  abbreviation: 'D'),
              {'championshipPts': '365'},
              1)
        ]),
        StandingTable('Constructor Standings', [
          StandingTeam(
              SportsTeam(
                  id: 'c',
                  name: 'Constructor One',
                  shortName: 'Constructor',
                  abbreviation: 'LP'),
              {'points': '607'},
              1)
        ]),
      ]));
      addTearDown(recording.close);
      await tester.pumpWidget(ChangeNotifierProvider.value(
          value: prefs,
          child: MaterialApp(
              home: SportsTeamsScreen(
                  follows: follows,
                  service: recording,
                  initialLeague: sportsLeagueById('racing.f1')))));
      await tester.pumpAndSettle();
      expect(find.text('Driver One'), findsOneWidget);
      expect(find.text('365'), findsOneWidget);
      expect(find.text('Constructor One'), findsNothing);
      await tester.tap(find.text('Constructors'));
      await tester.pumpAndSettle();
      expect(find.text('Constructor One'), findsOneWidget);
      expect(find.text('607'), findsOneWidget);
      expect(find.text('Con'), findsOneWidget);
      expect(find.text('LP'), findsNothing);
      expect(find.text('Driver One'), findsNothing);
      expect(find.text('Search constructors'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'Missing');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Clear filters'));
      await tester.pumpAndSettle();
      expect(find.text('Constructor One'), findsOneWidget);
      expect(recording.loads, 1);
      expect(tester.takeException(), isNull);
      if (size.width == 320) {
        tester.platformDispatcher.textScaleFactorTestValue = 1.6;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        await tester.pumpAndSettle();
        expect(find.text('Constructors').hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
    });
  }

  test('standings columns use the sport record rather than generic points', () {
    const all = {
      'wins',
      'losses',
      'ties',
      'gamesPlayed',
      'points',
      'winPercent',
      'pointDifferential',
      'bonusPoints',
      'otLosses',
      'championshipPts',
      'gamesBehind'
    };
    final basketball = visibleStandingsColumns(all, 960, sport: 'basketball');
    expect(basketball.map((c) => c.key),
        ['wins', 'losses', 'ties', 'winPercent', 'gamesBehind']);
    expect(visibleStandingsColumns(all, 320, sport: 'basketball').single.key,
        'winLossRecord');
    final soccer = visibleStandingsColumns(all, 960, sport: 'soccer');
    expect(soccer.firstWhere((c) => c.key == 'pointDifferential').label, 'GD');
    expect(soccer.map((c) => c.key), isNot(contains('championshipPts')));
    expect(visibleStandingsColumns(all, 960, sport: 'hockey').map((c) => c.key),
        contains('otLosses'));
    expect(visibleStandingsColumns(all, 960, sport: 'rugby').map((c) => c.key),
        contains('bonusPoints'));
    expect(
        visibleStandingsColumns(all, 560, sport: 'rugby', columnWidth: 46)
            .map((c) => c.key),
        containsAll(['wins', 'losses', 'points']));
    expect(
        visibleStandingsColumns(all, 560, sport: 'rugby', columnWidth: 46)
            .map((c) => c.key),
        isNot(contains('bonusPoints')));
    expect(visibleStandingsColumns(all, 960, sport: 'racing').map((c) => c.key),
        ['wins', 'championshipPts']);
    const team =
        SportsTeam(id: '1', name: 'Team', shortName: 'Team', abbreviation: 'T');
    final compact = visibleStandingsColumns({'wins', 'losses', 'ties'}, 320,
            sport: 'football')
        .single;
    expect(
        standingColumnValue(
            const StandingTeam(
                team, {'wins': '9', 'losses': '2', 'ties': '1'}, 1),
            compact),
        '9-2-1');
    expect(
        visibleStandingsColumns({'wins'}, 320, sport: 'basketball').single.key,
        'wins');
  });

  testWidgets('phone supports enlarged text without losing actions',
      (tester) async {
    tester.platformDispatcher.textScaleFactorTestValue = 1.6;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await open(tester, size: const Size(320, 568));
    expect(find.byKey(const ValueKey('standings-sport')).hitTestable(),
        findsOneWidget);
    expect(find.byKey(const ValueKey('standings-league')).hitTestable(),
        findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(const ValueKey('standings-league')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('shared toolbar keeps compact pane controls and owned focus',
      (tester) async {
    prefs.isTelevision = true;
    tester.view.physicalSize = const Size(960, 540);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final searchFocus = FocusNode(), leagueFocus = FocusNode();
    addTearDown(searchFocus.dispose);
    addTearDown(leagueFocus.dispose);
    var toolbarFocuses = 0;
    final recording = RecordingStandings(
        data: LeagueStandings(
      season: '2026',
      tables: [
        StandingTable(
            'East',
            List.generate(
                20,
                (i) => StandingTeam(
                    SportsTeam(
                        id: '$i',
                        name: 'Club $i',
                        shortName: 'Club $i',
                        abbreviation: 'C'),
                    {'points': '${40 - i}', 'wins': '10'},
                    i + 1))),
        const StandingTable('West', [])
      ],
    ));
    addTearDown(recording.close);
    await tester.pumpWidget(ChangeNotifierProvider.value(
        value: prefs,
        child: MaterialApp(
            home: Scaffold(
                body: SportsTeamsScreen(
                    follows: follows,
                    service: recording,
                    initialLeague: sportsLeagueById('eng.1'),
                    searchFocusNode: searchFocus,
                    entryFocusNode: leagueFocus,
                    onFocusToolbar: () => toolbarFocuses++,
                    layoutBuilder: (filters, actions, content) =>
                        Column(children: [
                          Row(children: [Expanded(child: filters), actions]),
                          Expanded(
                              child: Align(
                                  alignment: Alignment.topRight,
                                  child: SizedBox(width: 560, child: content))),
                        ]))))));
    await tester.pumpAndSettle();
    final search = find.byKey(const ValueKey('standings-search'));
    final group = find.byKey(const ValueKey('standings-group'));
    expect(tester.getRect(search).height, 34);
    expect(tester.getRect(search).width, 230);
    expect(tester.getRect(search).left, 400,
        reason: 'Search aligns with the content pane edge');
    expect(tester.getRect(search).center.dy,
        closeTo(tester.getRect(group).center.dy, 1));
    searchFocus.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pump();
    await tester.enterText(search, 'Club');
    await tester.pumpAndSettle();
    expect(tester.getRect(search).height, 34,
        reason: 'Clear search must not enlarge the compact control row');
    expect(tester.getSize(find.byTooltip('Clear search')).height,
        lessThanOrEqualTo(34));
    expect(tester.getRect(find.byType(StandingsTeamTile).first).height, 40);
    expect(tester.getRect(find.byType(StandingsTeamTile).first).top,
        lessThan(155));
    expect(find.text('Sport'), findsOneWidget);
    expect(find.text('League'), findsOneWidget);
    leagueFocus.requestFocus();
    await tester.pump();
    searchFocus.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(toolbarFocuses, 0);
    expect(leagueFocus.hasFocus, isTrue);
    expect(recording.loads, 1);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    // Screen removal must not dispose focus owned by the Sports toolbar.
    searchFocus.addListener(() {});
    leagueFocus.addListener(() {});
  });

  testWidgets('TV F1 controls are compact rectangles without new requests',
      (tester) async {
    prefs.isTelevision = true;
    tester.view.physicalSize = const Size(960, 540);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final recording = RecordingStandings(
        data: const LeagueStandings(tables: [
      StandingTable('Driver Standings', [
        StandingTeam(
            SportsTeam(
                id: 'd',
                name: 'Driver One',
                shortName: 'Driver',
                abbreviation: 'D'),
            {'championshipPts': '365'},
            1)
      ]),
      StandingTable('Constructor Standings', [
        StandingTeam(
            SportsTeam(
                id: 'c',
                name: 'Constructor One',
                shortName: 'Constructor',
                abbreviation: 'C'),
            {'points': '607'},
            1)
      ]),
    ]));
    addTearDown(recording.close);
    await tester.pumpWidget(ChangeNotifierProvider.value(
        value: prefs,
        child: MaterialApp(
            home: Scaffold(
                body: SportsTeamsScreen(
                    follows: follows,
                    service: recording,
                    initialLeague: sportsLeagueById('racing.f1'),
                    layoutBuilder: (filters, actions, content) =>
                        Column(children: [
                          Row(children: [Expanded(child: filters), actions]),
                          Expanded(
                              child: Align(
                                  alignment: Alignment.topRight,
                                  child: SizedBox(width: 560, child: content))),
                        ]))))));
    await tester.pumpAndSettle();
    final selector = find.byType(SegmentedButton<String>);
    expect(tester.getSize(selector), const Size(188, 34));
    final shape = tester
        .widget<SegmentedButton<String>>(selector)
        .style!
        .shape!
        .resolve({})! as RoundedRectangleBorder;
    expect(shape.borderRadius, BorderRadius.circular(6));
    await tester.tap(find.text('Constructors'));
    await tester.pumpAndSettle();
    expect(find.text('Constructor One'), findsOneWidget);
    expect(find.text('607'), findsOneWidget);
    expect(recording.loads, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('shared toolbar pane reflows at 320 with enlarged text',
      (tester) async {
    tester.view.physicalSize = const Size(960, 640);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 1.6;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final recording = RecordingStandings(
        data: const LeagueStandings(tables: [
      StandingTable('East', [
        StandingTeam(
            SportsTeam(
                id: '1',
                name: 'A long club name',
                shortName: 'Club',
                abbreviation: 'C'),
            {'points': '12'},
            1)
      ]),
      StandingTable('West', []),
    ]));
    addTearDown(recording.close);
    await tester.pumpWidget(ChangeNotifierProvider.value(
        value: prefs,
        child: MaterialApp(
            home: Scaffold(
                body: Center(
                    child: SizedBox(
                        width: 320,
                        child: SportsTeamsScreen(
                            follows: follows,
                            service: recording,
                            layoutBuilder: (filters, actions, content) =>
                                Column(children: [
                                  filters,
                                  Align(
                                      alignment: Alignment.centerRight,
                                      child: actions),
                                  Expanded(child: content),
                                ]))))))));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('standings-search')).hitTestable(),
        findsOneWidget);
    expect(find.byKey(const ValueKey('standings-group')).hitTestable(),
        findsOneWidget);
    expect(
        find.byKey(const ValueKey('standings-favourites-only')).hitTestable(),
        findsOneWidget);
    expect(tester.getRect(find.byType(StandingsTeamTile).first).height,
        greaterThanOrEqualTo(48));
    expect(tester.takeException(), isNull);
  });

  testWidgets('TV unfollow preserves useful focus on the next favourite',
      (tester) async {
    prefs.isTelevision = true;
    for (var i = 1; i <= 3; i++) {
      await follows.follow('eng.1', '$i', name: 'Saved $i');
    }
    await open(tester, favorites: true);
    final node = FocusManager.instance.rootScope.traversalDescendants
        .firstWhere((n) =>
            n.context?.findAncestorWidgetOfExactType<IconButton>()?.tooltip ==
            'Remove favourite');
    node.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(follows.teams.map((t) => t.teamId), ['2', '3']);
    final context = FocusManager.instance.primaryFocus!.context!;
    final tile = context.findAncestorWidgetOfExactType<ListTile>();
    expect(tile?.key, const ValueKey('eng.1|2'));
  });

  testWidgets('switching leagues restores query and scroll without refetch',
      (tester) async {
    await tester.runAsync(() => service.load(sportsLeagueById('nba')!));
    await open(tester);
    await tester.enterText(find.byType(TextField), 'Team');
    await tester.pumpAndSettle();
    final controller =
        tester.widget<ListView>(find.byType(ListView)).controller!;
    controller.jumpTo(600);
    await tester.pumpAndSettle();
    final offset = controller.offset;
    Future<void> choose(String sport, String query, String id) async {
      await tester.tap(find.byKey(const ValueKey('standings-sport')));
      await tester.pumpAndSettle();
      final sports =
          tester.widget<CompactChoiceList>(find.byType(CompactChoiceList));
      sports.choices.firstWhere((c) => c.id == sport).onTap();
      await tester.pumpAndSettle();
      final search = find.descendant(
          of: find.byType(Dialog), matching: find.byType(TextField));
      await tester.enterText(search, query);
      await tester.pumpAndSettle();
      final choices =
          tester.widget<CompactChoiceList>(find.byType(CompactChoiceList));
      choices.choices.firstWhere((c) => c.id == id).onTap();
      await tester.pumpAndSettle();
    }

    await choose('basketball', 'NBA', 'nba');
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
        isEmpty);
    await choose('soccer', 'Premier League', 'eng.1');
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'Team');
    expect(tester.widget<ListView>(find.byType(ListView)).controller!.offset,
        offset);
    expect(calls, 2);
  });

  testWidgets('guide-only sports select a supported league for standings',
      (tester) async {
    final recording = RecordingStandings();
    addTearDown(recording.close);
    await tester.pumpWidget(ChangeNotifierProvider.value(
        value: prefs,
        child: MaterialApp(
            home: SportsTeamsScreen(
                follows: follows,
                initialLeague: sportsLeagueById('rugby.live'),
                service: recording))));
    await tester.pumpAndSettle();
    expect(recording.requested?.id, 'nhl');
    expect(find.text('NHL'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test(
      'queued favourite edits preserve order, uniqueness, names and stored IDs',
      () async {
    await Future.wait([
      follows.follow('eng.1', '1', name: 'One'),
      follows.follow('eng.1', '2', name: 'Two'),
      follows.unfollow('eng.1', '1'),
      follows.follow('eng.1', '2', name: 'Two')
    ]);
    expect(follows.teams.map((t) => t.key), ['eng.1|2']);
    expect(storage.getSportsFollowedTeams(), ['eng.1|2']);
    expect(SportsFollows.load(storage).nameOf(follows.teams.single), 'Two');
    expect(() => follows.teams.clear(), throwsUnsupportedError);
  });
  for (final (size, scale) in [
    for (final size in [const Size(390, 844), const Size(844, 390)])
      for (final scale in [1.0, 2.0]) (size, scale)
  ]) {
    testWidgets(
        'phone standings controls stay compact while filtering at $size / $scale',
        (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final recording = RecordingStandings(
          data: const LeagueStandings(season: '2026', tables: [
        StandingTable('League', [
          StandingTeam(
              SportsTeam(
                  id: 'a',
                  name: 'North Harbour',
                  shortName: 'Harbour',
                  abbreviation: 'NH'),
              {'points': '24'},
              1)
        ])
      ]));
      addTearDown(recording.close);
      await tester.pumpWidget(ChangeNotifierProvider.value(
          value: prefs,
          child: MaterialApp(
              home: Scaffold(
                  body: SportsTeamsScreen(
                      follows: follows,
                      service: recording,
                      initialLeague: sportsLeagueById('eng.1'),
                      layoutBuilder: (filters, actions, content) =>
                          Column(children: [
                            Row(children: [Expanded(child: filters), actions]),
                            Expanded(child: content)
                          ]))))));
      await tester.pumpAndSettle();
      final search = find.byKey(const ValueKey('standings-search'));
      final before = tester.getSize(search).height;
      if (scale == 1) expect(before, lessThanOrEqualTo(42));
      await tester.enterText(search, 'North');
      await tester.pumpAndSettle();
      expect(tester.getSize(search).height, before);
      expect(find.byTooltip('Clear search').hitTestable(), findsOneWidget);
      await tester.tap(find.byTooltip('Clear search'));
      await tester.pumpAndSettle();
      expect(find.text('North Harbour'), findsWidgets);
      expect(recording.loads, 1);
      expect(tester.takeException(), isNull);
    });
  }
}
