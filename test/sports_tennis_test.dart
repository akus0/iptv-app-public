import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nox_iptv/models/sports.dart';
import 'package:nox_iptv/services/sports_service.dart';
import 'package:nox_iptv/utils/sports_time_filter.dart';
import 'package:nox_iptv/utils/sports_fixture_presentation.dart';

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

String _board(Map<String, dynamic> match) => jsonEncode({
      'events': [
        {
          'id': 't1',
          'name': 'Test Open',
          'groupings': [
            {
              'grouping': {'displayName': "Men's Singles"},
              'competitions': [match],
            }
          ],
        }
      ],
    });

Map<String, dynamic> _interruptedMatch(String name, String state,
        {bool completed = false}) =>
    _match('interrupted', 'Round 2', state, [
      _player('Novak Djokovic', [6, 3]),
      _player('Opponent', [4, 2]),
    ])
      ..['status'] = {
        'type': {
          'name': name,
          'state': state,
          'completed': completed,
          'shortDetail': '',
        }
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
              'media': {'displayName': 'Eurosport 2'},
              'region': 'gb',
              'lang': 'en',
              'type': {'shortName': 'TV'},
              'market': {'type': 'National', 'name': 'National'}
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
    final broadcast =
        live.scoreboardBroadcasts.firstWhere((b) => b.name == 'Eurosport 2');
    expect(broadcast.country, 'United Kingdom');
    expect(broadcast.medium, 'TV');
    expect(broadcast.language, 'en');
    expect(live.withOnlineBroadcasts([]).scoreboardBroadcasts,
        live.scoreboardBroadcasts);
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

  for (final status in {
    'STATUS_SUSPENDED': 'Suspended',
    'STATUS_INTERRUPTED': 'Interrupted',
    'STATUS_MEDICAL_TIMEOUT': 'Medical timeout',
    'STATUS_TIMEOUT': 'Timeout',
    'STATUS_RAIN_DELAY': 'Rain delay',
  }.entries) {
    for (final state in ['pre', 'in', 'post']) {
      test('${status.key}/$state remains an unfinished visible match', () {
        final game = parseEspnScoreboard((
          _board(_interruptedMatch(status.key, state)),
          sportsLeagueById('tennis.atp')!,
        )).single;
        final now = game.start.add(const Duration(hours: 3));
        expect(game.isLive, isTrue);
        expect(game.statusText, status.value);
        expect(SportsTimeFilter.live.accepts(game, now), isTrue);
        expect(SportsTimeFilter.liveAndSoon.accepts(game, now), isTrue);
        expect(SportsTimeFilter.soon.accepts(game, now), isFalse);
        expect(sportsFixtureCompleted(game), isFalse);
        expect(game.home.score, '1',
            reason: 'An interrupted set must not count as a completed set');
      });
    }
  }

  test('completed and cancelled matches do not become live', () {
    for (final name in [
      'STATUS_FINAL',
      'STATUS_RETIRED',
      'STATUS_WALKOVER',
      'STATUS_CANCELED',
      'STATUS_POSTPONED',
    ]) {
      final game = parseEspnScoreboard((
        _board(_interruptedMatch(name, 'post',
            completed:
                !{'STATUS_CANCELED', 'STATUS_POSTPONED'}.contains(name))),
        sportsLeagueById('tennis.atp')!,
      )).single;
      expect(game.isLive, isFalse, reason: name);
    }
    final completed = parseEspnScoreboard((
      _board(_interruptedMatch('STATUS_SUSPENDED', 'post', completed: true)),
      sportsLeagueById('tennis.atp')!,
    )).single;
    expect(completed.state, GameState.post,
        reason: 'Explicit completion takes precedence over interruption');
  });

  test('suspended tennis survives midnight, cached reads and resumption',
      () async {
    final now = DateTime(2026, 11, 4, 1);
    final league = sportsLeagueById('tennis.atp')!;
    var status = 'STATUS_SUSPENDED', state = 'post', calls = 0;
    final service = SportsService.withClient(MockClient((_) async {
      calls++;
      final match = _interruptedMatch(status, state,
          completed: status == 'STATUS_FINAL')
        ..['date'] =
            now.subtract(const Duration(hours: 2)).toUtc().toIso8601String();
      return http.Response(_board(match), 200);
    }), clock: () => now);
    final games = await service.gamesForDay([league], now);
    expect(games.single.isLive, isTrue);
    final initialCalls = calls;
    expect(
        (await service.gamesForDay([league], now)).single.id, games.single.id);
    expect(calls, initialCalls,
        reason: 'Visibility needs no additional requests');
    status = 'STATUS_IN_PROGRESS';
    state = 'in';
    expect(
        (await service.gamesForDay([league], now, forceRefresh: true))
            .single
            .isLive,
        isTrue);
    status = 'STATUS_FINAL';
    state = 'post';
    expect(
        await service.gamesForDay([league], now, forceRefresh: true), isEmpty,
        reason: 'Yesterday’s completed match no longer carries into today');
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
