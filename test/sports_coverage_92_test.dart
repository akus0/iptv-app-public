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
import 'package:nox_iptv/services/sports_match_inputs.dart';
import 'package:nox_iptv/services/sports_service.dart';
import 'package:nox_iptv/services/sports_supplement_service.dart';
import 'package:nox_iptv/utils/replay_event_date.dart';
import 'package:nox_iptv/services/sports_replay_service.dart';
import 'package:nox_iptv/services/storage_service.dart';
import 'package:nox_iptv/utils/combat_sports.dart';
import 'package:nox_iptv/utils/extended_sports.dart';
import 'package:nox_iptv/utils/guide_enrichment.dart';
import 'package:nox_iptv/utils/constants.dart';

final now = DateTime.utc(2026, 10, 24, 16);

class Guide extends EpgService {
  Guide(super.storage);
  final rows = <String, EpgProgram>{};
  final nextRows = <String, EpgProgram>{};
  @override
  EpgProgram? getCurrentProgram(String id) => rows[normalizeEpgId(id)];
  @override
  EpgProgram? getNextProgram(String id) => nextRows[normalizeEpgId(id)];
  @override
  Future<List<EpgProgram>> findProgrammesByTitle(
          DateTime from, DateTime to, List<String> terms, {List<String>? channelIds}) async =>
      rows.values.toList();
  @override
  Iterable<EpgProgram> cachedCurrentProgrammes(DateTime at) => rows.values;
  @override
  Future<List<EpgProgram>> findSportsProgrammesForChannels(
          List<String> ids, DateTime from, DateTime to) async =>
      rows.values.toList();
}

class Picks implements SportsMatchPicks {
  @override
  String? channelIdFor(SportsGame game) => null;
}

Channel channel(String id, String name) => Channel(
    id: 'p::$id',
    rawId: id,
    playlistId: 'p',
    name: name,
    group: 'Sports',
    url: '',
    epgIdOverride: id);
EpgProgram programme(String id, String title,
        {String? description, bool live = false, DateTime? start}) =>
    EpgProgram(
        channelId: id,
        title: title,
        description: description,
        isLive: live,
        start: start ?? now.subtract(const Duration(minutes: 30)),
        stop: now.add(const Duration(hours: 2)));
SportsGame card() => SportsGame(
    id: '333',
    league: sportsLeagueById('mma.ufc')!,
    start: now.subtract(const Duration(hours: 2)),
    state: GameState.live,
    statusText: 'Live',
    home: const SportsTeam(
        id: 'a',
        name: 'Alexander Volkanovski',
        shortName: 'Volkanovski',
        abbreviation: 'AV'),
    away: const SportsTeam(
        id: 'b',
        name: 'Movsar Evloev',
        shortName: 'Evloev',
        abbreviation: 'ME'),
    event: const SportsEventInfo(title: 'UFC 333: Volkanovski vs. Evloev'));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late StorageService storage;
  late Guide guide;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    storage = StorageService();
    await storage.init();
    guide = Guide(storage);
  });
  tearDown(() => guide.dispose());

  test(
      'coverage upgrade enables Championship/UFC/PFL once, retains later choices',
      () async {
    expect(savedSportsLeagues(storage).map((l) => l.id),
        containsAll(['eng.2', 'mma.ufc', 'mma.pfl']));
    expect(storage.getSportsChannelFilter(), 'possible');
    await storage.setSportsLeagues(['eng.1']);
    await storage.setSportsChannelFilter('matched');
    final restored = StorageService();
    await restored.init();
    expect(restored.getSportsLeagues(), ['eng.1']);
    expect(restored.getSportsChannelFilter(), 'matched');
    await restored.setActiveViewerId('second');
    expect(restored.getSportsChannelFilter(), 'possible');
    expect(restored.getSportsLeagues(), contains('eng.2'));
  });

  test('upgrade retains existing league order and bank additions', () async {
    SharedPreferences.setMockInitialValues({
      AppConstants.keySportsLeagues: ['tennis.atp', 'eng.3'],
      AppConstants.keySportsAddedLeagues: ['tennis.atp', 'eng.3']
    });
    final existing = StorageService();
    await existing.init();
    expect(existing.getSportsLeagues()!.take(2), ['tennis.atp', 'eng.3']);
    expect(savedSportsLeagues(existing).map((l) => l.id),
        containsAll(['tennis.atp', 'eng.3', 'eng.2', 'mma.ufc']));
  });

  for (final background in [false, true]) {
    test(
        '${background ? 'worker' : 'direct'} numbered UFC prelim guide is confirmed; wrong cards/replays are not',
        () async {
      guide.rows.addAll({
        'right': programme('right', 'UFC 333 Prelims', live: true),
        'wrong':
            programme('wrong', 'UFC 332: Volkanovski vs. Evloev', live: true),
        'repeat': programme('repeat', 'UFC 333 Replay'),
        'generic': programme('generic', 'UFC live coverage', live: true),
        'other': programme('other', 'UFC 333 and UFC 332 Highlights'),
      });
      final matcher = background
          ? SportsChannelMatcher.background(guide, clock: () => now)
          : SportsChannelMatcher(guide, clock: () => now);
      addTearDown(matcher.dispose);
      await matcher.prepare(
          [for (final id in guide.rows.keys) channel(id, 'Sports $id')]);
      final found = await matcher
          .matchDay([card()], Picks(), includePossible: true, limit: 20);
      final matches = found.values.single;
      expect(matches.where((m) => m.isConfident).map((m) => m.channel.rawId),
          ['right']);
      expect(matches.where((m) => m.channel.rawId == 'wrong'), isEmpty);
      expect(combatCardIdentity(card().event!.title), 'ufc 333');
    });
  }

  test('prelim status repairs a pending headline card using actual bout status',
      () async {
    Map<String, dynamic> status(String state) => {
          'type': {'state': state, 'shortDetail': state}
        };
    Map<String, dynamic> bout(String id, String state, List<String> names) => {
          'id': id,
          'date': '2026-10-24T14:00Z',
          'status': status(state),
          'competitors': [
            for (final name in names)
              {
                'athlete': {'id': name, 'displayName': name}
              }
          ]
        };
    final client = MockClient((_) async => http.Response(
        jsonEncode({
          'events': [
            {
              'id': '333',
              'name': 'UFC 333: Volkanovski vs. Evloev',
              'date': '2026-10-24T14:00Z',
              'status': status('pre'),
              'competitions': [
                bout('prelim', 'in', ['First Fighter', 'Second Fighter']),
                bout('main', 'pre', ['Alexander Volkanovski', 'Movsar Evloev'])
              ]
            }
          ]
        }),
        200));
    addTearDown(client.close);
    final games = await SportsService.withClient(client)
        .replayGames(sportsLeagueById('mma.ufc')!, now);
    expect(games.single.state, GameState.live);
    expect(games.single.home.name, contains('Volkanovski'));
    expect(games.single.start, DateTime.utc(2026, 10, 24, 14));
  });

  test(
      'combat guide fallbacks require live evidence and keep promotion filters',
      () async {
    final titles = {
      'one': 'ONE Friday Fights 176',
      'muay': 'Rajadamnern World Series Muay Thai',
      'boxing': 'Boxing: Smith vs Jones',
      'contender': "Dana White's Contender Series",
      'repeat': 'ONE Friday Fights 175 Replay',
      'old': 'GLORY 78'
    };
    for (final e in titles.entries) {
      guide.rows[e.key] =
          programme(e.key, e.value, live: !['repeat', 'old'].contains(e.key));
    }
    final matcher = SportsChannelMatcher(guide, clock: () => now);
    addTearDown(matcher.dispose);
    await matcher.prepare(
        [for (final e in titles.entries) channel(e.key, 'Sports ${e.key}')]);
    final games = await matcher.discoverGuideEvents();
    expect(games, hasLength(4));
    expect(
        games.map((g) => g.league.id),
        containsAll(
            ['guide.one', 'guide.muay-thai', 'guide.boxing', 'guide.mma']));
    final matches = await matcher.matchDay(games, Picks());
    expect(matches.values.every((m) => m.length == 1 && m.single.isConfident),
        isTrue);
  });

  test(
      'card-only Fighting schedules survive without invented opponents and deduplicate UFC',
      () {
    final rows = [
      for (final (id, title, league) in [
        ('1', 'ONE Friday Fights 176', 'ONE'),
        ('2', 'UFC 333: Volkanovski vs. Evloev', 'UFC')
      ])
        {
          'idEvent': id,
          'idLeague': id,
          'strSport': 'Fighting',
          'strLeague': league,
          'strEvent': title,
          'strHomeTeam': null,
          'strAwayTeam': null,
          'strTimestamp': now.toIso8601String(),
          'strStatus': 'LIVE',
        }
    ];
    final parsed = parseSupplementGames(
        (rows, [sportsLeagueById('mma.ufc')!], now.toLocal()));
    expect(parsed, hasLength(2));
    expect(parsed.first.league.kind, SportsKind.broadcast);
    expect(parsed.first.title, 'ONE Friday Fights 176');
    final merged = mergeSupplementGames([card()], parsed);
    expect(merged, hasLength(2));
    expect(merged.first.id, '333');
  });

  test('relative replay date does not borrow a series premiere footer', () {
    final p = programme('nba', 'NBA Playback',
        description:
            'A look back at one of the best games in the NBA from the previous night. (Basketball) - 2025-11-17');
    expect(replayEventDate(p)?.isPossible, true);
    expect(replayEventDate(p)?.day, DateTime.utc(2026, 10, 23));
    expect(classifySportsReplay(p)?.evidence, ReplayEvidence.labelled);
  });

  test(
      'live-marked combat coverage appears before its guide slot, with exact next-channel binding',
      () async {
    guide.rows['one'] = programme('one', 'Sports news');
    guide.nextRows['one'] = programme('one', 'ONE Friday Fights 176',
        live: true, start: now.add(const Duration(minutes: 30)));
    final matcher = SportsChannelMatcher(guide, clock: () => now);
    addTearDown(matcher.dispose);
    await matcher.prepare([channel('one', 'Sports One')]);
    final games = await matcher.discoverGuideEvents();
    expect(games.single.state, GameState.pre);
    final matches = await matcher.matchDay(games, Picks());
    expect(matches.values.single.single.isConfident, isTrue);
    expect(
        matches.values.single.single.programme!.title, 'ONE Friday Fights 176');
  });

  test('poker table descriptions work on dedicated channels, not films/ads',
      () {
    expect(
        extendedGuideSport(
            'Jeju', 'The final table of the NLH tournament with eight players.',
            channelName: 'Triton Poker'),
        'poker');
    expect(
        extendedGuideSport('Jeju', 'Coming soon on our 24/7 channel',
            channelName: 'Triton Poker'),
        isNull);
    expect(
        extendedGuideSport('Poker Night', 'A horror movie about a detective.',
            channelName: 'PokerGO'),
        isNull);
    for (final name in [
      'Pokergo',
      'World Poker Tour',
      'Triton Poker',
      'Glory Kickboxing',
      'Tennis Channel'
    ]) {
      final c = Channel(
          id: name,
          rawId: 'feed.us',
          playlistId: 'p',
          name: name,
          group: 'Sports',
          url: '');
      expect(
          guideEnrichmentMatch(c)?.supplementalId, startsWith('iptv-fill-us:'));
    }
  });

  test(
      'replays include yesterday after overnight margin, not ongoing overnight games',
      () {
    final p = programme('a', 'NBA: Portland v Sacramento',
        description: 'From Oct. 23, 2026. (Basketball)');
    expect(classifySportsReplay(p)?.evidence, ReplayEvidence.historical);
    final early = programme('a', 'NBA: Portland v Sacramento',
        description: 'From Oct. 23, 2026. (Basketball)',
        start: DateTime.utc(2026, 10, 24, 3));
    expect(classifySportsReplay(early), isNull);
    expect(
        classifySportsReplay(programme('a', 'Final Score : 24/10/2026',
            description: 'A round-up of results from the Premier League.')),
        isNull);
    expect(
        classifySportsReplay(programme('a', 'World Series in 30 - Game 1',
                description: 'Baseball from Oct. 23, 2026.'))
            ?.evidence,
        ReplayEvidence.labelled);
  });

  test('specific motorsport, rugby and combat highlights are recognised', () {
    for (final e in {
      'FIA World Endurance Championship': 'racing',
      'WXV: Black Ferns v France Ext. Hls': 'rugby',
      'UFC: Best of Alex Volkanovski': 'mma',
      '2022 Lacrosse Championship Replay': 'lacrosse'
    }.entries) {
      final p =
          programme('a', e.key, description: 'Highlights from the event.');
      expect(classifySportsHighlights(p)?.sport, e.value, reason: e.key);
    }
    expect(
        classifySportsHighlights(programme('a', 'Quick Pitch',
                description: 'All the highlights from Major League Baseball.'))
            ?.sport,
        'baseball');
  });
}
