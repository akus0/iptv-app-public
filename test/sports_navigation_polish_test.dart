import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nox_iptv/screens/sports_teams_screen.dart';
import 'package:nox_iptv/screens/sports_league_manager_screen.dart';
import 'package:nox_iptv/services/sports_follows.dart';
import 'package:nox_iptv/services/sports_service.dart';
import 'package:nox_iptv/widgets/sports_panel.dart';
import 'package:nox_iptv/widgets/sports_header_controls.dart';
import 'package:nox_iptv/widgets/sports_filter_picker.dart';
import 'package:nox_iptv/widgets/sports_favourite_tile.dart';
import 'package:nox_iptv/widgets/compact_choice_list.dart';
import 'sports_panel_test.dart' as harness;
import 'sports_details_panel_test.dart' show Details;
import 'sports_teams_screen_test.dart' show RecordingStandings;

Future<void> enter(WidgetTester tester, Finder finder, String text) async {
  final field = tester.widget<TextField>(finder);
  field.focusNode!.requestFocus();
  await tester.pump();
  if (field.readOnly) {
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
  }
  await tester.enterText(finder, text);
  await tester.pumpAndSettle();
}

Finder label(String value) =>
    find.byWidgetPredicate((widget) => widget is Text && widget.data == value);

void main() {
  for (final size in [const Size(390, 844), const Size(844, 390)]) {
    testWidgets(
        'favourites search keeps its input connection through keyboard resize $size',
        (tester) async {
      harness.viewport(tester, size);
      final (storage, prefs) = await harness.preferences(false);
      addTearDown(prefs.dispose);
      final follows = SportsFollows.load(storage);
      await follows.follow('eng.1', 'one', name: 'Club One');
      final standings = RecordingStandings();
      addTearDown(standings.close);
      Widget screen(double keyboard) => harness.app(
          storage,
          prefs,
          MediaQuery(
              data: MediaQueryData(
                  size: size, viewInsets: EdgeInsets.only(bottom: keyboard)),
              child: SportsTeamsScreen(
                  follows: follows,
                  favorites: true,
                  panel: true,
                  service: standings)));
      await tester.pumpWidget(screen(0));
      await tester.pumpAndSettle();
      final search = find.byKey(const ValueKey('standings-search'));
      await tester.tap(search);
      await tester.pump();
      final editable =
          tester.state<EditableTextState>(find.byType(EditableText));
      for (final inset in [80.0, 160.0, 180.0, 0.0, 180.0]) {
        await tester.pumpWidget(screen(inset));
        await tester.pump();
        expect(tester.state<EditableTextState>(find.byType(EditableText)),
            same(editable));
        expect(tester.widget<TextField>(search).focusNode!.hasFocus, isTrue);
        expect(tester.testTextInput.hasAnyClients, isTrue);
      }
      await tester.enterText(search, 'Club');
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(search).controller!.text, 'Club');
      expect(tester.takeException(), isNull);
    });
  }
  for (final television in [true, false]) {
    testWidgets('sports choice transitions follow input mode: TV=$television',
        (tester) async {
      final (storage, prefs) = await harness.preferences(television);
      addTearDown(prefs.dispose);
      String? selected;
      await tester.pumpWidget(harness.app(
          storage,
          prefs,
          Builder(
              builder: (context) => TextButton(
                  onPressed: () async {
                    selected = await showSportsChoices(context,
                        title: 'Options',
                        selected: '',
                        choices: const [SportsChoice('one', 'One', '')]);
                  },
                  child: const Text('Open')))));
      for (var i = 0; i < 12; i++) {
        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();
        final route = ModalRoute.of(tester.element(find.text('Options')))
            as TransitionRoute;
        expect(route.transitionDuration,
            television ? Duration.zero : const Duration(milliseconds: 150));
        await tester.tap(find.text('One'));
        await tester.pumpAndSettle();
        expect(selected, 'one');
        expect(find.text('Open').hitTestable(), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
    });
  }
  for (final size in [
    const Size(390, 844),
    const Size(844, 390),
    const Size(960, 540)
  ]) {
    testWidgets(
        'side favourites stays compact and browsing does not request details at $size',
        (tester) async {
      harness.viewport(tester, size);
      final (storage, prefs) = await harness.preferences(size.width == 960);
      addTearDown(prefs.dispose);
      final follows = SportsFollows.load(storage);
      for (var i = 0; i < 200; i++) {
        await follows.follow('eng.1', '$i', name: 'Club $i');
      }
      final details = Details(), standings = RecordingStandings();
      addTearDown(details.close);
      addTearDown(standings.close);
      await tester.pumpWidget(harness.app(
          storage,
          prefs,
          Builder(
              builder: (context) => TextButton(
                  onPressed: () => showSportsPanel(
                      context: context,
                      besidePreview: true,
                      builder: (_) => SportsTeamsScreen(
                          follows: follows,
                          favorites: true,
                          panel: true,
                          service: standings,
                          detailsService: details)),
                  child: const Text('Open')))));
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      final surface =
          tester.getRect(find.byKey(const ValueKey('sports-panel-surface')));
      if (size.width >= 700) {
        expect(surface.left, greaterThan(size.width * .38));
        expect(surface.width, lessThanOrEqualTo(size.width * .60));
      } else {
        expect(surface.center.dx, closeTo(size.width / 2, .1));
        expect(surface.width, greaterThan(size.width * .9));
      }
      expect(find.byType(SportsFavouriteTile).evaluate().length, lessThan(25));
      final listSearch = tester.widget<TextField>(find.byType(TextField));
      expect(listSearch.decoration!.hintText, 'Search favourites');
      await enter(tester, find.byType(TextField), 'Club 199');
      await tester.pumpAndSettle();
      expect(label('Club 199'), findsOneWidget);
      expect(find.byType(SportsFavouriteTile), findsOneWidget);
      await tester.tap(find.byTooltip('Clear search'));
      await tester.pumpAndSettle();
      final rowFocus = FocusManager.instance.rootScope.traversalDescendants
          .firstWhere((node) =>
              node.context?.findAncestorWidgetOfExactType<ListTile>()?.key ==
                  const ValueKey('eng.1|0') &&
              node.context?.findAncestorWidgetOfExactType<IconButton>() ==
                  null);
      rowFocus.requestFocus();
      await tester.pump();
      for (var i = 0; i < 60; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(details.calls, 0);
      expect(standings.loads, 0);
      expect(find.byType(SportsFavouriteTile).evaluate().length, lessThan(25));
      final close = tester
          .widget<IconButton>(find.byWidgetPredicate(
              (widget) => widget is IconButton && widget.tooltip == 'Close'))
          .onPressed!;
      close();
      close();
      await tester.pumpAndSettle();
      expect(find.text('Open').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets(
      'league sport filter keeps search and selection local and survives rapid nesting',
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
                      selected: 'l0',
                      topFirst: true,
                      options: [
                        for (var i = 0; i < 500; i++)
                          SportsFilterOption('l$i', 'League $i', Icons.sports,
                              group: i.isEven ? 'Soccer' : 'Basketball'),
                      ]);
                },
                child: const Text('Open')))));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.byType(ChoiceChip), findsNothing);
    for (var i = 0; i < 10; i++) {
      await tester.tap(find.byKey(const ValueKey('sports-picker-group')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(i.isEven ? 'Soccer' : 'All sports').last);
      await tester.pumpAndSettle();
      final options = tester
          .widget<CompactChoiceList>(find.byType(CompactChoiceList))
          .choices;
      expect(options.length, i.isEven ? 250 : 500);
    }
    await enter(tester, find.byType(TextField), 'League 499');
    await tester.pumpAndSettle();
    await tester.tap(label('League 499'));
    await tester.pumpAndSettle();
    expect(selected, 'l499');
    expect(tester.takeException(), isNull);
  });
  for (final size in [
    const Size(390, 844),
    const Size(844, 390),
    const Size(960, 540)
  ]) {
    testWidgets(
        'league management filters locally, saves in place and clears at $size',
        (tester) async {
      harness.viewport(tester, size);
      final (storage, prefs) = await harness.preferences(size.width == 960);
      addTearDown(prefs.dispose);
      await tester.pumpWidget(harness.app(
          storage, prefs, const SportsLeagueManagerScreen(embedded: true)));
      await tester.pumpAndSettle();
      final before = savedSportsLeagues(storage).map((l) => l.id).toSet();
      await enter(tester, find.byKey(const ValueKey('league-manager-search')),
          'EFL Championship');
      await tester.pumpAndSettle();
      expect(savedSportsLeagues(storage).map((l) => l.id).toSet(), before);
      await tester.tap(label('EFL Championship'));
      await tester.pumpAndSettle();
      expect(savedSportsLeagues(storage).any((l) => l.id == 'eng.2'), isTrue);
      expect(label('EFL Championship'), findsOneWidget);
      await tester.tap(find.byTooltip('Clear search'));
      await tester.pumpAndSettle();
      expect(savedSportsLeagues(storage).any((l) => l.id == 'eng.2'), isTrue);
      expect(tester.takeException(), isNull);
    });
  }
}
