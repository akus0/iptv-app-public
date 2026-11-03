import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:nox_iptv/models/custom_guide_source.dart';
import 'package:nox_iptv/models/playlist_profile.dart';
import 'package:nox_iptv/services/catalog_database.dart';
import 'package:nox_iptv/services/epg_service.dart';
import 'package:nox_iptv/services/playlist_manager.dart';
import 'package:nox_iptv/services/storage_service.dart';
import 'package:nox_iptv/utils/constants.dart';
import 'guide_enrichment_test.dart' show c;

class _Storage extends StorageService {
  _Storage(this.path);
  final String path;
  @override
  Future<String?> cacheFilePath(String name) async => path;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('custom guide settings round trip, validate URLs and isolate identities',
      () async {
    SharedPreferences.setMockInitialValues({});
    final storage = StorageService();
    await storage.init();
    const source = CustomGuideSource(
        id: 'test',
        name: 'Fixture',
        url: 'https://example.test/guide.xml.gz?token=fixture');
    await storage.setCustomGuideSources([source.withEnabled(false)]);
    final saved = storage.getCustomGuideSources().single;
    expect(saved.name, 'Fixture');
    expect(saved.enabled, isFalse);
    expect(Uri.parse(saved.sourceUrl).queryParameters, {'token': 'fixture'});
    expect(customGuideNamespace(saved.sourceUrl), saved.prefix);
    expect(
        CustomGuideSource.validateUrl(
            ' https://example.test/guide.xml#fragment '),
        'https://example.test/guide.xml');
    for (final invalid in [
      '',
      'file:///tmp/guide.xml',
      'http://',
      'http://example.test:99999'
    ]) {
      expect(
          () => CustomGuideSource.validateUrl(invalid), throwsFormatException);
    }
    expect(
        CustomGuideSource.fromJson(
            {'id': 'bad:id', 'url': source.url, 'name': 'Bad'}),
        isNull);
  });

  test(
      'custom guides fill exact-ID gaps, retain manual and primary listings, and stop when disabled',
      () async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final dir = await Directory.systemTemp.createTemp('iptv-custom-guide-');
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
      c('gap', 'Gap'),
      c('xt_live_42', 'XC gap').copyWith(epgKey: 'XC.Provider'),
      c('primary', 'Working'),
      c('manual', 'Manual'),
    ].map((c) => c.toJson()).toList()));
    final storage = _Storage(file.path);
    await storage.init();
    await storage.setSupplementaryGuideSelection({});
    const source = CustomGuideSource(
        id: 'test',
        name: 'Fixture',
        url: 'https://custom.example.test/guide.xml.gz');
    await storage.setCustomGuideSources([source]);
    await storage.setPlaylists([
      PlaylistProfile(
          id: 'test',
          name: 'Fixture',
          mode: 'm3u',
          m3uUrl: 'https://example.invalid/never-fetch',
          epgUrl: 'https://primary.example.test/guide',
          sortOrder: 0,
          createdAt: DateTime.now())
    ]);
    await storage.setEpgIdOverrides('test', {'manual': 'manual-id'});
    final manager = PlaylistManager(storage, CatalogDatabase());
    await manager.init(restoreInBackground: true);
    await manager.whenRestored;
    final epg = EpgService(storage);
    epg.supplementarySources = () => manager.supplementaryGuideSources(epg);
    epg.onSupplementaryGuidesUpdated =
        () => manager.finishSupplementaryGuides(epg);
    addTearDown(() async {
      manager.dispose();
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
    var customRequests = 0;
    var fail = false;
    await http.runWithClient(() async {
      Future<void> refresh() =>
          epg.refresh('https://primary.example.test/guide',
              knownChannelIds: {'primary', 'manual-id'});
      await refresh();
      expect(customRequests, 1);
      expect(epg.getCurrentProgram('primary')!.title, 'Provider');
      expect(epg.getCurrentProgram('manual-id')!.title, 'Manual');
      expect(epg.getCurrentProgram('${source.prefix}primary'), isNull);
      expect(epg.getCurrentProgram('${source.prefix}outside'), isNull);
      final gap =
          manager.visibleLiveChannels.firstWhere((c) => c.rawId == 'gap');
      expect(gap.epgId, '${source.prefix}gap');
      expect(epg.getCurrentProgram(gap.epgId)!.title, 'Custom');
      final xc = manager.visibleLiveChannels
          .firstWhere((c) => c.rawId == 'xt_live_42');
      expect(xc.epgId, '${source.prefix}xc.provider');
      expect(epg.getCurrentProgram(xc.epgId)!.title, 'XC Custom');
      expect(
          (await manager.supplementaryGuideSources(epg)).single.knownChannelIds,
          {'${source.prefix}gap', '${source.prefix}xc.provider'});
      fail = true;
      await refresh();
      expect(epg.error, isNotNull);
      expect(epg.getCurrentProgram(gap.epgId)!.title, 'Custom');
      await storage.setCustomGuideSources([source.withEnabled(false)]);
      await refresh();
      expect(customRequests, 2);
      expect(epg.getCurrentProgram(gap.epgId)!.title, 'Custom');
      final manual =
          manager.visibleLiveChannels.firstWhere((c) => c.rawId == 'manual');
      await manager.setEpgIdOverride(manual, '${source.prefix}gap');
      await manager.removeAutomaticGuideSource(source.prefix);
      expect(gap.epgIdOverride, isNull);
      expect(manual.epgId, '${source.prefix}gap',
          reason: 'Removing a source preserves explicit manual links.');
    },
        () => MockClient((request) async {
              expect(request.url.fragment, isEmpty);
              if (request.url.host == 'primary.example.test') {
                return http.Response(
                    '<tv>${row('primary', 'Provider')}${row('manual-id', 'Manual')}</tv>',
                    200);
              }
              expect(request.url.host, 'custom.example.test');
              customRequests++;
              if (fail) return http.Response('Unavailable', 503);
              return http.Response.bytes(
                  gzip.encode(utf8.encode(
                      '<tv><channel id="gap"><display-name>Gap</display-name></channel>${row('gap', 'Custom')}${row('XC.Provider', 'XC Custom')}${row('primary', 'Must not replace')}${row('outside', 'Outside')}</tv>')),
                  200);
            }));
  });
}
