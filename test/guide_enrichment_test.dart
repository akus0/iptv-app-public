import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:nox_iptv/models/channel.dart';
import 'package:nox_iptv/models/playlist_profile.dart';
import 'package:nox_iptv/services/catalog_database.dart';
import 'package:nox_iptv/services/epg_service.dart';
import 'package:nox_iptv/services/playlist_manager.dart';
import 'package:nox_iptv/services/storage_service.dart';
import 'package:nox_iptv/utils/constants.dart';
import 'package:nox_iptv/utils/guide_enrichment.dart';

Channel c(String id, String name, [String group = 'AU| Sports']) => Channel(
    id: 'test::$id',
    rawId: id,
    playlistId: 'test',
    name: name,
    group: group,
    url: 'https://example.invalid/never-open');

class _Storage extends StorageService {
  _Storage(this.path);
  final String path;
  @override
  Future<String?> cacheFilePath(String name) async => path;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('reviewed aliases respect regions, numbers, shifts and event feeds', () {
    expect(guideEnrichmentMatch(c('a', 'Fox Sports 503'))!.primaryId,
        'nsw-sydneyfoxsports503.au');
    expect(
        guideEnrichmentMatch(
                c('old.us', 'Baby TV (USA)', '🇬🇧 TV Guide (UK)'))!
            .primaryId,
        'babytv.us');
    expect(
        guideEnrichmentMatch(c('a', 'TNT Sports 10 ᴴᴰ', 'UK| TNT Sports'))!
            .externalId,
        'tntsports10.uk');
    for (final channel in [
      c('a', 'Fox Sports 503 +1'),
      c('a', 'Fox Sports 503 West'),
      c('a', 'Fox Sports 503', 'UK| Sports'),
      c('a', 'Sky Racing 2', 'AU| RACING PPV'),
      c('a', '### Fox Sports 503'),
      c('a', 'Channel 9 (Vic)'),
      c('mtv2west.us', 'MTV2', 'US| Entertainment'),
      c('a', 'Arirang', 'UK| Entertainment'),
    ]) {
      expect(guideEnrichmentMatch(channel), isNull, reason: channel.name);
    }
  });
  test(
      'repair first, supplement missing data only, persist sources and reuse fresh data',
      () async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final dir = await Directory.systemTemp.createTemp('iptv-guide-fill-');
    const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(pathChannel, (_) async => dir.path);
    SharedPreferences.setMockInitialValues({
      AppConstants.keyMigratedToMultiPlaylist: true,
      AppConstants.keyFavoritesDbReconciled: true
    });
    final file = File('${dir.path}/channels.json');
    await file.writeAsString(jsonEncode([
      c('a', 'Fox Sports 503'),
      c('b', 'Bein Sports 1'),
      c('c', 'Bein Sports 2'),
      c('d', 'Bein Sports 3'),
      c('e', 'Sky Racing 2'),
      c('f', 'Fox Sports 503 +1'),
    ].map((c) => c.toJson()).toList()));
    final storage = _Storage(file.path);
    await storage.init();
    await storage.setPlaylists([
      PlaylistProfile(
          id: 'test',
          name: 'Fixture',
          mode: 'm3u',
          m3uUrl: 'https://example.invalid/never-fetch',
          epgUrl: 'https://example.invalid/guide',
          sortOrder: 0,
          createdAt: DateTime.now())
    ]);
    await storage.setEpgIdOverrides('test', {'c': 'manual'});
    final playlist = PlaylistManager(storage, CatalogDatabase());
    await playlist.init(restoreInBackground: true);
    await playlist.whenRestored;
    final epg = EpgService(storage);
    addTearDown(() async {
      playlist.dispose();
      epg.dispose();
      messenger.setMockMethodCallHandler(pathChannel, null);
      await databaseFactory.deleteDatabase('${dir.path}/vesper_epg.db');
      await dir.delete(recursive: true);
    });
    final now = DateTime.now().toUtc();
    String stamp(DateTime d) =>
        '${d.toIso8601String().replaceAll(RegExp(r'[-:T]'), '').substring(0, 14)} +0000';
    String row(String id, String title) =>
        '<programme channel="$id" start="${stamp(now.subtract(const Duration(hours: 1)))}" stop="${stamp(now.add(const Duration(hours: 2)))}"><title>$title</title></programme>';
    final source = guideEnrichmentSources.first;
    var primaryRequests = 0, publicRequests = 0;
    var fail = false;
    await http.runWithClient(() async {
      final known = playlist.knownChannelIdsFor('test');
      expect(known, contains('nsw-sydneyfoxsports503.au'));
      await epg.refresh('https://example.invalid/guide',
          knownChannelIds: known);
      expect(await playlist.applyGuideEnrichment(epg), 1);
      expect(
          storage.getEpgIdOverrides('test')['a'], 'nsw-sydneyfoxsports503.au');
      final ids = playlist.guideEnrichmentCandidates(epg, source);
      expect(
          ids, {'iptv-fill-au:beinsports1.au', 'iptv-fill-au:skyracing2.au'});
      await epg.refresh(source.url, knownChannelIds: ids);
      expect(await playlist.applyGuideEnrichment(epg), 1);
      expect(storage.getEpgIdOverrides('test')['b'],
          'iptv-fill-au:beinsports1.au');
      expect(storage.getEpgIdOverrides('test')['c'], 'manual');
      expect(storage.getEpgIdOverrides('test').containsKey('d'), false);
      expect(storage.getEpgIdOverrides('test').containsKey('e'), false);
      expect(epg.getCurrentProgram('d')!.title, 'Working primary programme');
      final storedSource = (await playlist.supplementaryGuideSources(epg))
          .singleWhere((s) => s.url == source.url);
      expect(storedSource.knownChannelIds,
          {'iptv-fill-au:beinsports1.au', 'iptv-fill-au:skyracing2.au'});
      expect(playlist.guideEnrichmentCandidates(epg, source),
          contains('iptv-fill-au:beinsports1.au'));
      await epg.refresh(source.url,
          knownChannelIds: storedSource.knownChannelIds);
      expect(
          publicRequests, 1); // no repeated downloads while current data exists
      fail = true;
      await epg
          .refresh(source.url, knownChannelIds: {'iptv-fill-au:new-channel'});
      expect(epg.error, isNotNull);
      expect(epg.getCurrentProgram('iptv-fill-au:beinsports1.au')!.title,
          'Live tennis');
      expect(await playlist.applyGuideEnrichment(epg), 0);
    },
        () => MockClient((request) async {
              expect(request.url.fragment, isEmpty);
              if (request.url.host == 'example.invalid') {
                primaryRequests++;
                return http.Response(
                    '<tv>${row('nsw-sydneyfoxsports503.au', 'Golf')}${row('d', 'Working primary programme')}</tv>',
                    200);
              }
              expect(request.url.host, 'iptv-epg.org');
              publicRequests++;
              if (fail) return http.Response('Unavailable', 503);
              return http.Response(
                  '<tv>${row('beinsports1.au', 'Live tennis')}${row('skyracing2.au', 'No Data')}${row('beinsports3.au', 'Different public programme')}</tv>',
                  200);
            }));
    expect(primaryRequests, 1);
    expect(publicRequests, 2);
  });
}
