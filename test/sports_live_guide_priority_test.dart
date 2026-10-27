import 'package:flutter_test/flutter_test.dart';
import 'package:nox_iptv/models/channel.dart';
import 'package:nox_iptv/models/epg_program.dart';
import 'package:nox_iptv/models/sports.dart';
import 'package:nox_iptv/services/sports_channel_matcher.dart';
import 'package:nox_iptv/services/sports_match_inputs.dart';

final now = DateTime.utc(2026, 10, 22, 22, 57);

class _Guide implements SportsMatchGuide {
  final rows = <EpgProgram>[];
  int queries = 0;
  @override
  int get changeRevision => 1;
  @override
  DateTime? get lastUpdated => now;
  @override
  EpgProgram? getCurrentProgram(String id) =>
      rows.where((p) => p.channelId == id && p.isNowPlaying(now)).firstOrNull;
  @override
  EpgProgram? getNextProgram(String id) => null;
  @override
  Future<List<EpgProgram>> findProgrammesByTitle(
      DateTime from, DateTime to, List<String> terms, {List<String>? channelIds}) async {
    queries++;
    return rows
        .where((p) =>
            p.start.isBefore(to) &&
            p.stop.isAfter(from) &&
            terms.any((t) => p.title.toLowerCase().contains(t)))
        .toList();
  }

  @override
  Future<List<EpgProgram>> findSportsProgrammesForChannels(
          List<String> ids, DateTime from, DateTime to) async =>
      throw StateError('Team fixtures must not add guide queries');
}

class _Picks implements SportsMatchPicks {
  String? picked;
  @override
  String? channelIdFor(SportsGame game) => picked;
}

void main() {
  SportsTeam team(String name) =>
      SportsTeam(id: name, name: name, shortName: name, abbreviation: '');
  SportsGame game(
          {String home = 'Coastal Carolina', String away = 'James Madison'}) =>
      SportsGame(
          id: '$home-$away',
          league: sportsLeagueById('usa.ncaa.w.1')!,
          start: now.subtract(const Duration(minutes: 57)),
          state: GameState.live,
          statusText: 'Live',
          home: team(home),
          away: team(away));
  Channel channel(String id, String name) => Channel(
      id: id,
      rawId: id,
      playlistId: 'test',
      name: name,
      group: 'Sports',
      url: 'https://example.invalid/never-opened');
  EpgProgram programme(String id, String title, {String? description}) =>
      EpgProgram(
          channelId: id,
          title: title,
          description: description,
          start: now.subtract(const Duration(minutes: 57)),
          stop: now.add(const Duration(hours: 1)));
  late _Guide guide;
  late _Picks picks;
  late SportsChannelMatcher matcher;
  setUp(() {
    guide = _Guide();
    picks = _Picks();
    matcher = SportsChannelMatcher(guide, clock: () => now);
  });
  tearDown(() => matcher.dispose());
  Future<List<ChannelMatch>> match(List<Channel> channels,
      {SportsGame? fixture}) async {
    final g = fixture ?? game();
    await matcher.prepare(channels);
    return (await matcher.matchDay([g], picks,
        includePossible: true))[SportsChannelPicks.eventKey(g)]!;
  }

  test(
      'current guide overrides an old rotating PPV label and ranks above broad coverage',
      () async {
    guide.rows.add(programme('correct',
        'US (ESPN+ 043) | James Madison vs. Coastal Carolina Oct 22 6:00PM ET'));
    final result = await match([
      channel(
          'correct', 'ESPN+ 043 | Football: Other Teams vs Old Teams Oct 10'),
      channel('broad', "NCAA Women's Soccer"),
    ]);
    expect(result.first.channel.id, 'correct');
    expect(result.first.reason, MatchReason.guide);
    expect(result.last.isConfident, isFalse);
  });
  test('stale END label can recover only from a current exact team fixture',
      () async {
    guide.rows
        .add(programme('correct', 'James Madison vs Coastal Carolina Oct 22'));
    expect(
        (await match([channel('correct', 'END Other vs Teams Oct 10')]))
            .single
            .reason,
        MatchReason.guide);
  });
  test(
      'stale label override still rejects wrong opponents, sport, gender, date and repeats',
      () async {
    final titles = [
      'Soccer: James Madison vs South Carolina Oct 22',
      'College Basketball: James Madison vs Coastal Carolina Oct 22',
      "Men's Soccer: James Madison vs Coastal Carolina Oct 22",
      'Soccer: James Madison vs Coastal Carolina Oct 10',
      'Soccer Replay: James Madison vs Coastal Carolina Oct 22',
      'END | James Madison vs Coastal Carolina Oct 22',
      'ENDED | James Madison vs Coastal Carolina Oct 22',
    ];
    for (final (i, t) in titles.indexed) {
      guide.rows.add(programme('$i', t));
    }
    expect(
        await match([
          for (final (i, _) in titles.indexed)
            channel('$i', 'Other vs Teams Oct 10')
        ]),
        isEmpty);
  });
  test('idle and ended guide slots cannot become generic soccer suggestions',
      () async {
    final titles = [
      'NO EVENT STREAMING NOW - | US: SOCCER PPV 61',
      'End | The Dan Patrick Show | US: SOCCER PPV 84',
      'ENDED | Soccer',
      'OFF AIR | Soccer',
      'No Match Today | Soccer'
    ];
    for (final (i, t) in titles.indexed) {
      guide.rows.add(programme('$i', t));
    }
    expect(
        await match([
          for (final (i, _) in titles.indexed)
            channel('$i', 'Soccer Channel $i')
        ]),
        isEmpty);
  });
  test(
      'SOCCER PPV routing suffix is not evidence that a generic event is soccer',
      () async {
    guide.rows.add(programme('route', 'Live | Day 4 | all | US: SOCCER PPV 8'));
    expect(
        await match(
            [channel('route', 'Other Teams vs Old Teams | US: SOCCER PPV 8')]),
        isEmpty);
  });
  test(
      'current description-only fixture is retrieved without broad database searches',
      () async {
    guide.rows.add(programme('description', 'Matchday Live',
        description:
            'James Madison takes on Coastal Carolina. Live women’s college soccer coverage.'));
    final result = await match([channel('description', 'Event Feed 43')]);
    expect(result.single.reason, MatchReason.guide);
    expect(guide.queries, 1);
  });
  test('generic football title uses both opponents in synopsis', () async {
    guide.rows.add(programme('description', 'Live Football',
        description: 'James Madison vs Coastal Carolina. Live coverage.'));
    expect(
        (await match([channel('description', 'Event Feed 43')])).single.reason,
        MatchReason.guide);
  });
  test('fixture after character 320 is preserved from cached synopsis',
      () async {
    guide.rows.add(programme('description', 'Matchday Live',
        description:
            '${'Coverage notes. ' * 24}James Madison at Coastal Carolina. Soccer.'));
    expect(
        (await match([channel('description', 'Event Feed 43')])).single.reason,
        MatchReason.guide);
  });
  test(
      'incidental mentions, different title fixture and multi-fixture synopsis do not confirm',
      () async {
    guide.rows.addAll([
      programme('incidental', "Women's College Soccer",
          description:
              'James Madison won last week. Coastal Carolina lost yesterday. Live interviews at the stadium.'),
      programme('other', "Women's Soccer: UAlbany vs Vermont",
          description: 'James Madison vs Coastal Carolina is next week.'),
      programme('preview', 'Soccer',
          description: 'James Madison vs Coastal Carolina next week.'),
      programme('multiple', 'Soccer',
          description:
              'James Madison vs Coastal Carolina, followed by UAlbany vs Vermont.'),
      programme('separate', 'Soccer',
          description:
              'James Madison vs Vermont, then UAlbany vs Coastal Carolina.'),
    ]);
    final result = await match(
        [for (final p in guide.rows) channel(p.channelId, 'Event Feed')]);
    expect(result.where((m) => m.isConfident), isEmpty);
  });
  test('saved user pick still wins when provider marks a slot idle', () async {
    picks.picked = 'manual';
    guide.rows
        .add(programme('manual', 'NO EVENT STREAMING NOW - SOCCER PPV 1'));
    final result = await match([channel('manual', 'Soccer')]);
    expect(result.single.reason, MatchReason.pick);
  });
  test('one batch assigns each live fixture its own current guide channel',
      () async {
    final fixtures = [game(), game(home: 'Vermont', away: 'UAlbany')];
    guide.rows.addAll([
      programme('a', 'James Madison vs Coastal Carolina Oct 22'),
      programme('b', 'UAlbany vs Vermont Oct 22')
    ]);
    await matcher.prepare([
      channel('a', 'Stale A vs Old A Oct 10'),
      channel('b', 'Stale B vs Old B Oct 10'),
      channel('broad', 'Soccer TV')
    ]);
    final result =
        await matcher.matchDay(fixtures, picks, includePossible: true);
    expect([
      for (final g in fixtures)
        result[SportsChannelPicks.eventKey(g)]!.first.channel.id
    ], [
      'a',
      'b'
    ]);
  });
}
