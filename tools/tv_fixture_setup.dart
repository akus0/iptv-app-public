// Device-only fixture setup for repeatable TV measurements. Never shipped.
import 'dart:convert';
import 'package:nox_iptv/models/channel.dart';
import 'package:nox_iptv/models/playlist_profile.dart';
import 'package:nox_iptv/services/storage_service.dart';
import 'package:nox_iptv/utils/constants.dart';

Future<void> installLocalFixture(String url) async {
  final uri = Uri.parse(url);
  if (uri.scheme != 'http' ||
      uri.port != 8911 ||
      uri.path != '/fixture.m3u' ||
      !uri.host.startsWith('192.168.')) {
    throw ArgumentError('A local fixture URL is required');
  }
  final storage = StorageService();
  await storage.init();
  final profiles = storage.getPlaylists();
  const id = 'tv_performance_fixture';
  final existing = profiles.where((p) => p.id == id).firstOrNull;
  if (existing != null &&
      (existing.name != 'Performance test' || existing.m3uUrl != url)) {
    throw StateError('Fixture ID already in use');
  }
  final rows = [
    for (final (key, label, path) in [
      ('tv-test-live', 'Local live test', '/live.m3u8'),
      ('tv-test-seek', 'Local seek test', '/vod.m3u8'),
    ])
      Channel(
          id: '$id::$key',
          rawId: key,
          playlistId: id,
          name: label,
          group: 'Performance test',
          url: uri.replace(path: path).toString())
  ];
  await storage.writeCacheFile('${AppConstants.cacheFileM3uChannels}_$id',
      jsonEncode(rows.map((c) => c.toJson()).toList()));
  if (existing == null) {
    await storage.setPlaylists([
      ...profiles,
      PlaylistProfile(
          id: id,
          name: 'Performance test',
          mode: 'm3u',
          m3uUrl: url,
          sortOrder: profiles.length,
          createdAt: DateTime.now())
    ]);
  }
}
