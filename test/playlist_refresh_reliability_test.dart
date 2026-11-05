import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:nox_iptv/models/channel.dart';
import 'package:nox_iptv/models/playlist_profile.dart';
import 'package:nox_iptv/models/xtream_series.dart';
import 'package:nox_iptv/services/catalog_database.dart';
import 'package:nox_iptv/services/playlist_session.dart';
import 'package:nox_iptv/services/storage_service.dart';

class MemoryStorage extends StorageService {
  @override
  Future<void> writeCacheFile(String name, String content) async {}
}

class MemoryCatalog extends CatalogDatabase {
  final movies = <String, List<Channel>>{};
  final series = <String, List<XtreamSeries>>{};
  bool failWrite = false;
  @override
  Future<void> upsertVodCategory(
      String id, String category, List<Channel> items) async {
    if (failWrite) throw const FileSystemException('Synthetic storage failure');
    movies[category] = items;
  }

  @override
  Future<void> upsertSeriesCategory(
      String id, String category, List<XtreamSeries> items) async {
    series[category] = items;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final previousHttp = HttpOverrides.current;
  setUp(() => HttpOverrides.global = null);
  tearDown(() => HttpOverrides.global = previousHttp);
  late HttpServer server;
  late MemoryStorage storage;
  late MemoryCatalog db;
  late PlaylistSession session;
  final requests = <String>[];
  String? failAction;
  bool malformed = false;
  Object auth = 1;
  String liveName = 'Live';
  int active = 0, peak = 0;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    storage = MemoryStorage();
    await storage.init();
    db = MemoryCatalog();
    requests.clear();
    failAction = null;
    malformed = false;
    auth = 1;
    liveName = 'Live';
    active = 0;
    peak = 0;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final action = request.uri.queryParameters['action'] ?? 'auth';
      requests.add(action);
      active++;
      if (active > peak) peak = active;
      await Future<void>.delayed(const Duration(milliseconds: 5));
      Object body;
      if (action == failAction) {
        request.response.statusCode = malformed ? 200 : 503;
        body = {'error': 'Unavailable'};
      } else {
        body = switch (action) {
          'auth' => {
              'user_info': {
                'auth': auth,
                'status': 'Active',
                'max_connections': '1'
              }
            },
          'get_live_categories' => [
              {'category_id': '1', 'category_name': liveName}
            ],
          'get_live_streams' => [
              {'stream_id': 1, 'name': 'Live fixture', 'category_id': '1'}
            ],
          'get_vod_categories' => [
              for (var i = 1; i <= 3; i++)
                {'category_id': '$i', 'category_name': 'Movies $i'}
            ],
          'get_series_categories' => [
              {'category_id': '4', 'category_name': 'Series'}
            ],
          'get_vod_streams' => [
              {
                'stream_id': 1,
                'name': 'Movie fixture',
                'container_extension': 'mp4'
              }
            ],
          'get_series' => [
              {'series_id': 1, 'name': 'Series fixture', 'category_id': '4'}
            ],
          _ => throw StateError('Unexpected request'),
        };
      }
      request.response.write(jsonEncode(body));
      active--;
      await request.response.close();
    });
    final profile = PlaylistProfile(
        id: 'test',
        name: 'Test',
        mode: 'xtream',
        sortOrder: 0,
        createdAt: DateTime(2026),
        xtreamServer: 'http://127.0.0.1:${server.port}',
        xtreamUsername: 'fixture',
        xtreamPassword: 'fixture');
    await storage.setPlaylists([profile]);
    session = PlaylistSession(
        profile: profile,
        storage: storage,
        catalogDb: db,
        favoriteIds: () => {},
        favoriteSeriesIds: () => {},
        onNotify: () {});
  });
  tearDown(() async {
    session.catalogApi?.dispose();
    await server.close(force: true);
  });

  test(
      'XC endpoint URL and textual auth load a live playlist in three requests',
      () async {
    auth = '1';
    session.profile = session.profile.copyWith(
        xtreamServer:
            'http://127.0.0.1:${server.port}/player_api.php?username=old&password=old');
    await session.loadFromCatalog();
    expect(session.error, isNull);
    expect(session.liveChannels.single.name, 'Live fixture');
    expect(session.liveCategories.single.name, 'Live');
    expect(requests, ['auth', 'get_live_categories', 'get_live_streams']);
  });

  test('explicit account rejection does not retry backup servers', () async {
    auth = '0';
    session.profile = session.profile
        .copyWith(backupServers: ['http://127.0.0.1:${server.port}/backup']);
    await session.loadFromCatalog();
    expect(session.error, contains('Invalid Xtream username/password'));
    expect(requests, ['auth']);
  });

  test('an invalid saved address still allows a configured backup to connect',
      () async {
    session.profile = session.profile.copyWith(
        xtreamServer: 'http://',
        backupServers: ['http://127.0.0.1:${server.port}']);
    await session.loadFromCatalog();
    expect(session.error, isNull);
    expect(session.liveChannels, hasLength(1));
    expect(requests, ['auth', 'get_live_categories', 'get_live_streams']);
  });

  test(
      'ordinary loading stays lazy; explicit full refresh updates both libraries once',
      () async {
    await session.loadFromCatalog();
    expect(requests, ['auth', 'get_live_categories', 'get_live_streams']);
    requests.clear();
    await Future.wait(List.generate(25, (_) => session.runFullCatalogSync()));
    expect(requests.where((r) => r == 'auth'), hasLength(1));
    expect(db.movies.length, 3);
    expect(db.series.length, 1);
    expect(peak, 1, reason: 'Movies and series share the provider allowance.');
    expect(storage.getLastFullSyncAt('test'), isNotNull);
    expect(session.error, isNull);
    expect(session.isWarmingCatalog, isFalse);
  });
  test('failed live refresh keeps its previous groups and channels together',
      () async {
    await session.loadFromCatalog();
    liveName = 'Changed group';
    failAction = 'get_live_streams';
    await session.runFullCatalogSync();
    expect(session.error, isNotNull);
    expect(session.liveCategories.single.name, 'Live');
    expect(session.liveChannels.single.group, 'Live');
    expect(db.movies, isEmpty);
    failAction = null;
    await session.loadFromCatalog();
    expect(session.liveCategories.single.name, 'Changed group');
    expect(session.liveChannels.single.group, 'Changed group');
  });
  test(
      'library-only full refresh fetches metadata once and never requests live',
      () async {
    session.profile = session.profile.copyWith(includeLive: false);
    await session.runFullCatalogSync();
    expect(session.error, isNull);
    expect(requests.where((r) => r == 'get_vod_categories'), hasLength(1));
    expect(requests.where((r) => r == 'get_series_categories'), hasLength(1));
    expect(requests, isNot(contains('get_live_streams')));
    expect(db.movies.length, 3);
    expect(db.series.length, 1);
  });
  test(
      'failed authentication retains live content and never updates old library connection',
      () async {
    await session.runFullCatalogSync();
    final stamp = storage.getLastFullSyncAt('test');
    requests.clear();
    failAction = 'auth';
    await session.runFullCatalogSync();
    expect(session.error, isNotNull);
    expect(session.liveChannels.single.name, 'Live fixture');
    expect(requests.every((r) => r == 'auth'), isTrue);
    expect(storage.getLastFullSyncAt('test'), stamp);
  });
  for (final failure in [
    'get_vod_categories',
    'get_vod_streams',
    'get_series'
  ]) {
    test('$failure failure preserves saved content, freshness and retry',
        () async {
      await session.runFullCatalogSync();
      final stamp = storage.getLastFullSyncAt('test');
      final saved = db.movies['Movies 1'];
      failAction = failure;
      await session.runFullCatalogSync();
      expect(session.error, isNotNull);
      expect(storage.getLastFullSyncAt('test'), stamp);
      expect(db.movies['Movies 1']!.single.name, saved!.single.name);
      expect(db.series['Series']!.single.name, 'Series fixture');
      failAction = null;
      await session.runFullCatalogSync();
      expect(session.error, isNull);
      expect(storage.getLastFullSyncAt('test')!.isAfter(stamp!), isTrue);
    });
  }
  test('failed database write cannot mark a full refresh successful', () async {
    db.failWrite = true;
    await session.runFullCatalogSync();
    expect(session.error, isNotNull);
    expect(storage.getLastFullSyncAt('test'), isNull);
    db.failWrite = false;
    await session.runFullCatalogSync();
    expect(session.error, isNull);
  });
  test('disabled content and hidden categories do not download titles',
      () async {
    session.profile = session.profile.copyWith(includeSeries: false);
    await storage.setHiddenGroups('test', {'Movies 2'});
    await session.runFullCatalogSync();
    expect(db.movies.keys, unorderedEquals(['Movies 1', 'Movies 3']));
    expect(requests, isNot(contains('get_series')));
    expect(requests, isNot(contains('get_series_categories')));
  });
  test(
      'a provider error object cannot overwrite saved titles as an empty category',
      () async {
    await session.runFullCatalogSync();
    final stamp = storage.getLastFullSyncAt('test');
    failAction = 'get_vod_streams';
    malformed = true;
    await session.runFullCatalogSync();
    expect(session.error, isNotNull);
    expect(db.movies['Movies 1'], hasLength(1));
    expect(storage.getLastFullSyncAt('test'), stamp);
  });
}
