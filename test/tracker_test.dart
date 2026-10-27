import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nox_iptv/models/archive_models.dart';
import 'package:nox_iptv/services/archive_api_service.dart';
import 'package:nox_iptv/services/archive_cache.dart';
import 'package:nox_iptv/services/archive_service.dart';
import 'package:nox_iptv/services/storage_service.dart';
import 'package:nox_iptv/services/tracker_api.dart';
import 'package:nox_iptv/services/watch_tracker.dart';
import 'package:nox_iptv/utils/constants.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Fake Trakt (api.trakt.tv + the relay's /api/trakt/) and Simkl. Records
/// every request as "METHOD host/path" plus scrobble bodies.
class Fake {
  final log = <String>[];
  final scrobbles = <String, Map<String, dynamic>>{};
  bool approved = false;

  late final client = MockClient((req) async {
    final where = '${req.url.host}${req.url.path}';
    log.add('${req.method} $where');
    Object? body;
    var status = 200;
    switch (where) {
      case 'api.trakt.tv/oauth/device/code':
        body = {
          'device_code': 'dev123456',
          'user_code': 'ABCD1234',
          'verification_url': 'https://trakt.tv/activate',
          'expires_in': 600,
          'interval': 5
        };
      case 'api.trakt.tv/oauth/device/token':
        // Public client: the client id, never a secret.
        expect((jsonDecode(req.body) as Map).containsKey('client_secret'),
            isFalse);
        if (!approved) {
          status = 400;
        } else {
          body = {
            'access_token': 'TA',
            'refresh_token': 'TR',
            'expires_in': 86400,
            'created_at': 1700000000
          };
        }
      case 'api.trakt.tv/users/settings':
        body = {
          'user': {'username': 'ann'}
        };
      case 'api.simkl.com/oauth2/device':
        expect(req.method, 'POST');
        body = {
          'device_code': 'simkldev0001',
          'user_code': 'BDWP-HQPK',
          'verification_uri': 'https://simkl.com/pin',
          'verification_uri_complete':
              'https://simkl.com/pin?user_code=BDWP-HQPK',
          'expires_in': 900,
          'interval': 5
        };
      case 'api.simkl.com/oauth2/token':
        final b = jsonDecode(req.body) as Map;
        expect(b.containsKey('client_secret'), isFalse);
        if (b['grant_type'] == 'refresh_token') {
          body = {
            'access_token': 'SA2',
            'token_type': 'Bearer',
            'expires_in': 604800,
            'refresh_token': 'SR',
          };
        } else if (!approved) {
          status = 400;
          body = {'error': 'authorization_pending'};
        } else {
          expect(
              b['grant_type'], 'urn:ietf:params:oauth:grant-type:device_code');
          expect(b['device_code'], 'simkldev0001');
          body = {
            'access_token': 'SA',
            'token_type': 'Bearer',
            'expires_in': 604800,
            'refresh_token': 'SR',
          };
        }
      case 'api.simkl.com/users/settings':
        body = {
          'user': {'name': 'Bo'}
        };
      case 'api.trakt.tv/sync/watchlist/movies':
        expect(req.headers['Authorization'], 'Bearer TA');
        body = [
          {
            'movie': {
              'title': 'Heat',
              'year': 1995,
              'ids': {'imdb': 'tt0113277', 'trakt': 1}
            }
          },
          {
            'movie': {
              'title': 'No imdb',
              'ids': {'trakt': 2}
            }
          },
        ];
      case 'api.simkl.com/sync/all-items/shows/plantowatch':
        body = {
          'shows': [
            {
              'show': {
                'title': 'Andor',
                'year': 2022,
                'ids': {'imdb': 'tt9253284', 'simkl': 5}
              }
            }
          ]
        };
      case 'api.trakt.tv/scrobble/start' ||
            'api.trakt.tv/scrobble/pause' ||
            'api.trakt.tv/scrobble/stop' ||
            'api.simkl.com/scrobble/start' ||
            'api.simkl.com/scrobble/pause' ||
            'api.simkl.com/scrobble/stop':
        scrobbles['${req.url.host} ${req.url.path}'] =
            jsonDecode(req.body) as Map<String, dynamic>;
        status = 201;
        body = {};
      case 'v3-cinemeta.strem.io/meta/movie/tt0113277.json':
        body = {
          'meta': {'id': 'tt0113277', 'type': 'movie', 'name': 'Heat'}
        };
      case 'streams.example/stream/movie/tt0113277.json':
        body = {
          'streams': [
            {'url': 'https://cdn.example/heat.mp4', 'name': 'Example'}
          ]
        };
    }
    if (body == null) return http.Response('', status == 200 ? 404 : status);
    return http.Response.bytes(utf8.encode(jsonEncode(body)), status);
  });
}

/// No sqflite in tests: rows stay in memory.
class _MemoryCache extends ArchiveCache {
  final _rows = <String, List<ArchiveMeta>>{};
  @override
  Future<List<ArchiveMeta>> read(
          String sourceKey, ArchiveCatalog catalog) async =>
      _rows['$sourceKey|${catalog.slug}'] ?? const [];
  @override
  Future<DateTime?> fetchedAt(String sourceKey, ArchiveCatalog catalog) async =>
      null;
  @override
  Future<void> write(String sourceKey, ArchiveCatalog catalog,
          List<ArchiveMeta> items) async =>
      _rows['$sourceKey|${catalog.slug}'] = items;
  @override
  Future<void> clear() async => _rows.clear();
  @override
  Future<void> deleteSource(String sourceKey) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Trakt: device sign-in through the relay, token + user', () async {
    final fake = Fake();
    final api = TrackerApi(
        traktClientId: 'test-trakt-client',
        simklClientId: 'test-simkl-client',
        traktRedirectUri: 'https://example.invalid/oauth',
        client: fake.client);
    final code = await api.startSignIn(TrackerKind.trakt);
    expect(code.userCode, 'ABCD1234');
    expect(code.verificationUrl, 'https://trakt.tv/activate');
    expect(await api.pollSignIn(code), isNull); // still pending
    fake.approved = true;
    final login = (await api.pollSignIn(code))!;
    expect(login.accessToken, 'TA');
    expect(login.refreshToken, 'TR');
    expect(login.expiresAtMs, (1700000000 + 86400) * 1000);
    expect(login.userName, 'ann');
    expect(TrackerLogin.fromJson(login.toJson())!.refreshToken, 'TR');
  });

  test('Simkl: AUTH V2 device sign-in, no secret, 7-day token + refresh',
      () async {
    final fake = Fake();
    final api = TrackerApi(
        traktClientId: 'test-trakt-client',
        simklClientId: 'test-simkl-client',
        traktRedirectUri: 'https://example.invalid/oauth',
        client: fake.client);
    final code = await api.startSignIn(TrackerKind.simkl);
    expect(code.userCode, 'BDWP-HQPK');
    expect(code.verificationUrl, 'https://simkl.com/pin');
    expect(code.qrUrl, 'https://simkl.com/pin?user_code=BDWP-HQPK');
    expect(await api.pollSignIn(code), isNull); // authorization_pending
    fake.approved = true;
    final login = (await api.pollSignIn(code))!;
    expect(login.accessToken, 'SA');
    expect(login.refreshToken, 'SR');
    expect(login.needsRefresh, isFalse); // 7 days left
    expect(login.userName, 'Bo');
    final fresh = await api.refresh(login);
    expect(fresh.accessToken, 'SA2');
    expect(fresh.refreshToken, 'SR');
    expect(fresh.userName, 'Bo');
    expect(fake.log.any((l) => l.contains('api.trakt.tv')), isFalse);
  });

  test('lists become rows by IMDb id (titles without one left out)', () async {
    final api = TrackerApi(
        traktClientId: 'test-trakt-client',
        simklClientId: 'test-simkl-client',
        traktRedirectUri: 'https://example.invalid/oauth',
        client: Fake().client);
    const trakt = TrackerLogin(kind: TrackerKind.trakt, accessToken: 'TA');
    final movies = await api.fetchCatalog(
        trakt,
        TrackerApi.catalogsFor(TrackerKind.trakt)
            .firstWhere((c) => c.id == 'trakt.watchlist'));
    expect(movies.single.id, 'tt0113277');
    expect(movies.single.year, '1995');
    expect(movies.single.posterUrl, contains('tt0113277'));
    const simkl = TrackerLogin(kind: TrackerKind.simkl, accessToken: 'SA');
    final shows = await api.fetchCatalog(
        simkl,
        TrackerApi.catalogsFor(TrackerKind.simkl).firstWhere((c) =>
            c.id == 'simkl.plantowatch' && c.type == ArchiveType.series));
    expect(shows.single.name, 'Andor');
    expect(shows.single.type, ArchiveType.series);
  });

  test('Media Hub: tracker rows play through stream add-ons; plays scrobble',
      () async {
    final fake = Fake();
    const addon = ArchiveSource(
      manifestUrl: 'https://streams.example/manifest.json',
      name: 'Streams',
      catalogs: [],
      catalogProviderUrl: ArchiveCatalogProvider.baseUrl,
    );
    SharedPreferences.setMockInitialValues({
      AppConstants.keyArchiveSources: jsonEncode([addon.toJson()]),
    });
    final storage = StorageService();
    await storage.init();
    final api = TrackerApi(
        traktClientId: 'test-trakt-client',
        simklClientId: 'test-simkl-client',
        traktRedirectUri: 'https://example.invalid/oauth',
        client: fake.client);
    final service = ArchiveService(storage,
        api: ArchiveApiService(client: fake.client),
        cache: _MemoryCache(),
        trackers: api);
    WatchTracker.instance.attach(service, api: api);

    final trakt = await service.addTracker(const TrackerLogin(
        kind: TrackerKind.trakt, accessToken: 'TA', userName: 'ann'));
    await service.addTracker(
        const TrackerLogin(kind: TrackerKind.simkl, accessToken: 'SA'));
    // One account per tracker; the add-on stays.
    expect(service.sources.length, 3);
    expect(service.trackerSource(TrackerKind.trakt)!.description, 'ann');

    final heat = (await service.meta(
        trakt,
        const ArchiveMeta(
            id: 'tt0113277', type: ArchiveType.movie, name: 'Heat')))!;
    final options = await service.streams(trakt, heat);
    expect(options.single.stream.url, 'https://cdn.example/heat.mp4');
    expect(options.single.source.name, 'Streams');

    final ch = service.channelFor(trakt, heat, options.single.stream);
    WatchTracker.instance.register(ch.id, TrackedItem.movie(heat.imdb!));
    await WatchTracker.instance.started(ch.id);
    await WatchTracker.instance.stopped(
        ch.id, const Duration(minutes: 30), const Duration(minutes: 100));
    expect(fake.scrobbles['api.trakt.tv /scrobble/start']!['movie'], {
      'ids': {'imdb': 'tt0113277'}
    });
    expect(fake.scrobbles['api.trakt.tv /scrobble/pause']!['progress'], 30.0);
    expect(fake.scrobbles['api.simkl.com /scrobble/pause'], isNotNull);
    await WatchTracker.instance.stopped(
        ch.id, const Duration(minutes: 90), const Duration(minutes: 100));
    expect(fake.scrobbles['api.trakt.tv /scrobble/stop']!['progress'], 90.0);
    expect(fake.scrobbles['api.simkl.com /scrobble/stop'], isNotNull);

    // Untracked channels (live TV…) are never reported.
    fake.scrobbles.clear();
    await WatchTracker.instance.started('p::live1');
    expect(fake.scrobbles, isEmpty);
  });

  test('episode scrobble body: show by IMDb id + season/number', () {
    expect(
        const TrackedItem.episode('tt9253284', season: 1, episode: 3).toBody(),
        {
          'show': {
            'ids': {'imdb': 'tt9253284'}
          },
          'episode': {'season': 1, 'number': 3},
        });
  });

  test('IMDb id: from a tt id, an episode id, or a server provider id', () {
    expect(
        const ArchiveMeta(id: 'tt1:1:2', type: ArchiveType.series, name: 'x')
            .imdb,
        'tt1');
    expect(
        const ArchiveMeta(
                id: 'jf123', type: ArchiveType.movie, name: 'x', imdbId: 'tt9')
            .imdb,
        'tt9');
    expect(
        const ArchiveMeta(id: 'own:5', type: ArchiveType.movie, name: 'x').imdb,
        isNull);
  });
}
