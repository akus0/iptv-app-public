import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:nox_iptv/models/channel.dart';
import 'package:nox_iptv/models/epg_program.dart';
import 'package:nox_iptv/models/sports.dart';
import 'package:nox_iptv/services/epg_service.dart';
import 'package:nox_iptv/services/formula_one_schedule_service.dart';
import 'package:nox_iptv/services/sports_channel_matcher.dart';
import 'package:nox_iptv/services/sports_service.dart';
import 'package:nox_iptv/services/sports_supplement_service.dart';
import 'package:nox_iptv/services/storage_service.dart';
import 'package:nox_iptv/utils/formula_one.dart';
import 'package:nox_iptv/utils/sports_time_filter.dart';

final raceStart = DateTime.utc(2026, 11, 1, 20);
Map<String, dynamic> raceJson() => {
      'season': '2026',
      'round': '19',
      'raceName': 'Mexico City Grand Prix',
      'date': '2026-11-01',
      'time': '20:00:00Z',
      'Circuit': {
        'circuitName': 'Autódromo Hermanos Rodríguez',
        'Location': {'locality': 'Mexico City', 'country': 'Mexico'}
      },
      'FirstPractice': {'date': '2026-10-30', 'time': '18:30:00Z'},
      'SecondPractice': {'date': '2026-10-30', 'time': '22:00:00Z'},
      'ThirdPractice': {'date': '2026-10-31', 'time': '17:30:00Z'},
      'Qualifying': {'date': '2026-10-31', 'time': '21:00:00Z'},
    };
String calendar([Map<String, dynamic>? race]) => jsonEncode({
      'MRData': {
        'RaceTable': {
          'Races': [race ?? raceJson()]
        }
      }
    });
SportsGame game(
        {String session = 'Race',
        GameState state = GameState.pre,
        String title = 'Mexico City Grand Prix',
        DateTime? start,
        String source = 'ESPN'}) =>
    SportsGame(
        id: session,
        league: sportsLeagueById('racing.f1')!,
        start: start ?? raceStart,
        state: state,
        statusText: 'Scheduled',
        source: source,
        home:
            const SportsTeam(id: '', name: '', shortName: '', abbreviation: ''),
        away:
            const SportsTeam(id: '', name: '', shortName: '', abbreviation: ''),
        event: SportsEventInfo(
            title: title, session: session, matchingNames: [title]));
Channel channel(String id, String name, {String group = 'UK| FORMULA 1 PPV'}) =>
    Channel(
        id: id,
        rawId: id,
        playlistId: 'test',
        name: name,
        group: group,
        url: 'https://example.invalid/never-open');

class Guide extends EpgService {
  Guide(super.storage);
  List<EpgProgram> programmes = [];
  @override
  EpgProgram? getCurrentProgram(String id) =>
      programmes.where((p) => p.channelId == id).firstOrNull;
  @override
  Future<List<EpgProgram>> findProgrammesByTitle(
          DateTime from, DateTime to, List<String> terms, {List<String>? channelIds}) async =>
      programmes
          .where((p) =>
              p.stop.isAfter(from) &&
              p.start.isBefore(to) &&
              terms.any((t) => p.title.toLowerCase().contains(t)))
          .toList();
  @override
  Future<List<EpgProgram>> findSportsProgrammesForChannels(
          List<String> ids, DateTime from, DateTime to) async =>
      programmes
          .where((p) =>
              ids.contains(p.channelId) &&
              p.stop.isAfter(from) &&
              p.start.isBefore(to))
          .toList();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('complete normal and sprint calendars; never invent untimed sessions',
      () {
    final rows = parseFormulaOneSchedule(calendar());
    expect(rows, hasLength(5));
    expect(rows.last.start, raceStart);
    expect(rows.every((g) => g.isScheduleOnly), true);
    expect(rows.map((g) => g.event!.session),
        ['Practice 1', 'Practice 2', 'Practice 3', 'Qualifying', 'Race']);
    final sprint = raceJson()
      ..remove('SecondPractice')
      ..remove('ThirdPractice');
    sprint['SprintQualifying'] = {'date': '2026-10-30', 'time': '22:00:00Z'};
    sprint['Sprint'] = {'date': '2026-10-31', 'time': '17:30:00Z'};
    expect(
        parseFormulaOneSchedule(calendar(sprint)).map((g) => g.event!.session),
        containsAll(['Sprint Qualifying', 'Sprint']));
    sprint['Sprint'] = {'date': '2026-10-31'};
    expect(
        parseFormulaOneSchedule(calendar(sprint))
            .any((g) => g.event!.session == 'Sprint'),
        false);
  });
  test(
      'Live includes 30-minute sessions and 90-minute race build-up, without changing state',
      () {
    for (final session in [
      'Practice 1',
      'Practice 2',
      'Practice 3',
      'Qualifying',
      'Sprint Qualifying',
      'Sprint',
      'Race'
    ]) {
      final g = game(session: session);
      final boundary =
          raceStart.subtract(Duration(minutes: session == 'Race' ? 90 : 30));
      expect(
          SportsTimeFilter.live
              .accepts(g, boundary.subtract(const Duration(seconds: 1))),
          false,
          reason: session);
      expect(SportsTimeFilter.live.accepts(g, boundary), true, reason: session);
      expect(g.state, GameState.pre);
    }
    expect(
        isF1BuildUp(game(state: GameState.post),
            raceStart.subtract(const Duration(minutes: 20))),
        false);
  });
  test(
      'calendar download coalesces, persists, reuses lists and backs off failures',
      () async {
    SharedPreferences.setMockInitialValues({});
    var now = raceStart.subtract(const Duration(hours: 1));
    var calls = 0;
    final release = Completer<void>();
    final client = MockClient((request) async {
      calls++;
      expect(request.headers['User-Agent'], startsWith('iptv-app/'));
      expect(request.url.host, 'api.jolpi.ca');
      await release.future;
      return http.Response(calendar(), calls == 1 ? 200 : 503,
          headers: {'content-type': 'application/json; charset=utf-8'});
    });
    final service =
        FormulaOneScheduleService(client, clock: () => now, persist: true);
    final first = service.warm(cancelled: () => false);
    final second = service.warm(cancelled: () => false);
    release.complete();
    await Future.wait([first, second]);
    expect(calls, 1);
    final rows = service.gamesForDay(now.toLocal());
    expect(rows.single.state, GameState.pre);
    now = now.add(const Duration(minutes: 1));
    expect(service.gamesForDay(now.toLocal()), same(rows));
    final restored =
        FormulaOneScheduleService(client, clock: () => now, persist: true);
    await restored.warm(cancelled: () => false);
    expect(restored.gamesForDay(now.toLocal()).single.id, rows.single.id);
    expect(calls, 1);
    now = now.add(const Duration(hours: 6));
    await service.warm(cancelled: () => false);
    await service.warm(cancelled: () => false);
    expect(calls, 2);
    expect(service.gamesForDay(raceStart.toLocal()), isNotEmpty);
    now = now.add(const Duration(days: 8));
    expect(service.gamesForDay(raceStart.toLocal()), isEmpty);
  });
  test('build-up crosses local midnight and remains on the preceding day',
      () async {
    final start = DateTime(2026, 11, 2, 0, 30).toUtc();
    final raw = raceJson()
      ..remove('FirstPractice')
      ..remove('SecondPractice')
      ..remove('ThirdPractice')
      ..remove('Qualifying');
    raw['date'] = start.toIso8601String().substring(0, 10);
    raw['time'] = start.toIso8601String().substring(11);
    final service = FormulaOneScheduleService(
        MockClient((_) async => http.Response(calendar(raw), 200,
            headers: {'content-type': 'application/json; charset=utf-8'})),
        clock: () => start.subtract(const Duration(hours: 1)));
    await service.warm(cancelled: () => false);
    expect(service.gamesForDay(DateTime(2026, 11, 1)), hasLength(1));
    expect(service.gamesForDay(DateTime(2026, 11, 2)), hasLength(1));
  });
  test(
      'ESPN practices survive and supplemental dedup preserves primary identities',
      () {
    final body = jsonEncode({
      'events': [
        {
          'id': 'weekend',
          'name': 'Formula 1 sponsored Mexico City Grand Prix',
          'competitions': [
            for (final type in ['FP1', 'FP2', 'FP3', 'Qual', 'Race'])
              {
                'id': 'espn-$type',
                'date': raceStart.toIso8601String(),
                'type': {'abbreviation': type},
                'status': {
                  'type': {'state': 'pre'}
                },
              }
          ]
        }
      ]
    });
    final rows = parseEspnScoreboard((body, sportsLeagueById('racing.f1')!));
    expect(rows, hasLength(5));
    final combined =
        mergeSupplementGames(rows, [game(), game(session: 'Practice 1')]);
    expect(combined, hasLength(5));
    expect(combined.every((g) => g.id.startsWith('espn-')), true);
  });
  test('feed roles require explicit F1 names, not just category membership',
      () {
    expect(f1FeedKind(channel('main', 'F1: F1-TV')), F1Feed.main);
    expect(f1FeedKind(channel('driver', 'F1: OSCAR PIASTRI | MCLAREN | PIA')),
        F1Feed.onboard);
    expect(f1FeedKind(channel('tracker', 'F1: F1-TRACKER')), F1Feed.tracker);
    expect(f1FeedKind(channel('data', 'F1: F1-DATA')), F1Feed.data);
    expect(
        f1FeedKind(channel('fast', 'F1 Channel', group: 'Roku')), F1Feed.other);
    expect(f1FeedKind(channel('moto', 'ES: DAZN MOTOGP UHD')), isNull);
    expect(f1FeedKind(channel('dummy', '### FORMULA 1 ###')), isNull);
  });
  test(
      'main feeds enter at build-up, cameras remain available, wrong EPG never promotes',
      () async {
    SharedPreferences.setMockInitialValues({});
    final storage = StorageService();
    await storage.init();
    final guide = Guide(storage);
    addTearDown(guide.dispose);
    var now = raceStart.subtract(const Duration(minutes: 91));
    final matcher = SportsChannelMatcher(guide, clock: () => now);
    final channels = [
      channel('sky', 'UK: Sky Sports F1 UHD'),
      channel('main', 'F1: F1-TV'),
      channel('driver', 'F1: LANDO NORRIS | MCLAREN | NOR'),
      channel('tracker', 'F1: F1-TRACKER'),
      channel('data', 'F1: F1-DATA'),
      channel('fast', 'F1 Channel', group: 'Roku'),
      channel('moto', 'ES: DAZN MOTOGP UHD'),
      channel('replay', 'Sky Sports F1 Replay Feed'),
      channel('wrong', 'Sky Sports F1 Wrong GP'),
      channel('session', 'Sky Sports F1 Other Session'),
    ];
    guide.programmes = [
      for (final pair in [
        ('replay', 'F1 Mexico Grand Prix Replay'),
        ('wrong', 'Live F1 Singapore Grand Prix'),
        ('session', 'F1 Mexico Grand Prix Qualifying')
      ])
        EpgProgram(
            channelId: pair.$1,
            title: pair.$2,
            start: now.subtract(const Duration(hours: 1)),
            stop: raceStart.add(const Duration(hours: 2))),
    ];
    await matcher.prepare(channels);
    final picks = SportsChannelPicks.load(storage), g = game();
    List<ChannelMatch> matches(Map<String, List<ChannelMatch>> map) =>
        map[SportsChannelPicks.eventKey(g)]!;
    final before =
        matches(await matcher.matchDay([g], picks, includePossible: true));
    expect(before.where((m) => m.isConfident), isEmpty);
    now = raceStart.subtract(const Duration(minutes: 90));
    final after =
        matches(await matcher.matchDay([g], picks, includePossible: true));
    expect(after.where((m) => m.isConfident).map((m) => m.channel.id),
        containsAll(['sky', 'main']));
    expect(after.first.isConfident, true);
    expect(
        after.any((m) => ['replay', 'wrong', 'session'].contains(m.channel.id)),
        false);
    expect(
        after
            .where((m) => m.isConfident)
            .every((m) => ['sky', 'main'].contains(m.channel.id)),
        true);
    final alternatives = await matcher.alternativesFor(g, matches: after);
    expect(alternatives.map((m) => m.channel.id),
        containsAll(['driver', 'tracker', 'data']));
  });
  test('Grand Prix and support-series conflicts are narrow and explicit', () {
    expect(f1ProgrammeConflicts(game(), 'Live F1: Singapore Grand Prix'), true);
    expect(f1ProgrammeConflicts(game(), 'Live F1: Mexican Grand Prix'), false);
    expect(f1ProgrammeConflicts(game(), 'Live F1: Grand Prix Sunday'), false);
    expect(f1ProgrammeConflicts(game(), 'Formula 2 Race'), true);
  });
  test('public season fixture parses without subscription traffic', () {
    final file = File('test/fixtures/f1-2026.json');
    final rows = parseFormulaOneSchedule(file.readAsStringSync());
    expect(rows.length, greaterThan(100));
    expect(rows.map((g) => g.id).toSet().length, rows.length);
  });
}
