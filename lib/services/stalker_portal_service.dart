import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:crypto/crypto.dart';

import '../models/channel.dart';
import '../models/playlist_profile.dart';
import '../models/series_details.dart';
import '../models/vod_details.dart';
import '../models/xtream_category.dart';
import '../models/xtream_series.dart';
import 'catalog_api.dart';
import 'epg_database.dart';

/// User-facing errors never include a portal response, URL, MAC or token.
class PortalException implements Exception {
  const PortalException(this.message,
      {this.authentication = false, this.unsupported = false});
  final String message;
  final bool authentication, unsupported;
  @override
  String toString() => message;
}

String normalizePortalMac(String value) {
  final compact = value.trim().replaceAll(RegExp('[:-]'), '');
  if (!RegExp(r'^[0-9a-fA-F]{12}$').hasMatch(compact)) {
    throw const PortalException(
        'Enter the MAC address registered with your provider.');
  }
  return List.generate(6, (i) => compact.substring(i * 2, i * 2 + 2))
      .join(':')
      .toUpperCase();
}

/// Accept the provider's browser URL or explicit API endpoint. Discovery is
/// bounded to the two usual endpoints on that same configured portal root.
List<Uri> portalEndpoints(String value) {
  final uri = Uri.tryParse(value.trim());
  if (uri == null ||
      !const ['http', 'https'].contains(uri.scheme) ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment) {
    throw const PortalException(
        'Enter a portal URL beginning with http:// or https://.');
  }
  if (uri.path.toLowerCase().endsWith('.php')) return [uri];
  var path = uri.path.replaceFirst(RegExp(r'/+$'), '');
  path = path.replaceFirst(RegExp(r'/c(?:/index\.html?)?$'), '');
  return [
    uri.replace(path: '$path/server/load.php'),
    uri.replace(path: '$path/portal.php')
  ];
}

String portalGuideId(String playlistId, String channelId) =>
    'stalker:$playlistId:$channelId'.toLowerCase();

/// Cache ownership changes with credentials or guide mapping, never a token.
String portalConnectionIdentity(PlaylistProfile profile) => sha256
    .convert(utf8.encode(jsonEncode([
      profile.portalUrl,
      profile.portalMac,
      profile.portalUsername,
      profile.portalPassword,
      profile.portalSerial,
      profile.portalDeviceId,
      profile.portalDeviceId2,
      profile.portalSignature,
      profile.epgUrl,
      profile.includeLive
    ])))
    .toString();

/// A portal session exists only for a configured Stalker playlist. It has no
/// polling, eager library downloads or persisted authentication tokens.
class StalkerPortalService extends CatalogApi {
  StalkerPortalService(this.profile,
      {http.Client? client, this.requestTimeout = const Duration(seconds: 15)})
      : _client = client,
        _endpoints = portalEndpoints(profile.portalUrl ?? ''),
        mac = normalizePortalMac(profile.portalMac ?? '');
  final PlaylistProfile profile;
  http.Client? _client;
  http.Client get _transport => _client ??= http.Client();
  final List<Uri> _endpoints;
  final String mac;
  Uri? _endpoint;
  String? _token;
  List<Map<String, dynamic>>? _initialGenres;
  Future<void>? _authentication;
  bool _ready = false, _closed = false;
  int _generation = 0;
  int _activeRequests = 0;
  final _waitingRequests = <Completer<void>>[];
  @override
  int? maxConnections;
  @override
  DateTime? expiryDate;
  final Duration requestTimeout;
  static const _maxBytes = 16 * 1024 * 1024;
  static const _maxItems = 100000;
  static const userAgent = 'Mozilla/5.0 (QtEmbedded; U; Linux; C) '
      'AppleWebKit/533.3 (KHTML, like Gecko) MAG200 stbapp ver: 2 rev: 250 Safari/533.3';

  Map<String, String> get _headers => {
        'User-Agent': userAgent,
        'X-User-Agent': 'Model: MAG250; Link: WiFi',
        'Accept': 'application/json',
        'Cookie': 'mac=$mac; stb_lang=en; timezone=UTC',
        if (_endpoint != null)
          'Referer': (_endpoint!.path.endsWith('/server/load.php')
                  ? _endpoint!.resolve('../c/')
                  : _endpoint!.resolve('c/'))
              .toString(),
        if (_token != null) 'Authorization': 'Bearer $_token',
      };

  @override
  Future<void> authenticate() {
    if (_closed) {
      return Future.error(
          const PortalException('This playlist is no longer available.'));
    }
    if (_ready) return Future.value();
    return _authentication ??=
        _authenticate().whenComplete(() => _authentication = null);
  }

  Future<void> _authenticate() async {
    for (final endpoint in _endpoint == null ? _endpoints : [_endpoint!]) {
      _endpoint = endpoint;
      _token = null;
      try {
        final hello = await _send('stb', 'handshake', {'token': ''});
        final token = hello is Map ? _text(hello['token']) : null;
        if (token == null ||
            token.length > 4096 ||
            token.contains(RegExp(r'[\r\n]'))) {
          throw const PortalException(
              'The portal did not return a valid session.',
              unsupported: true);
        }
        _token = token;
        final login = profile.portalUsername?.trim() ?? '';
        final profileParameters = <String, String>{
          'hd': '1',
          'stb_type': 'MAG250',
          'image_version': '216',
          'num_banks': '1',
          'hw_version': '1.7-BD-00',
          'sn': '0000000000000',
          'ver':
              'ImageDescription: 0.2.16-250; ImageDate: 18 Mar 2013 19:56:53 GMT+0200; PORTAL version: 4.9.9; API Version: JS API version: 328; STB API version: 134; Player Engine version: 0x566',
          'auth_second_step': '0',
          'not_valid_token': '0',
          for (final entry in {
            'sn': profile.portalSerial,
            'device_id': profile.portalDeviceId,
            'device_id2': profile.portalDeviceId2,
            'signature': profile.portalSignature,
          }.entries)
            if (entry.value?.trim().isNotEmpty == true)
              entry.key: entry.value!.trim(),
        };
        var info = await _send('stb', 'get_profile', profileParameters);
        if (login.isNotEmpty) {
          final auth = await _send('stb', 'do_auth', {
            'login': login,
            'password': profile.portalPassword ?? '',
            if (profile.portalDeviceId?.isNotEmpty == true)
              'device_id': profile.portalDeviceId!,
            if (profile.portalDeviceId2?.isNotEmpty == true)
              'device_id2': profile.portalDeviceId2!,
          });
          if (auth == false ||
              auth == 0 ||
              auth == '0' ||
              (auth is Map &&
                  (auth['status'] == false || auth['status'] == 0))) {
            throw const PortalException(
                'The portal rejected the login details.',
                authentication: true);
          }
          info = await _send('stb', 'get_profile',
              {...profileParameters, 'auth_second_step': '1'});
        }
        if (info is! Map || info.isEmpty) {
          throw const PortalException(
              'The portal did not return an account profile.');
        }
        if ((info['status'] != null && '${info['status']}' != '0') ||
            _flag(info['blocked']) ||
            _flag(info['is_blocked']) ||
            _flag(info['need_auth']) ||
            _flag(info['not_valid_token'])) {
          throw const PortalException(
              'The portal rejected this device. Check its registered MAC and provider login.',
              authentication: true);
        }
        maxConnections = int.tryParse('${info['max_connections'] ?? ''}');
        expiryDate =
            _portalDate(info['expire_billing_date'] ?? info['expire_date']);
        if (_closed) {
          throw const PortalException('This playlist is no longer available.');
        }
        _generation++;
        _ready = true;
        return;
      } on PortalException catch (e) {
        // Some MAC-authenticated panels expose catalogues without a token API.
        // Accept that only after a real, well-formed catalogue response; an
        // explicit authentication rejection never falls back to this path.
        if (e.unsupported && _token == null && endpoint == _endpoints.last) {
          final genres = _rows(await _send('itv', 'get_genres', {}));
          _initialGenres = genres;
          _ready = true;
          _generation++;
          return;
        }
        if (!e.unsupported || endpoint == _endpoints.last) rethrow;
      }
    }
    throw const PortalException(
        'No supported Stalker endpoint was found at this URL.');
  }

  Future<dynamic> _request(String type, String action,
      [Map<String, String> parameters = const {}]) async {
    await authenticate();
    final generation = _generation;
    try {
      return await _send(type, action, parameters);
    } on PortalException catch (e) {
      if (!e.authentication) rethrow;
      // Concurrent expired-token responses share a single re-authentication.
      if (generation == _generation) _ready = false;
      await authenticate();
      return _send(type, action, parameters);
    }
  }

  Future<dynamic> _send(
      String type, String action, Map<String, String> params) async {
    if (_activeRequests >= 2) {
      final ready = Completer<void>();
      if (action == 'create_link') {
        _waitingRequests.insert(0, ready);
      } else {
        _waitingRequests.add(ready);
      }
      await ready.future;
    } else {
      _activeRequests++;
    }
    try {
      return await _sendOnce(type, action, params).timeout(requestTimeout,
          onTimeout: () => throw const PortalException(
              'The portal request timed out. Try again.'));
    } finally {
      if (_waitingRequests.isEmpty) {
        _activeRequests--;
      } else {
        _waitingRequests.removeAt(0).complete();
      }
    }
  }

  Future<dynamic> _sendOnce(
      String type, String action, Map<String, String> params) async {
    if (_closed) {
      throw const PortalException('This playlist is no longer available.');
    }
    final request = http.Request(
        'GET',
        _endpoint!.replace(queryParameters: {
          'type': type,
          'action': action,
          ...params,
          'JsHttpRequest': '1-xml',
        }))
      ..headers.addAll(_headers)
      ..followRedirects = false;
    final abort = Completer<void>();
    var bounded = http.AbortableRequest(request.method, request.url,
        abortTrigger: abort.future)
      ..headers.addAll(request.headers)
      ..followRedirects = false;
    final timer = Timer(requestTimeout, () {
      if (!abort.isCompleted) abort.complete();
    });
    try {
      var response = await _transport.send(bounded);
      // Follow a bounded canonical-path/HTTPS redirect without ever forwarding
      // a MAC, password or bearer token to a different host or downgraded URL.
      for (var redirects = 0;
          const [301, 302, 303, 307, 308].contains(response.statusCode) &&
              redirects < 3;
          redirects++) {
        await response.stream.listen((_) {}).cancel();
        final location = response.headers['location'];
        final target = location == null ? null : bounded.url.resolve(location);
        final current = bounded.url;
        final sameOrigin = target != null &&
            target.host == current.host &&
            target.userInfo.isEmpty &&
            !target.hasFragment &&
            ((target.scheme == current.scheme && target.port == current.port) ||
                (current.scheme == 'http' &&
                    current.port == 80 &&
                    target.scheme == 'https' &&
                    target.port == 443));
        if (!sameOrigin) {
          throw const PortalException(
              'The portal redirects to a different server. Enter its final portal URL.');
        }
        bounded =
            http.AbortableRequest('GET', target, abortTrigger: abort.future)
              ..headers.addAll(request.headers)
              ..followRedirects = false;
        response = await _transport.send(bounded);
      }
      if (response.statusCode != 200) {
        await response.stream.listen((_) {}).cancel();
      }
      if (response.statusCode == 401 || response.statusCode == 403) {
        throw const PortalException('The portal session was rejected.',
            authentication: true);
      }
      if (response.statusCode == 404 || response.statusCode == 405) {
        throw const PortalException('The portal endpoint is unavailable.',
            unsupported: true);
      }
      if (response.statusCode != 200) {
        throw const PortalException(
            'The portal could not complete the request. Check its URL and try again.');
      }
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response.stream) {
        if (bytes.length + chunk.length > _maxBytes) {
          if (!abort.isCompleted) abort.complete();
          throw const PortalException(
              'The portal response is too large to load safely.');
        }
        bytes.add(chunk);
      }
      final body = bytes.takeBytes();
      final decoded = body.length > 65536
          ? await compute(_decodePortal, body)
          : _decodePortal(body);
      if (bounded.url != request.url &&
          bounded.url.queryParameters['action'] == action &&
          bounded.url.queryParameters['type'] == type) {
        _endpoint = bounded.url.replace(query: '');
      }
      return decoded;
    } on PortalException {
      rethrow;
    } catch (_) {
      throw const PortalException(
          'The portal could not be reached. Check the connection and try again.');
    } finally {
      timer.cancel();
    }
  }

  Future<List<Map<String, dynamic>>> _pages(
      String type, Map<String, String> params) async {
    final items = <Map<String, dynamic>>[];
    final seen = <String>{};
    for (var page = 1; page <= 2000; page++) {
      final response =
          await _request(type, 'get_ordered_list', {...params, 'p': '$page'});
      final rows = _rows(response);
      final total = response is Map
          ? int.tryParse('${response['total_items'] ?? ''}')
          : null;
      if (rows.isEmpty) {
        if (total != null && items.length < total) {
          throw const PortalException(
              'The portal returned an incomplete catalogue. Existing content has been kept.');
        }
        return items;
      }
      var added = 0;
      for (final row in rows) {
        final id = _text(row['id']);
        if (id != null && seen.add(id)) {
          items.add(row);
          added++;
        }
      }
      if (items.length > _maxItems) {
        throw const PortalException(
            'This portal category is too large. Choose a smaller category.');
      }
      if (total != null && items.length >= total) return items;
      if (added == 0) {
        throw const PortalException(
            'The portal repeated a catalogue page. Existing content has been kept.');
      }
      if (response is List) return items;
      await Future<void>.delayed(Duration.zero);
    }
    throw const PortalException(
        'The portal catalogue exceeded its page limit.');
  }

  Future<List<XtreamCategory>> _categories(String type, String action) async {
    late final List<Map<String, dynamic>> data;
    try {
      await authenticate();
      if (type == 'itv' && _initialGenres != null) {
        data = _initialGenres!;
        _initialGenres = null;
      } else {
        data = _rows(await _request(type, action));
      }
    } on PortalException catch (e) {
      if (type != 'itv' && e.unsupported) return [];
      rethrow;
    }
    return data
        .where((r) => _text(r['id']) != null && r['id'].toString() != '*')
        .map((r) => XtreamCategory(
            id: '${r['id']}',
            name: _text(r['title'] ?? r['name']) ?? 'Uncategorized'))
        .toList();
  }

  @override
  Future<List<XtreamCategory>> getLiveCategories() =>
      _categories('itv', 'get_genres');
  @override
  Future<List<XtreamCategory>> getVodCategories() =>
      _categories('vod', 'get_categories');
  @override
  Future<List<XtreamCategory>> getSeriesCategories() =>
      _categories('series', 'get_categories');

  @override
  Future<List<Channel>> getLiveStreams(
      {required Map<String, String> categoryNames, String? categoryId}) async {
    List<Map<String, dynamic>> rows;
    try {
      final response = await _request('itv', 'get_all_channels');
      rows = _rows(response);
      final total = response is Map
          ? int.tryParse('${response['total_items'] ?? ''}')
          : null;
      if (total != null && rows.length < total) {
        rows = await _pages(
            'itv', {'genre': categoryId ?? '*', 'sortby': 'number'});
      }
    } on PortalException catch (e) {
      if (!e.unsupported) rethrow;
      rows =
          await _pages('itv', {'genre': categoryId ?? '*', 'sortby': 'number'});
    }
    if (categoryId != null) {
      rows = rows.where((r) => '${r['tv_genre_id']}' == categoryId).toList();
    }
    if (rows.length > _maxItems) {
      throw const PortalException(
          'The portal catalogue is too large to load safely.');
    }
    return compute(_portalChannels, (
      rows: rows,
      playlist: profile.id,
      categories: categoryNames,
      group: '',
      type: 'itv',
      base: _endpoint!.toString(),
      externalGuide: profile.epgUrl?.isNotEmpty == true
    ));
  }

  @override
  Future<List<Channel>> getVodStreams(
          String categoryId, String categoryName) async =>
      compute(_portalChannels, (
        rows: await _pages('vod', {'category': categoryId, 'sortby': 'name'}),
        playlist: profile.id,
        categories: const <String, String>{},
        group: categoryName,
        type: 'vod',
        base: _endpoint!.toString(),
        externalGuide: false
      ));

  @override
  Future<List<XtreamSeries>> getSeriesForCategory(String categoryId) async {
    final rows =
        await _pages('series', {'category': categoryId, 'sortby': 'name'});
    return compute(_portalSeries, (
      rows: rows,
      playlist: profile.id,
      category: categoryId,
      base: _endpoint!.toString()
    ));
  }

  @override
  Future<SeriesEpisodesResult> getSeriesEpisodes(
      int seriesId, String seriesName,
      {bool plotOnly = false}) async {
    if (plotOnly) {
      return (episodes: <int, List<Channel>>{}, plot: null, details: null);
    }
    final seasons = await _pages('series',
        {'movie_id': '$seriesId', 'season_id': '0', 'episode_id': '0'});
    if (seasons.length > 200) {
      throw const PortalException(
          'The portal returned an unsupported series structure.');
    }
    final episodes = <int, List<Channel>>{};
    for (final season in seasons) {
      final number = int.tryParse(
              '${season['season_number'] ?? season['season']}') ??
          int.tryParse(
              RegExp(r'\d+').firstMatch('${season['name']}')?.group(0) ?? '') ??
          1;
      final embedded = season['series'];
      final rows = embedded is List && embedded.isNotEmpty
          ? embedded
          : await _pages('series', {
              'movie_id': '${season['video_id'] ?? seriesId}',
              'season_id': '${season['id']}',
              'episode_id': '0'
            });
      final channels = episodes.putIfAbsent(number, () => []);
      for (final item in rows) {
        final row = item is Map
            ? Map<String, dynamic>.from(item)
            : <String, dynamic>{'id': '$item', 'episode_number': '$item'};
        final episode =
            '${row['episode_number'] ?? row['episode_num'] ?? row['series'] ?? row['id']}';
        // Only numeric embedded episodes share the season command. A
        // separately listed episode needs its own command or file lookup.
        final cmd =
            _text(row['cmd']) ?? (item is! Map ? _text(season['cmd']) : null);
        final id = _text(row['id']);
        if (id == null) continue;
        final raw = 'xt_ep_${seriesId}_${season['id']}_$id';
        channels.add(Channel(
            id: '${profile.id}::$raw',
            rawId: raw,
            playlistId: profile.id,
            name: _text(row['name']) ?? '$seriesName · S$number E$episode',
            group: seriesName,
            url: _reference('vod', cmd ?? '', extra: {
              'series': episode,
              if (cmd == null) ...{
                'movie_id': '${season['video_id'] ?? seriesId}',
                'season_id': '${season['id']}',
                'episode_id': id
              }
            }),
            logoUrl: _art(row['screenshot_uri'] ?? season['screenshot_uri'],
                _endpoint!.toString())));
      }
    }
    return (episodes: episodes, plot: null, details: null);
  }

  @override
  Future<VodDetails> getVodInfo(String streamId) async {
    final result = await _request(
        'vod', 'get_ordered_list', {'movie_id': streamId, 'p': '1'});
    final row =
        _rows(result).where((r) => '${r['id']}' == streamId).firstOrNull;
    if (row == null) return VodDetails.empty;
    return VodDetails(
        plot: _text(row['description']),
        genre: _text(row['genres_str']),
        cast: _text(row['actors']),
        director: _text(row['director']),
        releaseDate: _text(row['year']),
        rating: _text(row['rating_imdb']),
        posterUrl:
            _art(row['screenshot_uri'] ?? row['cover'], _endpoint!.toString()));
  }

  @override
  Future<String?> getVodDescription(String streamId) async =>
      (await getVodInfo(streamId)).plot;

  /// Only a selected stream is resolved. Temporary URLs and tokens never
  /// replace the stable command stored in favourites, history or SQLite.
  Future<Channel> resolve(Channel channel) async {
    final reference = Uri.parse(channel.url);
    if (reference.scheme != 'stalker' || channel.playlistId != profile.id) {
      throw const PortalException(
          'This channel does not belong to the portal.');
    }
    final params = reference.queryParameters;
    var cmd = params['cmd'] ?? '';
    if (cmd.isEmpty && params.containsKey('episode_id')) {
      final response = await _request('series', 'get_ordered_list', {
        for (final key in ['movie_id', 'season_id', 'episode_id'])
          key: params[key]!,
        'p': '1'
      });
      final rows = _rows(response);
      if (rows.length != 1) {
        throw const PortalException(
            'The portal did not identify this episode.');
      }
      cmd = _text(rows.single['cmd']) ?? '';
    }
    if (cmd.isEmpty) {
      throw const PortalException(
          'The portal did not provide a playback command.');
    }
    var url = _streamUrl(cmd);
    if (params['static'] != '1' || url == null) {
      final result = await _request(params['type'] ?? 'itv', 'create_link', {
        'cmd': cmd,
        'forced_storage': 'undefined',
        'disable_ad': '0',
        if (params.containsKey('series')) 'series': params['series']!,
      });
      url = _streamUrl(result is Map ? '${result['cmd'] ?? ''}' : '',
          base: _endpoint);
      if (url == null) {
        throw const PortalException(
            'The portal did not return a playable stream.');
      }
    }
    // Portal credentials must not be forwarded to an unrelated stream host.
    final streamOrigin = Uri.parse(url).origin;
    if (streamOrigin == (_endpoint?.origin ?? _endpoints.first.origin)) {
      await authenticate();
    }
    final sameOrigin =
        streamOrigin == (_endpoint?.origin ?? _endpoints.first.origin);
    return channel.copyWith(url: url, httpHeaders: {
      'User-Agent': userAgent,
      if (sameOrigin)
        for (final entry in _headers.entries)
          if (entry.key != 'Accept') entry.key: entry.value,
    });
  }

  Future<List<EpgRow>> guideRows() async {
    final data = await _request('itv', 'get_epg_info', {'period': '24'});
    return compute(_portalGuideRows, (data: data, playlist: profile.id));
  }

  @override
  void dispose() {
    _closed = true;
    _ready = false;
    _token = null;
    _client?.close();
  }
}

String? _text(dynamic value) =>
    value == null || '$value'.trim().isEmpty ? null : '$value'.trim();
bool _flag(dynamic v) => v == true || v == 1 || v == '1';
bool _explicitFalse(dynamic v) => v == false || v == 0 || v == '0';
DateTime? _portalDate(dynamic value) {
  final number = int.tryParse('$value');
  if (number != null && number > 0 && number < 100000000000) {
    return DateTime.fromMillisecondsSinceEpoch(number * 1000, isUtc: true);
  }
  return DateTime.tryParse('$value');
}

dynamic _decodePortal(Uint8List bytes) {
  final body = utf8
      .decode(bytes, allowMalformed: true)
      .trim()
      .replaceFirst('\ufeff', '');
  if (RegExp(
          r'^(authorization failed|access denied|unauthorized request|invalid token)[.!]?$',
          caseSensitive: false)
      .hasMatch(body)) {
    throw const PortalException('The portal session expired.',
        authentication: true);
  }
  dynamic decoded;
  try {
    decoded = jsonDecode(body);
  } catch (_) {
    throw const PortalException(
        'The address did not return a Stalker API response.',
        unsupported: true);
  }
  final data =
      decoded is Map && decoded.containsKey('js') ? decoded['js'] : decoded;
  if (data is Map) {
    final message = '${data['error'] ?? data['msg'] ?? ''}'.toLowerCase();
    if (RegExp(
            'unauthori|invalid token|access denied|authorization failed|auth failed')
        .hasMatch(message)) {
      throw const PortalException('The portal session expired.',
          authentication: true);
    }
    if ((data['error'] != null &&
            data['error'] != false &&
            data['error'] != 0 &&
            data['error'] != '0' &&
            _text(data['error']) != null) ||
        RegExp('unknown action|not supported|not implemented')
            .hasMatch(message)) {
      throw const PortalException('The portal could not complete this action.',
          unsupported: true);
    }
  }
  if (data == null) {
    throw const PortalException('This action is not available on the portal.',
        unsupported: true);
  }
  return data;
}

List<Map<String, dynamic>> _rows(dynamic data) {
  final value = data is Map && data.containsKey('data') ? data['data'] : data;
  if (value is! List || value.any((e) => e is! Map)) {
    throw const PortalException('The portal returned an unexpected catalogue.',
        unsupported: true);
  }
  return value.map((e) => Map<String, dynamic>.from(e as Map)).toList();
}

String _reference(String type, String cmd,
        {Map<String, String> extra = const {}, bool direct = false}) =>
    Uri(scheme: 'stalker', host: 'play', queryParameters: {
      'type': type,
      'cmd': cmd,
      if (direct) 'static': '1',
      ...extra
    }).toString();

String? _streamUrl(String command, {Uri? base}) {
  final cleaned = command.trim().replaceFirst(
      RegExp(r'^(ffmpeg|ffrt\d*|auto)\s+', caseSensitive: false), '');
  var uri = Uri.tryParse(cleaned);
  if (uri != null &&
      !uri.hasScheme &&
      base != null &&
      (cleaned.startsWith('/') || cleaned.startsWith('?'))) {
    uri = base.resolveUri(uri);
  }
  if (uri == null ||
      !const ['http', 'https'].contains(uri.scheme) ||
      uri.host.isEmpty ||
      cleaned.contains(RegExp(r'\s'))) {
    return null;
  }
  final host = uri.host.toLowerCase().replaceFirst(RegExp(r'\.$'), '');
  if (host == 'localhost' ||
      host.endsWith('.localhost') ||
      host == 'localhost.localdomain' ||
      host.startsWith('127.') ||
      const ['0.0.0.0', '::1', '::'].contains(host)) {
    return null;
  }
  return uri.toString();
}

String? _art(dynamic value, String base) {
  final text = _text(value);
  if (text == null) return null;
  var root = Uri.parse(base).resolve('../');
  if (Uri.parse(base).path.endsWith('/portal.php')) {
    root = Uri.parse(base).resolve('./');
  }
  final uri = root.resolve(text);
  return const ['http', 'https'].contains(uri.scheme) && uri.userInfo.isEmpty
      ? uri.toString()
      : null;
}

typedef _ChannelArgs = ({
  List<Map<String, dynamic>> rows,
  String playlist,
  Map<String, String> categories,
  String group,
  String type,
  String base,
  bool externalGuide
});
List<Channel> _portalChannels(_ChannelArgs args) {
  final channels = <Channel>[];
  final seen = <String>{};
  for (final row in args.rows) {
    final id = _text(row['id']);
    final name = _text(row['name']);
    final cmd = _text(row['cmd']);
    if (id == null || name == null || cmd == null || !seen.add(id)) continue;
    final live = args.type == 'itv';
    final raw = live ? 'st_live_$id' : 'xt_vod_$id';
    final flagsKnown = row.containsKey('use_http_tmp_link') &&
        row.containsKey('use_load_balancing');
    channels.add(Channel(
        id: '${args.playlist}::$raw',
        rawId: raw,
        playlistId: args.playlist,
        name: name,
        group: live
            ? args.categories['${row['tv_genre_id']}'] ?? 'Uncategorized'
            : args.group,
        epgKey: live
            ? (args.externalGuide
                ? _text(row['xmltv_id']) ?? portalGuideId(args.playlist, id)
                : portalGuideId(args.playlist, id))
            : null,
        url: _reference(args.type, cmd,
            direct: flagsKnown &&
                _explicitFalse(row['use_http_tmp_link']) &&
                _explicitFalse(row['use_load_balancing']) &&
                _streamUrl(cmd) != null),
        logoUrl: _art(
            row['logo'] ?? row['screenshot_uri'] ?? row['cover'], args.base),
        rating: _text(row['rating_imdb']),
        addedAt: _portalDate(row['added'])));
  }
  return channels;
}

typedef _SeriesArgs = ({
  List<Map<String, dynamic>> rows,
  String playlist,
  String category,
  String base
});
List<XtreamSeries> _portalSeries(_SeriesArgs args) => [
      for (final row in args.rows)
        if (int.tryParse('${row['id']}') != null && _text(row['name']) != null)
          XtreamSeries(
              seriesId: int.parse('${row['id']}'),
              playlistId: args.playlist,
              name: '${row['name']}',
              categoryId: args.category,
              coverUrl: _art(row['screenshot_uri'] ?? row['cover'], args.base),
              rating: _text(row['rating_imdb']))
    ];

typedef _GuideArgs = ({dynamic data, String playlist});
List<EpgRow> _portalGuideRows(_GuideArgs args) {
  final data = args.data is Map && (args.data as Map).containsKey('data')
      ? args.data['data']
      : args.data;
  if (data is! Map) {
    throw const PortalException('The portal returned an unsupported guide.');
  }
  final rows = <EpgRow>[];
  for (final entry in data.entries) {
    if (entry.value is! List) continue;
    for (final item in entry.value as List) {
      if (item is! Map) continue;
      final start = _portalDate(item['start_timestamp']);
      final stop = _portalDate(item['stop_timestamp']);
      final title = _text(item['name'] ?? item['title']);
      if (start == null ||
          stop == null ||
          !stop.isAfter(start) ||
          title == null) {
        continue;
      }
      rows.add((
        channelId: portalGuideId(args.playlist, '${entry.key}'),
        startMs: start.millisecondsSinceEpoch,
        stopMs: stop.millisecondsSinceEpoch,
        title: title,
        description: _text(item['descr'] ?? item['description']),
        isLive: _flag(item['is_live'])
      ));
      if (rows.length > 150000) {
        throw const PortalException(
            'The portal guide is too large to load safely.');
      }
    }
  }
  return rows;
}
