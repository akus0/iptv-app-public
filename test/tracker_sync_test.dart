import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nox_iptv/models/archive_models.dart';
import 'package:nox_iptv/models/channel.dart';
import 'package:nox_iptv/services/archive_cache.dart';
import 'package:nox_iptv/services/archive_service.dart';
import 'package:nox_iptv/services/storage_service.dart';
import 'package:nox_iptv/services/tracker_api.dart';
import 'package:nox_iptv/services/tracker_sync.dart';
import 'package:nox_iptv/utils/constants.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _MemoryCache extends ArchiveCache {
  @override
  Future<List<ArchiveMeta>> read(String k, ArchiveCatalog c) async => const [];
  @override
  Future<DateTime?> fetchedAt(String k, ArchiveCatalog c) async => null;
  @override
  Future<void> write(String k, ArchiveCatalog c, List<ArchiveMeta> i) async {}
  @override
  Future<void> clear() async {}
  @override
  Future<void> deleteSource(String k) async {}
}

/// Trakt: Andor S1E1-2 and Heat watched; Andor S1E3 paused at 42.5 %, Dune
/// paused at 30 %. Simkl: Breaking Bad S2E5 watched (IMDb only).
class _Fake {
  final history = <String, Map<String, dynamic>>{};

  late final client = MockClient((req) async {
    final where = '${req.url.host}${req.url.path}';
    Object? body;
    switch (where) {
      case 'api.trakt.tv/sync/watched/shows':
        body = [
          {
            'show': {
              'title': 'Andor',
              'ids': {'imdb': 'tt9253284', 'tmdb': 83867}
            },
            'seasons': [
              {
                'number': 1,
                'episodes': [
                  {'number': 1},
                  {'number': 2}
                ]
              }
            ]
          }
        ];
      case 'api.trakt.tv/sync/watched/movies':
        body = [
          {
            'movie': {
              'title': 'Heat',
              'ids': {'imdb': 'tt0113277', 'tmdb': 949}
            }
          }
        ];
      case 'api.trakt.tv/sync/playback':
        body = [
          {
            'progress': 42.5,
            'paused_at': '2026-10-19T20:00:00Z',
            'type': 'episode',
            'episode': {'season': 1, 'number': 3},
            'show': {
              'title': 'Andor',
              'year': 2022,
              'ids': {'imdb': 'tt9253284', 'tmdb': 83867}
            }
          },
          {
            'progress': 30,
            'paused_at': '2026-10-18T20:00:00Z',
            'type': 'movie',
            'movie': {
              'title': 'Dune',
              'year': 2021,
              'ids': {'imdb': 'tt1160419', 'tmdb': 438631}
            }
          },
        ];
      case 'api.simkl.com/sync/all-items/shows/all':
        expect(req.url.queryParameters['extended'], 'full');
        expect(req.url.queryParameters['client_id'], isNotEmpty);
        body = {
          'shows': [
            {
              'show': {
                'title': 'Breaking Bad',
                'ids': {'imdb': 'tt0903747'}
              },
              'seasons': [
                {
                  'number': 2,
                  'episodes': [
                    {'number': 5}
                  ]
                }
              ]
            }
          ]
        };
      case 'api.simkl.com/sync/all-items/movies/completed':
        body = {'movies': []};
      case 'api.simkl.com/sync/playback':
        body = [];
      case 'api.trakt.tv/sync/history' ||
            'api.trakt.tv/sync/history/remove' ||
            'api.simkl.com/sync/history' ||
            'api.simkl.com/sync/history/remove':
        history[where] = jsonDecode(req.body) as Map<String, dynamic>;
        return http.Response('{}', 201);
    }
    if (body == null) return http.Response('', 404);
    return http.Response.bytes(utf8.encode(jsonEncode(body)), 200);
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _Fake fake;
  late StorageService storage;

  setUp(() async {
    fake = _Fake();
    SharedPreferences.setMockInitialValues({
      AppConstants.keyArchiveSources: '[]',
    });
    storage = StorageService();
    await storage.init();
    final api = TrackerApi(
        traktClientId: 'test-trakt-client',
        simklClientId: 'test-simkl-client',
        traktRedirectUri: 'https://example.invalid/oauth',
        client: fake.client);
    final service =
        ArchiveService(storage, cache: _MemoryCache(), trackers: api);
    await service.addTracker(
        const TrackerLogin(kind: TrackerKind.trakt, accessToken: 'TA'));
    await service.addTracker(
        const TrackerLogin(kind: TrackerKind.simkl, accessToken: 'SA'));
    TrackerSync.instance.attach(service, api: api);
    TrackerSync.instance.invalidate();
  });

  test('history from both accounts, keyed by IMDb and TMDB', () async {
    final h = (await TrackerSync.instance.history())!;
    final andor = TrackerHistory.keys(imdb: 'tt9253284');
    expect(h.episodeWatched(andor, 1, 2), isTrue);
    expect(h.episodeWatched(TrackerHistory.keys(tmdb: '83867'), 1, 1), isTrue);
    expect(h.episodeWatched(andor, 1, 3), isFalse);
    expect(h.pausedEpisode(andor, 1, 3)!.progress, 42.5);
    expect(h.movieWatched(TrackerHistory.keys(tmdb: '949')), isTrue);
    expect(
        h.episodeWatched(TrackerHistory.keys(imdb: 'tt0903747'), 2, 5), isTrue);
  });

  test('a provider show (TMDB only): watched marks + resume filled in',
      () async {
    final changed = await TrackerSync.instance
        .applyToSeries(storage, tmdb: '83867', episodes: {
      'p::ep1': (1, 1),
      'p::ep2': (1, 2),
      'p::ep3': (1, 3),
      'p::ep4': (1, 4),
    });
    expect(changed, isTrue);
    expect(storage.isFullyWatched('p::ep1'), isTrue);
    expect(storage.isFullyWatched('p::ep2'), isTrue);
    // Paused at 42.5 %, length unknown: a fraction the player converts.
    expect(storage.isResumeFraction('p::ep3'), isTrue);
    expect(storage.getWatchedFraction('p::ep3'), closeTo(0.425, 0.001));
    expect(storage.getLastPosition('p::ep4'), 0);
    // Nothing new the second time.
    expect(
        await TrackerSync.instance.applyToSeries(storage,
            tmdb: '83867', episodes: {'p::ep1': (1, 1)}),
        isFalse);
  });

  test('movies: watched by TMDB, a local resume point is never overwritten',
      () async {
    expect(
        await TrackerSync.instance
            .applyToMovie(storage, tmdb: '949', channelId: 'p::heat'),
        isTrue);
    expect(storage.isFullyWatched('p::heat'), isTrue);
    await storage.setLastDuration('p::dune', 9000000);
    await storage.setLastPosition('p::dune', 1000);
    expect(
        await TrackerSync.instance
            .applyToMovie(storage, imdb: 'tt1160419', channelId: 'p::dune'),
        isFalse);
    expect(storage.getLastPosition('p::dune'), 1000);
  });

  test('catalog: provider movies with a TMDB id get marks / resume points',
      () async {
    Channel movie(String id, String? tmdb) => Channel(
        id: 'p::$id',
        rawId: id,
        playlistId: 'p',
        name: id,
        group: 'Movies',
        url: 'http://x/$id',
        tmdbId: tmdb);
    final n = await TrackerSync.instance.applyToCatalog(storage, [
      movie('heat', '949'),
      movie('dune', '438631'),
      movie('other', null),
    ]);
    expect(n, 2);
    expect(storage.isFullyWatched('p::heat'), isTrue);
    expect(storage.getWatchedFraction('p::dune'), closeTo(0.30, 0.001));
    expect(storage.getLastPosition('p::other'), 0);
  });

  test('hold-OK on an episode marks it on both accounts', () async {
    await TrackerSync.instance.setWatched(
        const TrackedItem.episode(null, tmdb: '83867', season: 1, episode: 4),
        watched: true);
    for (final host in ['api.trakt.tv', 'api.simkl.com']) {
      expect(fake.history['$host/sync/history'], {
        'shows': [
          {
            'ids': {'tmdb': 83867},
            'seasons': [
              {
                'number': 1,
                'episodes': [
                  {'number': 4}
                ]
              }
            ]
          }
        ]
      });
    }
    await TrackerSync.instance
        .setWatched(const TrackedItem.movie('tt0113277'), watched: false);
    expect(fake.history['api.trakt.tv/sync/history/remove'], {
      'movies': [
        {
          'ids': {'imdb': 'tt0113277'}
        }
      ]
    });
  });

  test('Continue watching rows: paused movies, and shows once', () async {
    final api = TrackerApi(
        traktClientId: 'test-trakt-client',
        simklClientId: 'test-simkl-client',
        traktRedirectUri: 'https://example.invalid/oauth',
        client: fake.client);
    const login = TrackerLogin(kind: TrackerKind.trakt, accessToken: 'TA');
    final rows = TrackerApi.catalogsFor(TrackerKind.trakt)
        .where((c) => c.id == 'trakt.playback');
    expect(rows.length, 2);
    final movies = await api.fetchCatalog(
        login, rows.firstWhere((c) => c.type == ArchiveType.movie));
    final shows = await api.fetchCatalog(
        login, rows.firstWhere((c) => c.type == ArchiveType.series));
    expect(movies.single.name, 'Dune');
    expect(shows.single.name, 'Andor');
    expect(shows.single.id, 'tt9253284');
  });
}
