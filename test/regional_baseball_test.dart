import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nox_iptv/models/sports.dart';
import 'package:nox_iptv/services/regional_baseball.dart';
import 'package:nox_iptv/services/sports_standings_service.dart';
import 'package:nox_iptv/services/sports_service.dart';

Uint8List bytes(String text) => Uint8List.fromList(utf8.encode(text));
String npbStandings() => '<title>2026 Regular Season | NPB.jp</title>${[
      ['Hanshin', 'Yomiuri', 'DeNA', 'Hiroshima', 'Yakult', 'Chunichi'],
      ['SoftBank', 'Seibu', 'Nippon-Ham', 'ORIX', 'Lotte', 'Rakuten'],
    ].map((teams) => '<table><thead><tr><th></th>${[
          'G',
          'W',
          'L',
          'T',
          'PCT',
          'GB'
        ].map((x) => '<th>$x</th>').join()}</tr></thead><tbody>${teams.map((name) => '<tr><th><span>$name</span><span>$name</span></th><td>12</td><td>8</td><td>3</td><td>1</td><td>.727</td><td>-</td></tr>').join()}</tbody></table>').join()}';
String npbSchedule(
        {String score1 = '2',
        String score2 = '1',
        String comment = '',
        String time = '18:00'}) =>
    '''<link rel="canonical" href="https://npb.jp/games/2026/schedule_10_detail.html"><table><tr id="date1001"><td><div class="team1">阪神</div><div class="score1">$score1</div><div class="state">-</div><div class="score2">$score2</div><div class="team2">巨人</div></td><td><div class="time">$time</div><div class="comment">$comment</div></td></tr></table>''';
String kboStandings() => '<input id="sample_inputYear" value="2026"><table>${[
      'KT',
      'SAMSUNG',
      'KIA',
      'LG',
      'DOOSAN',
      'SSG',
      'LOTTE',
      'NC',
      'HANWHA',
      'KIWOOM'
    ].indexed.map((e) => '<tr>${{
          'RK': '${e.$1 + 1}',
          'TEAM': e.$2,
          'GAMES': '12',
          'W': '8',
          'L': '3',
          'D': '1',
          'PCT': '.727',
          'GB': '0.0'
        }.entries.map((c) => '<td title="${c.key}">${c.value}</td>').join()}</tr>').join()}</table>';
String kboScoreboard(String date,
        {String state = 'FINAL',
        String home = 'KT',
        String homeScore = '6',
        String awayScore = '1'}) =>
    '''<input value="$date(MON)" id="sample_txtSearchDate"><div class="scoreboard_time"><span class="team_name">SAMSUNG</span><span class="team_score">$awayScore</span><span class="timer">$state</span><span class="team_score">$homeScore</span><span class="team_name">$home</span></div><div class="scoreboard_local"><span class="local_time">SUWON 18:30</span></div><div class="tbl_common"></div>''';
Map<String, dynamic> ablTeam(int id) => {
      'id': id,
      'name': 'Club $id',
      'shortName': 'Club $id',
      'abbreviation': 'C$id',
      'league': {'id': 595},
      'sport': {'id': 17}
    };
String ablStandings(int year) => jsonEncode({
      'records': [
        {
          'league': {'id': 595},
          'sport': {'id': 17},
          'teamRecords': [
            for (var i = 1; i <= 4; i++)
              {
                'season': '$year',
                'team': ablTeam(i),
                'leagueRank': '$i',
                'gamesPlayed': 12,
                'leagueGamesBack': '-',
                'leagueRecord': {
                  'wins': 8,
                  'losses': 3,
                  'ties': 1,
                  'pct': '.727'
                }
              }
          ]
        }
      ]
    });
String ablSchedule(
        {bool tbd = false, int league = 595, String status = 'Scheduled'}) =>
    jsonEncode({
      'dates': [
        {
          'games': [
            {
              'gamePk': 10,
              'gameDate': '2026-11-19T08:30:00Z',
              'status': {
                'abstractGameState': 'Preview',
                'detailedState': status,
                'startTimeTBD': tbd
              },
              'teams': {
                'home': {
                  'team': {
                    ...ablTeam(1),
                    'league': {'id': league}
                  }
                },
                'away': {'team': ablTeam(2)}
              }
            }
          ]
        }
      ]
    });

void main() {
  final npb = sportsLeagueById('baseball.npb')!,
      kbo = sportsLeagueById('baseball.kbo')!,
      abl = sportsLeagueById('baseball.abl')!;
  test(
      'regional leagues are opt-in and existing automatic guide identities stay unchanged',
      () {
    for (final league in [npb, kbo, abl]) {
      expect(kDefaultSportsLeagueIds, isNot(contains(league.id)));
      expect(supportsSportsScoreboard(league), isTrue);
      expect(league.allowSportOnlySuggestions, isFalse);
    }
    expect(sportsLeagueById('guide.npb')!.source, 'Channel guide');
    expect(sportsLeagueById('guide.kbo')!.source, 'Channel guide');
  });
  test('NPB validates all12 unique identities and correct season', () {
    final result = parseNpbStandings((bytes(npbStandings()), 2026));
    expect(result.tables.length, 2);
    expect(result.tables.first.rows.first.team.id, 'npb:t');
    expect(result.tables.last.rows.first.nameAliases, contains('ソフトバンク'));
    expect(() => parseNpbStandings((bytes(npbStandings()), 2025)),
        throwsFormatException);
    expect(
        () => parseNpbStandings(
            (bytes(npbStandings().replaceAll('Yomiuri', 'Hanshin')), 2026)),
        throwsFormatException);
    expect(
        () => parseNpbStandings((
              bytes(npbStandings().replaceFirst('<td>8</td>', '<td>-8</td>')),
              2026
            )),
        throwsFormatException);
  });
  test('KBO validates complete standings and stable team aliases', () {
    final result = parseKboStandings(bytes(kboStandings()));
    expect(result.tables.single.rows.length, 10);
    expect(result.tables.single.rows.first.team.id, 'kbo:KT');
    expect(
        () => parseKboStandings(
            bytes(kboStandings().replaceAll('SAMSUNG', 'UNKNOWN'))),
        throwsFormatException);
  });
  test(
      'NPB dates use JST, keep tied finals and exclude unknown/cancelled/past placeholders',
      () {
    final game = parseNpbScoreboard(npbSchedule(score2: '2'), npb).single;
    expect(game.start, DateTime.utc(2026, 10, 1, 9));
    expect(game.home.id, 'npb:t');
    expect(game.home.score, '2');
    expect(game.away.score, '2');
    expect(game.state, GameState.post);
    expect(parseNpbScoreboard(npbSchedule(comment: '中止'), npb), isEmpty);
    expect(parseNpbScoreboard(npbSchedule(time: '25:00'), npb), isEmpty);
    expect(
        parseNpbScoreboard(npbSchedule(score1: '', score2: ''), npb,
            now: DateTime.utc(2026, 10, 2)),
        isEmpty);
    expect(
        parseNpbScoreboard(npbSchedule(score1: '', score2: ''), npb,
                now: DateTime.utc(2026, 9, 1))
            .single
            .state,
        GameState.pre);
    expect(() => parseNpbScoreboard('<html>Error</html>', npb),
        throwsFormatException);
  });
  test(
      'KBO preserves KST/home identity, ignores cancelled and unverified states',
      () {
    final game = parseKboScoreboard(kboScoreboard('2026.11.03'), kbo).single;
    expect(game.home.id, 'kbo:KT');
    expect(game.away.id, 'kbo:SS');
    expect(game.home.score, '6');
    expect(game.start, DateTime.utc(2026, 11, 3, 9, 30));
    expect(
        parseKboScoreboard(
                kboScoreboard('2026.11.03',
                    state: '18:30', homeScore: '', awayScore: ''),
                kbo)
            .single
            .state,
        GameState.pre);
    expect(
        parseKboScoreboard(
            kboScoreboard('2026.11.03', state: 'CANCELLED'), kbo),
        isEmpty);
    expect(
        parseKboScoreboard(kboScoreboard('2026.11.03', home: 'UNKNOWN'), kbo),
        isEmpty);
  });
  test('ABL rejects foreign teams, TBD starts and cancelled games', () {
    final game = parseAblScoreboard(ablSchedule(), abl).single;
    expect(game.home.id, 'abl:1');
    expect(game.start, DateTime.utc(2026, 11, 19, 8, 30));
    expect(parseAblScoreboard(ablSchedule(tbd: true), abl), isEmpty);
    expect(parseAblScoreboard(ablSchedule(league: 103), abl), isEmpty);
    expect(parseAblScoreboard(ablSchedule(status: 'Postponed'), abl), isEmpty);
    expect(() => parseAblStandings((bytes(ablStandings(2025)), 2026, false)),
        throwsFormatException);
    expect(ablSeasonYear(DateTime(2027, 1, 10)), 2026);
  });
  test(
      'standings cache is on-demand and preserves last verified table on failed refresh',
      () async {
    var calls = 0, bad = false;
    final service = SportsStandingsService(
        clock: () => DateTime(2026, 11, 2),
        client: MockClient((r) async {
          calls++;
          return http.Response(bad ? 'changed markup' : npbStandings(), 200);
        }));
    addTearDown(service.close);
    expect(calls, 0);
    final data = await service.load(npb);
    expect(data.hasRows, isTrue);
    expect(calls, 1);
    expect(identical(await service.load(npb), data), isTrue);
    bad = true;
    final failed = await service.load(npb, refresh: true);
    expect(failed.failed, isTrue);
    expect(failed.tables.first.rows.first.team.id, 'npb:t');
    expect(calls, 2);
  });
  test(
      'ABL empty preseason retries only previous season and caches labelled result',
      () async {
    final years = <String>[];
    final service = SportsStandingsService(
        clock: () => DateTime(2026, 11, 2),
        client: MockClient((r) async {
          final year = r.url.queryParameters['season']!;
          years.add(year);
          return http.Response(
              year == '2026' ? '"invalid"' : ablStandings(2025), 200);
        }));
    addTearDown(service.close);
    final failed = await service.load(abl);
    expect(failed.failed, isTrue);
    expect(years, ['2026']);
    service.close();
    years.clear();
    final available = SportsStandingsService(
        clock: () => DateTime(2026, 11, 2),
        client: MockClient((r) async {
          final year = r.url.queryParameters['season']!;
          years.add(year);
          return http.Response(
              year == '2026' ? '{"records":[]}' : ablStandings(2025), 200);
        }));
    addTearDown(available.close);
    final data = await available.load(abl);
    expect(data.previousSeason, isTrue);
    expect(data.season, '2025–2026');
    expect(data.tables.single.rows.length, 4);
    await available.load(abl);
    expect(years, ['2026', '2025']);
  });
  test('regional score responses stop at the bounded payload limit', () async {
    var chunksRead = 0;
    final service =
        SportsService.withClient(MockClient.streaming((request, body) async {
      Stream<List<int>> chunks() async* {
        for (var i = 0; i < 8; i++) {
          chunksRead++;
          yield List<int>.filled(512 * 1024, 32);
        }
      }

      return http.StreamedResponse(chunks(), 200);
    }), clock: () => DateTime(2026, 11, 2));
    expect(await service.gamesForDay([npb], DateTime(2026, 11, 2)), isEmpty);
    expect(chunksRead, 5);
  });
  test('NPB monthly and ABL season snapshots deduplicate adjacent-day requests',
      () async {
    for (final league in [npb, abl]) {
      var calls = 0;
      final service = SportsService.withClient(MockClient((r) async {
        calls++;
        return http.Response(league == npb ? npbSchedule() : ablSchedule(), 200,
            headers: {'content-type': 'text/html; charset=utf-8'});
      }), clock: () => DateTime(2026, 11, 2));
      final day =
          league == npb ? DateTime(2026, 10, 15) : DateTime(2026, 11, 19);
      await service.gamesForDay([league], day);
      expect(calls, 1);
      await service.gamesForDay([league], day);
      expect(calls, 1);
    }
  });
}
