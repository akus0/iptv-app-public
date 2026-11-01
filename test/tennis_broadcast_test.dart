import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nox_iptv/models/sports.dart';
import 'package:nox_iptv/services/tennis_broadcast_service.dart';

String tile(String title,
        {String channel = 'Sky Sports Tennis',
        String kind = 'live',
        String sport = 'tennis',
        String slug = ''}) =>
    '''
<article data-sport="$sport"><span data-type="$kind">Live</span>
<span>Showing on $channel</span><a href="/tennis/watch/123/$slug"
 data-title="$title">$title</a></article>''';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final now = DateTime.utc(2026, 10, 22, 12);
  SportsGame game(
          {String title = 'Almaty Open',
          GameState state = GameState.live,
          String home = 'Tomas Machac',
          String away = 'Karen Khachanov'}) =>
      SportsGame(
          id: '1',
          league: sportsLeagueById('tennis.atp')!,
          start: now.subtract(const Duration(hours: 1)),
          state: state,
          statusText: 'Live',
          home: SportsTeam(
              id: '1', name: home, shortName: home, abbreviation: ''),
          away: SportsTeam(
              id: '2', name: away, shortName: away, abbreviation: ''),
          event: SportsEventInfo(title: title));

  test(
      'live linear listings are conservative, shared, region-scoped and expire',
      () async {
    var calls = 0;
    var time = now;
    final service = TennisBroadcastService(MockClient((request) async {
      calls++;
      expect(request.url.toString(), 'https://www.skysports.com/tennis/watch');
      return http.Response(
          [
            tile('ATP Almaty Open'),
            tile('Live ATP/WTA Tennis'),
            tile('Almaty Open', channel: 'Sky Sports+'),
            tile('ATP Almaty Open', kind: 'upcoming'),
            tile('WTA Almaty Open', channel: 'Sky Sports Arena'),
            tile('ATP Shanghai Masters', channel: 'Sky Sports Action'),
            tile('Almaty Open Highlights', channel: 'Sky Sports Mix'),
          ].join(),
          200);
    }), clock: () => time);
    await Future.wait(List.generate(
        30, (_) => service.warm([game()], cancelled: () => false)));
    expect(calls, 1);
    final found = service.cachedFor(game());
    expect(found, hasLength(1));
    expect(found.single.name, 'Sky Sports Tennis');
    expect(found.single.country, 'United Kingdom');
    expect(found.single.tournamentOnly, true);
    expect(service.cachedFor(game(title: 'Brussels Open')), isEmpty);
    expect(service.cachedFor(game(state: GameState.pre)), isEmpty);
    time = time.add(const Duration(minutes: 5));
    expect(service.cachedFor(game()), isEmpty);
    await service.warm([game()], cancelled: () => false);
    expect(calls, 2);
  });

  test('both players and tournament must agree; a multiplex is never numbered',
      () async {
    final service = TennisBroadcastService(
        MockClient((_) async => http.Response(
            [
              tile('T. Machac v K. Khachanov', slug: 'almaty-open-2026'),
              tile('T. Machac v K. Khachanov',
                  slug: 'shanghai-masters-2026', channel: 'Sky Sports Action'),
              tile('T. Machac v J. Sinner',
                  slug: 'almaty-open-2026', channel: 'Sky Sports Arena'),
              tile('T. Machac v K. Khachanov',
                  slug: 'almaty-open-2026', channel: 'Sky Sports+'),
            ].join(),
            200)),
        clock: () => now);
    await service.warm([game()], cancelled: () => false);
    expect(service.cachedFor(game()).map((b) => b.name), ['Sky Sports Tennis']);
  });

  test(
      'errors, stale pages, cancellation and empty results do not retry per match',
      () async {
    for (final status in [200, 429, 500]) {
      var calls = 0;
      var time = now;
      final service = TennisBroadcastService(MockClient((_) async {
        calls++;
        return http.Response(tile('Almaty Open'), status,
            headers: {'age': '600'});
      }), clock: () => time);
      await service.warm([game()], cancelled: () => true);
      expect(calls, 0);
      await service.warm([game()], cancelled: () => false);
      for (var i = 0; i < 20; i++) {
        await service.warm([game()], cancelled: () => false);
      }
      expect(calls, 1);
      expect(service.cachedFor(game()), isEmpty);
      time = time.add(const Duration(minutes: 16));
      await service.warm([game()], cancelled: () => false);
      expect(calls, 2);
    }
  });

  const file = String.fromEnvironment('TENNIS_SKY_FILE');
  test('saved first-party page parses without following any playback links',
      () {
    final rows = parseTennisLiveListings(File(file).readAsStringSync());
    expect(rows, isNotEmpty);
    expect(rows.every((r) => r.channel == 'Sky Sports Tennis'), true);
    expect(rows.every((r) => !r.channel.contains('+')), true);
  }, skip: file.isEmpty ? 'Optional saved public page' : false);
}
