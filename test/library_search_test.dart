import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nox_iptv/models/m3u_group.dart';
import 'package:nox_iptv/models/xtream_series.dart';
import 'package:nox_iptv/services/catalog_database.dart';
import 'package:nox_iptv/services/library_search_loader.dart';
import 'package:nox_iptv/services/storage_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'library_test.dart' show MemoryDb, Manager, movie, mountLibrary;

class _LoaderManager extends Manager {
  _LoaderManager(super.storage, super.catalogDb);
  final requests = <(String, String, String)>[];
  final failures = <String>{};
  Completer<void>? gate;
  @override
  Future<void> loadLibraryCategory(String playlistId, String name, String type,
      {bool refresh = false}) async {
    requests.add((playlistId, name, type));
    await gate?.future;
    if (failures.contains(name)) throw StateError('offline');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
      'SQL searches all allowed categories with stable pages and literal wildcards',
      () async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final dir = await Directory.systemTemp.createTemp('library-search-');
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (_) async => dir.path);
    final db = CatalogDatabase();
    addTearDown(() async {
      await (await openDatabase('${dir.path}/nox_catalog.db')).close();
      messenger.setMockMethodCallHandler(channel, null);
      await dir.delete(recursive: true);
    });
    await db.upsertVodCategory('one', 'Cinema', [
      for (var i = 0; i < 400; i++) movie(i, name: 'Shared $i'),
    ]);
    await db.upsertVodCategory('two', "Children's", [
      movie(500, playlist: 'two', group: "Children's", name: 'Shared 500'),
      movie(501, playlist: 'two', group: "Children's", name: r'100%_Real\Film'),
    ]);
    await db.upsertVodCategory(
        'one', 'Hidden', [movie(900, name: 'Shared hidden')]);
    await db.upsertVodCategory('disabled', 'Cinema',
        [movie(901, playlist: 'disabled', name: 'Shared disabled')]);
    final groups = [
      (playlistId: 'one', title: 'Cinema'),
      (playlistId: 'two', title: "Children's"),
      (
        playlistId: 'one',
        title: 'Cinema'
      ), // duplicate scope cannot duplicate results
      for (var i = 0; i < 1200; i++) (playlistId: 'one', title: 'Unused $i'),
    ];
    final ids = <String>{};
    for (var offset = 0; offset < 401; offset += 60) {
      final page = await db.searchLibraryPage(
          groups: groups,
          series: false,
          query: 'sHaReD',
          sort: LibrarySort.name,
          offset: offset);
      expect(page.total, 401);
      expect(page.movies.length, lessThanOrEqualTo(60));
      for (final item in page.movies) {
        expect(ids.add(item.id), isTrue);
      }
    }
    expect(ids, contains('two::xt_vod_500'));
    expect(ids, isNot(contains('one::xt_vod_900')));
    final wildcard = await db.searchLibraryPage(
        groups: groups, series: false, query: r'%_Real\');
    expect(wildcard.movies.single.rawId, 'xt_vod_501');
    final newest = await db.searchLibraryPage(
        groups: groups,
        series: false,
        query: 'Shared',
        sort: LibrarySort.newest);
    expect(newest.movies.first.rawId, 'xt_vod_500');
    await db.upsertSeriesCategory('two', 'Drama', [
      XtreamSeries(
          seriesId: 1,
          playlistId: 'two',
          name: 'Shared show',
          categoryId: 'Drama'),
    ]);
    // Concurrent content/scope changes must not reuse another request's allowlist.
    final results = await Future.wait([
      db.searchLibraryPage(
          groups: [(playlistId: 'two', title: 'Drama')],
          series: true,
          query: 'shared'),
      db.searchLibraryPage(
          groups: [(playlistId: 'one', title: 'Cinema')],
          series: false,
          query: 'shared'),
    ]);
    expect(results[0].series.single.name, 'Shared show');
    expect(results[0].movies, isEmpty);
    expect(results[1].total, 400);
    expect(
        (await db.searchLibraryPage(groups: [], series: false, query: 'Shared'))
            .total,
        0);
    expect(await db.storedLibraryGroups(series: true),
        {(playlistId: 'two', title: 'Drama')});
  });

  test(
      'missing categories load sequentially, cancel between requests, and retry failures',
      () async {
    final db = MemoryDb();
    final manager = _LoaderManager(StorageService(), db);
    addTearDown(manager.dispose);
    final loader = LibrarySearchLoader(db, manager);
    final groups = [
      (playlistId: 'one', title: 'Cinema'), // already on disk
      (playlistId: 'one', title: 'Missing'),
      (playlistId: 'two', title: 'Empty'),
      (playlistId: 'two', title: 'Offline'),
    ];
    var current = true;
    final progress = <(int, int, bool, bool)>[];
    manager.gate = Completer<void>();
    final first = loader.load(
        series: false,
        groups: groups,
        isCurrent: () => current,
        onProgress: (d, t, c, f) => progress.add((d, t, c, f)));
    await Future<void>.delayed(Duration.zero);
    expect(manager.requests, [('one', 'Missing', 'vod')]);
    current = false;
    manager.gate!.complete();
    await first;
    expect(manager.requests, hasLength(1));
    current = true;
    manager.gate = null;
    manager.failures.add('Offline');
    await loader.load(
        series: false,
        groups: groups,
        isCurrent: () => current,
        onProgress: (d, t, c, f) => progress.add((d, t, c, f)));
    expect(manager.requests.map((r) => r.$2), ['Missing', 'Empty', 'Offline']);
    expect(progress.last, (2, 2, false, true));
    manager.failures.clear();
    await loader.load(
        series: false,
        groups: groups,
        isCurrent: () => current,
        onProgress: (d, t, c, f) => progress.add((d, t, c, f)));
    expect(manager.requests.map((r) => r.$2),
        ['Missing', 'Empty', 'Offline', 'Offline']);
    expect(progress.last, (1, 1, true, false));
    // Movie checks must never suppress same-named series categories.
    await loader.load(
        series: true,
        groups: [groups[1]],
        isCurrent: () => true,
        onProgress: (_, __, ___, ____) {});
    expect(manager.requests.last, ('one', 'Missing', 'series'));
  });

  for (final size in [const Size(390, 844), const Size(960, 540)]) {
    testWidgets(
        'whole library search, paging, clear and content switching at $size',
        (tester) async {
      final env = await mountLibrary(tester, total: 500, size: size, groups: [
        M3uGroup(title: 'Cinema', playlistId: 'one', channels: []),
        M3uGroup(title: 'Other', playlistId: 'two', channels: []),
        M3uGroup(
            title: 'Hidden', playlistId: 'one', channels: [], isHidden: true),
      ]);
      if (size.width >= 600) {
        await tester.tap(find.byTooltip('Search titles'));
        await tester.pumpAndSettle();
      }
      expect(find.text('Search all movies'), findsOneWidget);
      if (size.width >= 600) {
        await tester.sendKeyEvent(LogicalKeyboardKey.select);
        await tester.pump();
      }
      await tester.enterText(find.byType(TextField), 'Film');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(env.db.searches.last.groups, {
        (playlistId: 'one', title: 'Cinema'),
        (playlistId: 'two', title: 'Other')
      });
      expect(find.text('All movie categories'), findsOneWidget);
      final loads = env.manager.loads;
      await tester.tap(find.text('Next'));
      await tester.pumpAndSettle();
      expect(env.db.searches.last.offset, 60);
      expect(env.manager.loads, loads,
          reason: 'Paging must not restart category downloads');
      await tester.tap(find.byTooltip('Clear search'));
      await tester.pumpAndSettle();
      expect(find.text('All movie categories'), findsNothing);
      expect(find.text('Cinema'), findsWidgets);
      // Mobile bottom bar and TV rail both expose the content switch.
      if (size.width >= 600) {
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
      }
      await tester.tap(find.text('Series').first);
      await tester.pumpAndSettle();
      if (size.width >= 600) {
        await tester.tap(find.byTooltip('Search titles'));
        await tester.pumpAndSettle();
      }
      expect(find.text('Search all series'), findsOneWidget);
      if (size.width >= 600) {
        await tester.sendKeyEvent(LogicalKeyboardKey.select);
        await tester.pump();
      }
      await tester.enterText(find.byType(TextField), 'Series 49');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(env.db.searches.last.series, isTrue);
      expect(
          env.db.searches.last.groups, {(playlistId: 'one', title: 'Drama')});
      expect(find.text('Series 49'), findsWidgets);
      expect(find.text('Film 0049'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
  testWidgets(
      'late categories preserve the focused results until Update is requested',
      (tester) async {
    final env = await mountLibrary(tester,
        total: 500,
        size: const Size(390, 844),
        groups: [
          M3uGroup(title: 'Cinema', playlistId: 'one', channels: []),
          M3uGroup(title: 'Missing', playlistId: 'two', channels: []),
        ]);
    final gate = Completer<void>();
    env.manager.downloadPending = gate;
    await tester.enterText(find.byType(TextField), 'Film');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(find.text('500 titles'), findsOneWidget);
    expect(
        find.textContaining('Searching remaining categories'), findsOneWidget);
    final node = tester
        .widgetList<Focus>(find.byType(Focus))
        .map((w) => w.focusNode)
        .whereType<FocusNode>()
        .firstWhere((n) => n.debugLabel == 'library-item-0');
    node.requestFocus();
    await tester.pumpAndSettle();
    env.db.total = 501;
    gate.complete();
    await tester.pumpAndSettle();
    expect(node.hasFocus, isTrue);
    expect(find.text('500 titles'), findsOneWidget);
    expect(find.text('Update results'), findsOneWidget);
    await tester.tap(find.text('Update results'));
    await tester.pumpAndSettle();
    expect(find.text('501 titles'), findsOneWidget);
    expect(find.text('Update results'), findsNothing);
    expect(node.hasFocus, isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'clearing search stops remaining downloads and restores the category',
      (tester) async {
    final env = await mountLibrary(tester, size: const Size(390, 844), groups: [
      M3uGroup(title: 'Cinema', playlistId: 'one', channels: []),
      M3uGroup(title: 'Missing', playlistId: 'two', channels: []),
      M3uGroup(title: 'Later', playlistId: 'two', channels: []),
    ]);
    final gate = Completer<void>();
    env.manager.downloadPending = gate;
    await tester.enterText(find.byType(TextField), 'Film');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(env.manager.categoryRequests, ['Cinema', 'Missing']);
    await tester.tap(find.byTooltip('Clear search'));
    await tester.pump();
    gate.complete();
    await tester.pumpAndSettle();
    expect(env.manager.categoryRequests, ['Cinema', 'Missing', 'Cinema']);
    expect(find.text('Cinema'), findsWidgets);
    expect(find.textContaining('Searching remaining categories'), findsNothing);
    expect(find.text('Update results'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
