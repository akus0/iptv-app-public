import 'package:nox_iptv/utils/constants.dart';
import 'package:nox_iptv/screens/settings/settings_menu_screen.dart';
import 'package:nox_iptv/widgets/sports_header_controls.dart';
import 'package:nox_iptv/widgets/sports_channel_picker.dart';
import 'package:nox_iptv/widgets/sports_activity_status.dart';
import 'package:nox_iptv/widgets/channel_now_label.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:nox_iptv/models/channel.dart';
import 'package:nox_iptv/models/epg_program.dart';
import 'package:nox_iptv/models/m3u_group.dart';
import 'package:nox_iptv/models/sports.dart';
import 'package:nox_iptv/models/sports_progress.dart';
import 'package:nox_iptv/screens/tv_home_screen.dart';
import 'package:nox_iptv/screens/library_screen.dart';
import 'package:nox_iptv/utils/top_level_tab_route.dart';
import 'package:nox_iptv/screens/sports_screen.dart';
import 'package:nox_iptv/widgets/sports_replays_panel.dart';
import 'package:nox_iptv/widgets/sports_filter_picker.dart';
import 'package:nox_iptv/widgets/player_controls.dart';
import 'package:nox_iptv/screens/sports_live_list_screen.dart';
import 'package:nox_iptv/services/app_preferences.dart';
import 'package:nox_iptv/services/catalog_database.dart';
import 'package:nox_iptv/services/epg_service.dart';
import 'package:nox_iptv/services/playback_service.dart';
import 'package:nox_iptv/services/playlist_manager.dart';
import 'package:nox_iptv/services/storage_service.dart';
import 'package:nox_iptv/services/sports_supplement_service.dart';
import 'package:nox_iptv/services/sports_service.dart';
import 'package:nox_iptv/services/sports_channel_matcher.dart';
import 'package:nox_iptv/services/viewer_profile_service.dart';
import 'package:nox_iptv/utils/route_observer.dart';
import 'package:nox_iptv/utils/tv_theme.dart';

class _Supplement extends SportsSupplementService {
  _Supplement()
      : super.withClient(MockClient((_) async => http.Response('{}', 200)));
  int warms = 0, loads = 0;
  final games = [
    SportsGame(
      id: 'extra-demo',
      league: sportsLeagueById('tennis.atp')!,
      start: DateTime.now(),
      state: GameState.live,
      statusText: 'Live',
      source: 'TheSportsDB',
      home: const SportsTeam(
          id: 'a', name: 'Extra Player', shortName: 'Extra', abbreviation: ''),
      away: const SportsTeam(
          id: 'b',
          name: 'Another Player',
          shortName: 'Another',
          abbreviation: ''),
      event: const SportsEventInfo(title: 'European Open'),
    )
  ];
  @override
  Future<void> warmBroadcasts(List<SportsGame> games,
      {required bool Function() cancelled}) async {
    warms++;
  }

  @override
  Future<List<SportsGame>> gamesForDay(List<SportsLeague> leagues, DateTime day,
      {bool Function()? cancelled}) async {
    loads++;
    return games;
  }

  @override
  List<SportsGame> cachedGamesForDay(
          List<SportsLeague> leagues, DateTime day) =>
      loads == 0 ? const [] : games;
}

class _PollingScores extends SportsService {
  _PollingScores()
      : super.withClient(MockClient((_) async => http.Response('{}', 200)));
  final start = DateTime.now();
  int calls = 0;
  @override
  Future<List<SportsGame>> gamesForDay(List<SportsLeague> leagues, DateTime day,
      {void Function(List<SportsGame>)? onProgress,
      bool forceRefresh = false,
      void Function(SportsWorkProgress)? onStatus}) async {
    calls++;
    return [
      for (var i = 0; i < (calls == 1 ? 216 : 217); i++)
        SportsGame(
            id: 'poll-$i',
            league: sportsLeagueById('nhl')!,
            start: start,
            state: GameState.live,
            statusText: 'Live',
            home: SportsTeam(
                id: 'h$i',
                name: i == 216 ? 'Zebrafish United' : 'Boston Bruins',
                shortName: 'Home',
                abbreviation: 'H',
                score: '$calls'),
            away: const SportsTeam(
                id: 'a',
                name: 'Toronto Maple Leafs',
                shortName: 'Away',
                abbreviation: 'A'))
    ];
  }
}

class _BrowseScores extends _PollingScores {
  @override
  Future<List<SportsGame>> gamesForDay(List<SportsLeague> leagues, DateTime day,
      {void Function(List<SportsGame>)? onProgress,
      bool forceRefresh = false,
      void Function(SportsWorkProgress)? onStatus}) async {
    calls++;
    return [
      for (var i = 0; i < 24; i++)
        SportsGame(
          id: 'browse-$i',
          league: sportsLeagueById('nhl')!,
          start: start,
          state: GameState.live,
          statusText: 'Live',
          home: SportsTeam(
              id: 'h$i',
              name: 'Homealpha$i',
              shortName: 'Homealpha$i',
              abbreviation: '',
              score: '$calls'),
          away: SportsTeam(
              id: 'a$i',
              name: 'Awaybeta$i',
              shortName: 'Awaybeta$i',
              abbreviation: ''),
        )
    ];
  }

  List<EpgProgram> rows({int from = 0}) => [
        for (var i = from; i < 24; i++)
          EpgProgram(
              channelId: 'feed-$i',
              title: 'Ice Hockey: Homealpha$i vs Awaybeta$i',
              start: start.subtract(const Duration(minutes: 5)),
              stop: start.add(const Duration(hours: 2)))
      ];
}

class _ReopenScores extends _BrowseScores {
  List<SportsGame> cached = [];
  Completer<List<SportsGame>>? pending;
  @override
  List<SportsGame> cachedGamesForDay(
          List<SportsLeague> leagues, DateTime day) =>
      cached;
  @override
  Future<List<SportsGame>> gamesForDay(List<SportsLeague> leagues, DateTime day,
      {void Function(List<SportsGame>)? onProgress,
      bool forceRefresh = false,
      void Function(SportsWorkProgress)? onStatus}) async {
    if (pending != null) return cached = await pending!.future;
    return cached = await super.gamesForDay(leagues, day);
  }
}

class _RowScores extends _PollingScores {
  _RowScores({this.counts = const {}, this.upcoming = const {}});
  final Map<String, int> counts;
  final Set<String> upcoming;
  @override
  Future<List<SportsGame>> gamesForDay(List<SportsLeague> leagues, DateTime day,
          {void Function(List<SportsGame>)? onProgress,
          bool forceRefresh = false,
          void Function(SportsWorkProgress)? onStatus}) async =>
      [
        for (final league in leagues)
          for (var i = 0;
              i < (counts[league.id] ?? (counts.isEmpty ? 20 : 0));
              i++)
            SportsGame(
                id: 'row-$i',
                league: league,
                start: start,
                state: upcoming.contains(league.id)
                    ? GameState.pre
                    : GameState.live,
                statusText: 'Live',
                home: SportsTeam(
                    id: 'h$i',
                    name: 'Home $i',
                    shortName: 'Home $i',
                    abbreviation: 'H'),
                away: SportsTeam(
                    id: 'a$i',
                    name: 'Away $i',
                    shortName: 'Away $i',
                    abbreviation: 'A'))
      ];
}

class _HeldScores extends _PollingScores {
  final done = Completer<List<SportsGame>>();
  void Function(List<SportsGame>)? publish;
  List<SportsGame> batch = [];
  @override
  Future<List<SportsGame>> gamesForDay(List<SportsLeague> leagues, DateTime day,
      {void Function(List<SportsGame>)? onProgress,
      bool forceRefresh = false,
      void Function(SportsWorkProgress)? onStatus}) {
    publish = onProgress;
    onStatus?.call(const SportsWorkProgress(SportsWorkStage.scores, total: 3));
    return done.future;
  }

  Future<void> firstBatch() async {
    batch =
        (await super.gamesForDay([sportsLeagueById('nhl')!], DateTime.now()))
            .take(1)
            .toList();
    publish?.call(batch);
  }
}

class _CalendarScores extends _PollingScores {
  final days = <DateTime>[];
  @override
  Future<List<SportsGame>> gamesForDay(List<SportsLeague> leagues, DateTime day,
      {void Function(List<SportsGame>)? onProgress,
      bool forceRefresh = false,
      void Function(SportsWorkProgress)? onStatus}) async {
    days.add(day);
    return [];
  }
}

class _RecoveringScores extends _HeldScores {
  final retries = <Completer<List<SportsGame>>>[];
  @override
  Future<List<SportsGame>> gamesForDay(List<SportsLeague> leagues, DateTime day,
      {void Function(List<SportsGame>)? onProgress,
      bool forceRefresh = false,
      void Function(SportsWorkProgress)? onStatus}) {
    if (publish == null) {
      return super.gamesForDay(leagues, day,
          onProgress: onProgress,
          forceRefresh: forceRefresh,
          onStatus: onStatus);
    }
    final request = Completer<List<SportsGame>>();
    retries.add(request);
    onStatus?.call(const SportsWorkProgress(SportsWorkStage.scores, total: 3));
    return request.future;
  }
}

class _WarmGuide extends _SlowGuide {
  _WarmGuide(super.storage);
  int reads = 0;
  @override
  EpgProgram? getCurrentProgram(String id) {
    reads++;
    return super.getCurrentProgram(id);
  }
}

class _SlowGuide extends _Epg {
  _SlowGuide(super.storage);
  final requests = <Completer<List<EpgProgram>>>[];
  @override
  Future<List<EpgProgram>> findProgrammesByTitle(
      DateTime from, DateTime to, List<String> terms,
      {List<String>? channelIds}) {
    final request = Completer<List<EpgProgram>>();
    requests.add(request);
    return request.future;
  }
}

class _Playlist extends PlaylistManager {
  _Playlist(super.storage, super.db);
  final fixtureChannels = [
    for (final name in [
      'ABC HD',
      'SBS HD',
      'Seven',
      'Nine',
      '10 HD',
      'ABC News',
      'SBS World',
      'Fox Sports',
      'Fox Sports HD'
    ])
      Channel(
          id: 'demo::$name',
          rawId: name,
          playlistId: 'demo',
          name: name,
          group: 'Australian TV',
          url: 'https://example.test/live'),
  ];
  @override
  bool get hasLiveChannels => channels.isNotEmpty;

  @override
  List<Channel> get channels => fixtureChannels;
  @override
  List<M3uGroup> get tvGroups => [
        M3uGroup(
            title: 'Australian TV',
            playlistId: 'demo',
            channels: fixtureChannels)
      ];
  @override
  List<Channel> visibleChannels(
          {String? playlistId, String? groupTitle, required String category}) =>
      groupTitle == null
          ? fixtureChannels
          : fixtureChannels.where((c) => c.group == groupTitle).toList();
  @override
  Future<void> ensureLiveChannelsLoaded() async {
    catalogueLoads++;
  }

  int catalogueLoads = 0;
}

class _Playback extends PlaybackService {
  _Playback(super.storage, super.playlist);
  final played = <Channel>[];
  Completer<void>? openGate;
  final history = <Channel>[];
  @override
  List<Channel> recentLiveChannels({int limit = 10}) =>
      history.take(limit).toList();
  @override
  Future<void> play(Channel channel) async {
    played.add(channel);
    currentChannel = channel;
    notifyListeners();
    await openGate?.future;
  }

  @override
  Future<void> stop() async {
    currentChannel = null;
    notifyListeners();
  }
}

class _Epg extends EpgService {
  _Epg(super.storage);
  Completer<List<EpgProgram>>? pending;
  List<EpgProgram> replays = [];
  @override
  Future<List<EpgProgram>> findSportsProgrammesForChannels(
          List<String> ids, DateTime from, DateTime to) async =>
      replays
          .where((p) =>
              ids.contains(p.channelId) &&
              p.start.isBefore(to) &&
              p.stop.isAfter(from))
          .toList();
  final withoutGuide = <String>{};
  @override
  Iterable<EpgProgram> cachedCurrentProgrammes(DateTime now) =>
      replays.where((p) => p.isNowPlaying(now));
  @override
  Future<List<EpgProgram>> findProgrammesByTitle(
          DateTime from, DateTime to, List<String> terms,
          {List<String>? channelIds}) async =>
      pending == null ? [] : await pending!.future;
  final now = DateTime.now();
  @override
  List<EpgProgram> getPrograms(String channelId) => [
        for (var i = -1; i < 5; i++)
          EpgProgram(
              channelId: channelId,
              title: [
                'Morning News',
                'The World Today',
                'Live Sport',
                'Evening Report',
                'Coast to Coast',
                'Night News'
              ][i + 1],
              description:
                  'News, stories and live coverage from across Australia and around the world.',
              start: DateTime(now.year, now.month, now.day, now.hour)
                  .add(Duration(hours: i)),
              stop: DateTime(now.year, now.month, now.day, now.hour)
                  .add(Duration(hours: i + 1))),
      ];
  @override
  EpgProgram? getCurrentProgram(String channelId) => withoutGuide
          .contains(channelId)
      ? null
      : replays
              .where((p) =>
                  normalizeEpgId(p.channelId) == normalizeEpgId(channelId) &&
                  p.isNowPlaying(DateTime.now()))
              .firstOrNull ??
          getPrograms(channelId)[1];
  @override
  EpgProgram? getNextProgram(String channelId) => getPrograms(channelId)[2];
}

// Isolate replies use real time; pumpAndSettle alone advances only fake time.
Future<void> settleSports(WidgetTester tester) async {
  for (var i = 0; i < 200; i++) {
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
    await tester.pump(const Duration(milliseconds: 16));
    if (!tester.binding.hasScheduledFrame) break;
  }
  await tester.pumpAndSettle();
}

Future<void> captureSports(WidgetTester tester, Size size, String name) async {
  if (!const bool.fromEnvironment('CAPTURE_LAYOUT')) return;
  await tester.pump(const Duration(milliseconds: 200));
  await tester.runAsync(() async {
    final boundary = tester
        .firstRenderObject<RenderRepaintBoundary>(find.byType(RepaintBoundary));
    final image = await boundary.toImage();
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    await File('/tmp/iptv-$name-${size.width.toInt()}.png')
        .writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

http.Response _tennisFixture() => http.Response(
    jsonEncode({
      'events': [
        {
          'id': 'tournament',
          'name': 'BNP Paribas Fortis European Open',
          'groupings': [
            {
              'grouping': {'displayName': "Men's Singles"},
              'competitions': [
                {
                  'id': 'tennis-demo',
                  'date': DateTime.now().toUtc().toIso8601String(),
                  'round': {'displayName': 'Round 2'},
                  'venue': {
                    'fullName': 'Brussels, Belgium',
                    'court': 'Court 2'
                  },
                  'status': {
                    'type': {'state': 'in', 'shortDetail': '2nd Set'}
                  },
                  'competitors': [
                    {
                      'athlete': {'id': '1', 'displayName': 'Yunchaokete Bu'},
                      'linescores': [
                        {'value': 6},
                        {'value': 3}
                      ]
                    },
                    {
                      'athlete': {'id': '2', 'displayName': 'Casper Ruud'},
                      'linescores': [
                        {'value': 4},
                        {'value': 2}
                      ]
                    },
                  ]
                }
              ]
            }
          ]
        }
      ]
    }),
    200);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(SportsChannelMatcher.disposeShared);
  setUp(SportsService.resetForTesting);
  tearDown(SportsService.resetForTesting);
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final cache = await Directory.systemTemp.createTemp('iptv-layout-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => cache.path,
    );
    const fonts = String.fromEnvironment('LAYOUT_FONT_DIR');
    if (fonts.isEmpty) return;
    for (final entry in {
      'Roboto': 'Roboto-Regular.ttf',
      'MaterialIcons': 'MaterialIcons-Regular.otf'
    }.entries) {
      final loader = FontLoader(entry.key);
      loader.addFont(File('$fonts/${entry.value}')
          .readAsBytes()
          .then((bytes) => ByteData.sublistView(bytes)));
      await loader.load();
    }
  });

  testWidgets(
      'top-level library switches preserve menu geometry and return Live TV focus without animation',
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
    final db = CatalogDatabase();
    final playlist = _Playlist(storage, db);
    final playback = _Playback(storage, playlist);
    final epg = _Epg(storage);
    final viewers = ViewerProfileService(storage, playlist, playback);
    await tester.pumpWidget(MultiProvider(
        providers: [
          Provider.value(value: storage),
          Provider<CatalogDatabase>.value(value: db),
          ChangeNotifierProvider.value(value: prefs),
          ChangeNotifierProvider<PlaylistManager>.value(value: playlist),
          ChangeNotifierProvider<PlaybackService>.value(value: playback),
          ChangeNotifierProvider<EpgService>.value(value: epg),
          ChangeNotifierProvider.value(value: viewers),
        ],
        child: MaterialApp(
            theme: buildAppTheme(prefs.palette),
            navigatorObservers: [appRouteObserver],
            home: const TvHomeScreen())));
    await tester.pumpAndSettle();
    const ids = ['live', 'sports', 'movies', 'series', 'settings'];
    Finder menu(String id) => find.byKey(ValueKey('main-nav-$id'));
    final bounds = {for (final id in ids) id: tester.getRect(menu(id))};
    final icons = {
      for (final id in ids)
        id: tester
            .widget<Icon>(
                find.descendant(of: menu(id), matching: find.byType(Icon)))
            .icon
    };
    await tester.tap(menu('movies'));
    await tester.pumpAndSettle();
    expect(find.byType(LibraryScreen), findsOneWidget);
    final route = ModalRoute.of(tester.element(find.byType(LibraryScreen)))!;
    expect(route, isA<TopLevelTabRoute<String>>());
    expect(route.transitionDuration, Duration.zero);
    expect(route.reverseTransitionDuration, Duration.zero);
    for (final id in ids) {
      expect(tester.getRect(menu(id)), bounds[id],
          reason: '$id must stay anchored');
      expect(
          tester
              .widget<Icon>(
                  find.descendant(of: menu(id), matching: find.byType(Icon)))
              .icon,
          icons[id]);
    }
    await tester.tap(menu('series'));
    await tester.pumpAndSettle();
    for (final id in ids) {
      expect(tester.getRect(menu(id)), bounds[id]);
    }
    await tester.tap(menu('live'));
    await tester.pump();
    await tester.pump();
    expect(find.byType(LibraryScreen), findsNothing);
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'tv-tab-TV');
    for (final id in ids) {
      expect(tester.getRect(menu(id)), bounds[id]);
    }
    expect(playback.played, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    viewers.dispose();
    playback.dispose();
    playlist.dispose();
    epg.dispose();
    prefs.dispose();
  });

  for (final palette in AppConstants.cyberpunkPalettes) {
    for (final size in [const Size(390, 844), const Size(960, 540)]) {
      testWidgets('theme guide smoke ${palette.id} ${size.width}',
          (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        SharedPreferences.setMockInitialValues({});
        final storage = StorageService();
        await storage.init();
        await storage.setPaletteId(palette.id);
        final prefs = AppPreferences(storage);
        await prefs.init();
        prefs.isTelevision = size.width > 600;
        final playlist = _Playlist(storage, CatalogDatabase());
        final playback = _Playback(storage, playlist);
        final epg = _Epg(storage);
        final viewers = ViewerProfileService(storage, playlist, playback);
        await tester.pumpWidget(MultiProvider(
            providers: [
              Provider<StorageService>.value(value: storage),
              ChangeNotifierProvider.value(value: prefs),
              ChangeNotifierProvider<PlaylistManager>.value(value: playlist),
              ChangeNotifierProvider<PlaybackService>.value(value: playback),
              ChangeNotifierProvider<EpgService>.value(value: epg),
              ChangeNotifierProvider.value(value: viewers),
            ],
            child: MaterialApp(
                theme: buildAppTheme(palette),
                navigatorObservers: [appRouteObserver],
                home: const TvHomeScreen())));
        await tester.pumpAndSettle();
        if (find.byKey(const ValueKey('guide-now')).evaluate().isEmpty) {
          await tester.tap(find.text('Australian TV').first);
          await tester.pumpAndSettle();
        }
        await tester.tap(find.byKey(const ValueKey('guide-now')));
        await tester.pumpAndSettle();
        expect(find.text('The World Today'), findsWidgets);
        expect(find.text('ABC HD'), findsWidgets);
        expect(playback.played, isEmpty);
        expect(tester.takeException(), isNull);
        await captureSports(tester, size, 'theme-guide-${palette.id}');
        await tester.pumpWidget(const SizedBox());
        viewers.dispose();
        playback.dispose();
        playlist.dispose();
        epg.dispose();
        prefs.dispose();
      });
    }
  }

  testWidgets(
      'multiview Sports selection returns a channel without preview playback',
      (tester) => http.runWithClient(() async {
            tester.view.physicalSize = const Size(1280, 720);
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.reset);
            SharedPreferences.setMockInitialValues(
                {'sports_online_extras': false});
            final storage = StorageService();
            await storage.init();
            await storage.setSportsAddedLeagues(['nhl']);
            await storage.setSportsLeagues(['nhl']);
            await storage.setSportsChannelFilter('all');
            const themeId = String.fromEnvironment('LAYOUT_THEME');
            if (themeId.isNotEmpty) await storage.setPaletteId(themeId);
            final prefs = AppPreferences(storage);
            await prefs.init();
            prefs.isTelevision = true;
            final playlist = _Playlist(storage, CatalogDatabase());
            final playback = _Playback(storage, playlist);
            final epg = _Epg(storage);
            final viewers = ViewerProfileService(storage, playlist, playback);
            final scores = _PollingScores();
            Channel? selected;
            await tester.pumpWidget(MultiProvider(
                providers: [
                  Provider.value(value: storage),
                  ChangeNotifierProvider.value(value: prefs),
                  ChangeNotifierProvider<PlaylistManager>.value(
                      value: playlist),
                  ChangeNotifierProvider<PlaybackService>.value(
                      value: playback),
                  ChangeNotifierProvider<EpgService>.value(value: epg),
                  ChangeNotifierProvider.value(value: viewers),
                ],
                child: MaterialApp(
                    theme: buildAppTheme(prefs.palette),
                    navigatorObservers: [appRouteObserver],
                    home: SportsScreen(
                        scores: scores,
                        selectionTitle: 'Sports · screen 2',
                        onChooseChannel: (c) async {
                          selected = c;
                        }))));
            await settleSports(tester);
            expect(find.text('Sports · screen 2'), findsOneWidget);
            expect(find.byType(PlayerControls), findsNothing);
            tester
                .widget<SportsFilterButton>(
                    find.byKey(const ValueKey('sport-picker')))
                .focusNode!
                .requestFocus();
            await tester.pump();
            await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
            await tester.pump();
            await tester.sendKeyDownEvent(LogicalKeyboardKey.select);
            await tester.pump(const Duration(milliseconds: 700));
            await tester.sendKeyUpEvent(LogicalKeyboardKey.select);
            await settleSports(tester);
            expect(find.byType(SportsChannelPickerDialog), findsOneWidget);
            final dialog = tester.widget<SportsChannelPickerDialog>(
                find.byType(SportsChannelPickerDialog));
            expect(dialog.allowMultiview, false);
            await tester.tap(find.text('Find another channel'));
            await settleSports(tester);
            final search = find.byKey(const ValueKey('sports-channel-search'));
            tester.widget<TextField>(search).focusNode!.requestFocus();
            await tester.pump();
            await tester.sendKeyEvent(LogicalKeyboardKey.select);
            await tester.pump();
            await tester.enterText(search, 'Fox');
            await tester.pump(const Duration(milliseconds: 250));
            await settleSports(tester);
            final chosenRow = tester
                .widget<SportsChannelRow>(find.byType(SportsChannelRow).first);
            await tester.tap(find.byKey(
                ValueKey('game-channel:${chosenRow.result.channel.id}')));
            await settleSports(tester);
            expect(selected, isNotNull);
            expect(playback.played, isEmpty);
            expect(playback.currentChannel, isNull);
            expect(tester.takeException(), isNull);
            await tester.pumpWidget(const SizedBox());
            await settleSports(tester);
            viewers.dispose();
            playback.dispose();
            playlist.dispose();
            epg.dispose();
            prefs.dispose();
            await tester.pump(const Duration(minutes: 2));
          }, () => MockClient((_) async => http.Response('{}', 200))));

  testWidgets(
      'pending Sports fullscreen cannot open over a newer route',
      (tester) => http.runWithClient(() async {
            tester.view.physicalSize = const Size(1280, 720);
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.reset);
            SharedPreferences.setMockInitialValues(
                {'sports_online_extras': false});
            final storage = StorageService();
            await storage.init();
            await storage.setSportsAddedLeagues(['nhl']);
            await storage.setSportsLeagues(['nhl']);
            await storage.setSportsChannelFilter('all');
            final prefs = AppPreferences(storage);
            await prefs.init();
            prefs.isTelevision = true;
            final playlist = _Playlist(storage, CatalogDatabase());
            playlist.fixtureChannels.add(Channel(
                id: 'demo::fixture',
                rawId: 'fixture',
                playlistId: 'demo',
                name: 'Home 0 vs Away 0',
                group: 'Sports',
                url: 'https://example.test/live'));
            final playback = _Playback(storage, playlist)
              ..openGate = Completer<void>();
            final epg = _Epg(storage);
            final viewers = ViewerProfileService(storage, playlist, playback);
            final navigator = GlobalKey<NavigatorState>();
            await tester.pumpWidget(MultiProvider(
                providers: [
                  Provider.value(value: storage),
                  ChangeNotifierProvider.value(value: prefs),
                  ChangeNotifierProvider<PlaylistManager>.value(
                      value: playlist),
                  ChangeNotifierProvider<PlaybackService>.value(
                      value: playback),
                  ChangeNotifierProvider<EpgService>.value(value: epg),
                  ChangeNotifierProvider.value(value: viewers),
                ],
                child: MaterialApp(
                    navigatorKey: navigator,
                    theme: buildAppTheme(prefs.palette),
                    navigatorObservers: [appRouteObserver],
                    home:
                        SportsScreen(scores: _RowScores(counts: {'nhl': 1})))));
            await settleSports(tester);
            final card = find.byKey(const ValueKey('card-nhl:row-0'));
            await tester.tap(card);
            await tester.pump();
            expect(playback.played, hasLength(1));
            // Repeated OK while the stream is opening must not stack fullscreen routes.
            await tester.tap(card);
            await tester.pump();
            await tester.tap(card);
            await tester.pump();
            unawaited(navigator.currentState!.push(MaterialPageRoute<void>(
                builder: (_) =>
                    const Scaffold(body: Text('New destination')))));
            await tester.pumpAndSettle();
            playback.openGate!.complete();
            await tester.pumpAndSettle();
            expect(find.text('New destination'), findsOneWidget);
            navigator.currentState!.pop();
            await tester.pumpAndSettle();
            expect(find.byType(SportsScreen), findsOneWidget);
            expect(tester.takeException(), isNull);
            await tester.pumpWidget(const SizedBox());
            SportsChannelMatcher.disposeShared();
            playback.dispose();
            playlist.dispose();
            epg.dispose();
            prefs.dispose();
            await tester.pump(const Duration(minutes: 2));
          }, () => MockClient((_) async => http.Response('{}', 200))));

  testWidgets(
      'TV sports remote reaches refresh and isolates card focus rebuilds',
      (tester) => http.runWithClient(() async {
            tester.view.physicalSize = const Size(1280, 720);
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.reset);
            SharedPreferences.setMockInitialValues(
                {'sports_online_extras': false});
            final storage = StorageService();
            await storage.init();
            await storage.setSportsAddedLeagues(['nhl']);
            await storage.setSportsLeagues(['nhl']);
            await storage.setSportsChannelFilter('all');
            const themeId = String.fromEnvironment('LAYOUT_THEME');
            if (themeId.isNotEmpty) await storage.setPaletteId(themeId);
            final prefs = AppPreferences(storage);
            await prefs.init();
            prefs.isTelevision = true;
            final playlist = _Playlist(storage, CatalogDatabase());
            final playback = _Playback(storage, playlist);
            final epg = _Epg(storage);
            final viewers = ViewerProfileService(storage, playlist, playback);
            final scores = _PollingScores();
            await tester.pumpWidget(MultiProvider(
                providers: [
                  Provider.value(value: storage),
                  ChangeNotifierProvider.value(value: prefs),
                  ChangeNotifierProvider<PlaylistManager>.value(
                      value: playlist),
                  ChangeNotifierProvider<PlaybackService>.value(
                      value: playback),
                  ChangeNotifierProvider<EpgService>.value(value: epg),
                  ChangeNotifierProvider.value(value: viewers),
                ],
                child: MaterialApp(
                    theme: buildAppTheme(prefs.palette),
                    navigatorObservers: [appRouteObserver],
                    home: SportsScreen(scores: scores))));
            await settleSports(tester);
            await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
            await tester.pump();
            expect(FocusManager.instance.primaryFocus?.debugLabel,
                'sports-chip-refresh');
            final calls = scores.calls;
            await tester.sendKeyEvent(LogicalKeyboardKey.select);
            await settleSports(tester);
            expect(scores.calls, calls + 1);
            // Returning to the toolbar is explicit, including during refresh.
            tester
                .widget<SportsFilterButton>(
                    find.byKey(const ValueKey('sport-picker')))
                .focusNode!
                .requestFocus();
            await tester.pump();
            await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
            await tester.pump();
            expect(FocusManager.instance.primaryFocus?.debugLabel,
                startsWith('sports-card-'));
            var screenBuilds = 0;
            final previous = debugOnRebuildDirtyWidget;
            debugOnRebuildDirtyWidget = (element, builtOnce) {
              if (element.widget is SportsScreen) screenBuilds++;
              previous?.call(element, builtOnce);
            };
            addTearDown(() => debugOnRebuildDirtyWidget = previous);
            for (var i = 0; i < 4; i++) {
              await tester.sendKeyEvent(i.isEven
                  ? LogicalKeyboardKey.arrowRight
                  : LogicalKeyboardKey.arrowLeft);
              await tester.pump();
            }
            expect(screenBuilds, 0,
                reason: 'Remote focus only updates preview and two cards');
            await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
            await tester.pump();
            expect(FocusManager.instance.primaryFocus?.debugLabel,
                'sports-chip-sport:hockey');
            await tester.sendKeyEvent(LogicalKeyboardKey.select);
            await settleSports(tester);
            await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
            await tester.pump();
            expect(FocusManager.instance.primaryFocus?.debugLabel,
                startsWith('sports-card-'));
            await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
            await tester.pump();
            expect(FocusManager.instance.primaryFocus?.debugLabel,
                'sports-chip-liveall');
            await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
            await tester.pump();
            expect(FocusManager.instance.primaryFocus?.debugLabel,
                startsWith('sports-card-'));
            expect(tester.takeException(), isNull);
            await tester.pumpWidget(const SizedBox());
            SportsChannelMatcher.disposeShared();
            viewers.dispose();
            playback.dispose();
            playlist.dispose();
            epg.dispose();
            prefs.dispose();
          },
              () => MockClient(
                  (_) async => http.Response('{"events":[]}', 200))));

  testWidgets(
      'TV sports navigates uneven rows, lazy cards and every toolbar control',
      (tester) => http.runWithClient(() async {
            tester.view.physicalSize = const Size(960, 540);
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.reset);
            SharedPreferences.setMockInitialValues(
                {'sports_online_extras': false});
            final storage = StorageService();
            await storage.init();
            await storage.setSportsAddedLeagues(
                ['eng.1', 'mma.ufc', 'guide.poker', 'nba', 'nhl']);
            await storage.setSportsLeagues(
                ['eng.1', 'mma.ufc', 'guide.poker', 'nba', 'nhl']);
            await storage.setSportsChannelFilter('all');
            const themeId = String.fromEnvironment('LAYOUT_THEME');
            if (themeId.isNotEmpty) await storage.setPaletteId(themeId);
            final prefs = AppPreferences(storage);
            await prefs.init();
            prefs.isTelevision = true;
            final playlist = _Playlist(storage, CatalogDatabase());
            final playback = _Playback(storage, playlist);
            final epg = _Epg(storage);
            final viewers = ViewerProfileService(storage, playlist, playback);
            final scores = _RowScores(upcoming: {
              'nba',
              'nhl'
            }, counts: {
              'eng.1': 1,
              'mma.ufc': 1,
              'guide.poker': 3,
              'nba': 1,
              'nhl': 20
            });
            await tester.pumpWidget(MultiProvider(
                providers: [
                  Provider.value(value: storage),
                  ChangeNotifierProvider.value(value: prefs),
                  ChangeNotifierProvider<PlaylistManager>.value(
                      value: playlist),
                  ChangeNotifierProvider<PlaybackService>.value(
                      value: playback),
                  ChangeNotifierProvider<EpgService>.value(value: epg),
                  ChangeNotifierProvider.value(value: viewers),
                ],
                child: MaterialApp(
                    theme: buildAppTheme(prefs.palette),
                    navigatorObservers: [appRouteObserver],
                    home: SportsScreen(scores: scores))));
            await settleSports(tester);
            String? focused() => FocusManager.instance.primaryFocus?.debugLabel;
            Future<void> press(LogicalKeyboardKey key) async {
              await tester.sendKeyEvent(key);
              await tester.pump();
              await tester.pump(const Duration(milliseconds: 20));
              final focus = FocusManager.instance.primaryFocus;
              if (focus?.debugLabel?.startsWith('sports-card-') ?? false) {
                final viewport = tester
                    .getRect(find.byKey(const PageStorageKey('sports-events')));
                expect(focus!.rect.top, greaterThanOrEqualTo(viewport.top - 1),
                    reason: 'Focused card is visible above');
                expect(
                    focus.rect.bottom, lessThanOrEqualTo(viewport.bottom + 1),
                    reason: 'Focused card is visible below');
                expect(focus.rect.left, greaterThanOrEqualTo(viewport.left - 1),
                    reason: 'Focused card is visible on left');
                expect(focus.rect.right, lessThanOrEqualTo(viewport.right + 1),
                    reason: 'Focused card is visible on right');
              }
            }

            final toolbar = [
              'view-events',
              'view-replays',
              'view-highlights',
              'sport-picker',
              'league-picker',
              'live-only',
              'with-channel',
              'day',
              'options'
            ];
            for (var i = 0; i < 3; i++) {
              await press(LogicalKeyboardKey.arrowLeft);
            }
            expect(focused(), 'sports-chip-view-events');
            for (final id in toolbar.skip(1)) {
              await press(LogicalKeyboardKey.arrowRight);
              expect(focused(), 'sports-chip-$id');
            }
            await press(LogicalKeyboardKey.arrowRight);
            expect(focused(), 'sports-chip-options',
                reason: 'No wrap into content');
            for (final id in toolbar.reversed.skip(1)) {
              await press(LogicalKeyboardKey.arrowLeft);
              expect(focused(), 'sports-chip-$id');
            }
            final rows = tester
                .widgetList<ListView>(find.byWidgetPredicate((w) =>
                    w is ListView && w.scrollDirection == Axis.horizontal))
                .toList();
            expect(rows.length, 5);
            String firstKey(ListView row) {
              final rowFinder = find.byKey(row.key!);
              final cards = find.descendant(
                  of: rowFinder,
                  matching: find.byWidgetPredicate((w) =>
                      w.key is ValueKey<String> &&
                      (w.key as ValueKey<String>).value.startsWith('card-')));
              return (tester.widget(cards.first).key as ValueKey<String>)
                  .value
                  .substring(5);
            }

            final firstKeys = rows.map(firstKey).toList();
            await press(LogicalKeyboardKey.arrowDown);
            expect(focused(), 'sports-card-${firstKeys.first}');
            for (final key in firstKeys.skip(1)) {
              await press(LogicalKeyboardKey.arrowDown);
              expect(focused(), 'sports-card-$key',
                  reason: 'Exactly one sport per Down');
            }
            await press(LogicalKeyboardKey.arrowDown);
            expect(focused(), 'sports-card-${firstKeys.last}');
            for (final key in firstKeys.reversed.skip(1)) {
              await press(LogicalKeyboardKey.arrowUp);
              expect(focused(), 'sports-card-$key');
            }
            await press(LogicalKeyboardKey.arrowUp);
            expect(focused(), 'sports-chip-view-events');
            // Enter poker's third card, then cross a one-card row in each direction.
            final pokerRow =
                firstKeys.indexWhere((k) => k.startsWith('guide.poker:'));
            for (var i = 0; i <= pokerRow; i++) {
              await press(LogicalKeyboardKey.arrowDown);
            }
            await press(LogicalKeyboardKey.arrowRight);
            await press(LogicalKeyboardKey.arrowRight);
            expect(focused(), 'sports-card-guide.poker:row-2');
            await press(LogicalKeyboardKey.arrowUp);
            expect(focused(), 'sports-card-${firstKeys[pokerRow - 1]}');
            await press(LogicalKeyboardKey.arrowDown);
            expect(focused(), 'sports-card-guide.poker:row-0');
            // Sport headings are reachable without being compulsory stops.
            await press(LogicalKeyboardKey.arrowLeft);
            expect(focused(), 'sports-chip-sport:poker');
            await press(LogicalKeyboardKey.arrowLeft);
            expect(focused(), 'sports-chip-refresh');
            await press(LogicalKeyboardKey.arrowRight);
            expect(focused(), 'sports-card-guide.poker:row-0');
            await press(LogicalKeyboardKey.contextMenu);
            expect(focused(), 'sports-chip-refresh');
            await press(LogicalKeyboardKey.arrowUp);
            expect(focused(), 'sports-chip-view-events');
            await press(LogicalKeyboardKey.arrowDown);
            expect(focused(), 'sports-card-guide.poker:row-0',
                reason: 'Resume browsing');
            // A long horizontal row must build and focus offscreen neighbours.
            final longRow = firstKeys.indexWhere((k) => k.startsWith('nhl:'));
            for (var i = pokerRow; i > longRow; i--) {
              await press(LogicalKeyboardKey.arrowUp);
            }
            for (var i = 1; i < 15; i++) {
              await press(LogicalKeyboardKey.arrowRight);
              expect(focused(),
                  'sports-card-${firstKeys[longRow].replaceFirst('row-0', 'row-$i')}');
            }
            await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowLeft);
            await tester.pump();
            for (var i = 12; i >= 8; i--) {
              await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowLeft);
              await tester.pump();
              await tester.pump(const Duration(milliseconds: 20));
              expect(focused(),
                  'sports-card-${firstKeys[longRow].replaceFirst('row-0', 'row-$i')}');
            }
            await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowLeft);
            await press(LogicalKeyboardKey.arrowUp);
            expect(focused(), 'sports-card-${firstKeys[longRow - 1]}');
            // Remember an Events-only filter, then replace its widget by
            // switching views. A detached node still has a context in Flutter.
            await press(LogicalKeyboardKey.contextMenu);
            await press(LogicalKeyboardKey.arrowUp);
            for (var i = 0; i < 3; i++) {
              await press(LogicalKeyboardKey.arrowRight);
            }
            expect(focused(), 'sports-chip-sport-picker');
            await press(LogicalKeyboardKey.arrowDown);
            await press(LogicalKeyboardKey.contextMenu);
            await press(LogicalKeyboardKey.arrowUp);
            await press(LogicalKeyboardKey.arrowLeft);
            await press(LogicalKeyboardKey.arrowLeft);
            expect(focused(), 'sports-chip-view-replays');
            await press(LogicalKeyboardKey.select);
            await settleSports(tester);
            await press(LogicalKeyboardKey.contextMenu);
            expect(focused(), 'replays-refresh');
            await press(LogicalKeyboardKey.arrowUp);
            expect(focused(), 'sports-chip-view-replays',
                reason: 'Do not focus the detached Events filter');
            await press(LogicalKeyboardKey.arrowRight);
            await press(LogicalKeyboardKey.select);
            await settleSports(tester);
            await press(LogicalKeyboardKey.contextMenu);
            expect(focused(), 'replays-refresh');
            await press(LogicalKeyboardKey.arrowUp);
            expect(focused(), 'sports-chip-view-highlights');
            expect(tester.takeException(), isNull);
            await tester.pumpWidget(const SizedBox());
            SportsChannelMatcher.disposeShared();
            viewers.dispose();
            playback.dispose();
            playlist.dispose();
            epg.dispose();
            prefs.dispose();
          },
              () => MockClient(
                  (_) async => http.Response('{"events":[]}', 200))));

  for (final size in [const Size(390, 844), const Size(1280, 720)]) {
    testWidgets(
        'direct settings navigation preserves playback at ${size.width}',
        (tester) => http.runWithClient(() async {
              tester.view.physicalSize = size;
              tester.view.devicePixelRatio = 1;
              addTearDown(tester.view.reset);
              SharedPreferences.setMockInitialValues(
                  {'sports_online_extras': false});
              final storage = StorageService();
              await storage.init();
              await storage.setSportsAddedLeagues(['nhl']);
              await storage.setSportsLeagues(['nhl']);
              const themeId = String.fromEnvironment('LAYOUT_THEME');
              if (themeId.isNotEmpty) await storage.setPaletteId(themeId);
              final prefs = AppPreferences(storage);
              await prefs.init();
              prefs.isTelevision = size.width > 600;
              final playlist = _Playlist(storage, CatalogDatabase());
              final playback = _Playback(storage, playlist);
              final epg = _Epg(storage);
              final viewers = ViewerProfileService(storage, playlist, playback);
              await playback.play(playlist.channels.first);
              await tester.pumpWidget(MultiProvider(
                  providers: [
                    Provider.value(value: storage),
                    ChangeNotifierProvider.value(value: prefs),
                    ChangeNotifierProvider<PlaylistManager>.value(
                        value: playlist),
                    ChangeNotifierProvider<PlaybackService>.value(
                        value: playback),
                    ChangeNotifierProvider<EpgService>.value(value: epg),
                    ChangeNotifierProvider.value(value: viewers),
                  ],
                  child: MaterialApp(
                      theme: buildAppTheme(prefs.palette),
                      navigatorObservers: [appRouteObserver],
                      home: const TvHomeScreen())));
              await tester.pumpAndSettle();
              final channel = playback.currentChannel;
              final count = playback.played.length;
              final settings = size.width < 600
                  ? find.byKey(const ValueKey('bottom-settings'))
                  : find.text('Settings');
              await tester.tap(settings);
              await tester.pumpAndSettle();
              expect(find.byType(SettingsMenuScreen), findsOneWidget);
              expect(find.text('Search'), findsNothing);
              expect(find.text('Refresh playlists'), findsNothing);
              expect(find.text('Playlists & guide'), findsOneWidget);
              expect(playback.currentChannel, channel);
              if (size.width < 600) {
                await tester.tap(find.byKey(const ValueKey('bottom-sports')));
                await settleSports(tester);
                expect(find.byType(SportsScreen), findsOneWidget);
                await tester.tap(find.byKey(const ValueKey('bottom-settings')));
                await settleSports(tester);
                expect(find.byType(SettingsMenuScreen), findsOneWidget);
                await tester.tap(find.byKey(const ValueKey('bottom-live')));
              } else {
                await tester.pageBack();
              }
              await settleSports(tester);
              expect(find.byType(SettingsMenuScreen), findsNothing);
              expect(find.byType(SportsScreen), findsNothing);
              expect(playback.currentChannel, channel);
              expect(playback.played.length, count);
              expect(tester.takeException(), isNull);
              await tester.pumpWidget(const SizedBox());
              SportsChannelMatcher.disposeShared();
              viewers.dispose();
              playback.dispose();
              playlist.dispose();
              epg.dispose();
              prefs.dispose();
            },
                () => MockClient(
                    (_) async => http.Response('{"events":[]}', 200))));
  }
  for (final (clock, label, expected) in [
    (DateTime(2026, 4, 5, 12), 'Tomorrow', DateTime(2026, 4, 6)),
    (DateTime(2026, 10, 5, 12), 'Yesterday', DateTime(2026, 10, 4)),
  ]) {
    testWidgets(
        'sports day picker follows calendar dates across DST: $label from $clock',
        (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({'sports_online_extras': false});
      final storage = StorageService();
      await storage.init();
      await storage.setSportsAddedLeagues(['nhl']);
      await storage.setSportsLeagues(['nhl']);
      await storage.setSportsChannelFilter('all');
      final prefs = AppPreferences(storage);
      await prefs.init();
      prefs.isTelevision = false;
      final playlist = _Playlist(storage, CatalogDatabase());
      final playback = _Playback(storage, playlist);
      final epg = _Epg(storage);
      final scores = _CalendarScores();
      final viewers = ViewerProfileService(storage, playlist, playback);
      await tester.pumpWidget(MultiProvider(
          providers: [
            Provider.value(value: storage),
            ChangeNotifierProvider.value(value: prefs),
            ChangeNotifierProvider<PlaylistManager>.value(value: playlist),
            ChangeNotifierProvider<PlaybackService>.value(value: playback),
            ChangeNotifierProvider<EpgService>.value(value: epg),
            ChangeNotifierProvider.value(value: viewers),
          ],
          child: MaterialApp(
              theme: buildAppTheme(prefs.palette),
              navigatorObservers: [appRouteObserver],
              home: SportsScreen(scores: scores, clock: () => clock))));
      await tester.pump(const Duration(milliseconds: 200));
      await tester.tap(find.text('Today'));
      await tester.pump(const Duration(milliseconds: 200));
      if (clock.month == 4) {
        expect(find.text('Tue 7 Apr'), findsOneWidget,
            reason: 'dated labels use the same calendar as requested events');
      }
      await tester.tap(find.text(label));
      await tester.pump(const Duration(milliseconds: 200));
      expect(scores.days.last, expected);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      SportsChannelMatcher.disposeShared();
      viewers.dispose();
      playback.dispose();
      playlist.dispose();
      epg.dispose();
      prefs.dispose();
    });
  }

  for (final initialFailure in [true, false]) {
    testWidgets(
        'unexpected scores failure retains events and permits retry, initial=$initialFailure',
        (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({'sports_online_extras': false});
      final storage = StorageService();
      await storage.init();
      await storage.setSportsAddedLeagues(['nhl']);
      await storage.setSportsLeagues(['nhl']);
      await storage.setSportsChannelFilter('all');
      final prefs = AppPreferences(storage);
      await prefs.init();
      prefs.isTelevision = false;
      final playlist = _Playlist(storage, CatalogDatabase());
      final playback = _Playback(storage, playlist);
      final epg = _Epg(storage);
      final scores = _RecoveringScores();
      final viewers = ViewerProfileService(storage, playlist, playback);
      await tester.pumpWidget(MultiProvider(
          providers: [
            Provider.value(value: storage),
            ChangeNotifierProvider.value(value: prefs),
            ChangeNotifierProvider<PlaylistManager>.value(value: playlist),
            ChangeNotifierProvider<PlaybackService>.value(value: playback),
            ChangeNotifierProvider<EpgService>.value(value: epg),
            ChangeNotifierProvider.value(value: viewers),
          ],
          child: MaterialApp(
              theme: buildAppTheme(prefs.palette),
              navigatorObservers: [appRouteObserver],
              home: SportsScreen(scores: scores))));
      Future<void> flush() async {
        for (var i = 0; i < 20; i++) {
          await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 10)));
          await tester.pump(const Duration(milliseconds: 10));
        }
      }

      final refresh = find.byKey(const ValueKey('sports-refresh'));
      await scores.firstBatch();
      await flush();
      if (!initialFailure) {
        scores.done.complete(scores.batch);
        await flush();
        await tester.tap(refresh);
        await tester.pump();
      }
      expect(tester.widget<IconButton>(refresh).onPressed, isNotNull,
          reason: 'A busy refresh stays focusable on TV');
      final pendingCalls = scores.retries.length;
      await tester.tap(refresh);
      await tester.pump();
      expect(scores.retries.length, pendingCalls,
          reason: 'Activating a busy refresh does not start another request');
      (initialFailure ? scores.done : scores.retries.last)
          .completeError(StateError('simulated unexpected feed failure'));
      await flush();
      expect(find.byKey(const ValueKey('card-nhl:poll-0')), findsOneWidget);
      expect(tester.widget<IconButton>(refresh).onPressed, isNotNull);
      expect(tester.takeException(), isNull);
      await tester.tap(refresh);
      await tester.pump();
      scores.retries.last.complete(scores.batch);
      await flush();
      expect(tester.widget<IconButton>(refresh).onPressed, isNotNull);
      expect(find.textContaining('Channels: checked'), findsOneWidget);
      expect(find.byKey(const ValueKey('card-nhl:poll-0')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      SportsChannelMatcher.disposeShared();
      viewers.dispose();
      playback.dispose();
      playlist.dispose();
      epg.dispose();
      prefs.dispose();
    });
  }

  testWidgets(
      'guide warms before scores and matches the first batch while other feeds wait',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({'sports_online_extras': false});
    final storage = StorageService();
    await storage.init();
    await storage.setSportsAddedLeagues(['nhl']);
    await storage.setSportsLeagues(['nhl']);
    await storage.setSportsChannelFilter('all');
    final prefs = AppPreferences(storage);
    await prefs.init();
    prefs.isTelevision = false;
    final playlist = _Playlist(storage, CatalogDatabase());
    final playback = _Playback(storage, playlist);
    final epg = _WarmGuide(storage);
    final scores = _HeldScores();
    final viewers = ViewerProfileService(storage, playlist, playback);
    await tester.pumpWidget(MultiProvider(
        providers: [
          Provider.value(value: storage),
          ChangeNotifierProvider.value(value: prefs),
          ChangeNotifierProvider<PlaylistManager>.value(value: playlist),
          ChangeNotifierProvider<PlaybackService>.value(value: playback),
          ChangeNotifierProvider<EpgService>.value(value: epg),
          ChangeNotifierProvider.value(value: viewers),
        ],
        child: MaterialApp(
            theme: buildAppTheme(prefs.palette),
            navigatorObservers: [appRouteObserver],
            home: SportsScreen(scores: scores))));
    Future<void> flush() async {
      for (var i = 0; i < 15; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)));
        await tester.pump(const Duration(milliseconds: 10));
      }
    }

    await flush();
    expect(scores.done.isCompleted, false);
    expect(epg.reads, greaterThan(0),
        reason: 'guide cache loads before the first score feed');
    expect(epg.requests, isEmpty, reason: 'no speculative programme queries');
    final reads = epg.reads;
    await scores.firstBatch();
    await flush();
    expect(scores.done.isCompleted, false);
    expect(epg.requests, hasLength(1),
        reason: 'event guide search overlaps remaining score feeds');
    expect(epg.reads, reads,
        reason: 'the event search reuses the prepared guide');
    epg.requests.single.complete([]);
    await flush();
    expect(find.textContaining('Channels: checked'), findsNothing,
        reason: 'the score feed is still visibly loading');
    expect(find.byKey(const ValueKey('card-nhl:poll-0')), findsOneWidget);
    scores.done.complete(scores.batch);
    await flush();
    expect(epg.requests, hasLength(1),
        reason: 'finishing scores does not repeat matching');
    expect(find.textContaining('Channels: checked'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    SportsChannelMatcher.disposeShared();
    viewers.dispose();
    playback.dispose();
    playlist.dispose();
    epg.dispose();
    prefs.dispose();
  });

  testWidgets(
      'late sport rows slot alphabetically without losing focused event',
      (tester) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({'sports_online_extras': false});
    final storage = StorageService();
    await storage.init();
    await storage.setSportsAddedLeagues(['nhl', 'nba', 'tennis.atp']);
    await storage.setSportsLeagues(['nhl', 'nba', 'tennis.atp']);
    await storage.setSportsChannelFilter('all');
    final prefs = AppPreferences(storage);
    await prefs.init();
    prefs.isTelevision = true;
    final playlist = _Playlist(storage, CatalogDatabase());
    playlist.fixtureChannels
      ..clear()
      ..add(Channel(
          id: 'weather',
          rawId: 'weather',
          playlistId: 'demo',
          name: 'Weather',
          group: 'News',
          epgIdOverride: 'weather',
          url: 'https://example.invalid/never-play'));
    final playback = _Playback(storage, playlist);
    final epg = _WarmGuide(storage);
    final scores = _HeldScores();
    final viewers = ViewerProfileService(storage, playlist, playback);
    await tester.pumpWidget(MultiProvider(
        providers: [
          Provider.value(value: storage),
          ChangeNotifierProvider.value(value: prefs),
          ChangeNotifierProvider<PlaylistManager>.value(value: playlist),
          ChangeNotifierProvider<PlaybackService>.value(value: playback),
          ChangeNotifierProvider<EpgService>.value(value: epg),
          ChangeNotifierProvider.value(value: viewers),
        ],
        child: MaterialApp(
            theme: buildAppTheme(prefs.palette),
            navigatorObservers: [appRouteObserver],
            home: SportsScreen(scores: scores))));
    Future<void> flush() async {
      for (var i = 0; i < 15; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)));
        await tester.pump(const Duration(milliseconds: 10));
      }
    }

    await flush();
    final now = DateTime.now();
    SportsGame event(String league, {bool soon = false}) => SportsGame(
        id: league,
        league: sportsLeagueById(league)!,
        start: now.add(Duration(minutes: soon ? 15 : 0)),
        state: soon ? GameState.pre : GameState.live,
        statusText: soon ? 'Soon' : 'Live',
        home: const SportsTeam(
            id: 'a', name: 'Alpha', shortName: 'Alpha', abbreviation: 'A'),
        away: const SportsTeam(
            id: 'b', name: 'Beta', shortName: 'Beta', abbreviation: 'B'));
    final tennis = event('tennis.atp');
    scores.batch = [tennis];
    scores.publish!(scores.batch);
    await flush();
    final card = find.byKey(const ValueKey('card-tennis.atp:tennis.atp'));
    expect(card, findsOneWidget);
    final dynamic widget = tester.widget(card);
    (widget.focusNode as FocusNode).requestFocus();
    await tester.pump();
    scores.batch = [tennis, event('nhl'), event('nba', soon: true)];
    scores.publish!(scores.batch);
    await flush();
    final basketball = find.byKey(const ValueKey('sport-heading:basketball'));
    final hockey = find.byKey(const ValueKey('sport-heading:hockey'));
    final tennisHeading = find.byKey(const ValueKey('sport-heading:tennis'));
    expect(tester.getTopLeft(basketball).dy,
        lessThan(tester.getTopLeft(hockey).dy));
    expect(tester.getTopLeft(hockey).dy,
        lessThan(tester.getTopLeft(tennisHeading).dy));
    expect((widget.focusNode as FocusNode).hasFocus, true);
    epg.requests.first.complete([]);
    scores.done.complete(scores.batch);
    await flush();
    expect(tester.getTopLeft(basketball).dy,
        lessThan(tester.getTopLeft(tennisHeading).dy));
    expect((widget.focusNode as FocusNode).hasFocus, true);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    SportsChannelMatcher.disposeShared();
    viewers.dispose();
    playback.dispose();
    playlist.dispose();
    epg.dispose();
    prefs.dispose();
  });

  testWidgets(
      'possible events appear before matching, then unmatched cards leave safely on TV',
      (tester) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({'sports_online_extras': false});
    final storage = StorageService();
    await storage.init();
    await storage.setSportsAddedLeagues(['nhl']);
    await storage.setSportsLeagues(['nhl']);
    await storage.setSportsChannelFilter('possible');
    final prefs = AppPreferences(storage);
    await prefs.init();
    prefs.isTelevision = true;
    final playlist = _Playlist(storage, CatalogDatabase());
    playlist.fixtureChannels
      ..clear()
      ..add(Channel(
          id: 'weather',
          rawId: 'weather',
          playlistId: 'demo',
          name: 'Weather',
          group: 'News',
          epgIdOverride: 'weather',
          url: 'https://example.invalid/never-play'));
    final playback = _Playback(storage, playlist);
    final epg = _WarmGuide(storage);
    final scores = _HeldScores();
    final viewers = ViewerProfileService(storage, playlist, playback);
    await tester.pumpWidget(MultiProvider(
        providers: [
          Provider.value(value: storage),
          ChangeNotifierProvider.value(value: prefs),
          ChangeNotifierProvider<PlaylistManager>.value(value: playlist),
          ChangeNotifierProvider<PlaybackService>.value(value: playback),
          ChangeNotifierProvider<EpgService>.value(value: epg),
          ChangeNotifierProvider.value(value: viewers),
        ],
        child: MaterialApp(
            theme: buildAppTheme(prefs.palette),
            navigatorObservers: [appRouteObserver],
            home: SportsScreen(scores: scores))));
    Future<void> flush() async {
      for (var i = 0; i < 15; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)));
        await tester.pump(const Duration(milliseconds: 10));
      }
    }

    await flush();
    expect(scores.done.isCompleted, false);
    expect(epg.reads, greaterThan(0),
        reason: 'guide cache loads before the first score feed');
    expect(epg.requests, isEmpty, reason: 'no speculative programme queries');
    final reads = epg.reads;
    await scores.firstBatch();
    await flush();
    expect(scores.done.isCompleted, false);
    expect(epg.requests, hasLength(1),
        reason: 'event guide search overlaps remaining score feeds');
    expect(epg.reads, reads,
        reason: 'the event search reuses the prepared guide');
    final card = find.byKey(const ValueKey('card-nhl:poll-0'));
    expect(card, findsOneWidget,
        reason: 'Scores are usable before guide search finishes');
    expect(find.text('Waiting for guide'), findsWidgets);
    final dynamic cardWidget = tester.widget(card);
    (cardWidget.focusNode as FocusNode).requestFocus();
    await tester.pump();
    expect(FocusManager.instance.primaryFocus?.debugLabel,
        'sports-card-nhl:poll-0');
    epg.requests.single.complete([]);
    await flush();
    expect(find.textContaining('Channels: checked'), findsNothing,
        reason: 'the score feed is still visibly loading');
    expect(card, findsNothing,
        reason: 'A completed empty result removes the pending card');
    expect(FocusManager.instance.primaryFocus?.debugLabel,
        startsWith('sports-chip-'));
    scores.done.complete(scores.batch);
    await flush();
    expect(epg.requests, hasLength(1),
        reason: 'finishing scores does not repeat matching');
    expect(find.textContaining('Channels: checked'), findsOneWidget);
    expect(card, findsNothing,
        reason: 'Finishing scores must not resurrect unmatched cards');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    SportsChannelMatcher.disposeShared();
    viewers.dispose();
    playback.dispose();
    playlist.dispose();
    epg.dispose();
    prefs.dispose();
  });

  testWidgets(
      'slow channel checks survive score polls and publish completed events',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({'sports_online_extras': false});
    final storage = StorageService();
    await storage.init();
    await storage.setSportsAddedLeagues(['nhl']);
    await storage.setSportsLeagues(['nhl']);
    await storage.setSportsChannelFilter('all');
    final prefs = AppPreferences(storage);
    await prefs.init();
    prefs.isTelevision = false;
    final playlist = _Playlist(storage, CatalogDatabase());
    final playback = _Playback(storage, playlist);
    final epg = _SlowGuide(storage);
    final scores = _PollingScores();
    final viewers = ViewerProfileService(storage, playlist, playback);
    await tester.pumpWidget(MultiProvider(
        providers: [
          Provider.value(value: storage),
          ChangeNotifierProvider.value(value: prefs),
          ChangeNotifierProvider<PlaylistManager>.value(value: playlist),
          ChangeNotifierProvider<PlaybackService>.value(value: playback),
          ChangeNotifierProvider<EpgService>.value(value: epg),
          ChangeNotifierProvider.value(value: viewers),
        ],
        child: MaterialApp(
            theme: buildAppTheme(prefs.palette),
            navigatorObservers: [appRouteObserver],
            home: SportsScreen(scores: scores))));
    Future<void> flush() async {
      for (var i = 0; i < 15; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)));
        await tester.pump(const Duration(milliseconds: 10));
      }
    }

    await flush();
    expect(epg.requests, hasLength(1));
    await tester.pump(const Duration(seconds: 31));
    await flush();
    expect(scores.calls, 2);
    expect(epg.requests, hasLength(1),
        reason: 'poll must share the running search');
    epg.requests.first.complete([]);
    await flush();
    expect(epg.requests, hasLength(2));
    expect(
        find.byWidgetPredicate((w) =>
            w is Tooltip &&
            (w.message?.contains(
                    '216 of 217 events have completed channel checks') ??
                false)),
        findsOneWidget,
        reason:
            'completed work remains visible while the newly added event is checked');
    epg.requests.last.complete([]);
    await flush();
    expect(find.textContaining('Channels: checked'), findsOneWidget);
    await tester.pump(const Duration(seconds: 31));
    await flush();
    expect(epg.requests, hasLength(2),
        reason: 'score-only updates reuse channel results');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    SportsChannelMatcher.disposeShared();
    viewers.dispose();
    playback.dispose();
    playlist.dispose();
    epg.dispose();
    prefs.dispose();
  });

  testWidgets('recycled sport rows restore only their own horizontal offset',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({'sports_online_extras': false});
    final storage = StorageService();
    await storage.init();
    final leagues = <String, SportsLeague>{};
    for (final league in [...kSportsLeagues, ...kSportsLeagueBank]) {
      leagues.putIfAbsent(league.espnPath.split('/').first, () => league);
    }
    final selected = leagues.values.map((l) => l.id).toList();
    await storage.setSportsAddedLeagues(selected);
    await storage.setSportsLeagues(selected);
    await storage.setSportsChannelFilter('all');
    final prefs = AppPreferences(storage);
    await prefs.init();
    prefs.isTelevision = false;
    final playlist = _Playlist(storage, CatalogDatabase());
    final playback = _Playback(storage, playlist);
    final epg = _Epg(storage);
    final viewers = ViewerProfileService(storage, playlist, playback);
    await tester.pumpWidget(MultiProvider(
        providers: [
          Provider.value(value: storage),
          ChangeNotifierProvider.value(value: prefs),
          ChangeNotifierProvider<PlaylistManager>.value(value: playlist),
          ChangeNotifierProvider<PlaybackService>.value(value: playback),
          ChangeNotifierProvider<EpgService>.value(value: epg),
          ChangeNotifierProvider.value(value: viewers),
        ],
        child: MaterialApp(
            theme: buildAppTheme(prefs.palette),
            navigatorObservers: [appRouteObserver],
            home: SportsScreen(scores: _RowScores()))));
    await settleSports(tester);
    final rows = find.byWidgetPredicate(
        (w) => w is ListView && w.scrollDirection == Axis.horizontal);
    expect(rows.evaluate().length, greaterThanOrEqualTo(2));
    final first = tester.widget<ListView>(rows.at(0)).controller!;
    final second = tester.widget<ListView>(rows.at(1)).controller!;
    final outer = tester
        .widget<CustomScrollView>(
            find.byKey(const PageStorageKey('sports-events')))
        .controller!;
    expect(first.offset, 0);
    second.jumpTo(400);
    await tester.pump();
    for (var trip = 0; trip < 3; trip++) {
      outer.jumpTo(outer.position.maxScrollExtent);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(first.hasClients, false,
          reason: 'The actual phone list must recycle its offscreen rows');
      expect(second.hasClients, false);
      // Rebuild the first rows while the page is still partly scrolled.
      outer.jumpTo(200);
      await tester.pump();
      expect(first.offset, 0, reason: 'Untouched row must remain at the start');
      expect(second.offset, 400,
          reason: 'Each row must restore its own position, not another row');
      outer.jumpTo(0);
      await tester.pump(const Duration(milliseconds: 300));
      expect(first.offset, 0, reason: 'No delayed horizontal correction');
      expect(second.offset, 400);
    }
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    SportsChannelMatcher.disposeShared();
    viewers.dispose();
    playback.dispose();
    playlist.dispose();
    epg.dispose();
    prefs.dispose();
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  for (final tv in [false, true]) {
    testWidgets(
        'reopening Sports and multiview selection reuses completed matches ${tv ? "TV" : "phone"}',
        (tester) async {
      tester.view.physicalSize =
          tv ? const Size(1280, 720) : const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({'sports_online_extras': false});
      final storage = StorageService();
      await storage.init();
      await storage.setSportsLeagues(['nhl']);
      await storage.setSportsChannelFilter('matched');
      final prefs = AppPreferences(storage);
      await prefs.init();
      prefs.isTelevision = tv;
      final playlist = _Playlist(storage, CatalogDatabase());
      final playback = _Playback(storage, playlist);
      final epg = _SlowGuide(storage);
      final scores = _ReopenScores();
      final now = DateTime.now();
      playlist.fixtureChannels
        ..clear()
        ..addAll([
          for (var i = 0; i < 24; i++)
            Channel(
                id: 'feed-$i',
                rawId: 'feed-$i',
                playlistId: 'demo',
                name: 'Event feed $i',
                group: 'Sports',
                url: 'https://example.invalid')
        ]);
      final viewers = ViewerProfileService(storage, playlist, playback);
      final nav = GlobalKey<NavigatorState>();
      await tester.pumpWidget(MultiProvider(
          providers: [
            Provider.value(value: storage),
            ChangeNotifierProvider.value(value: prefs),
            ChangeNotifierProvider<PlaylistManager>.value(value: playlist),
            ChangeNotifierProvider<PlaybackService>.value(value: playback),
            ChangeNotifierProvider<EpgService>.value(value: epg),
            ChangeNotifierProvider.value(value: viewers),
          ],
          child: MaterialApp(
              navigatorKey: nav,
              theme: buildAppTheme(prefs.palette),
              navigatorObservers: [appRouteObserver],
              home: const Scaffold())));
      void open({bool picker = false}) {
        unawaited(nav.currentState!.push(PageRouteBuilder<void>(
            transitionDuration: Duration.zero,
            reverseTransitionDuration: Duration.zero,
            pageBuilder: (_, __, ___) => SportsScreen(
                scores: scores,
                clock: () => now,
                onChooseChannel: picker ? (_) async {} : null,
                selectionTitle: picker ? 'Sports · screen 2' : null))));
      }

      Future<void> flush() async {
        for (var i = 0; i < 25; i++) {
          await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 10)));
          await tester.pump(const Duration(milliseconds: 10));
        }
      }

      final card = find.byKey(const ValueKey('card-nhl:browse-0'));
      open();
      await flush();
      expect(epg.requests, hasLength(1));
      epg.requests.first.complete(scores.rows());
      await flush();
      expect(card, findsOneWidget);
      final loads = playlist.catalogueLoads;
      for (final picker in [false, true]) {
        nav.currentState!.pop();
        await tester.pump();
        expect(find.byType(SportsScreen), findsNothing);
        scores.pending = Completer<List<SportsGame>>();
        open(picker: picker);
        await tester.pump();
        expect(card, findsOneWidget,
            reason:
                'Known matches visible on the first frame before scores return');
        final dynamic restored = tester.widget(card);
        expect((restored.match as ChannelMatch).isConfident, true);
        await flush();
        expect(epg.requests, hasLength(1),
            reason: 'No repeated guide query on a warm visit');
        expect(playlist.catalogueLoads, loads,
            reason: 'No repeated catalogue preparation');
        scores.pending!.complete(scores.cached);
        await flush();
        scores.pending = null;
      }
      nav.currentState!.pop();
      await tester.pump();
      epg.notifyListeners(); // Real guide updates invalidate a saved match snapshot.
      open(picker: true);
      await tester.pump();
      expect(card, findsNothing);
      await flush();
      expect(epg.requests, hasLength(2));
      epg.notifyListeners(); // Another guide revision while matching is in flight.
      epg.requests.last.complete(scores.rows());
      await flush();
      expect(card, findsNothing,
          reason: 'An obsolete guide reply cannot become a completed match');
      expect(epg.requests, hasLength(3));
      epg.requests.last.complete(scores.rows());
      await flush();
      expect(card, findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      SportsChannelMatcher.disposeShared();
      viewers.dispose();
      playback.dispose();
      playlist.dispose();
      epg.dispose();
      prefs.dispose();
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));
  }

  for (final tv in [false, true]) {
    testWidgets(
        'background matching preserves browsing position on ${tv ? "TV" : "phone"}',
        (tester) async {
      tester.view.physicalSize =
          tv ? const Size(1280, 720) : const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({'sports_online_extras': false});
      final storage = StorageService();
      await storage.init();
      await storage.setSportsAddedLeagues(['nhl']);
      await storage.setSportsLeagues(['nhl']);
      await storage.setSportsChannelFilter('matched');
      final prefs = AppPreferences(storage);
      await prefs.init();
      prefs.isTelevision = tv;
      final playlist = _Playlist(storage, CatalogDatabase());
      final playback = _Playback(storage, playlist);
      final epg = _SlowGuide(storage);
      final scores = _BrowseScores();
      var now = DateTime.now();
      playlist.fixtureChannels
        ..clear()
        ..addAll([
          for (var i = 0; i < 24; i++)
            Channel(
                id: 'feed-$i',
                rawId: 'feed-$i',
                playlistId: 'demo',
                name: 'Event feed $i',
                group: 'Sports',
                url: 'https://example.invalid')
        ]);
      final viewers = ViewerProfileService(storage, playlist, playback);
      await tester.pumpWidget(MultiProvider(
          providers: [
            Provider.value(value: storage),
            ChangeNotifierProvider.value(value: prefs),
            ChangeNotifierProvider<PlaylistManager>.value(value: playlist),
            ChangeNotifierProvider<PlaybackService>.value(value: playback),
            ChangeNotifierProvider<EpgService>.value(value: epg),
            ChangeNotifierProvider.value(value: viewers),
          ],
          child: MaterialApp(
              theme: buildAppTheme(prefs.palette),
              navigatorObservers: [appRouteObserver],
              home: SportsScreen(scores: scores, clock: () => now))));
      Future<void> flush() async {
        for (var i = 0; i < 20; i++) {
          await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 10)));
          await tester.pump(const Duration(milliseconds: 10));
        }
      }

      await flush();
      expect(epg.requests, hasLength(1));
      expect(find.byKey(const ValueKey('card-nhl:browse-0')), findsNothing,
          reason: 'With channel does not admit unchecked events');
      epg.requests.first.complete(scores.rows());
      await flush();
      if (!tv) {
        await tester.tap(find.byKey(const ValueKey('sport-heading:hockey')));
        await tester.pump();
      }
      final viewport = find.byKey(const PageStorageKey('sports-events'));
      final scrollTop = tester.getTopLeft(viewport).dy;
      final statusSlot = find.byKey(const ValueKey('sports-status-slot'));
      expect(tester.getSize(statusSlot).height, 38);
      final target = tv
          ? find
              .byWidgetPredicate(
                  (w) => w is ListView && w.scrollDirection == Axis.horizontal)
              .last
          : viewport;
      await tester.drag(
          target, tv ? const Offset(-1800, 0) : const Offset(0, -900));
      await tester.pump(const Duration(seconds: 1));
      final controller = tv
          ? tester.widget<ListView>(target).controller!
          : tester.widget<CustomScrollView>(viewport).controller!;
      final offset = controller.offset;
      expect(offset, greaterThan(100));
      final cards = find.byWidgetPredicate((w) =>
          w.key is ValueKey<String> &&
          (w.key as ValueKey<String>).value.startsWith('card-nhl:'));
      final anchor = cards
          .evaluate()
          .firstWhere((element) {
            final box = element.renderObject as RenderBox;
            final p = box.localToGlobal(Offset.zero);
            return tv
                ? p.dx >= 20 && p.dx < 900
                : p.dy >= scrollTop && p.dy < 700;
          })
          .widget
          .key!;
      final anchorFinder = find.byKey(anchor);
      if (tv) {
        final dynamic card = tester.widget(anchorFinder);
        (card.focusNode as FocusNode).requestFocus();
        await tester.pump(const Duration(milliseconds: 400));
      }
      final anchorPosition = tester.getTopLeft(anchorFinder);
      final settledOffset = controller.offset;
      // Invalidate the guide and refresh. The completed match stays visible
      // while the query is pending, then real removals above us are anchored.
      final sportsState = tester.state(find.byType(SportsScreen));
      final navigator = Navigator.of(tester.element(find.byType(SportsScreen)));
      unawaited(navigator.push(PageRouteBuilder<void>(
          transitionDuration: Duration.zero,
          reverseTransitionDuration: Duration.zero,
          pageBuilder: (_, __, ___) =>
              const Scaffold(body: Text('Floating player')))));
      await tester.pump(const Duration(milliseconds: 400));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      now = now.add(const Duration(minutes: 6));
      await tester.pump(const Duration(minutes: 6));
      epg.notifyListeners();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      navigator.pop();
      await tester.pump(const Duration(milliseconds: 400));
      expect(tester.state(find.byType(SportsScreen)), same(sportsState));
      await flush();
      expect(epg.requests, hasLength(2));
      expect(find.textContaining('Channels: guide scan'), findsOneWidget);
      expect(tester.getSize(statusSlot).height, 38);
      expect(
          find.descendant(
              of: statusSlot, matching: find.byType(LinearProgressIndicator)),
          findsNothing);
      expect(
          find.descendant(
              of: statusSlot, matching: find.byType(CircularProgressIndicator)),
          findsNothing);
      expect(tester.getTopLeft(anchorFinder), anchorPosition);
      final dynamic retainedCard = tester.widget(anchorFinder);
      expect((retainedCard.match as ChannelMatch).isConfident, true);
      expect(
          find.descendant(
              of: anchorFinder, matching: find.byType(SportsEventMatchStatus)),
          findsNothing,
          reason:
              'Usable channels keep their programme details during a recheck');
      expect(
          find.descendant(
              of: anchorFinder, matching: find.byType(ChannelNowLabel)),
          findsOneWidget);
      expect((retainedCard.game as SportsGame).home.score, '2');
      epg.requests.last.complete(scores.rows(from: 3));
      await flush();
      expect(controller.offset, lessThan(settledOffset));
      expect(tester.getTopLeft(viewport).dy, scrollTop);
      expect(tester.getTopLeft(anchorFinder), anchorPosition);
      expect(find.byKey(const ValueKey('card-nhl:browse-0')), findsNothing);
      expect(find.byKey(const ValueKey('sports-apply-updates')), findsNothing);
      for (final element in cards.evaluate()) {
        final dynamic card = element.widget;
        expect((card.match as ChannelMatch).isConfident, true);
      }
      if (tv) {
        final dynamic card = tester.widget(anchorFinder);
        // Refresh button was tapped, so explicitly restore remote browsing.
        (card.focusNode as FocusNode).requestFocus();
        await tester.pump();
      }
      // A database failure is not a successful empty match result.
      epg.notifyListeners();
      await tester.tap(find.byKey(const ValueKey('sports-refresh')));
      await flush();
      expect(epg.requests, hasLength(3));
      epg.requests.last.completeError(StateError('simulated guide failure'));
      await flush();
      final dynamic keptAfterFailure = tester.widget(anchorFinder);
      expect((keptAfterFailure.match as ChannelMatch).isConfident, true);
      expect(find.textContaining('Channels: check failed'), findsOneWidget,
          reason: tester
              .widget<Text>(find.byKey(const ValueKey('sports-load-status')))
              .data);
      expect(tester.getTopLeft(anchorFinder), anchorPosition);
      // Retry the failed lookup without a guide revision. The failed future
      // must have left the query cache. Remove the focused card this time.
      await tester.tap(find.byKey(const ValueKey('sports-refresh')));
      await flush();
      expect(epg.requests, hasLength(4));
      final anchorId = (anchor as ValueKey<String>).value.split('browse-').last;
      if (tv) {
        final dynamic card = tester.widget(anchorFinder);
        (card.focusNode as FocusNode).requestFocus();
        await tester.pump();
      }
      epg.requests.last.complete(scores
          .rows(from: 3)
          .where((p) => p.channelId != 'feed-$anchorId')
          .toList());
      await flush();
      expect(anchorFinder, findsNothing);
      if (tv) {
        expect(FocusManager.instance.primaryFocus?.debugLabel,
            'sports-card-nhl:browse-${int.parse(anchorId) + 1}');
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      SportsChannelMatcher.disposeShared();
      viewers.dispose();
      playback.dispose();
      playlist.dispose();
      epg.dispose();
      prefs.dispose();
    });
  }

  testWidgets(
      'nonempty supplemental events settle without an enrichment/rematch loop',
      (tester) async {
    await http.runWithClient(() async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({'sports_online_extras': true});
      final storage = StorageService();
      await storage.init();
      await storage.setSportsAddedLeagues(['tennis.atp']);
      await storage.setSportsLeagues(['tennis.atp']);
      await storage.setSportsChannelFilter('all');
      final prefs = AppPreferences(storage);
      await prefs.init();
      prefs.isTelevision = false;
      final playlist = _Playlist(storage, CatalogDatabase());
      final playback = _Playback(storage, playlist);
      final epg = _Epg(storage);
      final viewers = ViewerProfileService(storage, playlist, playback);
      final supplement = _Supplement();
      await tester.pumpWidget(MultiProvider(
          providers: [
            Provider.value(value: storage),
            ChangeNotifierProvider.value(value: prefs),
            ChangeNotifierProvider<PlaylistManager>.value(value: playlist),
            ChangeNotifierProvider<PlaybackService>.value(value: playback),
            ChangeNotifierProvider<EpgService>.value(value: epg),
            ChangeNotifierProvider.value(value: viewers),
          ],
          child: MaterialApp(
              theme: buildAppTheme(prefs.palette),
              navigatorObservers: [appRouteObserver],
              home: SportsScreen(
                  supplement: supplement,
                  scores: SportsService.withClient(
                      MockClient((_) async => _tennisFixture()))))));
      for (var i = 0; i < 20; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(supplement.loads, greaterThan(0));
      expect(supplement.warms, lessThanOrEqualTo(2));
      final warmCount = supplement.warms;
      for (var i = 0; i < 20; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)));
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(supplement.warms, warmCount);
      expect(find.byKey(const ValueKey('tennis-tournament-extra-demo')),
          findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      SportsChannelMatcher.disposeShared();
      await tester.pump(const Duration(seconds: 31));
      viewers.dispose();
      playback.dispose();
      playlist.dispose();
      epg.dispose();
      prefs.dispose();
    }, () => MockClient((_) async => _tennisFixture()));
  });
  testWidgets(
      'mobile landscape uses compact columns and guide rows without overflow',
      (tester) async {
    tester.view.physicalSize = const Size(844, 390);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({'sports_online_extras': false});
    final storage = StorageService();
    await storage.init();
    final prefs = AppPreferences(storage);
    await prefs.init();
    prefs.isTelevision = false;
    final playlist = _Playlist(storage, CatalogDatabase());
    final playback = _Playback(storage, playlist);
    final epg = _Epg(storage);
    final viewers = ViewerProfileService(storage, playlist, playback);
    final capture = GlobalKey();
    await tester.pumpWidget(MultiProvider(
        providers: [
          Provider.value(value: storage),
          ChangeNotifierProvider.value(value: prefs),
          ChangeNotifierProvider<PlaylistManager>.value(value: playlist),
          ChangeNotifierProvider<PlaybackService>.value(value: playback),
          ChangeNotifierProvider<EpgService>.value(value: epg),
          ChangeNotifierProvider.value(value: viewers),
        ],
        child: MaterialApp(
            theme: buildAppTheme(prefs.palette),
            navigatorObservers: [appRouteObserver],
            home: RepaintBoundary(key: capture, child: const TvHomeScreen()))));
    await tester.pump(const Duration(milliseconds: 300));
    final labels = find.byKey(const ValueKey('guide-channel-scroll'));
    expect(tester.widget<ListView>(labels).itemExtent, 36);
    expect(
        tester.getSize(find.byKey(const ValueKey('guide-search'))).height, 24);
    expect(tester.getTopLeft(labels).dx, lessThan(365));
    expect(tester.takeException(), isNull);
    if (const bool.fromEnvironment('CAPTURE_LAYOUT')) {
      await tester.runAsync(() async {
        final image = await (capture.currentContext!.findRenderObject()
                as RenderRepaintBoundary)
            .toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('/tmp/iptv-guide-landscape.png')
            .writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }
    playlist.fixtureChannels.add(Channel(
        id: 'demo::other',
        rawId: 'other',
        playlistId: 'demo',
        name: 'Other category channel',
        group: 'Other category',
        url: 'https://example.test/other'));
    playlist.notifyListeners();
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('all-live-channels')));
    await settleSports(tester);
    expect(tester.widget<ListView>(labels).childrenDelegate.estimatedChildCount,
        10);
    await tester.tap(find.byKey(const ValueKey('live-categories-rail')));
    await settleSports(tester);
    await tester.tap(find.text('Australian TV'));
    await settleSports(tester);
    expect(tester.widget<ListView>(labels).childrenDelegate.estimatedChildCount,
        9);
    expect(tester.getTopLeft(labels).dx, lessThan(110));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    SportsChannelMatcher.disposeShared();
    await tester.pump(const Duration(seconds: 5));
    viewers.dispose();
    playback.dispose();
    playlist.dispose();
    epg.dispose();
    prefs.dispose();
  });
  for (final size in [
    const Size(390, 844),
    const Size(844, 390),
    const Size(1280, 720)
  ]) {
    testWidgets('guide sports survive scores and refresh at ${size.width}',
        (tester) async {
      await http.runWithClient(() async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        SharedPreferences.setMockInitialValues({'sports_online_extras': true});
        final storage = StorageService();
        await storage.init();
        await storage.setSportsLeagues(['nhl']);
        const themeId = String.fromEnvironment('LAYOUT_THEME');
        if (themeId.isNotEmpty) await storage.setPaletteId(themeId);
        final prefs = AppPreferences(storage);
        await prefs.init();
        prefs.isTelevision = size.width > 1000;
        final playlist = _Playlist(storage, CatalogDatabase());
        final playback = _Playback(storage, playlist);
        final epg = _Epg(storage);
        final now = DateTime.now();
        epg.replays = [
          EpgProgram(
              channelId: 'Fox Sports',
              title: 'World Poker Tour',
              description:
                  'The final table. The world’s finest poker players compete.',
              start: now.subtract(const Duration(minutes: 20)),
              stop: now.add(const Duration(hours: 1)))
        ];
        final viewers = ViewerProfileService(storage, playlist, playback);
        final pending = Completer<http.Response>();
        var requests = 0;
        var failing = true;
        final supplement = _Supplement();
        await tester.pumpWidget(MultiProvider(
            providers: [
              Provider.value(value: storage),
              ChangeNotifierProvider.value(value: prefs),
              ChangeNotifierProvider<PlaylistManager>.value(value: playlist),
              ChangeNotifierProvider<PlaybackService>.value(value: playback),
              ChangeNotifierProvider<EpgService>.value(value: epg),
              ChangeNotifierProvider.value(value: viewers),
            ],
            child: MaterialApp(
                theme: buildAppTheme(prefs.palette),
                navigatorObservers: [appRouteObserver],
                home: SportsScreen(
                    supplement: supplement,
                    scores: SportsService.withClient(MockClient((_) {
                      requests++;
                      return failing
                          ? pending.future
                          : Future.value(http.Response('{"events":[]}', 200));
                    }))))));
        for (var i = 0; i < 40; i++) {
          await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 10)));
          await tester.pump(const Duration(milliseconds: 20));
        }
        expect(find.text('World Poker Tour'), findsWidgets,
            reason: 'Guide coverage appears before scores finish');
        expect(find.text('On air'), findsOneWidget);
        pending.complete(http.Response('Access denied by event source', 403));
        await settleSports(tester);
        expect(find.text('World Poker Tour'), findsWidgets);
        expect(find.text('Pick a channel'), findsNothing);
        final callsBeforeDetails = requests;
        expect(find.byKey(const ValueKey('sports-feed-info')), findsOneWidget);
        if (prefs.isTelevision) {
          tester
              .widget<IconButton>(find.byKey(const ValueKey('sports-refresh')))
              .focusNode!
              .requestFocus();
          await tester.pump();
          await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
          await tester.pump();
          expect(
              tester
                  .widget<IconButton>(
                      find.byKey(const ValueKey('sports-feed-info')))
                  .focusNode!
                  .hasFocus,
              isTrue);
          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        } else {
          await tester.tap(find.byKey(const ValueKey('sports-feed-info')));
        }
        await tester.pumpAndSettle();
        expect(find.text('Event feed details'), findsOneWidget);
        await tester.tap(find.byType(ExpansionTile).first);
        await tester.pumpAndSettle();
        expect(find.text('Access denied by event source'), findsOneWidget);
        expect(requests, callsBeforeDetails,
            reason: 'Diagnostics must not fetch again');
        await tester.tap(find.byTooltip('Close feed details'));
        await tester.pumpAndSettle();
        failing = false;
        await tester.tap(find.byKey(const ValueKey('sports-refresh')));
        await settleSports(tester);
        expect(find.text('World Poker Tour'), findsWidgets);
        expect(find.text('On air'), findsOneWidget);
        expect(requests, greaterThan(callsBeforeDetails));
        expect(find.byKey(const ValueKey('sports-feed-info')), findsNothing);
        await captureSports(tester, size, 'guide-sports');
        epg.replays = [
          for (final entry in [
            (
              'Fox Sports',
              'NBA: Boston Celtics v New York Knicks (Replay)',
              'Full game replay from 21 October 2026.'
            ),
            (
              'Seven',
              'World Poker Tour Highlights',
              'Highlights from the final table.'
            ),
            (
              'Nine',
              'Tennis: Alcaraz v Sinner (Replay)',
              'Full match replay from 20 October 2026.'
            ),
          ])
            EpgProgram(
                channelId: entry.$1,
                title: entry.$2,
                description: entry.$3,
                start: now.subtract(const Duration(minutes: 20)),
                stop: now.add(const Duration(hours: 1)))
        ];
        epg.notifyListeners();
        final videoBefore =
            tester.getRect(find.byKey(const ValueKey('sports-channel-box')));
        for (final tab in ['replays', 'highlights']) {
          await tester.ensureVisible(find.byKey(ValueKey('sports-view-$tab')));
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(ValueKey('sports-view-$tab')));
          await settleSports(tester);
          final video =
              tester.getRect(find.byKey(const ValueKey('sports-channel-box')));
          final browsing =
              tester.getRect(find.byKey(const ValueKey('replays-scroll')));
          expect(video, videoBefore);
          if (size.width > size.height) {
            expect(browsing.left, greaterThan(video.right));
            expect(browsing.top, closeTo(video.top, .1));
            expect(browsing.height, greaterThan(size.height * .75));
            final footer = tester
                .getRect(find.byKey(const ValueKey('sports-preview-footer')));
            expect(footer.bottom, closeTo(size.height, .1));
            expect(video.width, greaterThan((size.width - 40) * .36));
          } else {
            expect(browsing.top, greaterThan(video.bottom));
          }
          await captureSports(tester, size, 'sports-$tab');
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        SportsChannelMatcher.disposeShared();
        await tester.pump(const Duration(seconds: 31));
        viewers.dispose();
        playback.dispose();
        playlist.dispose();
        epg.dispose();
        prefs.dispose();
      }, () => MockClient((_) async => http.Response('{"events":[]}', 200)));
    });
  }
  var scoreRequests = 0;
  for (final size in [
    const Size(960, 540),
    const Size(1280, 720),
    const Size(390, 844)
  ]) {
    testWidgets(
        'guide and navigation fit ${size.width} x ${size.height}',
        (tester) => http.runWithClient(() async {
              tester.view.physicalSize = size;
              tester.view.devicePixelRatio = 1;
              addTearDown(tester.view.reset);
              SharedPreferences.setMockInitialValues(
                  {'sports_online_extras': false});
              final storage = StorageService();
              await storage.init();
              await storage.setSportsLeagues(['nba', 'nhl', 'nfl']);
              await storage.setSportsChannelFilter('matched');
              // These layout fixtures deliberately reuse one demo channel for
              // several simultaneous games. Explicit picks establish that UI
              // setup; automatic matching must now flag shared feeds uncertain.
              await storage.setSportsChannelPicks(jsonEncode({
                'events': {
                  for (final league in ['nba', 'nhl', 'nfl'])
                    for (var i = 1; i < 5; i++)
                      '$league:$i': {
                        'c': 'demo::Fox Sports',
                        't': DateTime.now().millisecondsSinceEpoch
                      }
                },
                'teams': <String, String>{}
              }));
              const themeId = String.fromEnvironment('LAYOUT_THEME');
              if (themeId.isNotEmpty) await storage.setPaletteId(themeId);
              final prefs = AppPreferences(storage);
              await prefs.init();
              prefs.isTelevision = size.width > 600;
              final playlist = _Playlist(storage, CatalogDatabase());
              final playback = _Playback(storage, playlist);
              final epg = _Epg(storage);
              final viewers = ViewerProfileService(storage, playlist, playback);
              final capture = GlobalKey();
              await tester.pumpWidget(MultiProvider(
                providers: [
                  Provider.value(value: storage),
                  ChangeNotifierProvider.value(value: prefs),
                  ChangeNotifierProvider<PlaylistManager>.value(
                      value: playlist),
                  ChangeNotifierProvider<PlaybackService>.value(
                      value: playback),
                  ChangeNotifierProvider<EpgService>.value(value: epg),
                  ChangeNotifierProvider.value(value: viewers),
                ],
                child: RepaintBoundary(
                    child: MaterialApp(
                        debugShowCheckedModeBanner: false,
                        theme: buildAppTheme(prefs.palette),
                        navigatorObservers: [appRouteObserver],
                        home: RepaintBoundary(
                            key: capture, child: const TvHomeScreen()))),
              ));
              await tester.pump(const Duration(milliseconds: 300));
              expect(find.text('Movies'), findsOneWidget);
              expect(find.text('Series'), findsOneWidget);
              expect(find.text('Media Hub'), findsNothing);
              expect(find.text('Sports'), findsOneWidget);
              expect(find.text('ABC HD'), findsWidgets);
              expect(tester.takeException(), isNull);
              if (size.width > 600) {
                // Live TV -> groups -> programmes; programme navigation stays in grid.
                await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
                await tester.pump(const Duration(milliseconds: 300));
                await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
                await tester.pump(const Duration(milliseconds: 300));
                final first = FocusManager.instance.primaryFocus;
                expect(
                    first?.ancestors
                        .any((node) => node.debugLabel == 'timeline-grid'),
                    isTrue);
                await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
                await tester.pump(const Duration(milliseconds: 300));
                expect(FocusManager.instance.primaryFocus, isNot(first));
                await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
                await tester.pump(const Duration(milliseconds: 300));
                expect(
                    FocusManager.instance.primaryFocus?.ancestors
                        .any((node) => node.debugLabel == 'timeline-grid'),
                    isTrue);
              }
              if (size.width > 600) {
                // Tap the Now shortcut, then use the remote to move across
                // the toolbar and down into the guide again.
                await tester.tap(find.byKey(const ValueKey('guide-now')));
                await tester.pump();
                await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
                await tester.pump();
                await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
                await tester.pump();
                expect(FocusManager.instance.primaryFocus?.debugLabel,
                    'guide-now');
                await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
                await tester.pump();
                expect(
                    FocusManager.instance.primaryFocus?.ancestors
                        .any((n) => n.debugLabel == 'timeline-grid'),
                    isTrue);
              }
              expect(tester.takeException(), isNull);
              await tester.pump(const Duration(milliseconds: 200));
              if (const bool.fromEnvironment('CAPTURE_LAYOUT')) {
                await tester.runAsync(() async {
                  final boundary = capture.currentContext!.findRenderObject()!
                      as RenderRepaintBoundary;
                  final image = await boundary.toImage();
                  final bytes =
                      await image.toByteData(format: ui.ImageByteFormat.png);
                  await File('/tmp/iptv-guide-${size.width.toInt()}.png')
                      .writeAsBytes(bytes!.buffer.asUint8List());
                  image.dispose();
                });
              }
              if (size.width < 600) {
                // Touch scrolling must work on either column, including flings.
                final originalCount = playlist.fixtureChannels.length;
                playlist.fixtureChannels.addAll(List.generate(
                    100,
                    (i) => Channel(
                        id: 'demo::extra$i',
                        rawId: 'extra$i',
                        playlistId: 'demo',
                        name: [0, 30, 70, 98].contains(i)
                            ? '### Section $i ###'
                            : 'Extra $i',
                        group: 'Australian TV',
                        url: 'https://example.test/$i')));
                playlist.notifyListeners();
                await tester.pump(const Duration(milliseconds: 100));
                final labels =
                    find.byKey(const ValueKey('guide-channel-scroll'));
                final programmes =
                    find.byKey(const ValueKey('guide-programme-scroll'));
                ScrollController scroll(Finder finder) =>
                    tester.widget<ListView>(finder).controller!;
                await tester.fling(labels, const Offset(0, -220), 1200);
                await tester.pump(const Duration(milliseconds: 250));
                expect(scroll(labels).offset, greaterThan(150));
                expect(scroll(programmes).offset,
                    closeTo(scroll(labels).offset, .1));
                await tester.pump(const Duration(seconds: 2));
                final beforeGridDrag = scroll(programmes).offset;
                await tester.dragFrom(Offset(300, tester.getCenter(labels).dy),
                    const Offset(0, -150));
                await tester.pump(const Duration(milliseconds: 100));
                expect(scroll(programmes).offset,
                    closeTo(scroll(labels).offset, .1));
                expect(scroll(programmes).offset, greaterThan(beforeGridDrag));
                await playback.play(playlist.fixtureChannels[50]);
                await tester.pump();
                await tester
                    .tap(find.byKey(const ValueKey('guide-playing-channel')));
                await tester.pump();
                await tester.pump();
                expect(scroll(labels).offset, greaterThan(1500));
                expect(
                    find.text(playlist.fixtureChannels[50].name).hitTestable(),
                    findsWidgets);
                final time = find.byKey(const ValueKey('guide-time-scroll'));
                final horizontal =
                    tester.widget<SingleChildScrollView>(time).controller!;
                final now = horizontal.offset;
                horizontal.jumpTo(now + 300);
                await tester.pump();
                await tester.tap(find.byKey(const ValueKey('guide-now')));
                await tester.pump();
                expect(horizontal.offset, closeTo(now, .1));
                // Reopening search must focus the field, not retain focus on its button.
                for (var i = 0; i < 2; i++) {
                  await tester.tap(find.byKey(const ValueKey('guide-search')));
                  await tester.pump();
                  await tester.pump();
                  final field =
                      tester.widget<TextField>(find.byType(TextField));
                  expect(field.focusNode!.hasFocus, true);
                  expect(tester.testTextInput.isVisible, true);
                  await tester.enterText(find.byType(TextField), 'Extra 4');
                  await tester.pump();
                  expect(field.focusNode!.hasFocus, true);
                  await tester.tap(find.byTooltip('Close filter'));
                  await tester.pump();
                }
                // Search current EPG titles/descriptions as well as channel names.
                await tester.tap(find.byKey(const ValueKey('guide-search')));
                await tester.pump();
                await tester.pump();
                await tester.enterText(find.byType(TextField), 'World Today');
                await tester.pump();
                await tester.pump(const Duration(milliseconds: 200));
                await tester.pump();
                expect(
                    tester
                        .widget<ListView>(labels)
                        .childrenDelegate
                        .estimatedChildCount,
                    playlist.fixtureChannels.length - 4);
                await tester.enterText(find.byType(TextField), 'not-a-show');
                await tester.pump();
                await tester.pump(const Duration(milliseconds: 200));
                await tester.pump();
                expect(find.text('No channels found.'), findsOneWidget);
                expect(
                    find.byKey(const ValueKey('guide-search')), findsOneWidget);
                await tester.tap(find.byTooltip('Close filter'));
                await tester.pump();
                // Tap cycles headers; holding offers direct selection. No stream is opened.
                scroll(labels).jumpTo(0);
                await tester.pump();
                final playsBefore = playback.played.length;
                final sectionButton =
                    find.byKey(const ValueKey('guide-next-section'));
                for (final index in [
                  originalCount,
                  originalCount + 30,
                  originalCount + 70,
                  originalCount + 98,
                  originalCount
                ]) {
                  await tester.tap(sectionButton);
                  await tester.pump();
                  await tester.pump();
                  expect(
                      scroll(labels).offset,
                      closeTo(
                          (index * 44.0).clamp(
                              0.0, scroll(labels).position.maxScrollExtent),
                          .1));
                }
                await tester.longPress(sectionButton);
                await tester.pump(const Duration(milliseconds: 300));
                expect(find.byKey(const ValueKey('guide-section-picker')),
                    findsOneWidget);
                expect(
                    tester
                        .widget<ListView>(find.descendant(
                            of: find
                                .byKey(const ValueKey('guide-section-picker')),
                            matching: find.byType(ListView)))
                        .itemExtent,
                    40);
                await captureSports(tester, size, 'guide-sections');
                await tester.tap(find
                    .byKey(ValueKey('guide-section-${originalCount + 70}')));
                await settleSports(tester);
                expect(scroll(labels).offset,
                    closeTo((originalCount + 70) * 44.0, .1));
                expect(playback.played.length, playsBefore);
                // The same button supports a real remote hold (repeat + release),
                // without the held key selecting a popup item accidentally.
                await tester.tap(find.byKey(const ValueKey('guide-now')));
                await tester.pump();
                await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
                await tester.pump();
                await tester.sendKeyDownEvent(LogicalKeyboardKey.select);
                await tester.pump(const Duration(milliseconds: 600));
                await tester.sendKeyRepeatEvent(LogicalKeyboardKey.select);
                await settleSports(tester);
                await tester.sendKeyUpEvent(LogicalKeyboardKey.select);
                await tester.pump();
                expect(find.byKey(const ValueKey('guide-section-picker')),
                    findsOneWidget);
                await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
                await tester.pump();
                await tester.sendKeyEvent(LogicalKeyboardKey.select);
                await settleSports(tester);
                expect(find.byKey(const ValueKey('guide-section-picker')),
                    findsNothing);
                expect(scroll(labels).offset,
                    closeTo((originalCount + 30) * 44.0, .1));
                // History is a normal guide category, newest first, with EPG rows.
                playback.history.addAll(
                    [playlist.fixtureChannels[4], playlist.fixtureChannels[2]]);
                playback.notifyListeners();
                await tester.tap(find.byKey(const ValueKey('bottom-live')));
                await tester.pump();
                await tester.tap(find.text('History'));
                await tester.pump();
                expect(find.byType(SimpleDialog), findsNothing);
                expect(find.text('History'), findsOneWidget);
                expect(
                    tester
                        .widget<ListView>(labels)
                        .childrenDelegate
                        .estimatedChildCount,
                    2);
                await tester.pump();
                expect(
                    find.text('The World Today').hitTestable(), findsWidgets);
                final rulerScroll = tester
                    .widget<SingleChildScrollView>(
                        find.byKey(const ValueKey('guide-ruler-scroll')))
                    .controller!;
                expect(horizontal.offset, closeTo(rulerScroll.offset, .1));
                if (const bool.fromEnvironment('CAPTURE_LAYOUT')) {
                  await tester.runAsync(() async {
                    final image = await (capture.currentContext!
                            .findRenderObject() as RenderRepaintBoundary)
                        .toImage();
                    final bytes =
                        await image.toByteData(format: ui.ImageByteFormat.png);
                    await File('/tmp/iptv-history-390.png')
                        .writeAsBytes(bytes!.buffer.asUint8List());
                    image.dispose();
                  });
                }
                await tester.tap(find.byKey(const ValueKey('bottom-live')));
                await tester.pump();
                await tester.tap(find.text('Australian TV'));
                await tester.pump();
                playlist.fixtureChannels.removeRange(
                    originalCount, playlist.fixtureChannels.length);
                playlist.notifyListeners();
                await playback.stop();
                await tester.pump();
              }
              // The same active channel survives switching into Sports without a play/stop.
              final originalChannel = playlist.fixtureChannels.first;
              await playback.play(originalChannel);
              final playCount = playback.played.length;
              await tester.pump();
              epg.pending = Completer<List<EpgProgram>>();
              // TV hides passed columns; return through them before using tabs.
              for (var i = 0;
                  i < 2 &&
                      find
                          .byIcon(Icons.sports)
                          .hitTestable()
                          .evaluate()
                          .isEmpty;
                  i++) {
                await tester.binding.handlePopRoute();
                await tester.pumpAndSettle();
              }
              await tester.tap(find.byIcon(Icons.sports));
              await tester.pump(const Duration(milliseconds: 300));
              // Scoreboard parsing runs in an isolate, outside the fake test clock.
              await tester.runAsync(() async {
                await Future<void>.delayed(const Duration(milliseconds: 400));
              });
              await tester.pump(const Duration(milliseconds: 400));
              await tester.pump(const Duration(milliseconds: 200));
              for (var attempt = 0;
                  attempt < 20 && find.text('Celtics').evaluate().isEmpty;
                  attempt++) {
                await tester.runAsync(() =>
                    Future<void>.delayed(const Duration(milliseconds: 50)));
                await tester.pump(const Duration(milliseconds: 100));
              }
              // Loading state never bypasses the confidence filter.
              expect(find.byKey(const ValueKey('sports-load-status')),
                  findsOneWidget);
              expect(find.byKey(const ValueKey('card-nba:0')), findsNothing);
              await captureSports(tester, size, 'sports-loading');
              epg.pending!.complete([]);
              epg.pending = null;
              // A quiet frame does not mean the matching isolate has replied.
              for (var attempt = 0;
                  attempt < 100 &&
                      find
                          .byKey(const ValueKey('card-nba:1'))
                          .evaluate()
                          .isEmpty;
                  attempt++) {
                await tester.runAsync(() =>
                    Future<void>.delayed(const Duration(milliseconds: 10)));
                await tester.pump(const Duration(milliseconds: 16));
              }
              await settleSports(tester);
              await tester.pump(const Duration(milliseconds: 100));
              await tester.pump(const Duration(milliseconds: 100));
              expect(find.text('Matched'), findsOneWidget);
              expect(find.text('NFL RedZone'), findsNothing);
              expect(playback.currentChannel, same(originalChannel));
              expect(playback.played.length, playCount);
              Future<void> finishRefresh(int expectedRequests) async {
                for (var attempt = 0; attempt < 30; attempt++) {
                  await tester.runAsync(() =>
                      Future<void>.delayed(const Duration(milliseconds: 50)));
                  await tester.pump(const Duration(milliseconds: 100));
                  if (scoreRequests >= expectedRequests &&
                      tester
                              .widget<IconButton>(
                                  find.byKey(const ValueKey('sports-refresh')))
                              .onPressed !=
                          null) {
                    break;
                  }
                }
                expect(
                    tester
                        .widget<IconButton>(
                            find.byKey(const ValueKey('sports-refresh')))
                        .onPressed,
                    isNotNull);
              }

              final beforeRefresh = scoreRequests;
              await tester.tap(find.byKey(const ValueKey('sports-refresh')));
              await tester.pump();
              expect(find.byKey(const ValueKey('card-nba:1')), findsOneWidget);
              await finishRefresh(beforeRefresh + 9);
              expect(scoreRequests, beforeRefresh + 9);
              if (size.width < 600) {
                await settleSports(tester);
                final beforePull = scoreRequests;
                final groups =
                    find.byKey(const PageStorageKey('sports-events'));
                tester.widget<ScrollView>(groups).controller!.jumpTo(0);
                await tester.pumpAndSettle();
                final pull = await tester.startGesture(
                    tester.getTopLeft(groups) + const Offset(100, 24));
                for (var step = 0; step < 6; step++) {
                  await pull.moveBy(const Offset(0, 50));
                  await tester.pump(const Duration(milliseconds: 50));
                }
                await captureSports(tester, size, 'sports-refresh');
                await pull.up();
                // Start the snap animation before advancing its fake clock.
                await tester.pump();
                await tester.pump(const Duration(milliseconds: 300));
                await finishRefresh(beforePull + 9);
                expect(scoreRequests, beforePull + 9);
              }
              expect(playback.currentChannel, same(originalChannel));
              expect(playback.played.length, playCount);
              expect(find.byType(VideoPlayerPane), findsOneWidget);
              expect(
                  tester
                      .widget<SportsFilterButton>(
                          find.byKey(const ValueKey('live-only')))
                      .selected,
                  isTrue);
              expect(
                  tester
                      .widget<SportsFilterButton>(
                          find.byKey(const ValueKey('with-channel')))
                      .selected,
                  isTrue);
              expect(find.byKey(const ValueKey('card-nba:0')), findsNothing);
              // The wider lazy row mounts the upcoming card; on phones it is
              // beyond the viewport/cache extent until scrolled into view.
              if (size.width >= 600) {
                expect(
                    find.byKey(const ValueKey('card-nba:3')), findsOneWidget);
              }
              Future<void> chooseTime(String mode) async {
                await tester.tap(find.byKey(const ValueKey('live-only')));
                await tester.pump(const Duration(milliseconds: 200));
                await tester.tap(find.byKey(ValueKey('time-filter-$mode')));
                await tester.pump(const Duration(milliseconds: 200));
              }

              Future<void> toggleLive() => chooseTime(tester
                          .widget<SportsFilterButton>(
                              find.byKey(const ValueKey('live-only')))
                          .value ==
                      'Live'
                  ? 'all'
                  : 'live');
              final requestsBeforeTime = scoreRequests;
              await chooseTime('liveAndSoon');
              expect(
                  tester
                      .widget<SportsFilterButton>(
                          find.byKey(const ValueKey('live-only')))
                      .value,
                  'Live + soon');
              expect(
                  tester
                      .widget<SportsFilterButton>(
                          find.byKey(const ValueKey('with-channel')))
                      .value,
                  'Matched');
              await tester.tap(find.byKey(const ValueKey('live-only')));
              await settleSports(tester);
              await captureSports(tester, size, 'sports-showing');
              await tester.tap(find.byKey(const ValueKey('time-filter-live')));
              await settleSports(tester);
              expect(scoreRequests, requestsBeforeTime,
                  reason: 'Time filters must not fetch data');
              Future<void> chooseChannelFilter(String mode) async {
                await tester.tap(find.byKey(const ValueKey('with-channel')));
                await tester.pump(const Duration(milliseconds: 200));
                await tester.tap(find.byKey(ValueKey('channel-filter-$mode')));
                await tester.pump(const Duration(milliseconds: 200));
                // Selection applies after the dialog overlay has disposed.
                await tester.pump();
              }

              await chooseChannelFilter('possible');
              expect(storage.getSportsChannelFilter(), 'possible');
              expect(find.text('Possible'), findsOneWidget);
              await tester.tap(find.byKey(const ValueKey('with-channel')));
              await tester.pump(const Duration(milliseconds: 200));
              await captureSports(tester, size, 'channel-filter');
              await tester
                  .tap(find.byKey(const ValueKey('channel-filter-matched')));
              await tester.pump(const Duration(milliseconds: 200));
              // Capture lets the opening animation finish, so closing can
              // take longer than the partial animation in non-capture runs.
              await settleSports(tester);
              // Exercise the remaining filters starting from the unfiltered view.
              await playback.stop();
              await toggleLive();
              await chooseChannelFilter('all');
              await settleSports(tester);
              expect(find.byKey(const ValueKey('sports-channel-box')),
                  findsOneWidget);
              expect(playback.currentChannel, isNull);
              // An unmatched live fixture is visible until explicitly filtered.
              expect(find.byKey(const ValueKey('card-nba:0')), findsOneWidget);
              await chooseChannelFilter('matched');
              await tester.pump(const Duration(milliseconds: 200));
              expect(storage.getSportsWithChannel(), isTrue);
              expect(find.byKey(const ValueKey('card-nba:0')), findsNothing);
              expect(find.byKey(const ValueKey('card-nba:1')), findsOneWidget);
              await chooseChannelFilter('all');
              await tester.pump(const Duration(milliseconds: 200));
              expect(storage.getSportsWithChannel(), isFalse);
              expect(find.byKey(const ValueKey('card-nba:0')), findsOneWidget);
              expect(find.byKey(const ValueKey('sport-heading:basketball')),
                  findsOneWidget);
              expect(find.byKey(const ValueKey('sport-heading:hockey')),
                  findsOneWidget);
              if (size.width < 600) {
                expect(
                    tester
                        .getSize(
                            find.byKey(const ValueKey('sports-channel-box')))
                        .width,
                    greaterThan(340));
              }
              final overviewCard = find.descendant(
                  of: find.byKey(const ValueKey('card-nba:1')),
                  matching: find.byType(InkWell));
              tester.widget<InkWell>(overviewCard).focusNode!.requestFocus();
              await settleSports(tester);
              if (size.width > 600) {
                await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
                await settleSports(tester);
                expect(FocusManager.instance.primaryFocus?.debugLabel,
                    'sports-card-nfl:1');
                await tester.ensureVisible(
                    find.byKey(const ValueKey('sport-heading:basketball')));
                await tester.tap(
                    find.byKey(const ValueKey('sport-heading:basketball')));
                await settleSports(tester);
                expect(find.byKey(const ValueKey('sport-heading:hockey')),
                    findsNothing);
                await tester.binding.handlePopRoute();
                await settleSports(tester);
                expect(find.byKey(const ValueKey('sport-heading:hockey')),
                    findsOneWidget);
                tester.widget<InkWell>(overviewCard).focusNode!.requestFocus();
                await settleSports(tester);
              }
              // Capture the default live/matched overview, then continue filter checks.
              await toggleLive();
              await chooseChannelFilter('matched');
              await settleSports(tester);
              final scrollable = find
                  .descendant(
                      of: find.byKey(const PageStorageKey('sports-events')),
                      matching: find.byType(Scrollable))
                  .first;
              tester.state<ScrollableState>(scrollable).position.jumpTo(0);
              await settleSports(tester);
              await captureSports(tester, size, 'sports');
              await tester.tap(find.byKey(const ValueKey('league-picker')));
              await settleSports(tester);
              expect(
                  find.descendant(
                      of: find.byType(Dialog),
                      matching: find.text('American football')),
                  findsOneWidget);
              await tester.tap(find.byType(TextField));
              await tester.sendKeyEvent(LogicalKeyboardKey.select);
              await tester.pump();
              await tester.enterText(find.byType(TextField), 'NBA');
              await tester.pump();
              expect(find.text('Pro basketball'), findsOneWidget);
              await tester.enterText(find.byType(TextField), '');
              await tester.pump();
              expect(find.byKey(const ValueKey('sports-sort-top')),
                  findsOneWidget);
              await tester.tap(find.byKey(const ValueKey('sports-sort-live')));
              await settleSports(tester);
              await tester
                  .tap(find.byKey(const ValueKey('sports-sort-upcoming')));
              await settleSports(tester);
              await tester.tap(find.byKey(const ValueKey('sports-sort-top')));
              await settleSports(tester);
              await captureSports(tester, size, 'sports-leagues');
              await tester.sendKeyEvent(LogicalKeyboardKey.escape);
              await settleSports(tester);
              await toggleLive();
              await chooseChannelFilter('all');
              await settleSports(tester);
              await toggleLive();
              await settleSports(tester);
              expect(find.byKey(const ValueKey('card-nba:3')), findsNothing);
              await toggleLive();
              await settleSports(tester);
              await tester.ensureVisible(
                  find.byKey(const ValueKey('sport-heading:basketball')));
              await settleSports(tester);
              await tester
                  .tap(find.byKey(const ValueKey('sport-heading:basketball')));
              await settleSports(tester);
              expect(find.byKey(const ValueKey('sport-heading:hockey')),
                  findsNothing);
              expect(
                  find.byKey(const ValueKey('sport-picker')), findsOneWidget);
              // Sport/league pickers work without a scrolling toolbar.
              await tester.tap(find.byKey(const ValueKey('sport-picker')));
              await settleSports(tester);
              expect(find.text('Choose sport'), findsOneWidget);
              expect(
                  find.byWidgetPredicate((w) =>
                      w is SportsCounts && w.live == 9 && w.upcoming == 6),
                  findsOneWidget);
              await captureSports(tester, size, 'sports-picker');
              await tester.tap(find.byType(TextField));
              await tester.sendKeyEvent(LogicalKeyboardKey.select);
              await tester.pump();
              await tester.enterText(find.byType(TextField), 'basket');
              await tester.pump();
              await tester.tap(find.text('Basketball').last);
              await settleSports(tester);
              expect(find.text('Basketball'), findsOneWidget);
              await tester.tap(find.byKey(const ValueKey('league-picker')));
              await settleSports(tester);
              expect(find.text('Choose league'), findsOneWidget);
              await tester.sendKeyEvent(LogicalKeyboardKey.escape);
              await settleSports(tester);
              // Secondary controls remain available in the options menu.
              await tester.tap(find.byIcon(Icons.more_horiz));
              await tester.pump(const Duration(milliseconds: 200));
              expect(find.text('My Teams'), findsOneWidget);
              expect(find.text('Standings'), findsOneWidget);
              await tester.sendKeyEvent(LogicalKeyboardKey.escape);
              await tester.pump(const Duration(milliseconds: 200));
              // Focusing a matched game fills the idle preview without playing.
              await chooseChannelFilter('matched');
              await tester.pump(const Duration(milliseconds: 200));
              expect(find.text('Later today'), findsOneWidget);
              await toggleLive();
              await settleSports(tester);
              expect(find.text('Later today'), findsNothing);
              await tester.tap(find.byKey(const ValueKey('sport-picker')));
              await settleSports(tester);
              // Counts retain upcoming games even when Live-only is on.
              expect(
                  find.byWidgetPredicate((w) =>
                      w is SportsCounts && w.live == 6 && w.upcoming == 6),
                  findsOneWidget);
              await tester.sendKeyEvent(LogicalKeyboardKey.escape);
              await settleSports(tester);
              await toggleLive();
              await settleSports(tester);
              final gameInk = find.descendant(
                  of: find.byKey(const ValueKey('card-nba:1')),
                  matching: find.byType(InkWell));
              tester.widget<InkWell>(gameInk).focusNode!.requestFocus();
              await tester.pump(const Duration(milliseconds: 200));
              expect(find.text('Choose a game'), findsNothing);
              expect(playback.currentChannel, isNull);
              expect(
                  find.descendant(
                      of: find.byKey(const ValueKey('sports-channel-box')),
                      matching: find.text('Fox Sports')),
                  findsOneWidget);
              expect(find.text('Celtics'), findsWidgets);
              expect(tester.takeException(), isNull);
              if (size.width > 600) {
                expect(FocusManager.instance.primaryFocus?.debugLabel,
                    'sports-card-nba:1');
                await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
                await tester.pump(const Duration(milliseconds: 200));
                expect(FocusManager.instance.primaryFocus?.debugLabel,
                    'sports-card-nba:2');
                await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
                await tester.pump(const Duration(milliseconds: 200));
              }
              await tester.pump(const Duration(milliseconds: 200));
              if (const bool.fromEnvironment('CAPTURE_LAYOUT')) {
                await tester.runAsync(() async {
                  final boundary =
                      tester.firstRenderObject<RenderRepaintBoundary>(
                          find.byType(RepaintBoundary));
                  final image = await boundary.toImage();
                  final bytes =
                      await image.toByteData(format: ui.ImageByteFormat.png);
                  await File(
                          '/tmp/iptv-sports-detail-${size.width.toInt()}.png')
                      .writeAsBytes(bytes!.buffer.asUint8List());
                  image.dispose();
                });
              }
              // Long-press presents channels once, with a clear preview action.
              await tester
                  .ensureVisible(find.byKey(const ValueKey('card-nba:1')));
              await settleSports(tester);
              await tester.longPress(find.byKey(const ValueKey('card-nba:1')));
              await settleSports(tester);
              expect(find.text('Watch on…'), findsOneWidget);
              expect(find.text('Find another channel'), findsOneWidget);
              expect(find.text('Play here'), findsNothing);
              expect(find.byKey(const ValueKey('sports-channel-dialog')),
                  findsOneWidget);
              expect(find.byType(BottomSheet), findsNothing);
              expect(find.textContaining('The World Today'), findsWidgets);
              await captureSports(tester, size, 'sports-channels');
              await tester.binding.handlePopRoute();
              await settleSports(tester);
              if (prefs.isTelevision) {
                expect(FocusManager.instance.primaryFocus?.debugLabel,
                    'sports-card-nba:1');
              }
              await tester.longPress(find.byKey(const ValueKey('card-nba:1')));
              await settleSports(tester);

              await tester.tap(
                  find.byKey(const ValueKey('game-channel:demo::Fox Sports')));
              await settleSports(tester);
              expect(find.text('Watch on…'), findsNothing);
              expect(playback.currentChannel?.name, 'Fox Sports');
              await playback.stop();
              await settleSports(tester);
              playback.played.clear();
              // A single tap on an unfocused card starts its matched channel.
              FocusManager.instance.primaryFocus?.unfocus();
              await tester.pump();
              await tester
                  .ensureVisible(find.byKey(const ValueKey('card-nba:1')));
              await settleSports(tester);
              await tester.tap(find.byKey(const ValueKey('card-nba:1')));
              await tester.pump(const Duration(milliseconds: 200));
              expect(playback.played, hasLength(1));
              expect(playback.currentChannel?.name, 'Fox Sports');
              await tester
                  .ensureVisible(find.byKey(const ValueKey('card-nba:2')));
              await settleSports(tester);
              if (size.width > 600) {
                final second = find.descendant(
                    of: find.byKey(const ValueKey('card-nba:2')),
                    matching: find.byType(InkWell));
                tester.widget<InkWell>(second).focusNode!.requestFocus();
                await settleSports(tester);
                expect(playback.played, hasLength(1));
                await tester.sendKeyEvent(LogicalKeyboardKey.select);
              } else {
                await tester.tap(find.byKey(const ValueKey('card-nba:2')));
              }
              await tester.pump(const Duration(milliseconds: 200));
              expect(playback.played, hasLength(2));
              expect(find.byType(SportsScreen), findsOneWidget);
              // Back returns to the overview while the channel keeps playing.
              await tester.binding.handlePopRoute();
              await settleSports(tester);
              expect(playback.currentChannel?.name, 'Fox Sports');
              await tester
                  .tap(find.byKey(const ValueKey('sport-heading:basketball')));
              await settleSports(tester);
              // Lazy phone rows release offscreen headers: scroll back before
              // opening the stats action, as a viewer would.
              if (size.width < 600) {
                tester
                    .widget<CustomScrollView>(find
                        .descendant(
                            of: find.byType(SportsScreen),
                            matching: find.byType(CustomScrollView))
                        .first)
                    .controller!
                    .jumpTo(0);
                await tester.pump();
              }
              // See all keeps the same filter after its own data refresh.
              await tester.ensureVisible(find.text('See all · stats'));
              await settleSports(tester);
              await tester.tap(find.text('See all · stats'));
              await tester.pump(const Duration(milliseconds: 300));
              await tester.runAsync(() =>
                  Future<void>.delayed(const Duration(milliseconds: 200)));
              await tester.pump(const Duration(milliseconds: 200));
              final liveRows = tester
                  .widgetList<InkWell>(find.byType(InkWell))
                  .where((w) =>
                      w.focusNode?.debugLabel?.startsWith('sports-live-') ??
                      false)
                  .map((w) => w.focusNode!.debugLabel)
                  .toList();
              expect(liveRows,
                  unorderedEquals(['sports-live-nba:1', 'sports-live-nba:2']));
              Navigator.of(tester.element(find.byType(SportsLiveListScreen)))
                  .pop();
              await tester.pump(const Duration(milliseconds: 300));
              await settleSports(tester);
              expect(storage.getSportsWithChannel(), isTrue);
              // Replays use direct guide mappings, keep the current preview,
              // and preserve the Events filters when switching back.
              final replayNow = DateTime.now();
              for (final entry in [
                ('Replay 1', 'NBA League Pass'),
                ('NFL Replay 1', 'NFL Sunday Ticket'),
                ('NFL Replay 2', 'NFL Sunday Ticket'),
                ('NFL Replay 3', 'NFL Sunday Ticket'),
                ('NHL Replay 1', 'NHL Center Ice'),
                ('NHL Replay 2', 'NHL Center Ice'),
                ('PL REPLAY 1 HD', 'Soccer Replay'),
                ('PL REPLAY 2 HD', 'Soccer Replay'),
              ]) {
                playlist.fixtureChannels.add(Channel(
                    id: 'demo::${entry.$1}',
                    rawId: entry.$1,
                    playlistId: 'demo',
                    name: entry.$1,
                    group: entry.$2,
                    url: 'https://example.test/no-stream'));
                epg.withoutGuide.add(entry.$1);
              }
              playlist.notifyListeners();
              epg.replays = [
                for (final entry in [
                  (
                    'Fox Sports',
                    'NBA: Boston Celtics v New York Knicks (Replay)',
                    'Full game replay from 21 October 2026. Madison Square Garden, New York.'
                  ),
                  (
                    'Fox Sports HD',
                    'NBA: Boston Celtics v New York Knicks (Replay)',
                    'Full game replay from 21 October 2026. Madison Square Garden, New York.'
                  ),
                  (
                    'ABC HD',
                    'NCAA Women’s Volleyball: Texas v Stanford (Replay)',
                    'Replay of the women’s college volleyball match.'
                  ),
                  (
                    'SBS HD',
                    'NCAA Women’s Soccer: Florida Atlantic v South Florida (Replay)',
                    'Full match replay from 21 October.'
                  ),
                  (
                    'Seven',
                    'Cricket: Australia v India — 2nd ODI',
                    'Coverage of the second one-day international.'
                  ),
                  (
                    'Nine',
                    'Formula 1: Australian Grand Prix (Replay)',
                    'Full race replay from 24 March 2024. Albert Park, Melbourne.'
                  ),
                ])
                  EpgProgram(
                      channelId: entry.$1,
                      title: entry.$2,
                      description: entry.$3,
                      start: replayNow.subtract(const Duration(minutes: 25)),
                      stop: replayNow.add(const Duration(minutes: 95))),
              ];
              epg.notifyListeners();
              final beforeReplays = playback.played.length;
              final livePreviewRect =
                  tester.getRect(find.byKey(const ValueKey('sports-preview')));
              final liveRefreshRect =
                  tester.getRect(find.byKey(const ValueKey('sports-refresh')));
              final livePlayerElement =
                  tester.element(find.byType(VideoPlayerPane));
              tester
                  .widget<TextButton>(
                      find.byKey(const ValueKey('sports-view-replays')))
                  .focusNode!
                  .requestFocus();
              await tester.pumpAndSettle();
              await tester.sendKeyEvent(LogicalKeyboardKey.select);
              await tester.pump();
              await tester.pump(const Duration(milliseconds: 300));
              expect(find.textContaining('4 shown'), findsOneWidget);
              expect(
                  tester.getRect(find.byKey(const ValueKey('sports-preview'))),
                  livePreviewRect);
              expect(
                  tester.getRect(find.byKey(const ValueKey('replays-refresh'))),
                  liveRefreshRect);
              expect(tester.element(find.byType(VideoPlayerPane)),
                  same(livePlayerElement));
              expect(
                  tester
                      .getBottomRight(
                          find.byKey(const ValueKey('replay-sport-picker')))
                      .dy,
                  lessThan(livePreviewRect.top));
              await tester.tap(find.byKey(const ValueKey('replay-options')));
              await settleSports(tester);
              await captureSports(tester, size, 'replay-options');
              await tester.tap(find.text('Include possible replays'));
              await settleSports(tester);
              expect(find.textContaining('5 shown'), findsOneWidget);
              expect(find.text('21 Oct 2026'), findsWidgets);
              expect(find.byKey(const ValueKey('replay-view-toggle')),
                  findsNothing);
              await tester.tap(find.byKey(const ValueKey('replay-options')));
              await settleSports(tester);
              await tester.tap(find.text('Search replays'));
              await settleSports(tester);
              final searchField =
                  find.byKey(const ValueKey('replay-search-field'));
              expect(tester.widget<TextField>(searchField).focusNode!.hasFocus,
                  true);
              if (tester.widget<TextField>(searchField).readOnly) {
                await tester.sendKeyEvent(LogicalKeyboardKey.select);
                await tester.pump();
              }
              await tester.enterText(searchField, 'new york');
              await settleSports(tester);
              expect(find.textContaining('1 shown'), findsOneWidget);
              await captureSports(tester, size, 'replay-search');
              await tester.enterText(searchField, 'fox sports hd');
              await settleSports(tester);
              expect(find.textContaining('1 shown'), findsOneWidget);
              await tester.enterText(searchField, 'Austrália India');
              await settleSports(tester);
              expect(find.textContaining('1 shown'), findsOneWidget);
              await tester.enterText(searchField, 'no such event');
              await settleSports(tester);
              expect(find.textContaining('0 shown'), findsOneWidget);
              expect(find.text('Clear filters'), findsOneWidget);
              await tester.tap(find.text('Clear filters'));
              await settleSports(tester);
              expect(find.textContaining('5 shown'), findsOneWidget);
              await tester.tap(find.byTooltip('Close search'));
              await settleSports(tester);
              expect(searchField, findsNothing);
              expect(playback.played.length, beforeReplays);

              await tester
                  .tap(find.byKey(const ValueKey('replay-sort-picker')));
              await settleSports(tester);
              expect(find.text('Order within each sport'), findsOneWidget);
              await tester.tap(find.text('Ending soon'));
              await settleSports(tester);
              expect(find.text('Ending soon'), findsOneWidget);
              await tester
                  .tap(find.byKey(const ValueKey('replay-sort-picker')));
              await settleSports(tester);
              await tester.tap(find.text('Recent events'));
              await settleSports(tester);
              expect(find.byKey(const ValueKey('replay-channel-directory')),
                  findsNothing);
              await tester.tap(find.byKey(const ValueKey('replay-options')));
              await settleSports(tester);
              await tester.tap(find.byWidgetPredicate(
                  (w) => w is PopupMenuItem<String> && w.value == 'likely'));
              await settleSports(tester);
              expect(find.textContaining('4 shown'), findsOneWidget);
              await tester.tap(find.byKey(const ValueKey('replay-options')));
              await settleSports(tester);
              await tester.tap(find.byWidgetPredicate(
                  (w) => w is PopupMenuItem<String> && w.value == 'likely'));
              await settleSports(tester);
              expect(find.textContaining('5 shown'), findsOneWidget);
              await tester
                  .tap(find.byKey(const ValueKey('replay-date-picker')));
              await settleSports(tester);
              await captureSports(tester, size, 'replay-browser');
              await tester.tap(find.text('Date unclear'));
              await settleSports(tester);
              expect(find.textContaining('3 shown'), findsOneWidget);
              await tester
                  .tap(find.byKey(const ValueKey('replay-date-picker')));
              await settleSports(tester);
              await tester.tap(find.text('All dates'));
              await settleSports(tester);
              expect(find.textContaining('5 shown'), findsOneWidget);
              await tester
                  .tap(find.byKey(const ValueKey('replay-sort-picker')));
              await settleSports(tester);
              expect(find.text('Past 4 weeks'), findsNothing);
              expect(find.text('By sport'), findsNothing);
              await tester.tap(find.text('Top leagues'));
              await settleSports(tester);
              await tester
                  .tap(find.byKey(const ValueKey('replay-sport-picker')));
              await settleSports(tester);
              await tester.tap(find.descendant(
                  of: find.byType(SimpleDialog),
                  matching: find.text('Basketball')));
              await settleSports(tester);
              expect(find.textContaining('1 shown'), findsOneWidget);
              expect(playback.played.length, beforeReplays);
              await tester
                  .tap(find.byKey(const ValueKey('replay-sport-picker')));
              await settleSports(tester);
              await tester.tap(find.descendant(
                  of: find.byType(SimpleDialog),
                  matching: find.text('All sports')));
              await settleSports(tester);
              expect(find.textContaining('5 shown'), findsOneWidget);
              final catalogueLoads = playlist.catalogueLoads;
              await tester.tap(find.byKey(const ValueKey('replays-refresh')));
              await settleSports(tester);
              expect(playlist.catalogueLoads, catalogueLoads);
              final replayScroll = find.byKey(const ValueKey('replays-scroll'));
              final replayPull = await tester.startGesture(
                  tester.getTopLeft(replayScroll) + const Offset(20, 12));
              for (var i = 0; i < 8; i++) {
                await replayPull.moveBy(const Offset(0, 40));
                await tester.pump(const Duration(milliseconds: 40));
              }
              await replayPull.up();
              await settleSports(tester);
              expect(find.text('Couldn’t refresh'), findsNothing);
              expect(playlist.catalogueLoads, catalogueLoads);
              expect(playback.played.length, beforeReplays);
              expect(playback.currentChannel?.name, 'Fox Sports');
              expect(find.byType(VideoPlayerPane), findsOneWidget);
              expect(find.text('Replay'), findsWidgets);
              await tester.pump(const Duration(seconds: 2));
              await settleSports(tester);
              await captureSports(tester, size, 'sports-replays');
              final replayCard = find.byWidgetPredicate((w) =>
                  w is InkWell &&
                  (w.key?.toString().contains('replay-demo::Fox Sports:') ??
                      false));
              expect(replayCard, findsOneWidget);
              await tester.longPress(replayCard);
              await settleSports(tester);
              expect(
                  find.text('Replay identified in the guide'), findsOneWidget);
              expect(
                  find.descendant(
                    of: find.byType(Dialog),
                    matching: find.textContaining('Madison Square Garden'),
                  ), findsOneWidget);
              await captureSports(tester, size, 'sports-replay-channels');
              await tester.tap(find.descendant(
                  of: find.byType(AlertDialog),
                  matching: find.text('Fox Sports HD')));
              await settleSports(tester);
              expect(playback.currentChannel?.name, 'Fox Sports HD');
              expect(playback.played.length, beforeReplays + 1);
              await tester
                  .tap(find.byKey(const ValueKey('replay-sport-picker')));
              await settleSports(tester);
              await tester.tap(find.descendant(
                  of: find.byType(SimpleDialog),
                  matching: find.text('Volleyball')));
              await settleSports(tester);
              expect(find.textContaining('1 shown'), findsOneWidget);
              expect(find.textContaining('NCAA Women’s Volleyball'),
                  findsOneWidget);
              // Remote OK tunes the exact programme channel once.
              final volleyball = find.byWidgetPredicate((w) =>
                  w is InkWell &&
                  (w.key?.toString().contains('replay-demo::ABC HD:') ??
                      false));
              tester.widget<InkWell>(volleyball).focusNode!.requestFocus();
              await tester.pump();
              await tester.sendKeyEvent(LogicalKeyboardKey.select);
              await settleSports(tester);
              expect(playback.currentChannel?.name, 'ABC HD');
              expect(playback.played.length, beforeReplays + 2);
              // Missing guide listings are explicit, don't start streams when
              // opened, and only tune the channel the user actually chooses.
              await tester.tap(find.byKey(const ValueKey('replay-options')));
              await settleSports(tester);
              await tester
                  .tap(find.byKey(const ValueKey('replay-channel-directory')));
              await settleSports(tester);
              expect(find.textContaining('availability is unverified'),
                  findsOneWidget);
              expect(playback.played.length, beforeReplays + 2);
              await captureSports(tester, size, 'replay-directory');
              await tester.tap(find.descendant(
                  of: find.byType(AlertDialog),
                  matching: find.text('NFL Replay 1')));
              await settleSports(tester);
              expect(playback.currentChannel?.name, 'NFL Replay 1');
              expect(playback.played.length, beforeReplays + 3);
              // Highlights are a separate current-guide view; opening it
              // preserves playback, and its details/search never imply dates.
              for (final entry in [
                (
                  'NBA TV',
                  'NBA: Boston v New York Highlights',
                  'Highlights from the NBA season opener at Madison Square Garden.'
                ),
                (
                  'NBA TV HD',
                  'NBA: Boston v New York Highlights',
                  'Highlights from the NBA season opener at Madison Square Garden.'
                ),
                (
                  'Sky Sports Cricket',
                  '2nd Test Day 4: SA v AUS Hlts',
                  'Day four highlights from South Africa v Australia in Gqeberha.'
                ),
                (
                  'Sky Sport Select',
                  'A-League: Phoenix v Melbourne City Hls',
                  'Highlights from the opening round of the Women’s A-League in Wellington.'
                ),
              ]) {
                playlist.fixtureChannels.add(Channel(
                    id: 'demo::${entry.$1}',
                    rawId: entry.$1,
                    playlistId: 'demo',
                    name: entry.$1,
                    group: 'Sports',
                    url: 'https://example.test/no-stream'));
                epg.replays.add(EpgProgram(
                    channelId: entry.$1,
                    title: entry.$2,
                    description: entry.$3,
                    start: replayNow.subtract(const Duration(minutes: 8)),
                    stop: replayNow.add(const Duration(minutes: 22))));
              }
              playlist.notifyListeners();
              epg.notifyListeners();
              tester
                  .widget<TextButton>(
                      find.byKey(const ValueKey('sports-view-highlights')))
                  .focusNode!
                  .requestFocus();
              await tester.pumpAndSettle();
              await tester.sendKeyEvent(LogicalKeyboardKey.select);
              await settleSports(tester);
              expect(
                  find.byWidgetPredicate(
                      (w) => w is SportsReplaysPanel && w.highlights),
                  findsOneWidget);
              expect(find.textContaining('3 shown'), findsOneWidget);
              expect(playback.currentChannel?.name, 'NFL Replay 1');
              expect(playback.played.length, beforeReplays + 3);
              expect(find.text('Date unclear'), findsNothing);
              expect(find.text('Likely replay'), findsNothing);
              await captureSports(tester, size, 'sports-highlights');
              await tester
                  .tap(find.byKey(const ValueKey('replay-sort-picker')));
              await settleSports(tester);
              expect(find.text('Sort highlights'), findsOneWidget);
              expect(find.text('Event date'), findsNothing);
              expect(find.text('Recent events'), findsNothing);
              await tester.tap(find.text('Top leagues').last);
              await settleSports(tester);
              await tester.tap(find.byKey(const ValueKey('replay-options')));
              await settleSports(tester);
              expect(find.text('Include possible replays'), findsNothing);
              await tester.tap(find.text('Search highlights'));
              await settleSports(tester);
              final highlightSearch =
                  find.byKey(const ValueKey('replay-search-field'));
              if (tester.widget<TextField>(highlightSearch).readOnly) {
                await tester.sendKeyEvent(LogicalKeyboardKey.select);
                await tester.pump();
              }
              await tester.enterText(highlightSearch, 'Boston');
              await settleSports(tester);
              expect(find.textContaining('1 shown'), findsOneWidget);
              final highlightCard = find.byWidgetPredicate((w) =>
                  w is InkWell &&
                  (w.key?.toString().contains('replay-demo::NBA TV:') ??
                      false));
              if (size.width >= 600) {
                tester.widget<InkWell>(highlightCard).focusNode!.requestFocus();
                await tester.pump();
                await tester.sendKeyEvent(LogicalKeyboardKey.select);
              } else {
                await tester.tap(highlightCard);
              }
              await settleSports(tester);
              expect(playback.currentChannel?.name, 'NBA TV');
              await tester.tap(find.descendant(
                  of: highlightCard,
                  matching: find.byTooltip('Programme details and channels')));
              await settleSports(tester);
              expect(find.text('Original guide'), findsOneWidget);
              expect(find.text('Original guide & date source'), findsNothing);
              await captureSports(tester, size, 'highlight-channels');
              await tester.tap(find.descendant(
                  of: find.byType(AlertDialog),
                  matching: find.text('NBA TV HD')));
              await settleSports(tester);
              expect(playback.currentChannel?.name, 'NBA TV HD');
              tester
                  .widget<TextButton>(
                      find.byKey(const ValueKey('sports-view-replays')))
                  .focusNode!
                  .requestFocus();
              await tester.pumpAndSettle();
              await tester.sendKeyEvent(LogicalKeyboardKey.select);
              await settleSports(tester);
              expect(find.textContaining('4 shown'), findsOneWidget);
              expect(playback.currentChannel?.name, 'NBA TV HD');
              tester
                  .widget<TextButton>(
                      find.byKey(const ValueKey('sports-view-events')))
                  .focusNode!
                  .requestFocus();
              await tester.pumpAndSettle();
              await tester.sendKeyEvent(LogicalKeyboardKey.select);
              await settleSports(tester);
              expect(playback.currentChannel?.name, 'NBA TV HD');
              expect(
                  find.byWidgetPredicate(
                      (w) => w is SportsReplaysPanel && !w.highlights),
                  findsNothing);
              expect(tester.takeException(), isNull);
              epg.replays = [];
              // An empty matched-channel result stays useful and can be cleared.
              playlist.fixtureChannels.clear();
              playlist.notifyListeners();
              await tester.tap(find.text('Today'));
              await tester.pump(const Duration(milliseconds: 200));
              await tester.tap(find.text('Tomorrow'));
              await tester.pump(const Duration(milliseconds: 200));
              await tester.runAsync(() =>
                  Future<void>.delayed(const Duration(milliseconds: 400)));
              await tester.pump(const Duration(milliseconds: 200));
              await tester.tap(find.text('Tomorrow'));
              await tester.pump(const Duration(milliseconds: 200));
              await tester.tap(find.text('Today'));
              await tester.pump(const Duration(milliseconds: 200));
              await tester.runAsync(() =>
                  Future<void>.delayed(const Duration(milliseconds: 200)));
              await tester.pump(const Duration(milliseconds: 200));
              await settleSports(tester);
              expect(
                  find.text('No games with a matched channel'), findsOneWidget);
              await chooseChannelFilter('all');
              await tester.pump(const Duration(milliseconds: 200));
              expect(find.byKey(const ValueKey('card-nba:0')), findsOneWidget);
              expect(tester.takeException(), isNull);
              if (size.width < 600) {
                expect(
                    find.byKey(const ValueKey('bottom-live')), findsOneWidget);
                await tester.tap(find.byKey(const ValueKey('bottom-settings')));
                await tester.tap(find.byKey(const ValueKey('bottom-settings')));
                await settleSports(tester);
                expect(find.byType(SportsScreen), findsNothing);
                expect(playback.currentChannel?.name, 'NBA TV HD');
                expect(find.text('Settings'), findsWidgets);
                await tester.tap(find.byKey(const ValueKey('bottom-sports')));
                await settleSports(tester);
                final beforeReturn = playback.played.length;
                expect(playback.currentChannel?.name, 'NBA TV HD');
                await tester.tap(find.byKey(const ValueKey('bottom-live')));
                await settleSports(tester);
                expect(playback.played.length, beforeReturn);
                expect(playback.currentChannel?.name, 'NBA TV HD');
                expect(find.byType(SportsScreen), findsNothing);
                expect(
                    find.byKey(const ValueKey('bottom-live')), findsOneWidget);
              }
              await tester.pumpWidget(const SizedBox());
              SportsChannelMatcher.disposeShared();
              await tester.pump(const Duration(seconds: 31));
              prefs.dispose();
              playlist.dispose();
              playback.dispose();
              epg.dispose();
              viewers.dispose();
            },
                () => MockClient((request) async {
                      if (request.url.path.contains('/tennis/')) {
                        return _tennisFixture();
                      }
                      if (!['/nba/', '/nhl/', '/nfl/']
                          .any(request.url.path.contains)) {
                        return http.Response('{"events":[]}', 200);
                      }
                      if (request.url.path.endsWith('/scoreboard')) {
                        scoreRequests++;
                      }
                      return http.Response(
                          jsonEncode({
                            'events': [
                              for (var i = 0; i < 5; i++)
                                {
                                  'id': '$i',
                                  'date':
                                      DateTime.now().toUtc().toIso8601String(),
                                  'competitions': [
                                    {
                                      'status': {
                                        'type': {
                                          'state': i < 3 ? 'in' : 'pre',
                                          'shortDetail':
                                              i < 3 ? 'Q3 06:24' : 'Tonight'
                                        }
                                      },
                                      'broadcasts': [
                                        if (i != 0)
                                          {
                                            'names': ['Fox Sports']
                                          }
                                      ],
                                      'competitors': [
                                        {
                                          'homeAway': 'home',
                                          'score': '84',
                                          'team': {
                                            'id': 'b$i',
                                            'displayName': request.url.path
                                                    .contains('/football/')
                                                ? 'Buffalo Bills'
                                                : request.url.path
                                                        .contains('/hockey/')
                                                    ? 'Vancouver Canucks'
                                                    : 'Boston Celtics',
                                            'shortDisplayName': request.url.path
                                                    .contains('/football/')
                                                ? 'Bills'
                                                : request.url.path
                                                        .contains('/hockey/')
                                                    ? 'Canucks'
                                                    : 'Celtics',
                                            'abbreviation': request.url.path
                                                    .contains('/football/')
                                                ? 'BUF'
                                                : request.url.path
                                                        .contains('/hockey/')
                                                    ? 'VAN'
                                                    : 'BOS'
                                          }
                                        },
                                        {
                                          'homeAway': 'away',
                                          'score': '78',
                                          'team': {
                                            'id': 'l$i',
                                            'displayName': request.url.path
                                                    .contains('/football/')
                                                ? 'Kansas City Chiefs'
                                                : request.url.path
                                                        .contains('/hockey/')
                                                    ? 'Edmonton Oilers'
                                                    : 'Los Angeles Lakers',
                                            'shortDisplayName': request.url.path
                                                    .contains('/football/')
                                                ? 'Chiefs'
                                                : request.url.path
                                                        .contains('/hockey/')
                                                    ? 'Oilers'
                                                    : 'Lakers',
                                            'abbreviation': request.url.path
                                                    .contains('/football/')
                                                ? 'KC'
                                                : request.url.path
                                                        .contains('/hockey/')
                                                    ? 'EDM'
                                                    : 'LAL'
                                          }
                                        },
                                      ],
                                    }
                                  ],
                                }
                            ],
                          }),
                          200);
                    })));
  }
  for (final size in [
    const Size(390, 844),
    const Size(844, 390),
    const Size(960, 540),
    const Size(1280, 720)
  ]) {
    testWidgets('tennis tournament cards fit ${size.width}', (tester) async {
      await http.runWithClient(() async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        SharedPreferences.setMockInitialValues({'sports_online_extras': false});
        final storage = StorageService();
        await storage.init();
        await storage.setSportsAddedLeagues(['tennis.atp']);
        await storage.setSportsLeagues(['tennis.atp']);
        await storage.setSportsChannelFilter('all');
        const themeId = String.fromEnvironment('LAYOUT_THEME');
        if (themeId.isNotEmpty) await storage.setPaletteId(themeId);
        final prefs = AppPreferences(storage);
        await prefs.init();
        prefs.isTelevision = size.width >= 960;
        final playlist = _Playlist(storage, CatalogDatabase());
        playlist.fixtureChannels.add(Channel(
            id: 'demo::tennis',
            rawId: 'tennis',
            playlistId: 'demo',
            name: 'Bu vs Ruud - ATP European Open',
            group: 'Tennis',
            url: 'https://example.invalid/never-opened'));
        final otherTennis = Channel(
            id: 'demo::other-tennis',
            rawId: 'other-tennis',
            playlistId: 'demo',
            name: 'ATP Tennis - another match',
            group: 'Tennis',
            url: 'https://example.invalid/never-opened');
        playlist.fixtureChannels.add(otherTennis);
        final playback = _Playback(storage, playlist);
        final epg = _Epg(storage);
        epg.replays.add(EpgProgram(
            channelId: 'tennis',
            title: 'ATP Tennis: European Open',
            description: 'Live from Brussels, Court 2.',
            start: DateTime.now().subtract(const Duration(minutes: 20)),
            stop: DateTime.now().add(const Duration(hours: 3))));
        final viewers = ViewerProfileService(storage, playlist, playback);
        await tester.pumpWidget(MultiProvider(
            providers: [
              Provider.value(value: storage),
              ChangeNotifierProvider.value(value: prefs),
              ChangeNotifierProvider<PlaylistManager>.value(value: playlist),
              ChangeNotifierProvider<PlaybackService>.value(value: playback),
              ChangeNotifierProvider<EpgService>.value(value: epg),
              ChangeNotifierProvider.value(value: viewers),
            ],
            child: MaterialApp(
                debugShowCheckedModeBanner: false,
                theme: buildAppTheme(prefs.palette),
                navigatorObservers: [appRouteObserver],
                home: const TvHomeScreen())));
        await settleSports(tester);
        await tester.tap(find.byIcon(Icons.sports));
        for (var i = 0;
            i < 30 &&
                find
                    .byKey(const ValueKey('tennis-tournament-tennis-demo'))
                    .evaluate()
                    .isEmpty;
            i++) {
          await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 50)));
          await tester.pump(const Duration(milliseconds: 100));
        }
        await settleSports(tester);
        expect(find.byKey(const ValueKey('tennis-tournament-tennis-demo')),
            findsOneWidget);
        expect(find.text('BNP Paribas Fortis European Open'), findsWidgets);
        expect(find.text('ATP · Round 2'), findsOneWidget);
        final eventCard = find.descendant(
            of: find.byKey(const ValueKey('card-tennis.atp:tennis-demo')),
            matching: find.byType(InkWell));
        tester.widget<InkWell>(eventCard).focusNode!.requestFocus();
        await settleSports(tester);
        final video =
            tester.getRect(find.byKey(const ValueKey('sports-channel-box')));
        final activity =
            tester.getRect(find.byKey(const ValueKey('sports-status-slot')));
        final summary =
            tester.getRect(find.byKey(const ValueKey('sports-preview-title')));
        if (size.width < 600) {
          expect(activity.left, greaterThan(summary.right));
          expect(activity.top, greaterThanOrEqualTo(video.bottom));
          expect(video.height, closeTo((size.width - 24) * 9 / 16, .1));
        } else {
          expect(summary.left, closeTo(video.left, .1));
          expect(summary.top, greaterThan(video.bottom));
          expect(activity.top, greaterThan(summary.bottom));
          expect(activity.right, lessThanOrEqualTo(video.right + .1));
          expect(activity.bottom, closeTo(size.height - 4, .1));
          expect(video.width, greaterThan((size.width - 40) * .36));
          final card = tester.getRect(
              find.byKey(const ValueKey('card-tennis.atp:tennis-demo')));
          expect(card.left, greaterThan(video.right));
          expect(card.top, lessThan(video.bottom));
        }
        expect(tester.takeException(), isNull);
        await captureSports(tester, size, 'tennis');
        if (size.width == 390) {
          // Another tennis stream may appear among broad alternatives, but
          // must not displace this event's recommendation or get its badge.
          await playback.play(otherTennis);
          await settleSports(tester);
          await tester.longPress(
              find.byKey(const ValueKey('card-tennis.atp:tennis-demo')));
          await settleSports(tester);
          final initialPicker =
              tester.widget<SportsChannelList>(find.byType(SportsChannelList));
          final options = initialPicker.rows;
          expect(options.any((row) => row.channel.id == otherTennis.id), true);
          expect(options.first.channel.id, isNot(otherTennis.id));
          expect(initialPicker.playingId, isNull);
          expect(find.textContaining('Playing'), findsNothing);
          final chosenId = options.first.channel.id;
          await tester.tap(find.byKey(ValueKey('game-channel:$chosenId')));
          await settleSports(tester);
          expect(playback.currentChannel?.id, chosenId);
          final saved = jsonDecode(storage.getSportsChannelPicks()!) as Map;
          expect(saved['events']['tennis.atp:tennis-demo']['c'], chosenId,
              reason:
                  'explicitly choosing even the first suggestion is remembered');
          await tester.longPress(
              find.byKey(const ValueKey('card-tennis.atp:tennis-demo')));
          await settleSports(tester);
          final reopened =
              tester.widget<SportsChannelList>(find.byType(SportsChannelList));
          expect(reopened.rows.first.channel.id, chosenId);
          expect(reopened.playingId, chosenId);
          expect(reopened.selectedId, chosenId);
          await captureSports(tester, size, 'sports-playing-channel');
          await tester.binding.handlePopRoute();
          await settleSports(tester);
          expect(tester.takeException(), isNull);
        }

        await tester.pumpWidget(const SizedBox());
        SportsChannelMatcher.disposeShared();
        await tester.pump(const Duration(seconds: 31));
        viewers.dispose();
        playback.dispose();
        playlist.dispose();
        epg.dispose();
        prefs.dispose();
      }, () => MockClient((_) async => _tennisFixture()));
    });
  }
}
