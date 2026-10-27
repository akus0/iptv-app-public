import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:nox_iptv/models/channel.dart';
import 'package:nox_iptv/models/epg_program.dart';
import 'package:nox_iptv/models/sports.dart';
import 'package:nox_iptv/services/epg_service.dart';
import 'package:nox_iptv/services/sports_channel_matcher.dart';
import 'package:nox_iptv/services/sports_service.dart';
import 'package:nox_iptv/services/storage_service.dart';

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
              terms.any((t) => p.title.toLowerCase().contains(t)))
          .toList();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Guide guide;
  late SportsChannelMatcher matcher;
  late SportsChannelPicks picks;
  late List<SportsGame> games;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final storage = StorageService();
    await storage.init();
    guide = _Guide(storage);
    matcher = SportsChannelMatcher(guide);
    picks = SportsChannelPicks.load(storage);
    final fixtures = jsonDecode(
        await File('test/fixtures/college_scoreboards_2026_10_21.json')
            .readAsString()) as Map;
    games = [
      for (final entry in fixtures.entries)
        ...parseEspnScoreboard(
            (jsonEncode(entry.value), sportsLeagueById(entry.key)!))
    ];
  });
  tearDown(() => guide.dispose());
  SportsGame gameWith(String name) {
    final g = games.firstWhere(
        (g) => g.home.name.contains(name) || g.away.name.contains(name));
    // Recorded identities remain useful, but these tests explicitly exercise
    // a CURRENT programme. Keep their synthetic broadcast window current so
    // the real matcher's ended-programme guard doesn't expire the fixture.
    return SportsGame(
        id: g.id,
        league: g.league,
        start: DateTime.now().subtract(const Duration(minutes: 20)),
        state: GameState.live,
        statusText: 'Live',
        home: g.home,
        away: g.away,
        broadcasts: g.broadcasts,
        event: g.event,
        leaders: g.leaders,
        situation: g.situation,
        source: g.source,
        onlineBroadcasts: g.onlineBroadcasts);
  }

  Channel channel(String id, String name) => Channel(
      id: 'fixture::$id',
      rawId: id,
      playlistId: 'fixture',
      name: name,
      group: 'Sports',
      url: 'https://example.invalid/not-a-stream');
  EpgProgram programme(String id, String title, SportsGame game) => EpgProgram(
      channelId: id,
      title: title,
      start: game.start.subtract(const Duration(minutes: 10)),
      stop: game.start.add(const Duration(hours: 4)));
  Future<List<ChannelMatch>> match(
      SportsGame game, List<Channel> channels) async {
    await matcher.prepare(channels);
    return (await matcher
        .matchDay([game], picks))[SportsChannelPicks.eventKey(game)]!;
  }

  test(
      'live volleyball resolves FAU and school names, not another sport or gender',
      () async {
    final game = gameWith('Florida Atlantic');
    expect(game.away.location, 'Florida Atlantic');
    final result = await match(game, [
      channel('short', 'Volleyball (W): FAU at USF'),
      channel('school', 'Volleyball (W): Florida Atlantic at South Florida'),
      channel('basketball', 'Basketball (W): FAU at USF'),
      channel('soccer', 'Soccer (W): Florida Atlantic at South Florida'),
      channel('men', 'Volleyball (M): Florida Atlantic at South Florida'),
      channel('other', 'Volleyball (W): Florida Atlantic at UCF'),
      channel('broad', 'Volleyball TV'),
      channel('header', '### Volleyball ###'),
    ]);
    expect(result.map((m) => m.channel.rawId).toSet(), {'short', 'school'});
    expect(result.every((m) => m.reason == MatchReason.name), true);
  });

  test('school aliases match a current soccer fixture in names and EPG',
      () async {
    final game = gameWith('App State');
    guide.programmes = [
      programme('guide',
          "Women's Soccer: Southern Mississippi at Appalachian State", game)
    ];
    final result = await match(game, [
      channel('guide', 'ESPN+ 42'),
      channel('correct', "Soccer (W): Southern Mississippi vs Appalachian St."),
      channel('wrongGender', "Soccer (M): Southern Miss at App State"),
      channel('football', 'College Football: Southern Miss at App State'),
      channel('other', 'Soccer (W): Southern Miss at Georgia State'),
      channel('sport', 'Fox Soccer Plus'),
      channel('broadLeague', "NCAA Women's Soccer"),
    ]);
    expect(result.map((m) => m.channel.rawId), ['guide', 'correct']);
    expect(result.first.reason, MatchReason.guide);
  });

  test('three-letter college names and abbreviations retrieve guide candidates',
      () async {
    final game = gameWith('Florida Atlantic');
    guide.programmes = [
      programme('guide', "Women's Volleyball: FAU at USF", game)
    ];
    final result = await match(game, [channel('guide', 'Event feed')]);
    expect(result.single.reason, MatchReason.guide);
  });

  test(
      'generic sport titles use a bounded fixture synopsis without replacing explicit opponents',
      () async {
    final recorded = gameWith('Florida Atlantic');
    // Keep this synthetic live guide slot current. The recorded fixture's
    // original three-hour broadcast expires as wall-clock time advances.
    final game = SportsGame(
        id: recorded.id,
        league: recorded.league,
        start: DateTime.now().subtract(const Duration(minutes: 20)),
        state: GameState.live,
        statusText: 'Live',
        home: recorded.home,
        away: recorded.away);
    guide.programmes = [
      for (final (id, title, description) in [
        (
          'correct',
          "Women's College Volleyball",
          'Florida Atlantic at South Florida. Live coverage.'
        ),
        (
          'other',
          "Women's College Volleyball",
          'Florida Atlantic at UCF. Live coverage.'
        ),
        (
          'wrongTitle',
          "Women's Volleyball: FAU at UCF",
          'Florida Atlantic at South Florida is next week.'
        ),
        (
          'wrongSport',
          'College Basketball',
          'Florida Atlantic at South Florida.'
        ),
        (
          'wrongGender',
          "Men's Volleyball",
          'Florida Atlantic at South Florida.'
        ),
        (
          'replay',
          "Women's Volleyball Replay",
          'Florida Atlantic at South Florida.'
        ),
      ])
        EpgProgram(
            channelId: id,
            title: title,
            description: description,
            start: game.start,
            stop: game.start.add(const Duration(hours: 3))),
    ];
    final result = await match(game, [
      for (final p in guide.programmes)
        channel(p.channelId, 'Event feed ${p.channelId}')
    ]);
    expect(result.single.channel.rawId, 'correct');
    expect(result.single.reason, MatchReason.guide);
    expect(result.single.detail, contains('Florida Atlantic at South Florida'));
  });

  test(
      'Saint, St and possessive school spellings resolve without broad guesses',
      () async {
    final game = gameWith("St. John's");
    final result = await match(game, [
      channel('right', "Women's Soccer: St Johns at Providence"),
      channel('wrong', "Men's Soccer: St Johns at Providence"),
    ]);
    expect(result.single.channel.rawId, 'right');
    final mary = gameWith("Saint Mary's");
    expect(
        (await match(mary, [channel('mary', "Soccer (M): Denver at St Marys")]))
            .single
            .channel
            .rawId,
        'mary');
  });

  test('Michigan is not Michigan State and one mention cannot prove both teams',
      () async {
    final template = gameWith('App State');
    SportsTeam team(String name) =>
        SportsTeam(id: name, name: name, shortName: name, abbreviation: '');
    final game = SportsGame(
        id: 'collision',
        league: template.league,
        start: template.start,
        state: template.state,
        statusText: 'Live',
        home: team('Michigan'),
        away: team('Michigan State'));
    final result = await match(game, [
      channel('one', 'Soccer (W): Michigan State at Iowa'),
      channel('wrong', 'Soccer (W): Eastern Michigan at Michigan State'),
      channel('right', 'Soccer (W): Michigan at Michigan State'),
    ]);
    expect(result.single.channel.rawId, 'right');
  });

  test('provider routing category does not override the named event sport',
      () async {
    final game = gameWith('Florida Atlantic');
    final result = await match(game, [
      channel('right',
          "Women's Volleyball - Florida Atlantic at South Florida | US: SOCCER PPV 4")
    ]);
    expect(result.single.channel.rawId, 'right');
  });

  test(
      'a currently wrong guide slot vetoes name and broadcaster guesses, not saved picks',
      () async {
    final game = gameWith('Florida Atlantic');
    guide.programmes = [
      programme('wrong', 'Basketball: FAU at USF', game),
      programme('other', 'Volleyball: FAU at UCF', game),
      programme('right', 'Volleyball (W): FAU at USF', game),
    ];
    final channels = [
      for (final id in ['wrong', 'other', 'right'])
        channel(id, 'Volleyball (W): FAU at USF')
    ];
    expect((await match(game, channels)).single.channel.rawId, 'right');
    await picks.pickForGame(game, 'fixture::wrong');
    expect((await match(game, channels)).first.reason, MatchReason.pick);
  });

  test('streaming service names cannot select an arbitrary numbered event slot',
      () async {
    final game = gameWith('App State');
    expect(game.broadcasts, contains('ESPN+'));
    expect(
        await match(game, [
          channel('one', 'ESPN+ 001'),
          channel('two', 'ESPN+ 002'),
          channel('linear', 'ESPN HD')
        ]),
        isEmpty);
  });

  test('current college fixtures never fall back to generic sport channels',
      () async {
    await matcher.prepare([
      channel('soccer', 'Fox Soccer Plus'),
      channel('volleyball', 'Volleyball World TV'),
      channel('football', 'NFL Network')
    ]);
    final results = await matcher.matchDay(games, picks);
    expect(games.length, 54);
    expect(results.values.every((m) => m.isEmpty), true);
  });

  const labels = String.fromEnvironment('PLAYLIST_LABELS_FILE');
  test('audit recorded current scoreboards against offline playlist names',
      () async {
    final rows = jsonDecode(await File(labels).readAsString()) as List;
    final channels = [
      for (final (i, row) in rows.indexed)
        Channel(
            id: 'offline::$i',
            rawId: '$i',
            playlistId: 'offline',
            name: row['name'],
            group: row['group'],
            url: 'https://example.invalid/not-a-stream')
    ];
    await matcher.prepare(channels);
    final live = games.where((g) => g.state == GameState.live).toList();
    final results = await matcher.matchDay(live, picks, includeGuide: false);
    for (final game in live) {
      final matches = results[SportsChannelPicks.eventKey(game)]!;
      // This older playlist cannot prove today's rotating event slots.
      // Keep the audit reproducible without ever retrieving provider data.
      // ignore: avoid_print
      print('${game.league.shortName}: ${game.title}: '
          '${matches.map((m) => '${m.reason.name}: ${m.channel.name}').join(' | ')}');
      expect(
          matches.every((m) =>
              m.reason != MatchReason.sport && m.reason != MatchReason.league),
          true);
    }
  },
      skip: labels.isEmpty
          ? 'Optional sanitized offline playlist labels.'
          : false);
}
