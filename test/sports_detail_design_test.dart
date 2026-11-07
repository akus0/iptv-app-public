import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nox_iptv/models/sports.dart';
import 'package:nox_iptv/models/sports_details.dart';
import 'package:nox_iptv/services/sports_standings_service.dart';
import 'package:nox_iptv/widgets/sports_detail_components.dart';
import 'package:nox_iptv/widgets/sports_detail_views.dart';
import 'package:nox_iptv/widgets/sports_details_panel.dart';
import 'package:nox_iptv/widgets/sports_header_controls.dart';
import 'sports_panel_test.dart' as harness;
import 'sports_details_panel_test.dart' as fixtures;

const _team = SportsTeam(
    id: 'north',
    name: 'Northside United',
    shortName: 'Northside',
    abbreviation: 'NU',
    record: '12–4–2');
const _opponent = SportsTeam(
    id: 'coast',
    name: 'Coastal Athletic',
    shortName: 'Coastal',
    abbreviation: 'CA',
    score: '2');
final _league = kSportsLeagues.firstWhere((l) => l.id == 'eng.1');
SportsDetails _data() => SportsDetails(
        title: _team.name,
        source: 'Test data',
        fetchedAt: DateTime(2026, 11, 4),
        sections: [
          const SportsDetailSection('Season record',
              kind: SportsDetailKind.record,
              columns: [
                'Record'
              ],
              rows: [
                SportsDetailRow('Overall', ['12–4–2']),
                SportsDetailRow('Home', ['7–1–1']),
                SportsDetailRow('Away', ['5–3–1']),
              ]),
          SportsDetailSection('Roster',
              kind: SportsDetailKind.lineup,
              columns: const [
                '#',
                'Position'
              ],
              rows: [
                for (var i = 0; i < 1000; i++)
                  SportsDetailRow('Player $i', ['$i', 'Midfielder'],
                      id: '$i',
                      detail: i == 0 ? 'Captain · Starter' : 'Active'),
              ]),
        ]);

void main() {
  for (final (size, tv) in [
    (const Size(320, 568), false),
    (const Size(844, 390), false),
    (const Size(960, 540), true)
  ]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
          'detail roster stays lazy and row data accessible at $size / $scale',
          (tester) async {
        harness.viewport(tester, size);
        final (storage, prefs) = await harness.preferences(tv);
        addTearDown(prefs.dispose);
        final service = fixtures.Details();
        addTearDown(service.close);
        await tester.pumpWidget(harness.app(
            storage,
            prefs,
            MediaQuery(
                data: MediaQueryData(
                    size: size, textScaler: TextScaler.linear(scale)),
                child: SportsDetailsPanel(
                    league: _league,
                    team: _team,
                    initialData: _data(),
                    standing: const StandingTeam(
                        _team,
                        {
                          'wins': '12',
                          'ties': '4',
                          'losses': '2',
                          'points': '40'
                        },
                        2),
                    service: service))));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(SportsOptionButton, 'Roster'));
        await tester.pumpAndSettle();
        expect(find.text('Captain · Starter'), findsOneWidget);
        expect(find.text('Player 999'), findsNothing);
        expect(find.byType(SportsDetailTable), findsOneWidget);
        final mountedPlayers = find.byWidgetPredicate(
            (w) => w is Text && (w.data?.startsWith('Player ') ?? false));
        expect(mountedPlayers.evaluate().length, lessThan(30));
        await tester.tap(find.text('Player 0'));
        await tester.pumpAndSettle();
        expect(
            find.descendant(
                of: find.byType(SportsCompactDialog),
                matching: find.text('Midfielder')),
            findsOneWidget);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        if (tv) {
          for (var i = 0; i < 20; i++) {
            await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
            await tester.pump();
          }
          expect(find.text('Player 20'), findsOneWidget);
        }
        expect(service.calls, 0);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      });
    }
  }
  testWidgets(
      'period preview opens the full innings table without another request',
      (tester) async {
    harness.viewport(tester, const Size(320, 568));
    final (storage, prefs) = await harness.preferences(false);
    addTearDown(prefs.dispose);
    final league = kSportsLeagues.firstWhere((l) => l.id == 'mlb');
    final service = fixtures.Details();
    addTearDown(service.close);
    final game = SportsGame(
        id: 'extra-innings',
        league: league,
        start: DateTime(2026, 11, 4),
        state: GameState.post,
        statusText: 'Final',
        home: _team,
        away: _opponent);
    final data = SportsDetails(
        title: game.title,
        source: 'Fixture',
        fetchedAt: DateTime(2026),
        sections: [
          SportsDetailSection('Innings',
              kind: SportsDetailKind.periods,
              columns: [
                for (var i = 1; i <= 12; i++) '$i'
              ],
              rows: const [
                SportsDetailRow('Northside', [
                  '0',
                  '1',
                  '0',
                  '0',
                  '2',
                  '0',
                  '0',
                  '1',
                  '0',
                  '0',
                  '0',
                  '2'
                ]),
                SportsDetailRow('Coastal', [
                  '0',
                  '0',
                  '1',
                  '0',
                  '0',
                  '1',
                  '0',
                  '0',
                  '2',
                  '0',
                  '0',
                  '0'
                ])
              ])
        ]);
    await tester.pumpWidget(harness.app(
        storage,
        prefs,
        SportsDetailsPanel(
            league: league, game: game, service: service, initialData: data)));
    await tester.pumpAndSettle();
    expect(find.text('By inning'), findsOneWidget);
    await tester.ensureVisible(find.text('View all'));
    await tester.tap(find.text('View all'));
    await tester.pumpAndSettle();
    expect(find.byType(SportsDetailTable), findsOneWidget);
    await tester.tap(find.text('Northside'));
    await tester.pumpAndSettle();
    expect(
        find.descendant(
            of: find.byType(SportsCompactDialog), matching: find.text('12')),
        findsOneWidget);
    expect(service.calls, 0);
    expect(tester.takeException(), isNull);
  });
  testWidgets('fixture rows hide scores and retain both opponents',
      (tester) async {
    harness.viewport(tester, const Size(320, 568));
    final (storage, prefs) = await harness.preferences(false);
    addTearDown(prefs.dispose);
    final game = SportsGame(
        id: 'match',
        league: _league,
        start: DateTime(2026, 11, 4, 19),
        state: GameState.post,
        statusText: 'Final',
        home: _team,
        away: _opponent);
    for (final hide in [true, false]) {
      await tester.pumpWidget(harness.app(
          storage,
          prefs,
          SizedBox(
              height: 90,
              child: SportsDetailFixtureRow(game: game, hideScores: hide))));
      expect(find.text(_team.name), findsOneWidget);
      expect(find.text(_opponent.name), findsOneWidget);
      expect(find.text('2'), hide ? findsNothing : findsOneWidget);
      expect(tester.takeException(), isNull);
    }
  });
}
