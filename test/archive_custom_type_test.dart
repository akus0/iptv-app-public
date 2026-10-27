import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nox_iptv/models/archive_models.dart';
import 'package:nox_iptv/services/archive_api_service.dart';
import 'package:nox_iptv/services/archive_service.dart';
import 'package:nox_iptv/services/storage_service.dart';
import 'package:nox_iptv/utils/constants.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A source with its own catalogs of a custom type ("other") on its own
/// ids (not IMDb `tt…`): it must be accepted, browsed under Movies, and
/// every request must carry its own type and ids.
void main() {
  final hits = <String>[];
  final client = MockClient((req) async {
    hits.add(req.url.path);
    Object? body;
    switch (req.url.path) {
      case '/own/manifest.json':
        body = {
          'name': 'Own Catalog',
          'resources': ['catalog', 'meta', 'stream'],
          'types': ['other'],
          'idPrefixes': ['own:'],
          'catalogs': [
            {
              'type': 'other',
              'id': 'latest',
              'name': 'Latest',
              'extra': [
                {'name': 'search'}
              ]
            },
          ],
        };
      case '/own/catalog/other/latest.json':
        body = {
          'metas': [
            // No type on the preview: the catalog's stands in.
            {'id': 'own:42', 'name': 'Clip', 'poster': 'https://img/42.jpg'},
          ]
        };
      case '/own/meta/other/own:42.json':
        body = {
          'meta': {'id': 'own:42', 'type': 'other', 'name': 'Clip'}
        };
      case '/own/stream/other/own:42.json':
        body = {
          'streams': [
            {'url': 'https://cdn/own42.mp4'}
          ]
        };
    }
    if (body == null) return http.Response('not found', 404);
    return http.Response.bytes(utf8.encode(jsonEncode(body)), 200);
  });
  final api = ArchiveApiService(client: client);

  test('custom type + own ids: accepted, own catalog, own requests', () async {
    final s = await api.fetchManifest('https://x.org/own');
    expect(s.streamOnly, isFalse);
    final c = s.catalogs.single;
    expect(c.type, ArchiveType.movie);
    expect(c.wire, 'other');
    expect(c.searchable, isTrue);

    hits.clear();
    final items = await api.fetchCatalog(s.catalogBaseUrl, c);
    final m = items.single;
    expect(m.id, 'own:42');
    expect(m.posterUrl, 'https://img/42.jpg');
    expect(m.type, ArchiveType.movie);
    expect(m.wire, 'other');

    final full =
        await api.fetchMeta(s.catalogBaseUrl, m.type, m.id, wire: m.wire);
    expect(full!.wire, 'other');
    final streams =
        await api.fetchStreams(s.baseUrl, m.type, m.id, wire: m.wire);
    expect(streams.single.url, 'https://cdn/own42.mp4');
    expect(hits, [
      '/own/catalog/other/latest.json',
      '/own/meta/other/own:42.json',
      '/own/stream/other/own:42.json',
    ]);
  });

  test('custom type survives storage (source, catalog, history meta)',
      () async {
    final s = await api.fetchManifest('https://x.org/own');
    final back = ArchiveSource.fromJson(s.toJson());
    expect(back.catalogs.single.wire, 'other');
    expect(back.catalogs.single.type, ArchiveType.movie);
    final m = (await api.fetchCatalog(s.baseUrl, s.catalogs.single)).single;
    expect(ArchiveMeta.fromJson(m.toJson())!.wire, 'other');
    // A regular movie stays plain.
    const plain = ArchiveMeta(id: 'tt1', type: ArchiveType.movie, name: 'A');
    expect(ArchiveMeta.fromJson(plain.toJson())!.wireType, isNull);
  });

  test('stream-only with only custom types is still rejected', () async {
    final bad = ArchiveApiService(
        client: MockClient((_) async => http.Response(
            jsonEncode({
              'name': 'Streams only',
              'resources': ['stream'],
              'types': ['other'],
              'idPrefixes': ['own:'],
              'catalogs': []
            }),
            200)));
    expect(() => bad.fetchManifest('https://x.org'),
        throwsA(isA<ArchiveApiException>()));
  });

  test('Movies genre filter offers Other only when a custom type exists',
      () async {
    final own = await api.fetchManifest('https://x.org/own');
    const plain = ArchiveSource(
      manifestUrl: 'https://p.org/manifest.json',
      name: 'Plain',
      catalogs: [
        ArchiveCatalog(
            type: ArchiveType.movie,
            id: 'noir',
            name: 'Noir',
            genres: ['Crime']),
      ],
    );
    Future<ArchiveService> service(List<ArchiveSource> list) async {
      SharedPreferences.setMockInitialValues({
        AppConstants.keyArchiveSources:
            jsonEncode([for (final s in list) s.toJson()]),
      });
      final storage = StorageService();
      await storage.init();
      return ArchiveService(storage, api: api);
    }

    final both = await service([plain, own]);
    expect(
        both.genres(ArchiveType.movie), ['Crime', ArchiveService.otherGenre]);
    expect(both.genres(ArchiveType.series), isEmpty);
    // Regular rows can still be searched; the custom one isn't mixed in.
    expect(both.canSearch(ArchiveType.movie), isTrue);

    final plainOnly = await service([plain]);
    expect(plainOnly.genres(ArchiveType.movie), ['Crime']);
  });
}
