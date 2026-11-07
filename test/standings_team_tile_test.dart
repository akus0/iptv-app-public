import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:nox_iptv/models/sports.dart';
import 'package:nox_iptv/services/app_preferences.dart';
import 'package:nox_iptv/services/storage_service.dart';
import 'package:nox_iptv/services/sports_standings_service.dart';
import 'package:nox_iptv/widgets/standings_team_tile.dart';

void main() {
  late AppPreferences prefs;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final storage = StorageService();
    await storage.init();
    prefs = AppPreferences(storage);
    await prefs.init();
  });
  tearDown(() => prefs.dispose());
  const stats = {
    'gamesPlayed': '18',
    'wins': '11',
    'ties': '2',
    'losses': '5',
    'pointDifferential': '+37',
    'bonusPoints': '9',
    'points': '55',
  };
  for (final scenario in [
    (
      sport: 'rugby',
      league: 'rugby.270557',
      width: 960.0,
      tv: true,
      scale: 1.0,
      stats: stats
    ),
    (
      sport: 'rugby',
      league: 'rugby.270557',
      width: 560.0,
      tv: true,
      scale: 1.0,
      stats: stats
    ),
    (
      sport: 'rugby',
      league: 'rugby.270557',
      width: 320.0,
      tv: false,
      scale: 1.0,
      stats: stats
    ),
    (
      sport: 'rugby',
      league: 'rugby.270557',
      width: 768.0,
      tv: false,
      scale: 1.0,
      stats: stats
    ),
    (
      sport: 'racing',
      league: 'racing.f1',
      width: 560.0,
      tv: true,
      scale: 1.0,
      stats: {'wins': '11', 'championshipPts': '365'}
    ),
    (
      sport: 'basketball',
      league: 'basketball.mens-college-basketball',
      width: 560.0,
      tv: true,
      scale: 1.0,
      stats: {'vs. Conf.': '9-2', 'overall': '21-4'}
    ),
    (
      sport: 'basketball',
      league: 'basketball.mens-college-basketball',
      width: 320.0,
      tv: false,
      scale: 1.6,
      stats: {'vs. Conf.': '9-2', 'overall': '21-4'}
    ),
    (
      sport: 'rugby',
      league: 'rugby.270557',
      width: 320.0,
      tv: false,
      scale: 2.0,
      stats: stats
    ),
  ]) {
    testWidgets(
        'header and row cells align ${scenario.sport} ${scenario.width} ${scenario.scale} TV=${scenario.tv}',
        (tester) async {
      prefs.isTelevision = scenario.tv;
      tester.view.physicalSize = Size(scenario.width, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final columnWidth = 46 * scenario.scale;
      final columns = visibleStandingsColumns(
          scenario.stats.keys.toSet(), scenario.width,
          sport: scenario.sport,
          leagueId: scenario.league,
          columnWidth: columnWidth);
      final row = StandingTeam(
          const SportsTeam(
              id: 'test',
              name: 'Canterbury Rugby',
              shortName: 'Canterbury',
              abbreviation: 'CAN'),
          scenario.stats,
          1);
      var details = 0, toggles = 0;
      await tester.pumpWidget(ChangeNotifierProvider.value(
          value: prefs,
          child: MaterialApp(
              home: MediaQuery(
                  data: MediaQueryData(
                      size: Size(scenario.width, 600),
                      textScaler: TextScaler.linear(scenario.scale)),
                  child: Scaffold(
                      body: Column(children: [
                    StandingsTableHeader(
                        columns: columns,
                        columnWidth: columnWidth,
                        label: 'Team'),
                    StandingsTeamTile(
                        row: row,
                        columns: columns,
                        columnWidth: columnWidth,
                        alternate: true,
                        followed: false,
                        directory: false,
                        onToggle: () => toggles++,
                        onDetails: () => details++),
                  ]))))));
      await tester.pumpAndSettle();
      final header = find.byType(StandingsTableHeader),
          tile = find.byType(StandingsTeamTile);
      if (scenario.width == 960) expect(columns.length, 7);
      for (final column in columns) {
        final heading =
            find.descendant(of: header, matching: find.text(column.label));
        final value = find.descendant(
            of: tile, matching: find.text(standingColumnValue(row, column)));
        expect(tester.getTopRight(value).dx,
            closeTo(tester.getTopRight(heading).dx, .01),
            reason: column.key);
      }
      final compact = scenario.width < 600;
      expect(tester.getSize(tile).height,
          scenario.tv ? 40 : greaterThanOrEqualTo(compact ? 44 : 48));
      expect(
          tester.getSize(find.byKey(const ValueKey('follow-test'))).height,
          scenario.tv
              ? 32
              : compact
                  ? 40
                  : 48);
      final title = tester.widget<Text>(find.text('Canterbury Rugby'));
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(tester.widget<Text>(find.text('Canterbury Rugby')), same(title),
          reason: 'Focus keeps the static row content');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(details, 1);
      expect(toggles, 0);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(toggles, 1);
      expect(details, 1);
      expect(tester.takeException(), isNull);
    });
  }
}
