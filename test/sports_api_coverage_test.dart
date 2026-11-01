import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:nox_iptv/models/channel.dart';
import 'package:nox_iptv/models/epg_program.dart';
import 'package:nox_iptv/models/sports.dart';
import 'package:nox_iptv/services/epg_service.dart';
import 'package:nox_iptv/services/sports_channel_matcher.dart';
import 'package:nox_iptv/services/sports_service.dart';
import 'package:nox_iptv/services/storage_service.dart';

const _ids = [
  'sco.2',
  'usa.w.usl.1',
  'fifa.wworld.u17',
  'mex.w.1',
  'col.1',
  'per.1',
  'conmebol.sudamericana'
];
final _now = DateTime.utc(2026, 10, 30, 19, 40);

class _Guide extends EpgService {
  _Guide(super.storage);
  final programmes = <EpgProgram>[];
  @override
  EpgProgram? getCurrentProgram(String id) =>
      programmes.where((p) => p.channelId == id).firstOrNull;
  @override
  EpgProgram? getNextProgram(String id) => null;
  @override
  Future<List<EpgProgram>> findProgrammesByTitle(
          DateTime from, DateTime to, List<String> terms,
          {List<String>? channelIds}) async =>
      programmes;
  @override
  Future<List<EpgProgram>> findSportsProgrammesForChannels(
          List<String> ids, DateTime from, DateTime to) async =>
      programmes.where((p) => ids.contains(p.channelId)).toList();
}

SportsGame _game(String league, String home, String away) => SportsGame(
    id: '$league:$home:$away',
    league: sportsLeagueById(league)!,
    start: _now.subtract(const Duration(minutes: 10)),
    state: GameState.live,
    statusText: 'Live',
    home: SportsTeam(
        id: 'home',
        name: home,
        shortName: home.replaceAll(' U17', ''),
        abbreviation: ''),
    away: SportsTeam(
        id: 'away',
        name: away,
        shortName: away.replaceAll(' U17', ''),
        abbreviation: ''));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
      'added score feeds share bounded loading, parse scores and reuse their cache',
      () async {
    var calls = 0, active = 0, peak = 0;
    final service = SportsService.withClient(MockClient((request) async {
      calls++;
      active++;
      if (active > peak) peak = active;
      await Future<void>.delayed(const Duration(milliseconds: 2));
      active--;
      final id = request.url.path.split('/').reversed.skip(1).first;
      expect(_ids, contains(id));
      expect(request.url.queryParameters['dates'], matches(r'^\d{8}$'));
      return http.Response(
          jsonEncode({
            'events': [
              {
                'id': id,
                'date': _now.toIso8601String(),
                'status': {
                  'type': {'state': 'in', 'shortDetail': '65′'}
                },
                'competitions': [
                  {
                    'broadcasts': [
                      {
                        'names': ['Sports Network']
                      }
                    ],
                    'competitors': [
                      {
                        'homeAway': 'home',
                        'score': '2',
                        'team': {'id': 'h', 'displayName': 'Home Club'}
                      },
                      {
                        'homeAway': 'away',
                        'score': '1',
                        'team': {'id': 'a', 'displayName': 'Away Club'}
                      }
                    ]
                  }
                ]
              }
            ]
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'});
    }), clock: () => _now);
    final leagues = _ids.map((id) => sportsLeagueById(id)!).toList();
    final games = await service.gamesForDay(leagues, _now.toLocal());
    expect(games, hasLength(_ids.length));
    expect(
        games.every(
            (g) => g.isLive && g.home.score == '2' && g.away.score == '1'),
        isTrue);
    expect(games.every((g) => g.broadcasts.single == 'Sports Network'), isTrue);
    expect(peak, lessThanOrEqualTo(6));
    expect(calls, _ids.length * 3);
    await service.gamesForDay(leagues, _now.toLocal());
    expect(calls, _ids.length * 3,
        reason: 'Warm reopening must not fetch again');
  });

  for (final background in [false, true]) {
    test(
        'new competitions confirm the fixture, not another programme ($background)',
        () async {
      SharedPreferences.setMockInitialValues({});
      final storage = StorageService();
      await storage.init();
      final guide = _Guide(storage);
      addTearDown(guide.dispose);
      final matcher = background
          ? SportsChannelMatcher.background(guide, clock: () => _now)
          : SportsChannelMatcher(guide, clock: () => _now);
      addTearDown(matcher.dispose);
      final fixtures = [
        (
          _game('sco.2', 'Stenhousemuir', 'Livingston'),
          'Sportscene: Championship Live',
          'Live Championship action as Stenhousemuir host Livingston.'
        ),
        (
          _game('usa.w.usl.1', 'Carolina Ascent FC', 'Lexington SC'),
          'USL Super League Soccer: Lexington SC at Carolina Ascent FC LIVE',
          ''
        ),
        (
          _game('fifa.wworld.u17', 'Argentina U17', 'Ghana U17'),
          'FIFA U-17 Women’s World Cup: Argentina U17 vs Ghana U17 LIVE',
          ''
        ),
        (
          _game('mex.w.1', 'Tigres UANL', 'Monterrey'),
          'Liga MX Femenil: Tigres UANL vs Monterrey LIVE',
          ''
        ),
        (
          _game('col.1', 'Independiente Medellín', 'Alianza FC'),
          'Fútbol Colombiano Primera División: Independiente Medellín vs Alianza FC LIVE',
          ''
        ),
        (
          _game('per.1', 'Los Chankas', 'Alianza Lima'),
          'Peruvian Liga 1: Los Chankas vs Alianza Lima LIVE',
          ''
        ),
        (
          _game(
              'conmebol.sudamericana', 'Montevideo City Torque', 'Atlético-MG'),
          'Copa Sudamericana: Montevideo City Torque vs Atlético-MG LIVE',
          ''
        ),
        (
          _game('fifa.wworld.u17', 'North Korea U17', 'Morocco U17'),
          'FIFA U-17 Women’s World Cup: Korea DPR U17 vs Morocco U17 LIVE',
          ''
        ),
        (
          _game('fifa.friendly.w', 'Argentina', 'Ghana'),
          'Women’s Soccer: Argentina vs Ghana LIVE',
          ''
        ),
      ];
      final titles = [
        for (final f in fixtures) (f.$2, f.$3),
        ('Women’s U20 Soccer: Argentina U20 vs Ghana U20 LIVE', ''),
        (
          'FIFA U-17 Women’s World Cup: Korea Republic U17 vs Morocco U17 LIVE',
          ''
        ),
        ('Men’s U17 Soccer: Argentina U17 vs Ghana U17 LIVE', ''),
        ('Liga MX Men’s Soccer: Tigres UANL vs Monterrey LIVE', ''),
        ('Scottish Championship: Ayr United vs Raith Rovers LIVE', '')
      ];
      final channels = <Channel>[];
      for (var i = 0; i < titles.length; i++) {
        final id = '$i';
        channels.add(Channel(
            id: 'fixture::$id',
            rawId: id,
            playlistId: 'fixture',
            name: 'Sports Channel $i',
            group: 'Sports',
            url: 'https://example.invalid/unused',
            epgIdOverride: id));
        guide.programmes.add(EpgProgram(
            channelId: id,
            title: titles[i].$1,
            description: titles[i].$2,
            start: _now.subtract(const Duration(minutes: 20)),
            stop: _now.add(const Duration(hours: 2)),
            isLive: true));
      }
      await matcher.prepare(channels);
      final matches = await matcher.matchDay(
          [for (final f in fixtures) f.$1], SportsChannelPicks.load(storage));
      for (var i = 0; i < fixtures.length; i++) {
        final game = fixtures[i].$1;
        final confident = matches[SportsChannelPicks.eventKey(game)]!
            .where((m) => m.isConfident)
            .map((m) => m.channel.rawId)
            .toList();
        expect(confident, ['$i'], reason: game.league.id);
      }
    });
  }
}
