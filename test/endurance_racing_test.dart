import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:nox_iptv/models/channel.dart';
import 'package:nox_iptv/models/epg_program.dart';
import 'package:nox_iptv/models/sports.dart';
import 'package:nox_iptv/services/epg_service.dart';
import 'package:nox_iptv/services/sports_channel_matcher.dart';
import 'package:nox_iptv/services/storage_service.dart';
import 'package:nox_iptv/utils/endurance_racing.dart';
import 'package:nox_iptv/utils/extended_sports.dart';

class _Guide extends EpgService {
  _Guide(super.storage, this.rows);
  final Map<String, EpgProgram> rows;
  @override
  EpgProgram? getCurrentProgram(String id) => rows[normalizeEpgId(id)];
  @override
  EpgProgram? getNextProgram(String id) => null;
  @override
  Future<List<EpgProgram>> findProgrammesByTitle(
          DateTime from, DateTime to, List<String> terms, {List<String>? channelIds}) async =>
      rows.values.toList();
  @override
  Future<List<EpgProgram>> findSportsProgrammesForChannels(
          List<String> ids, DateTime from, DateTime to) async =>
      rows.values.toList();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final cases = {
    '24 Hours of Le Mans': 'racing.wec',
    '24 Heures du Mans': 'racing.wec',
    '24h Le Mans': 'racing.wec',
    'Lone Star Le Mans': 'racing.wec',
    'Qatar 1812km': 'racing.wec',
    'Rolex 24 at Daytona': 'racing.imsa',
    '12 Hours of Sebring': 'racing.imsa',
    'Twelve Hours of Sebring': 'racing.imsa',
    'Motul Petit Le Mans': 'racing.imsa',
    "Sahlen's Six Hours of the Glen": 'racing.imsa',
    'Battle on the Bricks': 'racing.imsa',
    'European Le Mans Series': 'racing.elms',
    'Asian Le Mans Series': 'racing.asian-le-mans',
    'Winter Le Mans Series': 'racing.asian-le-mans',
    'Michelin Le Mans Cup': 'racing.le-mans-cup',
    'Road to Le Mans': 'racing.le-mans-cup',
    'Michelin 24H Dubai': 'racing.24h-series',
    '24H Series': 'racing.24h-series',
    '12H Mugello': 'racing.24h-series',
    '24 Hours of Spa': 'racing.igtc',
    'Bathurst 12 Hour': 'racing.igtc',
    '24h Nürburgring': 'racing.igtc',
    'Suzuka 1000km': 'racing.igtc',
    'Indianapolis 8 Hour': 'racing.igtc',
    'ADAC NLS Race 5': 'racing.nls',
    'Nürburgring Langstrecken-Serie': 'racing.nls',
    'Super Taikyu': 'racing.super-taikyu',
    'Fuji 24 Hours': 'racing.super-taikyu',
    'GT World Challenge Europe Endurance Cup': 'racing.gtwc',
    'International GT Open': 'racing.gt-open',
    'British GT: Silverstone 500': 'racing.british-gt',
    'IMSA Michelin Pilot Challenge': 'racing.imsa-pilot',
    'FIM EWC: 24 Heures Motos': 'racing.ewc',
    '24 Hours of Le Mans - Motorcycles': 'racing.ewc',
    "Bol d'Or": 'racing.ewc',
    'Suzuka 8 Hours': 'racing.ewc',
  };
  test(
      'endurance names reach the fast guide gate and the correct selectable series',
      () {
    for (final entry in cases.entries) {
      expect(extendedGuideSport(entry.key, ''), 'racing', reason: entry.key);
      expect(enduranceLeagueId(entry.key, ''), entry.value, reason: entry.key);
      expect(sportsLeagueById(entry.value), isNotNull);
      expect(kDefaultSportsLeagueIds, contains(entry.value));
    }
    expect(
        enduranceLeagueId('Rolex 24 at Daytona',
            'Drivers hope to compete at the 24 Hours of Le Mans.'),
        'racing.imsa');
    for (final title in [
      'Le Mans vs Paris FC',
      '24 Hours in A&E',
      'Porsche road test',
      'Endurance training',
      'The Road to Le Mans documentary'
    ]) {
      expect(extendedGuideSport(title, ''), isNull, reason: title);
    }
  });

  test(
      'calendar matching recognises named endurance races and rejects bike/support feeds',
      () async {
    SharedPreferences.setMockInitialValues({});
    final storage = StorageService();
    await storage.init();
    final now = DateTime.utc(2026, 6, 14, 10);
    final start = now.subtract(const Duration(hours: 20));
    final end = now.add(const Duration(hours: 4));
    final fixtures = [
      ('racing.wec', 'Circuit de la Sarthe', 'Live: 24 Hours of Le Mans'),
      (
        'racing.imsa',
        'Daytona International Speedway',
        'Live: Rolex 24 at Daytona'
      ),
      (
        'racing.imsa',
        'Sebring International Raceway',
        'Live: 12 Hours of Sebring'
      ),
      ('racing.imsa', 'Michelin Raceway Road Atlanta', 'Live: Petit Le Mans'),
      ('racing.igtc', 'Mount Panorama Circuit', 'Live: Bathurst 12 Hour'),
      ('racing.igtc', 'Circuit de Spa Francorchamps', 'Live: 24 Hours of Spa'),
    ];
    for (final (id, venue, title) in fixtures) {
      final league = sportsLeagueById(id)!;
      final side = SportsTeam(
          id: 'race', name: title, shortName: title, abbreviation: '');
      final game = SportsGame(
          id: 'calendar:$id:$venue',
          league: league,
          start: start,
          end: end,
          state: GameState.live,
          statusText: 'Scheduled now',
          home: side,
          away: side,
          source: 'RaceTV Guide',
          event: SportsEventInfo(
              title: '${league.shortName} · $venue',
              session: 'Race',
              venue: venue,
              matchingNames: [venue, ...enduranceVenueAliases(id, venue)]));
      final rows = <String, EpgProgram>{
        'correct': EpgProgram(
            channelId: 'correct', title: title, start: start, stop: end),
        'bikes': EpgProgram(
            channelId: 'bikes',
            title: 'Live: 24 Hours of Le Mans - Motorcycles',
            start: start,
            stop: end),
        'support': EpgProgram(
            channelId: 'support',
            title: 'Live: Road to Le Mans - Michelin Le Mans Cup',
            start: start,
            stop: end),
      };
      final guide = _Guide(storage, rows);
      final matcher = SportsChannelMatcher(guide, clock: () => now);
      try {
        await matcher.prepare([
          for (final key in rows.keys)
            Channel(
                id: 'p::$key',
                rawId: key,
                playlistId: 'p',
                name: 'Sports $key',
                group: 'Sports',
                url: 'https://example.invalid/no-stream',
                epgIdOverride: key)
        ]);
        final matches =
            (await matcher.matchDay([game], SportsChannelPicks.load(storage)))
                .values
                .single;
        expect(matches.where((m) => m.isConfident).map((m) => m.channel.rawId),
            ['correct'],
            reason: title);
      } finally {
        matcher.dispose();
        guide.dispose();
      }
    }
  });

  for (final background in [false, true]) {
    test(
        'overnight Le Mans stays live, keeps exact channel binding and expires ($background)',
        () async {
      SharedPreferences.setMockInitialValues({});
      final storage = StorageService();
      await storage.init();
      var now = DateTime.utc(2026, 6, 14, 10);
      final start = DateTime.utc(2026, 6, 13, 14),
          end = DateTime.utc(2026, 6, 14, 14);
      final rows = <String, EpgProgram>{
        'car': EpgProgram(
            channelId: 'car',
            title: 'Live: 24 Hours of Le Mans',
            start: start,
            stop: end),
        'bike': EpgProgram(
            channelId: 'bike',
            title: 'Live: 24 Hours of Le Mans - Motorcycles',
            start: start,
            stop: end),
        'replay': EpgProgram(
            channelId: 'replay',
            title: '24 Heures du Mans replay',
            start: start,
            stop: end),
      };
      final guide = _Guide(storage, rows);
      final matcher = background
          ? SportsChannelMatcher.background(guide, clock: () => now)
          : SportsChannelMatcher(guide, clock: () => now);
      final channels = [
        for (final id in rows.keys)
          Channel(
              id: 'test::$id',
              rawId: id,
              playlistId: 'test',
              name: 'Sports $id',
              group: 'Sports',
              url: 'https://example.invalid/never-play',
              epgIdOverride: id)
      ];
      try {
        await matcher.prepare(channels);
        final games = await matcher.discoverGuideEvents();
        expect(games, hasLength(2));
        final car = games.singleWhere((g) => g.league.id == 'racing.wec');
        expect(car.start.day, 13);
        expect(car.state, GameState.live);
        expect(games.any((g) => g.league.id == 'racing.ewc'), isTrue);
        final result =
            (await matcher.matchDay([car], SportsChannelPicks.load(storage)))
                .values
                .single;
        expect(result.map((m) => m.channel.rawId), ['car']);
        expect(result.single.isConfident, isTrue);
        now = end.add(const Duration(seconds: 1));
        expect(await matcher.discoverGuideEvents(), isEmpty);
      } finally {
        matcher.dispose();
        guide.dispose();
      }
    });
  }
}
