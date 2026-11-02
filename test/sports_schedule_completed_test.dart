import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:nox_iptv/models/sports.dart';
import 'package:nox_iptv/services/app_preferences.dart';
import 'package:nox_iptv/services/storage_service.dart';
import 'package:nox_iptv/widgets/compact_choice_list.dart';
import 'package:nox_iptv/widgets/sports_filter_picker.dart';
import 'package:nox_iptv/widgets/sports_schedule_days.dart';
import 'package:nox_iptv/widgets/sports_schedule_panel.dart';
import 'sports_schedule_panel_test.dart' as fixtures;

class MixedScores extends fixtures.DayScores {
  bool allCompleted = false;
  @override
  List<SportsGame> fixtures(DateTime day, [int count = 48]) => [
        for (var i = 0; i < count; i++)
          SportsGame(
              id: '$i',
              league: sportsLeagueById('eng.1')!,
              start: day.add(Duration(hours: i)),
              state: allCompleted || i < 10 || i == 11
                  ? GameState.post
                  : i == 10
                      ? GameState.live
                      : GameState.pre,
              statusText: !allCompleted && i == 11
                  ? 'Postponed'
                  : i < 10
                      ? 'Final'
                      : 'Scheduled',
              home: const SportsTeam(
                  id: 'h', name: 'Home', shortName: 'Home', abbreviation: 'H'),
              away: const SportsTeam(
                  id: 'a', name: 'Away', shortName: 'Away', abbreviation: 'A'))
      ];
  @override
  Future<({List<SportsGame> games, bool incomplete})> scheduleGames(
      SportsLeague league, DateTime from, DateTime through,
      {bool Function()? shouldContinue}) async {
    calls++;
    return (games: fixtures(from), incomplete: false);
  }
}

void main() {
  test('schedule sport picker omits badges without changing Events', () {
    final leagues = [sportsLeagueById('eng.1')!];
    final counts = {'soccer': (live: 3, upcoming: 7)};
    final events = sportsSportOptions(leagues, counts).last;
    final schedule =
        sportsSportOptions(leagues, counts, showCounts: false).last;
    expect(events.live, 3);
    expect(events.upcoming, 7);
    expect(schedule.live, isNull);
    expect(schedule.upcoming, isNull);
  });
  for (final overview in [false, true]) {
    testWidgets(
        'completed filter, current time and day tracking (overview $overview)',
        (tester) async {
      tester.view.physicalSize = const Size(960, 540);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({});
      final storage = StorageService();
      await storage.init();
      final prefs = AppPreferences(storage);
      await prefs.init();
      prefs.isTelevision = true;
      addTearDown(prefs.dispose);
      final entry = FocusNode();
      addTearDown(entry.dispose);
      final browse = SportsScheduleBrowseState();
      final scores = MixedScores();
      await tester.pumpWidget(ChangeNotifierProvider.value(
          value: prefs,
          child: MaterialApp(
              home: Scaffold(
                  body: SportsSchedulePanel(
            service: scores,
            browseState: browse,
            entryFocus: entry,
            initialLeague: sportsLeagueById('eng.1'),
            overviewLeagues: overview ? [sportsLeagueById('eng.1')!] : null,
            clock: () => DateTime(2026, 11, 3, 12, 30),
            onFocusToolbar: () {},
            layoutBuilder: (filters, actions, content) => Column(children: [
              SizedBox(
                  height: 48,
                  child: Row(children: [Expanded(child: filters), actions])),
              Expanded(child: content)
            ]),
          )))));
      await tester.pumpAndSettle();
      CompactChoiceList list() => tester.widget(find.byType(CompactChoiceList));
      CompactChoiceListState state() =>
          tester.state(find.byType(CompactChoiceList));
      expect(browse.showCompleted, isFalse);
      expect(list().choices.length, 38);
      expect(list().choices.first.id, 'eng.1:10');
      expect(list().choices.any((c) => c.id == 'eng.1:11'), isTrue,
          reason: 'Postponed games are not finished games');
      expect(list().choices.where((c) => c.markerBefore != null).single.id,
          'eng.1:13');
      entry.requestFocus();
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('schedule-completed')));
      await tester.pumpAndSettle();
      expect(browse.showCompleted, isTrue);
      expect(list().choices.length, 48);
      expect(state().firstVisibleIndex, 10);
      expect(find.textContaining('Now ·'), findsOneWidget);
      expect(scores.calls + scores.days.length, 1);
      if (overview) {
        await tester.tap(find.byKey(const ValueKey('schedule-order')));
        await tester.pumpAndSettle();
        expect(list().choices.every((c) => c.markerBefore == null), isTrue);
        expect(list().trailingMarker, isNull);
      } else {
        state().revealIndex(28);
        await tester.pumpAndSettle();
        expect(
            tester
                .widget<SportsScheduleDays>(find.byType(SportsScheduleDays))
                .selected,
            DateTime(2026, 11, 4));
        expect(browse.selectedDay, isNull,
            reason: 'Following the viewport must not filter the loaded list');
        expect(list().choices.length, 48);
        state().revealIndex(3, requestFocus: true);
        await tester.pumpAndSettle();
        expect(
            tester
                .widget<SportsScheduleDays>(find.byType(SportsScheduleDays))
                .selected,
            DateTime(2026, 11, 3));
      }
      expect(scores.calls + scores.days.length, 1);
      if (overview) {
        scores.allCompleted = true;
        await tester.tap(find.byKey(const ValueKey('schedule-completed')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('schedule-day-2026-11-04')));
        await tester.pumpAndSettle();
        expect(find.byType(CompactChoiceList), findsNothing);
        await tester.tap(find.text('Show all fixtures'));
        await tester.pumpAndSettle();
        expect(list().choices, hasLength(48));
        expect(browse.showCompleted, isTrue);
        expect(scores.days, hasLength(2));
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
