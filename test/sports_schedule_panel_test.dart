import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:nox_iptv/models/sports.dart';
import 'package:nox_iptv/services/app_preferences.dart';
import 'package:nox_iptv/services/storage_service.dart';
import 'package:nox_iptv/services/sports_service.dart';
import 'package:nox_iptv/widgets/sports_schedule_panel.dart';
import 'package:nox_iptv/widgets/sports_fixture_row.dart';
import 'package:nox_iptv/widgets/sports_schedule_calendar.dart';
import 'package:nox_iptv/widgets/sports_schedule_days.dart';
import 'package:nox_iptv/widgets/compact_choice_list.dart';

class Scores extends SportsService {
  Scores()
      : super.withClient(MockClient((_) async => http.Response('{}', 200)));
  int calls = 0;
  final requestedLeagues = <String>[];
  Completer<({List<SportsGame> games, bool incomplete})>? pending;
  @override
  Future<({List<SportsGame> games, bool incomplete})> scheduleGames(
      SportsLeague league, DateTime from, DateTime through,
      {bool Function()? shouldContinue}) async {
    calls++;
    requestedLeagues.add(league.id);
    if (pending != null) return pending!.future;
    return (
      games: [
        for (var i = 0; i < 50; i++)
          SportsGame(
              id: '$i',
              league: league,
              start: from.add(Duration(hours: i)),
              state: GameState.pre,
              statusText: i == 0 ? '11/1 - 3:30 PM EST' : 'Scheduled',
              home: const SportsTeam(
                  id: 'h',
                  name: 'Home Club',
                  shortName: 'Home',
                  abbreviation: 'H'),
              away: const SportsTeam(
                  id: 'a',
                  name: 'Away Club',
                  shortName: 'Away',
                  abbreviation: 'A'))
      ],
      incomplete: false
    );
  }
}

class DayScores extends Scores {
  final days = <DateTime>[];
  void Function(List<SportsGame>)? progress;
  Completer<({List<SportsGame> games, bool incomplete})>? dayPending;
  List<SportsGame> fixtures(DateTime day, [int count = 1000]) => [
        for (var i = 0; i < count; i++)
          SportsGame(
              id: '$i',
              league: sportsLeagueById(i.isEven ? 'nba' : 'eng.1')!,
              start: day.add(Duration(minutes: i)),
              state: GameState.pre,
              statusText: 'Scheduled',
              home: const SportsTeam(
                  id: 'h',
                  name: 'Home Club',
                  shortName: 'Home',
                  abbreviation: 'H'),
              away: const SportsTeam(
                  id: 'a',
                  name: 'Away Club',
                  shortName: 'Away',
                  abbreviation: 'A'))
      ];
  @override
  Future<({List<SportsGame> games, bool incomplete})> scheduleDay(
      List<SportsLeague> leagues, DateTime day,
      {bool Function()? shouldContinue,
      void Function(List<SportsGame>)? onProgress}) async {
    days.add(day);
    progress = onProgress;
    return dayPending?.future ??
        Future.value((games: fixtures(day), incomplete: false));
  }
}

class _ResumingScores extends DayScores {
  int cacheReads = 0;
  final phases = <SchedulerPhase>[];
  @override
  List<SportsGame> cachedScheduleDay(List<SportsLeague> leagues, DateTime day) {
    cacheReads++;
    phases.add(SchedulerBinding.instance.schedulerPhase);
    return fixtures(day, 12);
  }
}

class _IndexedFixture extends SportsGame {
  _IndexedFixture(DateTime day)
      : super(
            id: 'indexed',
            league: sportsLeagueById('nba')!,
            start: day.add(const Duration(hours: 23)),
            state: GameState.pre,
            statusText: 'Scheduled',
            home: const SportsTeam(
                id: 'h',
                name: 'Indexed club',
                shortName: 'Home',
                abbreviation: 'H'),
            away: const SportsTeam(
                id: 'a',
                name: 'Away club',
                shortName: 'Away',
                abbreviation: 'A'));
  int indexReads = 0;
  @override
  String get title => 'Indexed fixture';
  @override
  SportsTeam get first {
    indexReads++;
    return super.first;
  }
}

Future<void> tapDate(WidgetTester tester, String id) async {
  final strip = find.byType(SportsScheduleDays);
  final list = tester.widget<ListView>(
      find.descendant(of: strip, matching: find.byType(ListView)));
  list.controller!.jumpTo(0);
  await tester.pumpAndSettle();
  final target = find.byKey(ValueKey(id));
  await tester.scrollUntilVisible(target, 80,
      scrollable:
          find.descendant(of: strip, matching: find.byType(Scrollable)));
  await tester.pumpAndSettle();
  await tester.tap(target);
}

void main() {
  for (final tv in [false, true]) {
    testWidgets('schedule reuses partial rows across tab visits (tv=$tv)',
        (tester) async {
      tester.view.physicalSize =
          tv ? const Size(960, 540) : const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({});
      final storage = StorageService();
      await storage.init();
      final prefs = AppPreferences(storage);
      await prefs.init();
      prefs.isTelevision = tv;
      addTearDown(prefs.dispose);
      final entry = FocusNode();
      addTearDown(entry.dispose);
      final browse = SportsScheduleBrowseState();
      final scores = _ResumingScores()..dayPending = Completer();
      final day = DateTime(2026, 11, 10);
      Widget app() => ChangeNotifierProvider.value(
          value: prefs,
          child: MaterialApp(
              home: Scaffold(
                  body: SportsSchedulePanel(
                      browseState: browse,
                      entryFocus: entry,
                      onFocusToolbar: () {},
                      overviewLeagues: [
                        sportsLeagueById('nba')!,
                        sportsLeagueById('eng.1')!
                      ],
                      service: scores,
                      clock: () => day,
                      layoutBuilder: (filters, actions, content) => content))));
      List<CompactChoice> rows() => tester
          .widget<CompactChoiceList>(find.byType(CompactChoiceList))
          .choices;
      await tester.pumpWidget(app());
      expect(scores.cacheReads, 0,
          reason: 'Feed assembly must not run inside the transition frame');
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(milliseconds: 1));
      expect(scores.cacheReads, 0);
      expect(scores.days, isEmpty,
          reason: 'Leaving before entry work starts must cancel that work');
      await tester.pumpWidget(app());
      await tester.pump(const Duration(milliseconds: 1));
      expect(scores.cacheReads, 1);
      expect(
          scores.phases, isNot(contains(SchedulerPhase.persistentCallbacks)));
      scores.progress!(scores.fixtures(day, 20));
      await tester.pump(const Duration(milliseconds: 1));
      expect(rows(), hasLength(20));
      final oldResponse = scores.dayPending!;
      final oldProgress = scores.progress!;
      await tester.pumpWidget(const SizedBox());
      scores.dayPending = Completer();
      await tester.pumpWidget(app());
      expect(rows(), hasLength(20),
          reason:
              'Already displayed fixtures are available on the first frame');
      await tester.pump(const Duration(milliseconds: 1));
      expect(scores.cacheReads, 1,
          reason: 'An unchanged partial view reuses its prepared list');
      expect(scores.days, hasLength(2),
          reason: 'A cancelled load must still refresh, not become fresh');
      oldProgress(scores.fixtures(day, 80));
      oldResponse
          .complete((games: scores.fixtures(day, 80), incomplete: false));
      await tester.pump(const Duration(milliseconds: 1));
      expect(rows(), hasLength(20),
          reason: 'Discard the departed panel response');
      final indexed = _IndexedFixture(day);
      final completed = [...scores.fixtures(day, 39), indexed];
      scores.progress!(completed);
      await tester.pump(const Duration(milliseconds: 1));
      scores.dayPending!.complete((games: [...completed], incomplete: false));
      await tester.pumpAndSettle();
      expect(rows(), hasLength(40));
      await tester.pumpWidget(const SizedBox());
      indexed.indexReads = 0;
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      expect(rows(), hasLength(40));
      expect(indexed.indexReads, 0,
          reason:
              'Equivalent completion lists must retain the prepared search index');
      expect(scores.days, hasLength(2),
          reason: 'Fresh complete data needs no load');
      await tester.pumpWidget(const SizedBox());
      browse.from = DateTime(2026, 11, 11);
      scores.dayPending = Completer();
      await tester.pumpWidget(app());
      expect(find.byType(SportsFixtureRow), findsNothing,
          reason: 'Retained fixtures must not leak into a different day');
      await tester.pump(const Duration(milliseconds: 1));
      expect(scores.cacheReads, 2);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      scores.dayPending!
          .complete((games: const <SportsGame>[], incomplete: false));
      await tester.pump(const Duration(milliseconds: 1));
    });
  }

  testWidgets(
      'enabled leagues update an open schedule and discard stale responses',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    final storage = StorageService();
    await storage.init();
    final prefs = AppPreferences(storage);
    await prefs.init();
    prefs.isTelevision = false;
    addTearDown(prefs.dispose);
    final entry = FocusNode();
    addTearDown(entry.dispose);
    final scores = DayScores()..pending = Completer();
    final browse = SportsScheduleBrowseState()
      ..initialized = true
      ..leagueId = 'nba'
      ..sport = 'basketball';
    var enabled = [sportsLeagueById('nba')!, sportsLeagueById('eng.1')!];
    Widget app() => ChangeNotifierProvider.value(
        value: prefs,
        child: MaterialApp(
            home: Scaffold(
                body: SportsSchedulePanel(
                    browseState: browse,
                    entryFocus: entry,
                    onFocusToolbar: () {},
                    overviewLeagues: enabled,
                    service: scores,
                    clock: () => DateTime(2026, 11, 10),
                    layoutBuilder: (filters, actions, content) =>
                        Column(children: [
                          SizedBox(
                              height: 48,
                              child: Row(children: [
                                Expanded(child: filters),
                                actions
                              ])),
                          Expanded(child: content)
                        ])))));
    await tester.pumpWidget(app());
    await tester.pump(const Duration(milliseconds: 1));
    expect(scores.calls, 1);
    enabled = [sportsLeagueById('eng.1')!];
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    expect(browse.leagueId, isNull);
    expect(browse.sport, isNull);
    expect(scores.days.length, 1);
    expect(find.byType(SportsFixtureRow), findsWidgets);
    scores.pending!.complete((games: const <SportsGame>[], incomplete: false));
    await tester.pumpAndSettle();
    expect(find.byType(SportsFixtureRow), findsWidgets,
        reason: 'The disabled league response cannot replace the new scope.');
    await tester.tap(find.byKey(const ValueKey('schedule-range-7')));
    await tester.pumpAndSettle();
    enabled = [sportsLeagueById('nba')!, sportsLeagueById('eng.1')!];
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    expect(scores.days.length, 1,
        reason: 'Changing calendar scope does not fetch fixtures.');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  for (final size in [
    const Size(320, 568),
    const Size(390, 844),
    const Size(844, 390),
    const Size(960, 540)
  ]) {
    testWidgets('schedule is lazy, compact and navigable at $size',
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
      addTearDown(prefs.dispose);
      final scores = Scores(),
          browse = SportsScheduleBrowseState(),
          entry = FocusNode();
      addTearDown(entry.dispose);
      SportsGame? opened;
      var automatic = false;
      Widget app() => ChangeNotifierProvider.value(
          value: prefs,
          child: MaterialApp(
              home: Scaffold(
                  body: SportsSchedulePanel(
                      browseState: browse,
                      entryFocus: entry,
                      onFocusToolbar: () {},
                      service: scores,
                      initialLeague:
                          automatic ? sportsLeagueById('eng.1') : null,
                      onGameDetails: (game) => opened = game,
                      clock: () => DateTime(2026, 11, 10),
                      layoutBuilder: (filters, actions, content) =>
                          Column(children: [
                            SizedBox(
                                height: 48,
                                child: Row(children: [
                                  Expanded(child: filters),
                                  actions
                                ])),
                            Expanded(child: content)
                          ])))));
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      expect(scores.calls, 0);
      await tester.tap(find.byKey(const ValueKey('schedule-league')));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(scores.calls, 0);
      await tester.pumpWidget(const SizedBox());
      automatic = true;
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      expect(scores.calls, 1);
      expect(find.textContaining('EST'), findsNothing,
          reason: 'Do not mix provider and viewer timezones');
      expect(find.text('50 fixtures · local time · ESPN'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('eng.1:0')));
      await tester.pumpAndSettle();
      expect(opened?.id, '0');
      expect(tester.takeException(), isNull);
      expect(scores.calls, 1,
          reason: 'Opening fixture information makes no extra request');
      expect(tester.getSize(find.byKey(const ValueKey('eng.1:0'))).height, 52);
      if (size.width < 600 && size.height > size.width) {
        expect(
            tester
                .getSize(find.byKey(const ValueKey('schedule-previous')))
                .height,
            36);
      }

      // Date and text filtering are local; opening a result retains its identity.
      await tapDate(tester, 'schedule-day-2026-11-11');
      await tester.pumpAndSettle();
      expect(scores.calls, 1);
      expect(browse.selectedDay, DateTime(2026, 11, 11));
      expect(find.byKey(const ValueKey('eng.1:0')), findsNothing);
      expect(find.byKey(const ValueKey('eng.1:24')), findsOneWidget);
      await tapDate(tester, 'schedule-day-all');
      await tester.pumpAndSettle();
      await tester
          .ensureVisible(find.byKey(const ValueKey('schedule-search-toggle')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('schedule-search-toggle')));
      await tester.pumpAndSettle();
      if (prefs.isTelevision) {
        await tester.sendKeyEvent(LogicalKeyboardKey.select);
        await tester.pump();
      }
      await tester.enterText(
          find.byKey(const ValueKey('schedule-search')), 'not a team');
      await tester.pumpAndSettle();
      expect(find.text('No fixtures match these filters'), findsOneWidget);
      if (size.width < 600 && size.height > size.width) {
        expect(
            tester
                .getSize(find.byKey(const ValueKey('schedule-search')))
                .height,
            lessThanOrEqualTo(42));
      }
      expect(scores.calls, 1);
      await tester.tap(find.text('Show all fixtures'));
      await tester.pumpAndSettle();
      expect(browse.query, isEmpty);
      await tester.tap(find.byTooltip('Clear search'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      prefs.setUse24h(false);
      await tester.pumpAndSettle();
      expect(find.text('12:00 AM'), findsOneWidget);
      expect(scores.calls, 1);
      prefs.setUse24h(true);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('schedule-range-30')));
      await tester.pumpAndSettle();
      expect(scores.calls, 2);
      expect(browse.days, 30);
      await tester.ensureVisible(find.byKey(const ValueKey('schedule-next')));
      await tester.tap(find.byKey(const ValueKey('schedule-next')));
      await tester.pumpAndSettle();
      expect(scores.calls, 3);
      expect(browse.from, DateTime(2026, 12, 1));
      expect(browse.days, 31);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(app());
      expect(find.byType(SportsScheduleCalendar), findsOneWidget);
      await tester.pumpAndSettle();
      expect(scores.calls, 3,
          reason: 'Returning uses the recent window immediately');
      await tester
          .tap(find.byKey(const ValueKey('schedule-calendar-day-2026-12-01')));
      await tester.pumpAndSettle();
      expect(scores.calls, 3, reason: 'Drilling into a loaded month is local');
      await tester.tap(find.byKey(const ValueKey('schedule-today')));
      await tester.pumpAndSettle();
      expect(browse.from, DateTime(2026, 11, 10));
      expect(scores.calls, 4);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
  for (final size in [
    const Size(320, 568),
    const Size(390, 844),
    const Size(844, 390),
    const Size(960, 540)
  ]) {
    testWidgets(
        'today overview loads dates only on request and stays lazy at $size',
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
      addTearDown(prefs.dispose);
      final entry = FocusNode();
      addTearDown(entry.dispose);
      final browse = SportsScheduleBrowseState(), scores = DayScores();
      Widget app() => ChangeNotifierProvider.value(
          value: prefs,
          child: MaterialApp(
              home: Scaffold(
                  body: SportsSchedulePanel(
                      browseState: browse,
                      entryFocus: entry,
                      onFocusToolbar: () {},
                      service: scores,
                      initialLeague: sportsLeagueById('nhl'),
                      overviewLeagues: [
                        sportsLeagueById('nba')!,
                        sportsLeagueById('eng.1')!
                      ],
                      clock: () => DateTime(2026, 11, 10),
                      layoutBuilder: (filters, actions, content) =>
                          Column(children: [
                            SizedBox(
                                height: 48,
                                child: Row(children: [
                                  Expanded(child: filters),
                                  actions
                                ])),
                            Expanded(child: content)
                          ])))));
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      expect(scores.days, [DateTime(2026, 11, 10)]);
      expect(scores.calls, 0);
      expect(browse.leagueId, isNull);
      expect(find.text('All sports'), findsOneWidget);
      expect(find.byKey(const ValueKey('schedule-range-30')), findsOneWidget);
      final timeRows = tester
          .widget<CompactChoiceList>(find.byType(CompactChoiceList))
          .choices;
      expect(timeRows.take(3).map((r) => r.id), ['nba:0', 'eng.1:1', 'nba:2']);
      expect(timeRows.every((r) => r.group == null), isTrue);
      expect(
          tester
              .widgetList<SportsFixtureRow>(find.byType(SportsFixtureRow))
              .every((row) => row.showSport && row.showLeague),
          isTrue);
      await tester
          .ensureVisible(find.byKey(const ValueKey('schedule-search-toggle')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('schedule-search-toggle')));
      await tester.pumpAndSettle();
      if (prefs.isTelevision) {
        await tester.sendKeyEvent(LogicalKeyboardKey.select);
        await tester.pump();
      }
      for (final query in ['basketball', 'NBA']) {
        await tester.enterText(
            find.byKey(const ValueKey('schedule-search')), query);
        await tester.pumpAndSettle();
        final filtered = tester
            .widget<CompactChoiceList>(find.byType(CompactChoiceList))
            .choices;
        expect(filtered, hasLength(500));
        expect(filtered.every((row) => row.id.startsWith('nba:')), isTrue);
        expect(find.byType(SportsFixtureRow).evaluate().length, lessThan(25));
      }
      await tester.tap(find.byTooltip('Clear search'));
      await tester.pumpAndSettle();
      expect(scores.days, hasLength(1));
      expect(
          tester
              .widget<CompactChoiceList>(find.byType(CompactChoiceList))
              .choices,
          hasLength(1000));
      await tester
          .ensureVisible(find.byKey(const ValueKey('schedule-display')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('schedule-display')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('schedule-order-sport')));
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      expect(browse.groupBySport, isTrue);
      expect(
          tester
              .widgetList<SportsFixtureRow>(find.byType(SportsFixtureRow))
              .every((row) => !row.showSport),
          isTrue);
      expect(scores.days.length, 1);
      expect(
          tester
              .widget<CompactChoiceList>(find.byType(CompactChoiceList))
              .choices
              .take(2)
              .map((r) => r.id),
          ['nba:0', 'nba:2']);
      expect(find.byType(SportsFixtureRow).evaluate().length, lessThan(25));
      expect(tester.takeException(), isNull);
      await tapDate(tester, 'schedule-day-2026-11-11');
      await tester.pumpAndSettle();
      expect(scores.days, [DateTime(2026, 11, 10), DateTime(2026, 11, 11)]);
      await tapDate(tester, 'schedule-day-2026-11-10');
      await tester.pumpAndSettle();
      expect(scores.days.length, 2,
          reason: 'Recent days return without a request');
      await tester.tap(find.byKey(const ValueKey('schedule-sport')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('basketball')));
      await tester.pumpAndSettle();
      expect(browse.sport, 'basketball');
      expect(scores.days.length, 2);
      expect(find.textContaining('500 fixtures · local time'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      expect(browse.sport, 'basketball');
      expect(scores.days.length, 2);
      // A fresh requested day publishes incrementally, but never moves a focused row.
      scores.dayPending = Completer();
      await tapDate(tester, 'schedule-day-2026-11-12');
      await tester.pump();
      final initial = scores.fixtures(DateTime(2026, 11, 12), 20);
      scores.progress!(initial);
      await tester.pump();
      final row = find.byKey(const ValueKey('nba:0'));
      final ink = tester.widget<InkWell>(row);
      ink.focusNode!.requestFocus();
      await tester.pump();
      final before = tester.getRect(row);
      scores.progress!(scores.fixtures(DateTime(2026, 11, 12)));
      await tester.pump();
      expect(ink.focusNode!.hasFocus, isTrue);
      expect(tester.getRect(row).top, before.top);
      expect(
          find.byKey(const ValueKey('schedule-apply-updates')), findsOneWidget);
      scores.dayPending!.complete(
          (games: scores.fixtures(DateTime(2026, 11, 12)), incomplete: false));
      await tester.pumpAndSettle();
      if (prefs.isTelevision) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
        await tester.pumpAndSettle();
        expect(entry.hasFocus, isTrue);
        for (var i = 0; i < 4; i++) {
          await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
          await tester.pumpAndSettle();
        }
        var updateFocused = false;
        FocusManager.instance.primaryFocus?.context?.visitAncestorElements((e) {
          if (e.widget.key == const ValueKey('schedule-apply-updates')) {
            updateFocused = true;
          }
          return !updateFocused;
        });
        expect(updateFocused, isTrue);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      } else {
        await tester.ensureVisible(
            find.byKey(const ValueKey('schedule-apply-updates')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('schedule-apply-updates')));
      }
      await tester.pumpAndSettle();
      expect(find.textContaining('500 fixtures · local time'), findsOneWidget);
      expect(find.byType(SportsFixtureRow).evaluate().length, lessThan(25));
      // One local calendar, with week navigation loading only the selected day.
      expect(find.byKey(const ValueKey('schedule-date')), findsOneWidget);
      scores.dayPending = null;
      final requestsBeforeWeek = scores.days.length;
      await tester.tap(find.byTooltip('Next week'));
      await tester.pumpAndSettle();
      expect(browse.from, DateTime(2026, 11, 19));
      expect(scores.days.length, requestsBeforeWeek + 1);
      await tester.tap(find.byTooltip('Previous week'));
      await tester.pumpAndSettle();
      expect(browse.from, DateTime(2026, 11, 12));
      expect(scores.days.length, requestsBeforeWeek + 1);
      await tester.tap(find.byKey(const ValueKey('schedule-date')));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(scores.days.length, requestsBeforeWeek + 1);
      await tester.tap(find.byKey(const ValueKey('schedule-range-7')));
      await tester.pumpAndSettle();
      expect(find.byType(SportsScheduleCalendar), findsOneWidget);
      expect(find.byType(SportsFixtureRow), findsNothing);
      expect(scores.days.length, requestsBeforeWeek + 1,
          reason: 'Calendar opens without requests');
      await tester.tap(find.byKey(const ValueKey('schedule-load-week')));
      await tester.pumpAndSettle();
      final loaded = scores.days.length;
      expect(
          browse.summaries.keys
              .toSet()
              .containsAll(List.generate(7, (i) => DateTime(2026, 11, 9 + i))),
          isTrue);
      await tester.tap(find.byKey(const ValueKey('schedule-load-week')));
      await tester.pumpAndSettle();
      expect(scores.days.length, loaded, reason: 'Fresh summaries reused');
      await tester.tap(find.byKey(const ValueKey('schedule-range-30')));
      await tester.pumpAndSettle();
      expect(scores.days.length, loaded,
          reason: 'Month has no automatic fan-out');
      final calendar = tester
          .widget<SportsScheduleCalendar>(find.byType(SportsScheduleCalendar));
      expect(calendar.from, DateTime(2026, 11, 1));
      expect(calendar.days, 30);
      final date =
          find.byKey(const ValueKey('schedule-calendar-day-2026-11-12'));
      await tester.ensureVisible(date);
      await tester.tap(date);
      await tester.pumpAndSettle();
      expect(browse.calendarDays, 0);
      expect(browse.from, DateTime(2026, 11, 12));
      expect(scores.days.length, loaded,
          reason: 'Retained fixture day opens immediately');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
