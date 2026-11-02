import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nox_iptv/models/sports.dart';
import 'package:nox_iptv/services/sports_follows.dart';
import 'package:nox_iptv/services/sports_service.dart';
import 'package:nox_iptv/services/sports_standings_service.dart';
import 'package:nox_iptv/screens/sports_teams_screen.dart';
import 'package:nox_iptv/widgets/compact_choice_list.dart';
import 'package:nox_iptv/widgets/sports_schedule_panel.dart';
import 'package:nox_iptv/widgets/sports_fixture_row.dart';
import 'sports_panel_test.dart' as harness;
import 'sports_schedule_panel_test.dart' show DayScores;
import 'sports_teams_screen_test.dart' show RecordingStandings;

void main() {
  test(
      'favourites use league identity, persist and invalidate cached membership',
      () async {
    final (storage, prefs) = await harness.preferences(true);
    addTearDown(prefs.dispose);
    final follows = SportsFollows.load(storage);
    final games = DayScores().fixtures(DateTime(2026, 11, 2), 2);
    await follows.follow('eng.1', 'h', name: 'Home Club');
    expect(follows.involves(games[0]), false);
    expect(follows.involves(games[1]), true);
    final revision = follows.revision;
    await follows.follow('eng.1', 'h');
    expect(follows.revision, revision);
    expect(SportsFollows.load(storage).involves(games[1]), true);
    await follows.unfollow('eng.1', 'h');
    expect(follows.involves(games[1]), false);
    await follows.follow('eng.1', 'h');
    expect(follows.involves(games[1]), true);
  });

  for (final leagueId in ['racing.f1', 'golf.pga']) {
    test(
        'event favourites include supplied athletes outside the leaders: $leagueId',
        () async {
      final (storage, prefs) = await harness.preferences(true);
      addTearDown(prefs.dispose);
      final follows = SportsFollows.load(storage);
      final league = sportsLeagueById(leagueId)!;
      final games = parseEspnScoreboard((
        jsonEncode({
          'events': [
            {
              'id': 'event',
              'name': 'Championship',
              'date': '2026-11-02T12:00:00Z',
              'status': {
                'type': {'state': 'in', 'shortDetail': 'Live'}
              },
              'competitions': [
                {
                  'id': 'race',
                  'date': '2026-11-02T12:00:00Z',
                  'competitors': [
                    for (var i = 1; i <= 20; i++)
                      {
                        'id': '$i',
                        'order': i,
                        'score': '$i',
                        'athlete': {'id': '$i', 'displayName': 'Athlete $i'}
                      }
                  ]
                }
              ]
            }
          ]
        }),
        league
      ));
      expect(games, hasLength(1));
      final game = games.single;
      expect(game.event!.participantIds, contains('20'));
      expect(game.event!.leaders.length, lessThanOrEqualTo(5));
      await follows.follow(leagueId, '20', name: 'Athlete 20');
      expect(follows.involves(game), true);
      await follows.unfollow(leagueId, '20');
      expect(follows.involves(game), false);
      await follows.follow('another.league', '20');
      expect(follows.involves(game), false);
      if (leagueId == 'racing.f1') {
        await follows.follow(leagueId, '20', name: 'Constructor 20');
        expect(follows.involves(game), false,
            reason: 'A constructor ID must not identify a different driver');
      }
    });
  }

  testWidgets(
      'schedule favourites filter, refresh and restore locally without requests',
      (tester) async {
    harness.viewport(tester, const Size(960, 540));
    final (storage, prefs) = await harness.preferences(true);
    addTearDown(prefs.dispose);
    final follows = SportsFollows.load(storage);
    await follows.follow('eng.1', 'h', name: 'Home Club');
    final scores = DayScores();
    final browse = SportsScheduleBrowseState(), entry = FocusNode();
    addTearDown(entry.dispose);
    Widget app() => harness.app(
        storage,
        prefs,
        SportsSchedulePanel(
          follows: follows,
          browseState: browse,
          entryFocus: entry,
          onFocusToolbar: () {},
          service: scores,
          overviewLeagues: [
            sportsLeagueById('nba')!,
            sportsLeagueById('eng.1')!
          ],
          clock: () => DateTime(2026, 11, 2),
          layoutBuilder: (filters, actions, content) => Column(children: [
            SizedBox(
                height: 40,
                child: Row(children: [Expanded(child: filters), actions])),
            Expanded(child: content)
          ]),
        ));
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    expect(scores.days, hasLength(1));
    expect(
        tester
            .widgetList<SportsFixtureRow>(find.byType(SportsFixtureRow))
            .any((r) => r.favourite),
        true);
    await tester.tap(find.byKey(const ValueKey('schedule-favourites-only')));
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<CompactChoiceList>(find.byType(CompactChoiceList))
            .choices,
        hasLength(500));
    expect(
        tester
            .widgetList<SportsFixtureRow>(find.byType(SportsFixtureRow))
            .every((r) => r.favourite && r.game.league.id == 'eng.1'),
        true);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    expect(browse.onlyFavourites, true);
    expect(scores.days, hasLength(1));
    await tester.runAsync(() => follows.unfollow('eng.1', 'h'));
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    expect(find.byType(SportsFixtureRow), findsNothing);
    await tester.tap(find.text('Show all fixtures'));
    await tester.pumpAndSettle();
    expect(browse.onlyFavourites, false);
    expect(
        tester
            .widget<CompactChoiceList>(find.byType(CompactChoiceList))
            .choices,
        hasLength(1000));
    expect(scores.days, hasLength(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'standings responds to favourites changed in another panel without reloading',
      (tester) async {
    harness.viewport(tester, const Size(960, 540));
    final (storage, prefs) = await harness.preferences(true);
    addTearDown(prefs.dispose);
    final follows = SportsFollows.load(storage);
    await follows.follow('eng.1', 'one');
    final service = RecordingStandings(
        data: const LeagueStandings(tables: [
      StandingTable('League', [
        StandingTeam(
            SportsTeam(
                id: 'one',
                name: 'One Club',
                shortName: 'One',
                abbreviation: 'ONE'),
            {'points': '3'},
            1),
        StandingTeam(
            SportsTeam(
                id: 'two',
                name: 'Two Club',
                shortName: 'Two',
                abbreviation: 'TWO'),
            {'points': '1'},
            2),
      ])
    ]));
    addTearDown(service.close);
    Widget app() => harness.app(
        storage,
        prefs,
        SportsTeamsScreen(
            follows: follows,
            service: service,
            initialLeague: sportsLeagueById('eng.1'),
            panel: true));
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('standings-favourites-only')));
    await tester.pumpAndSettle();
    expect(find.text('One Club'), findsWidgets);
    expect(find.text('Two Club'), findsNothing);
    await tester.runAsync(() async {
      await follows.unfollow('eng.1', 'one');
      await follows.follow('eng.1', 'two');
    });
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    expect(find.text('One Club'), findsNothing);
    expect(find.text('Two Club'), findsWidgets);
    expect(service.loads, 1);
    expect(tester.takeException(), isNull);
  });
}
