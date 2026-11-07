import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:nox_iptv/models/sports.dart';
import 'package:nox_iptv/services/app_preferences.dart';
import 'package:nox_iptv/services/storage_service.dart';
import 'package:nox_iptv/widgets/sports_schedule_calendar.dart';
import 'package:nox_iptv/widgets/sports_schedule_panel.dart';
import 'sports_schedule_panel_test.dart' show DayScores;

Future<void> mount(
    WidgetTester tester, DayScores service, SportsScheduleBrowseState browse,
    {double scale = 1}) async {
  SharedPreferences.setMockInitialValues({});
  final storage = StorageService();
  await storage.init();
  final prefs = AppPreferences(storage);
  await prefs.init();
  prefs.isTelevision = tester.view.physicalSize.width >= 960;
  addTearDown(prefs.dispose);
  final focus = FocusNode();
  addTearDown(focus.dispose);
  await tester.pumpWidget(ChangeNotifierProvider.value(
      value: prefs,
      child: MaterialApp(
          builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(scale)),
              child: child!),
          home: Scaffold(
              body: SportsSchedulePanel(
                  browseState: browse,
                  entryFocus: focus,
                  onFocusToolbar: () {},
                  service: service,
                  overviewLeagues: [
                    sportsLeagueById('nba')!,
                    sportsLeagueById('eng.1')!
                  ],
                  clock: () => DateTime(2026, 11, 10),
                  layoutBuilder: (filters, actions, content) => Column(
                      children: [filters, Expanded(child: content)]))))));
  await tester.pumpAndSettle();
}

class PartialMonthScores extends DayScores {
  bool failSoccer = true;
  @override
  Future<({List<SportsGame> games, bool incomplete})> scheduleGames(
      SportsLeague league, DateTime from, DateTime through,
      {bool Function()? shouldContinue}) async {
    calls++;
    if (league.id == 'eng.1' && failSoccer) {
      throw StateError('Fixture unavailable');
    }
    return (
      games: fixtures(from, 4).where((g) => g.league.id == league.id).toList(),
      incomplete: false
    );
  }
}

void main() {
  for (final size in [
    const Size(320, 568),
    const Size(844, 390),
    const Size(960, 540)
  ]) {
    testWidgets('calendar supports enlarged text and remote focus at $size',
        (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final scores = DayScores(), browse = SportsScheduleBrowseState();
      await mount(tester, scores, browse, scale: 2);
      final month = find.byKey(const ValueKey('schedule-range-30'));
      await tester.ensureVisible(month);
      await tester.tap(month);
      await tester.pumpAndSettle();
      expect(scores.days.length, 1);
      expect(find.byType(SportsScheduleCalendar), findsOneWidget);
      expect(tester.takeException(), isNull);
      final first =
          find.byKey(const ValueKey('schedule-calendar-day-2026-11-01'));
      await tester.ensureVisible(first);
      await tester.tap(first);
      await tester.pumpAndSettle();
      expect(browse.from, DateTime(2026, 11, 1));
      expect(scores.days.length, 2);
      await tester.ensureVisible(month);
      await tester.tap(month);
      await tester.pumpAndSettle();
      // Use keyboard traversal through the calendar's native focusable tiles.
      await tester.tap(first);
      await tester.pumpAndSettle();
      expect(scores.days.length, 2, reason: 'Loaded day is cached');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets(
      'month uses explicit, cached league requests and stores only counts',
      (tester) async {
    tester.view.physicalSize = const Size(960, 540);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final scores = DayScores(), browse = SportsScheduleBrowseState();
    await mount(tester, scores, browse);
    await tester.tap(find.byKey(const ValueKey('schedule-range-30')));
    await tester.pumpAndSettle();
    expect(scores.days.length, 1);
    expect(scores.calls, 0, reason: 'Opening a month must not fetch it');
    await tester.tap(find.byKey(const ValueKey('schedule-load-month')));
    await tester.pumpAndSettle();
    expect(scores.calls, 2,
        reason: 'Each league uses its existing monthly endpoint');
    expect(scores.days.length, 1, reason: 'No extra daily requests');
    expect(browse.summaries.length, 30);
    expect(browse.summaries.values.every((s) => !s.incomplete), isTrue);
    expect(browse.summaries[DateTime(2026, 11, 1)]!.sports,
        {'basketball': 24, 'soccer': 24});
    await tester.tap(find.byKey(const ValueKey('schedule-load-month')));
    await tester.pumpAndSettle();
    expect(scores.calls, 2, reason: 'Fresh complete summaries are reused');
    expect(tester.takeException(), isNull);
  });

  testWidgets('partial month preserves a fresh complete day and can retry',
      (tester) async {
    tester.view.physicalSize = const Size(960, 540);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final scores = PartialMonthScores(), browse = SportsScheduleBrowseState();
    await mount(tester, scores, browse);
    final today = browse.summaries[DateTime(2026, 11, 10)];
    expect(today, isNotNull);
    await tester.tap(find.byKey(const ValueKey('schedule-range-30')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('schedule-load-month')));
    await tester.pumpAndSettle();
    expect(browse.summaries[DateTime(2026, 11, 1)]!.incomplete, isTrue);
    expect(browse.summaries[DateTime(2026, 11, 1)]!.sports, {'basketball': 2});
    expect(browse.summaries[DateTime(2026, 11, 10)], same(today));
    scores.failSoccer = false;
    await tester.tap(find.byKey(const ValueKey('schedule-load-month')));
    await tester.pumpAndSettle();
    expect(browse.summaries.values.every((s) => !s.incomplete), isTrue);
    expect(browse.summaries[DateTime(2026, 11, 1)]!.sports,
        {'basketball': 2, 'soccer': 2});
    expect(browse.summaries.length, 30);
    expect(tester.takeException(), isNull);
  });

  for (final stop in [true, false]) {
    testWidgets(
        'month queue is sequential and cancels on ${stop ? 'Stop' : 'date change'}',
        (tester) async {
      tester.view.physicalSize = const Size(960, 540);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final scores = DayScores(), browse = SportsScheduleBrowseState();
      await mount(tester, scores, browse);
      await tester.tap(find.byKey(const ValueKey('schedule-range-30')));
      await tester.pumpAndSettle();
      scores.pending = Completer();
      await tester.tap(find.byKey(const ValueKey('schedule-load-month')));
      await tester.pump();
      expect(scores.calls, 1);
      expect(find.text('Stop'), findsOneWidget);
      await tester.tap(
          find.byKey(ValueKey(stop ? 'schedule-load-month' : 'schedule-next')));
      await tester.pump();
      scores.pending!.complete(
          (games: scores.fixtures(DateTime(2026, 11, 1)), incomplete: false));
      await tester.pumpAndSettle();
      expect(scores.calls, 1,
          reason: 'Queued leagues must not start after cancellation');
      expect(browse.summaries.containsKey(DateTime(2026, 11, 1)), isFalse);
      expect(find.text('Stop'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
      'remote walks calendar rows through unmounted days and back to Load month',
      (tester) async {
    tester.view.physicalSize = const Size(560, 260);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final key = GlobalKey<SportsScheduleCalendarState>();
    DateTime? selected;
    var exits = 0;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SportsScheduleCalendar(
                key: key,
                from: DateTime(2026, 11, 1),
                days: 30,
                today: DateTime(2026, 11, 10),
                selected: DateTime(2026, 11, 1),
                loading: false,
                summaries: const {},
                onSelected: (day) => selected = day,
                onLoadMonth: () {},
                onExitUp: () => exits++))));
    await tester.pumpAndSettle();
    Finder day(int n) => find.byKey(ValueKey(
        'schedule-calendar-day-2026-11-${n.toString().padLeft(2, '0')}'));
    key.currentState!.focusEntry();
    await tester.pumpAndSettle();
    expect(tester.widget<InkWell>(day(1)).focusNode!.hasFocus, isTrue);
    for (final n in [8, 15, 22, 29]) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(tester.widget<InkWell>(day(n)).focusNode!.hasFocus, isTrue);
      expect(tester.getRect(day(n)).bottom, lessThanOrEqualTo(260));
      expect(tester.getRect(day(n)).top, greaterThanOrEqualTo(0));
    }
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(selected, DateTime(2026, 11, 30));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    for (final n in [22, 15, 8, 1]) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pumpAndSettle();
      expect(tester.widget<InkWell>(day(n)).focusNode!.hasFocus, isTrue);
    }
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    final button = tester
        .widget<TextButton>(find.byKey(const ValueKey('schedule-load-month')));
    expect(button.focusNode!.hasFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    expect(exits, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'summary loading is cancellable and never publishes into another view',
      (tester) async {
    tester.view.physicalSize = const Size(960, 540);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final scores = DayScores(), browse = SportsScheduleBrowseState();
    await mount(tester, scores, browse);
    await tester.tap(find.byKey(const ValueKey('schedule-range-7')));
    await tester.pumpAndSettle();
    scores.dayPending = Completer();
    await tester.tap(find.byKey(const ValueKey('schedule-load-week')));
    await tester.pump();
    expect(scores.days.length, 2);
    expect(find.text('Stop'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('schedule-range-30')));
    await tester.pump();
    scores.dayPending!.complete(
        (games: scores.fixtures(DateTime(2026, 11, 9)), incomplete: false));
    await tester.pumpAndSettle();
    expect(scores.days.length, 2,
        reason: 'No queued days run after changing views');
    expect(browse.summaries.containsKey(DateTime(2026, 11, 9)), isFalse);
    expect(browse.calendarDays, 30);
    expect(find.text('Stop'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'late day replies cannot overwrite another month and Day loads its current date',
      (tester) async {
    tester.view.physicalSize = const Size(960, 540);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final scores = DayScores(), browse = SportsScheduleBrowseState();
    await mount(tester, scores, browse);
    scores.dayPending = Completer();
    await tester.tap(find.byKey(const ValueKey('schedule-day-2026-11-11')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('schedule-range-30')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('schedule-next')));
    await tester.pump();
    expect(browse.from, DateTime(2026, 12, 1));
    scores.dayPending!.complete(
        (games: scores.fixtures(DateTime(2026, 11, 11)), incomplete: false));
    await tester.pumpAndSettle();
    expect(browse.summaries.containsKey(DateTime(2026, 12, 1)), isFalse);
    expect(scores.days.length, 2);
    scores.dayPending = null;
    await tester.tap(find.byKey(const ValueKey('schedule-range-1')));
    await tester.pumpAndSettle();
    expect(scores.days.last, DateTime(2026, 12, 1));
    expect(scores.days.length, 3);
    expect(browse.calendarDays, 0);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('calendar exposes unknown, partial and empty days distinctly',
      (tester) async {
    tester.view.physicalSize = const Size(960, 540);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    DateTime? selected;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SportsScheduleCalendar(
                from: DateTime(2026, 11, 9),
                days: 7,
                today: DateTime(2026, 11, 10),
                selected: DateTime(2026, 11, 10),
                loading: false,
                summaries: {
                  DateTime(2026, 11, 9): SportsScheduleSummary(const {},
                      incomplete: false, at: DateTime(2026)),
                  DateTime(2026, 11, 10): SportsScheduleSummary(
                      const {'soccer': 4, 'basketball': 2},
                      incomplete: true, at: DateTime(2026)),
                },
                onSelected: (day) => selected = day))));
    await tester.pumpAndSettle();
    expect(find.text('0 fixtures'), findsOneWidget);
    expect(find.text('6 fixtures · partial'), findsOneWidget);
    expect(find.text('Open to load fixtures'), findsWidgets);
    final day = find.byKey(const ValueKey('schedule-calendar-day-2026-11-10'));
    await tester.tap(day);
    await tester.pumpAndSettle();
    expect(selected, DateTime(2026, 11, 10));
    Focus.of(tester.element(find.text('0 fixtures'))).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(selected, DateTime(2026, 11, 10),
        reason: 'Remote focus moves to the adjacent day');
    expect(tester.takeException(), isNull);
  });
}
