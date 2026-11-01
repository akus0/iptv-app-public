import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nox_iptv/models/archive_models.dart';
import 'package:nox_iptv/services/archive_api_service.dart';

void main() {
  test('manifest genre options become the filter list, years dropped', () {
    final c = ArchiveCatalog.fromJson({
      'type': 'movie',
      'id': 'top',
      'name': 'Top',
      'extra': [
        {
          'name': 'genre',
          'options': ['Horror', 'Comedy', '1999', 'Horror', ' ']
        },
        {'name': 'skip'},
      ],
    })!;
    expect(c.genres, ['Horror', 'Comedy']);
    // Stored form round-trips.
    expect(ArchiveCatalog.fromJson(c.toJson())!.genres, ['Horror', 'Comedy']);
  });

  test('withGenre narrows only catalogs offering it', () {
    final rows = ArchiveCatalogProvider.catalogsFor({ArchiveType.series},
        now: DateTime(2026));
    final narrowed = [
      for (final c in rows)
        if (c.withGenre('Game-Show') case final n?) n
    ];
    // "New" fixes its own genre (the year): left out.
    expect(narrowed.map((c) => c.id), ['top', 'imdbRating']);
    expect(narrowed.first.slug, 'top?genre=Game-Show');
    expect(narrowed.first.searchable, isTrue);
    // A movie catalog has no TV-only genres.
    final movie = ArchiveCatalogProvider.catalogsFor({ArchiveType.movie});
    expect(movie.first.withGenre('Game-Show'), isNull);
    expect(movie.first.withGenre('Horror'), isNotNull);
  });

  test('old stored provider sources get the genres back', () {
    final s = ArchiveSource.fromJson({
      'url': 'https://s/manifest.json',
      'catalogs': [
        {'type': 'movie', 'id': 'top', 'name': 'Popular'}
      ],
      'catalogProvider': ArchiveCatalogProvider.baseUrl,
    });
    expect(s.catalogs.first.genres, contains('Western'));
  });

  test('a genre page asks the catalog with genre + skip', () async {
    final asked = <String>[];
    final api = ArchiveApiService(
        client: MockClient((req) async {
      asked.add(req.url.path);
      return http.Response(jsonEncode({'metas': []}), 200);
    }));
    final c = ArchiveCatalogProvider.catalogsFor({ArchiveType.movie})
        .first
        .withGenre('Sci-Fi')!;
    await api.fetchCatalog('https://p', c, skip: 100);
    expect(asked, ['/catalog/movie/top/genre=Sci-Fi&skip=100.json']);
  });
}
