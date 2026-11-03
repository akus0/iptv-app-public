import 'dart:convert';
import 'dart:io';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;
import 'package:nox_iptv/services/playlist_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:nox_iptv/services/storage_service.dart';
import 'package:nox_iptv/services/catalog_database.dart';
import 'package:nox_iptv/services/playlist_session.dart';
import 'package:nox_iptv/services/epg_database.dart';
import 'package:nox_iptv/services/epg_service.dart';
import 'package:nox_iptv/models/channel.dart';
import 'package:nox_iptv/utils/constants.dart';
import 'package:nox_iptv/services/stalker_portal_service.dart';
import 'stalker_portal_test.dart' show portalProfile, js;

class _Cache extends StorageService {
  _Cache(this.path);
  final String path;
  @override
  Future<String?> readCacheFile(String name) async =>
      name.startsWith(AppConstants.cacheFileLiveCategories)
          ? '[{"id":"10","name":"Sports"}]'
          : '[]';
  @override
  Future<String?> cacheFilePath(String name) async => path;
  @override
  Future<void> deleteCacheFile(String name) async {}
  @override
  Future<void> writeCacheFile(String name, String content) async {}
}

class _Catalogue extends CatalogDatabase {
  int clears = 0;
  @override
  Future<void> clearForPlaylist(String id) async {
    clears++;
  }
}

class _Guide extends EpgDatabase {
  final inserted = <EpgRow>[];
  final sources = <String>[];
  final deleted = <String>[];
  @override
  Future<void> open() async {}
  @override
  Future<Set<String>> channelIdsWithData(int from) async =>
      inserted.map((r) => r.channelId).toSet();
  @override
  Future<Map<String, List<EpgRow>>> programmesBetween(int from, int to) async =>
      {};
  @override
  Future<void> insertBatch(List<EpgRow> rows, String source, int gen) async {
    expect(rows.length, lessThanOrEqualTo(512));
    inserted.addAll(rows);
    sources.add(source);
  }

  @override
  Future<void> deleteStaleFromSource(String source, int gen) async {
    deleted.add(source);
  }

  @override
  Future<void> deleteEndedBefore(int before) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test(
      'cached portal startup restores directory and channels without authentication or network',
      () async {
    final directory = await Directory.systemTemp.createTemp('portal-cache-');
    addTearDown(() => directory.delete(recursive: true));
    final c = Channel(
        id: 'portal-fixture::st_live_1',
        rawId: 'st_live_1',
        playlistId: 'portal-fixture',
        name: 'Cached',
        group: 'Sports',
        url: 'stalker://play?type=itv&cmd=fixture');
    final file = File('${directory.path}/channels.json');
    await file.writeAsString(jsonEncode([c.toJson()]));
    final storage = _Cache(file.path);
    await storage.init();
    await storage.setPortalCacheIdentity(
        portalProfile().id, portalConnectionIdentity(portalProfile()));
    final session = PlaylistSession(
        profile: portalProfile(),
        storage: storage,
        catalogDb: CatalogDatabase(),
        favoriteIds: () => {},
        favoriteSeriesIds: () => {},
        onNotify: () {});
    addTearDown(() => session.catalogApi?.dispose());
    await HttpOverrides.runZoned(() async {
      await session.restoreOrLoad();
      expect(session.liveCategories.single.name, 'Sports');
      expect(session.liveChannels, isEmpty);
      await session.ensureLiveChannelsLoaded();
    },
        createHttpClient: (_) =>
            throw StateError('Cached startup must not create an HTTP client'));
    expect(session.liveChannels.single.url, c.url);
    expect(session.allCachedVod, isEmpty);
  });
  test('a changed portal account cannot reuse the previous library catalogue',
      () async {
    final storage = _Cache('unused');
    await storage.init();
    final profile = portalProfile().copyWith(includeLive: false);
    await storage.setPortalCacheIdentity(profile.id, 'previous-account');
    final db = _Catalogue();
    final session = PlaylistSession(
        profile: profile,
        storage: storage,
        catalogDb: db,
        favoriteIds: () => {},
        favoriteSeriesIds: () => {},
        onNotify: () {});
    var rejected = true;
    final api = StalkerPortalService(profile, client: MockClient((r) async {
      if (r.url.queryParameters['action'] == 'handshake') {
        return js({'token': 't'});
      }
      if (r.url.queryParameters['action'] == 'get_profile') {
        return js({'status': rejected ? 1 : 0});
      }
      return js([]);
    }));
    session.catalogApi = api;
    addTearDown(api.dispose);
    await expectLater(
        session.ensureLibraryCategories(), throwsA(isA<PortalException>()));
    expect(db.clears, 0);
    expect(storage.getPortalCacheIdentity(profile.id), 'previous-account');
    rejected = false;
    await session.ensureLibraryCategories();
    expect(db.clears, 1);
    expect(storage.getPortalCacheIdentity(profile.id),
        portalConnectionIdentity(profile));
    await session.ensureLibraryCategories();
    expect(db.clears, 1);
  });

  test('editing a portal identity replaces its authenticated playback session',
      () async {
    final storage = _Cache('unused');
    await storage.init();
    final manager = PlaylistManager(storage, _Catalogue());
    addTearDown(manager.dispose);
    final profile = portalProfile();
    await manager.addPlaylist(profile);
    final macs = <String>[];
    final channel = Channel(
        id: 'portal-fixture::st_live_1',
        rawId: 'st_live_1',
        playlistId: profile.id,
        name: 'Fixture',
        group: 'TV',
        url: 'stalker://play?type=itv&cmd=fixture');
    await http.runWithClient(() async {
      await manager.resolvePlaybackChannel(channel);
      await manager
          .updatePlaylist(profile.copyWith(portalMac: '00:1A:79:12:34:57'));
      await manager.resolvePlaybackChannel(channel);
    },
        () => MockClient((r) async {
              final action = r.url.queryParameters['action'];
              if (action == 'handshake') {
                macs.add(r.headers['cookie']!);
                return js({'token': 't'});
              }
              if (action == 'get_profile') return js({'status': 0});
              return js({'cmd': 'https://stream.example.test/fixture'});
            }));
    expect(macs, hasLength(2));
    expect(macs.first, contains('34:56'));
    expect(macs.last, contains('34:57'));
  });

  test(
      'portal guide import is bounded and failed/empty refresh preserves previous source rows',
      () async {
    final storage = _Cache('unused');
    await storage.init();
    final db = _Guide();
    final epg = EpgService(storage, database: db);
    addTearDown(epg.dispose);
    final now = DateTime.now().millisecondsSinceEpoch;
    var fail = false, empty = false, calls = 0;
    epg.portalSources = () => [
          (
            id: 'fixture',
            load: () async {
              calls++;
              if (fail) throw StateError('offline');
              if (empty) return <EpgRow>[];
              return List.generate(
                  1100,
                  (i) => (
                        channelId: 'stalker:fixture:$i',
                        startMs: now,
                        stopMs: now + 3600000,
                        title: 'Fixture',
                        description: null,
                        isLive: false
                      ));
            }
          )
        ];
    await epg.init();
    expect(calls, 0);
    await epg.refreshPortal('fixture');
    expect(calls, 1);
    expect(db.sources, hasLength(3));
    expect(db.deleted, ['stalker:fixture']);
    fail = true;
    await epg.refreshPortal('fixture');
    expect(db.deleted, hasLength(1));
    expect(epg.error, isNotNull);
    fail = false;
    empty = true;
    await epg.refreshPortal('fixture');
    expect(db.deleted, hasLength(1));
    expect(db.inserted, hasLength(1100));
  });
}
