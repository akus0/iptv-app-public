import 'dart:convert';
import 'package:nox_iptv/models/channel.dart';
import 'package:nox_iptv/models/epg_program.dart';
import 'package:nox_iptv/services/epg_service.dart';
import 'package:nox_iptv/services/sports_channel_matcher.dart';
import 'package:nox_iptv/services/sports_match_inputs.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:nox_iptv/models/sports.dart';
import 'package:nox_iptv/services/sports_service.dart';
import 'package:nox_iptv/services/storage_service.dart';

Map<String, Object> event(String id, String league, String state) => {
      'id': id,
      'date': DateTime.now().toUtc().toIso8601String(),
      'links': [
        {'href': 'https://www.espn.com/rugby/match/_/gameId/$id/league/$league'}
      ],
      'competitions': [
        {
          'status': {
            'type': {'state': state, 'shortDetail': 'Half time'}
          },
          'competitors': [
            {
              'homeAway': 'home',
              'score': '17',
              'team': {
                'id': '1',
                'displayName': 'Leinster',
                'shortDisplayName': 'Leinster',
                'abbreviation': 'LEI'
              }
            },
            {
              'homeAway': 'away',
              'score': '10',
              'team': {
                'id': '2',
                'displayName': 'Munster',
                'shortDisplayName': 'Munster',
                'abbreviation': 'MUN'
              }
            },
          ]
        }
      ]
    };

class _Guide extends EpgService {
  _Guide(super.storage, this.rows);
  final Map<String, EpgProgram> rows;
  @override
  EpgProgram? getCurrentProgram(String id) => rows[id];
  @override
  EpgProgram? getNextProgram(String id) => null;
  @override
  Future<List<EpgProgram>> findProgrammesByTitle(
          DateTime a, DateTime b, List<String> terms, {List<String>? channelIds}) async =>
      rows.values.toList();
  @override
  Future<List<EpgProgram>> findSportsProgrammesForChannels(
          List<String> ids, DateTime a, DateTime b) async =>
      rows.values.toList();
}

class _Picks implements SportsMatchPicks {
  @override
  String? channelIdFor(SportsGame game) => null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('automatic rugby coverage is available after upgrade and can be hidden',
      () async {
    SharedPreferences.setMockInitialValues({});
    final storage = StorageService();
    await storage.init();
    await storage.setSportsLeagues(['mlb', 'guide.rugby-nrl']);
    expect(
        savedSportsLeagues(storage).map((l) => l.id), contains('rugby.live'));
    expect(
        savedSportsLeagues(storage).any((l) => l.id.startsWith('guide.rugby')),
        false);
    await storage.setHiddenGuideLeagues(['rugby.live']);
    expect(savedSportsLeagues(storage).map((l) => l.id),
        isNot(contains('rugby.live')));
  });
  test('aggregate keeps competition identity, real teams and scores', () {
    final games = parseEspnScoreboard((
      jsonEncode({
        'events': [event('live', '270557', 'in')]
      }),
      kLiveRugbyLeague
    ));
    expect(games.single.league.id, 'rugby.270557');
    expect(games.single.home.name, 'Leinster');
    expect(games.single.home.score, '17');
    expect(games.single.away.score, '10');
    expect(games.single.isGuideEvent, false);
    expect(matchesSportsLeague(games.single.league, 'rugby.live'), true);
    expect(matchesSportsLeague(sportsLeagueById('nba')!, 'rugby.live'), false);
  });
  test(
      'live rugby fixture confirms the team-specific guide before generic rugby channels',
      () async {
    SharedPreferences.setMockInitialValues({});
    final storage = StorageService();
    await storage.init();
    final now = DateTime.now().toUtc();
    EpgProgram programme(String id, String title) => EpgProgram(
        channelId: id,
        title: title,
        start: now.subtract(const Duration(minutes: 30)),
        stop: now.add(const Duration(minutes: 90)),
        isLive: true);
    final guide = _Guide(storage, {
      'right': programme('right', 'Live URC: Leinster v Munster'),
      'generic': programme('generic', 'Rugby coverage'),
      'wrong': programme('wrong', 'Live URC: Bulls v Ulster'),
    });
    final matcher = SportsChannelMatcher(guide);
    addTearDown(() {
      matcher.dispose();
      guide.dispose();
    });
    await matcher.prepare([
      for (final id in guide.rows.keys)
        Channel(
            id: 'test::$id',
            rawId: id,
            playlistId: 'test',
            name: 'Rugby Sports $id',
            group: 'Sports',
            url: 'https://example.invalid/no-stream')
    ]);
    final game = parseEspnScoreboard((
      jsonEncode({
        'events': [event('live', '270557', 'in')]
      }),
      kLiveRugbyLeague
    )).single;
    final results = await matcher.matchDay([game], _Picks());
    final matches = results[SportsChannelPicks.eventKey(game)]!;
    expect(matches.first.channel.rawId, 'right');
    expect(matches.first.isConfident, true);
  });

  test('one shared feed per date, live-only display, cache and ended removal',
      () async {
    var requests = 0, ended = false;
    final service = SportsService.withClient(MockClient((r) async {
      requests++;
      expect(r.url.path, endsWith('/rugby/all/scoreboard'));
      return http.Response(
          jsonEncode({
            'events': [
              event('live', '270557', ended ? 'post' : 'in'),
              event('soon', '267979', 'pre'),
              event('old', '270559', 'post'),
            ]
          }),
          200);
    }));
    final selected = [
      kLiveRugbyLeague,
      ...kSportsLeagueBank.where((l) => l.espnPath.startsWith('rugby/'))
    ];
    final day = DateTime.now();
    final result = await Future.wait([
      service.gamesForDay(selected, day),
      service.gamesForDay(selected, day)
    ]);
    expect(requests, 3); // timezone neighbours, not three requests per league
    expect(result.first.map((g) => g.id), ['live']);
    expect(await service.gamesForDay(selected, day), hasLength(1));
    expect(requests, 3);
    ended = true;
    expect(
        await service.gamesForDay(selected, day, forceRefresh: true), isEmpty);
    expect(service.cachedGamesForDay(selected, day), isEmpty);
  });
}
