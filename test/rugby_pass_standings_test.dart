import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nox_iptv/models/sports.dart';
import 'package:nox_iptv/services/sports_standings_service.dart';
import 'package:nox_iptv/services/rugby_pass_standings.dart';
import 'npc_standings_test.dart' as npc;

Uint8List bytes(String value) => Uint8List.fromList(utf8.encode(value));
String page(String league) {
  final top = league == 'rugby.270559';
  return npc
      .html(rows: top ? npc.entries() : npc.entries().take(6).toList())
      .replaceAll('bunnings-npc', top ? 'top-14' : 'major-league-rugby')
      .replaceAll('New Zealand NPC', top ? 'Top 14' : 'Major League Rugby')
      .replaceAll('NPC Table',
          top ? 'Top 14 Standings' : 'Major League Rugby Standings')
      .replaceAll('"ovalId":1001', '"ovalId":${top ? 1002 : 1174}')
      .replaceAll('202600', top ? '202601' : '202600')
      .replaceAll(
          '"label":"2026"', top ? '"label":"2026/2027"' : '"label":"2026"')
      .replaceAll('],"2026")', top ? '],"2026/2027")' : '],"2026")');
}

LeagueStandings parsed(String league, String body, LeagueStandings teams) =>
    parseRugbyPassStandings((bytes(body), teams, 2026, league));
String scoreboard(
        {String id = 'new', String name = 'Missing', String slug = '270559'}) =>
    jsonEncode({
      'leagues': [
        {
          'slug': slug,
          'season': {'year': 2026}
        }
      ],
      'events': [
        {
          'season': {'year': 2026},
          'competitions': [
            {
              'competitors': [
                {
                  'team': {
                    'id': id,
                    'uid': 's:300~t:$id',
                    'displayName': name,
                    'shortDisplayName': name
                  }
                }
              ]
            }
          ]
        }
      ],
    });
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('Top14 and MLR validate own competition, season and complete membership',
      () {
    final teams = npc.directory();
    for (final league in ['rugby.270559', 'rugby.289262']) {
      final result = parsed(league, page(league), teams);
      expect(result.sourceName, 'RugbyPass');
      expect(result.season, league == 'rugby.270559' ? '2026/2027' : '2026');
      expect(result.previousSeason, isFalse);
      expect(result.tables.first.rows,
          hasLength(league == 'rugby.270559' ? 14 : 6));
      expect(result.tables.first.rows.first.team.id, 'espn-1');
      expect(result.tables.first.rows.first.stats['points'], '40');
      expect(identical(parsed(league, npc.html(), teams), teams), isTrue);
      expect(
          identical(
              parsed(
                  league,
                  page(league).replaceFirst('"started":1', '"started":0'),
                  teams),
              teams),
          isTrue);
    }
  });
  test(
      'scoreboard supplements missing IDs without replacing known directory identities',
      () {
    final teams = npc.directory();
    final result = supplementRugbyTeams((
      bytes(scoreboard(id: '999', name: 'Vannes')),
      teams,
      'rugby.270559',
      2026
    ));
    expect(result.tables.single.rows, hasLength(15));
    expect(result.tables.single.rows.last.team.id, '999');
    final duplicate = supplementRugbyTeams((
      bytes(scoreboard(id: '999', name: 'Province 2')),
      teams,
      'rugby.270559',
      2026
    ));
    expect(duplicate.tables.single.rows, hasLength(14));
    expect(duplicate.tables.single.rows.any((row) => row.team.id == 'espn-2'),
        isTrue);
    expect(
        identical(
            supplementRugbyTeams((
              bytes(scoreboard(slug: 'wrong')),
              teams,
              'rugby.270559',
              2026
            )),
            teams),
        isTrue);
  });
  test('ambiguous source names or incomplete tables preserve existing data',
      () {
    final original = npc.directory(ambiguous: true);
    expect(
        identical(
            parsed('rugby.270559', page('rugby.270559'), original), original),
        isTrue);
    final teams = npc.directory();
    expect(
        identical(
            parsed(
                'rugby.270559',
                page('rugby.270559')
                    .replaceFirst('"position":14', '"position":13'),
                teams),
            teams),
        isTrue);
  });
  test(
      'stale ESPN table uses current complete source, avoids empty season retry and caches',
      () async {
    final requests = <Uri>[];
    var fail = false;
    final service = SportsStandingsService(
        clock: () => DateTime(2026, 11, 1),
        client: MockClient((request) async {
          requests.add(request.url);
          if (request.url.host == 'www.rugbypass.com') {
            return http.Response.bytes(
                bytes(page('rugby.270559')), fail ? 503 : 200);
          }
          if (request.url.path.endsWith('/teams')) {
            return http.Response(
                jsonEncode({
                  'sports': [
                    {
                      'leagues': [
                        {
                          'teams': [
                            for (var i = 1; i <= 15; i++)
                              {
                                'team': {
                                  'id': 'espn-$i',
                                  'displayName':
                                      i == 1 ? 'Manawatu' : 'Province $i'
                                }
                              }
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
                'season': {'year': 2027, 'displayName': '2026-27'},
                'seasons': [
                  {'year': 2027, 'startDate': '2026-08-01T00:00Z'}
                ],
                'standings': {
                  'season': 2023,
                  'seasonDisplayName': '2022-23',
                  'entries': [
                    {
                      'team': {'id': 'old', 'displayName': 'Old team'},
                      'stats': []
                    }
                  ]
                },
              }),
              200);
        }));
    addTearDown(service.close);
    fail = true;
    final initial = await service.load(sportsLeagueById('rugby.270559')!);
    expect(initial.season, '2022-23');
    expect(initial.previousSeason, isTrue);
    expect(initial.hasRows, isTrue);
    requests.clear();
    fail = false;
    final result =
        await service.load(sportsLeagueById('rugby.270559')!, refresh: true);
    expect(result.sourceName, 'RugbyPass');
    expect(result.season, '2026/2027');
    expect(result.tables, hasLength(1));
    expect(result.tables.single.rows, hasLength(14));
    expect(requests, hasLength(3));
    expect(requests.any((uri) => uri.queryParameters.containsKey('season')),
        isFalse);
    await service.load(sportsLeagueById('rugby.270559')!);
    expect(requests, hasLength(3));
    fail = true;
    final old =
        await service.load(sportsLeagueById('rugby.270559')!, refresh: true);
    expect(old.season, '2026/2027');
    expect(old.sourceName, 'RugbyPass');
    expect(old.previousSeason, isFalse);
    expect(old.failed, isTrue);
  });
}
