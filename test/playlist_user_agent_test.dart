import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nox_iptv/models/channel.dart';
import 'package:nox_iptv/models/playlist_profile.dart';
import 'package:nox_iptv/services/catalog_database.dart';
import 'package:nox_iptv/services/m3u_parser.dart';
import 'package:nox_iptv/services/playback_service.dart';
import 'package:nox_iptv/services/multiview_session.dart';
import 'package:nox_iptv/services/playlist_manager.dart';
import 'package:nox_iptv/services/playlist_session.dart';
import 'package:nox_iptv/services/stalker_portal_service.dart';
import 'package:nox_iptv/services/storage_service.dart';
import 'package:nox_iptv/services/xtream_api_service.dart';
import 'package:nox_iptv/utils/playlist_user_agent.dart';
import 'stalker_portal_test.dart' show portalProfile, js;

PlaylistProfile profile(String id,
        {String agent = '', String mode = 'm3u', String? url}) =>
    PlaylistProfile(
        id: id,
        name: id,
        mode: mode,
        userAgent: agent,
        m3uUrl: url,
        xtreamServer: url,
        xtreamUsername: 'fixture',
        xtreamPassword: 'fixture',
        epgUrl: url == null ? null : '$url/guide',
        sortOrder: 0,
        createdAt: DateTime(2026));
Channel channel(String id, {Map<String, String> headers = const {}}) => Channel(
    id: '$id::1',
    rawId: '1',
    playlistId: id,
    name: 'Fixture',
    group: 'TV',
    url: 'https://example.invalid/never-open',
    httpHeaders: headers);

class _FailingStorage extends StorageService {
  bool fail = false;
  @override
  Future<void> setPlaylists(List<PlaylistProfile> profiles) {
    if (fail) throw StateError('fixture write failure');
    return super.setPlaylists(profiles);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late StorageService storage;
  setUp(() async {
    HttpOverrides.global = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler(
            'dev.flutter.pigeon.wakelock_plus_platform_interface.WakelockPlusApi.toggle',
            (_) async => const StandardMessageCodec().encodeMessage([null]));
    SharedPreferences.setMockInitialValues({});
    storage = StorageService();
    await storage.init();
  });

  test(
      'legacy/default profiles retain defaults; overrides survive copies and storage',
      () async {
    final original = profile('one');
    expect(original.userAgent, isEmpty);
    expect(original.toJson().containsKey('userAgent'), isFalse);
    expect(PlaylistProfile.fromJson(original.toJson()).userAgent, isEmpty);
    final edited = original.copyWith(userAgent: '  VLC/3.0.20  ');
    await storage.setPlaylists([edited, profile('two')]);
    expect(storage.getPlaylists().first.userAgent, 'VLC/3.0.20');
    expect(edited.copyWith(name: 'Renamed').userAgent, 'VLC/3.0.20');
    expect(edited.copyWith(userAgent: '').requestHeaders, isEmpty);
    expect(identical(edited.requestHeaders, edited.requestHeaders), isTrue);
    for (final invalid in [
      'bad\r\nInjected: value',
      'bad\tvalue',
      'x' * 513,
      '\u2603'
    ]) {
      expect(playlistUserAgentError(invalid), isNotNull);
      expect(
          PlaylistProfile.fromJson({...original.toJson(), 'userAgent': invalid})
              .requestHeaders,
          isEmpty);
    }
  });

  test(
      'overrides isolate playlists and preserve catalogue revisions and source headers',
      () async {
    final manager = PlaylistManager(storage, CatalogDatabase());
    addTearDown(manager.dispose);
    await manager.addPlaylist(profile('one'));
    await manager.addPlaylist(profile('two', agent: 'VLC'));
    final first = channel('one', headers: {
      'user-agent': 'SourceAgent',
      'Referer': 'https://example.invalid/'
    });
    final revision = manager.liveRevision;
    expect(manager.playbackHeaders(first), same(first.httpHeaders));
    await manager.setPlaylistUserAgent('one', 'IPTVSmartersPro');
    expect(manager.liveRevision, revision);
    expect(manager.isLoading, isFalse);
    expect(manager.playbackHeaders(first), {
      'User-Agent': 'IPTVSmartersPro',
      'Referer': 'https://example.invalid/'
    });
    expect(manager.playbackHeaders(channel('two')), {'User-Agent': 'VLC'});
    expect(manager.playbackHeaders(channel('missing')), isEmpty);
    await manager.setPlaylistUserAgent('one', '');
    expect(manager.playbackHeaders(first), same(first.httpHeaders));
    expect(manager.liveRevision, revision);
    await expectLater(manager.setPlaylistUserAgent('one', 'bad\r\nheader'),
        throwsFormatException);
    expect(manager.profiles.first.userAgent, isEmpty);
  });

  test('a failed save preserves the old override and catalogue revision',
      () async {
    final failing = _FailingStorage();
    await failing.init();
    final manager = PlaylistManager(failing, CatalogDatabase());
    addTearDown(manager.dispose);
    await manager.addPlaylist(profile('one', agent: 'TiviMate'));
    final revision = manager.liveRevision;
    failing.fail = true;
    await expectLater(
        manager.setPlaylistUserAgent('one', 'VLC'), throwsStateError);
    expect(manager.playbackHeaders(channel('one')), {'User-Agent': 'TiviMate'});
    expect(manager.liveRevision, revision);
    expect(failing.getPlaylists().single.userAgent, 'TiviMate');
  });

  test(
      'normal, retry and multiview controller factories read current overrides',
      () async {
    final manager = PlaylistManager(storage, CatalogDatabase());
    final playback = PlaybackService(storage, manager);
    final multi =
        MultiviewSession(httpHeadersForChannel: manager.playbackHeaders);
    addTearDown(playback.dispose);
    addTearDown(manager.dispose);
    await manager.addPlaylist(profile('one', agent: 'TiviMate'));
    final cached =
        channel('one', headers: {'Referer': 'https://example.invalid/'});
    final normal = playback.createController(cached);
    expect(normal.httpHeaders,
        {'Referer': 'https://example.invalid/', 'User-Agent': 'TiviMate'});
    await manager.setPlaylistUserAgent('one', 'VLC');
    final retry = playback.createController(cached,
        url: 'https://backup.example.invalid/never-open');
    expect(retry.httpHeaders['User-Agent'], 'VLC');
    expect(retry.dataSource, 'https://backup.example.invalid/never-open');
    final grid = multi.createController(cached);
    expect(grid.httpHeaders['User-Agent'], 'VLC');
    await manager.setPlaylistUserAgent('one', '');
    final cleared = playback.createController(cached);
    expect(cleared.httpHeaders, cached.httpHeaders);
    expect(cached.httpHeaders.containsKey('User-Agent'), isFalse,
        reason: 'The catalogue must never retain a playlist override');
    for (final controller in [normal, retry, grid, cleared]) {
      await controller.dispose();
    }
    await multi.close();
  });

  test(
      'M3U download requires the configured agent, including through redirects',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final seen = <(String, String?)>[];
    server.listen((r) async {
      final agent = r.headers.value('user-agent');
      seen.add((r.uri.path, agent));
      if (agent != 'IPTVSmartersPro') {
        r.response.statusCode = 403;
      } else if (r.uri.path == '/redirect') {
        r.response.statusCode = 302;
        r.response.headers.set('Location', '/playlist');
      } else {
        r.response.write(
            '#EXTM3U\n#EXTINF:-1 tvg-id="fixture",Fixture\nhttps://example.invalid/never-open\n');
      }
      await r.response.close();
    });
    final url = 'http://127.0.0.1:${server.port}/redirect';
    await expectLater(
        M3uParser.fetchAndParse(url, playlistId: 'p'), throwsException);
    final rows = await M3uParser.fetchAndParse(url,
        playlistId: 'p', headers: playlistUserAgentHeaders('IPTVSmartersPro'));
    expect(rows, hasLength(1));
    expect(seen.skip(1),
        [('/redirect', 'IPTVSmartersPro'), ('/playlist', 'IPTVSmartersPro')]);
    expect(rows.single.httpHeaders, isEmpty);
  });

  test(
      'XC authentication and all catalogue endpoints use the selected agent; live edits update requests',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final seen = <(String, String?)>[];
    var requiredAgent = 'IPTVSmartersPro';
    server.listen((r) async {
      final action = r.uri.queryParameters['action'] ?? '';
      final agent = r.headers.value('user-agent');
      seen.add((action, agent));
      if (agent != requiredAgent) {
        r.response.statusCode = 403;
      } else {
        r.response.headers.contentType = ContentType.json;
        r.response.write(jsonEncode(action.isEmpty
            ? {
                'user_info': {'auth': 1, 'status': 'Active'}
              }
            : action.endsWith('_info')
                ? {'info': {}, 'episodes': {}}
                : []));
      }
      await r.response.close();
    });
    final base = 'http://127.0.0.1:${server.port}';
    final p = profile('p', agent: requiredAgent, mode: 'xtream', url: base);
    final api = XtreamApiService(
        server: base,
        username: 'fixture',
        password: 'fixture',
        playlistId: 'p');
    await expectLater(api.authenticate(), throwsA(isA<XtreamException>()));
    api.userAgent = p.userAgent;
    await api.authenticate();
    await api.getLiveCategories();
    await api.getVodCategories();
    await api.getSeriesCategories();
    await api.getLiveStreams(categoryNames: {});
    await api.getVodStreams('1', 'Movies');
    await api.getSeriesForCategory('1');
    await api.getSeriesEpisodes(1, 'Series');
    await api.getVodInfo('1');
    expect(seen.skip(1).every((r) => r.$2 == requiredAgent), isTrue);
    final session = PlaylistSession(
        profile: p.copyWith(includeLive: false),
        storage: storage,
        catalogDb: CatalogDatabase(),
        favoriteIds: () => {},
        favoriteSeriesIds: () => {},
        onNotify: () {});
    final beforeRestore = seen.length;
    await session.restoreOrLoad();
    expect(seen.length, beforeRestore,
        reason: 'Cached library setup adds no authentication request');
    await session.catalogApi!.authenticate();
    expect(seen.last.$2, requiredAgent);
    requiredAgent = 'VLC';
    session.profile = p.copyWith(userAgent: requiredAgent);
    await session.catalogApi!.getVodCategories();
    expect(seen.last.$2, requiredAgent);
    session.profile = p.copyWith(userAgent: '');
    await expectLater(session.catalogApi!.getVodCategories(),
        throwsA(isA<XtreamException>()));
    expect(seen.last.$2, isNot(anyOf('VLC', 'IPTVSmartersPro')));
  });

  for (final agent in ['', 'TiviMate']) {
    test(
        'portal retains protocol headers and scopes stream credentials: agent=$agent',
        () async {
      final seen = <http.Request>[];
      final p = portalProfile().copyWith(userAgent: agent);
      final api = StalkerPortalService(p, client: MockClient((r) async {
        seen.add(r);
        return r.url.queryParameters['action'] == 'handshake'
            ? js({'token': 'fixture-token'})
            : js({'status': 0});
      }));
      addTearDown(api.dispose);
      await api.authenticate();
      final expected = agent.isEmpty ? StalkerPortalService.userAgent : agent;
      expect(seen.every((r) => r.headers['user-agent'] == expected), isTrue);
      expect(seen.first.headers['x-user-agent'], contains('MAG250'));
      final raw = channel(p.id).copyWith(
          url: Uri(scheme: 'stalker', host: 'play', queryParameters: {
        'cmd': 'http://cdn.example.invalid/fixture',
        'static': '1'
      }).toString());
      final resolved = await api.resolve(raw);
      expect(resolved.httpHeaders, {'User-Agent': expected});
      final same = await api.resolve(raw.copyWith(
          url: Uri(scheme: 'stalker', host: 'play', queryParameters: {
        'cmd': 'https://portal.example.test/fixture',
        'static': '1'
      }).toString()));
      expect(same.httpHeaders['User-Agent'], expected);
      expect(same.httpHeaders['Authorization'], 'Bearer fixture-token');
      expect(same.httpHeaders['Cookie'], contains('mac='));
    });
  }
}
