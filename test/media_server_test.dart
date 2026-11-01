import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nox_iptv/models/archive_models.dart';
import 'package:nox_iptv/services/archive_api_service.dart';
import 'package:nox_iptv/services/archive_service.dart';
import 'package:nox_iptv/services/media_server_api.dart';
import 'package:nox_iptv/services/storage_service.dart';
import 'package:nox_iptv/utils/constants.dart';
import 'package:shared_preferences/shared_preferences.dart';

// This API test needs no platform filesystem or native path_provider plugin.
class _MemoryStorage extends StorageService {
  final _cache = <String, String>{};
  @override
  Future<String?> readCacheFile(String name) async => _cache[name];
  @override
  Future<void> writeCacheFile(String name, String content) async {
    _cache[name] = content;
  }
}

/// A fake Jellyfin (API at the root) or Emby (API under `/emby`, legacy
/// headers) server. Records each request with the auth it carried.
MockClient fakeServer(MediaServerKind kind, List<String> log) {
  final emby = kind == MediaServerKind.emby;
  final prefix = emby ? '/emby' : '';
  return MockClient((req) async {
    final path = req.url.path;
    final auth = emby
        ? req.headers['x-emby-authorization']
        : req.headers['authorization'];
    final token = emby ? req.headers['x-emby-token'] : null;
    log.add('${req.method} $path');
    Object? body;
    if (!path.startsWith(prefix) || (emby && !path.startsWith('/emby/'))) {
      return http.Response('not found', 404);
    }
    final p = path.substring(prefix.length);
    if (p == '/System/Info/Public') {
      body = emby
          ? {'ServerName': 'Den', 'Version': '4.8.10.0', 'Id': 'e1'}
          : {
              'ServerName': 'Attic',
              'Version': '10.10.7',
              'ProductName': 'Jellyfin Server',
              'Id': 'j1'
            };
    } else if (auth == null || !auth.contains('Client="iptv-app"')) {
      return http.Response('no auth', 401);
    } else if (p == '/Users/AuthenticateByName') {
      final b = jsonDecode(req.body) as Map;
      if (b['Username'] != 'ann' || b['Pw'] != 'pw') {
        return http.Response('bad', 401);
      }
      body = {
        'User': {'Id': 'u1', 'Name': 'ann'},
        'AccessToken': 'tok',
      };
    } else if (!(auth.contains('Token="tok"') || token == 'tok')) {
      return http.Response('no token', 401);
    } else if (p == '/Users/u1/Views') {
      body = {
        'Items': [
          {'Id': 'lm', 'Name': 'Films', 'CollectionType': 'movies'},
          {'Id': 'lt', 'Name': 'Shows', 'CollectionType': 'tvshows'},
          {'Id': 'lx', 'Name': 'Music', 'CollectionType': 'music'},
        ]
      };
    } else if (p == '/Users/u1/Items' &&
        req.url.queryParameters['ParentId'] == 'lm') {
      body = {
        'Items': [
          {
            'Id': 'm1',
            'Name': 'Home Movie',
            'Type': 'Movie',
            'ProductionYear': 2024,
            'ImageTags': {'Primary': 'pt'},
            'BackdropImageTags': ['bt'],
            'RunTimeTicks': 54000000000,
            'CommunityRating': 7.25,
          }
        ]
      };
    } else if (p == '/Users/u1/Items/s1') {
      body = {'Id': 's1', 'Name': 'A Show', 'Type': 'Series'};
    } else if (p == '/Shows/s1/Episodes') {
      body = {
        'Items': [
          {'Id': 'e2', 'Name': 'Two', 'ParentIndexNumber': 1, 'IndexNumber': 2},
          {'Id': 'e1', 'Name': 'One', 'ParentIndexNumber': 1, 'IndexNumber': 1},
          {
            'Id': 'e3',
            'Name': 'Missing',
            'ParentIndexNumber': 1,
            'IndexNumber': 3,
            'LocationType': 'Virtual'
          },
        ]
      };
    }
    if (body == null) return http.Response('not found', 404);
    return http.Response.bytes(utf8.encode(jsonEncode(body)), 200);
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('address clean-up', () {
    expect(MediaServerApi.normalizeUrl(' 192.0.2.10:8096/ '),
        'http://192.0.2.10:8096');
    expect(
        MediaServerApi.normalizeUrl(
            'https://jf.example.org/web/index.html#!/home.html'),
        'https://jf.example.org');
  });

  for (final kind in MediaServerKind.values) {
    group(kind.label, () {
      final log = <String>[];
      final api = MediaServerApi(client: fakeServer(kind, log));
      final apiBase = kind == MediaServerKind.emby
          ? 'http://nas:8096/emby'
          : 'http://nas:8096';

      test('detects the server, signs in, libraries become catalogs', () async {
        final s = await api.connect('nas:8096', 'ann', 'pw');
        expect(s.server!.kind, kind);
        expect(s.baseUrl, apiBase);
        expect(s.name, kind == MediaServerKind.emby ? 'Den' : 'Attic');
        expect(s.catalogs.map((c) => '${c.type.wire}/${c.id}/${c.name}'),
            ['movie/lm/Films', 'series/lt/Shows']); // music left out
        // Survives storage (and Transfer).
        final back = ArchiveSource.fromJson(s.toJson());
        expect(back.server!.token, 'tok');
        expect(back.baseUrl, apiBase);
      });

      test('wrong password', () async {
        expect(() => api.connect('nas:8096', 'ann', 'nope'),
            throwsA(isA<MediaServerLoginException>()));
      });

      test('rows, episodes and the direct stream', () async {
        final s = await api.connect('nas:8096', 'ann', 'pw');
        final m = (await api.fetchCatalog(s, s.catalogs.first)).single;
        expect(m.type, ArchiveType.movie);
        expect(m.year, '2024');
        expect(m.runtime, '90 min');
        expect(m.rating, '7.3');
        expect(m.posterUrl,
            '$apiBase/Items/m1/Images/Primary?maxHeight=600&tag=pt');
        expect(m.backgroundUrl,
            '$apiBase/Items/m1/Images/Backdrop/0?maxWidth=1280&tag=bt');

        const show =
            ArchiveMeta(id: 's1', type: ArchiveType.series, name: 'A Show');
        final full = await api.fetchMeta(s, show);
        expect(full!.videos.map((v) => '${v.season}x${v.episode} ${v.id}'),
            ['1x1 e1', '1x2 e2']); // sorted, missing episode dropped

        final key = kind == MediaServerKind.jellyfin ? 'ApiKey' : 'api_key';
        expect(api.streams(s, 'e1').single.url,
            '$apiBase/Videos/e1/stream?static=true&$key=tok');
      });
    });
  }

  test('not a server', () async {
    final api = MediaServerApi(
        client: MockClient((_) async => http.Response('nope', 404)));
    expect(() => api.connect('nowhere', 'a', 'b'),
        throwsA(isA<ArchiveApiException>()));
  });

  test('ArchiveService: add, rows refresh and Play go to the server', () async {
    SharedPreferences.setMockInitialValues({
      AppConstants.keyArchiveSources: '[]',
    });
    final storage = _MemoryStorage();
    await storage.init();
    final log = <String>[];
    final service = ArchiveService(storage,
        servers:
            MediaServerApi(client: fakeServer(MediaServerKind.jellyfin, log)));
    addTearDown(service.dispose);
    final s = await service.addMediaServer('nas:8096', 'ann', 'pw');
    // Signing in again as the same user replaces, doesn't duplicate.
    await service.addMediaServer('nas:8096', 'ann', 'pw');
    expect(service.sources.length, 1);
    const movie =
        ArchiveMeta(id: 'm1', type: ArchiveType.movie, name: 'Home Movie');
    final options = await service.streams(s, movie);
    expect(options.single.stream.url,
        'http://nas:8096/Videos/m1/stream?static=true&ApiKey=tok');
    final ch = service.channelFor(s, movie, options.single.stream);
    expect(ch.url, options.single.stream.url);
    expect(ch.playlistId, ArchiveService.playlistId);
  });
}
