import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nox_iptv/models/channel.dart';
import 'package:nox_iptv/models/epg_program.dart';
import 'package:nox_iptv/models/sports.dart';
import 'package:nox_iptv/services/sports_channel_matcher.dart';
import 'package:nox_iptv/services/sports_match_inputs.dart';
import 'package:nox_iptv/services/sports_service.dart';
import 'package:nox_iptv/utils/sports_time_filter.dart';

final now = DateTime.utc(2026, 10, 28, 12);

class Guide implements SportsMatchGuide {
  final rows = <EpgProgram>[];
  int queries = 0, reads = 0, revision = 1;
  DateTime Function() clock = () => now;
  final requests = <List<String>>[];
  @override
  int get changeRevision => revision;
  @override
  DateTime? get lastUpdated => now;
  @override
  EpgProgram? getCurrentProgram(String id) {
    reads++;
    return rows
        .where((p) => p.channelId == id && p.isNowPlaying(clock()))
        .firstOrNull;
  }

  @override
  EpgProgram? getNextProgram(String id) => rows
      .where((p) => p.channelId == id && p.start.isAfter(clock()))
      .firstOrNull;
  @override
  Future<List<EpgProgram>> findProgrammesByTitle(
      DateTime from, DateTime to, List<String> terms) async {
    queries++;
    requests.add(List.of(terms));
    return rows
        .where((p) =>
            p.stop.isAfter(from) &&
            p.start.isBefore(to) &&
            terms.any(p.title.toLowerCase().contains))
        .toList();
  }

  @override
  Future<List<EpgProgram>> findSportsProgrammesForChannels(
          List<String> ids, DateTime from, DateTime to) async =>
      rows
          .where((p) =>
              ids.contains(p.channelId) &&
              p.stop.isAfter(from) &&
              p.start.isBefore(to))
          .toList();
}

class Picks implements SportsMatchPicks {
  @override
  String? channelIdFor(SportsGame game) => null;
}

SportsTeam team(String n, [String code = '']) =>
    SportsTeam(id: n, name: n, shortName: n, abbreviation: code);
SportsGame game(String league, String home, String away,
        {String code = '',
        String? event,
        String? session,
        DateTime? start,
        GameState state = GameState.live}) =>
    SportsGame(
        id: 'test',
        league: sportsLeagueById(league)!,
        start: start ?? now.subtract(const Duration(minutes: 15)),
        state: state,
        statusText: '',
        home: team(home, code),
        away: team(away),
        event: event == null
            ? null
            : SportsEventInfo(title: event, session: session));
Channel channel(String name) => Channel(
    id: '1',
    rawId: '1',
    playlistId: 'research',
    name: name,
    group: 'Sports',
    url: 'https://example.invalid/never-opened',
    epgIdOverride: '1');
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Future<List<ChannelMatch>> probe(SportsGame g, String name,
      {String? title, String? description, DateTime? slot}) async {
    final guide = Guide();
    if (title != null) {
      guide.rows.add(EpgProgram(
          channelId: '1',
          title: title,
          description: description,
          start: slot ?? now.subtract(const Duration(minutes: 20)),
          stop: now.add(const Duration(hours: 3))));
    }
    final matcher = SportsChannelMatcher(guide, clock: () => now);
    try {
      await matcher.prepare([channel(name)]);
      return (await matcher.matchDay([g], Picks(),
          includePossible: true))[SportsChannelPicks.eventKey(g)]!;
    } finally {
      matcher.dispose();
    }
  }

  test('soccer guide names may omit FC without matching different clubs',
      () async {
    final fixture =
        game('afc.cup', 'Adelaide United FC', 'Lion City Sailors FC');
    final right = await probe(fixture, 'Arena 7',
        title: 'AFC Champions League Two: Adelaide United - Lion City Sailors');
    expect(right.any((m) => m.isConfident), isTrue);
    for (final title in [
      'Adelaide City vs Lion City Sailors',
      'Adelaide vs Lion City Sailors',
      'Adelaide United vs Young Lions'
    ]) {
      expect(
          (await probe(fixture, 'Arena 7', title: title))
              .any((m) => m.isConfident),
          isFalse);
    }
  });

  test('a channel label cannot supply an opponent from a different fixture',
      () async {
    final fixture =
        game('fifa.world', 'United States', 'Australia', code: 'USA');
    final wrong = await probe(
        fixture, 'FIFA World Cup | USA Soccer09: Australia vs Turkey');
    expect(wrong.where((m) => m.isConfident), isEmpty);
    final right = await probe(fixture, 'FIFA World Cup | USA vs Australia');
    expect(right.where((m) => m.isConfident), isNotEmpty);
    final timed =
        await probe(fixture, 'FIFA World Cup 12:30: USA vs Australia');
    expect(timed.where((m) => m.isConfident), isNotEmpty);
  });

  test('field hockey matches teams without accepting an ice hockey fixture',
      () async {
    final fixture = game('field-hockey.womens-college-field-hockey',
        'Liberty Flames', 'Villanova Wildcats');
    for (final label in ['Field hockey', 'Ice hockey']) {
      final matches = await probe(fixture, 'Arena 7',
          title: '$label: Liberty Flames vs Villanova Wildcats');
      expect(matches.any((m) => m.isConfident), label == 'Field hockey');
    }
  });
  test('new NBL league uses fixture evidence and rejects NBA coverage',
      () async {
    final fixture =
        game('basketball.nbl', 'Sydney Kings', 'Tasmania JackJumpers');
    final correct = await probe(fixture, 'Arena 7',
        title: 'NBL Basketball: Sydney Kings vs Tasmania JackJumpers');
    expect(correct.any((m) => m.isConfident), true);
    final wrong = await probe(fixture, 'Arena 7',
        title: 'NBA Basketball: Sydney Kings vs Tasmania JackJumpers');
    expect(wrong.any((m) => m.isConfident), false);
  });
  test('PGA Tour does not claim a Champions Tour broadcast', () async {
    final matches = await probe(
        game('golf.pga', '', '', event: 'Simmons Bank Championship'),
        'Golf channel',
        title: 'PGA Tour Champions: Simmons Bank Championship');
    expect(matches.any((m) => m.isConfident), false);
  });
  for (final next in [false, true]) {
    for (final sport in ['NHL', 'ice hockey']) {
      test('exact synopsis-only fixture: next=$next, context=$sport', () async {
        final fixture = game('nhl', 'Boston Bruins', 'Toronto Maple Leafs',
            start: next ? now.add(const Duration(minutes: 20)) : null,
            state: next ? GameState.pre : GameState.live);
        final rows = await probe(fixture, 'Arena 7',
            title: 'Live coverage',
            description:
                'Boston Bruins vs Toronto Maple Leafs. Live $sport action.',
            slot: next ? now.add(const Duration(minutes: 10)) : null);
        expect(rows.where((m) => m.isConfident), hasLength(1));
      });
    }
  }
  test(
      'synopsis context does not override an explicitly different title or sport',
      () async {
    final fixture = game('nhl', 'Boston Bruins', 'Toronto Maple Leafs');
    for (final title in [
      'NBA: Boston Bruins vs Toronto Maple Leafs',
      'NHL: Montreal Canadiens vs Vancouver Canucks',
      'NHL Highlights'
    ]) {
      final rows = await probe(fixture, 'Arena 7',
          title: title,
          description:
              'Boston Bruins vs Toronto Maple Leafs. Live NHL action.');
      expect(rows.where((m) => m.isConfident), isEmpty, reason: title);
    }
  });

  for (final title in [
    "Australian Open: OConnell vs de Minaur",
    "Australian Open: O’Connell vs de Minaur",
    "ATP Tennis: C. O'Connell vs A. de Minaur",
    "ATP Tennis: Christopher O'Connell vs Alex de Minaur"
  ]) {
    test('tennis surname punctuation: $title', () async {
      final rows = await probe(
          game('tennis.atp', "Christopher O'Connell", 'Alex de Minaur',
              event: 'Australian Open'),
          title);
      expect(rows.where((m) => m.isConfident), hasLength(1));
    });
  }
  test('tennis still rejects the wrong first initial', () async {
    final rows = await probe(
        game('tennis.atp', "Christopher O'Connell", 'Alex de Minaur',
            event: 'Australian Open'),
        "ATP Tennis: J. O'Connell vs A. de Minaur");
    expect(rows.where((m) => m.isConfident), isEmpty);
  });
  for (final separator in ['-', '–', '—', 'vs']) {
    test('tennis comma-form player names with $separator', () async {
      final rows = await probe(
          game('tennis.atp', 'Jannik Sinner', 'Carlos Alcaraz',
              event: 'Australian Open'),
          'ATP Tennis: Sinner, Jannik $separator Alcaraz, Carlos');
      expect(rows.where((m) => m.isConfident), hasLength(1));
    });
  }
  test('compound names and multiple tennis fixtures retain safeguards',
      () async {
    final fixture = game('tennis.atp', 'Jan-Lennard Struff', 'Carlos Alcaraz',
        event: 'Australian Open');
    final right = await probe(
        fixture, 'ATP Tennis: Struff, Jan-Lennard - Alcaraz, Carlos');
    expect(right.where((m) => m.isConfident), hasLength(1));
    final multi = await probe(fixture,
        'ATP Tennis: Struff vs Alcaraz followed by Sinner vs Djokovic');
    expect(multi.where((m) => m.isConfident), isEmpty);
  });

  Map<String, Object> golf(String status,
          {String state = 'in', DateTime? start}) =>
      {
        'events': [
          {
            'id': 'golf',
            'name': 'Test Championship',
            'date': (start ?? now).toIso8601String(),
            'competitions': [
              {
                'status': {
                  'type': {
                    'state': state,
                    'name': status,
                    'shortDetail': status
                  }
                },
                'competitors': <Object>[],
              }
            ]
          }
        ]
      };
  test('golf between rounds stays ongoing but is not active live play', () {
    for (final status in [
      'STATUS_IN_PROGRESS',
      'STATUS_PLAY_COMPLETE',
      'STATUS_SUSPENDED',
      'STATUS_DELAYED'
    ]) {
      final g = parseEspnScoreboard(
          (jsonEncode(golf(status)), sportsLeagueById('golf.pga')!)).single;
      final active = status == 'STATUS_IN_PROGRESS';
      expect(g.state, GameState.live, reason: 'Tournament is still ongoing');
      expect(g.isLive, active);
      expect(SportsTimeFilter.live.accepts(g, now), active);
      expect(SportsTimeFilter.liveAndSoon.accepts(g, now), active);
      expect(SportsTimeFilter.all.accepts(g, now), true);
      expect(g.withOnlineBroadcasts([]).isLive, active);
      expect(g.statusText, status);
    }
  });

  for (final minutes in [-840, -30, 20, 60]) {
    test('bounded upcoming refresh interval: $minutes minutes', () async {
      var clock = now, calls = 0;
      final client = MockClient((request) async {
        calls++;
        return http.Response(
            jsonEncode(golf('STATUS_SCHEDULED',
                state: 'pre', start: now.add(Duration(minutes: minutes)))),
            200);
      });
      addTearDown(client.close);
      final service = SportsService.withClient(client, clock: () => clock);
      final league = sportsLeagueById('golf.pga')!;
      await service.replayGames(league, now);
      clock = clock.add(const Duration(seconds: 60));
      await service.replayGames(league, now);
      expect(calls, minutes >= -180 && minutes < 30 ? 2 : 1);
      clock = clock.add(const Duration(minutes: 11));
      await service.replayGames(league, now);
      expect(calls, minutes >= -180 && minutes < 30 ? 3 : 2,
          reason: 'Unresolved fixtures are still retried');
    });
  }
  test('explicitly postponed imminent fixture does not fast-poll', () async {
    var clock = now, calls = 0;
    final client = MockClient((request) async {
      calls++;
      return http.Response(
          jsonEncode(golf('STATUS_POSTPONED', state: 'pre')), 200);
    });
    addTearDown(client.close);
    final service = SportsService.withClient(client, clock: () => clock);
    await service.replayGames(sportsLeagueById('golf.pga')!, now);
    clock = clock.add(const Duration(seconds: 60));
    await service.replayGames(sportsLeagueById('golf.pga')!, now);
    expect(calls, 1);
  });
  test('only supported college feeds request expanded scoreboard coverage',
      () async {
    final requests = <Uri>[];
    final client = MockClient((r) async {
      requests.add(r.url);
      return http.Response('{"events":[]}', 200);
    });
    addTearDown(client.close);
    final service = SportsService.withClient(client, clock: () => now);
    for (final path in [
      'basketball/mens-college-basketball',
      'football/college-football',
      'basketball/nba'
    ]) {
      final league = [...kSportsLeagues, ...kSportsLeagueBank]
          .firstWhere((l) => l.espnPath == path);
      await service.replayGames(league, now);
    }
    expect(requests[0].queryParameters['groups'], '50');
    expect(requests[0].queryParameters['limit'], '300');
    expect(requests[1].queryParameters['groups'], '80');
    expect(requests[1].queryParameters['limit'], '300');
    expect(requests[2].queryParameters.containsKey('groups'), false);
    expect(requests[2].queryParameters.containsKey('limit'), false);
  });
  test(
      'progressive batches query only missing guide terms; refresh still rechecks',
      () async {
    final guide = Guide();
    final matcher = SportsChannelMatcher(guide, clock: () => now);
    addTearDown(matcher.dispose);
    await matcher.prepare([channel('Arena 7')]);
    final first = game('nhl', 'Boston Bruins', 'Toronto Maple Leafs');
    final second = game('nhl', 'Montreal Canadiens', 'Vancouver Canucks');
    guide.rows.add(EpgProgram(
        channelId: '1',
        title: 'NHL: Montreal Canadiens vs Vancouver Canucks',
        start: now.subtract(const Duration(minutes: 20)),
        stop: now.add(const Duration(hours: 3))));
    await matcher.matchDay([first], Picks());
    final oldTerms = guide.requests.single.toSet();
    final result = await matcher.matchDay([second], Picks());
    expect(result.values.single.where((m) => m.isConfident), hasLength(1));
    if (guide.requests.length == 2) {
      expect(guide.requests.last.toSet().intersection(oldTerms), isEmpty,
          reason: 'Previously searched terms are not sent to SQL again');
    }
    final count = guide.queries;
    await matcher.matchDay([first, second], Picks());
    expect(guide.queries, count);
    guide.rows.clear();
    guide.revision++;
    final changed = await matcher.matchDay([second], Picks());
    expect(changed.values.single.where((m) => m.isConfident), isEmpty);
    expect(guide.queries, greaterThan(count));
  });

  test(
      'programme turnover preserves an unrelated event cache, not expired evidence',
      () async {
    var clock = now;
    final guide = Guide()..clock = (() => clock);
    final matcher = SportsChannelMatcher(guide, clock: () => clock);
    addTearDown(matcher.dispose);
    final channels = [
      channel('Arena 7'),
      Channel(
          id: '2',
          rawId: '2',
          playlistId: 'research',
          name: 'Arena 8',
          group: 'Sports',
          url: 'https://example.invalid/unused',
          epgIdOverride: '2'),
    ];
    await matcher.prepare(channels);
    final hockey = game('nhl', 'Boston Bruins', 'Toronto Maple Leafs');
    final basketball = game('nba', 'Los Angeles Lakers', 'Boston Celtics');
    guide.rows.addAll([
      EpgProgram(
          channelId: '1',
          title: 'NHL: Boston Bruins vs Toronto Maple Leafs',
          start: now.subtract(const Duration(minutes: 20)),
          stop: now.add(const Duration(hours: 3))),
      EpgProgram(
          channelId: '2',
          title: 'NBA: Los Angeles Lakers vs Boston Celtics',
          start: now.subtract(const Duration(minutes: 20)),
          stop: now.add(const Duration(minutes: 1))),
    ]);
    final first = await matcher.matchDay([hockey, basketball], Picks());
    final hockeyKey = SportsChannelPicks.eventKey(hockey);
    final basketballKey = SportsChannelPicks.eventKey(basketball);
    expect(first[hockeyKey], isNotEmpty);
    expect(first[basketballKey], isNotEmpty);
    clock = clock.add(const Duration(minutes: 2));
    final second = await matcher.matchDay([hockey, basketball], Picks());
    expect(second[hockeyKey]!.single, same(first[hockeyKey]!.single));
    expect(second[basketballKey], isEmpty);
    guide.revision++;
    guide.rows.clear();
    final updated = await matcher.matchDay([hockey, basketball], Picks());
    expect(updated[hockeyKey], isEmpty);
  });
}
