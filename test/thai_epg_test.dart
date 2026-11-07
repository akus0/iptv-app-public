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
import 'package:nox_iptv/utils/thai_epg.dart';

Channel channel(String id, String name) => Channel(
    id: 'test::$id',
    rawId: id,
    playlistId: 'test',
    name: name,
    group: 'TH| THAILAND',
    url: 'https://example.invalid/never-open');

class _Storage extends StorageService {
  _Storage(this.path);
  final String path;
  @override
  Future<String?> cacheFilePath(String name) async => path;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
      'regional aliases reject unrelated and ambiguous channel names',
      () {
    expect(thaiEpgCandidate(channel('a', 'TH: TNN24Thai')),
        '${thaiEpgPrefix}tnn24.th');
    expect(thaiEpgCandidate(channel('a', 'TH: THAIRATH 32 HD')),
        '${thaiEpgPrefix}trath.th');
    for (final name in [
      'KH: CNN',
      'US: CNN',
      'TH: TV5 THAI HD',
      'TH: THAI 5 HD',
      'TH: LAO TV',
      'TH: MONO+',
      'TH: TVK KHMER',
      'TH: GMM GRAMMY GOLD'
    ]) {
      expect(thaiEpgCandidate(channel('a', name)), isNull, reason: name);
    }
  });
  test(
      'regional category cleanup preserves uncertain entries',
      () {
    for (final name in [
      'KH: TV 5',
      'TH: TVK KHMER',
      'TH: MVTV-MVLAO HD',
      'TH: LAO THAI TV',
      'TH: BAYON HD',
      '##### CAMBODIA #####'
    ]) {
      expect(isNonThaiEntryInThaiGroup(channel('x', name)), true, reason: name);
    }
    for (final name in [
      'TH: THAI 5 HD',
      'TH: PBS THAI',
      'TH: TV CONGRESS',
      'TH: VANPHENH TV',
      'TH: MYANMAR CHANNEL'
    ]) {
      expect(isNonThaiEntryInThaiGroup(channel('x', name)), false,
          reason: name);
    }
    final other = Channel(
        id: 'x',
        rawId: 'x',
        playlistId: 'test',
        name: 'KH: TV 5',
        group: 'Cambodia',
        url: 'https://example.invalid/no-stream');
    expect(isNonThaiEntryInThaiGroup(other), false);
  });
  test(
      'supplementary guide setup namespaces rows and preserves assignments',
      () async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final dir = await Directory.systemTemp.createTemp('iptv-thai-test-');
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
      channel('a', 'TH: CNN HD'),
      channel('b', 'TH: TNN 24 HD'),
      channel('c', 'TH: CH8 THAI'),
      channel('d', 'KH: CNN'),
      channel('e', 'TH: TV5 THAI HD'),
      channel('f', 'TH: CARTOON NETWORK'),
      channel('g', 'TH: MV LAO'),
      channel('h', 'TH: BAYON HD'),
      channel('i', 'TH: PBS THAI'),
    ].map((c) => c.toJson()).toList()));
    final storage = _Storage(file.path);
    await storage.init();
    await storage.setPlaylists([
      PlaylistProfile(
          id: 'test',
          name: 'Fixture',
          mode: 'm3u',
          m3uUrl: 'https://example.invalid/not-used',
          epgUrl: 'https://example.invalid/provider',
          sortOrder: 0,
          createdAt: DateTime.now())
    ]);
    await storage.setEpgIdOverrides('test', {'b': 'manual'});
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
        '<programme channel="$id" start="${stamp(now.subtract(const Duration(hours: 1)))}" stop="${stamp(now.add(const Duration(hours: 1)))}"><title>$title</title></programme>';
    var requests = 0;
    await http.runWithClient(() async {
      await epg.refresh('https://example.invalid/provider',
          knownChannelIds: {'c', 'cnn.th'});
      expect(await playlist.tidyThaiChannels(), 3);
      expect(playlist.hiddenChannelsFor('test').map((c) => c.rawId),
          containsAll(['d', 'g', 'h']));
      final hidden =
          playlist.hiddenChannelsFor('test').firstWhere((c) => c.rawId == 'd');
      await playlist.toggleChannelHidden(hidden);
      expect(playlist.isChannelHidden(hidden),
          false); // recoverable; no recurring forced filter
      final ids = playlist.thaiGuideCandidates(epg);
      expect(ids, contains('${thaiEpgPrefix}cnn.th'));
      expect(ids, isNot(contains('${thaiEpgPrefix}ch8.th')));
      await epg.refresh(thaiEpgSourceUrl, knownChannelIds: ids);
      expect(await playlist.applyThaiGuide(epg), 1);
      expect(storage.getEpgIdOverrides('test')['a'], '${thaiEpgPrefix}cnn.th');
      expect(epg.getCurrentProgram('cnn.th')!.title,
          'Existing regional programme');
      expect(epg.getCurrentProgram('${thaiEpgPrefix}cnn.th')!.title,
          'English programme');
      expect(epg.getCurrentProgram('${thaiEpgPrefix}cnn.th')!.description,
          'English description');
      final channels = playlist.visibleChannels(category: 'tv');
      expect(channels.singleWhere((c) => c.rawId == 'a').epgId,
          '${thaiEpgPrefix}cnn.th');
      expect(channels.singleWhere((c) => c.rawId == 'b').epgId, 'manual');
      expect(channels.singleWhere((c) => c.rawId == 'c').epgId, 'c');
      expect(channels.singleWhere((c) => c.rawId == 'f').epgId, 'f');
      final source = (await playlist.supplementaryGuideSources(epg))
          .singleWhere((s) => s.url == thaiEpgSourceUrl);
      expect(source.knownChannelIds,
          {'${thaiEpgPrefix}cnn.th', '${thaiEpgPrefix}cartoonnet.th'});
      expect(playlist.thaiGuideCandidates(epg),
          contains('${thaiEpgPrefix}cnn.th'));
      expect(await playlist.applyThaiGuide(epg), 0);
    },
        () => MockClient((request) async {
              requests++;
              expect(request.url.fragment, isEmpty);
              return http.Response(
                  '<tv>${request.url.host == 'example.invalid' ? row('c', 'Working primary programme') + row('cnn.th', 'Existing regional programme') : row('CNN.th', 'รายการภาษาไทย').replaceFirst('</title>', '</title><title lang="en">English programme</title><title lang="th">รายการภาษาไทย</title><desc lang="th">รายละเอียด</desc><desc lang="en">English description</desc>')}</tv>',
                  200,
                  headers: {'content-type': 'application/xml; charset=utf-8'});
            }));
    expect(requests, 2); // test provider fixture + one supplemental request
  });
}
