import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:nox_iptv/models/playlist_profile.dart';
import 'package:nox_iptv/services/catalog_database.dart';
import 'package:nox_iptv/services/playlist_manager.dart';
import 'package:nox_iptv/services/playlist_session.dart';
import 'package:nox_iptv/services/storage_service.dart';

class MemoryStorage extends StorageService {
  bool fail = false;
  @override
  Future<void> writeCacheFile(String name, String content) async {}
  @override
  Future<void> setHiddenGroupsForType(
      String id, String type, Set<String> groups) async {
    await Future<void>.delayed(Duration.zero);
    if (fail) throw StateError('Storage unavailable');
    await super.setHiddenGroupsForType(id, type, groups);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late MemoryStorage storage;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    storage = MemoryStorage();
    await storage.init();
  });
  test(
      'legacy visibility is inherited, then separated by type, playlist and viewer',
      () async {
    await storage.setHiddenGroups('p', {'UK'});
    for (final type in ['tv', 'vod', 'series']) {
      expect(storage.getHiddenGroupsForType('p', type), {'UK'});
    }
    await storage.setHiddenGroupsForType('p', 'vod', {'US'});
    final restored = StorageService();
    await restored.init();
    expect(restored.getHiddenGroupsForType('p', 'tv'), {'UK'});
    expect(restored.getHiddenGroupsForType('p', 'series'), {'UK'});
    expect(restored.getHiddenGroupsForType('p', 'vod'), {'US'});
    expect(restored.getHiddenGroupsForType('other', 'vod'), isEmpty);
    await restored.setActiveViewerId('other');
    expect(restored.getHiddenGroupsForType('p', 'vod'), isEmpty);
  });
  test(
      'rapid independent changes persist in order; failed save leaves state intact and can retry',
      () async {
    final session = PlaylistSession(
        profile: PlaylistProfile(
            id: 'p',
            name: 'Test',
            mode: 'm3u',
            createdAt: DateTime(2026),
            sortOrder: 0),
        storage: storage,
        catalogDb: CatalogDatabase(),
        favoriteIds: () => {},
        favoriteSeriesIds: () => {},
        onNotify: () {});
    await Future.wait([
      session.setGroupHidden('UK', true, type: 'vod'),
      session.setGroupHidden('US', true, type: 'vod'),
      session.setGroupHidden('UK', true, type: 'series'),
    ]);
    expect(session.hiddenGroupsForType('vod'), {'UK', 'US'});
    expect(storage.getHiddenGroupsForType('p', 'vod'), {'UK', 'US'});
    expect(session.hiddenGroupsForType('series'), {'UK'});
    expect(session.hiddenGroups, isEmpty);
    storage.fail = true;
    await expectLater(
        session.setGroupHidden('UK', false, type: 'vod'), throwsStateError);
    expect(session.hiddenGroupsForType('vod'), {'UK', 'US'});
    storage.fail = false;
    await session.setGroupHidden('UK', false, type: 'vod');
    expect(session.hiddenGroupsForType('vod'), {'US'});
  });
  test(
      'category snapshots reuse data and invalidate for visibility, ordering and enabled state',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((r) async {
      r.response.write(
          '#EXTM3U\n#EXTINF:-1 group-title="UK",One\nhttps://example.invalid/never-play\n#EXTINF:-1 group-title="US",Two\nhttps://example.invalid/never-play2\n');
      await r.response.close();
    });
    final manager = PlaylistManager(storage, CatalogDatabase());
    addTearDown(manager.dispose);
    await manager.addPlaylist(PlaylistProfile(
        id: 'p',
        name: 'Test',
        mode: 'm3u',
        m3uUrl: 'http://127.0.0.1:${server.port}/list',
        createdAt: DateTime(2026),
        sortOrder: 0));
    await manager.loadPlaylist('p');
    final liveRevision = manager.liveRevision;
    await manager.setGroupHidden('p', 'UK', true, type: 'vod');
    expect(manager.liveRevision, liveRevision,
        reason: 'Movies visibility cannot restart live matching');
    final first = manager.tvGroups;
    expect(first.map((g) => g.title), ['UK', 'US']);
    expect(manager.tvGroups, same(first));
    manager.notifyLibraryChanged();
    expect(manager.tvGroups, same(first));
    await manager.setGroupHidden('p', 'UK', true);
    expect(manager.tvGroups, isNot(same(first)));
    expect(manager.tvGroups.first.isHidden, isTrue);
    expect(first.first.isHidden, isFalse);
    expect(() => manager.tvGroups.clear(), throwsUnsupportedError);
    await manager
        .updatePlaylist(manager.profiles.single.copyWith(enabled: false));
    expect(manager.tvGroups, isEmpty);
    expect(manager.groupsForPlaylist('p', 'tv'), hasLength(2),
        reason: 'Disabled playlists remain manageable');
  });
}
