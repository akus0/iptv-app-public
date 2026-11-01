import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:nox_iptv/models/playlist_profile.dart';
import 'package:nox_iptv/services/catalog_database.dart';
import 'package:nox_iptv/services/playlist_manager.dart';
import 'package:nox_iptv/services/storage_service.dart';

class _MemoryStorage extends StorageService {
  @override
  Future<void> writeCacheFile(String name, String content) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('editing a working M3U does not inherit another playlist HTTP error',
      () async {
    SharedPreferences.setMockInitialValues({});
    final storage = _MemoryStorage();
    await storage.init();
    final manager = PlaylistManager(storage, CatalogDatabase());
    addTearDown(manager.dispose);
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final requested = <String>[];
    server.listen((request) async {
      requested.add(request.uri.path);
      if (request.uri.path == '/denied') {
        request.response.statusCode = 403;
      } else {
        request.response.write(
            '#EXTM3U\n#EXTINF:-1 tvg-id="one" group-title="TV",Channel One\nhttps://example.invalid/never-play\n');
      }
      await request.response.close();
    });
    String url(String path) => 'http://127.0.0.1:${server.port}/$path';
    PlaylistProfile profile(String id, String path) => PlaylistProfile(
        id: id,
        name: id,
        mode: 'm3u',
        m3uUrl: url(path),
        createdAt: DateTime(2026),
        sortOrder: 0,
        categoryLayout: 'organised');
    await manager.addPlaylist(profile('other', 'denied'));
    await manager.addPlaylist(profile('edited', 'original'));
    await manager.loadPlaylist('other');
    expect(manager.error, contains('403'));
    final edited = manager.profiles.singleWhere((p) => p.id == 'edited');
    await manager.updatePlaylist(edited.copyWith(m3uUrl: url('replacement')));
    await manager.loadPlaylist('edited');
    expect(requested, ['/denied', '/replacement']);
    expect(manager.channels.single.name, 'Channel One');
    expect(storage.getPlaylists().singleWhere((p) => p.id == 'edited').m3uUrl,
        url('replacement'));
    expect(manager.profiles.singleWhere((p) => p.id == 'edited').categoryLayout,
        'organised');
    expect(manager.anyPlaylistError, contains('403'));
    expect(manager.error, isNull,
        reason:
            'The successful foreground edit must not show another playlist failure.');
    await manager.updatePlaylist(manager.profiles
        .singleWhere((p) => p.id == 'edited')
        .copyWith(m3uUrl: url('denied')));
    await manager.loadPlaylist('edited');
    expect(manager.error, contains('403'));
    expect(manager.channels.single.name, 'Channel One',
        reason: 'Failed refresh retains cached channels.');
    await manager.updatePlaylist(manager.profiles
        .singleWhere((p) => p.id == 'edited')
        .copyWith(m3uUrl: url('recovered')));
    await manager.loadPlaylist('edited');
    expect(manager.error, isNull);
    expect(requested, ['/denied', '/replacement', '/denied', '/recovered']);
  });
}
