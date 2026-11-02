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

class _DelayedStorage extends StorageService {
  final cache = Completer<String?>();
  int reads = 0;
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
