import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import '../models/archive_models.dart';
import 'archive_api_service.dart';

/// Wrong user name or password (the server answered 401).
class MediaServerLoginException implements Exception {
  @override
  String toString() => 'MediaServerLoginException';
}

/// Signed in, but the user sees no movie or TV library.
class MediaServerNoLibraryException implements Exception {
  @override
  String toString() => 'MediaServerNoLibraryException';
}

/// Plain HTTP client for Jellyfin and Emby servers, mapped onto the Media
/// Hub's models: the user's movie and TV libraries are catalogs, a series'
/// episodes are its `videos`, and Play is the server's direct (original
/// file, no transcode) stream URL. No state: the login lives on the
/// [ArchiveSource] ([ArchiveSource.server]).
///
/// The two speak the same API (Jellyfin is a 2018 fork of Emby). What
/// differs, and is handled here:
/// - auth header: Jellyfin `Authorization: MediaBrowser …`; Emby
///   `X-Emby-Authorization` + `X-Emby-Token` (newer Jellyfin turns those
///   legacy headers off), and the stream URL's key is `ApiKey` vs
///   `api_key`;
/// - path: Emby usually lives under `/emby` (tried when the plain address
///   isn't a server);
/// - which one it is: `/System/Info/Public` (no login needed) —
///   `ProductName` "Jellyfin Server", or a 10.x version, is Jellyfin.
class MediaServerApi {
  MediaServerApi({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;
  static const _timeout = Duration(seconds: 20);
  static const _pageSize = 100;

  /// What the user typed into a base URL: `http://` by default (servers
  /// on a home network rarely have a certificate), no trailing slash, no
  /// web-UI path (`…/web/index.html#!/home` pasted from the browser).
  static String normalizeUrl(String input) {
    var u = input.trim();
    final hash = u.indexOf('#');
    if (hash >= 0) u = u.substring(0, hash);
    if (!u.startsWith('http://') && !u.startsWith('https://')) {
      u = 'http://$u';
    }
    u = u.replaceFirst(RegExp(r'/web(/.*)?$', caseSensitive: false), '');
    return u.replaceAll(RegExp(r'/+$'), '');
  }

  static String _authValue(String deviceId, String? token) =>
      'MediaBrowser Client="iptv-app", Device="iptv-app", '
      'DeviceId="$deviceId", Version="1.0"'
      '${token == null ? '' : ', Token="$token"'}';

  static Map<String, String> _headers(
      MediaServerKind kind, String deviceId, String? token) {
    final auth = _authValue(deviceId, token);
    return {
      'Accept': 'application/json',
      'Content-Type': 'application/json',
      if (kind == MediaServerKind.jellyfin)
        'Authorization': auth
      else ...{
        'X-Emby-Authorization': auth,
        if (token != null) 'X-Emby-Token': token,
      },
    };
  }

  Future<Map<String, dynamic>> _json(http.Response r, Uri uri) async {
    if (r.statusCode == 401) throw MediaServerLoginException();
    if (r.statusCode != 200) {
      throw ArchiveApiException('HTTP ${r.statusCode} for $uri');
    }
    final body = jsonDecode(utf8.decode(r.bodyBytes));
    if (body is! Map) throw ArchiveApiException('Not a JSON object: $uri');
    return Map<String, dynamic>.from(body);
  }

  Future<Map<String, dynamic>> _get(Uri uri,
          [Map<String, String>? headers]) async =>
      _json(await _client.get(uri, headers: headers).timeout(_timeout), uri);

  Future<Map<String, dynamic>> _getAuthed(
      ArchiveSource s, String pathAndQuery) {
    final login = s.server!;
    return _get(Uri.parse('${s.baseUrl}$pathAndQuery'),
        _headers(login.kind, login.deviceId, login.token));
  }

  /// Finds the server at [input]: the address as typed, then with `/emby`.
  /// Returns its API base, kind and display name.
  Future<({String apiBase, MediaServerKind kind, String name})> discover(
      String input) async {
    final root = normalizeUrl(input);
    final bases = [
      root,
      if (!root.toLowerCase().endsWith('/emby')) '$root/emby',
    ];
    for (final base in bases) {
      Map<String, dynamic> info;
      try {
        info = await _get(Uri.parse('$base/System/Info/Public'));
      } catch (_) {
        continue;
      }
      if (info['Id'] == null && info['Version'] == null) continue;
      final product = '${info['ProductName'] ?? ''}'.toLowerCase();
      final version = '${info['Version'] ?? ''}';
      final kind = product.contains('jellyfin') ||
              (product.isEmpty && version.startsWith('10.'))
          ? MediaServerKind.jellyfin
          : MediaServerKind.emby;
      final name = '${info['ServerName'] ?? ''}'.trim();
      return (
        apiBase: base,
        kind: kind,
        name: name.isEmpty ? Uri.parse(base).host : name,
      );
    }
    throw ArchiveApiException('No Jellyfin or Emby server at $root');
  }

  /// Signs in and returns the source: one catalog per movie / TV library
  /// the user can see. Throws [MediaServerLoginException] (bad user or
  /// password), [MediaServerNoLibraryException] or [ArchiveApiException]
  /// (no server there).
  Future<ArchiveSource> connect(
      String address, String userName, String password) async {
    final found = await discover(address);
    final deviceId = sha1
        .convert(utf8.encode('vespertv|${found.apiBase}|$userName'))
        .toString()
        .substring(0, 16);
    final uri = Uri.parse('${found.apiBase}/Users/AuthenticateByName');
    final auth = await _json(
        await _client
            .post(uri,
                headers: _headers(found.kind, deviceId, null),
                body: jsonEncode({'Username': userName, 'Pw': password}))
            .timeout(_timeout),
        uri);
    final user = auth['User'];
    final token = auth['AccessToken']?.toString();
    final userId = user is Map ? user['Id']?.toString() : null;
    if (token == null || userId == null) {
      throw ArchiveApiException('No access token from ${found.apiBase}');
    }
    final login = MediaServerLogin(
      kind: found.kind,
      userId: userId,
      token: token,
      deviceId: deviceId,
      userName: (user as Map)['Name']?.toString() ?? userName,
    );
    final draft = ArchiveSource(
      manifestUrl: '${found.apiBase}#$userId',
      name: found.name,
      server: login,
    );
    final catalogs = await libraries(draft);
    if (catalogs.isEmpty) throw MediaServerNoLibraryException();
    return ArchiveSource(
      manifestUrl: draft.manifestUrl,
      name: found.name,
      description: '${found.kind.label} · ${login.userName}',
      catalogs: catalogs,
      server: login,
    );
  }

  /// The user's movie and TV libraries as catalogs (library id = catalog
  /// id). Other kinds (music, photos, books…) are left out.
  Future<List<ArchiveCatalog>> libraries(ArchiveSource s) async {
    final j = await _getAuthed(s, '/Users/${s.server!.userId}/Views');
    return [
      for (final v in (j['Items'] as List? ?? const []))
        if (v is Map && v['Id'] != null)
          if (switch ('${v['CollectionType'] ?? ''}'.toLowerCase()) {
            'movies' => ArchiveType.movie,
            'tvshows' => ArchiveType.series,
            _ => null,
          }
              case final type?)
            ArchiveCatalog(
              type: type,
              id: '${v['Id']}',
              name: '${v['Name'] ?? ''}'.trim(),
              searchable: true,
            ),
    ];
  }

  /// One page of a library, newest first (a search: by name).
  Future<List<ArchiveMeta>> fetchCatalog(
    ArchiveSource s,
    ArchiveCatalog catalog, {
    int skip = 0,
    String? search,
  }) async {
    final q = {
      'ParentId': catalog.id,
      'Recursive': 'true',
      'IncludeItemTypes':
          catalog.type == ArchiveType.series ? 'Series' : 'Movie',
      'Fields': 'Overview,Genres,ProductionYear,ProviderIds',
      'EnableImageTypes': 'Primary,Backdrop',
      'ImageTypeLimit': '1',
      'StartIndex': '$skip',
      'Limit': '$_pageSize',
      if (search == null) ...{
        'SortBy': 'DateCreated,SortName',
        'SortOrder': 'Descending',
      } else ...{
        'SearchTerm': search,
        'SortBy': 'SortName',
      },
    };
    final j = await _getAuthed(
        s, '/Users/${s.server!.userId}/Items?${Uri(queryParameters: q).query}');
    return [
      for (final it in (j['Items'] as List? ?? const []))
        if (it is Map)
          if (_meta(s, Map<String, dynamic>.from(it)) case final m?) m,
    ];
  }

  /// The full item; a series also gets its episodes as `videos`.
  Future<ArchiveMeta?> fetchMeta(ArchiveSource s, ArchiveMeta preview) async {
    final uid = s.server!.userId;
    final item = await _getAuthed(s, '/Users/$uid/Items/${preview.id}');
    final meta = _meta(s, item) ?? preview;
    if (meta.type != ArchiveType.series) return meta;
    final eps = await _getAuthed(
        s,
        '/Shows/${preview.id}/Episodes?${Uri(queryParameters: {
              'UserId': uid,
              'Fields': 'Overview,PremiereDate',
            }).query}');
    final videos = [
      for (final e in (eps['Items'] as List? ?? const []))
        if (e is Map && e['Id'] != null && e['LocationType'] != 'Virtual')
          ArchiveVideo(
            id: '${e['Id']}',
            title: '${e['Name'] ?? ''}'.trim(),
            season: (e['ParentIndexNumber'] as num?)?.toInt() ?? 0,
            episode: (e['IndexNumber'] as num?)?.toInt() ?? 0,
            thumbnailUrl: _image(s, e, 'Primary', 'maxWidth=480'),
            overview: _str(e['Overview']),
            released: _str(e['PremiereDate']),
          ),
    ]..sort((a, b) {
        final c = a.season.compareTo(b.season);
        return c != 0 ? c : a.episode.compareTo(b.episode);
      });
    return ArchiveMeta(
      id: meta.id,
      type: meta.type,
      name: meta.name,
      posterUrl: meta.posterUrl,
      backgroundUrl: meta.backgroundUrl,
      year: meta.year,
      description: meta.description,
      genres: meta.genres,
      runtime: meta.runtime,
      rating: meta.rating,
      videos: videos,
    );
  }

  /// The direct stream of a movie or episode item: the original file as
  /// stored on the server (no transcoding), with the token in the URL so
  /// both players can open it as is.
  List<ArchiveStream> streams(ArchiveSource s, String itemId) {
    final login = s.server!;
    final key = login.kind == MediaServerKind.jellyfin ? 'ApiKey' : 'api_key';
    return [
      ArchiveStream(
        url: '${s.baseUrl}/Videos/${Uri.encodeComponent(itemId)}/stream'
            '?static=true&$key=${Uri.encodeComponent(login.token)}',
        name: s.name,
        title: login.kind.label,
      ),
    ];
  }

  static String? _str(Object? v) {
    final t = v?.toString().trim();
    return (t == null || t.isEmpty) ? null : t;
  }

  /// An item's image URL, or null when it has none of that type. Images
  /// need no login on either server.
  static String? _image(ArchiveSource s, Map j, String type, String size) {
    final id = j['Id'];
    if (type == 'Backdrop') {
      final tags = j['BackdropImageTags'];
      if (tags is! List || tags.isEmpty) return null;
      return '${s.baseUrl}/Items/$id/Images/Backdrop/0?$size&tag=${tags.first}';
    }
    final tags = j['ImageTags'];
    final tag = tags is Map ? tags[type] : null;
    if (tag == null) return null;
    return '${s.baseUrl}/Items/$id/Images/$type?$size&tag=$tag';
  }

  ArchiveMeta? _meta(ArchiveSource s, Map<String, dynamic> j) {
    final id = _str(j['Id']);
    final name = _str(j['Name']);
    if (id == null || name == null) return null;
    final ticks = j['RunTimeTicks'];
    final rating = j['CommunityRating'];
    // Lets Trakt/Simkl scrobble server plays (WatchTracker).
    final providers = j['ProviderIds'];
    final imdb = providers is Map
        ? (providers['Imdb'] ?? providers['IMDB'])?.toString()
        : null;
    return ArchiveMeta(
      id: id,
      imdbId: imdb != null && imdb.startsWith('tt') ? imdb : null,
      type: j['Type'] == 'Series' ? ArchiveType.series : ArchiveType.movie,
      name: name,
      posterUrl: _image(s, j, 'Primary', 'maxHeight=600'),
      backgroundUrl: _image(s, j, 'Backdrop', 'maxWidth=1280'),
      year: _str(j['ProductionYear']),
      description: _str(j['Overview']),
      genres: [
        for (final g in (j['Genres'] as List? ?? const []))
          if (_str(g) case final t?) t,
      ],
      runtime: ticks is num && ticks > 0
          ? '${(ticks / 600000000).round()} min'
          : null,
      rating: rating is num ? rating.toStringAsFixed(1) : null,
    );
  }

  void close() => _client.close();
}
