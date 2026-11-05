import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:nox_iptv/models/channel.dart';
import 'package:nox_iptv/models/sports.dart';
import 'package:nox_iptv/services/sky_tennis_schedule_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final start = DateTime.utc(2026, 10, 22, 12);
  late DateTime now;
  SportsGame game() => SportsGame(
      id: '1',
      league: sportsLeagueById('tennis.wta')!,
      start: start,
      state: GameState.live,
      statusText: 'Live',
      home: const SportsTeam(
          id: 'j', name: 'Iva Jovic', shortName: 'Jovic', abbreviation: ''),
      away: const SportsTeam(
          id: 'p',
          name: 'Jasmine Paolini',
          shortName: 'Paolini',
          abbreviation: ''),
      event: const SportsEventInfo(title: 'Ningbo Open'));
  Channel channel(String name, {String group = 'UK Sports'}) => Channel(
      id: name,
      rawId: name,
      playlistId: 'test',
      name: name,
      group: group,
      url: 'https://example.invalid/not-playable');
  String payload(
          {String desc =
              'In Ningbo, Iva Jovic goes head to head with Jasmine Paolini.',
          String title = 'Live: WTA Tennis',
          int duration = 5400,
          String sid = '1705'}) =>
      jsonEncode({
        'date': '20261022',
        'schedule': [
          {
            'sid': sid,
            'events': [
              {
                't': title,
                'sy': desc,
                'st': start.millisecondsSinceEpoch ~/ 1000,
                'd': duration,
              }
            ]
          }
        ]
      });
  setUp(() {
    now = start.add(const Duration(minutes: 5));
    SharedPreferences.setMockInitialValues({});
  });

  test(
      'one batch serves repeated calls; exact identity, region and time are retained',
      () async {
    var calls = 0;
    final service = SkyTennisScheduleService(MockClient((r) async {
      calls++;
      expect(r.url.host, 'awk.epgsky.com');
      expect(r.url.path, '/hawk/linear/schedule/20261022/1701,1705');
      expect(r.headers['X-SkyOTT-Territory'], 'GB');
      expect(r.url.hasQuery, false);
      return http.Response(payload(), 200);
    }), clock: () => now);
    service.configureChannels([
      channel('UK: Sky Sports Tennis HD'),
      channel('Sky Sports Main Event')
    ]);
    await Future.wait(List.generate(
        30, (_) => service.warm([game()], cancelled: () => false)));
    expect(calls, 1);
    final b = service.cachedFor(game()).single;
    expect(b.tournamentOnly, false);
    expect(b.country, 'United Kingdom');
    expect(b.programme!.start, start);
    expect(b.programme!.description, contains('Jovic'));
    now = now.add(const Duration(minutes: 10));
    expect(service.cachedFor(game()), isEmpty);
  });

  test(
      'unknown regions, numbered feeds and missing installed channels make no requests',
      () async {
    var calls = 0;
    final service = SkyTennisScheduleService(MockClient((_) async {
      calls++;
      return http.Response(payload(), 200);
    }), clock: () => now);
    for (final channels in <List<Channel>>[
      [],
      [channel('Sky Sports Tennis', group: 'Sports')],
      [channel('DE: Sky Sports Tennis', group: 'UK Sports')],
      [channel('Sky Sports+ 2')],
      [channel('Sky Sports Tennis 2')],
    ]) {
      service.configureChannels(channels);
      await service.warm([game()], cancelled: () => false);
    }
    expect(calls, 0);
  });

  test('mixed blocks stay possible and highlights are excluded', () async {
    for (final title in ['Live: WTA Tennis', 'Tennis Highlights']) {
      final service = SkyTennisScheduleService(
          MockClient((_) async => http.Response(
              payload(
                  title: title,
                  desc:
                      'Ningbo: Iva Jovic vs Jasmine Paolini, followed by Badosa vs Ruzic.'),
              200)),
          clock: () => now);
      SharedPreferences.setMockInitialValues({});
      service.configureChannels([channel('Sky Sports Tennis')]);
      await service.warm([game()], cancelled: () => false);
      final rows = service.cachedFor(game());
      if (title == 'Tennis Highlights') {
        expect(rows, isEmpty);
      } else {
        expect(rows.single.tournamentOnly, true);
      }
    }
  });

  test('programme boundary expires evidence even inside cache TTL', () async {
    final service = SkyTennisScheduleService(
        MockClient((_) async => http.Response(payload(duration: 360), 200)),
        clock: () => now);
    service.configureChannels([channel('Sky Sports Tennis')]);
    await service.warm([game()], cancelled: () => false);
    expect(service.cachedFor(game()), hasLength(1));
    now = start.add(const Duration(minutes: 6));
    expect(service.cachedFor(game()), isEmpty);
  });

  test('fresh disk cache survives reopening without an extra request',
      () async {
    var calls = 0;
    final client = MockClient((_) async {
      calls++;
      return http.Response(payload(), 200);
    });
    for (var i = 0; i < 2; i++) {
      final service = SkyTennisScheduleService(client, clock: () => now);
      service.configureChannels([channel('Sky Sports Tennis')]);
      await service.warm([game()], cancelled: () => false);
      expect(service.cachedFor(game()).single.tournamentOnly, false);
    }
    expect(calls, 1);
  });

  test(
      'failure, malformed payload, stale HTTP cache and oversized data back off',
      () async {
    for (final response in [
      http.Response('', 429),
      http.Response('{}', 200),
      http.Response(payload(), 200, headers: {'age': '601'}),
      http.Response('x' * (256 * 1024 + 1), 200)
    ]) {
      SharedPreferences.setMockInitialValues({});
      var calls = 0;
      final service = SkyTennisScheduleService(MockClient((_) async {
        calls++;
        return response;
      }), clock: () => now);
      service.configureChannels([channel('Sky Sports Tennis')]);
      for (var i = 0; i < 10; i++) {
        await service.warm([game()], cancelled: () => false);
      }
      expect(calls, 1);
      expect(service.cachedFor(game()), isEmpty);
      now = now.add(const Duration(minutes: 16));
      await service.warm([game()], cancelled: () => false);
      expect(calls, 2);
    }
  });

  test(
      'navigation cancellation discards a response and does not restart per card',
      () async {
    var cancelled = false, calls = 0;
    final ready = Completer<void>();
    final response = Completer<http.Response>();
    final service = SkyTennisScheduleService(MockClient((_) async {
      calls++;
      ready.complete();
      return response.future;
    }), clock: () => now);
    service.configureChannels([channel('Sky Sports Tennis')]);
    final task = service.warm([game()], cancelled: () => cancelled);
    await ready.future;
    cancelled = true;
    response.complete(http.Response(payload(), 200));
    await task;
    expect(service.cachedFor(game()), isEmpty);
    await service.warm([game()], cancelled: () => false);
    expect(calls, 1);
  });

  test(
      'saved first-party schedule identifies the researched single-fixture slot',
      () {
    final rows = parseSkyTennisSchedule(
        File('test/fixtures/sky-tennis-schedule.json').readAsStringSync());
    final p =
        rows.where((p) => p.description?.contains('Jovic') == true).single;
    expect(p.start, DateTime.utc(2026, 10, 22, 5));
    expect(p.stop, DateTime.utc(2026, 10, 22, 6, 30));
    expect(rows.every((p) => p.isLive), true);
  });
}
