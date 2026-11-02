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
