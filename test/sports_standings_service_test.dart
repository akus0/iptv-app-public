import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nox_iptv/models/sports.dart';
import 'package:nox_iptv/services/sports_standings_service.dart';

String table({String season = '2026', int teams = 2}) => jsonEncode({
      'children': [
        {
          'name': 'Conference A',
          'standings': {
            'seasonDisplayName': season,
            'entries': [
              for (var i = teams; i > 0; i--)
                {
                  'team': {'id': '$i', 'displayName': 'Team $i'},
                  'stats': [
                    {'name': 'rank', 'displayValue': '$i'},
                    {'name': 'points', 'displayValue': '${10 - i}'}
                  ]
                }
            ]
          }
        }
      ]
    });
String directory(int count) => jsonEncode({
      'sports': [
        {
          'leagues': [
            {
              'teams': [
                for (var i = 0; i < count; i++)
                  {
                    'team': {'id': '$i', 'displayName': 'Team $i'}
                  }
              ]
            }
          ]
        }
      ]
    });
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final league = sportsLeagueById('eng.1')!;
  Map<String, dynamic> datedTable(int tableYear) {
    final value =
        jsonDecode(table(season: '$tableYear')) as Map<String, dynamic>;
    value['season'] = {'year': 2027, 'displayName': '2027'};
    value['seasons'] = [
      {'year': 2027, 'startDate': '2027-01-01'},
      {'year': 2026, 'startDate': '2026-01-01'},
      {'year': 2025, 'startDate': '2025-01-01'},
    ];
    value['children'][0]['standings']['season'] = tableYear;
    return value;
  }

  test('table season overrides premature root metadata without extra requests',
      () {
    final result = parseLeagueStandings((
      Uint8List.fromList(utf8.encode(jsonEncode(datedTable(2026)))),
      league,
      DateTime(2026, 11, 1),
      false,
    ));
    expect(result.season, '2026');
    expect(result.previousSeason, isFalse);
    expect(result.tables.single.rows, hasLength(2));
  });
  test('stale populated tables retry the latest begun season once', () async {
    final requests = <Uri>[];
    final service = SportsStandingsService(
        clock: () => DateTime(2026, 11, 1),
        client: MockClient((r) async {
          requests.add(r.url);
          return http.Response(
              jsonEncode(datedTable(
                  r.url.queryParameters['season'] == '2026' ? 2026 : 2023)),
              200);
        }));
    addTearDown(service.close);
    final result = await service.load(league);
    expect(requests, hasLength(2));
    expect(requests.last.queryParameters['season'], '2026');
    expect(result.season, '2026');
    expect(result.previousSeason, isFalse);
  });
  test('different table seasons cannot silently become one current table', () {
    final value = datedTable(2026);
    value['children'].add(datedTable(2023)['children'][0]);
    expect(
        () => parseLeagueStandings((
              Uint8List.fromList(utf8.encode(jsonEncode(value))),
              league,
              DateTime(2026, 11, 1),
              false,
            )),
        throwsFormatException);
  });
  test(
      'official rugby rankings retain ESPN identities and supplied world ranks',
      () async {
    final requests = <Uri>[];
    final service = SportsStandingsService(client: MockClient((r) async {
      requests.add(r.url);
      if (r.url.path.endsWith('/teams')) {
        return http.Response(
            jsonEncode({
              'sports': [
                {
                  'leagues': [
                    {
                      'teams': [
                        {
                          'team': {
                            'id': 'espn-sa',
                            'displayName': 'South Africa'
                          }
                        },
                        {
                          'team': {
                            'id': 'espn-us',
                            'displayName': 'United States of America'
                          }
                        },
                        {
                          'team': {
                            'id': 'espn-new',
                            'displayName': 'Unknown country'
                          }
                        },
                      ]
                    }
                  ]
                }
              ]
            }),
            200);
      }
      return http.Response(
          jsonEncode({
            'label': 'Mens Rugby Union',
            'effective': {'label': '2026-10-26'},
            'entries': [
              {
                'team': {'id': 'wr-us', 'name': 'USA'},
                'pos': 16,
                'pts': 71.1234
              },
              {
                'team': {'id': 'wr-sa', 'name': 'South Africa'},
                'pos': 1,
                'pts': 93.0917
              },
              {
                'team': {'id': 'wr-fr', 'name': 'France'},
                'pos': 4,
                'pts': 88.0
              },
            ]
          }),
          200);
    }));
    addTearDown(service.close);
    expect(requests, isEmpty);
    final data = await service.load(sportsLeagueById('rugby.289234')!);
    expect(data.rankings, isTrue);
    expect(data.directory, isFalse);
    expect(data.sourceName, 'World Rugby');
    expect(data.updatedAt, DateTime(2026, 10, 26));
    expect(
        data.tables.first.rows.map((r) => r.team.id), ['espn-sa', 'espn-us']);
    expect(data.tables.first.rows.map((r) => r.position), [1, 16]);
    expect(data.tables.first.rows.last.stats['rankingPoints'], '71.12');
    expect(data.tables.last.rows.single.team.id, 'espn-new');
    expect(data.tables.last.rows.single.position, isNull);
    expect(requests, hasLength(2));
    await service.load(sportsLeagueById('rugby.289234')!);
    expect(requests, hasLength(2));
  });
  test('ambiguous or invalid world ranking data never assigns guessed ranks',
      () {
    const team = SportsTeam(
        id: 'espn-1', name: 'France', shortName: 'France', abbreviation: 'FRA');
    const original = LeagueStandings(directory: true, tables: [
      StandingTable('Teams', [StandingTeam(team, {}, null)])
    ]);
    for (final entries in [
      [
        {
          'team': {'name': 'France'},
          'pos': 4,
          'pts': 88
        },
        {
          'team': {'name': 'France'},
          'pos': 5,
          'pts': 87
        }
      ],
      [
        {
          'team': {'name': 'France'},
          'pos': 0,
          'pts': 88
        }
      ],
      [
        {
          'team': {'name': 'France'},
          'pos': 4,
          'pts': '88'
        }
      ],
      [
        {
          'team': {'name': 'France A'},
          'pos': 4,
          'pts': 88
        }
      ],
    ]) {
      final data = parseWorldRugbyRankings((
        Uint8List.fromList(utf8.encode(jsonEncode({
          'label': 'Mens Rugby Union',
          'effective': {'label': '2026-10-26'},
          'entries': entries
        }))),
        original
      ));
      expect(identical(data, original), isTrue);
    }
  });
  test('unavailable rugby rankings leave the team directory usable', () async {
    final service = SportsStandingsService(
        client: MockClient((r) async => r.url.path.endsWith('/teams')
            ? http.Response(directory(4), 200)
            : http.Response('', 503)));
    addTearDown(service.close);
    final data = await service.load(sportsLeagueById('rugby.289234')!);
    expect(data.directory, isTrue);
    expect(data.failed, isFalse);
    expect(data.rankings, isFalse);
    expect(data.tables.single.rows, hasLength(4));
  });
  test(
      'future rollover retries the newest started season, not the one before it',
      () async {
    final queries = <String?>[];
    final service = SportsStandingsService(
        clock: () => DateTime(2026, 11, 1),
        client: MockClient((r) async {
          final year = r.url.queryParameters['season'];
          queries.add(year);
          return http.Response(
              year == '2027'
                  ? table(season: '2026-26')
                  : jsonEncode({
                      'season': {'year': 2028, 'displayName': '2027-27'},
                      'seasons': [
                        {'year': 2028, 'startDate': '2027-08-04'},
                        {'year': 2027, 'startDate': '2026-08-04'},
                        {'year': 2026, 'startDate': '2025-08-04'},
                      ]
                    }),
              200);
        }));
    addTearDown(service.close);
    final data = await service.load(sportsLeagueById('rugby.270563')!);
    expect(queries, [null, '2027']);
    expect(data.season, '2026-26');
    expect(data.previousSeason, isFalse);
  });
  test('large college feeds fit their bounded allowances', () async {
    for (final (id, size) in [
      ('college-football', 3 * 1024 * 1024),
      ('basketball.mens-college-basketball', 6 * 1024 * 1024),
      ('basketball.womens-college-basketball', 6 * 1024 * 1024),
    ]) {
      final service = SportsStandingsService(
          client: MockClient(
              (r) async => http.Response(table() + ' ' * size, 200)));
      addTearDown(service.close);
      final data = await service.load(sportsLeagueById(id)!);
      expect(data.failed, isFalse, reason: id);
      expect(data.tables.single.rows, hasLength(2));
    }
  });
  test('expanded college response allowances are still enforced', () async {
    final service = SportsStandingsService(
        client: MockClient(
            (r) async => http.Response(' ' * (8 * 1024 * 1024 + 1), 200)));
    addTearDown(service.close);
    expect(
        (await service
                .load(sportsLeagueById('basketball.mens-college-basketball')!))
            .failed,
        isTrue);
  });
  test('missing table endpoint still offers teams without repeated requests',
      () async {
    for (final status in [404, 410]) {
      final paths = <String>[];
      final service =
          SportsStandingsService(client: MockClient((request) async {
        paths.add(request.url.path);
        return request.url.path.endsWith('/teams')
            ? http.Response(directory(3), 200)
            : http.Response('', status);
      }));
      addTearDown(service.close);
      final data = await service.load(league);
      expect(data.failed, isFalse);
      expect(data.directory, isTrue);
      expect(data.tables.single.rows, hasLength(3));
      expect(paths, hasLength(2));
      await service.load(league);
      expect(paths, hasLength(2));
    }
  });
  test('rate limits do not cause a fallback request cascade', () async {
    var calls = 0;
    final service = SportsStandingsService(client: MockClient((request) async {
      calls++;
      return http.Response('', 429);
    }));
    addTearDown(service.close);
    expect((await service.load(league)).failed, isTrue);
    await service.load(league);
    expect(calls, 1);
  });
  test('uses the root season when rows provide no season metadata', () async {
    final response = jsonDecode(table()) as Map<String, dynamic>;
    response['children'][0]['standings'].remove('seasonDisplayName');
    response['season'] = {
      'year': 2027,
      'displayName': '2026-27 NBA Regular Season'
    };
    final service = SportsStandingsService(
        client:
            MockClient((_) async => http.Response(jsonEncode(response), 200)));
    addTearDown(service.close);
    final data = await service.load(sportsLeagueById('nba')!);
    expect(data.season, '2026-27 NBA Regular Season');
  });
  test('retains supplied logos, portraits and flags without extra requests',
      () async {
    var calls = 0;
    final service = SportsStandingsService(client: MockClient((request) async {
      calls++;
      return http.Response(
          jsonEncode({
            'standings': {
              'entries': [
                {
                  'team': {
                    'id': '1',
                    'displayName': 'Team',
                    'logos': [
                      {'href': 'https://a.espncdn.com/team.png'}
                    ]
                  }
                },
                {
                  'athlete': {
                    'id': '2',
                    'displayName': 'Driver',
                    'headshot': {'href': 'https://a.espncdn.com/driver.png'},
                    'flag': {'href': 'https://a.espncdn.com/flag.png'}
                  },
                  'stats': [
                    {
                      'name': 'championshipPts',
                      'displayName': 'Championship points',
                      'displayValue': '123'
                    }
                  ]
                },
                {
                  'athlete': {
                    'id': '3',
                    'displayName': 'Driver without portrait',
                    'flag': {'href': 'https://a.espncdn.com/flag.png'}
                  }
                },
                {
                  'team': {
                    'id': '4',
                    'displayName': 'Invalid image',
                    'logos': [
                      {'href': 'http://example.com/insecure.png'},
                      {'href': 'https://user:password@example.com/private.png'}
                    ]
                  }
                },
              ]
            }
          }),
          200);
    }));
    addTearDown(service.close);
    final data = await service.load(league);
    final rows = data.tables.single.rows;
    expect(rows.map((r) => r.team.logoUrl), [
      'https://a.espncdn.com/team.png',
      'https://a.espncdn.com/driver.png',
      'https://a.espncdn.com/flag.png',
      null,
    ]);
    expect(rows[1].statLabels['championshipPts'], 'Championship points');
    expect(calls, 1);
    await service.load(league);
    expect(calls, 1);
  });
  test('no startup request; coalesces a visible league and caches until expiry',
      () async {
    var count = 0;
    var now = DateTime(2026, 11, 1);
    final gate = Completer<void>();
    final service = SportsStandingsService(
        clock: () => now,
        client: MockClient((r) async {
          count++;
          await gate.future;
          return http.Response(table(), 200);
        }));
    addTearDown(service.close);
    expect(count, 0);
    final first = service.load(league);
    final second = service.load(league);
    gate.complete();
    final results = await Future.wait([first, second]);
    expect(count, 1);
    expect(identical(results[0], results[1]), isTrue);
    expect(results.first.tables.single.rows.map((r) => r.position), [1, 2]);
    await service.load(league);
    expect(count, 1);
    now = now.add(const Duration(minutes: 31));
    await service.load(league);
    expect(count, 2);
  });
  test(
      'previous season is bounded and labelled; missing NCAA tables still offer teams',
      () async {
    final paths = <Uri>[];
    final service = SportsStandingsService(
        clock: () => DateTime(2026, 11, 1),
        client: MockClient((r) async {
          paths.add(r.url);
          if (r.url.path.endsWith('/teams')) {
            return http.Response(directory(421), 200);
          }
          if (r.url.queryParameters['season'] == '2025') {
            return http.Response(table(season: '2025'), 200);
          }
          if (r.url.path.contains('rugby')) {
            return http.Response(
                jsonEncode({
                  'seasons': [
                    {'year': 2026, 'startDate': '2026-07-01'},
                    {'year': 2025, 'startDate': '2025-07-01'}
                  ]
                }),
                200);
          }
          return http.Response('{}', 200);
        }));
    addTearDown(service.close);
    final rugby = await service.load(sportsLeagueById('rugby.244293')!);
    expect(rugby.season, '2025');
    expect(rugby.previousSeason, isTrue);
    expect(paths, hasLength(2));
    for (final id in ['usa.ncaa.m.1', 'usa.ncaa.w.1']) {
      final result = await service.load(sportsLeagueById(id)!);
      expect(result.directory, isTrue);
      expect(result.tables.single.rows, hasLength(421));
      expect(
          result.tables.single.rows
              .every((r) => r.position == null && r.stats.isEmpty),
          isTrue);
    }
    expect(paths, hasLength(8));
    await service.load(sportsLeagueById('rugby.289234')!);
    expect(paths[8].path, endsWith('/teams'));
    expect(paths.last.host, 'api.wr-rims-prod.pulselive.com');
    expect(paths, hasLength(10));
  });
  test('empty NPC fallback does not crawl older years or invent positions',
      () async {
    final paths = <Uri>[];
    final service = SportsStandingsService(
        clock: () => DateTime(2026, 11, 1),
        client: MockClient((r) async {
          paths.add(r.url);
          return http.Response(
              r.url.path.endsWith('teams')
                  ? directory(14)
                  : jsonEncode({
                      'seasons': [
                        {'year': 2027, 'startDate': '2026-08-01'},
                        {'year': 2026, 'startDate': '2025-08-01'}
                      ]
                    }),
              200);
        }));
    addTearDown(service.close);
    final result = await service.load(sportsLeagueById('rugby.270563')!);
    expect(paths, hasLength(4));
    expect(result.directory, isTrue);
    expect(result.tables.single.rows, hasLength(14));
    await service.load(sportsLeagueById('rugby.270563')!);
    expect(paths, hasLength(4));
  });
  test('failed refresh keeps saved table and does not retry on every visit',
      () async {
    var failing = false, calls = 0;
    final service = SportsStandingsService(client: MockClient((r) async {
      calls++;
      return http.Response(failing ? '' : table(), failing ? 503 : 200);
    }));
    addTearDown(service.close);
    await service.load(league);
    failing = true;
    final failed = await service.load(league, refresh: true);
    expect(failed.failed, isTrue);
    expect(failed.hasRows, isTrue);
    await service.load(league);
    expect(calls, 2);
  });
  test('optional requests have a separate two-request concurrency bound',
      () async {
    var active = 0, peak = 0;
    final service = SportsStandingsService(client: MockClient((r) async {
      active++;
      if (active > peak) peak = active;
      await Future<void>.delayed(const Duration(milliseconds: 20));
      active--;
      return http.Response(table(), 200);
    }));
    addTearDown(service.close);
    await Future.wait([
      for (final id in ['eng.1', 'esp.1', 'ger.1', 'ita.1', 'fra.1'])
        service.load(sportsLeagueById(id)!)
    ]);
    expect(peak, 2);
  });
  test(
      'rugby column aliases retain provider values and unranked rows stay unranked',
      () async {
    final service = SportsStandingsService(
        client: MockClient((r) async => http.Response(
            jsonEncode({
              'standings': {
                'seasonDisplayName': '2026',
                'entries': [
                  {
                    'team': {'id': '1', 'displayName': 'One'},
                    'stats': [
                      {'name': 'gamesWon', 'displayValue': '4'},
                      {'name': 'gamesLost', 'displayValue': '2'},
                      {'name': 'gamesDrawn', 'displayValue': '0'},
                      {'name': 'pointsDifference', 'displayValue': '+57'},
                      {'name': 'points', 'displayValue': '19'},
                    ]
                  },
                ]
              },
            }),
            200)));
    addTearDown(service.close);
    final row = (await service.load(league)).tables.single.rows.single;
    expect(row.stats['wins'], '4');
    expect(row.stats['losses'], '2');
    expect(row.stats['ties'], '0');
    expect(row.stats['pointDifferential'], '+57');
    expect(row.stats['points'], '19');
    expect(row.position, isNull);
  });
  test(
      'oversized or malformed responses fail without replacing a usable cached table',
      () async {
    var body = table();
    final service = SportsStandingsService(
        client: MockClient((r) async => http.Response(body, 200)));
    addTearDown(service.close);
    await service.load(league);
    for (final invalid in ['invalid json', 'x' * (2 * 1024 * 1024 + 1)]) {
      body = invalid;
      final result = await service.load(league, refresh: true);
      expect(result.failed, isTrue);
      expect(result.tables.single.rows, hasLength(2));
    }
  });
  test('timeout aborts the underlying request', () async {
    var aborted = false;
    final service = SportsStandingsService(
        timeout: const Duration(milliseconds: 20),
        client: MockClient.streaming((request, body) async {
          (request as http.Abortable).abortTrigger!.then((_) => aborted = true);
          await Future<void>.delayed(const Duration(milliseconds: 80));
          return http.StreamedResponse(const Stream.empty(), 200);
        }));
    addTearDown(service.close);
    expect((await service.load(league)).failed, isTrue);
    await Future<void>.delayed(Duration.zero);
    expect(aborted, isTrue);
  });
}
