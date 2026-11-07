import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nox_iptv/models/sports.dart';
import 'package:nox_iptv/services/ncaa_soccer_rankings.dart';
import 'package:nox_iptv/services/sports_standings_service.dart';

String poll(
        {String gender = 'men',
        String header = 'POINTS',
        String record = '12-0-2',
        bool dated = true,
        int count = 25}) =>
    '''
<link rel="canonical" href="https://www.ncaa.com/rankings/soccer-$gender/d1/${gender == 'men' ? 'united-soccer-coaches' : 'iwsoc-coaches-poll'}" />
${dated ? '<figure class="rankings-last-updated">Through Games OCT. 25, 2026</figure>' : ''}
<table><thead><tr><th>RANK</th><th>SCHOOL</th><th>FIRST-PLACE VOTES</th><th>RECORD</th><th>PREVIOUS</th><th>$header</th></tr></thead><tbody>
${[
      for (var i = 1; i <= count; i++)
        '<tr><td>${i == 24 ? 'T23' : i == 23 ? 'T23' : i}</td><td>School $i</td><td>0</td><td>$record</td><td>$i</td><td>${200 - i}</td></tr>'
    ].join()}
</tbody></table>''';

LeagueStandings teams({bool ambiguous = false}) =>
    LeagueStandings(directory: true, tables: [
      StandingTable('Teams', [
        for (var i = 1; i <= 26; i++)
          StandingTeam(
              SportsTeam(
                  id: 'espn-$i',
                  name: 'School $i Mascots',
                  shortName: 'Short $i',
                  abbreviation: 'S$i'),
              const {},
              null,
              nameAliases: {'School $i', if (ambiguous && i == 26) 'School 1'})
      ])
    ]);

LeagueStandings parse(String html,
        {LeagueStandings? directory, String gender = 'men'}) =>
    parseNcaaSoccerRankings(
        (Uint8List.fromList(utf8.encode(html)), directory ?? teams(), gender));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('official poll keeps ESPN identities, tied positions and W-L-T values',
      () {
    final result = parse(poll());
    expect(result.rankings, isTrue);
    expect(result.rankingTitle, 'National rankings');
    expect(result.sourceName, 'United Soccer Coaches');
    expect(result.updatedAt, DateTime(2026, 10, 25));
    expect(result.tables.first.rows, hasLength(25));
    expect(result.tables.first.rows[23].position, 23);
    expect(result.tables.first.rows[23].team.id, 'espn-24');
    expect(result.tables.first.rows.first.stats, {
      'wins': '12',
      'losses': '0',
      'ties': '2',
      'pollPoints': '199',
      'overall': '12-0-2'
    });
    expect(result.tables.last.rows.single.team.id, 'espn-26');
    expect(result.tables.last.rows.single.position, isNull);
    expect(parse(poll(gender: 'women'), gender: 'women').sourceName,
        'IWSOC Coaches Poll');
  });
  test('ambiguous team names never become guessed favourite identities', () {
    final original = teams(ambiguous: true);
    expect(identical(parse(poll(), directory: original), original), isTrue);
  });
  test('unknown, incomplete or changed tables fall back to the whole directory',
      () {
    final original = teams();
    for (final html in [
      poll(header: 'NEW POINTS'),
      poll(record: '12-2'),
      poll(dated: false),
      poll(count: 24),
      poll().replaceFirst('School 5</td>', 'Unknown School</td>'),
      poll().replaceFirst('School 5</td>', 'School 4</td>'),
      poll().replaceFirst('<td>1</td>', '<td>?</td>')
    ]) {
      expect(identical(parse(html, directory: original), original), isTrue);
    }
    expect(
        identical(parse(poll(gender: 'women'), directory: original), original),
        isTrue);
  });
  test('NCAA enrichment is on demand, bounded and cached', () async {
    final requests = <Uri>[];
    final service = SportsStandingsService(client: MockClient((r) async {
      requests.add(r.url);
      if (r.url.host == 'www.ncaa.com') return http.Response(poll(), 200);
      if (r.url.path.endsWith('/teams')) {
        return http.Response(
            jsonEncode({
              'sports': [
                {
                  'leagues': [
                    {
                      'teams': [
                        for (var i = 1; i <= 26; i++)
                          {
                            'team': {
                              'id': 'espn-$i',
                              'displayName': 'School $i Mascots',
                              'shortDisplayName': 'Short $i',
                              'location': 'School $i'
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
    final league = sportsLeagueById('usa.ncaa.m.1')!;
    final result = await service.load(league);
    expect(result.rankings, isTrue);
    expect(requests, hasLength(3));
    expect(requests.last.host, 'www.ncaa.com');
    await service.load(league);
    expect(requests, hasLength(3));
  });
  test('invalid official markup does not discard the usable team directory',
      () async {
    final service = SportsStandingsService(client: MockClient((r) async {
      if (r.url.path.endsWith('/teams')) {
        return http.Response(
            jsonEncode({
              'sports': [
                {
                  'leagues': [
                    {
                      'teams': [
                        {
                          'team': {'id': '1', 'displayName': 'School'}
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
          r.url.host == 'www.ncaa.com'
              ? poll().replaceFirst('</td>', '</changed>')
              : '{}',
          200);
    }));
    addTearDown(service.close);
    final result = await service.load(sportsLeagueById('usa.ncaa.m.1')!);
    expect(result.directory, isTrue);
    expect(result.failed, isFalse);
    expect(result.tables.single.rows.single.team.id, '1');
  });
}
