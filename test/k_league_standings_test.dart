import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nox_iptv/models/sports.dart';
import 'package:nox_iptv/services/k_league_standings.dart';
import 'package:nox_iptv/services/sports_standings_service.dart';

Map<String, Object?> entry(String id, int rank,
        {int league = 1, int? phase, int points = 40}) =>
    {
      'teamId': id,
      'teamName': 'Team $id',
      'year': 2026,
      'leagueId': league,
      'rank': rank,
      'gainPoint': points,
      'assignGameType': phase,
      'gameCount': 30,
      'winCnt': 10,
      'tieCnt': 10,
      'lossCnt': 10,
      'gapCnt': -2,
      'gainGoal': 30,
      'lossGoal': 32,
    };
String response(List<Map<String, Object?>> rows,
        {bool split = false, int year = 2026}) =>
    jsonEncode({
      'resultCode': 200,
      'data': {'year': year, 'isSplitRank': split, 'teamRank': rows}
    });
LeagueStandings parse(String body, {String league = 'kor.1'}) =>
    parseKLeagueStandings((
      Uint8List.fromList(utf8.encode(body)),
      sportsLeagueById(league)!,
      2026
    ));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
      'split phases preserve global ranks and published points without reshuffling',
      () {
    final result = parse(response([
      entry('K09', 1, phase: 23, points: 60),
      entry('K04', 7, phase: 24, points: 65),
      entry('K21', 6, phase: 23, points: 45),
    ], split: true));
    expect(result.tables.map((t) => t.name), ['Final A', 'Final B']);
    expect(result.tables.first.rows.map((r) => r.position), [1, 6]);
    expect(result.tables.last.rows.single.position, 7);
    expect(result.tables.last.rows.single.stats['points'], '65');
    expect(result.tables.first.rows.first.team.id, 'kleague:K09');
    expect(result.tables.first.rows.first.team.logoUrl,
        'https://www.kleague.com/assets/images/emblem/emblem_K09.png');
    expect(result.tables.first.rows.first.stats['pointDifferential'], '-2');
    expect(result.sourceName, 'K League');
    expect(result.season, '2026');
  });
  test('K League2 retains regular-season table and existing schedule IDs', () {
    final result = parse(
        response([entry('K02', 1, league: 2), entry('K29', 2, league: 2)]),
        league: 'kor.2');
    expect(result.tables.single.name, 'K League 2');
    expect(result.tables.single.rows.map((r) => r.team.id),
        ['kleague:K02', 'kleague:K29']);
    expect(result.previousSeason, isFalse);
    expect(result.directory, isFalse);
  });
  test('unknown phases, duplicate identities and mixed seasons fail closed',
      () {
    for (final body in [
      response([entry('K09', 1, phase: 99)], split: true),
      response([entry('K09', 1), entry('K09', 2)]),
      response([entry('K09', 1, league: 2)]),
      response([entry('K09', 1)], year: 2025),
      response([
        {...entry('K09', 1), 'gainPoint': 'unknown'}
      ]),
    ]) {
      expect(() => parse(body), throwsFormatException);
    }
  });
  test('one on-demand English POST is cached and failed refresh retains data',
      () async {
    final requests = <http.Request>[];
    var fail = false;
    final service = SportsStandingsService(
        clock: () => DateTime(2026, 11, 1),
        client: MockClient((r) async {
          requests.add(r);
          return http.Response(
              fail ? '' : response([entry('K09', 1)]), fail ? 503 : 200);
        }));
    addTearDown(service.close);
    expect(requests, isEmpty);
    final league = sportsLeagueById('kor.1')!;
    final data = await service.load(league);
    expect(data.hasRows, isTrue);
    expect(requests, hasLength(1));
    expect(requests.single.method, 'POST');
    expect(requests.single.headers['Accept-Language'], 'en');
    expect(requests.single.url.host, 'www.kleague.com');
    expect(requests.single.url.queryParameters, {
      'leagueId': '1',
      'year': '2026',
      'stadium': 'all',
      'recordType': 'rank',
      'lang': 'en'
    });
    await service.load(league);
    expect(requests, hasLength(1));
    fail = true;
    final stale = await service.load(league, refresh: true);
    expect(stale.failed, isTrue);
    expect(stale.tables.single.rows.single.team.id, 'kleague:K09');
    expect(stale.sourceName, 'K League');
    await service.load(league);
    expect(requests, hasLength(2));
  });
}
