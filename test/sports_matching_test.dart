import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:nox_iptv/models/channel.dart';
import 'package:nox_iptv/models/epg_program.dart';
import 'package:nox_iptv/models/sports.dart';
import 'package:nox_iptv/services/epg_service.dart';
import 'package:nox_iptv/services/sports_channel_matcher.dart';
import 'package:nox_iptv/services/storage_service.dart';

class _Guide extends EpgService {
  _Guide(super.storage);
  List<EpgProgram> programmes = [];
  List<String> terms = [];
  int queries = 0;
  @override
  Future<List<EpgProgram>> findSportsProgrammesForChannels(
      List<String> ids, DateTime from, DateTime to) async {
    final feeds = ids.toSet();
    return programmes
        .where((p) =>
            feeds.contains(p.channelId) &&
            p.stop.isAfter(from) &&
            p.start.isBefore(to))
        .toList();
  }

  @override
  EpgProgram? getCurrentProgram(String id) => programmes
      .where((p) => p.channelId == id && p.isNowPlaying(DateTime.now()))
      .firstOrNull;
  @override
  EpgProgram? getNextProgram(String id) => programmes
      .where((p) => p.channelId == id && p.start.isAfter(DateTime.now()))
      .firstOrNull;
  @override
  Future<List<EpgProgram>> findProgrammesByTitle(
      DateTime from, DateTime to, List<String> terms, {List<String>? channelIds}) async {
    queries++;
    this.terms = terms;
    // Approximate SQLite retrieval as well as testing the final scorer. This
    // catches broadening the scorer but forgetting to retrieve its candidates.
    return programmes
        .where((p) =>
            p.stop.isAfter(from) &&
            p.start.isBefore(to) &&
            terms.any((t) => p.title.toLowerCase().contains(t.toLowerCase())))
        .toList();
  }
}

final _start = DateTime.utc(2026, 10, 10, 12);
SportsGame _game(
        {String id = 'match',
        String home = 'Yunchaokete Bu',
        String away = 'Casper Ruud',
        String league = 'tennis.atp',
        String tournament = 'Rolex Shanghai Masters',
        List<String> aliases = const [],
        List<String> broadcasts = const [],
        String? court,
        String? round}) =>
    SportsGame(
        id: id,
        league: sportsLeagueById(league)!,
        start: _start,
        state: GameState.live,
        statusText: 'Live',
        broadcasts: broadcasts,
        home: SportsTeam(
            id: 'home', name: home, shortName: home, abbreviation: ''),
        away: SportsTeam(
            id: 'away', name: away, shortName: away, abbreviation: ''),
        event: tournament.isEmpty
            ? null
            : SportsEventInfo(
                title: tournament,
                matchingNames: aliases,
                court: court,
                session: round));
Channel _channel(String id, String name, {String group = 'Sports'}) => Channel(
    id: 'test::$id',
    rawId: id,
    playlistId: 'test',
    name: name,
    group: group,
    url: 'https://example.invalid/never-opened');
EpgProgram _programme(String id, String title,
        {int offset = 0, int hours = 3}) =>
    EpgProgram(
        channelId: id,
        title: title,
        start: _start.add(Duration(hours: offset)),
        stop: _start.add(Duration(hours: offset + hours)));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Guide guide;
  late SportsChannelMatcher matcher;
  late SportsChannelPicks picks;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final storage = StorageService();
    await storage.init();
    guide = _Guide(storage);
    matcher = SportsChannelMatcher(guide);
    picks = SportsChannelPicks.load(storage);
  });
  tearDown(() => guide.dispose());
  Future<List<ChannelMatch>> match(SportsGame game, List<Channel> channels,
      {bool includeGuide = true, int limit = 20}) async {
    await matcher.prepare(channels);
    return (await matcher.matchDay([game], picks,
        includeGuide: includeGuide,
        limit: limit))[SportsChannelPicks.eventKey(game)]!;
  }

  test('tennis uses bounded synopsis for tournament and exact opponents',
      () async {
    guide.programmes = [
      EpgProgram(
          channelId: 'event',
          title: 'ATP Tennis',
          description: 'Live from Brussels. European Open on Court 2.',
          start: _start,
          stop: _start.add(const Duration(hours: 4))),
      EpgProgram(
          channelId: 'exact',
          title: 'ATP Tennis',
          description: 'European Open: Yunchaokete Bu vs Casper Ruud.',
          start: _start,
          stop: _start.add(const Duration(hours: 4))),
      EpgProgram(
          channelId: 'other',
          title: 'ATP Tennis',
          description: 'European Open: Jannik Sinner vs Novak Djokovic.',
          start: _start,
          stop: _start.add(const Duration(hours: 4))),
    ];
    final result = await match(
        _game(
            tournament: 'BNP Paribas Fortis European Open',
            aliases: ['Brussels']),
        [
          for (final id in ['event', 'exact', 'other'])
            _channel(id, 'Feed $id'),
        ]);
    expect(result.map((m) => m.channel.rawId), ['exact', 'event']);
    expect(result.first.reason, MatchReason.guide);
    expect(result.last.reason, MatchReason.tournament);
    expect(result.last.isConfident, false);
    expect(guide.queries, 1);
  });

  test('tennis rejects explicit wrong courts, rounds, doubles and juniors',
      () async {
    final result = await match(_game(court: 'Court 2', round: 'Semifinals'), [
      _channel('right', 'ATP Shanghai Court 2 Semifinal'),
      _channel('wrong-court', 'ATP Shanghai Court 1 Semifinal'),
      _channel('wrong-round', 'ATP Shanghai Court 2 Quarterfinal'),
      _channel('doubles', 'ATP Shanghai Doubles'),
      _channel('junior', 'Shanghai Tennis Juniors'),
      _channel('qualifier', 'ATP Shanghai Qualifying'),
      _channel('broad', 'ATP Shanghai Live'),
    ]);
    expect(result.map((m) => m.channel.rawId).toSet(), {'right', 'broad'});
    expect(result.first.channel.rawId, 'right');
  });

  test('different tournaments in the same batch cannot borrow coverage',
      () async {
    final shanghai = _game(),
        brussels = _game(
            id: 'brussels', tournament: 'European Open', aliases: ['Brussels']);
    await matcher.prepare([
      _channel('shanghai', 'ATP Shanghai Live'),
      _channel('brussels', 'ATP Brussels Live'),
      _channel('mixed', 'ATP Shanghai and Brussels Live')
    ]);
    final result = await matcher.matchDay([shanghai, brussels], picks);
    expect(
        result[SportsChannelPicks.eventKey(shanghai)]!
            .map((m) => m.channel.rawId)
            .toSet(),
        {'shanghai', 'mixed'});
    expect(
        result[SportsChannelPicks.eventKey(brussels)]!
            .map((m) => m.channel.rawId)
            .toSet(),
        {'brussels', 'mixed'});
  });

  test('tournament broadcast hints remain possible and cannot cross regions',
      () async {
    final result = await match(
        _game(broadcasts: ['Tennis Channel']).withOnlineBroadcasts(const [
          SportsBroadcast('Sky Sports Tennis',
              source: 'Sky Sports live schedule',
              country: 'United Kingdom',
              tournamentOnly: true),
        ]),
        [
          _channel('exact', 'Bu vs Ruud - ATP Shanghai'),
          _channel('uk', 'UK: Sky Sports Tennis HD'),
          _channel('de', 'DE: Sky Sports Tennis HD'),
          _channel('network', 'Tennis Channel'),
        ]);
    expect(result.first.channel.rawId, 'exact');
    final online = result.firstWhere((m) => m.channel.rawId == 'uk');
    expect(online.reason, MatchReason.tournament);
    expect(online.isConfident, false);
    expect(online.supportingBroadcasts, isNotEmpty);
    expect(result.firstWhere((m) => m.channel.rawId == 'network').isConfident,
        false);
    expect(
        result.firstWhere((m) => m.channel.rawId == 'de').supportingBroadcasts,
        isEmpty);
  });

  test('NHL network aliases retain region and exact channel identity',
      () async {
    final game = _game(
            league: 'nhl',
            tournament: '',
            home: 'Toronto Maple Leafs',
            away: 'Boston Bruins')
        .withOnlineBroadcasts(const [
      SportsBroadcast('SNO', source: 'NHL', country: 'Canada'),
    ]);
    final result = await match(
        game,
        [
          _channel('ontario', 'CA: Sportsnet Ontario HD',
              group: 'Canada Sports'),
          _channel('east', 'CA: Sportsnet East HD', group: 'Canada Sports'),
          _channel('foreign', 'US: Sportsnet Ontario HD', group: 'US Sports'),
        ],
        includeGuide: false);
    expect(
        result
            .where((m) => m.reason == MatchReason.listing)
            .map((m) => m.channel.rawId),
        ['ontario']);
  });
  test(
      'abbreviated highlights and synopsis-only replays cannot match live games',
      () async {
    final base = _game(tournament: '');
    final game = SportsGame(
        id: base.id,
        league: base.league,
        start: DateTime.now().subtract(const Duration(minutes: 20)),
        state: GameState.live,
        statusText: 'Live',
        home: base.home,
        away: base.away);
    for (final suffix in ['Hlts', 'Hls', 'H/L', 'Re-Air', 'Condensed']) {
      guide.programmes = [
        EpgProgram(
            channelId: 'feed',
            title: 'Tennis: Bu v Ruud $suffix',
            start: game.start,
            stop: game.start.add(const Duration(hours: 3)))
      ];
      guide.notifyListeners();
      final result = await match(game, [_channel('feed', 'Tennis: Bu v Ruud')]);
      expect(result, isEmpty, reason: suffix);
    }
    guide.programmes = [
      EpgProgram(
          channelId: 'feed',
          title: 'Tennis: Bu v Ruud',
          description: 'Highlights from the match in Shanghai.',
          start: game.start,
          stop: game.start.add(const Duration(hours: 3)))
    ];
    guide.notifyListeners();
    expect(await match(game, [_channel('feed', 'Sky Sports Tennis')]), isEmpty);
  });
  test(
      'event TV listings corroborate a region-matched channel without overriding saved or exact evidence',
      () async {
    final game = _game(tournament: '').withOnlineBroadcasts(const [
      SportsBroadcast('Sky Sports Tennis',
          source: 'TheSportsDB', country: 'United Kingdom'),
    ]);
    final channels = [
      _channel('uk', 'UK: Sky Sports Tennis HD', group: 'UK Sports'),
      _channel('us', 'US: Sky Sports Tennis HD', group: 'US Sports'),
      _channel('exact', 'Bu vs Ruud'),
    ];
    await matcher.prepare(channels);
    final matched = (await matcher.matchDay([game], picks, includeGuide: false))
        .values
        .single;
    final listed = matched.singleWhere((m) => m.channel.id == 'test::uk');
    expect(listed.reason, MatchReason.listing);
    expect(listed.supportingBroadcasts.single, contains('TheSportsDB'));
    expect(matched.first.channel.id, 'test::exact');
    expect(
        matched
            .where((m) => m.channel.id == 'test::us')
            .every((m) => m.reason != MatchReason.listing),
        true);
    await picks.pickForGame(game, 'test::us');
    final picked = (await matcher.matchDay([game], picks, includeGuide: false))
        .values
        .single;
    expect(picked.first.channel.id, 'test::us');
    expect(picked.first.reason, MatchReason.pick);
    final plain = (await matcher
            .matchDay([_game(tournament: '')], picks, includeGuide: false))
        .values
        .single;
    expect(plain.every((m) => m.supportingBroadcasts.isEmpty), true);
  });

  test('reversed player names outrank tournament coverage and dedicated tennis',
      () async {
    final result = await match(_game(), [
      _channel('sport', 'Sky Sports Tennis'),
      _channel('wrong',
          'Medvedev, Daniil vs Struff, Jan-Lennard @ Oct 10 - ATP Shanghai'),
      _channel('event', 'ATP 1000 Tennis: Shanghai vs Day #4 @ Oct 10'),
      _channel(
          'exact', 'Bu, Yunchaokete vs Ruud, Casper @ Oct 10 - ATP Shanghai'),
    ]);
    expect(result.map((m) => m.channel.rawId), ['exact', 'event', 'sport']);
    expect(result.map((m) => m.reason),
        [MatchReason.name, MatchReason.tournament, MatchReason.sport]);
  });

  test(
      'headers, unused slots, stale dates and unrelated tennis are not matches',
      () async {
    final result = await match(_game(), [
      _channel('header', '### TENNIS ATP ###'),
      _channel('empty', ':Tennis 28', group: 'Tennis'),
      _channel('old', 'Bu, Yunchaokete vs Ruud, Casper | 2026-09-20 | ATP'),
      _channel('oldNumeric', 'Shanghai ATP Tennis | 20-09-2026'),
      _channel('year', 'Bu, Yunchaokete vs Ruud, Casper | 2025-10-10'),
      _channel('table', 'Major League Table Tennis'),
      _channel('wta', 'WTA Shanghai Tennis'),
      _channel('college', 'College Tennis Live'),
      _channel('replay', 'ATP Shanghai Highlights'),
      _channel('end', 'End | ATP Shanghai Tennis | 10-10-2026'),
      _channel('offline', 'Tennis Channel Offline'),
      _channel('valid', 'Tennis Channel'),
    ]);
    expect(result.map((m) => m.channel.rawId), ['valid']);
    expect(matcher.search('ATP').any((c) => c.rawId == 'header'), isFalse);
  });

  test('full names, compound surnames, accents and three-letter surnames',
      () async {
    final result =
        await match(_game(home: 'Jiří Lehečka', away: 'Arthur Fils'), [
      _channel('exact', 'Lehecka, Jiri vs Fils, Arthur - ATP Shanghai'),
    ]);
    expect(result.single.reason, MatchReason.name);
    expect(sportsNormalize('Lehec\u030cka'), sportsNormalize('Lehečka'));
    final short =
        await match(_game(home: 'Ann Fox', away: 'Felix Auger-Aliassime'), [
      _channel('exact', 'Fox vs Auger-Aliassime - ATP Shanghai'),
    ]);
    expect(short.single.reason, MatchReason.name);
  });

  test('a shared surname cannot count as both opponents', () async {
    final result = await match(
        _game(
            home: 'Serena Williams',
            away: 'Venus Williams',
            league: 'tennis.wta'),
        [
          _channel('wrong', 'Williams vs Swiatek - WTA Tennis'),
          _channel('right', 'S. Williams vs V. Williams - WTA Tennis'),
        ]);
    expect(result.map((m) => m.channel.rawId), ['right']);
  });

  test('explicit full names rank ahead of surname-only listings', () async {
    final result = await match(
        _game(home: 'Juan Manuel Cerundolo', away: 'Carlos Alcaraz'), [
      _channel('surname', 'Cerundolo vs Alcaraz - ATP'),
      _channel('full', 'Cerundolo, Juan Manuel vs Alcaraz, Carlos - ATP'),
    ]);
    expect(result.first.channel.rawId, 'full');
    expect(result.first.score, greaterThan(result.last.score));
  });

  test('scoreboard short tournament names supplement sponsor titles', () async {
    final result = await match(
        _game(tournament: 'Sponsor Invitational', aliases: ['Shanghai']), [
      _channel('event', 'ATP Shanghai - Centre Court', group: 'Tennis'),
    ]);
    expect(result.single.reason, MatchReason.tournament);
    expect(
        SportsChannelMatcher.searchSuggestions(_game()),
        containsAll([
          'Yunchaokete Bu',
          'Ruud',
          'ATP',
          'Rolex Shanghai Masters',
          'shanghai',
          'tennis'
        ]));
  });

  test(
      'all-day guide coverage overlaps the match even when it began hours earlier',
      () async {
    guide.programmes = [
      _programme('coverage', 'ATP Shanghai Tennis: Centre Court',
          offset: -4, hours: 9)
    ];
    final result = await match(_game(), [_channel('coverage', 'Event Feed 1')]);
    expect(result.single.reason, MatchReason.tournament);
    expect(guide.terms, contains('shanghai'));
    expect(guide.queries, 1);
  });

  test('guide exact match outranks coverage and avoids later matches/replays',
      () async {
    guide.programmes = [
      _programme('exact', 'Bu, Yunchaokete vs Ruud, Casper'),
      _programme('coverage', 'ATP Shanghai Tennis'),
      _programme('later', 'ATP Shanghai Tennis', offset: 3),
      _programme('wrong', 'ATP Shanghai: Medvedev vs Struff'),
      _programme('replay', 'Replay: Bu vs Ruud - ATP Shanghai'),
    ];
    final result = await match(_game(), [
      for (final id in ['exact', 'coverage', 'later', 'wrong', 'replay'])
        _channel(
            id,
            id == 'wrong' || id == 'replay'
                ? 'Tennis Channel $id'
                : 'Feed $id'),
    ]);
    expect(result.map((m) => m.channel.rawId), ['exact', 'coverage']);
    expect(result.first.reason, MatchReason.guide);
  });

  test('guide disambiguates same tournament name across sports', () async {
    guide.programmes = [
      _programme('golf', 'US Open Golf'),
      _programme('tennis', 'US Open Tennis'),
    ];
    final result = await match(_game(tournament: 'US Open'), [
      _channel('golf', 'Golf Channel'),
      _channel('tennis', 'Tennis Channel'),
    ]);
    expect(result.map((m) => m.channel.rawId), ['tennis']);
  });

  test('known wrong live programme suppresses a broad channel fallback',
      () async {
    guide.programmes = [_programme('wrong', 'WTA Tennis: Beijing Final')];
    final result =
        await match(_game(), [_channel('wrong', 'Sky Sports Tennis')]);
    expect(result, isEmpty);
  });

  test('an explicit user pick still wins over automatic evidence', () async {
    final game = _game();
    await picks.pickForGame(game, 'test::picked');
    final result = await match(game, [
      _channel('picked', 'My channel'),
      _channel('exact', 'Bu vs Ruud - ATP Shanghai'),
    ]);
    expect(result.first.reason, MatchReason.pick);
    expect(result.first.channel.rawId, 'picked');
  });

  test('network quality variants match exactly without mixing ESPN and ESPN+',
      () async {
    final result = await match(
        _game(league: 'nhl', tournament: '', broadcasts: ['ESPN2']), [
      _channel('correct', 'US: ESPN 2 (720p)'),
      _channel('base', 'US: ESPN HD'),
      _channel('plus', 'ESPN+'),
      _channel('regional', 'ESPN 2 Extra'),
      _channel('foreign', 'FR: ESPN 2 HD'),
    ]);
    expect(result.map((m) => m.channel.rawId), ['correct']);
    expect(result.single.reason, MatchReason.network);
  });

  test('duplicate quality variants cannot consume all fallback choices',
      () async {
    final result = await match(
        _game(tournament: ''),
        [
          for (var i = 0; i < 12; i++)
            _channel('sky$i', 'Sky Sports Tennis 1080p50'),
          _channel('tc', 'Tennis Channel'),
          _channel('super', 'Supersport Tennis'),
        ],
        limit: 3);
    expect(result.map((m) => m.channel.rawId), containsAll(['tc', 'super']));
  });

  test('same-day coverage ranks above adjacent-day listings', () async {
    final result = await match(_game(), [
      _channel('next', 'ATP Shanghai Tennis Day 5 @ Oct 11'),
      _channel('today', 'ATP Shanghai Tennis Day 4 @ Oct 10'),
    ]);
    expect(result.first.channel.rawId, 'today');
    expect(result.first.score, greaterThan(result.last.score));
  });

  test('team, fight and racing exact matches remain above sport fallbacks',
      () async {
    for (final example in [
      (
        'nhl',
        'Boston Bruins',
        'Toronto Maple Leafs',
        'Boston Bruins vs Toronto Maple Leafs'
      ),
      ('mma.ufc', 'Brendan Allen', 'Chris Duncan', 'Allen vs Duncan UFC'),
    ]) {
      final result = await match(
          _game(
              league: example.$1,
              home: example.$2,
              away: example.$3,
              tournament: ''),
          [_channel('exact', example.$4)]);
      expect(result.single.reason, MatchReason.name);
    }
    final racing = await match(
        _game(
            league: 'racing.f1',
            tournament: 'Singapore Airlines Singapore Grand Prix'),
        [
          _channel('fallback', 'Sky Sports F1'),
          _channel('exact', 'Singapore Grand Prix - Race @ Oct 10'),
        ]);
    expect(racing.first.channel.rawId, 'exact');
  });
  test(
      'short surnames work in event names and the guide without losing the opponent',
      () async {
    guide.programmes = [_programme('guide', 'Bu vs Ruud')];
    final result = await match(_game(), [
      _channel('name', 'Bu vs Ruud - ATP Shanghai'),
      _channel('guide', 'Court 1'),
      _channel('other', 'Bu vs Sinner - ATP Shanghai'),
    ]);
    expect(result.map((m) => m.channel.rawId), ['guide', 'name']);
    expect(result.first.programme?.title, 'Bu vs Ruud');
  });

  test('correct-time guide evidence outranks name-only and later repeat slots',
      () async {
    guide.programmes = [
      _programme('guide', 'Yunchaokete Bu vs Casper Ruud'),
      _programme('later', 'Yunchaokete Bu vs Casper Ruud', offset: 3),
      _programme('ended', 'Yunchaokete Bu vs Casper Ruud',
          offset: -2, hours: 1),
      _programme('stale', 'Yunchaokete Bu vs Casper Ruud'),
    ];
    final result = await match(_game(), [
      _channel('name', 'Bu vs Ruud - ATP Shanghai'),
      _channel('guide', 'Court 1'),
      _channel('later', 'Court 2'),
      _channel('ended', 'Court 3'),
      _channel('stale', 'END: Court 4'),
    ]);
    expect(result.map((m) => m.channel.rawId), ['guide', 'name', 'later']);
    for (var i = 1; i < result.length; i++) {
      expect(result[i - 1].score, greaterThanOrEqualTo(result[i].score));
    }
  });

  test('live matching prefers the current slot over a programme that has ended',
      () async {
    final now = DateTime.now().toUtc();
    final game = SportsGame(
        id: 'live',
        league: sportsLeagueById('tennis.atp')!,
        start: now.subtract(const Duration(hours: 2)),
        state: GameState.live,
        statusText: 'Live',
        home: _game().home,
        away: _game().away);
    guide.programmes = [
      for (final id in ['ended', 'current'])
        EpgProgram(
            channelId: id,
            title: 'Bu vs Ruud Tennis',
            start: now.subtract(const Duration(hours: 2)),
            stop: now.add(Duration(hours: id == 'ended' ? -1 : 1)))
    ];
    final result = await match(
        game, [_channel('ended', 'Court 1'), _channel('current', 'Court 2')]);
    expect(result.map((m) => m.channel.rawId), ['current']);
  });

  test(
      'manual search finds mapped cached guide titles and invalidates on guide changes',
      () async {
    final now = DateTime.now();
    guide.programmes = [
      EpgProgram(
          channelId: 'mapped',
          title: 'Shanghai Tennis: Bu vs Ruud',
          start: now.subtract(const Duration(minutes: 20)),
          stop: now.add(const Duration(hours: 2)))
    ];
    final channel = _channel('feed', 'Centre Court')..epgIdOverride = 'mapped';
    await matcher.prepare([channel, _channel('header', '### Shanghai Tennis')]);
    final first = await matcher.searchWithGuide('Shanghai');
    expect(first.single.channel.id, channel.id);
    expect(first.single.programme?.title, contains('Bu vs Ruud'));
    expect(first.single.programmeSearchHit, isTrue);
    final nameOnly = await matcher.searchWithGuide('Centre');
    expect(nameOnly.single.channel.id, channel.id);
    expect(
        nameOnly.single.programme, isNull); // A name hit is not EPG evidence.
    expect(guide.queries, 0);
    final retained = await matcher.searchWithGuide('Centre', matches: [
      ChannelMatch(nameOnly.single.channel, MatchReason.guide, 500,
          programme: first.single.programme),
    ]);
    expect(retained.single.programme, first.single.programme);
    expect(retained.single.programmeSearchHit, isFalse);
    expect(identical(first, await matcher.searchWithGuide('Shanghai')), isTrue);
    guide.programmes = [];
    guide.notifyListeners();
    expect(await matcher.searchWithGuide('Shanghai'), isEmpty);
  });

  test(
      'manual search stays bounded, cancellable and ranks a late playlist entry first',
      () async {
    final channels = [
      for (var i = 0; i < 80000; i++) _channel('$i', 'Tennis Feed $i')
    ];
    await matcher.prepare(channels);
    final preferred = ChannelMatch(channels.last, MatchReason.guide, 500);
    var ticks = 0;
    final timer =
        Timer.periodic(const Duration(milliseconds: 1), (_) => ticks++);
    final clock = Stopwatch()..start();
    final result =
        await matcher.searchWithGuide('Tennis', matches: [preferred]);
    timer.cancel();
    expect(result, hasLength(200));
    expect(result.first.channel.id, channels.last.id);
    expect(ticks, greaterThan(0));
    debugPrint(
        '80k manual search: ${clock.elapsedMilliseconds}ms, $ticks event-loop ticks');
    expect(await matcher.searchWithGuide('Feed', isCancelled: () => true),
        isEmpty);
  });
}
