import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nox_iptv/widgets/sports_schedule_days.dart';

void main() {
  for (final scale in [1.0, 2.0]) {
    testWidgets(
        'month dates stay lazy and remote navigation reaches either end at scale $scale',
        (tester) async {
      final entry = FocusNode();
      final selection = ValueNotifier<DateTime?>(null);
      addTearDown(entry.dispose);
      addTearDown(selection.dispose);
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: Center(
                  child: SizedBox(
                      width: 300,
                      child: MediaQuery(
                          data: MediaQueryData(
                              textScaler: TextScaler.linear(scale)),
                          child: ValueListenableBuilder<DateTime?>(
                              valueListenable: selection,
                              builder: (_, selected, __) => SportsScheduleDays(
                                  from: DateTime(2026, 11, 1),
                                  days: 30,
                                  today: DateTime(2026, 11, 3),
                                  counts: {
                                    for (var i = 1; i <= 30; i++)
                                      DateTime(2026, 11, i): i
                                  },
                                  selected: selected,
                                  onSelected: (day) => selection.value = day,
                                  entryFocus: entry,
                                  dense: true))))))));
      await tester.pumpAndSettle();
      expect(find.byType(TextButton).evaluate().length, lessThan(9));
      entry.requestFocus();
      await tester.pump();
      for (var i = 0; i < 30; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.pump(const Duration(milliseconds: 16));
      }
      await tester.pumpAndSettle();
      expect(
          FocusManager.instance.primaryFocus?.debugLabel, 'schedule-date-30');
      expect(
          find.byKey(const ValueKey('schedule-day-2026-11-30')).hitTestable(),
          findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(selection.value, DateTime(2026, 11, 30));
      for (var i = 0; i < 30; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
        await tester.pump(const Duration(milliseconds: 16));
      }
      await tester.pumpAndSettle();
      expect(entry.hasFocus, isTrue);
      expect(find.byType(TextButton).evaluate().length, lessThan(9));
      entry.unfocus();
      await tester.pump();
      selection.value = DateTime(2026, 11, 26);
      await tester.pumpAndSettle();
      expect(
          find.byKey(const ValueKey('schedule-day-2026-11-26')).hitTestable(),
          findsOneWidget);
      expect(FocusManager.instance.primaryFocus?.debugLabel,
          isNot('schedule-date-26'));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
