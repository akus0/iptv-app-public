import 'package:nox_iptv/models/sports_favourites_filter.dart';
import 'package:nox_iptv/utils/sports_channel_filter.dart';
import 'package:nox_iptv/widgets/sports_event_controls.dart';
import 'package:nox_iptv/utils/sports_time_filter.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nox_iptv/widgets/sports_header_controls.dart';
import 'package:nox_iptv/widgets/sports_filter_picker.dart';
import 'package:nox_iptv/widgets/compact_choice_list.dart';
import 'package:provider/provider.dart';
import 'sports_panel_test.dart' as harness;

void main() {
  for (final size in [
    const Size(320, 568),
    const Size(844, 390),
    const Size(960, 540)
  ]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('Result scope has explicit choices at $size / $scale',
          (tester) async {
        harness.viewport(tester, size);
        final tv = size == const Size(960, 540);
        final (storage, prefs) = await harness.preferences(tv);
        addTearDown(prefs.dispose);
        final focus = FocusNode();
        addTearDown(focus.dispose);
        var filter = SportsFavouritesFilter.favourites;
        await tester.pumpWidget(ChangeNotifierProvider.value(
            value: prefs,
            child: MaterialApp(
                builder: (context, child) => MediaQuery(
                    data: MediaQuery.of(context)
                        .copyWith(textScaler: TextScaler.linear(scale)),
                    child: child!),
                home: Scaffold(
                    body: StatefulBuilder(
                        builder: (context, update) => Center(
                            child: SportsFavouritesFilterButton(
                                focusNode: focus,
                                filter: filter,
                                favouriteLeagueCount: 2,
                                favouriteTeamCount: 3,
                                onChanged: (value) =>
                                    update(() => filter = value))))))));
        expect(find.text('Show'), findsOneWidget);
        expect(find.byIcon(Icons.keyboard_arrow_down_rounded), findsOneWidget);
        if (tv) {
          focus.requestFocus();
          await tester.pump();
          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        } else {
          await tester.tap(find.byType(SportsFavouritesFilterButton));
        }
        await tester.pumpAndSettle();
        expect(filter, SportsFavouritesFilter.favourites,
            reason: 'Opening the menu does not change results');
        expect(
            find.text('2 saved · includes the whole league'), findsOneWidget);
        expect(
            find.text('3 saved · only these teams & athletes, in any league'),
            findsOneWidget);
        expect(
            tester
                .widget<ListTile>(
                    find.byKey(const ValueKey('sports-favourites-favourites')))
                .selected,
            true);
        if (tv) {
          await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        } else {
          await tester.tap(find.byKey(const ValueKey('sports-favourites-all')));
        }
        await tester.pumpAndSettle();
        expect(filter, SportsFavouritesFilter.all);
        expect(find.byType(Dialog), findsNothing);
        if (tv) {
          expect(focus.hasFocus, true,
              reason: 'Closing the choices returns to the originating control');
        }
        // Every scope is a single, mutually exclusive choice, with no save step.
        for (final next in [
          SportsFavouritesFilter.leagues,
          SportsFavouritesFilter.teams,
          SportsFavouritesFilter.favourites
        ]) {
          await tester.tap(find.byType(SportsFavouritesFilterButton));
          await tester.pumpAndSettle();
          final choice = find.byKey(ValueKey('sports-favourites-${next.name}'));
          await tester.ensureVisible(choice);
          await tester.tap(choice);
          await tester.pumpAndSettle();
          expect(filter, next);
          expect(find.byTooltip('Show: ${next.label} · change result filter'),
              findsOneWidget);
          expect(find.byType(Dialog), findsNothing);
        }
        await tester.tap(find.byType(SportsFavouritesFilterButton));
        await tester.pumpAndSettle();
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(filter, SportsFavouritesFilter.favourites,
            reason: 'Cancelling preserves the current choice');
        expect(tester.takeException(), isNull);
        expect(storage.getSportsLeagues(), ['nhl']);
      });
    }
  }
  testWidgets(
      'queued activations and reselection never stack menus or change scope',
      (tester) async {
    harness.viewport(tester, const Size(960, 540));
    final (storage, prefs) = await harness.preferences(true);
    addTearDown(prefs.dispose);
    var changes = 0;
    await tester.pumpWidget(harness.app(
        storage,
        prefs,
        Center(
            child: SportsFavouritesFilterButton(
          filter: SportsFavouritesFilter.teams,
          favouriteLeagueCount: 0,
          favouriteTeamCount: 0,
          onChanged: (_) => changes++,
        ))));
    final activate = tester
        .widget<TextButton>(find.descendant(
            of: find.byType(SportsFavouritesFilterButton),
            matching: find.byType(TextButton)))
        .onPressed!;
    for (var n = 0; n < 12; n++) {
      activate();
    }
    await tester.pumpAndSettle();
    expect(find.byType(SimpleDialog), findsOneWidget);
    expect(find.text('No favourite teams or athletes yet'), findsOneWidget);
    expect(find.text('No favourite leagues yet'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('sports-favourites-teams')));
    await tester.pumpAndSettle();
    expect(changes, 0, reason: 'Reselecting the active scope is a no-op');
    expect(find.byType(SimpleDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });
  for (final size in [const Size(320, 568), const Size(844, 390)]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('scope picker stays compact and searchable at $size / $scale',
          (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final (_, prefs) = await harness.preferences(false);
        addTearDown(prefs.dispose);
        String? selected;
        await tester.pumpWidget(ChangeNotifierProvider.value(
            value: prefs,
            child: MaterialApp(
                builder: (context, child) => MediaQuery(
                    data: MediaQuery.of(context)
                        .copyWith(textScaler: TextScaler.linear(scale)),
                    child: child!),
                home: Scaffold(
                    body: Builder(
                        builder: (context) => TextButton(
                            onPressed: () async {
                              selected = await showSportsFilterPicker(context,
                                  title: 'Choose league',
                                  itemLabel: 'leagues',
                                  description:
                                      'Shared filters · enabled leagues only',
                                  selected: '',
                                  options: [
                                    const SportsFilterOption('',
                                        'All favourite leagues', Icons.public),
                                    const SportsFilterOption(
                                        '__manage_leagues__',
                                        'Manage favourite leagues',
                                        Icons.tune,
                                        description:
                                            '100 favourites · Events & Schedule'),
                                    for (var i = 0; i < 100; i++)
                                      SportsFilterOption(
                                          '$i', 'League $i', Icons.sports,
                                          searchTerms:
                                              i == 99 ? 'Australia' : ''),
                                  ]);
                            },
                            child: const Text('Open')))))));
        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: 'Opening the picker');
        if (scale == 1) {
          expect(find.text('Shared filters · enabled leagues only'),
              findsOneWidget);
        }
        expect(find.byType(CompactChoiceList), findsOneWidget);
        if (scale == 1) {
          expect(find.text('100 leagues'), findsOneWidget);
        }
        final manage = find.byKey(const ValueKey('__manage_leagues__'));
        expect(manage.hitTestable(), findsOneWidget);
        expect(
            tester
                .widget<CompactChoiceList>(find.byType(CompactChoiceList))
                .choices
                .any((c) => c.id == '__manage_leagues__'),
            isFalse);
        await tester.enterText(find.byType(TextField), 'nothing matches xyz');
        await tester.pumpAndSettle();
        expect(find.text('No matches'), findsOneWidget);
        expect(manage.hitTestable(), findsOneWidget);
        await tester.tap(find.widgetWithText(TextButton, 'Clear search'));
        await tester.pumpAndSettle();
        expect(
            tester
                .widget<TextField>(find.byType(TextField))
                .focusNode!
                .hasFocus,
            isTrue);
        await tester.enterText(find.byType(TextField), 'Australia');
        await tester.pumpAndSettle();
        expect(
            tester
                .widget<CompactChoiceList>(find.byType(CompactChoiceList))
                .choices
                .single
                .id,
            '99');
        final editable =
            tester.state<EditableTextState>(find.byType(EditableText));
        tester.view.viewInsets =
            FakeViewPadding(bottom: size.width > size.height ? 180 : 240);
        await tester.pumpAndSettle();
        expect(tester.state<EditableTextState>(find.byType(EditableText)),
            same(editable));
        expect(tester.testTextInput.hasAnyClients, isTrue);
        expect(selected, isNull);
        expect(tester.takeException(), isNull);
        tester.view.resetViewInsets();
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: 'Closing the keyboard');
        await tester.tap(find.byKey(const ValueKey('99')));
        await tester.pumpAndSettle();
        expect(selected, '99');
      });
    }
  }

  testWidgets(
      'league management stays separate from results and has a direct remote return path',
      (tester) async {
    harness.viewport(tester, const Size(960, 540));
    final (storage, prefs) = await harness.preferences(true);
    addTearDown(prefs.dispose);
    String? selected;
    await tester.pumpWidget(harness.app(
        storage,
        prefs,
        Builder(
            builder: (context) => TextButton(
                onPressed: () async {
                  selected = await showSportsFilterPicker(context,
                      title: 'Choose league',
                      itemLabel: 'leagues',
                      selected: '125',
                      options: [
                        const SportsFilterOption('__manage_leagues__',
                            'Manage favourite leagues', Icons.tune),
                        for (var i = 0; i < 500; i++)
                          SportsFilterOption('$i', 'League $i', Icons.sports,
                              group: i.isEven ? 'Soccer' : 'Basketball'),
                      ]);
                },
                child: const Text('Open')))));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'choice-125');
    expect(find.text('Left'), findsOneWidget,
        reason: 'The shortcut to the pinned action is visible on TV.');
    final results =
        tester.widget<CompactChoiceList>(find.byType(CompactChoiceList));
    expect(results.choices, hasLength(500));
    expect(
        find
            .byWidgetPredicate(
                (w) => w is Text && (w.data?.startsWith('League ') ?? false))
            .evaluate()
            .length,
        lessThan(30),
        reason: 'Large catalogues only mount visible results.');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    expect(
        FocusManager.instance.primaryFocus?.debugLabel, 'sports-picker-manage');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'choice-125');
    await tester.sendKeyEvent(LogicalKeyboardKey.end);
    await tester.pumpAndSettle();
    final lastResult = FocusManager.instance.primaryFocus?.debugLabel;
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(
        FocusManager.instance.primaryFocus?.debugLabel, 'sports-picker-manage',
        reason: 'Normal Down navigation also reaches the pinned footer.');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus?.debugLabel, lastResult);
    await tester.sendKeyEvent(LogicalKeyboardKey.home);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    expect(
        FocusManager.instance.primaryFocus?.debugLabel, 'sports-picker-group',
        reason: 'Up from results reaches the controls immediately above.');
    await tester.tap(find.byType(TextField));
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'no matching league xyz');
    await tester.pumpAndSettle();
    expect(find.text('No matches'), findsOneWidget);
    final manage = find.byKey(const ValueKey('__manage_leagues__'));
    expect(manage.hitTestable(), findsOneWidget);
    await tester.tap(manage);
    await tester.pumpAndSettle();
    expect(selected, '__manage_leagues__');
    expect(storage.getSportsLeagues(), ['nhl']);
    expect(tester.takeException(), isNull);
  });

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
