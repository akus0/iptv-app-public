import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nox_iptv/models/sports.dart';
import 'package:nox_iptv/models/sports_details.dart';
import 'package:nox_iptv/services/sports_details_service.dart';

const league = SportsLeague(
    id: 'nba',
    espnPath: 'basketball/nba',
    name: 'NBA',
    shortName: 'NBA',
    logoUrl: '');
const home =
    SportsTeam(id: '1', name: 'Home', shortName: 'Home', abbreviation: 'H');
const away =
    SportsTeam(id: '2', name: 'Away', shortName: 'Away', abbreviation: 'A');
SportsGame game(
        {String id = '100',
        SportsLeague competition = league,
        String source = 'ESPN'}) =>
    SportsGame(
        id: id,
        league: competition,
        start: DateTime.utc(2026, 11, 2),
        state: GameState.live,
        statusText: 'Q2',
        home: home,
        away: away,
        source: source);
Map<String, dynamic> summary(
        {String id = '100', String state = 'in', bool mismatch = false}) =>
    {
      'header': {
        'id': id,
        'name': 'Away at Home',
        'competitions': [
          {
            'id': id,
            'status': {
              'type': {'state': state, 'detail': 'Q2'}
            },
            'competitors': [
              {
                'team': {'id': mismatch ? '3' : '1'}
              },
              {
                'team': {'id': '2'}
              }
            ]
          }
        ]
      },
      'gameInfo': {
        'venue': {'fullName': 'Arena'},
        'attendance': 1234
      },
      'boxscore': {
        'teams': [
          {
            'team': {'id': '1'},
            'statistics': [
              {'name': 'rebounds', 'label': 'Rebounds', 'displayValue': '20'},
              {'name': 'assists', 'label': 'Assists', 'displayValue': '8'}
            ]
          },
          {
            'team': {'id': '2'},
            'statistics': [
              {'name': 'assists', 'label': 'Assists', 'displayValue': '10'},
              {'name': 'rebounds', 'label': 'Rebounds', 'displayValue': '18'}
            ]
          }
        ],
        'players': [
          {
            'team': {'id': '1', 'displayName': 'Home'},
            'statistics': [
              {
                'labels': ['MIN', 'REB', 'PTS'],
                'keys': ['minutes', 'rebounds', 'points'],
                'athletes': [
                  {
                    'athlete': {'id': '5', 'displayName': 'Scorer'},
                    'starter': true,
                    'stats': ['12', '3', '9']
                  },
                  {
                    'athlete': {'id': '6', 'displayName': 'Bench'},
                    'didNotPlay': true,
                    'stats': []
                  },
                  {
                    'athlete': {'id': '7', 'displayName': 'Broken row'},
                    'stats': ['4']
                  }
                ]
              }
            ]
          }
        ]
      },
      'rosters': [
        {
          'team': {'id': '1', 'displayName': 'Home'},
          'roster': [
            {
              'athlete': {
                'id': '5',
                'displayName': 'Scorer',
                'position': {'abbreviation': 'C'}
              },
              'jersey': '9',
              'starter': true
            }
          ]
        }
      ]
    };
Map<String, dynamic> teamBody({String id = '1'}) => {
      'team': {
        'id': id,
        'displayName': 'Home',
        'standingSummary': '2nd in conference',
        'record': {
          'items': [
            {'description': 'Overall', 'summary': '5-2'}
          ]
        },
        'athletes': [
          {
            'id': '5',
            'displayName': 'Player',
            'jersey': '9',
            'position': {'abbreviation': 'C'}
          }
        ]
      }
    };
void main() {
  test(
      'period scores follow displayed teams and retain absent periods',
      () async {
    final body = jsonDecode(jsonEncode(summary())) as Map<String, dynamic>;
    final sides = body['header']['competitions'][0]['competitors'] as List;
    sides[0]['linescores'] = [
      {'displayValue': '10'},
      {'displayValue': '12'}
    ];
    sides[1]['linescores'] = [
      {'displayValue': '11'}
    ];
    sides[0]['score'] = '22';
    sides[1]['score'] = '11';
    final service = SportsDetailsService(
        client: MockClient((_) async => http.Response(jsonEncode(body), 200)));
    addTearDown(service.close);
    final result = await service.game(game());
    final periods =
        result.sections.singleWhere((s) => s.kind == SportsDetailKind.periods);
    expect(periods.columns, ['Q1', 'Q2']);
    for (final row in periods.rows) {
      expect(row.values, row.id == '1' ? ['10', '12'] : ['11', '–']);
    }
    expect(result.scores, {'1': '22', '2': '11'});
  });

  TestWidgetsFlutterBinding.ensureInitialized();
  test('comparison joins stat names and player columns retain exact indexes',
      () async {
    final service = SportsDetailsService(
        client:
            MockClient((_) async => http.Response(jsonEncode(summary()), 200)));
    addTearDown(service.close);
    final result = await service.game(game());
    expect(result.failed, isFalse);
    final stats =
        result.sections.singleWhere((s) => s.title == 'Match statistics');
    expect(stats.columns, ['A', 'H']);
    expect(stats.rows.singleWhere((r) => r.label == 'Rebounds').values,
        ['18', '20']);
    final players =
        result.sections.singleWhere((s) => s.title.endsWith('Players'));
    expect(players.columns, ['PTS', 'REB', 'MIN']);
    expect(players.rows.first.values, ['9', '3', '12']);
    expect(players.rows.last.detail, 'Did not play');
    expect(players.rows.length, 2);
    expect(result.sections.last.rows.single.values, ['9', 'C']);
  });
  test('pregame figures are explicitly separated from match statistics',
      () async {
    final service = SportsDetailsService(
        client: MockClient((_) async =>
            http.Response(jsonEncode(summary(state: 'pre')), 200)));
    addTearDown(service.close);
    final result = await service.game(game());
    expect(result.sections.any((s) => s.title == 'Pregame comparison'), isTrue);
    expect(result.sections.any((s) => s.title == 'Match statistics'), isFalse);
  });
  test('regional sources and nonnumeric identities never call ESPN', () async {
    var calls = 0;
    final service = SportsDetailsService(client: MockClient((_) async {
      calls++;
      return http.Response('{}', 200);
    }));
    addTearDown(service.close);
    for (final source in [
      'NPB',
      'KBO',
      'ABL',
      'K League',
      'B.League',
      'EASL',
      'Channel guide'
    ]) {
      final regional = SportsLeague(
          id: 'regional',
          espnPath: 'baseball/npb',
          name: source,
          shortName: source,
          logoUrl: '',
          source: source);
      expect(
          (await service.game(game(competition: regional, source: source)))
              .unsupported,
          isTrue);
      expect((await service.team(regional, home)).unsupported, isTrue);
    }
    expect((await service.game(game(id: 'kleague:1'))).unsupported, isTrue);
    expect(calls, 0);
  });
  test('one team endpoint supplies record and roster without fanout', () async {
    final urls = <Uri>[];
    final service = SportsDetailsService(client: MockClient((r) async {
      urls.add(r.url);
      return http.Response(jsonEncode(teamBody()), 200);
    }));
    addTearDown(service.close);
    final result = await service.team(league, home);
    expect(result.sections.map((s) => s.title), ['Team record', 'Roster']);
    expect(result.sections.last.rows.single.values, ['9', 'C']);
    expect(urls.single.path, '/apis/site/v2/sports/basketball/nba/teams/1');
    expect(urls.single.queryParameters, {'enable': 'roster'});
  });
  test('different event or matchup or team identity fails closed', () async {
    for (final body in [summary(id: '101'), summary(mismatch: true)]) {
      final service = SportsDetailsService(
          client:
              MockClient((_) async => http.Response(jsonEncode(body), 200)));
      expect((await service.game(game())).failed, isTrue);
      service.close();
    }
    final service = SportsDetailsService(
        client: MockClient(
            (_) async => http.Response(jsonEncode(teamBody(id: '3')), 200)));
    addTearDown(service.close);
    expect((await service.team(league, home)).failed, isTrue);
  });
  test('inflight and TTL caching coalesce requests, failures preserve data',
      () async {
    var now = DateTime.utc(2026, 11, 2), calls = 0, fail = false;
    final gate = Completer<void>();
    final service = SportsDetailsService(
        clock: () => now,
        client: MockClient((_) async {
          calls++;
          await gate.future;
          return http.Response(fail ? '{}' : jsonEncode(summary()), 200);
        }));
    addTearDown(service.close);
    final first = service.game(game()),
        second = service.game(game(), refresh: true);
    gate.complete();
    final original = await first.timeout(const Duration(seconds: 3));
    expect(identical(original, await second), isTrue);
    expect(identical(original, await service.game(game())), isTrue);
    expect(calls, 1);
    now = now.add(const Duration(minutes: 3));
    fail = true;
    final failed = await service.game(game());
    expect(failed.failed, isTrue);
    expect(failed.stale, isTrue);
    expect(failed.fetchedAt, original.fetchedAt);
    expect(failed.sections, same(original.sections));
    await service.game(game());
    expect(calls, 2);
    now = now.add(const Duration(seconds: 31));
    await service.game(game());
    expect(calls, 3);
  });
  test('concurrent selections use no more than two HTTP slots', () async {
    var active = 0, peak = 0;
    final gates = <Completer<void>>[];
    final service = SportsDetailsService(client: MockClient((r) async {
      active++;
      if (active > peak) peak = active;
      final gate = Completer<void>();
      gates.add(gate);
      await gate.future;
      active--;
      return http.Response(
          jsonEncode(summary(id: r.url.queryParameters['event']!)), 200);
    }));
    addTearDown(service.close);
    final requests = [
      for (var i = 0; i < 5; i++) service.game(game(id: '${100 + i}'))
    ];
    while (gates.length < 2) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(gates.length, 2);
    for (var i = 0; i < 5; i++) {
      while (gates.length <= i) {
        await Future<void>.delayed(Duration.zero);
      }
      gates[i].complete();
    }
    expect((await Future.wait(requests)).every((r) => !r.failed), isTrue);
    expect(peak, 2);
  });
  test(
      'oversized responses stop reading before parsing and timeout releases slot',
      () async {
    var read = 0;
    final service =
        SportsDetailsService(client: MockClient.streaming((r, _) async {
      Stream<List<int>> chunks() async* {
        for (var i = 0; i < 8; i++) {
          read++;
          yield List.filled(512 * 1024, 32);
        }
      }

      return http.StreamedResponse(chunks(), 200);
    }));
    addTearDown(service.close);
    expect((await service.game(game())).failed, isTrue);
    expect(read, 5);
    final timeout = SportsDetailsService(
        timeout: const Duration(milliseconds: 20),
        client: MockClient((_) async {
          await Future<void>.delayed(const Duration(milliseconds: 50));
          return http.Response('{}', 200);
        }));
    addTearDown(timeout.close);
    expect((await timeout.game(game())).failed, isTrue);
  });
  test(
      'missing provider data differs from a valid response without extra sections',
      () async {
    final empty = SportsDetailsService(
        client:
            MockClient((_) async => http.Response('{"team":{"id":"1"}}', 200)));
    addTearDown(empty.close);
    final result = await empty.team(league, home);
    expect(result.failed, isFalse);
    expect(result.unsupported, isFalse);
    expect(result.sections, isEmpty);
    expect(result.message, contains('No roster'));
    final absent = SportsDetailsService(
        client: MockClient((_) async => http.Response('{}', 404)));
    addTearDown(absent.close);
    expect((await absent.team(league, home)).unsupported, isTrue);
  });
  test(
      'details cache has a fixed capacity and cannot retain every visited event',
      () async {
    var calls = 0;
    final service = SportsDetailsService(client: MockClient((r) async {
      calls++;
      return http.Response(
          jsonEncode(summary(id: r.url.queryParameters['event']!)), 200);
    }));
    addTearDown(service.close);
    for (var i = 0; i < 25; i++) {
      await service.game(game(id: '${100 + i}'));
    }
    await service.game(game(id: '124'));
    expect(calls, 25);
    await service.game(game());
    expect(calls, 26);
  });

  final fixtures = Platform.environment['SPORTS_DETAILS_FIXTURES'];
  for (final path in [
    'soccer/eng.1',
    'basketball/nba',
    'football/nfl',
    'hockey/nhl',
    'baseball/mlb',
    'basketball/mens-college-basketball',
    'football/college-football',
    'rugby/270563'
  ]) {
    test('actual official summary and team response: $path', () async {
      final stem = '$fixtures/${path.replaceAll('/', '-')}';
      final body = jsonDecode(File('$stem-summary.json').readAsStringSync())
          as Map<String, dynamic>;
      final header = body['header'] as Map<String, dynamic>;
      final competitors =
          (header['competitions'] as List).first['competitors'] as List;
      SportsTeam side(dynamic x) {
        final t = x['team'];
        return SportsTeam(
            id: t['id'],
            name: t['displayName'],
            shortName: t['displayName'],
            abbreviation: t['abbreviation']);
      }

      final a = side(competitors[0]), b = side(competitors[1]);
      final competition = SportsLeague(
          id: path, espnPath: path, name: path, shortName: path, logoUrl: '');
      final teamJson = jsonDecode(File('$stem-team.json').readAsStringSync())
          as Map<String, dynamic>;
      final selected = side({'team': teamJson['team']});
      final service = SportsDetailsService(
          client: MockClient((r) async => http.Response.bytes(
              File(r.url.path.endsWith('summary')
                      ? '$stem-summary.json'
                      : '$stem-team.json')
                  .readAsBytesSync(),
              200)));
      addTearDown(service.close);
      final result = await service.game(SportsGame(
          id: header['id'],
          league: competition,
          start: DateTime.now(),
          state: GameState.post,
          statusText: '',
          home: a,
          away: b));
      expect(result.failed, isFalse);
      expect(result.sections, isNotEmpty);
      expect(
          result.sections.every(
              (s) => s.rows.every((r) => r.values.length == s.columns.length)),
          isTrue);
      final team = await service.team(competition, selected);
      expect(team.failed, isFalse);
      if (!path.startsWith('rugby/')) {
        expect(team.sections.any((s) => s.title == 'Roster'), isTrue);
      }
    },
        skip: fixtures == null
            ? 'Set SPORTS_DETAILS_FIXTURES to public response fixtures'
            : false);
  }
}
