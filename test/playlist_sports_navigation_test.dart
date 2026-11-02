import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:nox_iptv/models/playlist_profile.dart';
import 'package:nox_iptv/models/sports.dart';
import 'package:nox_iptv/models/sports_details.dart';
import 'package:nox_iptv/widgets/sports_panel.dart';
import 'package:nox_iptv/widgets/tv_menu_tile.dart';
import 'package:nox_iptv/screens/catalog_sync_screen.dart';
import 'package:nox_iptv/screens/settings/playlist_manager_screen.dart';
import 'package:nox_iptv/screens/sports_teams_screen.dart';
import 'package:nox_iptv/services/app_preferences.dart';
import 'package:nox_iptv/services/catalog_database.dart';
import 'package:nox_iptv/services/playlist_manager.dart';
import 'package:nox_iptv/services/sports_follows.dart';
import 'package:nox_iptv/services/sports_standings_service.dart';
import 'package:nox_iptv/services/storage_service.dart';
import 'package:nox_iptv/widgets/sports_details_panel.dart';
import 'sports_details_panel_test.dart' show Details;
import 'sports_teams_screen_test.dart' show RecordingStandings;

class RefreshPlaylists extends PlaylistManager {
  RefreshPlaylists(super.storage, super.catalogDb);
  final updates = <String?>[];
  final m3u = <String>[];
  Completer<void>? pending;
  bool fail = false;
  @override
  List<PlaylistProfile> get profiles => [
        for (final id in ['one', 'two'])
          PlaylistProfile(
              id: id,
              name: 'Playlist $id',
              mode: 'xtream',
              xtreamServer: 'https://provider.example.test',
              sortOrder: 0,
              createdAt: DateTime(2026)),
        PlaylistProfile(
            id: 'm3u',
            name: 'M3U',
            mode: 'm3u',
            sortOrder: 2,
            createdAt: DateTime(2026),
            m3uUrl: 'https://provider.example.test/list'),
      ];
  @override
  Future<void> runFullCatalogSync({String? playlistId}) async {
    updates.add(playlistId);
    if (pending != null) await pending!.future;
    if (fail) throw StateError("Fixture refresh failure");
  }

  @override
  Future<void> loadPlaylist(String playlistId) async => m3u.add(playlistId);
}

class PendingDetails extends Details {
  final requests = <String>[];
  final first = Completer<SportsDetails>();
  @override
  Future<SportsDetails> team(SportsLeague league, SportsTeam team,
      {bool refresh = false}) {
    requests.add(team.id);
    return requests.length == 1 ? first.future : Future.value(result);
  }
}

class MutableStandings extends SportsStandingsService {
  LeagueStandings data = const LeagueStandings(failed: true);
  final refreshes = <bool>[];
  @override
  Future<LeagueStandings> load(SportsLeague league,
      {bool refresh = false, bool rememberSelection = true}) async {
    refreshes.add(refresh);
    return data;
  }
}

class DirectoryStandings extends RecordingStandings {
  DirectoryStandings()
      : super(
            data: const LeagueStandings(tables: [
          StandingTable('Table', [
            StandingTeam(
                SportsTeam(
                    id: '1',
                    name: 'Current Club',
                    shortName: 'Club',
                    abbreviation: 'FC'),
                {},
                1)
          ])
        ]));
  int directoryCalls = 0;
  @override
  Future<LeagueStandings> teamDirectory(SportsLeague league,
      {bool refresh = false}) async {
    directoryCalls++;
    return const LeagueStandings(directory: true, tables: [
      StandingTable('Teams', [
        StandingTeam(
            SportsTeam(
                id: '2',
                name: 'Former Club',
                shortName: 'Club',
                abbreviation: 'FC'),
            {},
            null)
      ])
    ]);
  }
}

void main() {
  late StorageService storage;
  late AppPreferences prefs;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    storage = StorageService();
    await storage.init();
    prefs = AppPreferences(storage);
    await prefs.init();
    prefs.isTelevision = true;
  });
  tearDown(() => prefs.dispose());

  Future<void> open(WidgetTester tester, Widget child,
      {PlaylistManager? playlist,
      Size size = const Size(960, 540),
      double scale = 1}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MultiProvider(
        providers: [
          Provider<StorageService>.value(value: storage),
          ChangeNotifierProvider.value(value: prefs),
          if (playlist != null)
            ChangeNotifierProvider<PlaylistManager>.value(value: playlist),
        ],
        child: MaterialApp(
            builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: TextScaler.linear(scale)),
                child: child!),
            home: child)));
    await tester.pumpAndSettle();
  }

  FocusNode rowFocus(String key) =>
      FocusManager.instance.rootScope.traversalDescendants.firstWhere((n) =>
          n.context?.findAncestorWidgetOfExactType<IconButton>() == null &&
          n.context?.findAncestorWidgetOfExactType<ListTile>()?.key ==
              ValueKey(key));

  testWidgets(
      'legacy favourite identities resolve once per league and persist in original order',
      (tester) async {
    final follows = SportsFollows.load(storage);
    await follows.follow('eng.1', '2');
    await follows.follow('eng.1', '1');
    final service = RecordingStandings(
        data: LeagueStandings(tables: [
      StandingTable('Table', [
        for (final id in ['1', '2'])
          StandingTeam(
              SportsTeam(
                  id: id,
                  name: 'Resolved $id',
                  shortName: 'Club',
                  abbreviation: 'FC'),
              {'points': '12'},
              1)
      ])
    ]));
    addTearDown(service.close);
    await open(tester,
        SportsTeamsScreen(follows: follows, favorites: true, service: service));
    expect(service.loads, 1);
    expect(find.text('Resolved 2'), findsOneWidget);
    expect(find.text('Team 2'), findsNothing);
    final restored = SportsFollows.load(storage);
    expect(restored.teams.map((t) => t.teamId), ['2', '1']);
    expect(restored.nameOf(restored.teams.first), 'Resolved 2');
    await tester.pumpWidget(const SizedBox());
    await open(
        tester,
        SportsTeamsScreen(
            follows: restored, favorites: true, service: service));
    expect(service.loads, 1);
  });

  testWidgets(
      'favourites outside current standings recover from the league directory without inventing a rank',
      (tester) async {
    final follows = SportsFollows.load(storage);
    await follows.follow('eng.1', '2');
    final service = DirectoryStandings();
    addTearDown(service.close);
    final details = Details();
    addTearDown(details.close);
    await open(
        tester,
        SportsTeamsScreen(
            follows: follows,
            favorites: true,
            service: service,
            detailsService: details));
    expect(service.loads, 1);
    expect(service.directoryCalls, 1);
    expect(find.text('Former Club'), findsOneWidget);
    await tester.tap(find.text('Former Club'));
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<SportsDetailsPanel>(find.byType(SportsDetailsPanel))
            .standing!
            .position,
        isNull);
    expect(follows.teams.single.teamId, '2');
  });

  testWidgets(
      'failed legacy name recovery retries explicitly without removing saved favourites',
      (tester) async {
    final follows = SportsFollows.load(storage);
    await follows.follow('eng.1', '1');
    final service = MutableStandings();
    addTearDown(service.close);
    await open(tester,
        SportsTeamsScreen(follows: follows, favorites: true, service: service));
    expect(find.text('Team 1'), findsOneWidget);
    expect(follows.teams.length, 1);
    service.data = const LeagueStandings(tables: [
      StandingTable('Table', [
        StandingTeam(
            SportsTeam(
                id: '1',
                name: 'Recovered Club',
                shortName: 'Club',
                abbreviation: 'FC'),
            {},
            null)
      ])
    ]);
    await tester.tap(find.byTooltip('Retry team names'));
    await tester.pumpAndSettle();
    expect(service.refreshes, [false, true]);
    expect(find.text('Recovered Club'), findsOneWidget);
    expect(find.byTooltip('Retry team names'), findsNothing);
    expect(follows.teams.length, 1);
  });

  for (final size in [
    const Size(320, 640),
    const Size(844, 390),
    const Size(960, 540)
  ]) {
    testWidgets('favourites and details fit enlarged text at $size',
        (tester) async {
      prefs.isTelevision = size.width >= 960;
      final follows = SportsFollows.load(storage);
      await follows.follow('eng.1', '1', name: 'A long favourite club name');
      final details = Details();
      addTearDown(details.close);
      await open(
          tester,
          SportsTeamsScreen(
              follows: follows, favorites: true, detailsService: details),
          size: size,
          scale: 1.6);
      await tester.tap(find.text('A long favourite club name'));
      await tester.pumpAndSettle();
      expect(find.byType(SportsDetailsPanel), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
      'remote favourites show details on left after settling, never the add league pane',
      (tester) async {
    final follows = SportsFollows.load(storage);
    for (final id in ['1', '2']) {
      await follows.follow('eng.1', id, name: 'Saved $id');
    }
    final details = Details();
    addTearDown(details.close);
    await open(
        tester,
        SportsTeamsScreen(
            follows: follows, favorites: true, detailsService: details));
    rowFocus('eng.1|1').requestFocus();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    rowFocus('eng.1|2').requestFocus();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(details.calls, 0);
    await tester.pump(const Duration(milliseconds: 160));
    await tester.pumpAndSettle();
    expect(details.calls, 1);
    final panel =
        tester.widget<SportsDetailsPanel>(find.byType(SportsDetailsPanel));
    expect(panel.team!.id, '2');
    expect(panel.embedded, true);
    expect(tester.getTopLeft(find.byType(SportsDetailsPanel)).dx,
        lessThan(tester.getTopLeft(find.byKey(const ValueKey('eng.1|2'))).dx));
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(find.byType(SportsTeamsScreen), findsOneWidget);
    expect(details.calls, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'slow favourite details coalesce remote movement to the latest team',
      (tester) async {
    final follows = SportsFollows.load(storage);
    for (final id in ['1', '2', '3']) {
      await follows.follow('eng.1', id, name: 'Saved $id');
    }
    final details = PendingDetails();
    addTearDown(details.close);
    await open(
        tester,
        SportsTeamsScreen(
            follows: follows, favorites: true, detailsService: details));
    for (final id in ['1', '2', '3']) {
      rowFocus('eng.1|$id').requestFocus();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
    }
    expect(details.requests, ['1']);
    details.first.complete(details.result);
    await tester.pumpAndSettle();
    expect(details.requests, ['1', '3']);
    expect(
        tester
            .widget<SportsDetailsPanel>(find.byType(SportsDetailsPanel))
            .team!
            .id,
        '3');
    expect(tester.takeException(), isNull);
  });

  testWidgets('favourite selection retains search, list and scroll position',
      (tester) async {
    final follows = SportsFollows.load(storage);
    for (var i = 1; i <= 200; i++) {
      await follows.follow('eng.1', '$i', name: 'Saved club $i');
    }
    final details = Details();
    addTearDown(details.close);
    await open(
        tester,
        SportsTeamsScreen(
            follows: follows, favorites: true, detailsService: details));
    final search = tester.widget<TextField>(find.byType(TextField));
    final listFinder =
        find.byWidgetPredicate((w) => w is ListView && w.controller != null);
    final list = tester.widget<ListView>(listFinder);
    list.controller!.jumpTo(1500);
    await tester.pumpAndSettle();
    final offset = list.controller!.offset;
    final row = find.byType(ListTile).hitTestable().first;
    await tester.tap(row);
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byType(TextField)), same(search),
        reason: 'Selection must not rebuild or refilter the list');
    expect(tester.widget<ListView>(listFinder), same(list));
    expect(list.controller!.offset, offset);
    expect(find.byType(ListTile).evaluate().length, lessThan(30),
        reason: 'Only rows near the viewport should be mounted');
    expect(find.byType(SportsDetailsPanel), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('rapid remote scrolling stays in favourites while details load',
      (tester) async {
    final follows = SportsFollows.load(storage);
    for (var i = 1; i <= 200; i++) {
      await follows.follow('eng.1', '$i', name: 'Saved club $i');
    }
    final details = PendingDetails();
    addTearDown(details.close);
    await open(
        tester,
        SportsTeamsScreen(
            follows: follows, favorites: true, detailsService: details));
    rowFocus('eng.1|1').requestFocus();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 260));
    expect(details.requests, ['1']);
    for (var i = 0; i < 35; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump(const Duration(milliseconds: 30));
    }
    final focused = FocusManager.instance.primaryFocus!.context!
        .findAncestorWidgetOfExactType<ListTile>();
    expect(focused?.key, const ValueKey('eng.1|36'));
    expect(
        find.byKey(const ValueKey('eng.1|36')).hitTestable(), findsOneWidget);
    expect(find.byType(ListTile).evaluate().length, lessThan(30));
    await tester.pump(const Duration(milliseconds: 260));
    expect(details.requests, ['1']);
    details.first.complete(details.result);
    await tester.pumpAndSettle();
    expect(details.requests, ['1', '36']);
    expect(
        tester
            .widget<SportsDetailsPanel>(find.byType(SportsDetailsPanel))
            .team!
            .id,
        '36');
    expect(tester.takeException(), isNull);
  });

  testWidgets('closing favourites with pending details queues no more work',
      (tester) async {
    final follows = SportsFollows.load(storage);
    for (final id in ['1', '2']) {
      await follows.follow('eng.1', id, name: 'Saved $id');
    }
    final details = PendingDetails();
    addTearDown(details.close);
    await open(
        tester,
        SportsTeamsScreen(
            follows: follows, favorites: true, detailsService: details));
    await tester.tap(find.byKey(const ValueKey('eng.1|1')));
    await tester.pump();
    await tester.tap(find.text('Saved 2'));
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    details.first.complete(details.result);
    await tester.pumpAndSettle();
    expect(details.requests, ['1']);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'removing a loading favourite and undo preserves identity and order',
      (tester) async {
    final follows = SportsFollows.load(storage);
    for (final id in ['1', '2']) {
      await follows.follow('eng.1', id, name: 'Saved $id');
    }
    final details = PendingDetails();
    addTearDown(details.close);
    await open(
        tester,
        SportsTeamsScreen(
            follows: follows, favorites: true, detailsService: details));
    await tester.tap(find.byKey(const ValueKey('eng.1|1')));
    await tester.pump();
    await tester.tap(find.byTooltip('Remove favourite').first);
    await tester.pump(const Duration(milliseconds: 300));
    details.first.complete(details.result);
    await tester.pumpAndSettle();
    expect(find.byType(SportsDetailsPanel), findsNothing);
    expect(follows.teams.map((t) => t.teamId), ['2']);
    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(follows.teams.map((t) => t.teamId), ['1', '2']);
    expect(follows.nameOf(follows.teams.first), 'Saved 1');
    await tester.tap(find.byKey(const ValueKey('eng.1|1')));
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<SportsDetailsPanel>(find.byType(SportsDetailsPanel))
            .team!
            .id,
        '1');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'TV favourites overlay has enough width for details and preserves the underlying screen',
      (tester) async {
    final follows = SportsFollows.load(storage);
    await follows.follow('eng.1', '1', name: 'Saved Club');
    final details = Details();
    addTearDown(details.close);
    await open(
        tester,
        Scaffold(
            body: Builder(
                builder: (context) => TextButton(
                    onPressed: () => showSportsPanel<void>(
                        context: context,
                        fullWidth: true,
                        maxWidth: 1000,
                        builder: (_) => SportsTeamsScreen(
                            follows: follows,
                            favorites: true,
                            panel: true,
                            detailsService: details)),
                    child: const Text('Open favourites')))));
    await tester.tap(find.text('Open favourites'));
    await tester.pumpAndSettle();
    expect(
        tester
            .getSize(find.byKey(const ValueKey('sports-panel-surface')))
            .width,
        greaterThan(700));
    await tester.tap(find.text('Saved Club'));
    await tester.pumpAndSettle();
    expect(find.byType(SportsDetailsPanel), findsOneWidget);
    expect(find.byTooltip('Close'), findsOneWidget);
    rowFocus('eng.1|1').requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(
        FocusManager.instance.primaryFocus?.context
            ?.findAncestorWidgetOfExactType<IconButton>()
            ?.tooltip,
        'Remove favourite');
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(find.text('Undo').hitTestable(), findsOneWidget,
        reason: 'Undo must be inside the active overlay, above its barrier.');
    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(follows.teams.single.teamId, '1');
    expect(find.text('Saved Club'), findsWidgets);
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    expect(find.text('Open favourites'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'phone favourite selection opens that team and keeps the list on return',
      (tester) async {
    prefs.isTelevision = false;
    final follows = SportsFollows.load(storage);
    await follows.follow('eng.1', '1', name: 'Saved Club');
    final details = Details();
    addTearDown(details.close);
    await open(
        tester,
        SportsTeamsScreen(
            follows: follows, favorites: true, detailsService: details),
        size: const Size(390, 844));
    expect(details.calls, 0);
    await tester.tap(find.text('Saved Club'));
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<SportsDetailsPanel>(find.byType(SportsDetailsPanel))
            .team!
            .id,
        '1');
    expect(find.byType(SportsTeamsScreen), findsOneWidget);
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    expect(find.text('Saved Club'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'phone team details persist an identity absent from the league table',
      (tester) async {
    prefs.isTelevision = false;
    final follows = SportsFollows.load(storage);
    await follows.follow('eng.1', '1');
    final service = MutableStandings();
    addTearDown(service.close);
    final details = Details()
      ..overrideResult = SportsDetails(
          title: 'Recovered Club', source: 'ESPN', fetchedAt: DateTime(2026));
    addTearDown(details.close);
    await open(
        tester,
        SportsTeamsScreen(
            follows: follows,
            favorites: true,
            service: service,
            detailsService: details),
        size: const Size(390, 844));
    await tester.tap(find.text('Team 1'));
    await tester.pumpAndSettle();
    expect(follows.nameOf(follows.teams.single), 'Recovered Club');
    expect(SportsFollows.load(storage).nameOf(follows.teams.single),
        'Recovered Club');
    expect(details.calls, 1);
  });

  for (final size in [const Size(320, 640), const Size(960, 540)]) {
    testWidgets('compact refresh confirmation fits large text at $size',
        (tester) async {
      prefs.isTelevision = size.width > 700;
      final manager = RefreshPlaylists(storage, CatalogDatabase());
      addTearDown(manager.dispose);
      await open(
          tester,
          Scaffold(
              body: Builder(
                  builder: (context) => TextButton(
                      onPressed: () =>
                          confirmAndRunFullCatalogSync(context, manager),
                      child: const Text('Refresh')))),
          size: size,
          scale: 2);
      await tester.tap(find.text('Refresh'));
      await tester.pumpAndSettle();
      expect(
          tester
              .getSize(find
                  .descendant(
                      of: find.byType(AlertDialog),
                      matching: find.byType(Material))
                  .first)
              .width,
          lessThanOrEqualTo(480));
      expect(find.text('Cancel').hitTestable(), findsOneWidget);
      expect(find.text('Update').hitTestable(), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(manager.updates, isEmpty);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
      'playlist update dialog owns remote input, cancels safely and updates only selected playlist',
      (tester) async {
    final manager = RefreshPlaylists(storage, CatalogDatabase());
    addTearDown(manager.dispose);
    await open(tester, const PlaylistManagerScreen(), playlist: manager);
    await tester.tap(find.text('Refresh playlists'));
    await tester.pumpAndSettle();
    expect(
        ModalRoute.of(tester.element(find.byType(AlertDialog)))!
            .transitionDuration,
        Duration.zero);
    expect(
        FocusManager.instance.primaryFocus!.context!
            .findAncestorWidgetOfExactType<AlertDialog>(),
        isNotNull);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(manager.updates, isEmpty);
    await tester.ensureVisible(find.text('Playlist two'));
    await tester.tap(find.text('Playlist two'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Refresh playlist'));
    tester
        .widget<TvMenuTile>(find.byWidgetPredicate(
            (w) => w is TvMenuTile && w.title == 'Refresh playlist'))
        .focusNode!
        .requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(
        find.descendant(
            of: find.byType(AlertDialog), matching: find.text('Playlist two')),
        findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    manager.pending = Completer<void>();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(manager.updates, ['two']);
    expect(manager.m3u, isEmpty);
    manager.pending!.complete();
    await tester.pumpAndSettle();
    expect(find.text('Refresh playlist'), findsOneWidget);
    expect(
        FocusManager.instance.primaryFocus,
        tester
            .widget<TvMenuTile>(find.byWidgetPredicate(
                (w) => w is TvMenuTile && w.title == 'Refresh playlist'))
            .focusNode);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
      'failed individual refresh removes only progress and can be retried',
      (tester) async {
    final manager = RefreshPlaylists(storage, CatalogDatabase())..fail = true;
    addTearDown(manager.dispose);
    await open(tester, const PlaylistManagerScreen(), playlist: manager);
    await tester.ensureVisible(find.text('Playlist two'));
    await tester.tap(find.text('Playlist two'));
    await tester.pumpAndSettle();
    for (var attempt = 0; attempt < 2; attempt++) {
      await tester.ensureVisible(find.text('Refresh playlist'));
      tester
          .widget<TvMenuTile>(find.byWidgetPredicate(
              (w) => w is TvMenuTile && w.title == 'Refresh playlist'))
          .focusNode!
          .requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Update'));
      await tester.pumpAndSettle();
      expect(find.text('Refresh playlist'), findsOneWidget);
      expect(
          FocusManager.instance.primaryFocus,
          tester
              .widget<TvMenuTile>(find.byWidgetPredicate(
                  (w) => w is TvMenuTile && w.title == 'Refresh playlist'))
              .focusNode);
      expect(find.byType(AlertDialog), findsNothing);
      manager.fail = false;
    }
    expect(manager.updates, ['two', 'two']);
    expect(tester.takeException(), isNull);
  });
}
