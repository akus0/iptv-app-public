import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nox_iptv/models/sports.dart';
import 'package:nox_iptv/services/sports_service.dart';

/// ESPN's tennis scoreboard: one event per tournament, `groupings` per draw,
/// every match of the tournament inside (shape taken from tennis/atp).
Map<String, dynamic> _player(String name, List<num> sets, {bool? winner}) => {
      'homeAway': 'home',
      'athlete': {'id': name, 'displayName': name, 'shortName': name},
      'linescores': [
        for (final s in sets) {'value': s}
      ],
      if (winner != null) 'winner': winner,
    };

Map<String, dynamic> _match(String id, String round, String state,
        List<Map<String, dynamic>> players) =>
    {
      'id': id,
      'date': '2026-10-19T12:00Z',
      'round': {'displayName': round},
      'venue': {'fullName': 'Brussels, Belgium', 'court': 'Court 2'},
      'status': {
        'type': {'state': state, 'shortDetail': state == 'in' ? '2nd Set' : ''}
      },
      'competitors': players,
    };

void main() {
  test('tennis: main-draw singles matches become cards', () {
    final league = sportsLeagueById('tennis.atp')!;
    expect(league.kind, SportsKind.tennis);
    final body = jsonEncode({
      'events': [
        {
          'id': 't1',
          'name': 'European Open',
          'shortName': 'Antwerp',
          'broadcasts': [
            {
              'names': ['Tennis Channel']
            },
            {
              'media': {'name': 'Sky Sports Tennis'}
            },
          ],
          'geoBroadcasts': [
            {
              'media': {'displayName': 'Eurosport 2'}
            }
          ],
          'groupings': [
            {
              'grouping': {'displayName': "Men's Singles"},
              'competitions': [
                _match('m1', 'Round 2', 'in', [
                  _player('Ann Alpha', [6, 3]),
                  _player('Bob Beta', [4, 2]),
                ]),
                _match('m2', 'Final Qualifying', 'post', [
                  _player('Cy Q', [6, 6], winner: true),
                  _player('Di Q', [1, 1], winner: false),
                ]),
                _match('m3', 'Round 1', 'post', [
                  _player('Ed Echo', [6, 4, 6], winner: true),
                  _player('Flo Fox', [3, 6, 2], winner: false),
                ]),
              ],
            },
            {
              'grouping': {'displayName': "Men's Doubles"},
              'competitions': [
                _match('d1', 'Round 1', 'in', [
                  {'homeAway': 'home', 'linescores': []},
                  {'homeAway': 'away', 'linescores': []},
                ]),
              ],
            },
          ],
        }
      ]
    });
    final games = parseEspnScoreboard((body, league));
    expect(games.map((g) => g.id), ['m1', 'm3']); // no qualifying, doubles
    final live = games.first;
    expect(live.state, GameState.live);
    expect(live.event!.title, 'European Open');
    expect(live.event!.matchingNames, ['Antwerp', 'Brussels']);
    expect(live.event!.court, 'Court 2');
    expect(live.broadcasts,
        ['Tennis Channel', 'Sky Sports Tennis', 'Eurosport 2']);
    expect(live.event!.session, 'Round 2');
    expect(live.title, contains('vs'));
    // Live: only finished sets count (first set 6-4 won, second ongoing).
    expect({live.home.score, live.away.score}, {'1', '0'});
    final done = games.last;
    expect({done.home.score, done.away.score}, {'2', '1'});
  });

  const snapshot = String.fromEnvironment('TENNIS_ESPN_FILE');
  test('saved current ESPN tennis includes usable city and court metadata', () {
    final games = parseEspnScoreboard(
        (File(snapshot).readAsStringSync(), sportsLeagueById('tennis.atp')!));
    expect(games.length, greaterThan(10));
    final brussels = games
        .where((g) => g.event!.venue?.contains('Brussels') == true)
        .toList();
    expect(brussels, isNotEmpty);
    expect(brussels.every((g) => g.event!.matchingNames.contains('Brussels')),
        true);
    expect(brussels.any((g) => (g.event!.court ?? '').isNotEmpty), true);
  }, skip: snapshot.isEmpty ? 'Optional saved ESPN scoreboard' : false);

  test('NCAA soccer leagues are in the bank', () {
    for (final id in ['usa.ncaa.m.1', 'usa.ncaa.w.1']) {
      final l = sportsLeagueById(id)!;
      expect(l.soccer, isTrue);
      expect(kSportsLeagueRegions, contains(l.region));
    }
    expect(kSportsLeagueRegions, contains('Tennis'));
  });
}
