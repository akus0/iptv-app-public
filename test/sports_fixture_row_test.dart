import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nox_iptv/models/sports.dart';
import 'package:nox_iptv/widgets/sports_fixture_row.dart';
import 'package:nox_iptv/widgets/sports_widgets.dart';

void main() {
  for (final scale in [1.0, 2.0]) {
    testWidgets('field fixture fits event context and channel at $scale',
        (tester) async {
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final game = SportsGame(
          id: 'race',
          league: sportsLeagueById('racing.f1')!,
          start: DateTime(2026, 11, 3),
          state: GameState.pre,
          statusText: 'Scheduled',
          home: const SportsTeam(
              id: '', name: '', shortName: '', abbreviation: ''),
          away: const SportsTeam(
              id: '', name: '', shortName: '', abbreviation: ''),
          event: const SportsEventInfo(
              title: 'Grand Prix with a deliberately long event title',
              session: 'Qualifying',
              venue: 'International circuit'));
      await tester.pumpWidget(MaterialApp(
          home: MediaQuery(
              data: MediaQueryData(textScaler: TextScaler.linear(scale)),
              child: Scaffold(
                  body: Center(
                      child: SizedBox(
                          height: 64 * scale,
                          child: Padding(
                              padding: const EdgeInsets.all(4),
                              child: SportsFixtureRow(
                                  game: game,
                                  time: '7:00 PM',
                                  hideScores: false,
                                  use24h: false,
                                  channelName: 'Motor Racing HD',
                                  onDetails: () {}))))))));
      await tester.pump();
      expect(find.text('Motor Racing HD'), findsOneWidget);
      expect(find.textContaining('Qualifying'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
  for (final scale in [1.0, 2.0]) {
    testWidgets(
        'compact fixture preserves identity and hidden scores at $scale',
        (tester) async {
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      SportsGame game(GameState state) => SportsGame(
          id: 'fixture',
          league: sportsLeagueById('eng.1')!,
          start: DateTime(2026, 11, 10, 19),
          state: state,
          statusText: "73′",
          home: const SportsTeam(
              id: 'h',
              name: 'North Harbour United',
              shortName: 'United',
              abbreviation: 'NHU',
              score: '2',
              record: '8-2-1'),
          away: const SportsTeam(
              id: 'a',
              name: 'South Coast United',
              shortName: 'United',
              abbreviation: 'SCU',
              score: '1',
              record: '6-3-2'));
      Future<void> show(GameState state, bool hidden,
          {bool channel = false, bool allSports = false}) async {
        await tester.pumpWidget(MaterialApp(
            home: MediaQuery(
                data: MediaQueryData(textScaler: TextScaler.linear(scale)),
                child: Scaffold(
                    body: Center(
                        child: SizedBox(
                            height: (channel
                                    ? 68
                                    : allSports
                                        ? 52
                                        : 56) *
                                scale,
                            child: Padding(
                                padding: const EdgeInsets.all(4),
                                child: SportsFixtureRow(
                                    game: game(state),
                                    time: '7:00 PM',
                                    hideScores: hidden,
                                    showLeague: allSports,
                                    showSport: allSports,
                                    channelName: channel
                                        ? 'Sports Network with a long channel name'
                                        : null,
                                    possibleChannel: true,
                                    onDetails: channel ? () {} : null,
                                    use24h: false))))))));
        await tester.pump();
        expect(tester.takeException(), isNull);
      }

      await show(GameState.pre, false);
      expect(find.text('North Harbour United'), findsOneWidget);
      expect(find.text('South Coast United'), findsOneWidget);
      expect(find.text('8-2-1'), findsOneWidget);
      expect(find.byType(SportsLogo), findsNWidgets(2));
      await show(GameState.live, true, allSports: true);
      expect(find.text('Soccer'), findsOneWidget);
      expect(find.text(sportsLeagueById('eng.1')!.shortName), findsOneWidget);
      expect(find.text('LIVE'), findsOneWidget);
      expect(find.text('2'), findsNothing);
      expect(find.text('73′'), findsNothing);
      await show(GameState.live, true, channel: true);
      expect(find.textContaining('Possible · Sports Network'), findsOneWidget);
      expect(find.text('2'), findsNothing);
      expect(find.text('73′'), findsNothing);
      expect(
          tester
              .widgetList<SportsLogo>(find.byType(SportsLogo))
              .every((logo) => !logo.animate && logo.size == 18),
          isTrue);
      await show(GameState.live, false);
      expect(find.text('LIVE'), findsOneWidget);
      expect(find.text('73′'), findsOneWidget);
      expect(find.text('2'), findsOneWidget);
      await show(GameState.live, true);
      expect(find.text('2'), findsNothing);
      expect(find.text('1'), findsNothing);
      expect(find.text('73′'), findsNothing);
      expect(find.text('8-2-1'), findsNothing);
      expect(find.byType(SportsLogo), findsNWidgets(2));
    });
  }
}
