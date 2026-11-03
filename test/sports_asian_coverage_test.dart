import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nox_iptv/models/sports.dart';
import 'package:nox_iptv/models/sports_progress.dart';
import 'package:nox_iptv/services/k_league_scoreboard.dart';
import 'package:nox_iptv/services/easl_scoreboard.dart';
import 'package:nox_iptv/services/sports_service.dart';
import 'package:nox_iptv/utils/extended_sports.dart';

Map<String, Object?> fixture(
        {String status = '',
        String date = '2026.10.31',
        String time = '14:00',
        int id = 201,
        int league = 1}) =>
    {
      'leagueId': league,
      'gameId': id,
      'gameDate': date,
      'gameTime': time,
      'gameStatus': status,
      'endYn': status == 'FE' ? 'Y' : 'N',
      'homeTeam': 'K05',
      'homeTeamName': 'JEONBUK',
      'awayTeam': 'K10',
      'awayTeamName': 'DAEJEON',
      'homeGoal': 0,
      'awayGoal': 1,
      'broadcastName': 'JTBC SPORTS//COUPANGPLAY',
    };
String board(List<Map<String, Object?>> rows) => jsonEncode({
      'resultCode': '200',
      'data': {'scheduleList': rows}
    });

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final league = sportsLeagueById('kor.1')!;

  Map<String, Object?> easl(
          {String status = 'SCHEDULED',
          String id = 'match',
          String stamp = '2026-10-28T11:10:00'}) =>
      {
        'fixtureId': id,
        'status': status,
        'startTimeUTC': stamp,
        'competitors': [
          {
            'isHome': true,
            'teamId': 'pilots',
            'nameFullLatin': 'Taoyuan Pauian Pilots',
            'score': '0'
          },
          {
            'isHome': false,
            'teamId': 'kings',
            'nameFullLocal': 'Ryukyu Golden Kings',
            'nameFullLatin': '琉球ゴールデンキングス',
            'score': '2'
          },
        ],
      };

  test(
      'EASL parses explicit match states and UTC without inventing draft games',
      () {
    final league = sportsLeagueById('basketball.easl')!;
    final rows = [
      easl(),
      easl(status: 'IN_PROGRESS', id: 'live'),
      easl(status: 'CONFIRMED', id: 'finished'),
      easl(status: 'DRAFT', id: 'draft'),
      easl(id: 'undated', stamp: ''),
      easl(),
      easl(status: 'CANCELLED', id: 'cancelled')
    ];
    final games = parseEaslScoreboard(jsonEncode(rows), league);
    expect(games, hasLength(3));
    expect(games.first.start, DateTime.utc(2026, 10, 28, 11, 10));
    expect(games.first.home.score, isNull);
    expect(games[1].state, GameState.live);
    expect(games[1].home.score, '0');
    expect(games.last.state, GameState.post);
    expect(games.first.away.name, 'Ryukyu Golden Kings');
  });

  test('EASL shares one season fetch and excludes old unfinished fixtures',
      () async {
    var calls = 0;
    final league = sportsLeagueById('basketball.easl')!;
    final day = DateTime(2026, 10, 28);
    final service = SportsService.withClient(MockClient((request) async {
      calls++;
      expect(request.url.host, 'easl.joshricha.com');
      expect(request.method, 'GET');
      return http.Response(
          jsonEncode([
            easl(),
            easl(
                id: 'stale',
                status: 'IN_PROGRESS',
                stamp: '2026-10-01T10:00:00')
          ]),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'});
    }), clock: () => day);
    expect(await service.gamesForDay([league], day), hasLength(1));
    expect(await service.gamesForDay([league], DateTime(2026, 11, 1)), isEmpty);
    expect(calls, 1);
  });

  test('Korean fixtures use explicit state, KST and meaningful scores', () {
    final games = parseKLeagueScoreboard(
        board([
          fixture(),
          fixture(status: '1S 25', id: 202),
          fixture(status: '1E', id: 203),
          fixture(status: 'FE', id: 204),
          fixture(status: 'POSTPONED', id: 205),
          fixture(date: '2026.02.31', id: 206),
          fixture(time: 'TBC', id: 207),
          fixture(league: 2, id: 208),
          fixture(),
        ]),
        league);
    expect(games.length, 4);
    expect(games.first.start, DateTime.utc(2026, 10, 31, 5));
    expect(games.first.state, GameState.pre);
    expect(games.first.home.score, isNull);
    expect(games[1].state, GameState.live);
    expect(games[1].home.score, '0');
    expect(games[1].away.score, '1');
    expect(games[2].statusText, 'Half-time');
    expect(games.last.state, GameState.post);
    expect(games.first.source, 'K League');
    expect(games.first.broadcasts, ['JTBC SPORTS', 'COUPANGPLAY']);
    expect(
        parseKLeagueScoreboard(
                board([fixture(date: '2026.11.01', time: '00:30')]), league)
            .single
            .start,
        DateTime.utc(2026, 10, 31, 15, 30));
    expect(() => parseKLeagueScoreboard('{"resultCode":"500"}', league),
        throwsFormatException);
  });

  test('a shared monthly request serves concurrent days and warm returns',
      () async {
    var calls = 0;
    final gate = Completer<void>();
    final service = SportsService.withClient(MockClient((request) async {
      calls++;
      expect(request.method, 'POST');
      expect(request.url.host, 'www.kleague.com');
      expect(jsonDecode(request.body)['lang'], 'en');
      expect(request.headers['Accept-Language'], 'en');
      await gate.future;
      return http.Response(board([fixture(date: '2026.10.20')]), 200);
    }), clock: () => DateTime(2026, 10, 20));
    final progress = <SportsWorkProgress>[];
    final a = service
        .gamesForDay([league], DateTime(2026, 10, 20), onStatus: progress.add);
    final b = service.gamesForDay([league], DateTime(2026, 10, 21));
    gate.complete();
    expect(await a, hasLength(1));
    expect(await b, isEmpty);
    expect(calls, 1);
    expect(progress.last.total, 1);
    expect(await service.gamesForDay([league], DateTime(2026, 10, 20)),
        hasLength(1));
    expect(calls, 1);
    expect(
        service.cachedGamesForDay([league], DateTime(2026, 10, 21)), isEmpty);
  });

  test('month boundaries fetch both months once and live data expires',
      () async {
    var calls = 0;
    var clock = DateTime(2026, 10, 31);
    final months = <String>[];
    final service = SportsService.withClient(MockClient((request) async {
      calls++;
      final month = jsonDecode(request.body)['month'] as String;
      months.add(month);
      return http.Response(
          board(month == '10' ? [fixture(status: '2S 12')] : []), 200);
    }), clock: () => clock);
    final initial = await service.gamesForDay([league], clock);
    expect(initial, hasLength(1));
    expect(months, unorderedEquals(['10', '11']));
    clock = clock.add(const Duration(seconds: 51));
    await service.gamesForDay([league], DateTime(2026, 10, 31));
    expect(calls, 3);
    expect(months.last, '10');
  });

  test('failed refresh preserves fixtures, backs off and scopes rate limits',
      () async {
    var clock = DateTime(2026, 10, 20);
    var calls = 0;
    var fail = false;
    final service = SportsService.withClient(MockClient((request) async {
      calls++;
      if (request.url.host == 'www.kleague.com') {
        return fail
            ? http.Response('Busy', 429, headers: {'retry-after': '120'})
            : http.Response(
                board([fixture(date: '2026.10.20', status: '1S 2')]), 200);
      }
      return http.Response('{"events":[]}', 200);
    }), clock: () => clock);
    await service.gamesForDay([league], clock);
    fail = true;
    clock = clock.add(const Duration(seconds: 51));
    expect(await service.gamesForDay([league], clock), hasLength(1));
    expect(service.issuesForDay([league], clock), hasLength(1));
    expect(service.errorForDay([league], clock), contains('1 of 1'));
    await service.gamesForDay([league], clock);
    expect(calls, 2);
    await service.gamesForDay([sportsLeagueById('afc.cup')!], clock);
    expect(calls, 5, reason: 'K League rate limits must not block ESPN');
    expect(service.errorForDay([sportsLeagueById('afc.cup')!], clock), isNull);
  });

  test('WTT branded competitions are table tennis, not incidental initials',
      () {
    expect(extendedGuideSport('WTT Champions Montpellier 2026', ''),
        'table-tennis');
    expect(extendedGuideSport('WTT Star Contender', ''), 'table-tennis');
    expect(extendedGuideSport('WTT business news', ''), isNull);
    expect(extendedGuideSport('PBA Bowling', ''), 'bowling');
  });

  test('an unreachable score provider does not suppress another provider',
      () async {
    final day = DateTime(2026, 10, 20);
    var koreanRequests = 0;
    final service = SportsService.withClient(MockClient((request) async {
      if (request.url.host != 'www.kleague.com') {
        throw http.ClientException('unreachable');
      }
      koreanRequests++;
      return http.Response(board([fixture(date: '2026.10.20')]), 200);
    }), clock: () => day);
    final games = await service.gamesForDay([
      ...kSportsLeagues.where((l) => l.source == 'ESPN').take(12),
      league,
    ], day);
    expect(koreanRequests, 1);
    expect(games.where((g) => g.league.id == league.id), hasLength(1));
    expect(service.errorForDay([league], day), isNull);
  });
}
