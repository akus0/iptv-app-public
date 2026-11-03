import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:nox_iptv/models/channel.dart';
import 'package:nox_iptv/models/sports.dart';
import 'package:nox_iptv/services/app_preferences.dart';
import 'package:nox_iptv/services/sports_channel_matcher.dart';
import 'package:nox_iptv/services/storage_service.dart';
import 'package:nox_iptv/widgets/compact_choice_list.dart';
import 'package:nox_iptv/widgets/sports_schedule_panel.dart';
import 'sports_schedule_panel_test.dart' as fixtures;

void main() {
  for (final tv in [true, false]) {
    testWidgets(
        'Schedule reuses cached channels lazily and keeps details ($tv)',
        (tester) async {
      tester.view.physicalSize =
          tv ? const Size(960, 540) : const Size(320, 800);
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
      final scores = fixtures.DayScores();
      Channel channel(String id) => Channel(
          id: 'p::$id',
          rawId: id,
          playlistId: 'p',
          name: 'Sports $id',
          group: 'Sport',
          url: '');
      final original = ChannelMatch(channel('one'), MatchReason.guide, 900);
      final other = ChannelMatch(channel('two'), MatchReason.league, 300);
      final matches = <String, ChannelMatch>{'nba:0': original};
      final played = <ChannelMatch>[];
      final details = <SportsGame>[];
      var lookups = 0;
      late StateSetter update;
      await tester.pumpWidget(ChangeNotifierProvider.value(
          value: prefs,
          child:
              MaterialApp(home: StatefulBuilder(builder: (context, setState) {
            update = setState;
            return Scaffold(
                body: SportsSchedulePanel(
                    service: scores,
                    browseState: browse,
                    entryFocus: entry,
                    initialLeague: sportsLeagueById('nba'),
                    overviewLeagues: [
                      sportsLeagueById('nba')!,
                      sportsLeagueById('eng.1')!
                    ],
                    clock: () => DateTime(2026, 11, 3, 12),
                    channelMatchForGame: (game) {
                      lookups++;
                      return matches[SportsChannelPicks.eventKey(game)];
                    },
                    onWatchGame: (_, match) => played.add(match),
                    onGameDetails: details.add,
                    onFocusToolbar: () {},
                    layoutBuilder: (filters, actions, content) =>
                        Column(children: [
                          SizedBox(
                              height: 48,
                              child: Row(children: [
                                Expanded(child: filters),
                                actions
                              ])),
                          Expanded(child: content)
                        ])));
          }))));
      await tester.pumpAndSettle();
      expect(find.text('Sports one'), findsOneWidget);
      expect(lookups, lessThan(40),
          reason: 'Only mounted rows read matches, not all 1,000 fixtures');
      expect(
          tester
              .widget<CompactChoiceList>(find.byType(CompactChoiceList))
              .choices,
          hasLength(1000));
      final calls = scores.days.length;
      final row = find.byKey(const ValueKey('nba:0'));
      final focus = tester.widget<InkWell>(row).focusNode!;
      final rowHeight = tester.getSize(row).height;
      focus.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pump();
      expect(played, [same(original)]);
      expect(details, isEmpty);
      await tester.tap(find.byKey(const ValueKey('fixture-details-nba:0')));
      await tester.pump();
      expect(details, hasLength(1));
      expect(played, hasLength(1));
      focus.requestFocus();
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.select);
      await tester.pump(const Duration(milliseconds: 600));
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.select);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.select);
      await tester.pump();
      expect(details, hasLength(2));
      expect(played, hasLength(1),
          reason: 'Holding for details must never start playback');
      update(() => matches['nba:0'] = other);
      await tester.pumpAndSettle();
      expect(find.text('Possible · Sports two'), findsOneWidget);
      expect(focus.hasFocus, isTrue);
      expect(tester.getSize(row).height, rowHeight);
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pump();
      expect(played.last, same(other));
      // Read the current cache at activation, even before another render.
      matches.clear();
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pump();
      expect(played, hasLength(2));
      expect(details, hasLength(3));
      update(() {});
      await tester.pumpAndSettle();
      expect(find.textContaining('Sports two'), findsNothing);
      expect(tester.getSize(row).height, rowHeight);
      expect(scores.days.length, calls,
          reason:
              'Reading or launching a cached match never refetches the schedule');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
