import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nox_iptv/models/sports.dart';
import 'package:nox_iptv/services/npc_standings.dart';
import 'package:nox_iptv/services/sports_standings_service.dart';

List<Map<String, Object?>> entries() => [
      for (var i = 1; i <= 14; i++)
        {
          'name': 'New Zealand NPC',
          'team': {
            'id': i + 100,
            'name': 'Province $i Mascots',
            'shortName': i == 1 ? 'Manawatū' : 'Province $i'
          },
          'position': i,
          'played': 10,
          'won': 8,
          'drawn': 0,
          'lost': 2,
          'pointsDiff': 71,
          'points': 40,
          'bonus': 8,
          'pointsFor': 311,
          'pointsAgainst': 240,
        }
    ];
String html(
        {List<Map<String, Object?>>? rows,
        int year = 2026,
        int competition = 1001,
        List<Map<String, Object?>> logos = const [],
        int? selectedYear}) =>
    '''
<title>Hilux NPC Table $year | NPC Rugby Standings | RugbyPass</title>
<link rel="canonical" href="https://www.rugbypass.com/bunnings-npc/standings/" />
<div id="standings-data" style="display: none;">${jsonEncode({
          'hasStandings': true,
          'standingsConference': false,
          'ovalId': competition,
          'standings': logos,
          'standingsData': {'standings': rows ?? entries()}
        })}</div>
<script>CompStandings.init(${jsonEncode([
          {'season': year * 100, 'label': '$year', 'standings': 1, 'started': 1}
        ])},"${selectedYear ?? year}")</script>''';
LeagueStandings directory({bool ambiguous = false}) =>
    LeagueStandings(directory: true, tables: [
      StandingTable('Teams', [
        for (var i = 1; i <= 14; i++)
          StandingTeam(
              SportsTeam(
                  id: 'espn-$i',
                  name: i == 1 ? 'Manawatu' : 'Province $i',
                  shortName: i == 1 ? 'Manawatu' : 'Province $i',
                  abbreviation: 'P$i',
                  logoUrl: 'https://example.com/$i.png'),
              const {},
              null,
              nameAliases: ambiguous && i == 14 ? {'Province 2'} : {})
      ])
    ]);
LeagueStandings parse(String body, {LeagueStandings? teams}) =>
    parseNpcStandings(
        (Uint8List.fromList(utf8.encode(body)), teams ?? directory(), 2026));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('province logos require a unique source ID, matching name and CDN URL',
      () {
    const logo =
        'https://eu-cdn.rugbypass.com/webp-images/images/team-images/logos/png/123.png.webp?maxw=70';
    const valid = {'id': 101, 'name': 'Manawatu', 'logo': logo};
    final correct = parse(html(logos: [valid])).tables.single.rows.first;
    expect(correct.team.id, 'espn-1');
    expect(correct.team.name, 'Manawatu');
    expect(correct.team.logoUrl, logo);
    for (final logos in [
      [valid, valid],
      [
        {...valid, 'id': 999}
      ],
      [
        {...valid, 'name': 'Another province'}
      ],
      [
        {...valid, 'logo': 'https://example.com/image.png'}
      ],
      [
        {...valid, 'logo': logo.replaceFirst('https:', 'http:')}
      ],
    ]) {
      expect(parse(html(logos: logos)).tables.single.rows.first.team.logoUrl,
          'https://example.com/1.png');
    }
  });
  test(
      'complete NPC table preserves all 14 ESPN identities, logos, ranks and source values',
      () {
    final result = parse(html());
    expect(result.directory, isFalse);
    expect(result.rankings, isFalse);
    expect(result.sourceName, 'RugbyPass');
    expect(result.season, '2026');
    expect(result.previousSeason, isFalse);
    expect(result.tables.single.name, 'Regular season');
    expect(result.tables.single.rows.map((r) => r.team.id),
        [for (var i = 1; i <= 14; i++) 'espn-$i']);
    expect(result.tables.single.rows.map((r) => r.position),
        [for (var i = 1; i <= 14; i++) i]);
    expect(result.tables.single.rows.first.team.logoUrl,
        'https://example.com/1.png');
    expect(result.tables.single.rows.first.stats['points'], '40');
    expect(result.tables.single.rows.first.stats['bonusPoints'], '8');
  });
  test('source selected season is validated and previous season is labelled',
      () {
    final previous = parse(html(year: 2025));
    expect(previous.season, '2025');
    expect(previous.previousSeason, isTrue);
    final original = directory();
    for (final body in [
      html(year: 2024),
      html(year: 2027),
      html(selectedYear: 2025),
      html(competition: 999),
      html().replaceFirst('CompStandings.init', 'Different.init')
    ]) {
      expect(identical(parse(body, teams: original), original), isTrue);
    }
  });
  test(
      'partial, duplicate, unmatched or ambiguous data never becomes standings',
      () {
    final original = directory();
    for (final rows in [
      entries().take(13).toList(),
      [...entries().take(13), entries().first],
      [
        {
          ...entries().first,
          'team': {'shortName': 'Unknown Province'}
        },
        ...entries().skip(1)
      ],
      [
        {...entries().first, 'points': '40'},
        ...entries().skip(1)
      ],
      [
        {...entries().first, 'position': 0},
        ...entries().skip(1)
      ],
      [
        {...entries().first, 'played': -1},
        ...entries().skip(1)
      ]
    ]) {
      expect(identical(parse(html(rows: rows), teams: original), original),
          isTrue);
    }
    final ambiguous = directory(ambiguous: true);
    expect(identical(parse(html(), teams: ambiguous), ambiguous), isTrue);
  });
  test(
      'NPC fetches one optional page, caches it and keeps directory if page fails',
      () async {
    final requests = <Uri>[];
    var fail = false;
    final service = SportsStandingsService(
        clock: () => DateTime(2026, 11, 1),
        client: MockClient((r) async {
          requests.add(r.url);
          if (r.url.host == 'www.rugbypass.com') {
            return http.Response.bytes(
                utf8.encode(fail ? '' : html()), fail ? 503 : 200);
          }
          if (r.url.path.endsWith('/teams')) {
            return http.Response(
                jsonEncode({
                  'sports': [
                    {
                      'leagues': [
                        {
                          'teams': [
                            for (var i = 1; i <= 14; i++)
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
          return http.Response('{}', 200);
        }));
    addTearDown(service.close);
    expect(requests, isEmpty);
    final league = sportsLeagueById('rugby.270563')!;
    expect((await service.load(league)).sourceName, 'RugbyPass');
    expect(requests, hasLength(3));
    await service.load(league);
    expect(requests, hasLength(3));
    fail = true;
    final fallback = await service.load(league, refresh: true);
    expect(fallback.directory, isFalse);
    expect(fallback.sourceName, 'RugbyPass');
    expect(fallback.failed, isTrue);
    expect(fallback.tables.single.rows, hasLength(14));
    expect(requests.where((u) => u.host == 'www.rugbypass.com'), hasLength(2));
  });
}
