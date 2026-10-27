import 'dart:io';
import 'package:nox_iptv/models/vod_details.dart';
import 'package:nox_iptv/models/series_details.dart';
import 'dart:async';
import 'dart:ui' show ImageByteFormat;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:nox_iptv/models/channel.dart';
import 'package:nox_iptv/models/m3u_group.dart';
import 'package:nox_iptv/models/playlist_profile.dart';
import 'package:nox_iptv/models/xtream_category.dart';
import 'package:nox_iptv/models/xtream_series.dart';
import 'package:nox_iptv/services/app_preferences.dart';
import 'package:nox_iptv/services/catalog_database.dart';
import 'package:nox_iptv/services/playlist_manager.dart';
import 'package:nox_iptv/services/playlist_session.dart';
import 'package:nox_iptv/services/storage_service.dart';
import 'package:nox_iptv/services/xtream_api_service.dart';
import 'package:nox_iptv/screens/library_screen.dart';
import 'package:nox_iptv/screens/movie_detail_screen.dart';
import 'package:nox_iptv/widgets/hold_to_activate.dart';
import 'package:nox_iptv/utils/tv_theme.dart';

Channel movie(int i,
        {String group = 'Cinema', String playlist = 'one', String? name}) =>
    Channel(
        id: '$playlist::xt_vod_$i',
        rawId: 'xt_vod_$i',
        playlistId: playlist,
        name: name ?? 'Film ${i.toString().padLeft(4, '0')}',
        group: group,
        url: 'https://example.invalid/movie/$i',
        addedAt: DateTime(2026, 1, 1).add(Duration(minutes: i)));

class MemoryStorage extends StorageService {
  @override
  Future<void> writeCacheFile(String name, String contents) async {}
}

class Api extends XtreamApiService {
  Api()
      : super(
            server: 'https://example.invalid',
            username: 'test',
            password: 'test',
            playlistId: 'one');
  int detailLoads = 0, episodeLoads = 0;
  Completer<void>? detailGate;
  bool detailFailure = false;
  @override
  Future<VodDetails> getVodInfo(String id) async {
    detailLoads++;
    await detailGate?.future;
    if (detailFailure) throw StateError('offline');
    return VodDetails.empty;
  }

  @override
  Future<SeriesEpisodesResult> getSeriesEpisodes(int id, String name,
      {bool plotOnly = false}) async {
    episodeLoads++;
    await detailGate?.future;
    return (episodes: <int, List<Channel>>{}, plot: null, details: null);
  }

  int categories = 0, loads = 0, active = 0, peak = 0;
  bool fail = false;
  Completer<void>? gate;
  Completer<void>? started;
  @override
  Future<List<XtreamCategory>> getVodCategories() async {
    categories++;
    return [XtreamCategory(id: '1', name: 'Cinema')];
  }

  @override
  Future<List<XtreamCategory>> getSeriesCategories() async {
    categories++;
    return [];
  }

  @override
  Future<List<Channel>> getVodStreams(String id, String name) async {
    loads++;
    started?.complete();
    await gate?.future;
    active++;
    if (active > peak) peak = active;
    await Future<void>.delayed(const Duration(milliseconds: 15));
    active--;
    if (fail) throw StateError('offline');
    return [movie(1, group: name)];
  }
}

class MemoryDb extends CatalogDatabase {
  int total = 180;
  final offsets = <int>[];
  @override
  Future<List<Channel>> getVodByIds(List<String> ids) async =>
      [for (final id in ids) movie(int.parse(id.split('_').last))];
  final counts = <String, int>{};
  @override
  Future<int> getVodCategoryCount(
          String playlistId, String categoryName) async =>
      counts[categoryName] ?? 0;
  @override
  Future<void> upsertVodCategory(
      String playlistId, String categoryName, List<Channel> items) async {
    counts[categoryName] = items.length;
  }

  @override
  Future<LibraryPage> libraryPage(
      {required String playlistId,
      required String category,
      required bool series,
      String query = '',
      LibrarySort sort = LibrarySort.provider,
      int offset = 0,
      int limit = 60}) async {
    offsets.add(offset);
    final indices = [for (var i = 0; i < total; i++) i]
        .where((i) => (series ? 'Series $i' : movie(i).name)
            .toLowerCase()
            .contains(query.toLowerCase()))
        .toList();
    final selected = indices.skip(offset).take(limit);
    return LibraryPage(
        total: indices.length,
        movies: series ? [] : [for (final i in selected) movie(i)],
        series: !series
            ? []
            : [
                for (final i in selected)
                  XtreamSeries(
                      seriesId: i,
                      playlistId: playlistId,
                      name: 'Series $i',
                      categoryId: category)
              ]);
  }
}

class Manager extends PlaylistManager {
  Manager(super.storage, super.catalogDb);
  int loads = 0;
  bool organised = false;
  List<M3uGroup>? fixtureGroups;
  @override
  String categoryLayoutFor(String id) => organised ? 'organised' : 'provider';
  bool failRefresh = false;
  Completer<void>? pending;
  @override
  Future<void> ensureLibraryCategories({bool refresh = false}) async {}
  @override
  Future<void> loadLibraryCategory(String playlistId, String name, String type,
      {bool refresh = false}) async {
    loads++;
    if (refresh && failRefresh) throw StateError('offline');
    await pending?.future;
  }

  @override
  List<M3uGroup> get vodGroups =>
      fixtureGroups ??
      [M3uGroup(title: 'Cinema', playlistId: 'one', channels: [])];
  @override
  List<M3uGroup> get seriesGroups =>
      [M3uGroup(title: 'Drama', playlistId: 'one', channels: [])];
}

Future<
        ({
          StorageService storage,
          AppPreferences prefs,
          MemoryDb db,
          Manager manager
        })>
    mountLibrary(WidgetTester tester,
        {int total = 180,
        Size size = const Size(960, 540),
        bool organised = false,
        List<M3uGroup>? groups}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final storage = StorageService();
  await storage.init();
  final prefs = AppPreferences(storage);
  await prefs.init();
  prefs.isTelevision = size.width == 960;
  final db = MemoryDb()..total = total;
  final manager = Manager(storage, db)
    ..organised = organised
    ..fixtureGroups = groups;
  await tester.pumpWidget(MultiProvider(
      providers: [
        Provider<StorageService>.value(value: storage),
        Provider<CatalogDatabase>.value(value: db),
        ChangeNotifierProvider<AppPreferences>.value(value: prefs),
        ChangeNotifierProvider<PlaylistManager>.value(value: manager),
      ],
      child: MaterialApp(
          theme: buildAppTheme(prefs.palette), home: const LibraryScreen())));
  await tester.pumpAndSettle();
  addTearDown(() {
    manager.dispose();
    prefs.dispose();
  });
  return (storage: storage, prefs: prefs, db: db, manager: manager);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    const fonts = String.fromEnvironment('LAYOUT_FONT_DIR');
    if (fonts.isEmpty) return;
    for (final e in {
      'Roboto': 'Roboto-Regular.ttf',
      'MaterialIcons': 'MaterialIcons-Regular.otf'
    }.entries) {
      await (FontLoader(e.key)
            ..addFont(File('$fonts/${e.value}')
                .readAsBytes()
                .then(ByteData.sublistView)))
          .load();
    }
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test('content choices survive edits and old playlists retain all content',
      () {
    final p = PlaylistProfile(
        id: 'p',
        name: 'P',
        mode: 'xtream',
        sortOrder: 0,
        createdAt: DateTime(2026));
    final old = p.toJson()
      ..remove('includeLive')
      ..remove('includeMovies')
      ..remove('includeSeries');
    expect(PlaylistProfile.fromJson(old).includeMovies, isTrue);
    final selected = p.copyWith(
        includeLive: false, includeMovies: true, includeSeries: false);
    final restored =
        PlaylistProfile.fromJson(selected.toJson()).copyWith(name: 'Changed');
    expect(restored.includeLive, isFalse);
    expect(restored.includeMovies, isTrue);
    expect(restored.includeSeries, isFalse);
  });
  test(
      'library-only startup does not request live channels or catalogue titles',
      () async {
    final storage = MemoryStorage();
    await storage.init();
    final session = PlaylistSession(
        profile: PlaylistProfile(
            id: 'one',
            name: 'One',
            mode: 'xtream',
            sortOrder: 0,
            createdAt: DateTime(2026),
            includeLive: false,
            xtreamServer: 'https://example.invalid',
            xtreamUsername: 'test',
            xtreamPassword: 'test'),
        storage: storage,
        catalogDb: MemoryDb(),
        favoriteIds: () => {},
        favoriteSeriesIds: () => {},
        isRestrictedViewer: () => false,
        onNotify: () {});
    session.liveChannels = [movie(1)];
    await session.restoreOrLoad();
    expect(session.liveChannels, isEmpty);
    expect(session.vodCategories, isEmpty);
    expect(session.xtreamApi, isNotNull);
    final api = Api();
    session.xtreamApi = api;
    session.profile = session.profile.copyWith(includeMovies: false);
    await session.ensureLibraryCategories();
    await session.ensureLibraryCategories();
    expect(api.categories, 1);
    expect(api.loads, 0);
    expect(session.vodGroups, isEmpty);
  });
  test('library requests deduplicate, serialize and retry without bulk loading',
      () async {
    final storage = MemoryStorage();
    await storage.init();
    final api = Api();
    final db = MemoryDb();
    var liveUpdates = 0, libraryUpdates = 0;
    final session = PlaylistSession(
        profile: PlaylistProfile(
            id: 'one',
            name: 'One',
            mode: 'xtream',
            sortOrder: 0,
            createdAt: DateTime(2026)),
        storage: storage,
        catalogDb: db,
        favoriteIds: () => {},
        favoriteSeriesIds: () => {},
        isRestrictedViewer: () => false,
        onNotify: () => liveUpdates++,
        onLibraryNotify: () => libraryUpdates++)
      ..xtreamApi = api;
    await Future.wait(
        [session.ensureLibraryCategories(), session.ensureLibraryCategories()]);
    expect(api.categories, 2);
    expect(liveUpdates, 0);
    expect(libraryUpdates, 1);
    expect(api.loads, 0);
    session.vodCategoryIdByName['Other'] = '2';
    await Future.wait([
      session.loadLibraryCategory('Cinema', 'vod'),
      session.loadLibraryCategory('Cinema', 'vod'),
      session.loadLibraryCategory('Other', 'vod')
    ]);
    expect(api.loads, 2);
    expect(api.peak, 1);
    expect(session.vodByCategoryName, isEmpty);
    await session.loadLibraryCategory('Cinema', 'vod');
    expect(api.loads, 2);
    api.fail = true;
    await expectLater(
        session.loadLibraryCategory('Cinema', 'vod', refresh: true),
        throwsStateError);
    expect(db.counts['Cinema'], 1);
    api.fail = false;
    await session.loadLibraryCategory('Cinema', 'vod', refresh: true);
    expect(api.loads, 4);
  });
  test(
      'rapid detail reopens share pending requests and errors remain retryable',
      () async {
    final storage = MemoryStorage();
    await storage.init();
    final api = Api()..detailGate = Completer<void>();
    final session = PlaylistSession(
      profile: PlaylistProfile(
          id: 'one',
          name: 'One',
          mode: 'xtream',
          sortOrder: 0,
          createdAt: DateTime(2026)),
      storage: storage,
      catalogDb: MemoryDb(),
      favoriteIds: () => {},
      favoriteSeriesIds: () => {},
      isRestrictedViewer: () => false,
      onNotify: () {},
    )..xtreamApi = api;
    final series = XtreamSeries(
        seriesId: 1, playlistId: 'one', name: 'Show', categoryId: 'Drama');
    final movies = [for (var i = 0; i < 30; i++) session.getVodInfo('1')];
    final episodes = [
      for (var i = 0; i < 30; i++) session.loadSeriesEpisodes(series)
    ];
    expect(api.detailLoads, 1);
    expect(api.episodeLoads, 1);
    api.detailGate!.complete();
    await Future.wait(movies);
    await Future.wait(episodes);
    api.detailGate = null;
    api.detailFailure = true;
    await expectLater(session.getVodInfo('2'), throwsStateError);
    api.detailFailure = false;
    await session.getVodInfo('2');
    expect(api.detailLoads, 3);
    final replacement = Api();
    session.xtreamApi = replacement;
    await session.getVodInfo('1');
    expect(replacement.detailLoads, 1);
  });
  test('saved categories open while another category download is stalled',
      () async {
    final storage = MemoryStorage();
    await storage.init();
    final api = Api()
      ..gate = Completer<void>()
      ..started = Completer<void>();
    final db = MemoryDb()..counts['Saved'] = 120;
    final session = PlaylistSession(
        profile: PlaylistProfile(
            id: 'one',
            name: 'One',
            mode: 'xtream',
            sortOrder: 0,
            createdAt: DateTime(2026)),
        storage: storage,
        catalogDb: db,
        favoriteIds: () => {},
        favoriteSeriesIds: () => {},
        isRestrictedViewer: () => false,
        onNotify: () {})
      ..xtreamApi = api;
    session.vodCategoryIdByName.addAll({'Slow': '1', 'Saved': '2'});
    final download = session.loadLibraryCategory('Slow', 'vod');
    await api.started!.future;
    try {
      await session
          .loadLibraryCategory('Saved', 'vod')
          .timeout(const Duration(seconds: 1));
      expect(api.loads, 1);
      expect(api.gate!.isCompleted, isFalse);
      expect(db.counts['Saved'], 120);
    } finally {
      api.gate!.complete();
      await download;
    }
  });
  test(
      'paged catalogue searches beyond 300, escapes wildcards and isolates playlists',
      () async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final dir = await Directory.systemTemp.createTemp('library-test-');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    messenger.setMockMethodCallHandler(channel, (_) async => dir.path);
    final db = CatalogDatabase();
    await db.upsertVodCategory('one', 'Cinema', [
      for (var i = 0; i < 5000; i++) movie(i),
      movie(5000, name: '100%_Real')
    ]);
    await db.upsertVodCategory('two', 'Cinema', [movie(8000, playlist: 'two')]);
    final first = await db.libraryPage(
        playlistId: 'one', category: 'Cinema', series: false);
    final next = await db.libraryPage(
        playlistId: 'one', category: 'Cinema', series: false, offset: 60);
    expect(first.total, 5001);
    expect(first.movies, hasLength(60));
    expect(next.movies.first.rawId, 'xt_vod_60');
    final search = await db.libraryPage(
        playlistId: 'one', category: 'Cinema', series: false, query: '4999');
    expect(search.movies.single.rawId, 'xt_vod_4999');
    expect(
        (await db.libraryPage(
                playlistId: 'one',
                category: 'Cinema',
                series: false,
                query: '%_'))
            .movies
            .single
            .name,
        '100%_Real');
    expect(
        (await db.libraryPage(
                playlistId: 'one',
                category: 'Cinema',
                series: false,
                sort: LibrarySort.newest))
            .movies
            .first
            .rawId,
        'xt_vod_5000');
    await db.upsertSeriesCategory(
        'one',
        'Drama',
        List.generate(
            350,
            (i) => XtreamSeries(
                seriesId: i,
                playlistId: 'one',
                name: 'Show $i',
                categoryId: '1')));
    expect(
        (await db.libraryPage(
                playlistId: 'one',
                category: 'Drama',
                series: true,
                query: '349'))
            .series
            .single
            .seriesId,
        349);
    final sql = await openDatabase('${dir.path}/nox_catalog.db');
    for (final table in ['vod_channels', 'series_items']) {
      final plan = await sql.rawQuery(
          'EXPLAIN QUERY PLAN SELECT * FROM $table '
          'WHERE playlist_id = ? AND category_name = ? ORDER BY rowid LIMIT 60 OFFSET 300',
          ['one', table == 'vod_channels' ? 'Cinema' : 'Drama']);
      expect(plan.map((r) => r['detail']).join(' '),
          contains('idx_${table}_provider'));
      expect(plan.map((r) => r['detail']).join(' '),
          isNot(contains('TEMP B-TREE')));
    }
    // Simulate the installed v9 catalogue: upgrade must add indexes in place,
    // retaining saved titles rather than rebuilding from the provider.
    for (final table in ['vod_channels', 'series_items']) {
      await sql.execute('DROP INDEX idx_${table}_provider');
    }
    await sql.execute('PRAGMA user_version = 9');
    await sql.close();
    final upgraded = CatalogDatabase();
    final saved = await upgraded.libraryPage(
        playlistId: 'one', category: 'Cinema', series: false);
    expect(saved.total, 5001);
    final migrated = await openDatabase('${dir.path}/nox_catalog.db');
    expect(await migrated.getVersion(), 10);
    for (final table in ['vod_channels', 'series_items']) {
      expect(
          await migrated.rawQuery(
              "SELECT name FROM sqlite_master WHERE name = ?",
              ['idx_${table}_provider']),
          hasLength(1));
    }
    await migrated.close();
    messenger.setMockMethodCallHandler(channel, null);
    await dir.delete(recursive: true);
  });
  testWidgets(
      'burst poster activation opens a single detail and restores browse focus',
      (tester) async {
    await mountLibrary(tester);
    final activate =
        tester.widget<HoldToActivate>(find.byType(HoldToActivate).first).onTap;
    for (var i = 0; i < 25; i++) {
      activate();
    }
    await tester.pumpAndSettle();
    expect(find.byType(MovieDetailScreen, skipOffstage: false), findsOneWidget);
    final navigator =
        Navigator.of(tester.element(find.byType(MovieDetailScreen)));
    navigator.pop();
    // A queued activation while the old detail is still leaving is ignored.
    activate();
    await tester.pumpAndSettle();
    expect(find.byType(MovieDetailScreen, skipOffstage: false), findsNothing);
    expect(find.byType(GridView), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
      'switching library type restores page and scroll without resetting the category',
      (tester) async {
    final env = await mountLibrary(tester);
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();
    final grid = tester.widget<GridView>(find.byType(GridView));
    grid.controller!.jumpTo(150);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Show navigation'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Series').first);
    await tester.pumpAndSettle();
    expect(find.text('Series 0'), findsOneWidget);
    await tester.tap(find.text('Movies').first);
    await tester.pumpAndSettle();
    expect(env.db.offsets.last, 60);
    expect(tester.widget<GridView>(find.byType(GridView)).controller!.offset,
        closeTo(150, 1));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
      'offline refresh keeps saved titles, page and scroll; shrinking catalogue clamps page',
      (tester) async {
    final env = await mountLibrary(tester);
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();
    tester.widget<GridView>(find.byType(GridView)).controller!.jumpTo(150);
    await tester.pumpAndSettle();
    env.manager.failRefresh = true;
    await tester.tap(find.byTooltip('Refresh this category'));
    await tester.pumpAndSettle();
    expect(env.db.offsets.last, 60);
    expect(
        find.text('Could not update. Showing saved titles.'), findsOneWidget);
    expect(tester.widget<GridView>(find.byType(GridView)).controller!.offset,
        closeTo(150, 1));
    env.manager.failRefresh = false;
    env.db.total = 12;
    await tester.tap(find.byTooltip('Refresh this category'));
    await tester.pumpAndSettle();
    expect(env.db.offsets.last, 0);
    expect(find.text('Film 0000'), findsWidgets);
    expect(find.text('Next'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
      'remote reaches short final row and page keys; fast navigation retains latest focus',
      (tester) async {
    await mountLibrary(tester, total: 11);
    final first = find.byWidgetPredicate(
        (w) => w is Focus && w.focusNode?.debugLabel == 'library-item-0');
    tester.widget<Focus>(first).focusNode!.requestFocus();
    await tester.pumpAndSettle();
    final grid = tester.widget<GridView>(find.byType(GridView));
    final columns =
        (grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount)
            .crossAxisCount;
    // Focus the last column of the first row; Down must reach the short row.
    final node = tester
        .widget<Focus>(find
            .byType(Focus)
            .evaluate()
            .map((e) => e.widget)
            .whereType<Focus>()
            .where(
                (w) => w.focusNode?.debugLabel == 'library-item-${columns - 1}')
            .map((w) => find.byWidget(w))
            .first)
        .focusNode!;
    node.requestFocus();
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'library-item-10');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus?.debugLabel,
        'library-item-${10 - columns}');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
      'rapid remote movement stays bounded and page keys load only one page',
      (tester) async {
    final env = await mountLibrary(tester);
    final first = find.byWidgetPredicate(
        (w) => w is Focus && w.focusNode?.debugLabel == 'library-item-0');
    tester.widget<Focus>(first).focusNode!.requestFocus();
    await tester.pumpAndSettle();
    for (var i = 0; i < 30; i++) {
      await tester.sendKeyEvent(i % 2 == 0
          ? LogicalKeyboardKey.arrowRight
          : LogicalKeyboardKey.arrowLeft);
      await tester.pump(const Duration(milliseconds: 16));
    }
    await tester.pumpAndSettle();
    expect(env.db.offsets, [0]);
    expect(env.manager.loads, 1);
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'library-item-0');
    expect(find.byType(HoldToActivate).evaluate().length, lessThan(45));
    await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
    await tester.pumpAndSettle();
    expect(env.db.offsets.last, 60);
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'library-item-0');
    await tester.sendKeyEvent(LogicalKeyboardKey.pageUp);
    await tester.pumpAndSettle();
    expect(env.db.offsets.last, 0);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
      'search discards an obsolete pending result and submits only the current query',
      (tester) async {
    final env = await mountLibrary(tester, size: const Size(844, 390));
    await tester.tap(find.byTooltip('Search titles'));
    await tester.pumpAndSettle();
    env.manager.pending = Completer<void>();
    await tester.enterText(find.byType(TextField), 'Film 0001');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.enterText(find.byType(TextField), 'Film 0012');
    env.manager.pending!.complete();
    env.manager.pending = null;
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(find.text('Film 0012'), findsWidgets);
    expect(find.text('Film 0001'), findsNothing);
    await tester.tap(find.byTooltip('Clear search'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNothing);
    expect(find.text('Film 0000'), findsWidgets);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
      'favourites shelf uses current saved state and has no misleading category dropdown',
      (tester) async {
    final env = await mountLibrary(tester);
    await env.storage.setFavorites({movie(5).id});
    await tester.tap(find.byKey(const ValueKey('library-shelf-favorites')));
    await tester.pumpAndSettle();
    expect(find.text('Film 0005'), findsOneWidget);
    expect(find.text('Your favourites'), findsOneWidget);
    expect(find.text('Cinema'), findsNothing);
    expect(find.byIcon(Icons.star), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('library-shelf-categories')));
    await tester.pumpAndSettle();
    expect(find.text('Cinema'), findsWidgets);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
      'TV Back and arrows reveal categories then main menu without refetching',
      (tester) async {
    final env = await mountLibrary(tester);
    expect(find.byKey(const ValueKey('library-navigation')), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(
        FocusManager.instance.primaryFocus?.debugLabel, 'library-categories');
    expect(find.byKey(const ValueKey('library-navigation')), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'library-item-0');
    expect(find.text('Categories'), findsNothing);
    final before = env.manager.loads;
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(
        FocusManager.instance.primaryFocus?.debugLabel, 'library-categories');
    expect(find.text('Categories'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('library-navigation')), findsOneWidget);
    expect(
        FocusManager.instance.primaryFocus?.debugLabel, 'library-navigation-2');
    expect(env.manager.loads, before);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
      'main menu Up reaches Sports and Live TV directly, including hidden tab settings',
      (tester) async {
    final env = await mountLibrary(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    expect(
        FocusManager.instance.primaryFocus?.debugLabel, 'library-navigation-1');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    expect(
        FocusManager.instance.primaryFocus?.debugLabel, 'library-navigation-0');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(
        FocusManager.instance.primaryFocus?.debugLabel, 'library-navigation-2');
    expect(env.manager.loads, 1);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
      'category branches expand inline and survive entering and leaving posters',
      (tester) async {
    final env = await mountLibrary(tester, organised: true, groups: [
      M3uGroup(title: 'EN - ACTION', playlistId: 'one', channels: []),
      M3uGroup(title: 'EN - DRAMA', playlistId: 'one', channels: []),
      M3uGroup(title: 'DE - ACTION', playlistId: 'one', channels: []),
      M3uGroup(title: 'DE - DRAMA', playlistId: 'one', channels: []),
    ]);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(find.text('English'), findsOneWidget);
    expect(find.text('Drama'), findsOneWidget);
    expect(find.text('International'), findsOneWidget);
    final before = env.manager.loads;
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp); // Focus folder.
    await tester.sendKeyEvent(LogicalKeyboardKey.select); // Collapse.
    await tester.pumpAndSettle();
    expect(find.text('Drama'), findsNothing);
    expect(find.text('International'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.select); // Expand in place.
    await tester.sendKeyEvent(LogicalKeyboardKey
        .arrowRight); // Current content, without changing the tree.
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('English'), findsOneWidget);
    expect(find.text('Drama'), findsOneWidget);
    expect(find.text('International'), findsOneWidget);
    expect(env.manager.loads, before);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
      'nested categories use OK for expansion and Left Back Right only move between columns',
      (tester) async {
    final env = await mountLibrary(tester, organised: true, groups: [
      M3uGroup(title: 'EN - ACTION', playlistId: 'one', channels: []),
      M3uGroup(title: 'EN - DRAMA', playlistId: 'one', channels: []),
      M3uGroup(title: 'NETFLIX MOVIES', playlistId: 'one', channels: []),
      M3uGroup(title: 'NETFLIX KIDS', playlistId: 'one', channels: []),
    ]);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    final before = env.manager.loads;
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    expect(
        FocusManager.instance.primaryFocus?.debugLabel, 'library-navigation-2');
    expect(find.text('Drama'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(
        FocusManager.instance.primaryFocus?.debugLabel, 'library-navigation-2');
    expect(find.text('Drama'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    // Highlighted Action -> previous row is the closed streaming folder.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'library-item-0');
    expect(env.manager.loads, before);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Kids'), findsNothing); // Right did not expand it.
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(find.text('Kids'), findsOneWidget); // OK expands in place.
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(
        FocusManager.instance.primaryFocus?.debugLabel, 'library-navigation-2');
    expect(find.text('Kids'), findsOneWidget); // Back did not collapse it.
    expect(env.manager.loads, before);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
      'mobile category search keeps typing focus and searches folder names',
      (tester) async {
    await mountLibrary(tester,
        size: const Size(390, 844),
        organised: true,
        groups: [
          M3uGroup(title: 'EN - ACTION', playlistId: 'one', channels: []),
          M3uGroup(title: 'NETFLIX MOVIES', playlistId: 'one', channels: []),
          M3uGroup(title: 'NETFLIX KIDS', playlistId: 'one', channels: []),
        ]);
    await tester.tap(find.byKey(const ValueKey('library-category-button')));
    await tester.pumpAndSettle();
    final search = find.byType(TextField).last;
    await tester.enterText(search, 'net');
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(search).focusNode!.hasFocus, isTrue);
    await tester.enterText(search, 'netflix');
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(search).focusNode!.hasFocus, isTrue);
    expect(find.text('English › Streaming services › Netflix'), findsWidgets);
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsNothing);
    expect(find.text('English › Streaming services › Netflix › Movies'),
        findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('TV toolbar reaches refresh, search and sort in visual order',
      (tester) async {
    await mountLibrary(tester);
    final first = find.byWidgetPredicate(
        (w) => w is Focus && w.focusNode?.debugLabel == 'library-item-0');
    tester.widget<Focus>(first).focusNode!.requestFocus();
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus?.debugLabel,
        'library-shelf-categories');
    for (var i = 0; i < 3; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
    }
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'library-refresh');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus?.debugLabel,
        'library-search-button');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'library-sort');
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(find.text('Provider order'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(find.text('Provider order'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
      'large organised rail browses folders with bounded focus and no downloads',
      (tester) async {
    final groups = [
      for (var i = 0; i < 1000; i++)
        M3uGroup(title: 'EN - Collection $i', playlistId: 'one', channels: [])
    ];
    final env = await mountLibrary(tester, organised: true, groups: groups);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    final before = env.manager.loads;
    for (var i = 0; i < 80; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(env.manager.loads, before);
    expect(find.byType(Focus).evaluate().length, lessThan(80));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    expect(
        FocusManager.instance.primaryFocus?.debugLabel, 'library-navigation-2');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(env.manager.loads, before); // Right enters the existing catalogue.
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'library-item-0');
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey
        .select); // Explicitly select the highlighted category.
    await tester.pumpAndSettle();
    expect(env.manager.loads, before + 1);
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'library-item-0');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  test('movie and series category selections persist independently', () async {
    final storage = StorageService();
    await storage.init();
    await storage.setLibraryBrowseSelection(false, ['one', 'Cinema', 'name']);
    await storage.setLibraryBrowseSelection(true, ['one', 'Drama', 'newest']);
    expect(storage.getLibraryBrowseSelection(false), ['one', 'Cinema', 'name']);
    expect(storage.getLibraryBrowseSelection(true), ['one', 'Drama', 'newest']);
  });
  for (final size in [
    const Size(390, 844),
    const Size(844, 390),
    const Size(960, 540)
  ]) {
    testWidgets(
        'library fits $size and pages without downloading every category',
        (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final storage = StorageService();
      await storage.init();
      final prefs = AppPreferences(storage);
      await prefs.init();
      prefs.isTelevision = size.width == 960;
      final db = MemoryDb();
      final manager = Manager(storage, db);
      await tester.pumpWidget(MultiProvider(
          providers: [
            Provider<StorageService>.value(value: storage),
            Provider<CatalogDatabase>.value(value: db),
            ChangeNotifierProvider<AppPreferences>.value(value: prefs),
            ChangeNotifierProvider<PlaylistManager>.value(value: manager)
          ],
          child: MaterialApp(
              theme: buildAppTheme(prefs.palette),
              home: const RepaintBoundary(child: LibraryScreen()))));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(manager.loads, 1);
      expect(find.text('Film 0000'), findsWidgets);
      expect(find.text('Film 0059'), findsNothing);
      await tester.tap(find.text('Next'));
      await tester.pumpAndSettle();
      expect(find.text('Film 0060'), findsWidgets);
      expect(manager.loads, 2);
      if (size.width >= 600) {
        await tester.tap(find.byTooltip('Search titles'));
        await tester.pumpAndSettle();
      }
      await tester.tap(find.byTooltip('Clear search'));
      await tester.pumpAndSettle();
      expect(find.text('Film 0000'), findsWidgets);
      if (prefs.isTelevision) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pumpAndSettle();
        expect(FocusManager.instance.primaryFocus?.debugLabel,
            startsWith('library-item-'));
        for (var i = 0; i < 6; i++) {
          await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
          await tester.pumpAndSettle();
        }
        expect(FocusManager.instance.primaryFocus?.debugLabel,
            startsWith('library-item-'));
      }
      if (const String.fromEnvironment('LAYOUT_FONT_DIR') != '') {
        // Match Android's default font for screenshot-only button styles.
        // The test engine otherwise substitutes Ahem for unspecified families.
        InlineSpan androidFont(InlineSpan span) => span is TextSpan
            ? TextSpan(
                text: span.text,
                style: (span.style ?? const TextStyle()).copyWith(
                    fontFamily: span.style?.fontFamily ?? 'Roboto'),
                children: span.children?.map(androidFont).toList())
            : span;
        for (final element in find.byType(RichText).evaluate()) {
          final paragraph = element.renderObject! as RenderParagraph;
          paragraph.text = androidFont(paragraph.text);
        }
        await tester.pump();
      }
      await tester.runAsync(() async {
        final boundary = tester.renderObject<RenderRepaintBoundary>(
            find.byType(RepaintBoundary).first);
        final img = await boundary.toImage();
        final bytes = await img.toByteData(format: ImageByteFormat.png);
        await File('/tmp/iptv107-library-${size.width.toInt()}.png')
            .writeAsBytes(bytes!.buffer.asUint8List());
        img.dispose();
      });
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      manager.dispose();
      prefs.dispose();
    });
  }
}
