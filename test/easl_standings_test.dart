import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nox_iptv/models/sports.dart';
import 'package:nox_iptv/services/easl_standings.dart';
import 'package:nox_iptv/services/sports_standings_service.dart';

List<Map<String, Object?>> rows() => [
      for (var i = 0; i < 12; i++)
        {
          'position': i % 4 + 1,
          'team': {
            'id': '00000000-0000-0000-0000-${i.toString().padLeft(12, '0')}',
            'name': 'Team $i',
            'code': 'T$i',
            'logo': 'https://example.com/$i.png'
          },
          'pool': {'name': 'Group ${String.fromCharCode(65 + i ~/ 4)}'},
          'stats': {
            'gamePlayed': 1,
            'wins': 1,
            'losses': 0,
            'winPercentage': 1,
            'pointDifference': 15,
            'pointsFor': 98,
            'pointsAgainst': 83
          },
        }
    ];
Uint8List bytes(Object value) =>
    Uint8List.fromList(utf8.encode(jsonEncode(value)));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('EASL retains supplied group ranks, records and schedule UUIDs', () {
    final result = parseEaslStandings(bytes(rows().reversed.toList()));
    expect(result.tables.map((t) => t.name), ['Group A', 'Group B', 'Group C']);
    expect(result.tables.every((t) => t.rows.length == 4), isTrue);
    final first = result.tables.first.rows.first;
    expect(first.team.id, 'easl:00000000-0000-0000-0000-000000000000');
    expect(first.position, 1);
    expect(first.stats['winPercent'], '1.000');
    expect(first.stats['pointDifferential'], '15');
    expect(first.team.logoUrl, 'https://example.com/0.png');
    expect(result.sourceName, 'EASL');
    expect(result.season, isNull);
  });
  test('EASL rejects malformed stats, duplicate teams and duplicate ranks', () {
    for (final value in [
      <Object>[],
      [rows().first, rows().first],
      [
        rows().first,
        {...rows()[1], 'position': 1}
      ],
      [
        {
          ...rows().first,
          'stats': {...(rows().first['stats'] as Map), 'wins': -1}
        }
      ],
      [
        {
          ...rows().first,
          'stats': {...(rows().first['stats'] as Map), 'winPercentage': 2}
        }
      ],
    ]) {
      expect(() => parseEaslStandings(bytes(value)), throwsFormatException);
    }
  });
  test(
      'EASL only requests its small feed on demand and retains cache on failure',
      () async {
    var calls = 0, fail = false;
    final service = SportsStandingsService(client: MockClient((request) async {
      calls++;
      expect(request.url.toString(),
          'https://easl.joshricha.com/api/v1/standings');
      return http.Response.bytes(fail ? [] : bytes(rows()), fail ? 503 : 200);
    }));
    addTearDown(service.close);
    final league = sportsLeagueById('basketball.easl')!;
    expect(calls, 0);
    final result = await service.load(league);
    expect(result.tables.length, 3);
    expect(calls, 1);
    expect(identical(await service.load(league), result), isTrue);
    expect(calls, 1);
    fail = true;
    final cached = await service.load(league, refresh: true);
    expect(cached.failed, isTrue);
    expect(cached.tables, result.tables);
    expect(cached.sourceName, 'EASL');
  });
}
