import 'dart:async';
import 'package:nox_iptv/widgets/sports_schedule_calendar.dart';
import 'package:nox_iptv/models/sports_favourites_filter.dart';
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

class _EmptyScores extends DayScores {
  @override
  List<SportsGame> fixtures(DateTime day, [int count = 1000]) => const [];
}

class _UnorderedScores extends DayScores {
  @override
  List<SportsGame> fixtures(DateTime day, [int count = 1000]) => [
        for (final game in super.fixtures(day, count).reversed)
          SportsGame(
              id: game.id,
              league: game.league,
              start: day.add(Duration(minutes: int.parse(game.id) ~/ 4)),
              state: game.state,
              statusText: game.statusText,
              home: game.home,
              away: game.away),
      ];
}

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
    var favouriteLeagues = <String>{};
    final browse = SportsScheduleBrowseState(), entry = FocusNode();
    addTearDown(entry.dispose);
    Widget app() => harness.app(
        storage,
        prefs,
        SportsSchedulePanel(
          follows: follows,
          favouriteLeagueIds: favouriteLeagues,
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
    await tester
        .tap(find.byKey(const ValueKey('sports-favourites-favourites')));
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
    favouriteLeagues = {'nba'};
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<CompactChoiceList>(find.byType(CompactChoiceList))
            .choices,
        hasLength(1000),
        reason: 'Favourite leagues and followed teams combine with OR');
    expect(scores.days, hasLength(1),
        reason: 'Membership changes filter the existing snapshot');
    Future<void> chooseScope(SportsFavouritesFilter filter) async {
      await tester.tap(find.byKey(const ValueKey('schedule-favourites-only')));
      await tester.pumpAndSettle();
      await tester
          .tap(find.byKey(ValueKey('sports-favourites-${filter.name}')));
      await tester.pumpAndSettle();
    }

    for (final (filter, league) in [
      (SportsFavouritesFilter.leagues, 'nba'),
      (SportsFavouritesFilter.teams, 'eng.1'),
    ]) {
      await chooseScope(filter);
      expect(
          tester
              .widget<CompactChoiceList>(find.byType(CompactChoiceList))
              .choices,
          hasLength(500));
      final rows =
          tester.widgetList<SportsFixtureRow>(find.byType(SportsFixtureRow));
      expect(rows, isNotEmpty);
      expect(rows.every((row) => row.game.league.id == league), true);
      expect(scores.days, hasLength(1));
    }
    await chooseScope(SportsFavouritesFilter.favourites);
    favouriteLeagues = {};
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
    var favouriteLeagues = <String>{};
    Widget app() => harness.app(
        storage,
        prefs,
        SportsTeamsScreen(
            follows: follows,
            favouriteLeagueIds: favouriteLeagues,
            service: service,
            initialLeague: sportsLeagueById('eng.1'),
            panel: true));
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('standings-favourites-only')));
    await tester.pumpAndSettle();
    await tester
        .tap(find.byKey(const ValueKey('sports-favourites-favourites')));
    await tester.pumpAndSettle();
    expect(find.text('One Club'), findsWidgets);
    expect(find.text('Two Club'), findsNothing);
    favouriteLeagues = {'eng.1'};
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    expect(find.text('One Club'), findsWidgets);
    expect(find.text('Two Club'), findsWidgets,
        reason: 'A favourite league includes its whole table');
    expect(service.loads, 1);
    for (final filter in [
      SportsFavouritesFilter.teams,
      SportsFavouritesFilter.leagues,
      SportsFavouritesFilter.favourites
    ]) {
      await tester.tap(find.byKey(const ValueKey('standings-favourites-only')));
      await tester.pumpAndSettle();
      await tester
          .tap(find.byKey(ValueKey('sports-favourites-${filter.name}')));
      await tester.pumpAndSettle();
      expect(find.text('One Club'), findsWidgets);
      expect(find.text('Two Club'),
          filter == SportsFavouritesFilter.teams ? findsNothing : findsWidgets);
      expect(service.loads, 1, reason: 'Scope changes reuse the loaded table');
    }
    favouriteLeagues = {};
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
  testWidgets(
      'calendar counts follow scope locally and cancel an old week load',
      (tester) async {
    harness.viewport(tester, const Size(960, 540));
    final (storage, prefs) = await harness.preferences(true);
    addTearDown(prefs.dispose);
    final follows = SportsFollows.load(storage);
    await follows.follow('eng.1', 'h');
    final scores = DayScores();
    final browse = SportsScheduleBrowseState(), entry = FocusNode();
    addTearDown(entry.dispose);
    final today = DateTime(2026, 11, 2);
    Widget app() => harness.app(
        storage,
        prefs,
        SportsSchedulePanel(
          follows: follows,
          favouriteLeagueIds: const {'nba'},
          browseState: browse,
          entryFocus: entry,
          onFocusToolbar: () {},
          overviewLeagues: [
            sportsLeagueById('nba')!,
            sportsLeagueById('eng.1')!
          ],
          service: scores,
          clock: () => today,
          layoutBuilder: (filters, actions, content) => Column(children: [
            SizedBox(
                height: 40,
                child: Row(children: [Expanded(child: filters), actions])),
            Expanded(child: content),
          ]),
        ));
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('schedule-range-7')));
    await tester.pumpAndSettle();
    Map<String, int>? counts() => tester
        .widget<SportsScheduleCalendar>(find.byType(SportsScheduleCalendar))
        .summaries[today]
        ?.sports;
    expect(counts(), {'basketball': 500, 'soccer': 500});
    Future<void> choose(SportsFavouritesFilter value) async {
      await tester.tap(find.byKey(const ValueKey('schedule-favourites-only')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('sports-favourites-${value.name}')));
      await tester.pumpAndSettle();
    }

    await choose(SportsFavouritesFilter.teams);
    expect(counts(), {'soccer': 500},
        reason: 'Already-loaded calendar counts must not go blank');
    expect(scores.days, hasLength(1));
    scores.dayPending = Completer();
    await tester.tap(find.byKey(const ValueKey('schedule-load-week')));
    await tester.pump();
    expect(scores.days, hasLength(2));
    // Use bounded pumps while the week progress indicator is active.
    await tester.tap(find.byKey(const ValueKey('schedule-favourites-only')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('sports-favourites-leagues')));
    await tester.pumpAndSettle();
    expect(counts(), {'basketball': 500});
    scores.dayPending!.complete(
        (games: scores.fixtures(scores.days.last), incomplete: false));
    await tester.pumpAndSettle();
    expect(scores.days, hasLength(2),
        reason: 'No further days queued after changing scope');
    expect(browse.summaries.keys, [today],
        reason: 'Late old-scope results are discarded');
    await choose(SportsFavouritesFilter.all);
    expect(counts(), {'basketball': 500, 'soccer': 500});
    expect(scores.days, hasLength(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'rapid scope changes preserve ordered results and avoid refetches',
      (tester) async {
    harness.viewport(tester, const Size(960, 540));
    final (storage, prefs) = await harness.preferences(true);
    addTearDown(prefs.dispose);
    final follows = SportsFollows.load(storage);
    await follows.follow('eng.1', 'h');
    final scores = _UnorderedScores();
    final browse = SportsScheduleBrowseState(), entry = FocusNode();
    addTearDown(entry.dispose);
    var filter = SportsFavouritesFilter.all;
    Widget app() => harness.app(
        storage,
        prefs,
        SportsSchedulePanel(
          follows: follows,
          favouriteLeagueIds: const {'nba'},
          favouritesFilter: filter,
          browseState: browse,
          entryFocus: entry,
          onFocusToolbar: () {},
          overviewLeagues: [
            sportsLeagueById('nba')!,
            sportsLeagueById('eng.1')!
          ],
          service: scores,
          clock: () => DateTime(2026, 11, 2),
          layoutBuilder: (filters, actions, content) => Column(children: [
            SizedBox(
                height: 40,
                child: Row(children: [Expanded(child: filters), actions])),
            Expanded(child: content),
          ]),
        ));
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    final baselineOrder = tester
        .widget<CompactChoiceList>(find.byType(CompactChoiceList))
        .choices
        .map((row) => row.id)
        .toList();
    expect(baselineOrder.take(4), ['eng.1:1', 'eng.1:3', 'nba:0', 'nba:2'],
        reason:
            'Unordered fixtures with equal times have a stable identity tie-break');
    final times = <int>[];
    for (var i = 0; i < 40; i++) {
      filter = SportsFavouritesFilter.values[(i * 3 + 1) % 4];
      final watch = Stopwatch()..start();
      await tester.pumpWidget(app());
      await tester.pump();
      watch.stop();
      times.add(watch.elapsedMicroseconds);
      final choices = tester
          .widget<CompactChoiceList>(find.byType(CompactChoiceList))
          .choices;
      final expected = baselineOrder.where((id) =>
          filter == SportsFavouritesFilter.all ||
          filter == SportsFavouritesFilter.favourites ||
          (filter == SportsFavouritesFilter.leagues && id.startsWith('nba:')) ||
          (filter == SportsFavouritesFilter.teams && id.startsWith('eng.1:')));
      expect(choices.map((row) => row.id), expected);
      expect(
          tester
              .widgetList<SportsFixtureRow>(find.byType(SportsFixtureRow))
              .length,
          lessThan(25),
          reason: 'Rows remain lazy while switching large result sets');
    }
    times.sort();
    // Host widget-harness timings, not phone/TV frame-latency measurements.
    debugPrint(
        'SPORTS_SCOPE_HOST fixtures=1000 changes=40 median_us=${times[20]} p95_us=${times[38]} requests=${scores.days.length}');
    expect(scores.days, hasLength(1));
    expect(tester.takeException(), isNull);
  });
  testWidgets(
      'empty team favourites explain the selection and recover without changing date',
      (tester) async {
    harness.viewport(tester, const Size(390, 844));
    final (storage, prefs) = await harness.preferences(false);
    addTearDown(prefs.dispose);
    final follows = SportsFollows.load(storage);
    final scores = _EmptyScores();
    final day = DateTime(2026, 11, 9);
    final browse = SportsScheduleBrowseState()
      ..from = day
      ..favouritesFilter = SportsFavouritesFilter.teams;
    final entry = FocusNode();
    addTearDown(entry.dispose);
    await tester.pumpWidget(harness.app(
        storage,
        prefs,
        SportsSchedulePanel(
          follows: follows,
          favouriteLeagueIds: const {},
          browseState: browse,
          entryFocus: entry,
          onFocusToolbar: () {},
          overviewLeagues: [sportsLeagueById('nhl')!],
          service: scores,
          clock: () => day,
          layoutBuilder: (filters, actions, content) => Column(children: [
            SizedBox(
                height: 40,
                child: Row(children: [Expanded(child: filters), actions])),
            Expanded(child: content),
          ]),
        )));
    await tester.pumpAndSettle();
    expect(find.text('No favourite teams or athletes yet'), findsOneWidget);
    await tester.tap(find.text('Show all fixtures'));
    await tester.pumpAndSettle();
    expect(browse.favouritesFilter, SportsFavouritesFilter.all);
    expect(browse.from, day);
    expect(find.text('No fixtures published for these dates'), findsOneWidget);
    expect(scores.days, [day]);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
      'narrowing the calendar catalogue retains known counts without renewing their age',
      (tester) async {
    harness.viewport(tester, const Size(960, 540));
    final (storage, prefs) = await harness.preferences(true);
    addTearDown(prefs.dispose);
    final follows = SportsFollows.load(storage);
    await follows.follow('eng.1', 'h');
    final scores = DayScores(), browse = SportsScheduleBrowseState();
    final entry = FocusNode();
    addTearDown(entry.dispose);
    final day = DateTime(2026, 11, 2);
    var now = day;
    var filter = SportsFavouritesFilter.all;
    var leagues = [sportsLeagueById('nba')!, sportsLeagueById('eng.1')!];
    Widget app() => harness.app(
        storage,
        prefs,
        SportsSchedulePanel(
          follows: follows,
          favouriteLeagueIds: const {'nba'},
          favouritesFilter: filter,
          browseState: browse,
          entryFocus: entry,
          onFocusToolbar: () {},
          overviewLeagues: leagues,
          service: scores,
          clock: () => now,
          layoutBuilder: (filters, actions, content) => Column(children: [
            SizedBox(
                height: 40,
                child: Row(children: [Expanded(child: filters), actions])),
            Expanded(child: content),
          ]),
        ));
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('schedule-range-7')));
    await tester.pumpAndSettle();
    now = day.add(const Duration(minutes: 3));
    filter = SportsFavouritesFilter.teams;
    leagues = [sportsLeagueById('eng.1')!];
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    final summary = tester
        .widget<SportsScheduleCalendar>(find.byType(SportsScheduleCalendar))
        .summaries[day]!;
    expect(summary.sports, {'soccer': 500});
    expect(summary.at, day,
        reason: 'Filtering must not make stale source data appear fresh');
    expect(scores.days, [day], reason: 'Narrowing a known catalogue is local');
    leagues = [sportsLeagueById('eng.1')!, sportsLeagueById('nhl')!];
    filter = SportsFavouritesFilter.all;
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<SportsScheduleCalendar>(find.byType(SportsScheduleCalendar))
            .summaries,
        isEmpty,
        reason:
            'A wider, unknown catalogue must not show misleading complete totals');
    expect(scores.days, [day],
        reason: 'Wider calendar browsing still loads only on request');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'standings failure retains Retry while a favourites filter is active',
      (tester) async {
    harness.viewport(tester, const Size(390, 844));
    final (storage, prefs) = await harness.preferences(false);
    addTearDown(prefs.dispose);
    final follows = SportsFollows.load(storage);
    final service =
        RecordingStandings(data: const LeagueStandings(failed: true));
    addTearDown(service.close);
    await tester.pumpWidget(harness.app(
        storage,
        prefs,
        SportsTeamsScreen(
          follows: follows,
          service: service,
          panel: true,
          initialLeague: sportsLeagueById('eng.1'),
          favouritesFilter: SportsFavouritesFilter.teams,
        )));
    await tester.pumpAndSettle();
    expect(find.text('Retry'), findsOneWidget);
    expect(find.text('No favourite teams or athletes yet'), findsNothing,
        reason:
            'Network failure must not be presented as an empty saved selection');
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(service.loads, 2);
    expect(tester.takeException(), isNull);
  });
}
