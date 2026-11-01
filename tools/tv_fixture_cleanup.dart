// Device-only cleanup after tv_fixture_server.py tests. Never shipped.
// Requires the exact locally served fixture URL; unrelated playlists and
// history entries are left intact. Does not connect to any source or stream.
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:nox_iptv/services/storage_service.dart';
import 'package:nox_iptv/utils/constants.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  var status = 'Fixture cleanup failed';
  try {
    const url = String.fromEnvironment('IPTV_FIXTURE_URL');
    final uri = Uri.parse(url);
    if (uri.scheme != 'http' ||
        uri.path != '/fixture.m3u' ||
        uri.port != 8911) {
      throw StateError('An exact local fixture URL is required');
    }
    final storage = StorageService();
    await storage.init();
    final all = storage.getPlaylists();
    final fixtures = all
        .where((p) => p.name == 'Performance test' && p.m3uUrl == url)
        .toList();
    if (fixtures.length != 1) throw StateError('Expected one test playlist');
    final id = fixtures.single.id;
    final viewer = storage.getActiveViewerId();
    final key = viewer == AppConstants.mainViewerId
        ? 'recently_played'
        : 'recently_played_vp_$viewer';
    final raw = await storage.readCacheFile(key);
    final history = raw == null ? <dynamic>[] : jsonDecode(raw) as List;
    final retained = history.where((c) => c['playlistId'] != id).toList();
    final last = storage.getLastChannelId();
    if (last != null && last.startsWith('$id::')) {
      await storage.setLastChannelId(
          retained.isEmpty ? '' : retained.first['id'] as String);
    }
    await storage.writeCacheFile(key, jsonEncode(retained));
    await storage.setPlaylists(all.where((p) => p.id != id).toList());
    await storage.deleteCacheFile('${AppConstants.cacheFileM3uChannels}_$id');
    status =
        'Fixture removed; ${storage.getPlaylists().length} original playlist(s) retained; ${history.length - retained.length} test history entries removed';
  } catch (error) {
    status = 'Fixture cleanup failed: ${error.runtimeType}';
  }
  // ignore: avoid_print
  print('IPTV_FIXTURE_CLEANUP $status');
  runApp(MaterialApp(home: Scaffold(body: Center(child: Text(status)))));
}
