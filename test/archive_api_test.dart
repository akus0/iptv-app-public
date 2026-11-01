import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nox_iptv/models/archive_models.dart';
import 'package:nox_iptv/services/archive_api_service.dart';

/// A fake source speaking the catalog/meta/stream schema.
http.Client _fakeSource() => MockClient((req) async {
      final path = req.url.path;
      Object? body;
      if (path == '/pd/manifest.json') {
        body = {
          'id': 'org.example.pd',
          'name': 'Public Domain Classics',
          'resources': ['catalog', 'meta', 'stream'],
          'types': ['movie', 'series'],
          'catalogs': [
            {'type': 'movie', 'id': 'noir', 'name': 'Film Noir'},
            {'type': 'series', 'id': 'serials', 'name': 'Serials'},
            {
              'type': 'movie',
              'id': 'search',
              'extra': [
                {'name': 'search', 'isRequired': true}
              ]
            },
          ],
        };
      } else if (path == '/pd/catalog/movie/noir.json') {
        body = {
          'metas': [
            {
              'id': 'ia_detour',
              'type': 'movie',
              'name': 'Detour',
              'poster': 'https://img/detour.jpg',
              'releaseInfo': '1945'
            },
            {'id': 'broken'}, // no name: dropped
          ]
        };
      } else if (path == '/pd/meta/series/ia_flash.json') {
        body = {
          'meta': {
            'id': 'ia_flash',
            'type': 'series',
            'name': 'Flash Gordon',
            'videos': [
              {
                'id': 'ia_flash:1:2',
                'title': 'Ep 2',
                'season': 1,
                'episode': 2
              },
              {
                'id': 'ia_flash:1:1',
                'title': 'Ep 1',
                'season': 1,
                'episode': 1
              },
            ]
          }
        };
      } else if (path == '/pd/stream/movie/ia_detour.json') {
        body = {
          'streams': [
            {'infoHash': 'abc', 'title': 'torrent'},
            {'ytId': 'xyz'},
            {
              'url': 'https://archive.org/download/detour/detour.mp4',
              'name': 'Internet Archive',
              'title': '512Kb MPEG4'
            },
          ]
        };
      } else if (path == '/pd/stream/series/ia_flash:1:1.json') {
        body = {
          'streams': [
            {'url': 'https://archive.org/flash_1.mp4'}
          ]
        };
      }
      if (body == null) return http.Response('not found', 404);
      return http.Response(jsonEncode(body), 200,
          headers: {'content-type': 'application/json'});
    });

void main() {
  final api = ArchiveApiService(client: _fakeSource());
  const base = 'https://example.org/pd';

  test('normalizes pasted links', () {
    expect(ArchiveApiService.normalizeManifestUrl('stremio://example.org/pd/'),
        'https://example.org/pd/manifest.json');
    expect(ArchiveApiService.normalizeManifestUrl('example.org/pd'),
        'https://example.org/pd/manifest.json');
  });

  test('manifest keeps only browsable catalogs', () async {
    final s = await api.fetchManifest('https://example.org/pd');
    expect(s.name, 'Public Domain Classics');
    expect(s.baseUrl, base);
    expect(s.catalogs.map((c) => c.id), ['noir', 'serials']);
    // Round-trips through the stored JSON.
    final back = ArchiveSource.fromJson(s.toJson());
    expect(back.catalogs.length, 2);
    expect(back.key, s.key);
  });

  test('catalog parses title, poster, year', () async {
    final items = await api.fetchCatalog(base,
        const ArchiveCatalog(type: ArchiveType.movie, id: 'noir', name: ''));
    expect(items.length, 1);
    expect(items.first.name, 'Detour');
    expect(items.first.posterUrl, 'https://img/detour.jpg');
    expect(items.first.year, '1945');
  });

  test('movie stream: only the direct URL survives', () async {
    final streams =
        await api.fetchStreams(base, ArchiveType.movie, 'ia_detour');
    expect(streams.length, 1);
    expect(streams.first.url, 'https://archive.org/download/detour/detour.mp4');
    expect(streams.first.label, 'Internet Archive · 512Kb MPEG4');
  });

  test('series meta sorts episodes; episode stream id works', () async {
    final meta = await api.fetchMeta(base, ArchiveType.series, 'ia_flash');
    expect(meta!.videos.map((v) => v.episode), [1, 2]);
    final streams =
        await api.fetchStreams(base, ArchiveType.series, meta.videos.first.id);
    expect(streams.single.url, 'https://archive.org/flash_1.mp4');
    expect(ArchiveApiService.episodeId('ia_flash', 1, 1), 'ia_flash:1:1');
  });

  test('a link without streams is rejected', () async {
    final noStreams = ArchiveApiService(
        client: MockClient((_) async => http.Response(
            jsonEncode({
              'name': 'Subs only',
              'resources': ['subtitles'],
              'catalogs': []
            }),
            200)));
    expect(() => noStreams.fetchManifest('https://x.org'),
        throwsA(isA<ArchiveApiException>()));
  });

  group('stream-only source + public catalog provider', () {
    final hits = <String>[];
    final client = MockClient((req) async {
      hits.add('${req.url.host}${req.url.path}');
      final path = req.url.path;
      final host = req.url.host;
      Object? body;
      if (host == 'my.addon' && path == '/abc/manifest.json') {
        body = {
          'id': 'my.addon',
          'name': 'My Streams',
          'resources': [
            {
              'name': 'stream',
              'types': ['movie', 'series'],
              'idPrefixes': ['tt']
            }
          ],
          'types': ['movie', 'series'],
          'catalogs': [],
        };
      } else if (host == 'v3-cinemeta.strem.io' &&
          path == '/catalog/movie/top.json') {
        body = {
          'metas': [
            {
              'id': 'tt0037638',
              'type': 'movie',
              'name': 'Detour',
              'poster': 'https://img/p.jpg'
            }
          ]
        };
      } else if (host == 'v3-cinemeta.strem.io' &&
          path == '/meta/series/tt0000001.json') {
        body = {
          'meta': {
            'id': 'tt0000001',
            'type': 'series',
            'name': 'Show',
            'videos': [
              {'id': 'tt0000001:1:2', 'name': 'Two', 'season': 1, 'episode': 2},
              {'id': 'tt0000001:1:1', 'name': 'One', 'season': 1, 'episode': 1},
            ]
          }
        };
      } else if (host == 'my.addon' &&
          path == '/abc/stream/movie/tt0037638.json') {
        body = {
          'streams': [
            {'infoHash': 'deadbeef'},
            {'url': 'https://cdn.my.addon/detour.mp4', 'name': 'My Streams'}
          ]
        };
      } else if (host == 'v3-cinemeta.strem.io' &&
          (path == '/catalog/movie/year/genre=2026&skip=50.json' ||
              path == '/catalog/movie/top/search=the%20office.json')) {
        body = {
          'metas': [
            {'id': 'tt0000009', 'type': 'movie', 'name': 'Found'}
          ]
        };
      } else if (host == 'my.addon' &&
          path == '/abc/stream/movie/tt0000002.json') {
        body = {
          'streams': [
            {
              'url': 'https://cdn.my.addon/a_4k.mkv',
              'name': 'My Streams\n4K',
              'title': 'Film.2160p.mkv\n💾 20 GB 🇫🇷'
            },
            {
              'url': 'https://cdn.my.addon/a_1080.mp4',
              'name': 'My Streams 1080p',
              'description': 'English'
            },
            {'url': 'magnet:?xt=urn:btih:abc', 'name': 'not http'},
            {'url': 'https://cdn.my.addon/a_720.mp4'},
          ]
        };
      } else if (host == 'my.addon' &&
          path == '/abc/stream/series/tt0000001:1:1.json') {
        body = {
          'streams': [
            {'url': 'https://cdn.my.addon/show_s1e1.mp4'}
          ]
        };
      }
      if (body == null) return http.Response('not found', 404);
      return http.Response.bytes(utf8.encode(jsonEncode(body)), 200);
    });
    final api = ArchiveApiService(client: client);

    test('manifest gets the provider catalogs', () async {
      final s = await api.fetchManifest('https://my.addon/abc/manifest.json');
      expect(s.streamOnly, isTrue);
      expect(s.baseUrl, 'https://my.addon/abc');
      expect(s.catalogBaseUrl, ArchiveCatalogProvider.baseUrl);
      expect(s.catalogs.map((c) => '${c.type.wire}/${c.slug}'), [
        'movie/top',
        'movie/year?genre=${DateTime.now().year}',
        'movie/imdbRating',
        'series/top',
        'series/year?genre=${DateTime.now().year}',
        'series/imdbRating',
      ]);
      expect(s.catalogs.where((c) => c.searchable).map((c) => c.id),
          ['top', 'top']);
      final back = ArchiveSource.fromJson(s.toJson());
      expect(back.catalogBaseUrl, ArchiveCatalogProvider.baseUrl);
      expect(back.baseUrl, 'https://my.addon/abc');
    });

    test('grids come from the provider, Play from the custom URL', () async {
      final s = await api.fetchManifest('https://my.addon/abc');
      hits.clear();
      final items = await api.fetchCatalog(s.catalogBaseUrl,
          s.catalogs.firstWhere((c) => c.type == ArchiveType.movie));
      expect(items.single.id, 'tt0037638');
      final streams =
          await api.fetchStreams(s.baseUrl, ArchiveType.movie, items.single.id);
      expect(streams.single.url, 'https://cdn.my.addon/detour.mp4');
      expect(hits, [
        'v3-cinemeta.strem.io/catalog/movie/top.json',
        'my.addon/abc/stream/movie/tt0037638.json',
      ]);
    });

    test('series: provider episodes, stream by tt:season:episode', () async {
      final s = await api.fetchManifest('https://my.addon/abc');
      hits.clear();
      final meta = await api.fetchMeta(
          s.catalogBaseUrl, ArchiveType.series, 'tt0000001');
      expect(meta!.videos.first.id, 'tt0000001:1:1');
      expect(meta.videos.first.title, 'One');
      final streams = await api.fetchStreams(s.baseUrl, ArchiveType.series,
          ArchiveApiService.episodeId('tt0000001', 1, 1));
      expect(streams.single.url, 'https://cdn.my.addon/show_s1e1.mp4');
      expect(hits, [
        'v3-cinemeta.strem.io/meta/series/tt0000001.json',
        'my.addon/abc/stream/series/tt0000001:1:1.json',
      ]);
    });

    test('stream-only on non-IMDB ids is rejected', () async {
      final other = ArchiveApiService(
          client: MockClient((_) async => http.Response(
              jsonEncode({
                'name': 'Own ids',
                'resources': ['stream'],
                'types': ['movie'],
                'idPrefixes': ['ia_'],
                'catalogs': []
              }),
              200)));
      expect(() => other.fetchManifest('https://x.org'),
          throwsA(isA<ArchiveApiException>()));
    });
    test('New row sends its year; paging adds skip; search', () async {
      hits.clear();
      const newRow = ArchiveCatalog(
          type: ArchiveType.movie,
          id: 'year',
          name: 'New',
          extra: {'genre': '2026'});
      final more = await api
          .fetchCatalog(ArchiveCatalogProvider.baseUrl, newRow, skip: 50);
      expect(more.single.name, 'Found');
      const top = ArchiveCatalog(
          type: ArchiveType.movie,
          id: 'top',
          name: 'Popular',
          searchable: true);
      final found = await api.fetchCatalog(ArchiveCatalogProvider.baseUrl, top,
          search: 'the office');
      expect(found.single.id, 'tt0000009');
      expect(hits, [
        'v3-cinemeta.strem.io/catalog/movie/year/genre=2026&skip=50.json',
        'v3-cinemeta.strem.io/catalog/movie/top/search=the%20office.json',
      ]);
    });

    test('every direct stream is offered with its name and title', () async {
      final streams = await api.fetchStreams(
          'https://my.addon/abc', ArchiveType.movie, 'tt0000002');
      expect(streams.map((s) => s.url), [
        'https://cdn.my.addon/a_4k.mkv',
        'https://cdn.my.addon/a_1080.mp4',
        'https://cdn.my.addon/a_720.mp4',
      ]);
      expect(streams[0].name, 'My Streams\n4K');
      expect(streams[0].title, 'Film.2160p.mkv\n💾 20 GB 🇫🇷');
      expect(streams[0].label, 'My Streams\n4K · Film.2160p.mkv 💾 20 GB 🇫🇷');
      expect(streams[1].title, 'English'); // description stands in
      expect(streams[2].name, isNull);
      expect(streams[2].label, isNull);
    });

    test('a source stored with the old single row gets every row', () {
      final old = ArchiveSource.fromJson({
        'url': 'https://my.addon/abc/manifest.json',
        'name': 'My Streams',
        'catalogs': [
          {'type': 'movie', 'id': 'top', 'name': 'Popular'},
        ],
        'catalogProvider': ArchiveCatalogProvider.baseUrl,
      });
      expect(old.catalogs.map((c) => c.id), ['top', 'year', 'imdbRating']);
      final own = ArchiveSource.fromJson({
        'url': 'https://example.org/pd/manifest.json',
        'catalogs': [
          {'type': 'movie', 'id': 'noir', 'name': 'Film Noir'},
        ],
      });
      expect(own.catalogs.map((c) => c.id), ['noir']);
    });
  });
}
