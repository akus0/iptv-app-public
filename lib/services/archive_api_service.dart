import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/archive_models.dart';

/// Thrown when a source answers with something that isn't the schema
/// (wrong status code, not JSON, missing fields).
class ArchiveApiException implements Exception {
  ArchiveApiException(this.message);
  final String message;
  @override
  String toString() => 'ArchiveApiException: $message';
}

/// Plain HTTP client for Stremio-schema servers — no state, no cache
/// (that's `ArchiveService` + `ArchiveCache`). Every call takes a base
/// URL, so any server following the same REST schema works:
///
///   GET {base}/manifest.json
///   GET {base}/catalog/{type}/{catalogId}.json        (+ /skip={n}.json)
///   GET {base}/meta/{type}/{id}.json                  (series episodes)
///   GET {base}/stream/movie/{videoId}.json
///   GET {base}/stream/series/{id}:{season}:{episode}.json
///
/// Catalog/meta calls go to `ArchiveSource.catalogBaseUrl` (the public
/// [ArchiveCatalogProvider] for a stream-only source), stream calls to the
/// source's own `baseUrl`.
class ArchiveApiService {
  ArchiveApiService({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;
  static const _timeout = Duration(seconds: 20);

  /// Turns whatever the user pasted (`stremio://…`, a base URL, a link
  /// with or without `/manifest.json`) into the manifest URL.
  static String normalizeManifestUrl(String input) {
    var u = input.trim();
    if (u.startsWith('stremio://')) u = 'https://${u.substring(10)}';
    if (!u.startsWith('http://') && !u.startsWith('https://')) {
      u = 'https://$u';
    }
    if (!u.endsWith('/manifest.json')) {
      u = '${u.replaceAll(RegExp(r'/+$'), '')}/manifest.json';
    }
    return u;
  }

  Future<Map<String, dynamic>> _getJson(Uri uri) async {
    final r = await _client.get(uri).timeout(_timeout);
    if (r.statusCode != 200) {
      throw ArchiveApiException('HTTP ${r.statusCode} for $uri');
    }
    final body = jsonDecode(utf8.decode(r.bodyBytes));
    if (body is! Map) throw ArchiveApiException('Not a JSON object: $uri');
    return Map<String, dynamic>.from(body);
  }

  /// Ids go into the path as one segment each; `:` is legal there and the
  /// schema relies on it for episodes, so only encode what has to be.
  static String _seg(String s) => Uri.encodeComponent(s).replaceAll('%3A', ':');

  /// Fetches and checks a manifest — this is the "does the connection
  /// work" test. A source either serves its own catalogs (any type, any id
  /// scheme: custom types are browsed under Movies, see
  /// [ArchiveType.bucketFor]), or is stream-only on IMDB ids (`tt…`) and
  /// gets its grids from [ArchiveCatalogProvider]. Throws
  /// [ArchiveApiException] when it's neither (stream-only on its own ids
  /// leaves nothing to browse), or offers no `stream` resource.
  Future<ArchiveSource> fetchManifest(String input) async {
    final url = normalizeManifestUrl(input);
    final j = await _getJson(Uri.parse(url));
    final resourceList = j['resources'] as List? ?? const [];
    final resources = resourceList
        .map((e) => e is Map ? e['name']?.toString() : e?.toString())
        .toSet();
    // A manifest can omit 'catalog' from resources and still list catalogs.
    if (!resources.contains('stream')) {
      throw ArchiveApiException('This source offers no streams.');
    }
    final catalogs = <ArchiveCatalog>[];
    for (final c in (j['catalogs'] as List? ?? const [])) {
      if (c is! Map) continue;
      final needsExtra = (c['extra'] as List? ?? const [])
          .any((e) => e is Map && e['isRequired'] == true);
      final legacyRequired = (c['extraRequired'] as List? ?? const []);
      if (needsExtra || legacyRequired.isNotEmpty) continue;
      final cat = ArchiveCatalog.fromJson(Map<String, dynamic>.from(c));
      if (cat != null) catalogs.add(cat);
    }
    String? providerUrl;
    if (catalogs.isEmpty) {
      // Stream-only: fine when its streams are keyed on IMDB ids, which the
      // public provider's catalogs and metas use too.
      final streamRes =
          resourceList.whereType<Map>().where((r) => r['name'] == 'stream');
      final prefixes = <String>{
        for (final p in [
          ...(j['idPrefixes'] as List? ?? const []),
          for (final r in streamRes) ...(r['idPrefixes'] as List? ?? const []),
        ])
          p.toString(),
      };
      final types = <ArchiveType>{
        for (final t in [
          ...(j['types'] as List? ?? const []),
          for (final r in streamRes) ...(r['types'] as List? ?? const []),
        ])
          if (ArchiveType.fromWire(t?.toString()) case final type?) type,
      };
      if (types.isEmpty ||
          !(prefixes.isEmpty || prefixes.any((p) => p.startsWith('tt')))) {
        throw ArchiveApiException('This source has no catalog to browse.');
      }
      catalogs.addAll(ArchiveCatalogProvider.catalogsFor(types));
      providerUrl = ArchiveCatalogProvider.baseUrl;
    }
    return ArchiveSource(
      manifestUrl: url,
      name: (j['name']?.toString().trim().isNotEmpty ?? false)
          ? j['name'].toString().trim()
          : Uri.parse(url).host,
      description: j['description']?.toString() ?? '',
      logoUrl: j['logo']?.toString(),
      catalogs: catalogs,
      catalogProviderUrl: providerUrl,
    );
  }

  /// The schema's extra path segment: `/genre=2026&skip=100`, or '' when
  /// there's nothing to add.
  static String _extraPath(Map<String, String> extra) {
    if (extra.isEmpty) return '';
    return '/${[
      for (final e in extra.entries)
        '${Uri.encodeComponent(e.key)}=${Uri.encodeComponent(e.value)}'
    ].join('&')}';
  }

  /// One page of a catalog. Sources page with `skip` (50-100 a page).
  /// [search] queries a [ArchiveCatalog.searchable] catalog instead.
  Future<List<ArchiveMeta>> fetchCatalog(
    String baseUrl,
    ArchiveCatalog catalog, {
    int skip = 0,
    String? search,
  }) async {
    final extra = _extraPath({
      ...catalog.extra,
      if (search != null) 'search': search,
      if (skip > 0) 'skip': '$skip',
    });
    final j = await _getJson(Uri.parse(
        '$baseUrl/catalog/${_seg(catalog.wire)}/${_seg(catalog.id)}$extra.json'));
    return [
      for (final m in (j['metas'] as List? ?? const []))
        if (m is Map)
          if (ArchiveMeta.fromJson(Map<String, dynamic>.from(m),
                  fallbackType: catalog.type, fallbackWire: catalog.wire)
              case final meta?)
            meta,
    ];
  }

  /// Full meta — needed for a series (its `videos` are the episodes) and
  /// for a longer description than the catalog preview carries. [wire]
  /// is the source's own type string when it isn't [type]'s.
  Future<ArchiveMeta?> fetchMeta(String baseUrl, ArchiveType type, String id,
      {String? wire}) async {
    final w = wire ?? type.wire;
    final j =
        await _getJson(Uri.parse('$baseUrl/meta/${_seg(w)}/${_seg(id)}.json'));
    final m = j['meta'];
    if (m is! Map) return null;
    return ArchiveMeta.fromJson(Map<String, dynamic>.from(m),
        fallbackType: type, fallbackWire: w);
  }

  /// Direct, playable streams for a movie id or an episode id
  /// (`{id}:{season}:{episode}`, or whatever id the series meta's video
  /// carries). Torrent/YouTube/external entries are skipped — see
  /// [ArchiveStream].
  Future<List<ArchiveStream>> fetchStreams(
      String baseUrl, ArchiveType type, String videoId,
      {String? wire}) async {
    final j = await _getJson(Uri.parse(
        '$baseUrl/stream/${_seg(wire ?? type.wire)}/${_seg(videoId)}.json'));
    final out = <ArchiveStream>[];
    for (final s in (j['streams'] as List? ?? const [])) {
      if (s is! Map) continue;
      final url = s['url']?.toString();
      if (url == null) continue;
      final uri = Uri.tryParse(url);
      if (uri == null || !(uri.scheme == 'http' || uri.scheme == 'https')) {
        continue;
      }
      String? text(Object? v) {
        final t = v?.toString().trim();
        return (t == null || t.isEmpty) ? null : t;
      }

      String? sub;
      final subs = s['subtitles'];
      if (subs is List && subs.isNotEmpty && subs.first is Map) {
        sub = (subs.first as Map)['url']?.toString();
      }
      out.add(ArchiveStream(
        url: url,
        name: text(s['name']),
        title: text(s['title']) ?? text(s['description']),
        subtitleUrl: sub,
      ));
    }
    return out;
  }

  /// Episode stream id when the series meta has no `videos` to take it
  /// from — the schema's default shape.
  static String episodeId(String seriesId, int season, int episode) =>
      '$seriesId:$season:$episode';

  void close() => _client.close();
}
