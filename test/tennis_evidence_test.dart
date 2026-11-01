import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:nox_iptv/models/channel.dart';
import 'package:nox_iptv/models/epg_program.dart';
import 'package:nox_iptv/models/sports.dart';
import 'package:nox_iptv/services/epg_service.dart';
import 'package:nox_iptv/services/storage_service.dart';
import 'package:nox_iptv/services/sports_channel_matcher.dart';

class Guide extends EpgService {
  Guide(super.storage);
  List<EpgProgram> rows = [];
  int titleQueries = 0, idQueries = 0;
  @override
  Future<List<EpgProgram>> findProgrammesByTitle(
      DateTime from, DateTime to, List<String> terms, {List<String>? channelIds}) async {
    titleQueries++;
    return rows
        .where((p) => terms.any((t) => p.title.toLowerCase().contains(t)))
        .toList();
  }

  @override
  Future<List<EpgProgram>> findSportsProgrammesForChannels(
      List<String> ids, DateTime from, DateTime to) async {
    idQueries++;
    return rows
        .where((p) =>
            ids.contains(p.channelId) &&
            p.start.isBefore(to) &&
            p.stop.isAfter(from))
        .toList();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final start = DateTime.utc(2026, 10, 22, 5);
  late DateTime now;
  late Guide guide;
  late SportsChannelMatcher matcher;
  late SportsChannelPicks picks;
  SportsGame game(
          {String id = '1',
          String home = 'Iva Jovic',
          String away = 'Jasmine Paolini',
          String? court,
          GameState state = GameState.live}) =>
      SportsGame(
          id: id,
          league: sportsLeagueById('tennis.wta')!,
          start: start,
          state: state,
          statusText: 'Live',
          home: SportsTeam(
              id: home, name: home, shortName: home, abbreviation: ''),
          away: SportsTeam(
              id: away, name: away, shortName: away, abbreviation: ''),
          event: SportsEventInfo(title: 'Ningbo Open', court: court));
  Channel channel(String name, {String id = '1'}) => Channel(
      id: 'test::$id',
      rawId: id,
      playlistId: 'test',
      name: name,
      group: 'UK Sports',
      url: 'https://example.invalid/not-playable',
      epgIdOverride: id);
  EpgProgram programme(String title,
          {String? desc, DateTime? from, DateTime? to, String id = '1'}) =>
      EpgProgram(
          channelId: id,
          title: title,
          description: desc,
          start: from ?? start,
          stop: to ?? start.add(const Duration(hours: 2)));
  Future<List<ChannelMatch>> match(SportsGame g, List<Channel> channels) async {
    await matcher.prepare(channels);
    return (await matcher.matchDay([g], picks, includePossible: true))
        .values
        .single;
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final storage = StorageService();
    await storage.init();
    guide = Guide(storage);
    now = start.add(const Duration(minutes: 5));
    matcher = SportsChannelMatcher(guide, clock: () => now);
    picks = SportsChannelPicks.load(storage);
  });
  tearDown(() => guide.dispose());

  test(
      'exact dated guide supersedes stale dynamic names, but never replay/idle headers',
      () async {
    guide.rows = [
      for (var i = 1; i <= 5; i++)
        programme('Jovic vs Paolini @ Oct 22 - WTA Ningbo', id: '$i')
    ];
    final found = await match(game(), [
      channel('Badosa vs Ruzic @ Oct 10 - WTA Osaka :Tennis 01'),
      channel('Tennis Replay Oct 10', id: '2'),
      channel('Tennis OFF AIR Oct 10', id: '3'),
      channel('### Tennis Oct 10', id: '4'),
      channel('END: Tennis Oct 10', id: '5'),
    ]);
    expect(
        found.where((m) => m.isConfident).map((m) => m.channel.rawId), ['1']);
    expect(found.first.reason, MatchReason.guide);
  });

  test(
      'generic titles on indexed tennis IDs use synopsis without global text scans',
      () async {
    guide.rows = [
      programme('Live event', desc: 'Ningbo: Iva Jovic faces Jasmine Paolini.')
    ];
    final channels = [channel('Tennis Channel Plus 2')];
    final found = await match(game(), channels);
    expect(found.single.reason, MatchReason.guide);
    expect(guide.idQueries, 1);
    await matcher.matchDay([game()], picks, includePossible: true);
    expect(guide.idQueries, 1);
    expect(guide.titleQueries, 1);
    expect(matcher.guideStatusFor(game()), isNull);
  });

  test(
      'multi-match blocks, repeats, wrong embedded dates and incidental names are not exact',
      () async {
    for (final p in [
      programme('WTA Ningbo',
          desc: 'Jovic vs Paolini, followed by Badosa vs Ruzic.'),
      programme('WTA Ningbo', desc: 'Jovic and Paolini feature in interviews.'),
      programme('WTA Ningbo', desc: 'Highlights: Jovic vs Paolini.'),
      programme('Jovic vs Paolini @ Oct 10 - WTA Ningbo'),
      programme('Jovic vs Paolini - WTA Ningbo Doubles'),
      programme('K. Jovic vs J. Paolini - WTA Ningbo'),
    ]) {
      expect(SportsChannelMatcher.tennisProgrammeIsExact(game(), p), false,
          reason: p.title + (p.description ?? ''));
    }
  });

  test(
      'later programmes are possible, become exact at start, and expire at stop',
      () async {
    final begins = start.add(const Duration(minutes: 10));
    guide.rows = [
      programme('Jovic vs Paolini - WTA Ningbo',
          from: begins, to: begins.add(const Duration(minutes: 1)))
    ];
    final channels = [channel('Tennis Channel Plus 2')];
    expect((await match(game(), channels)).every((m) => !m.isConfident), true);
    now = begins;
    expect(
        (await matcher.matchDay([game()], picks, includePossible: true))
            .values
            .single
            .single
            .isConfident,
        true);
    now = begins.add(const Duration(minutes: 1));
    expect(
        (await matcher.matchDay([game()], picks, includePossible: true))
            .values
            .single
            .every((m) => !m.isConfident),
        true);
    expect(matcher.guideStatusFor(game()), contains('unavailable'));
  });

  test('one feed cannot confirm overlapping different live fixtures', () async {
    guide.rows = [
      programme('Jovic vs Paolini - WTA Ningbo'),
      programme('Badosa vs Ruzic - WTA Ningbo',
          from: start.add(const Duration(minutes: 1)))
    ];
    await matcher.prepare([channel('Tennis Channel Plus 2')]);
    final result = await matcher.matchDay([
      game(),
      game(id: '2', home: 'Paula Badosa', away: 'Antonia Ruzic')
    ], picks, includePossible: true);
    expect(result.values.expand((v) => v).where((m) => m.isConfident), isEmpty);
  });

  test(
      'explicit tournament and court identify a current feed without player names',
      () async {
    final fixture = game(court: 'Court 1');
    guide.rows = [
      programme('Live Tennis', desc: 'WTA Ningbo Open: No. 1 Court.')
    ];
    final found = await match(fixture, [channel('Tennis Channel Plus 7')]);
    expect(found.single.isConfident, true);
    expect(found.single.reason, MatchReason.guide);
    for (final p in [
      programme('Tennis Channel Plus 1: WTA Ningbo'),
      programme('Live Tennis: Court 1'),
      programme('WTA Ningbo: Court 2'),
      programme('WTA Ningbo: Centre Court'),
      programme('WTA Ningbo: Court 1 and Court 2'),
      programme('WTA Ningbo: Court 1 and 2'),
      programme('WTA Ningbo: Court 1 highlights'),
      programme('WTA Ningbo: Court 1 @ Oct 10'),
      programme('WTA Ningbo: Court 1 Badosa vs Ruzic'),
    ]) {
      expect(SportsChannelMatcher.tennisProgrammeIsExact(fixture, p), false,
          reason: p.title);
    }
    expect(
        SportsChannelMatcher.tennisProgrammeIsExact(game(), guide.rows.single),
        false);
    expect(
        SportsChannelMatcher.tennisProgrammeIsExact(
            game(court: 'Centre Court'),
            programme(
                'Center Court Live : Brussels-ATP, Lyon-ATP, Almaty-ATP, Osaka-WTA & Ningbo-WTA Early Rounds',
                desc: 'Tennis action from around the world.')),
        false);
    expect(
        SportsChannelMatcher.tennisProgrammeIsExact(game(court: 'Centre Court'),
            programme('WTA Ningbo Open: Centre Court')),
        true);
  });

  test(
      'incremental tennis arrivals reuse results but recheck shared-feed conflicts',
      () async {
    guide.rows = [programme('WTA Ningbo Open: Court 1')];
    await matcher.prepare([channel('Tennis Channel Plus 7')]);
    final first = game(court: 'Court 1');
    final second = game(
        id: '2', home: 'Paula Badosa', away: 'Antonia Ruzic', court: 'Court 1');
    final alone = await matcher.matchDay([first], picks, includePossible: true);
    expect(alone.values.single.single.isConfident, true);
    final together =
        await matcher.matchDay([first, second], picks, includePossible: true);
    expect(
        together.values.expand((v) => v).where((m) => m.isConfident), isEmpty);
    expect(guide.idQueries, 1);
    final queries = guide.titleQueries;
    // Drop the first, retaining a previously demoted result in the event cache.
    final remaining =
        await matcher.matchDay([second], picks, includePossible: true);
    expect(remaining.values.single.single.isConfident, true);
    expect(guide.titleQueries, queries);
    expect(guide.idQueries, 1);
  });

  test('dedicated tournament coverage outranks the Center Court show brand',
      () async {
    guide.rows = [
      programme(
          'Center Court Live - Brussels-ATP, Almaty-ATP & Ningbo-WTA Quarterfinals',
          desc: 'Tennis action from around the world.'),
      programme('WTA Ningbo Open: Quarterfinals', id: '2'),
      programme('WTA Ningbo Open: Court 2', id: '3'),
    ];
    final found = await match(game(court: 'Center Court'), [
      channel('Tennis Channel'),
      channel('beIN Sports 1', id: '2'),
      channel('Tennis Channel Plus 3', id: '3'),
    ]);
    expect(found.first.channel.rawId, '2');
    expect(found.first.reason, MatchReason.tournament);
    expect(
        found.where((m) => m.channel.rawId == '1').single.isConfident, false);
    expect(found.where((m) => m.isConfident), isEmpty);
  });

  test('score cache expiry reuses the guide envelope while time advances',
      () async {
    guide.rows = [programme('Jovic vs Paolini - WTA Ningbo')];
    await match(game(), [channel('Tennis Channel Plus 2')]);
    now = now.add(const Duration(minutes: 5));
    await matcher.matchDay([game()], picks, includePossible: true);
    expect(guide.titleQueries, 1);
  });

  test('saved historical sample recovers metadata matches with original labels',
      () async {
    final rows = jsonDecode(
            File('test/fixtures/tennis-guide-evidence.json').readAsStringSync())
        as List;
    var recovered = 0;
    for (final row in rows) {
      final at = DateTime.parse(row['start'] as String);
      final players = List<String>.from(row['players'] as List);
      final g = SportsGame(
          id: row['id'] as String,
          league: sportsLeagueById('tennis.wta')!,
          start: at,
          state: GameState.live,
          statusText: 'Live',
          home: SportsTeam(
              id: 'a',
              name: players[0],
              shortName: players[0],
              abbreviation: ''),
          away: SportsTeam(
              id: 'b',
              name: players[1],
              shortName: players[1],
              abbreviation: ''),
          event: SportsEventInfo(
              title: row['tournament'] as String,
              matchingNames: List<String>.from(row['aliases'] as List)));
      now = at;
      guide.rows = [
        programme(row['programmeTitle'] as String,
            from: DateTime.parse(row['programmeStart'] as String),
            to: DateTime.parse(row['programmeStop'] as String))
      ];
      guide.notifyListeners();
      final found = await match(g, [channel(row['channelName'] as String)]);
      if (found.any((m) => m.isConfident)) recovered++;
    }
    expect(recovered, rows.length);
  });
}
