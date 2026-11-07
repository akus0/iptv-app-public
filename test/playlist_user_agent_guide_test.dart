import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:nox_iptv/models/playlist_profile.dart';
import 'package:nox_iptv/services/catalog_database.dart';
import 'package:nox_iptv/services/epg_service.dart';
import 'package:nox_iptv/services/playlist_manager.dart';
import 'package:nox_iptv/services/storage_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
      'guide overrides survive redirects and never spill into other playlists or supplements',
      () async {
    HttpOverrides.global = null;
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final dir = await Directory.systemTemp.createTemp('playlist-agent-guide-');
    const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(pathChannel, (_) async => dir.path);
    SharedPreferences.setMockInitialValues({});
    final storage = StorageService();
    await storage.init();
    final manager = PlaylistManager(storage, CatalogDatabase());
    final guide = EpgService(storage);
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() async {
      guide.dispose();
      manager.dispose();
      await server.close(force: true);
      messenger.setMockMethodCallHandler(pathChannel, null);
      await databaseFactory.deleteDatabase('${dir.path}/vesper_epg.db');
      await dir.delete(recursive: true);
    });
    var expected = 'TiviMate';
    final requests = <(String, String?)>[];
    final now = DateTime.now().toUtc();
    String stamp(DateTime d) =>
        '${d.toIso8601String().replaceAll(RegExp(r'[-:T]'), '').substring(0, 14)} +0000';
    server.listen((r) async {
      final agent = r.headers.value('user-agent');
      requests.add((r.uri.path, agent));
      final custom = r.uri.path.contains('first');
      final valid = custom && expected.isNotEmpty
          ? agent == expected
          : agent?.startsWith('Dart/') == true;
      if (!valid) {
        r.response.statusCode = 403;
      } else if (r.uri.path == '/first') {
        r.response.statusCode = 302;
        r.response.headers.set('Location', '/xml/first');
      } else {
        final id = r.uri.path.split('/').last;
        r.response.write(
            '<tv><programme channel="$id" start="${stamp(now.subtract(const Duration(hours: 1)))}" stop="${stamp(now.add(const Duration(hours: 2)))}"><title>Fixture programme</title></programme></tv>');
      }
      await r.response.close();
    });
    final base = 'http://127.0.0.1:${server.port}';
    for (final id in ['first', 'default']) {
      await manager.addPlaylist(PlaylistProfile(
          id: id,
          name: id,
          mode: 'm3u',
          sortOrder: 0,
          createdAt: DateTime(2026),
          epgUrl: '$base/$id',
          userAgent: id == 'first' ? expected : ''));
    }
    guide.startAutoRefresh(360, manager.epgSources);
    guide.supplementarySources = () async => [
          EpgSource(url: '$base/extra', knownChannelIds: {'extra'})
        ];
    for (final agent in ['TiviMate', 'VLC', '']) {
      expected = agent;
      requests.clear();
      await manager.setPlaylistUserAgent('first', agent);
      await guide.refreshAll();
      expect(guide.error, isNull);
      for (final id in ['first', 'default', 'extra']) {
        expect(guide.getCurrentProgram(id), isNotNull);
      }
      expect(requests.map((r) => r.$1),
          ['/first', '/xml/first', '/default', '/extra']);
      expect(
          requests
              .where((r) => !r.$1.contains('first'))
              .every((r) => r.$2!.startsWith('Dart/')),
          isTrue);
      if (agent.isNotEmpty) {
        expect(requests.take(2).every((r) => r.$2 == agent), isTrue);
      }
    }
    expected = 'IPTVSmartersPro';
    requests.clear();
    await guide.refresh('$base/first',
        knownChannelIds: {'first'}, headers: {'User-Agent': expected});
    expect(guide.error, isNull);
    expect(requests.take(2).every((r) => r.$2 == expected), isTrue,
        reason:
            'The initial Add Playlist guide request uses the same override');
  });
}
