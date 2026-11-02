import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nox_iptv/models/sports.dart';
import 'package:nox_iptv/services/ncaa_field_hockey_rankings.dart';
import 'package:nox_iptv/services/sports_standings_service.dart';

Uint8List bytes(String value) => Uint8List.fromList(utf8.encode(value));
Map<String, Object?> scoreboard({int year = 2026}) => {
      'leagues': [
        {
          'id': '802',
          'slug': 'womens-college-field-hockey',
          'season': {'year': year}
        }
      ],
      'events': [
        {
          'season': {'year': year},
          'competitions': [
            {
              'competitors': [
                for (var i = 1; i <= 83; i++)
                  {
                    'team': {
                      'id': '$i',
                      'uid': 's:800~l:802~t:$i',
                      'displayName': i == 1
                          ? 'Penn State Nittany Lions'
                          : 'School $i Mascot',
                      'location': i == 1 ? 'Penn State' : 'School $i',
                      'shortDisplayName': i == 1 ? 'Penn State' : 'School $i',
                      'logo': 'https://example.com/$i.png',
                    }
                  },
                {
                  'team': {
                    'id': '-1',
                    'uid': 's:800~l:802~t:-1',
                    'displayName': 'TBD',
                    'location': 'TBD'
                  }
                },
              ]
            }
          ],
        }
      ],
    };
String page(
        {int count = 82,
        String first = 'Penn St.',
        int firstRank = 1,
        int year = 2026}) =>
    '''
<link rel="canonical" href="https://www.ncaa.com/rankings/fieldhockey/d1/ncaa-field-hockey-rpi" />
<figure class="rankings-last-updated">Through Games Oct. 31 $year</figure>
<table><thead><tr>${[
      'Rank',
      'School',
      'Record',
      'Conf',
      'Road',
      'Neutral',
      'Home',
      'Non-Div I',
      'Prev'
    ].map((h) => '<th>$h</th>').join()}</tr></thead><tbody>
${[
      for (var i = 1; i <= count; i++)
        '<tr><td>${i == 1 ? firstRank : i}</td><td>${i == 1 ? first : 'School $i'}</td><td>10-2</td><td>Conference</td><td>2-0</td><td>0-0</td><td>8-2</td><td>0-0</td><td>$i</td></tr>'
    ].join()}
</tbody></table>''';
LeagueStandings directory() =>
    parseFieldHockeyTeams((bytes(jsonEncode(scoreboard())), 2026));
LeagueStandings ranks(String html, LeagueStandings teams) =>
    parseFieldHockeyRankings((bytes(html), teams, DateTime(2026, 11, 1)));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
      'scoreboard preserves ESPN identities and logos, excludes placeholder teams',
      () {
    final result = directory();
    expect(result.directory, isTrue);
    expect(result.season, '2026');
    expect(result.tables.single.rows, hasLength(83));
    final first = result.tables.single.rows.firstWhere((t) => t.team.id == '1');
    expect(first.team.name, 'Penn State Nittany Lions');
    expect(first.team.logoUrl, 'https://example.com/1.png');
    expect(
        parseFieldHockeyTeams((bytes(jsonEncode(scoreboard(year: 2025))), 2026))
            .hasRows,
        isFalse);
    final wrong = scoreboard();
    wrong['leagues'] = [
      {
        'id': '999',
        'slug': 'womens-college-field-hockey',
        'season': {'year': 2026}
      }
    ];
    expect(parseFieldHockeyTeams((bytes(jsonEncode(wrong)), 2026)).hasRows,
        isFalse);
  });
  test(
      'complete NCAA RPI joins every school, supplies real rank and W-L record',
      () {
    final result = ranks(page(), directory());
    expect(result.rankings, isTrue);
    expect(result.rankingTitle, 'National RPI rankings');
    expect(result.sourceName, 'NCAA');
    expect(result.updatedAt, DateTime(2026, 10, 31));
    expect(result.tables.first.rows, hasLength(82));
    expect(result.tables.first.rows.first.team.id, '1');
    expect(result.tables.first.rows.first.stats,
        {'wins': '10', 'losses': '2', 'overall': '10-2'});
    expect(result.tables.last.rows.single.team.id, '83');
    final tied =
        ranks(page().replaceFirst('<td>2</td>', '<td>1</td>'), directory());
    expect(
        tied.tables.first.rows.take(3).map((row) => row.position), [1, 1, 3]);
  });
  test('partial, changed, outdated or unmatched rankings preserve directory',
      () {
    final original = directory();
    for (final html in [
      page(count: 81),
      page(first: 'Unknown school'),
      page(firstRank: 2),
      page(year: 2025),
      page().replaceFirst('<th>Rank</th>', '<th>Score</th>'),
      page().replaceFirst('/fieldhockey/', '/soccer-men/')
    ]) {
      expect(identical(ranks(html, original), original), isTrue);
    }
    final ambiguous = LeagueStandings(directory: true, season: '2026', tables: [
      StandingTable('Teams', [
        ...original.tables.single.rows,
        const StandingTeam(
            SportsTeam(
                id: 'other',
                name: 'Penn State',
                shortName: 'Penn State',
                abbreviation: ''),
            {},
            null),
      ])
    ]);
    expect(identical(ranks(page(), ambiguous), ambiguous), isTrue);
  });
  test(
      'field hockey loads bounded sources only on demand, caches and retains teams on poll failure',
      () async {
    final requests = <Uri>[];
    var failed = false;
    final service = SportsStandingsService(
        clock: () => DateTime(2026, 11, 1),
        client: MockClient((request) async {
          requests.add(request.url);
          if (request.url.host == 'www.ncaa.com') {
            return http.Response(page(), failed ? 503 : 200);
          }
          if (request.url.path.endsWith('/scoreboard')) {
            return http.Response(jsonEncode(scoreboard()), 200);
          }
          return http.Response('{}', 200);
        }));
    addTearDown(service.close);
    final league =
        sportsLeagueById('field-hockey.womens-college-field-hockey')!;
    expect(requests, isEmpty);
    expect((await service.load(league)).rankings, isTrue);
    expect(requests, hasLength(2));
    expect(
        requests
            .where((uri) => uri.path.endsWith('/scoreboard'))
            .single
            .queryParameters,
        {'dates': '2026', 'limit': '1000'});
    await service.load(league);
    expect(requests, hasLength(2));
    failed = true;
    final fallback = await service.load(league, refresh: true);
    expect(fallback.directory, isFalse);
    expect(fallback.rankings, isTrue);
    expect(fallback.hasRows, isTrue);
    expect(fallback.failed, isTrue);
  });
}
