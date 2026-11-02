import 'package:nox_iptv/widgets/sports_detail_views.dart';
import 'package:nox_iptv/widgets/sports_header_controls.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nox_iptv/models/sports.dart';
import 'package:nox_iptv/models/sports_details.dart';
import 'package:nox_iptv/services/sports_details_service.dart';
import 'package:nox_iptv/services/sports_service.dart';
import 'package:nox_iptv/widgets/sports_details_panel.dart';
import 'package:nox_iptv/widgets/sports_panel.dart';
import 'sports_panel_test.dart' as harness;

final league = kSportsLeagues.firstWhere((l) => l.id == 'nba');
const home = SportsTeam(
    id: '1', name: 'Home Club', shortName: 'Home', abbreviation: 'H');
const away = SportsTeam(
    id: '2', name: 'Away Club', shortName: 'Away', abbreviation: 'A');
SportsGame fixture(String id, SportsTeam h, SportsTeam a) => SportsGame(
    id: id,
    league: league,
    start: DateTime(2026, 11, 2, 12),
    state: GameState.pre,
    statusText: '3 PM EST',
    home: h,
    away: a);

class Details extends SportsDetailsService {
  int calls = 0;
  Completer<SportsDetails>? pending;
  SportsDetails? overrideResult;
  SportsDetails get result =>
      overrideResult ??
      SportsDetails(
          title: 'Game',
          source: 'ESPN',
          fetchedAt: DateTime(2026, 11, 2, 12),
          sections: [
            SportsDetailSection('Players', columns: const [
              'PTS',
              'REB',
              'AST',
              'MIN'
            ], rows: [
              for (var i = 0; i < 100; i++)
                SportsDetailRow('Player $i', ['${20 + i}', '5', '3', '31'],
                    detail: 'Starter')
            ])
          ]);
  @override
  Future<SportsDetails> game(SportsGame game, {bool refresh = false}) async {
    calls++;
    if (pending != null) return pending!.future;
    return result;
  }

  @override
  Future<SportsDetails> team(SportsLeague league, SportsTeam team,
      {bool refresh = false}) async {
    calls++;
    if (pending != null) return pending!.future;
    return result;
  }
}

class Fixtures extends SportsService {
  Fixtures()
      : super.withClient(MockClient((_) async => http.Response('{}', 200)));
  int calls = 0;
  Completer<({List<SportsGame> games, bool incomplete})>? pending;
  bool Function()? continueRequest;
  @override
  Future<({List<SportsGame> games, bool incomplete})> scheduleGames(
      SportsLeague league, DateTime from, DateTime through,
      {bool Function()? shouldContinue}) async {
    calls++;
    continueRequest = shouldContinue;
    if (pending != null) return pending!.future;
    expect(through.difference(from).inDays, 29);
    return (
      games: [
        fixture('match', home, away),
        fixture(
            'different-team',
            const SportsTeam(
                id: '3',
                name: 'Home Club',
                shortName: 'Home',
                abbreviation: 'H'),
            away)
      ],
      incomplete: false
    );
  }
}

void main() {
  testWidgets('innings table exposes all nine regulation innings on TV',
      (tester) async {
    harness.viewport(tester, const Size(960, 540));
    final (storage, prefs) = await harness.preferences(true);
    addTearDown(prefs.dispose);
    await tester.pumpWidget(harness.app(
        storage,
        prefs,
        Center(
            child: SizedBox(
                width: 540,
                height: 400,
                child: SportsDetailTable(
                    section: SportsDetailSection('Innings',
                        kind: SportsDetailKind.periods,
                        columns: [
                      for (var i = 1; i <= 9; i++) '$i'
                    ],
                        rows: const [
                      SportsDetailRow(
                          'HOME', ['0', '0', '0', '0', '0', '0', '0', '0', '0'])
                    ]))))));
    await tester.pumpAndSettle();
    expect(find.text('9'), findsOneWidget);
    expect(find.textContaining('Select a row'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final size in [
    const Size(320, 568),
    const Size(390, 844),
    const Size(844, 390),
    const Size(960, 540)
  ]) {
    testWidgets('details preserve browsing and fit $size', (tester) async {
      harness.viewport(tester, size);
      if (size.width == 320) {
        tester.platformDispatcher.textScaleFactorTestValue = 1.5;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      }
      final (storage, prefs) = await harness.preferences(size.width >= 960);
      addTearDown(prefs.dispose);
      final service = Details();
      addTearDown(service.close);
      await tester.pumpWidget(harness.app(
          storage,
          prefs,
          Builder(
              builder: (context) => TextButton(
                  key: const ValueKey('origin'),
                  onPressed: () => showSportsPanel<void>(
                      context: context,
                      besidePreview: true,
                      builder: (_) => SportsDetailsPanel(
                          league: league,
                          game: fixture('g', home, away),
                          service: service)),
                  child: const Text('Open')))));
      final original = tester.element(find.byKey(const ValueKey('origin')));
      expect(service.calls, 0);
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(service.calls, 1);
      expect(find.textContaining('EST'), findsNothing);
      await tester.tap(find.text('Players'));
      await tester.pumpAndSettle();
      expect(find.text('Player 0'), findsOneWidget);
      expect(find.text('Player 99'), findsNothing, reason: 'Rows remain lazy');
      final heading = tester.getCenter(find.text('PTS'));
      final value = tester.getCenter(find.text('20'));
      expect((heading.dx - value.dx).abs(), lessThan(2));
      await tester.tap(find.text('Player 0'));
      await tester.pumpAndSettle();
      expect(
          find.descendant(
              of: find.byType(SportsCompactDialog), matching: find.text('MIN')),
          findsOneWidget);
      expect(
          find.descendant(
              of: find.byType(SportsCompactDialog), matching: find.text('31')),
          findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      for (var i = 0; i < 15; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pump();
      }
      expect(find.text('Player 15'), findsOneWidget);
      expect(service.calls, 1,
          reason: 'Browsing and row details do not refetch');
      await tester.tap(find.byTooltip('Close').first);
      await tester.pumpAndSettle();
      expect(
          tester.element(find.byKey(const ValueKey('origin'))), same(original));
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('hidden scores require explicit reveal and late response is safe',
      (tester) async {
    final (storage, prefs) = await harness.preferences(true);
    addTearDown(prefs.dispose);
    final service = Details()..pending = Completer<SportsDetails>();
    addTearDown(service.close);
    await tester.pumpWidget(harness.app(
        storage,
        prefs,
        SportsDetailsPanel(
            league: league,
            game: fixture('g', home, away),
            service: service,
            hideScores: true)));
    expect(service.calls, 0);
    await tester.tap(find.byKey(const ValueKey('sports-reveal-details')));
    await tester.pump();
    expect(service.calls, 1);
    await tester.pumpWidget(const SizedBox());
    service.pending!.complete(service.result);
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
  testWidgets('team fixtures are explicit and matched only by identity',
      (tester) async {
    final (storage, prefs) = await harness.preferences(true);
    addTearDown(prefs.dispose);
    final service = Details(), scores = Fixtures();
    addTearDown(service.close);
    await tester.pumpWidget(harness.app(
        storage,
        prefs,
        SportsDetailsPanel(
            league: league,
            team: home,
            service: service,
            scores: scores,
            hideScores: true)));
    await tester.pumpAndSettle();
    expect(scores.calls, 0);
    await tester.tap(find.text('Upcoming fixtures'));
    await tester.pumpAndSettle();
    expect(scores.calls, 1);
    expect(find.byKey(const ValueKey('team-fixture-match')), findsOneWidget);
    expect(find.byKey(const ValueKey('team-fixture-different-team')),
        findsNothing);
    await tester.tap(find.byKey(const ValueKey('team-fixture-match')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('sports-reveal-details')), findsOneWidget);
    expect(service.calls, 1,
        reason: 'Team browsing must preserve game score hiding');
    expect(tester.takeException(), isNull);
  });
  testWidgets('cancelled team fixtures are discarded and reload on return',
      (tester) async {
    final (storage, prefs) = await harness.preferences(true);
    addTearDown(prefs.dispose);
    final service = Details(), scores = Fixtures();
    addTearDown(service.close);
    final pending = Completer<({List<SportsGame> games, bool incomplete})>();
    scores.pending = pending;
    await tester.pumpWidget(harness.app(
        storage,
        prefs,
        SportsDetailsPanel(
            league: league, team: home, service: service, scores: scores)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Upcoming fixtures'));
    await tester.pump();
    expect(scores.continueRequest!(), isTrue);
    await tester.tap(find.byKey(const ValueKey('sports-detail-section')));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(const ValueKey('detail-section-overview')));
    await tester.pumpAndSettle();
    expect(scores.continueRequest!(), isFalse);
    pending.complete((games: <SportsGame>[], incomplete: false));
    scores.pending = null;
    await tester.pumpAndSettle();
    await tester.tap(find.text('Upcoming fixtures'));
    await tester.pumpAndSettle();
    expect(scores.calls, 2);
    expect(find.byKey(const ValueKey('team-fixture-match')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
      'refresh preserves selected table and coherent stale score/status',
      (tester) async {
    final (storage, prefs) = await harness.preferences(true);
    addTearDown(prefs.dispose);
    final service = Details();
    addTearDown(service.close);
    final players = service.result.sections.single;
    await tester.pumpWidget(harness.app(
        storage,
        prefs,
        SportsDetailsPanel(
            league: league, game: fixture('g', home, away), service: service)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Players'));
    await tester.pumpAndSettle();
    service.overrideResult = SportsDetails(
        title: 'Game',
        source: 'ESPN',
        fetchedAt: DateTime.now(),
        subtitle: 'Final',
        scoreLine: 'Home 100\nAway 90',
        sections: [const SportsDetailSection('Information'), players]);
    await tester.tap(find.byKey(const ValueKey('sports-detail-refresh')));
    await tester.pumpAndSettle();
    expect(find.text('Player 0'), findsOneWidget);
    service.overrideResult = service.result.withRefreshFailure();
    await tester.tap(find.byKey(const ValueKey('sports-detail-refresh')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('sports-detail-section')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('detail-section-overview')));
    await tester.pumpAndSettle();
    expect(find.text('Final'), findsOneWidget);
    expect(find.text('Home 100\nAway 90'), findsOneWidget);
    expect(find.text('Scheduled'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
