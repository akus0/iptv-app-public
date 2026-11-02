import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nox_iptv/models/sports.dart';
import 'package:nox_iptv/services/motogp_standings_source.dart';
import 'package:nox_iptv/services/motorsport_schedule_service.dart';
import 'package:nox_iptv/services/sports_service.dart';
import 'package:nox_iptv/services/sports_standings_service.dart';
import 'package:nox_iptv/services/sports_supplement_service.dart';

const added = [
  'football.ufl',
  'basketball.nba-development',
  'baseball.college-softball',
  'lacrosse.mens-college-lacrosse',
  'lacrosse.womens-college-lacrosse',
  'volleyball.mens-college-volleyball',
  'golf.ntw',
  'uru.1',
  'chi.1',
  'ecu.1',
  'crc.1',
  'ven.1',
  'bol.1',
  'par.1'
];
Uint8List bytes(dynamic data) =>
    Uint8List.fromList(utf8.encode(jsonEncode(data)));
String uuid(int i) =>
    '00000000-0000-0000-0000-${i.toString().padLeft(12, '0')}';
Map<String, dynamic> standings(String category, {int year = 2026}) => {
      'file':
          'https://resources.motogp.com/files/results/$year/MAL/$category/RAC/worldstanding.pdf',
      'classification': [
        for (var i = 0; i < 12; i++)
          {
            'position': i + 1,
            'points': 200 - i,
            'rider': {'id': uuid(i), 'full_name': 'Rider $i', 'number': i + 1},
            'team': {
              'season': {'year': year}
            },
            'race_wins': i == 0 ? 3 : 0,
            'podiums': 2,
          }
      ]
    };
String calendar() => '''BEGIN:VCALENDAR
VERSION:2.0
${['supercars', 'motogp', 'nascar-xfinity'].map((id) => '''BEGIN:VEVENT
UID:$id
DTSTART:20261101T030000Z
DTEND:20261101T050000Z
SUMMARY:$id - Race
LOCATION:Official circuit
URL:https://www.racetvguide.com/how-to-watch/$id/
END:VEVENT
''').join()}END:VCALENDAR
''';
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('new score leagues are opt-in with unique existing identities preserved',
      () {
    final all = [...kSportsLeagues, ...kSportsLeagueBank];
    expect(all.map((l) => l.id).toSet().length, all.length);
    for (final id in [
      ...added,
      'racing.nascar-xfinity',
      'racing.nascar-trucks'
    ]) {
      final league = sportsLeagueById(id)!;
      expect(league.enabledByDefault, isFalse, reason: id);
      expect(kDefaultSportsLeagueIds, isNot(contains(id)));
      expect(supportsSportsScoreboard(league), isTrue);
    }
    expect(sportsLeagueById('racing.nascar-xfinity')!.espnPath,
        'racing/nascar-secondary');
    expect(sportsLeagueById('racing.nascar-trucks')!.espnPath,
        'racing/nascar-truck');
    for (final id in motoGpStandingsClasses.keys) {
      expect(sportsLeagueById(id)!.source, 'RaceTV Guide');
      expect(supportsSportsScoreboard(sportsLeagueById(id)!), isFalse);
      expect(supportsSportsSchedule(sportsLeagueById(id)!), isTrue);
    }
  });
  test('MotoGP classes validate season, category, riders and supplied ranks',
      () {
    for (final category in motoGpStandingsClasses.values) {
      final result =
          parseMotoGpStandings((bytes(standings(category)), 2026, category));
      expect(result.tables.single.rows.length, 12);
      expect(result.tables.single.rows.first.team.id, 'motogp:${uuid(0)}');
      expect(result.tables.single.rows.first.stats['points'], '200');
      expect(result.season, '2026');
    }
    expect(
        () => parseMotoGpStandings((bytes(standings('Moto2')), 2026, 'MotoGP')),
        throwsFormatException);
    expect(
        () => parseMotoGpStandings(
            (bytes(standings('MotoGP', year: 2025)), 2026, 'MotoGP')),
        throwsFormatException);
    final invalid = standings('MotoGP');
    (invalid['classification'] as List)[0]['points'] = -1;
    expect(() => parseMotoGpStandings((bytes(invalid), 2026, 'MotoGP')),
        throwsFormatException);
  });
  test(
      'MotoGP source shares metadata and main service caches only requested classes',
      () async {
    final paths = <String>[];
    final source = SportsStandingsService(
        clock: () => DateTime(2026, 11, 2),
        client: MockClient((r) async {
          paths.add(r.url.path);
          final path = r.url.path.split('/').last;
          if (path == 'seasons') {
            return http.Response.bytes(
                bytes([
                  {'id': uuid(100), 'year': 2026}
                ]),
                200);
          }
          if (path == 'categories') {
            return http.Response.bytes(
                bytes([
                  for (final (i, c) in motoGpStandingsClasses.values.indexed)
                    {'id': uuid(101 + i), 'name': '$c™'}
                ]),
                200);
          }
          expect(path, 'standings');
          final index = int.parse(
                  r.url.queryParameters['categoryUuid']!.split('-').last) -
              101;
          return http.Response.bytes(
              bytes(standings(motoGpStandingsClasses.values.elementAt(index))),
              200);
        }));
    addTearDown(source.close);
    expect(paths, isEmpty);
    final results = await Future.wait([
      source.load(sportsLeagueById('racing.motogp')!),
      source.load(sportsLeagueById('racing.moto2')!)
    ]);
    expect(results.every((r) => r.hasRows && !r.failed), isTrue);
    expect(paths.where((p) => p.endsWith('/seasons')).length, 1);
    expect(paths.where((p) => p.endsWith('/categories')).length, 1);
    expect(paths.where((p) => p.endsWith('/standings')).length, 2);
    await source.load(sportsLeagueById('racing.moto2')!);
    expect(paths.length, 4);
  });
  test('calendar-only Schedule reuses one download and marks stale fallback',
      () async {
    var now = DateTime.utc(2026, 11, 1), calls = 0, fail = false;
    final client = MockClient((r) async {
      calls++;
      expect(r.url.host, 'www.racetvguide.com');
      return http.Response(fail ? '' : calendar(), fail ? 503 : 200);
    });
    final calendarService = MotorsportScheduleService(client, clock: () => now);
    final scores = SportsService.withClient(client,
        clock: () => now, motorsport: calendarService);
    final supercars = sportsLeagueById('racing.supercars')!;
    final date = DateTime(2026, 11, 1);
    final first = await scores.scheduleGames(supercars, date, date);
    expect(first.incomplete, isFalse);
    expect(first.games.single.league.id, supercars.id);
    expect(first.games.single.isScheduleOnly, isTrue);
    expect(first.games.single.home.score, isNull);
    await scores.scheduleGames(sportsLeagueById('racing.motogp')!, date, date);
    expect(calls, 1);
    now = now.add(const Duration(hours: 7));
    fail = true;
    final fallback = await scores.scheduleGames(supercars, date, date);
    expect(fallback.incomplete, isTrue);
    expect(fallback.games, isNotEmpty);
    expect(calls, 2);
  });
  test('disabled upgraded racing feeds cannot leak from calendar supplements',
      () async {
    final client = MockClient((_) async => http.Response(calendar(), 200));
    final motor = MotorsportScheduleService(client,
        clock: () => DateTime.utc(2026, 11, 1));
    final source =
        SportsSupplementService.withClient(client, motorsport: motor);
    final selected = [sportsLeagueById('racing.supercars')!];
    await source.warmMotorsport(selected, cancelled: () => false);
    expect(
        source
            .cachedGamesForDay(selected, DateTime(2026, 11, 1))
            .map((g) => g.league.id),
        ['racing.supercars']);
  });
  final fixtures = Platform.environment['SPORTS_COVERAGE_FIXTURES'];
  final filenames = {
    'football.ufl': 'football-ufl-scoreboard',
    'basketball.nba-development': 'basketball-gleague-month',
    'baseball.college-softball': 'baseball-softball',
    'lacrosse.mens-college-lacrosse':
        'lacrosse-mens-college-lacrosse-scoreboard',
    'lacrosse.womens-college-lacrosse':
        'lacrosse-womens-college-lacrosse-scoreboard',
    'volleyball.mens-college-volleyball': 'volleyball-mens-month',
    'golf.ntw': 'golf-ntw-current',
    'racing.nascar-xfinity': 'nascar-secondary-current',
    'racing.nascar-trucks': 'nascar-truck-current',
    for (final id in [
      'uru.1',
      'chi.1',
      'ecu.1',
      'crc.1',
      'ven.1',
      'bol.1',
      'par.1'
    ])
      id: 'soccer-$id-scoreboard'
  };
  for (final e in filenames.entries) {
    test('verified official results parse for ${e.key}', () async {
      final league = sportsLeagueById(e.key)!;
      final source = SportsService.withClient(MockClient((_) async =>
          http.Response.bytes(
              File('$fixtures/${e.value}.json').readAsBytesSync(), 200)));
      final games = await source.replayGames(league, DateTime(2026, 11, 1));
      expect(games, isNotEmpty);
      expect(games.every((g) => g.league.id == league.id), isTrue);
      expect(games.map((g) => g.id).toSet().length, games.length);
      if (league.kind == SportsKind.racing) {
        expect(games.first.event!.leaders, isNotEmpty);
      }
    },
        skip: fixtures == null
            ? 'Set SPORTS_COVERAGE_FIXTURES to public fixtures'
            : false);
  }
  for (final category in motoGpStandingsClasses.values) {
    test('official $category standings fixture validates all riders', () {
      final result = parseMotoGpStandings((
        File('$fixtures/motogp-${category.toLowerCase()}-standings.json')
            .readAsBytesSync(),
        2026,
        category
      ));
      expect(result.hasRows, isTrue);
      expect(result.tables.single.rows.length, greaterThanOrEqualTo(20));
    },
        skip: fixtures == null
            ? 'Set SPORTS_COVERAGE_FIXTURES to public fixtures'
            : false);
  }
}
