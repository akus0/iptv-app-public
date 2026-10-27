import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:nox_iptv/services/sports_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:nox_iptv/models/channel.dart';
import 'package:nox_iptv/models/epg_program.dart';
import 'package:nox_iptv/models/sports.dart';
import 'package:nox_iptv/services/epg_service.dart';
import 'package:nox_iptv/services/sports_channel_matcher.dart';
import 'package:nox_iptv/services/sports_match_inputs.dart';
import 'package:nox_iptv/services/sports_replay_service.dart';
import 'package:nox_iptv/services/storage_service.dart';
import 'package:nox_iptv/utils/extended_sports.dart';
import 'package:nox_iptv/utils/motorsport_coverage.dart';
import 'package:nox_iptv/utils/sports_guide_coverage.dart';

class _Guide extends EpgService {
  _Guide(super.storage);
  final rows = <String, EpgProgram>{};
  int reads = 0;
  @override
  EpgProgram? getCurrentProgram(String id) {
    reads++;
    return rows[normalizeEpgId(id)];
  }

  @override
  EpgProgram? getNextProgram(String id) => null;
  @override
  Future<List<EpgProgram>> findProgrammesByTitle(
          DateTime from, DateTime to, List<String> terms,
          {List<String>? channelIds}) =>
      throw StateError('Guide discovery must not query SQL or a provider');
  @override
  Future<List<EpgProgram>> findSportsProgrammesForChannels(
          List<String> ids, DateTime from, DateTime to) =>
      throw StateError('Exact guide bindings must not run fuzzy queries');
}

class _Picks implements SportsMatchPicks {
  _Picks([this.id]);
  final String? id;
  @override
  String? channelIdFor(SportsGame game) => id;
}

class _RacingGuide extends _Guide {
  _RacingGuide(super.storage);
  @override
  Future<List<EpgProgram>> findProgrammesByTitle(
          DateTime from, DateTime to, List<String> terms,
          {List<String>? channelIds}) async =>
      const [];
  @override
  Future<List<EpgProgram>> findSportsProgrammesForChannels(
          List<String> ids, DateTime from, DateTime to) async =>
      const [];
}

Channel _channel(String id, {String? epg, String? name}) => Channel(
    id: 'p::$id',
    rawId: id,
    playlistId: 'p',
    name: name ?? 'TV $id',
    group: 'TV',
    url: 'https://example.test/$id',
    epgIdOverride: epg ?? id);
final _now = DateTime.utc(2026, 10, 24, 12);
EpgProgram _programme(String id, String title,
        {String? description, bool live = false, DateTime? stop}) =>
    EpgProgram(
        channelId: id,
        title: title,
        description: description,
        isLive: live,
        start: _now.subtract(const Duration(minutes: 30)),
        stop: stop ?? _now.add(const Duration(minutes: 30)));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Guide guide;
  late StorageService storage;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    storage = StorageService();
    await storage.init();
    guide = _Guide(storage);
  });
  tearDown(() => guide.dispose());

  for (final background in [false, true]) {
    test('studio and recap programmes are not live events ($background)',
        () async {
      final rejected = [
        'F1 Paddock Live Pre Gara',
        'F1 Paddock Live',
        'Live Supercars Recap',
        'Live F1: Post-race',
        'Live F1: Ted’s Notebook',
        'Live WEC: Race Review',
        'X Games Highlights',
        'Billiards Roundup',
      ];
      final kept = [
        'Live F1: Mexico Grand Prix Race',
        'Live Supercars: Race 2',
        'Live WEC: Free Practice',
        'X Games - Shanghai',
        'World Poker Tour',
        'World Snooker Tour',
      ];
      for (final (i, title) in [...rejected, ...kept].indexed) {
        guide.rows['coverage$i'] =
            _programme('coverage$i', title, live: i < rejected.length + 3);
      }
      // A stale LIVE flag must not override an explicit highlights synopsis.
      guide.rows['summary'] = _programme('summary', 'X Games',
          live: true, description: 'Highlights from the X Games in Shanghai.');
      guide.rows['story'] = _programme('story', 'Surfing: A champion',
          description: 'The story of a surfing champion and his career.');
      guide.rows['documentary'] = _programme('documentary', 'X Games',
          description: 'A documentary about the BMX competition.');
      final matcher = background
          ? SportsChannelMatcher.background(guide, clock: () => _now)
          : SportsChannelMatcher(guide, clock: () => _now);
      addTearDown(matcher.dispose);
      await matcher.prepare([for (final id in guide.rows.keys) _channel(id)]);
      expect((await matcher.discoverGuideEvents()).map((g) => g.title),
          unorderedEquals(kept));
      final recap = _programme('recap', 'Supercars Recap', live: true);
      expect(classifySportsHighlights(recap)?.sport, 'racing');
      expect(classifySportsHighlights(guide.rows['summary']!)?.sport,
          'action-sports');
      expect(
          classifySportsHighlights(_programme(
              'race', 'Live F1: Mexico Grand Prix Race',
              live: true,
              description:
                  'Live coverage of the race, with highlights from qualifying.')),
          isNull);
    });
  }

  for (final worker in [false, true]) {
    test(
        '${worker ? 'worker' : 'direct'}: combat simulcasts attach to scored card and keep all picker channels',
        () async {
      final rows = _RacingGuide(storage);
      addTearDown(rows.dispose);
      var now = _now;
      for (var i = 0; i < 12; i++) {
        rows.rows['$i'] = _programme('$i',
            i.isEven ? 'Live UFC 333 Prelims HD' : 'UFC 333 Preliminary Fights',
            description: 'Live event coverage on broadcaster $i.',
            live: true,
            stop: _now.add(Duration(minutes: i == 0 ? 30 : 60)));
      }
      rows.rows['other'] = _programme('other', 'UFC 334 Prelims', live: true);
      final matcher = worker
          ? SportsChannelMatcher.background(rows, clock: () => now)
          : SportsChannelMatcher(rows, clock: () => now);
      addTearDown(matcher.dispose);
      await matcher.prepare([for (final id in rows.rows.keys) _channel(id)]);
      final discovered = await matcher.discoverGuideEvents();
      expect(discovered, hasLength(2));
      final broadcast =
          discovered.singleWhere((g) => g.guideProgrammes.length == 12);
      final score = SportsGame(
          id: 'score',
          league: sportsLeagueById('mma.ufc')!,
          start: _now,
          state: GameState.live,
          statusText: 'Round 2',
          home: broadcast.home,
          away: broadcast.away,
          event: const SportsEventInfo(title: 'UFC 333'));
      final merged = mergeSportsGuideCoverage([score], discovered);
      expect(merged, hasLength(2));
      final card = merged.singleWhere((g) => g.id == 'score');
      expect(card.guideProgrammes, hasLength(12));
      final short = (await matcher.matchDay([card], _Picks())).values.single;
      expect(short, hasLength(8));
      final all = await matcher.alternativesFor(card, matches: short);
      expect(all.where((m) => m.isConfident), hasLength(12));
      expect(
          all
              .where((m) => m.isConfident)
              .any((m) => m.channel.rawId == 'other'),
          isFalse);
      now = _now.add(const Duration(minutes: 31));
      final current =
          (await matcher.matchDay([card], _Picks(), limit: 30)).values.single;
      expect(current.where((m) => m.isConfident), hasLength(11));
      expect(
          current
              .where((m) => m.isConfident)
              .any((m) => m.channel.rawId == '0'),
          isFalse);
      matcher.dispose();
    });
  }

  for (final worker in [false, true]) {
    test(
        '${worker ? 'worker' : 'direct'}: combined motorsport keeps all channels and expires individual slots',
        () async {
      final racing = _RacingGuide(storage);
      addTearDown(racing.dispose);
      var now = _now;
      for (var i = 0; i < 12; i++) {
        racing.rows['$i'] = _programme(
            '$i',
            i.isEven
                ? 'Live F1 Mexico Grand Prix Race'
                : 'Formula One Mexican GP',
            description: 'Broadcast $i',
            live: true,
            stop: _now.add(Duration(minutes: i == 0 ? 10 : 60)));
      }
      final matcher = worker
          ? SportsChannelMatcher.background(racing, clock: () => now)
          : SportsChannelMatcher(racing, clock: () => now);
      addTearDown(matcher.dispose);
      await matcher.prepare([
        for (var i = 0; i < 12; i++)
          _channel('$i', name: i == 11 ? 'F1 Driver Tracker' : 'Race TV $i')
      ]);
      final games = await matcher.discoverGuideEvents();
      expect(games, hasLength(1));
      final all = await matcher.alternativesFor(games.single);
      expect(all, hasLength(12));
      expect(all.first.isConfident, isTrue);
      expect(all.last.channel.rawId, '11');
      expect(all.last.isConfident, isFalse);
      final main = SportsGame(
          id: 'score',
          league: sportsLeagueById('racing.f1')!,
          start: _now,
          end: _now.add(const Duration(hours: 2)),
          state: GameState.live,
          statusText: 'Lap 10',
          home: games.single.home,
          away: games.single.away,
          event: const SportsEventInfo(
              title: 'Mexico City Grand Prix', session: 'Race'));
      final merged = mergeMotorsportCoverage([main], games);
      expect(merged, hasLength(1));
      final matches = (await matcher.matchDay(merged, _Picks())).values.single;
      expect(matches, hasLength(8));
      expect(
          matches.every((m) => m.isConfident && m.programme != null), isTrue);
      final alternatives =
          await matcher.alternativesFor(merged.single, matches: matches);
      expect(alternatives, hasLength(12));
      expect(alternatives.where((m) => m.isConfident), hasLength(11));
      now = _now.add(const Duration(minutes: 11));
      final expired =
          (await matcher.matchDay(merged, _Picks(), limit: 30)).values.single;
      expect(
          expired.any((m) => m.channel.rawId == '0' && m.isConfident), isFalse);
      expect(expired.where((m) => m.isConfident), hasLength(10));
      matcher.dispose();
    });
  }

  test(
      'guide leagues survive upgrades, respect hiding, and make no score requests',
      () async {
    await storage.setSportsLeagues(['mlb']);
    expect(savedSportsLeagues(storage).map((l) => l.id),
        containsAll(['guide.npb', 'guide.kbo', 'guide.cpbl', 'rugby.live']));
    await storage.setHiddenGuideLeagues(['guide.kbo']);
    expect(savedSportsLeagues(storage).map((l) => l.id),
        isNot(contains('guide.kbo')));
    var requests = 0;
    final client = MockClient((request) async {
      requests++;
      throw StateError('Guide-only leagues must never query ESPN');
    });
    addTearDown(client.close);
    final service = SportsService.withClient(client);
    expect(await service.gamesForDay(kGuideSportsLeagues, _now), isEmpty);
    expect(service.lastError, isNull);
    expect(await service.replayGames(kGuideSportsLeagues.first, _now), isEmpty);
    expect(requests, 0);
    final all = [...kSportsLeagues, ...kSportsLeagueBank];
    expect(all.map((l) => l.id).toSet().length, all.length);
    expect(kSportsLeagueBank.where((l) => l.region == 'Rugby').length, 15);
  });

  for (final background in [false, true]) {
    test(
        'motorsport supports: exact channel evidence, no replay guesses ($background)',
        () async {
      final titles = [
        'Supercars : Gold Coast Supports (KAYO) ᴸᶦᵛᵉ',
        'Live Porsche Carrera Cup Australia: Race 2',
        'Live Aussie Racing Cars: Race 4',
        'Live Formula 2: Feature Race',
        'Live Formula 3: Sprint Race',
        'Live GT World Challenge: Race 2',
        'Live WEC: 8 Hours of Bahrain',
        'Live V8 SuperUtes: Race 3',
        'Supercars Gold Coast Supports replay',
        'Live Porsche road test',
        'Live Horse Racing',
        'GT3 Highlights',
        'Formula 2: Feature Race', // no live evidence: may be a replay
        'Live Supercars: Gold Coast 500', // explicit replay synopsis
      ];
      for (var i = 0; i < titles.length; i++) {
        guide.rows['motor$i'] = _programme('motor$i', titles[i],
            description: i == 0
                ? 'Porsche Carrera Cup Race 2; Aussie Racing Cars Race 4.'
                : i == 13
                    ? 'A replay of yesterday’s race.'
                    : '');
      }
      final channels = [
        for (var i = 0; i < titles.length; i++) _channel('motor$i'),
        _channel('variant', epg: 'motor0'),
        _channel('wrong', name: 'Supercars supports'),
      ];
      final matcher = background
          ? SportsChannelMatcher.background(guide, clock: () => _now)
          : SportsChannelMatcher(guide, clock: () => _now);
      addTearDown(matcher.dispose);
      await matcher.prepare(channels);
      final games = await matcher.discoverGuideEvents();
      expect(games.map((g) => g.title), unorderedEquals(titles.take(8)));
      expect(
          games.every((g) =>
              g.league.espnPath.startsWith('racing/') &&
              g.statusText == 'Live · guide'),
          isTrue);
      final support = games.singleWhere((g) => g.title == titles.first);
      final matches =
          await matcher.matchDay([support], _Picks(), includePossible: true);
      expect(matches.values.single.map((m) => m.channel.rawId),
          unorderedEquals(['motor0', 'variant']));
      expect(matches.values.single.every((m) => m.isConfident), isTrue);
      final reads = guide.reads;
      await matcher.discoverGuideEvents();
      expect(guide.reads, reads, reason: 'No rescanning an unchanged guide');
    });
  }

  test('motorsport may be in a competitive synopsis, never a bare car brand',
      () {
    expect(
        extendedGuideSport('Gold Coast Supports',
            'Live coverage of Porsche Carrera Cup and Aussie Racing Cars.'),
        'racing');
    expect(
        extendedGuideSport('Road test', 'Driving a new Porsche on the road.'),
        isNull);
    expect(extendedGuideSport('Live horse racing', 'Race coverage from Ascot.'),
        isNull);
  });

  test('rugby competition detection keeps unrelated leagues and shows out', () {
    final cases = {
      'NRL: Panthers vs Storm': 'nrl',
      'NRLW: Broncos vs Roosters': 'nrlw',
      "NRL Women: Broncos vs Roosters": 'nrlw',
      'Betfred Super League: Wigan vs Leeds': 'super-league',
      'Super Rugby Pacific: Blues vs Chiefs': 'super-rugby',
      'Bunnings NPC: Canterbury vs Waikato': 'npc',
      'Gallagher Prem: Bath vs Bristol': 'premiership',
      'Top 14: Toulouse vs Toulon': 'top14',
      'URC: Leinster vs Munster': 'urc',
      'Japan Rugby League One': 'league-one',
      'Currie Cup: Sharks vs Bulls': 'currie-cup',
      'Autumn Nations: England vs Australia': 'internationals',
    };
    expect(
        rugbyGuideCompetition('United Rugby Championship: Bulls v Lions', ''),
        'urc');
    expect(
        extendedGuideSport('This is TNT Sports Ultimate',
            'Home of Champions League and Gallagher Premiership coverage'),
        isNull);
    expect(
        extendedGuideSport('UEFA Europa League: Plzen v Levski', '',
            channelName: 'AU STAN | Bath v Bristol PREM Rugby'),
        isNull);
    for (final e in cases.entries) {
      expect(extendedGuideSport(e.key, ''), 'rugby', reason: e.key);
      expect(rugbyGuideCompetition(e.key, ''), e.value, reason: e.key);
    }
    for (final title in [
      'Super League: Basel vs Young Boys',
      'Premiership: Celtic vs Rangers',
      'Champions Cup: Soccer',
      'NRL News',
      'Rugby documentary'
    ]) {
      expect(extendedGuideSport(title, ''), isNull, reason: title);
    }
    expect(
        extendedGuideSport('Sharks vs Bulls', '',
            channelName: 'Sky Sport Rugby'),
        'rugby');
    expect(
        extendedGuideSport('Sharks vs Bulls', '', channelName: 'Sky Sport 1'),
        isNull);
  });

  for (final background in [false, true]) {
    test(
        '${background ? "worker" : "direct"}: rugby and cricket guide programmes never create live fixtures',
        () async {
      guide.rows['nrl'] =
          _programme('nrl', 'NRL: Panthers vs Storm', live: true);
      guide.rows['urc'] =
          _programme('urc', 'URC: Leinster vs Munster', live: true);
      guide.rows['cricket'] =
          _programme('cricket', 'Cricket: Australia vs India', live: true);
      guide.rows['future'] = _programme(
          'future', 'STAN | Bath v Bristol PREM Rugby (2026-11-01 05:40:15)');
      guide.rows['old'] = _programme('old', 'Replay: NRL Panthers vs Storm');
      final matcher = background
          ? SportsChannelMatcher.background(guide, clock: () => _now)
          : SportsChannelMatcher(guide, clock: () => _now);
      addTearDown(matcher.dispose);
      await matcher.prepare([for (final id in guide.rows.keys) _channel(id)]);
      final games = await matcher.discoverGuideEvents();
      expect(games, isEmpty);
    });
  }

  test(
      'extended sport vocabulary needs programme evidence, not incidental fiction',
      () {
    for (final entry in {
      'World Poker Tour': 'poker',
      'High Stakes Poker': 'poker',
      'PDC European Championship Darts': 'darts',
      'Counter-Strike: BLAST Premier': 'esports',
      'X Games': 'action-sports',
      'Street League Skateboarding': 'action-sports',
      'Northern Ireland Open Snooker': 'billiards',
      'PBA Tour Bowling': 'bowling',
      'BWF Badminton': 'badminton',
      'World Table Tennis': 'table-tennis',
    }.entries) {
      expect(extendedGuideSport(entry.key, ''), entry.value, reason: entry.key);
    }
    expect(extendedGuideSport('Poker Night', '(Sports, Cards)'), 'poker');
    expect(
        extendedGuideSport(
            'Cash Cab',
            'Unsuspecting members of the public climb into a taxicab for a chance to win. '
                '(Game show, Motorsports, Action sports, Esports) - 2012-04-21'),
        isNull);
    expect(
        extendedGuideSport('Sports quiz show',
            'Players compete with questions about darts and esports.'),
        isNull);
    for (final title in [
      'Poker Face',
      'Kill the Poker Player',
      'Poker Night',
      'Poker documentary',
      'Valorant review',
      'BMX tutorial',
      'Esports news'
    ]) {
      expect(extendedGuideSport(title, ''), isNull, reason: title);
    }
    expect(
        extendedGuideSport('Kill the Poker Player',
            'Two robbers search for stolen money. (Classic tv) - 1972'),
        isNull);
    expect(
        extendedGuideSport('The Upper Hand',
            'Caroline offers to host Charlie’s monthly poker game.'),
        isNull);
    expect(extendedGuideSport('Crime scene', 'The detective plays darts.'),
        isNull);
    expect(
        extendedGuideSport(
            'The Masters', 'Live coverage of the snooker tournament.'),
        'billiards');
  });

  for (final background in [false, true]) {
    test(
        '${background ? "worker" : "direct"}: exact mappings, variants, cache, manual picks and expiry',
        () async {
      var now = _now;
      guide.rows['poker'] =
          _programme('POKER', 'World Poker Tour', description: 'Final table.');
      guide.rows['darts'] =
          _programme('darts', 'European Championship Darts', live: true);
      final channels = [
        for (var i = 0; i < 12; i++) _channel('poker$i', epg: 'Poker'),
        _channel('darts'),
        _channel('other', name: 'World Poker Tour guesses'),
        _channel('header', epg: 'Poker', name: '### Poker'),
        _channel('xt_vod_1', epg: 'Poker'),
      ];
      final matcher = background
          ? SportsChannelMatcher.background(guide, clock: () => now)
          : SportsChannelMatcher(guide, clock: () => now);
      addTearDown(matcher.dispose);
      await matcher.prepare(channels);
      final games = await matcher.discoverGuideEvents();
      expect(games, hasLength(2));
      final poker = games.singleWhere((g) => g.league.id == 'guide.poker');
      expect(poker.title, 'World Poker Tour');
      expect(poker.isOnAirOnly, isTrue);
      expect(games.singleWhere((g) => g.league.id == 'guide.darts').statusText,
          'Live · guide');
      expect(poker.withOnlineBroadcasts([]).guideProgrammes,
          poker.guideProgrammes);
      final reads = guide.reads;
      for (var i = 0; i < 5; i++) {
        expect((await matcher.discoverGuideEvents()).map((g) => g.id),
            games.map((g) => g.id));
      }
      expect(guide.reads, reads,
          reason: 'Repeated polls reuse the snapshot/discovery');
      final matches =
          await matcher.matchDay(games, _Picks(), includePossible: true);
      final top = matches[SportsChannelPicks.eventKey(poker)]!;
      expect(top, hasLength(8));
      expect(top.every((m) => m.reason == MatchReason.guide && m.isConfident),
          isTrue);
      expect(
          identical(top.first.channel,
              channels.firstWhere((c) => c.id == top.first.channel.id)),
          isTrue);
      final all = await matcher.alternativesFor(poker, matches: top);
      expect(all, hasLength(12));
      expect(all.any((m) => m.channel.rawId == 'other'), isFalse);
      final manual = await matcher.matchDay([poker], _Picks('p::poker9'));
      expect(manual.values.single.first.channel.id, 'p::poker9');
      expect(
          (await matcher.alternativesFor(poker, matches: manual.values.single)),
          hasLength(12));
      now = _now.add(const Duration(minutes: 31));
      expect(await matcher.discoverGuideEvents(), isEmpty);
      expect(
          (await matcher.matchDay([poker], _Picks())).values.single, isEmpty);
    });
  }

  test('no placeholders, expired slots or explicitly recorded poker events',
      () async {
    final titles = [
      'Poker Face',
      'PDC Darts TV',
      'X Games 2024',
      'Poker replay: WSOP Final Table',
      'X Games highlights',
      'Darts coming soon',
      'PDC Darts: event ended',
      'PDC Board: Dutch Darts Championship stop:2026-10-18 23:00:00',
      'Poker Night',
      'US (ESPN+ 170) | Surfing: WSL Championship Tour (2026-10-25 02:30:00)',
      'Poker Masters \$2000 NL Holdem Final Table',
      'World Poker Tour',
    ];
    final channels = [
      for (var i = 0; i < titles.length; i++)
        _channel('$i', name: i == 1 ? titles[i] : null)
    ];
    for (var i = 0; i < titles.length; i++) {
      guide.rows['$i'] = _programme('$i', titles[i]);
    }
    final matcher = SportsChannelMatcher(guide, clock: () => _now);
    await matcher.prepare(channels);
    expect(
        (await matcher.discoverGuideEvents()).map((g) => g.title),
        unorderedEquals([
          'World Poker Tour',
          'Poker Masters \$2000 NL Holdem Final Table'
        ]));
  });

  test(
      'poker synopsis identifies coverage on general channels without broad plot matches',
      () {
    for (final (title, description, name) in [
      (
        'Bay 101 Shooting Stars',
        'From San Jose, California. (Card games, Poker)',
        'MASN'
      ),
      ('The Main Event', 'Las Vegas pros play poker.', 'CBS Sports Network'),
      (
        'The Final Table',
        "Live no-limit Texas hold'em action from Las Vegas.",
        'NBC Sports Boston'
      ),
      (
        'Choctaw: Part 2',
        'Coverage of the WPT final table, with interviews between hands.',
        'NESN'
      ),
      ('Weekend Tables', '${'x' * 605} (Poker)', 'CBS Sports Network'),
      ('Poker Night', '', 'Altitude Sports 2'),
      ('Poker Night', 'Poker Night', 'US | NBC Sports Philadelphia HD'),
    ]) {
      expect(extendedGuideSport(title, description, channelName: name), 'poker',
          reason: title);
    }
    for (final (title, description) in [
      (
        'The King of Queens',
        "Gambling N'Diction: Doug convinces his mum to enter a high-stakes poker tournament. (S8 Ep13/23)"
      ),
      (
        'Death in Paradise',
        'The team enter the high-stakes world of poker when a finalist is poisoned and the only suspects are the other players.'
      ),
      (
        'The Upper Hand',
        "Caroline offers to host Charlie's monthly poker game."
      ),
      (
        'A family night',
        'Poker players gather at the final table. (Comedy, Sitcom)'
      ),
      ('Poker Night', 'A detective is trapped by a murderer. (Movie, Horror)'),
      ('Poker interviews', 'Interview with poker players at the final table.'),
      ('NBA Basketball', 'A player enjoys poker action between games.'),
    ]) {
      expect(
          extendedGuideSport(title, description,
              channelName: 'CBS Sports Network'),
          isNull,
          reason: title);
    }
    expect(
        extendedGuideSport('Poker Night', '', channelName: 'A Movie Channel'),
        isNull);
  });

  for (final background in [false, true]) {
    test(
        '${background ? "worker" : "direct"}: general US guide poker keeps exact channels and does not need a supplemental feed',
        () async {
      guide.rows['masn'] = _programme('masn', 'Bay 101 Shooting Stars',
          description: 'From San Jose, California. (Card games, Poker)');
      guide.rows['cbs'] = _programme('cbs', 'The Main Event',
          description: 'Las Vegas pros play poker.', live: true);
      guide.rows['altitude'] = _programme('altitude', 'Poker Night');
      guide.rows['movie'] = _programme('movie', 'Poker Night',
          description: 'A detective is trapped by a murderer. (Movie, Horror)');
      final matcher = background
          ? SportsChannelMatcher.background(guide, clock: () => _now)
          : SportsChannelMatcher(guide, clock: () => _now);
      addTearDown(matcher.dispose);
      await matcher.prepare([
        _channel('masn', name: 'MASN'),
        _channel('cbs', name: 'CBS Sports Network'),
        _channel('altitude', name: 'Altitude Sports 2'),
        _channel('movie', name: 'Movies'),
        _channel('unrelated', name: 'World Poker Tour'),
      ]);
      final games = await matcher.discoverGuideEvents();
      expect(games, hasLength(3));
      final matches = await matcher.matchDay(games, _Picks());
      expect(matches.values.map((m) => m.single.channel.rawId).toSet(),
          {'masn', 'cbs', 'altitude'});
      expect(matches.values.every((m) => m.single.isConfident), true);
      expect(
          games
              .singleWhere((g) => g.title == 'Bay 101 Shooting Stars')
              .isOnAirOnly,
          true);
      expect(games.singleWhere((g) => g.title == 'The Main Event').isOnAirOnly,
          false);
      final reads = guide.reads;
      await matcher.discoverGuideEvents();
      expect(guide.reads, reads, reason: 'Same cached guide is reused');
    });
  }

  test('poker aliases, channel context and non-competition exclusions', () {
    expect(extendedGuideSport('WPT Choctaw: Part 2', ''), 'poker');
    expect(extendedGuideSport('Poker Go: Heads Up Showdown 2022', ''), 'poker');
    expect(extendedGuideSport('Poker Night', '(Poker) - 2018-03-07'), 'poker');
    expect(
        extendedGuideSport('Bahamas: \$250K NLH Invitational', '',
            channelName: 'US | Triton Poker HD'),
        'poker');
    expect(extendedGuideSport('Bahamas: \$250K NLH Invitational', ''), isNull);
    expect(
        extendedGuideSport(
            'An Interview With: Peter Jetten', 'One of Triton Poker’s players'),
        isNull);
    expect(
        extendedGuideSport('Poker Face', 'A crime drama.',
            channelName: 'Poker TV'),
        isNull);
    expect(
        extendedGuideSport(
            'Tour de France Route Presentation', 'Cycling coverage'),
        isNull);
    expect(extendedGuideSport('Roasted squash', 'Cooking a winter vegetable.'),
        isNull);
  });
  test(
      'a real poker episode may share the channel name; advertisements may not',
      () async {
    guide.rows['episode'] = _programme('episode', 'World Poker Tour',
        description: 'Six players contest the final table at WPT Choctaw.');
    guide.rows['advert'] = _programme('advert', 'PokerGO',
        description:
            'The home of poker tournaments, your non-stop poker channel.');
    final matcher = SportsChannelMatcher(guide, clock: () => _now);
    await matcher.prepare([
      _channel('episode', name: 'World Poker Tour'),
      _channel('advert', name: 'PokerGO')
    ]);
    final games = await matcher.discoverGuideEvents();
    expect(games, hasLength(1));
    expect(games.single.title, 'World Poker Tour');
    matcher.dispose();
  });
  test('existing cricket and cycling replay vocabulary remains available', () {
    for (final title in [
      'Replay: IPL Final',
      'Replay: T20 Final',
      'Replay: Vuelta Stage 5',
      'Replay: MLB Baseball',
      'Replay: FIH Pro League Field Hockey Final'
    ]) {
      expect(classifySportsReplay(_programme('a', title)), isNotNull,
          reason: title);
    }
  });
  for (final background in [false, true]) {
    test(
        '${background ? "worker" : "direct"}: poker and Asian baseball use exact airing channels, excluding known recordings',
        () async {
      final titles = {
        'old': 'Poker Go: 2021 Poker Masters',
        'classic': 'World Poker Tour - Aruba Poker Classic',
        'replay': 'Replay: WSOP Final Table',
        'alias': 'WPT Choctaw: Part 2',
        'npb': 'Nippon Professional Baseball',
        'kbo': 'KBO: LG Twins vs KIA Tigers',
        'cpbl': '中華職棒：統一獅 vs 中信兄弟',
        'local': '韓国プロ野球：KIA vs Samsung',
        'cricket': 'Cricket: Australia vs India',
        'netball': 'Suncorp Super Netball',
        'cycling': 'Cycling: Tour de France',
        'squash': 'PSA World Tour: Squash',
        'handball': 'Handball: Championship Final',
        'field': 'FIH Pro League: Field Hockey',
        'bad': 'No event: Poker Masters',
        'highlights': 'WPT Highlights',
        'stale': 'Poker PPV stop:2026-10-18 23:00:00',
      };
      for (final e in titles.entries) {
        guide.rows[e.key] =
            _programme(e.key, e.value, live: e.key == 'old' || e.key == 'kbo');
      }
      final matcher = background
          ? SportsChannelMatcher.background(guide, clock: () => _now)
          : SportsChannelMatcher(guide, clock: () => _now);
      addTearDown(matcher.dispose);
      await matcher.prepare([
        for (final id in titles.keys) _channel(id),
        _channel('guess', name: 'KBO Baseball Poker')
      ]);
      final games = await matcher.discoverGuideEvents();
      expect(games, hasLength(11));
      expect(games.where((g) => g.title == titles['cricket']), isEmpty);
      expect(games.where((g) => g.title == titles['old']), isEmpty);
      expect(games.where((g) => g.title == titles['replay']), isEmpty);
      expect(games.singleWhere((g) => g.title == titles['classic']).statusText,
          'On air');
      expect(games.where((g) => g.league.id == 'guide.kbo'), hasLength(2));
      expect(
          games.singleWhere((g) => g.league.id == 'guide.npb').league.espnPath,
          'baseball/guide');
      final matches = await matcher.matchDay(games, _Picks());
      for (final g in games) {
        final matched = matches[SportsChannelPicks.eventKey(g)]!;
        expect(matched, hasLength(1));
        expect(matched.single.isConfident, isTrue);
        expect(matched.single.programme!.title, g.title);
        expect(matched.single.channel.rawId, isNot('guess'));
      }
    });
  }

  test(
      'identical simultaneous broadcasts combine; different tables stay separate',
      () async {
    guide.rows['a'] =
        _programme('a', 'World Poker Tour', description: 'Table one');
    guide.rows['b'] =
        _programme('b', 'World Poker Tour', description: 'Table two');
    guide.rows['c'] =
        _programme('c', 'World Poker Tour', description: 'Table one');
    final matcher = SportsChannelMatcher(guide, clock: () => _now);
    await matcher.prepare([_channel('a'), _channel('b'), _channel('c')]);
    final games = await matcher.discoverGuideEvents();
    expect(games, hasLength(2));
    expect(games.map((g) => g.guideProgrammes.length).toList()..sort(), [1, 2]);
    final old = games.first;
    guide.rows.clear();
    guide.notifyListeners();
    expect(await matcher.discoverGuideEvents(), isEmpty);
    // Replacing the catalogue also invalidates discovery and exact matches.
    await matcher.prepare([_channel('new')]);
    expect(await matcher.discoverGuideEvents(), isEmpty);
    expect((await matcher.matchDay([old], _Picks())).values.single, isEmpty);
  });

  test('new sports also classify explicit replays and highlights', () {
    for (final title in [
      'World Poker Tour',
      'PDC Darts Championship',
      'Counter-Strike Final',
      'X Games BMX Final'
    ]) {
      expect(classifySportsReplay(_programme('a', 'Replay: $title')), isNotNull,
          reason: title);
      expect(classifySportsHighlights(_programme('a', '$title Highlights')),
          isNotNull,
          reason: title);
    }
    expect(classifySportsReplay(_programme('a', 'Poker Face Replay')), isNull);
  });

  test(
      '80k catalogue shares one guide index and warm discovery does zero reads',
      () async {
    final channels = [
      for (var i = 0; i < 80000; i++) _channel('$i', epg: '${i % 8000}')
    ];
    for (var i = 0; i < 8000; i++) {
      guide.rows['$i'] = _programme(
          '$i', i < 8 ? 'World Poker Tour' : 'Daily programme',
          description: i < 8 ? 'Table $i' : 'General entertainment');
    }
    final matcher = SportsChannelMatcher(guide, clock: () => _now);
    await matcher.prepare(channels);
    guide.reads = 0;
    final watch = Stopwatch()..start();
    expect(await matcher.discoverGuideEvents(), hasLength(8));
    final cold = watch.elapsedMicroseconds;
    expect(guide.reads, 8000);
    watch.reset();
    for (var i = 0; i < 100; i++) {
      await matcher.discoverGuideEvents();
    }
    expect(guide.reads, 8000);
    // ignore: avoid_print
    print(
        '80k catalogue: discovery ${cold / 1000}ms; 100 cached calls ${watch.elapsedMicroseconds / 1000}ms; zero SQL/network');
  });
}
