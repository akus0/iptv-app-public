import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:nox_iptv/models/channel.dart';
import 'package:nox_iptv/models/epg_program.dart';
import 'package:nox_iptv/models/sports.dart';
import 'package:nox_iptv/services/epg_service.dart';
import 'package:nox_iptv/services/sports_channel_matcher.dart';
import 'package:nox_iptv/services/storage_service.dart';
import 'package:nox_iptv/utils/sports_title_matcher.dart';

class _Guide extends EpgService {
  _Guide(super.storage);
  final rows = <EpgProgram>[];
  @override
  EpgProgram? getCurrentProgram(String id) => null;
  @override
  EpgProgram? getNextProgram(String id) => null;
  @override
  Future<List<EpgProgram>> findProgrammesByTitle(
      DateTime from, DateTime to, List<String> terms,
      {List<String>? channelIds}) async {
    final matcher = SportsTitleMatcher(terms);
    return rows
        .where((p) =>
            p.start.isBefore(to) &&
            p.stop.isAfter(from) &&
            (channelIds == null || channelIds.contains(p.channelId)) &&
            matcher.matches(p.title))
        .toList();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final now = DateTime.utc(2026, 10, 31, 6, 10);
  final league = sportsLeagueById('jpn.1')!;
  SportsTeam team(String name, String shortName, String code) => SportsTeam(
      id: code, name: name, shortName: shortName, abbreviation: code);
  final pairs = [
    (
      team('Fagiano Okayama', 'Okayama', 'OKA'),
      team('FC Tokyo', 'Tokyo', 'TOK')
    ),
    (
      team('Kyoto Sanga', 'Kyoto Sanga', 'KYO'),
      team('Shimizu S-Pulse', 'Shimizu', 'SHI')
    ),
    (
      team('Mito Hollyhock', 'Mito Hollyhock', 'MITO'),
      team('Sanfrecce Hiroshima', 'Sanfreece', 'SAN')
    ),
    (
      team('Kashima Antlers', 'Kashima', 'KAN'),
      team('Cerezo Osaka', 'Cerezo Osaka', 'CER')
    ),
    (
      team('Vissel Kobe', 'Vissel Kobe', 'VIS'),
      team('Nagoya Grampus', 'Nagoya', 'NAG')
    ),
    (
      team('Kashiwa Reysol', 'Kashiwa', 'KRE'),
      team('Urawa Red Diamonds', 'Urawa Reds', 'URA')
    ),
  ];
  final games = [
    for (var i = 0; i < pairs.length; i++)
      SportsGame(
          id: '$i',
          league: league,
          start: DateTime.utc(
              2026,
              10,
              31,
              i < 3
                  ? 5
                  : i == 5
                      ? 7
                      : 6),
          state: i == 5 ? GameState.pre : GameState.live,
          statusText: '',
          home: pairs[i].$1,
          away: pairs[i].$2)
  ];
  Channel channel(String id, String name) => Channel(
      id: 'p::$id',
      rawId: id,
      playlistId: 'p',
      name: name,
      group: 'Sports',
      url: 'https://example.invalid/$id');
  late _Guide guide;
  late SportsChannelMatcher matcher;
  late SportsChannelPicks picks;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final storage = StorageService();
    await storage.init();
    guide = _Guide(storage);
    matcher = SportsChannelMatcher(guide, clock: () => now);
    picks = SportsChannelPicks.load(storage);
  });
  tearDown(() {
    matcher.dispose();
    guide.dispose();
  });

  test('six J1 fixtures only confirm the two explicitly named feeds', () async {
    await matcher.prepare([
      channel('one',
          'Event 27 | Kashima Antlers v Cerezo Osaka J.League (2026-10-31 16:55:15)'),
      channel('two',
          'Event 30 | Kashiwa Reysol v Urawa Red Diamonds J.League (2026-10-31 17:55:15)'),
      channel('stale',
          'Event 8 | Kashima Antlers v Cerezo Osaka J.League (2026-10-25)'),
      channel('next-day',
          'Event 50 | Yokohama F. Marinos v Kawasaki Frontale J.League (2026-11-01)'),
      channel('generic', 'Football Sports'),
      channel('tennis', 'Tokyo: Day 6 WTA 500 (2026-10-31)'),
    ]);
    guide.rows.add(EpgProgram(
        channelId: 'stale',
        title: 'Kashima Antlers v Cerezo Osaka J.League (2026-10-31)',
        start: now.subtract(const Duration(hours: 12)),
        stop: now.subtract(const Duration(hours: 10))));
    final result = await matcher.matchDay(games, picks, includePossible: true);
    for (var i = 0; i < games.length; i++) {
      final confirmed = result[SportsChannelPicks.eventKey(games[i])]!
          .where((m) => m.isConfident)
          .map((m) => m.channel.rawId)
          .toList();
      expect(
          confirmed,
          i == 3
              ? ['one']
              : i == 5
                  ? ['two']
                  : isEmpty,
          reason: '${games[i].home.name} vs ${games[i].away.name}');
    }
  });

  test(
      'J.League aliases identify explicit codes without promoting generic coverage',
      () async {
    await matcher.prepare([
      for (final id in ['dot', 'joined', 'wrong', 'generic', 'replay'])
        channel(id, 'Sports Feed $id'),
    ]);
    for (final entry in {
      'dot': 'J.League: KAN v CER',
      'joined': 'JLeague: KAN vs CER',
      'wrong': 'J.League: KAN v KRE',
      'generic': 'J.League live football',
      'replay': 'Replay J.League: KAN v CER',
    }.entries) {
      guide.rows.add(EpgProgram(
          channelId: entry.key,
          title: entry.value,
          start: now.subtract(const Duration(minutes: 15)),
          stop: now.add(const Duration(hours: 2))));
    }
    final result =
        await matcher.matchDay([games[3]], picks, includePossible: true);
    expect(
        result.values.single
            .where((m) => m.isConfident)
            .map((m) => m.channel.rawId)
            .toSet(),
        {'dot', 'joined'});
  });
}
