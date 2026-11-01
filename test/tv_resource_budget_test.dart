import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:nox_iptv/models/epg_program.dart';
import 'package:nox_iptv/models/playlist_profile.dart';
import 'package:nox_iptv/services/catalog_database.dart';
import 'package:nox_iptv/services/device_memory_service.dart';
import 'package:nox_iptv/services/epg_database.dart';
import 'package:nox_iptv/services/epg_service.dart';
import 'package:nox_iptv/services/guide_programme_cache.dart';
import 'package:nox_iptv/services/m3u_parser.dart';
import 'package:nox_iptv/services/playlist_session.dart';
import 'package:nox_iptv/services/storage_service.dart';

class MemoryStorage extends StorageService {
  final files = <String, String>{};
  final reads = <String>[];
  @override
  Future<void> writeCacheFile(String name, String content) async {
    files[name] = content;
  }

  @override
  Future<String?> readCacheFile(String name) async {
    reads.add(name);
    return files[name];
  }

  @override
  Future<void> deleteCacheFile(String name) async {}
}

class QueuedGuide extends EpgDatabase {
  final batches = <List<String>>[];
  final completions = <Completer<Map<String, List<EpgRow>>>>[];
  @override
  Future<void> open() async {}
  @override
  Future<Map<String, List<EpgRow>>> programmesBetween(int from, int to) async =>
      {};
  @override
  Future<Set<String>> channelIdsWithData(int from) async =>
      {for (var i = 0; i < 100; i++) '$i'};
  @override
  Future<Map<String, List<EpgRow>>> programmesFor(List<String> ids, int from) {
    batches.add(ids);
    final done = Completer<Map<String, List<EpgRow>>>();
    completions.add(done);
    return done.future;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('cached guide reads during fast browsing never enqueue disk loads',
      () async {
    final storage = MemoryStorage();
    await storage.init();
    final db = QueuedGuide();
    final service = EpgService(storage, database: db);
    await service.init();
    for (var i = 0; i < 100; i++) {
      service.peekPrograms('$i');
    }
    await Future<void>.delayed(Duration.zero);
    expect(db.batches, isEmpty);
    service.getPrograms('5');
    await Future<void>.delayed(Duration.zero);
    expect(db.batches, [
      ['5']
    ]);
    db.completions.single.complete({});
    await Future<void>.delayed(Duration.zero);
    service.dispose();
  });

  test('artwork cache leaves decoder headroom even on high-memory devices', () {
    expect(imageCacheBudgetBytes(null), 32 << 20);
    for (final gb in [1, 2, 3, 4, 8]) {
      final info =
          DeviceMemoryInfo(totalMemBytes: gb << 30, isLowRamDevice: false);
      expect(imageCacheBudgetBytes(info), lessThanOrEqualTo(64 << 20));
    }
    expect(
        imageCacheBudgetBytes(const DeviceMemoryInfo(
            totalMemBytes: 8 << 30, isLowRamDevice: true)),
        32 << 20);
  });

  test('guide cache preserves hot rows, bounds cold rows and snapshots safely',
      () {
    final cache = GuideProgrammeCache(maxChannels: 3, maxProgrammes: 4);
    EpgProgram programme(String title) => EpgProgram(
        channelId: title,
        title: title,
        start: DateTime(2026),
        stop: DateTime(2026, 1, 2));
    final a = [programme('a')];
    cache['a'] = a;
    cache['b'] = [programme('b')];
    cache['c'] = [programme('c')];
    expect(identical(cache['a'], a), isTrue);
    final snapshot = cache.snapshot();
    cache['d'] = [programme('d')];
    expect(cache['b'], isNull);
    expect(identical(cache['a'], a), isTrue);
    expect(snapshot.keys, contains('b'));
    cache['e'] = [programme('e1'), programme('e2'), programme('e3')];
    expect(cache.programmeCount, lessThanOrEqualTo(4));
    final large = [for (var i = 0; i < 10; i++) programme('$i')];
    cache['large'] = large;
    expect(cache.length, 1);
    expect(identical(cache['large'], large), isTrue,
        reason: 'A long single schedule must never be truncated');
    cache.clear();
    expect(cache.length, 0);
    expect(cache.programmeCount, 0);
  });

  test(
      'scroll requests are serial batches of 32 and complete safely after disposal',
      () async {
    final storage = MemoryStorage();
    await storage.init();
    final db = QueuedGuide();
    final service = EpgService(storage, database: db);
    await service.init();
    for (var i = 0; i < 80; i++) {
      service.getPrograms('$i');
    }
    await Future<void>.delayed(Duration.zero);
    expect(db.batches.map((b) => b.length), [32]);
    // More scrolling during an outstanding query must not start another query.
    for (var i = 80; i < 100; i++) {
      service.getPrograms('$i');
    }
    await Future<void>.delayed(Duration.zero);
    expect(db.batches, hasLength(1));
    db.completions[0].complete({});
    await Future<void>.delayed(const Duration(milliseconds: 5));
    expect(db.batches.map((b) => b.length), [32, 32]);
    db.completions[1].complete({});
    await Future<void>.delayed(const Duration(milliseconds: 5));
    db.completions[2].complete({});
    await Future<void>.delayed(const Duration(milliseconds: 5));
    expect(db.batches.map((b) => b.length), [32, 32, 32, 4]);
    expect(db.batches.expand((b) => b).toSet(), hasLength(100));
    service.dispose();
    db.completions[3].complete({});
    await Future<void>.delayed(const Duration(milliseconds: 5));
  });

  test(
      'large guide batches convert in the worker and publish exact channel IDs',
      () async {
    final storage = MemoryStorage();
    await storage.init();
    final db = QueuedGuide();
    final service = EpgService(storage, database: db);
    await service.init();
    final completed = Completer<void>();
    service.guideRowsLoaded.addListener(() {
      if (!completed.isCompleted) completed.complete();
    });
    service.getPrograms('0');
    await Future<void>.delayed(Duration.zero);
    final start = DateTime.now().millisecondsSinceEpoch;
    final rows = <EpgRow>[
      for (var i = 1023; i >= 0; i--)
        (
          channelId: '0',
          startMs: start + i * 1000,
          stopMs: start + (i + 1) * 1000,
          title: 'Slot $i',
          description: null,
          isLive: false
        ),
    ];
    db.completions.single.complete({'0': rows});
    await completed.future.timeout(const Duration(seconds: 10));
    final programmes = service.getPrograms('0');
    expect(programmes, hasLength(1024));
    expect(programmes.first.title, 'Slot 0');
    expect(programmes.last.title, 'Slot 1023');
    expect(service.lastLoadedGuideChannelIds, {'0'});
    service.dispose();
  });

  test(
      'live-only M3U preserves movie networks and excludes explicit on-demand routes',
      () {
    final channels = M3uParser.parse('''#EXTM3U
#EXTINF:-1 group-title="Movies",Cinema Live
https://example.invalid/live/user/pass/1.ts
#EXTINF:-1 group-title="Series",Series Live
https://example.invalid/live/user/pass/2.ts
#EXTINF:-1 group-title="Game Shows",Game Show Live
https://example.invalid/live/user/pass/3.ts
#EXTINF:-1 group-title="Cinema",On demand movie
https://example.invalid/movie/user/pass/4.mp4
#EXTINF:-1 group-title="Drama",On demand episode
https://example.invalid/series/user/pass/5.mp4
''', playlistId: 'p', liveOnly: true);
    expect(channels.map((c) => c.name),
        ['Cinema Live', 'Series Live', 'Game Show Live']);
    expect(channels.map((c) => c.rawId), ['ch_1', 'ch_2', 'ch_3']);
    final session = PlaylistSession(
        profile: PlaylistProfile(
            id: 'p',
            name: 'Fixture',
            mode: 'm3u',
            sortOrder: 0,
            createdAt: DateTime(2026)),
        storage: MemoryStorage(),
        catalogDb: CatalogDatabase(),
        favoriteIds: () => {},
        favoriteSeriesIds: () => {},
        isRestrictedViewer: () => false,
        onNotify: () {});
    session.channels = channels;
    expect(session.tvGroups, hasLength(3));
    expect(session.visibleChannels(category: 'tv'), hasLength(3));
    expect(session.vodGroups, isEmpty);
    expect(session.seriesGroups, isEmpty);
  });

  test('Xtream live sync never downloads on-demand titles', () async {
    final storage = MemoryStorage();
    await storage.init();
    final profile = PlaylistProfile(
        id: 'p',
        name: 'Fixture',
        mode: 'xtream',
        xtreamServer: 'https://example.invalid',
        xtreamUsername: 'fixture',
        xtreamPassword: 'fixture',
        sortOrder: 0,
        createdAt: DateTime(2026));
    await storage.setPlaylists([profile]);
    PlaylistSession session() => PlaylistSession(
        profile: profile,
        storage: storage,
        catalogDb: CatalogDatabase(),
        favoriteIds: () => {},
        favoriteSeriesIds: () => {},
        isRestrictedViewer: () => false,
        onNotify: () {});
    final requests = <String>[];
    final first = session();
    await http.runWithClient(() async {
      await first.loadFromXtream();
      final restored = session();
      await restored.restoreOrLoad();
      expect(restored.tvGroups.single.title, 'Movie networks');
      expect(restored.vodByCategoryName, isEmpty);
      expect(restored.seriesByCategoryName, isEmpty);
    },
        () => MockClient((request) async {
              final action = request.url.queryParameters['action'] ?? '';
              requests.add(action);
              final data = switch (action) {
                '' => {
                    'user_info': {
                      'auth': 1,
                      'status': 'Active',
                      'max_connections': '1'
                    }
                  },
                'get_live_categories' => [
                    {'category_id': '1', 'category_name': 'Movie networks'}
                  ],
                'get_live_streams' => [
                    {'stream_id': 1, 'name': 'Cinema', 'category_id': '1'}
                  ],
                _ => throw StateError('Unexpected catalogue request: $action'),
              };
              return http.Response(jsonEncode(data), 200);
            }));
    expect(first.error, isNull);
    expect(first.liveChannels, hasLength(1));
    expect(requests, ['', 'get_live_categories', 'get_live_streams']);
    expect(
        storage.reads
            .where((name) => name.contains('vod') || name.contains('series')),
        everyElement(
            anyOf(contains('categories'), contains('series_categories'))));
  });
}
