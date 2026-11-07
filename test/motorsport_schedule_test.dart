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
import 'package:nox_iptv/services/motorsport_schedule_service.dart';
import 'package:nox_iptv/services/sports_channel_matcher.dart';
import 'package:nox_iptv/services/sports_supplement_service.dart';
import 'package:nox_iptv/services/storage_service.dart';

String entry(
        {String id = 'practice',
        String start = '20261023T035000Z',
        String end = '20261023T052000Z',
        String session = 'Practice 2',
        String series = 'supercars',
        String extra = ''}) =>
    '''BEGIN:VEVENT
UID:$id
DTSTART:$start
DTEND:$end
SUMMARY:Repco Supercars Championship - $session
LOCATION:Surfers Paradise Street Circuit · Surfers Paradise\\, Queensland
URL:https://www.racetvguide.com/how-to-watch/$series/
$extra
END:VEVENT
''';
String calendar(List<String> rows) =>
    'BEGIN:VCALENDAR\nVERSION:2.0\n${rows.join()}END:VCALENDAR\n';

class _Guide extends EpgService {
  _Guide(super.storage);
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
              terms.any((t) =>
                  '${p.title} ${p.description}'.toLowerCase().contains(t)))
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
  test(
      'UTC sessions and folded fields survive; invalid/non-driving entries do not',
      () {
    final rows = parseMotorsportCalendar(utf8.encode(calendar([
      entry().replaceFirst('Street Circuit', 'Street\n Circuit'),
      entry(
          id: 'qualifying',
          session: 'Qualifying (Race 31)',
          start: '20261023T060500Z',
          end: '20261023T070500Z'),
      entry(id: 'cancelled', extra: 'STATUS:CANCELLED'),
      entry(id: 'floating', start: '20261023T035000'),
      entry(id: 'date-only', start: '20261023'),
      entry(id: 'invalid', start: '20261323T035000Z'),
      entry(id: 'backwards', end: '20261023T025000Z'),
      entry(id: 'too-long', end: '20261025T052000Z'),
      entry(id: 'parade', session: 'Drivers Parade'),
      entry(id: 'espn', series: 'f1'),
      entry(), // Duplicate UID.
    ])));
    expect(rows, hasLength(2));
    expect(rows.first.start, DateTime.utc(2026, 10, 23, 3, 50));
    expect(rows.first.title, 'Supercars · Gold Coast 500');
    expect(rows.first.league.kind, SportsKind.racing);
    expect(rows.first.aliases, contains('Gold Coast 500'));
    expect(rows.last.session, 'Qualifying (Race 31)');
  });

  test(
      'expanded calendar uses timed sessions only and keeps each series distinct',
      () {
    final slugs = [
      'f2',
      'f3',
      'f1-academy',
      'igtc',
      'elms',
      'super-gt',
      'dtm',
      'wrc',
      'worldssp',
      'bsb',
      'nhra',
      'tcr-world-tour'
    ];
    final rows = parseMotorsportCalendar(utf8.encode(calendar([
      for (final slug in slugs) entry(id: slug, series: slug),
      entry(id: 'all-day-f2', series: 'f2').replaceAll(
          'DTSTART:20261023T035000Z', 'DTSTART;VALUE=DATE:20261023'),
    ])));
    expect(rows.map((r) => r.league.id),
        unorderedEquals(slugs.map((s) => 'racing.$s')));
    for (final row in rows) {
      expect(sportsLeagueById(row.league.id), same(row.league));
      expect(kDefaultSportsLeagueIds, contains(row.league.id));
    }
  });

  test(
      'direct and description calendar URLs keep timed support-series sessions',
      () {
    final direct = entry(id: 'porsche', series: 'carrera-cup')
        .replaceAll('/how-to-watch/', '/');
    final description = entry(id: 'bikes', series: 'bsb').replaceAll(
        'URL:https://www.racetvguide.com/how-to-watch/bsb/',
        'DESCRIPTION:Calendar and TV guide: https://www.racetvguide.com/calendars/bsb/');
    final rows = parseMotorsportCalendar(utf8.encode(calendar([
      direct,
      description,
      entry(id: 'unknown', series: 'not-a-series'),
      entry(id: 'wrong-host').replaceAll('www.racetvguide.com', 'example.test'),
    ])));
    expect(rows.map((r) => r.league.id),
        unorderedEquals(['racing.porsche-carrera-cup-na', 'racing.bsb']));
  });

  test(
      'one download coalesces, caches and projects session boundaries without more requests',
      () async {
    var now = DateTime.utc(2026, 10, 23, 4);
    var calls = 0;
    final release = Completer<void>();
    final service = MotorsportScheduleService(MockClient((_) async {
      calls++;
      await release.future;
      return http.Response(calendar([entry()]), 200,
          headers: {'content-type': 'text/calendar; charset=utf-8'});
    }), clock: () => now);
    final first = service.warm(cancelled: () => false);
    final second = service.warm(cancelled: () => false);
    release.complete();
    await Future.wait([first, second]);
    expect(calls, 1);
    final games = service.gamesForDay(now.toLocal());
    expect(games.single.state, GameState.live);
    expect(games.single.statusText, 'Scheduled now');
    expect(games.single.isScheduleOnly, true);
    now = now.add(const Duration(minutes: 1));
    expect(service.gamesForDay(now.toLocal()), same(games));
    await service.warm(cancelled: () => false);
    expect(calls, 1);
    now = DateTime.utc(2026, 10, 23, 5, 20);
    expect(service.gamesForDay(now.toLocal()).single.state, GameState.post);
    expect(calls, 1);
  });

  test('leaving during a download does not impose a retry cooldown', () async {
    final pending = Completer<http.Response>();
    var cancelled = false;
    var calls = 0;
    final service = MotorsportScheduleService(MockClient((_) async {
      calls++;
      if (calls == 1) return pending.future;
      return http.Response.bytes(utf8.encode(calendar([entry()])), 200);
    }), clock: () => DateTime.utc(2026, 10, 23, 4));
    final first = service.warm(cancelled: () => cancelled);
    await Future<void>.delayed(Duration.zero);
    cancelled = true;
    pending
        .complete(http.Response.bytes(utf8.encode(calendar([entry()])), 200));
    await first;
    expect(service.gamesForDay(DateTime(2026, 10, 23)), isEmpty);
    cancelled = false;
    await service.warm(cancelled: () => cancelled);
    expect(calls, 2);
    expect(service.gamesForDay(DateTime(2026, 10, 23)), isNotEmpty);
  });

  test('failures back off, retain usable schedules and stop after stale limit',
      () async {
    var now = DateTime.utc(2026, 10, 23, 4);
    var calls = 0;
    final service = MotorsportScheduleService(MockClient((_) async {
      calls++;
      return calls == 1
          ? http.Response(calendar([entry()]), 200,
              headers: {'content-type': 'text/calendar; charset=utf-8'})
          : http.Response('', 429);
    }), clock: () => now);
    await service.warm(cancelled: () => false);
    now = now.add(const Duration(hours: 7));
    await service.warm(cancelled: () => false);
    await service.warm(cancelled: () => false);
    expect(calls, 2);
    expect(service.gamesForDay(DateTime(2026, 10, 23)), isNotEmpty);
    now = now.add(const Duration(days: 2));
    expect(service.gamesForDay(DateTime(2026, 10, 23)), isEmpty);
  });

  test(
      'motorsport is optional and arrives while the other supplement is still waiting',
      () async {
    final tsdb = Completer<http.Response>();
    var calls = 0;
    final motor = MotorsportScheduleService(MockClient((_) async {
      calls++;
      return http.Response(calendar([entry()]), 200,
          headers: {'content-type': 'text/calendar; charset=utf-8'});
    }), clock: () => DateTime.utc(2026, 10, 23, 4));
    final service = SportsSupplementService.withClient(
        MockClient((_) => tsdb.future),
        motorsport: motor,
        requestSpacing: Duration.zero);
    await service
        .warmMotorsport([sportsLeagueById('eng.1')!], cancelled: () => false);
    expect(calls, 0);
    final leagues = [sportsLeagueById('racing.supercars')!];
    final pending = service.gamesForDay(leagues, DateTime(2026, 10, 23));
    await service.warmMotorsport(leagues, cancelled: () => false);
    final cached = service.cachedGamesForDay(leagues, DateTime(2026, 10, 23));
    expect(cached.single.league.id, 'racing.supercars');
    expect(tsdb.isCompleted, false);
    expect(
        service.cachedGamesForDay(
            [sportsLeagueById('racing.f1')!], DateTime(2026, 10, 23)),
        isEmpty,
        reason: 'Disabling a calendar league must actually hide its sessions');
    expect(service.cachedGamesForDay(leagues, DateTime(2026, 10, 23)),
        same(cached));
    tsdb.complete(http.Response('{}', 200));
    await pending;
    expect(
        service
            .cachedGamesForDay(leagues, DateTime(2026, 10, 23))
            .single
            .league
            .id,
        'racing.supercars');
  });

  test(
      'two-team-free motorsport entries parse and preserve explicit provider status',
      () {
    final start = DateTime.now().toUtc().add(const Duration(minutes: 10));
    final games = parseSupplementGames((
      [
        {
          'idEvent': '42',
          'idLeague': '1',
          'strLeague': 'V8 Supercars',
          'strSport': 'Motorsport',
          'strEvent': 'Gold Coast 500',
          'strTimestamp': start.toIso8601String(),
          'strStatus': 'NS',
        }
      ],
      [sportsLeagueById('racing.supercars')!],
      start.toLocal()
    ));
    expect(games, hasLength(1));
    expect(games.single.league.id, 'racing.supercars');
    expect(games.single.league.isField, true);
    expect(games.single.title, 'Gold Coast 500');
    expect(games.single.state, GameState.pre);
  });

  test(
      'Supercars matches circuit in synopsis; rejects wrong session, series and replay',
      () async {
    SharedPreferences.setMockInitialValues({});
    final storage = StorageService();
    await storage.init();
    final guide = _Guide(storage);
    final now = DateTime.utc(2026, 10, 23, 4);
    final service = MotorsportScheduleService(
        MockClient((_) async => http.Response(calendar([entry()]), 200,
            headers: {'content-type': 'text/calendar; charset=utf-8'})),
        clock: () => now);
    await service.warm(cancelled: () => false);
    final game = service.gamesForDay(now.toLocal()).single;
    final descriptions = [
      'LIVE coverage of the Supercars Championship Gold Coast 500, Practice 1.',
      'Gold Coast 500: Practice 1 from Surfers Paradise.',
      'Gold Coast 500: Qualifying for Race 31.',
      'Gold Coast 500: Practice 2 replay.',
      'MotoGP: Gold Coast 500 Practice 2.',
      'Bathurst 1000 Practice 2.',
      'Gold Coast 500: Supports, Porsche Carrera Cup Practice 2.',
    ];
    final channels = [
      for (var i = 0; i < descriptions.length; i++)
        Channel(
            id: 'test::$i',
            rawId: '$i',
            playlistId: 'test',
            name: 'AU Sports $i',
            group: 'Sports',
            url: 'https://example.invalid/never-play')
    ];
    guide.programmes = [
      for (var i = 0; i < descriptions.length; i++)
        EpgProgram(
            channelId: '$i',
            title: i == 0
                ? 'Supercars: Practice 2'
                : i == 4
                    ? 'Live MotoGP'
                    : 'Live Supercars',
            description: descriptions[i],
            start: now.subtract(const Duration(minutes: 20)),
            stop: now.add(const Duration(minutes: 40)))
    ];
    final matcher = SportsChannelMatcher(guide, clock: () => now);
    await matcher.prepare(channels);
    final matches = (await matcher.matchDay([game],
        SportsChannelPicks.load(storage)))[SportsChannelPicks.eventKey(game)]!;
    expect(matches.first.channel.id, 'test::0');
    expect(matches.first.reason, MatchReason.guide);
    expect(matches.where((m) => m.isConfident).map((m) => m.channel.id),
        ['test::0']);
    expect(
        matches.where((m) => [
              'test::1',
              'test::2',
              'test::3',
              'test::4',
              'test::6'
            ].contains(m.channel.id)),
        isEmpty);
    guide.dispose();
  });

  test(
      'saved public calendar parses in isolation without any provider requests',
      () async {
    final file = File('test/fixtures/motorsport_calendar_2026_10_23.ics');
    final watch = Stopwatch()..start();
    final rows = parseMotorsportCalendar(await file.readAsBytes());
    expect(
        rows.where((r) =>
            r.league.id == 'racing.supercars' &&
            r.start == DateTime.utc(2026, 10, 23, 3, 50)),
        hasLength(1));
    expect(
        rows.map((r) => r.league.id).toSet().length, greaterThanOrEqualTo(8));
    // Diagnostic only: desktop timings are not TV guarantees.
    // ignore: avoid_print
    print(
        'Public motorsport calendar: ${rows.length} sessions parsed in ${watch.elapsedMilliseconds}ms');
  });
}
