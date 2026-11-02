import 'package:nox_iptv/utils/sports_channel_filter.dart';
import 'package:nox_iptv/widgets/sports_event_controls.dart';
import 'package:nox_iptv/utils/sports_time_filter.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nox_iptv/widgets/sports_header_controls.dart';

void main() {
  testWidgets(
      'compact filter panel applies choices directly without loading on open or cancel',
      (tester) async {
    var time = SportsTimeFilter.all;
    var channels = SportsChannelFilter.all;
    var changes = 0;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: Builder(
                builder: (context) => TextButton(
                    onPressed: () => showSportsEventFilters(context,
                            time: time, channels: channels, onTime: (value) {
                          time = value;
                          changes++;
                        }, onChannels: (value) {
                          channels = value;
                          changes++;
                        }),
                    child: const Text('Filters'))))));
    await tester.tap(find.text('Filters'));
    await tester.pumpAndSettle();
    expect(changes, 0);
    await tester.tap(find.byKey(const ValueKey('time-filter-liveAndSoon')));
    await tester.pump();
    expect(time, SportsTimeFilter.liveAndSoon);
    await tester.tap(find.byKey(const ValueKey('channel-filter-possible')));
    await tester.pump();
    expect(channels, SportsChannelFilter.possible);
    expect(changes, 2);
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Filters'));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(changes, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'shared filters grow at 2x text while preserving focus and compact defaults',
      (tester) async {
    final sport = FocusNode(), league = FocusNode();
    addTearDown(sport.dispose);
    addTearDown(league.dispose);
    addTearDown(tester.view.reset);
    var selected = 0;
    for (final size in [const Size(320, 568), const Size(960, 540)]) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      for (final scale in [1.0, 2.0]) {
        await tester.pumpWidget(MaterialApp(
            home: MediaQuery(
                data: MediaQueryData(
                    size: size, textScaler: TextScaler.linear(scale)),
                child: Scaffold(
                    body: Builder(
                        builder: (context) => Align(
                            alignment: Alignment.topCenter,
                            child: SizedBox(
                                height: sportsFilterHeight(context),
                                child: Row(children: [
                                  Expanded(
                                      child: SportsFilterButton(
                                          caption: 'Sport',
                                          value: 'Football / Soccer',
                                          focusNode: sport,
                                          onTap: () {})),
                                  const SizedBox(width: 6),
                                  Expanded(
                                      child: SportsFilterButton(
                                          caption: 'League',
                                          value: 'UEFA Champions League',
                                          focusNode: league,
                                          onTap: () => selected++)),
                                ]))))))));
        await tester.pump();
        final height =
            tester.getSize(find.byType(SportsFilterButton).first).height;
        if (scale == 1) {
          expect(height, size.width < 600 ? 32 : 34);
        } else {
          expect(height, greaterThanOrEqualTo(54));
        }
        expect(tester.takeException(), isNull);
        sport.requestFocus();
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        expect(league.hasFocus, isTrue);
        final before = selected;
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pump();
        expect(selected, before + 1);
        expect(tester.takeException(), isNull);
      }
    }
    await tester.pumpWidget(const SizedBox());
  });
}
