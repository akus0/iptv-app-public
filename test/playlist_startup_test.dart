import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:nox_iptv/models/channel.dart';
import 'package:nox_iptv/models/playlist_profile.dart';
import 'package:nox_iptv/services/catalog_database.dart';
import 'package:nox_iptv/services/playlist_manager.dart';
import 'package:nox_iptv/services/storage_service.dart';
import 'package:nox_iptv/utils/constants.dart';
import 'package:nox_iptv/utils/live_category_folders.dart';

class _DelayedStorage extends StorageService {
  final cache = Completer<String?>();
  int reads = 0;
  String? preview;
  int writes = 0;
  bool failPreviewRead = false, failPreviewWrite = false;
  @override
  Future<String?> readCacheFile(String name) async {
    if (failPreviewRead) {
      throw const FileSystemException('Synthetic read failure');
    }
    return preview;
  }

  @override
  Future<void> writeCacheFile(String name, String content) async {
    if (failPreviewWrite) {
      throw const FileSystemException('Synthetic write failure');
    }
    preview = content;
    writes++;
  }

  @override
  Future<String?> cacheFilePath(String name) {
    reads++;
    return cache.future;
  }
}

class _NoNetwork extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      throw StateError('Startup tests must never contact any server');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    HttpOverrides.global = _NoNetwork();
    SharedPreferences.setMockInitialValues({
      AppConstants.keyMigratedToMultiPlaylist: true,
      AppConstants.keyFavoritesDbReconciled: true,
    });
  });
  tearDown(() => HttpOverrides.global = null);

  Future<_DelayedStorage> storage() async {
    final value = _DelayedStorage();
    await value.init();
    await value.setPlaylists([
      PlaylistProfile(
        id: 'fixture',
        name: 'Offline fixture',
        mode: 'm3u',
        m3uUrl: 'https://example.invalid/not-used',
        sortOrder: 0,
        createdAt: DateTime(2026),
      )
    ]);
    return value;
  }

  test(
      'background restore completes later without duplicate reads or lost channels',
      () async {
    final dir = await Directory.systemTemp.createTemp('iptv-startup-test-');
    addTearDown(() => dir.delete(recursive: true));
    final channel = Channel(
        id: 'fixture::one',
        rawId: 'one',
        playlistId: 'fixture',
        name: 'Cached channel',
        group: 'TV',
        url: 'https://example.invalid/never-play');
    final file = File('${dir.path}/cache.json');
    await file.writeAsString(jsonEncode([channel.toJson()]));
    final store = await storage();
    final playlist = PlaylistManager(store, CatalogDatabase());
    await playlist.init(restoreInBackground: true);
    expect(playlist.isLoading, isTrue);
    expect(playlist.hasLiveChannels, isFalse);
    expect(playlist.visibleLiveChannels, isEmpty);
    expect(playlist.profiles, hasLength(1));
    final first = playlist.ensureLiveChannelsLoaded();
    final second = playlist.ensureLiveChannelsLoaded();
    expect(identical(first, second), isTrue);
    store.cache.complete(file.path);
    await Future.wait([playlist.whenRestored, first, second]);
    expect(playlist.channels.single.name, 'Cached channel');
    expect(playlist.isLoading, isFalse);
    expect(playlist.error, isNull);
    expect(store.reads, 1);
    expect(store.getPlaylists().single.id, 'fixture');
    expect(store.getPlaylists().single.categoryLayout, 'provider');
    expect(playlist.hasLiveChannels, isTrue);
    final snapshot = playlist.visibleLiveChannels;
    expect(snapshot.single.name, 'Cached channel');
    expect(() => snapshot.clear(), throwsUnsupportedError);
    final revision = playlist.liveRevision;
    final allRevision = playlist.changeRevision;
    var notifications = 0;
    playlist.addListener(() => notifications++);
    playlist.notifyLibraryChanged();
    expect(playlist.changeRevision, greaterThan(allRevision));
    expect(playlist.liveRevision, revision);
    expect(identical(playlist.visibleLiveChannels, snapshot), isTrue);
    expect(notifications, 1);
    await playlist.toggleChannelHidden(snapshot.single);
    expect(playlist.liveRevision, greaterThan(revision));
    expect(playlist.visibleLiveChannels, isEmpty);
    await playlist.toggleChannelHidden(snapshot.single);
    expect(playlist.visibleLiveChannels, hasLength(1));
    await playlist.setPlaylistEnabled('fixture', false);
    expect(playlist.hasLiveChannels, isFalse);
    expect(playlist.visibleLiveChannels, isEmpty);
    await playlist.setPlaylistEnabled('fixture', true);
    expect(playlist.hasLiveChannels, isTrue);
    expect(playlist.visibleLiveChannels, hasLength(1));
    expect(store.reads, 1);
    playlist.dispose();
  });

  test(
      'cached curated playlist migrates to organised without provider requests',
      () async {
    final dir = await Directory.systemTemp.createTemp('iptv-layout-test-');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/cache.json');
    await file.writeAsString(jsonEncode([
      for (final country in ['UK', 'US'])
        Channel(
          id: 'fixture::$country',
          rawId: country,
          playlistId: 'fixture',
          name: 'Cached $country channel',
          group: 'TV Guide ($country)',
          url: 'https://example.invalid/never-play',
        ).toJson(),
    ]));
    final store = await storage();
    final playlist = PlaylistManager(store, CatalogDatabase());
    await playlist.init(restoreInBackground: true);
    store.cache.complete(file.path);
    await playlist.whenRestored;
    expect(playlist.categoryLayoutFor('fixture'), 'organised');
    expect(store.getPlaylists().single.categoryLayout, 'organised');
    expect(playlist.channels, hasLength(2));
    expect(store.reads, 1);
    playlist.dispose();
  });

  test(
      'category preview restores grouped sidebar before channels with current visibility and order',
      () async {
    final dir = await Directory.systemTemp.createTemp('iptv-category-preview-');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/channels.json');
    const titles = ['TV Guide (UK)', 'TV Guide (USA)', 'NBA League Pass'];
    await file.writeAsString(jsonEncode([
      for (var i = 0; i < 6000; i++)
        Channel(
                id: 'fixture::$i',
                rawId: '$i',
                playlistId: 'fixture',
                name: 'Cached channel $i',
                group: titles[i % titles.length],
                url: 'https://example.invalid/never-play')
            .toJson(),
    ]));
    final store = await storage();
    store.cache.complete(file.path);
    final first = PlaylistManager(store, CatalogDatabase());
    await first.init();
    expect(store.preview, isNotNull);
    expect(store.writes, 1);
    final preview = store.preview!;
    first.dispose();
    await store.setHiddenGroups('fixture', {'TV Guide (USA)'});
    await store
        .setGroupOrder('fixture', 'tv', ['NBA League Pass', 'TV Guide (UK)']);
    final second = PlaylistManager(store, CatalogDatabase());
    var early = false;
    second.addListener(() {
      if (second.hasLiveChannels || second.tvGroups.isEmpty) return;
      early = true;
      expect(second.tvGroups.first.title, 'NBA League Pass');
      expect(
          second.tvGroups
              .singleWhere((g) => g.title == 'TV Guide (USA)')
              .isHidden,
          isTrue);
      expect(second.tvGroups.every((g) => g.channels.isEmpty), isTrue);
      expect(second.categoryLayoutFor('fixture'), 'organised');
      final tree = buildLiveCategoryTree(
          second.tvGroups.where((g) => !g.isHidden).toList(),
          layouts: {'fixture': second.categoryLayoutFor('fixture')});
      expect(tree.any((node) => node.label == 'Sports'), isTrue);
    });
    await second.init();
    expect(early, isTrue);
    expect(second.channels, hasLength(6000));
    expect(store.writes, 1,
        reason:
            'An unchanged catalogue must not rewrite metadata every launch');
    expect(store.preview, preview);
    second.dispose();

    for (final invalid in [
      '{',
      jsonEncode({
        'version': 1,
        'source': 'another-source',
        'titles': ['Wrong category']
      })
    ]) {
      store.preview = invalid;
      final fallback = PlaylistManager(store, CatalogDatabase());
      var publishedPreview = false;
      fallback.addListener(() {
        if (!fallback.hasLiveChannels && fallback.tvGroups.isNotEmpty) {
          publishedPreview = true;
        }
      });
      await fallback.init();
      expect(publishedPreview, isFalse);
      expect(fallback.channels, hasLength(6000));
      expect(fallback.tvGroups.map((g) => g.title),
          isNot(contains('Wrong category')));
      fallback.dispose();
    }
    for (final readFailure in [true, false]) {
      store.preview = null;
      store.failPreviewRead = readFailure;
      store.failPreviewWrite = !readFailure;
      final fallback = PlaylistManager(store, CatalogDatabase());
      await fallback.init();
      expect(fallback.channels, hasLength(6000));
      expect(fallback.error, isNull);
      fallback.dispose();
    }
    store.failPreviewRead = store.failPreviewWrite = false;
    store.preview = preview;
    await file.writeAsString(jsonEncode([
      Channel(
              id: 'fixture::new',
              rawId: 'new',
              playlistId: 'fixture',
              name: 'New channel',
              group: 'New category',
              url: 'https://example.invalid/never-play')
          .toJson()
    ]));
    final changed = PlaylistManager(store, CatalogDatabase());
    await changed.init();
    expect(changed.tvGroups.map((g) => g.title), ['New category']);
    expect(changed.channels.single.rawId, 'new');
    expect(jsonDecode(store.preview!)['titles'], ['New category']);
    changed.dispose();
  });

  test(
      'failed background restore reports a guide error instead of an unhandled future',
      () async {
    final store = await storage();
    final playlist = PlaylistManager(store, CatalogDatabase());
    await playlist.init(restoreInBackground: true);
    store.cache.completeError(StateError('Offline fixture cache failed'));
    await playlist.whenRestored;
    expect(playlist.isLoading, isFalse);
    expect(playlist.error, contains('Could not load playlist'));
    expect(store.getPlaylists().single.categoryLayout, 'auto');
    await playlist.retryFailedConnections();
    expect(playlist.error, contains('Could not load playlist'));
    expect(store.getPlaylists(), hasLength(1));
    playlist.dispose();
  });
}
