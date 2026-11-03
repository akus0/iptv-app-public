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
  @override
  EpgProgram? getCurrentProgram(String id) => null;
  @override
  EpgProgram? getNextProgram(String id) => null;
  @override
  Future<List<EpgProgram>> findProgrammesByTitle(
          DateTime from, DateTime to, List<String> terms,
          {List<String>? channelIds}) async =>
      [];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  var now = DateTime.utc(2026, 10, 31, 12);
  const fixture = 'Boston Bruins vs Toronto Maple Leafs';
  Channel channel(String id, String name) => Channel(
      id: id,
      rawId: id,
      playlistId: 'test',
      name: name,
      group: 'Sports',
      url: 'https://example.invalid/unused');
  SportsGame game(
          {GameState state = GameState.live, DateTime? start, DateTime? end}) =>
      SportsGame(
          id: 'game',
          league: sportsLeagueById('nhl')!,
          start: start ?? now,
          end: end,
          state: state,
          statusText: state.name,
          home: const SportsTeam(
              id: 'home',
              name: 'Boston Bruins',
              shortName: 'Bruins',
              abbreviation: 'BOS'),
          away: const SportsTeam(
              id: 'away',
              name: 'Toronto Maple Leafs',
              shortName: 'Maple Leafs',
              abbreviation: 'TOR'));
  late _Guide guide;
  late SportsChannelPicks picks;
  setUp(() async {
    now = DateTime.utc(2026, 10, 31, 12);
    SharedPreferences.setMockInitialValues({});
    final storage = StorageService();
    await storage.init();
    guide = _Guide(storage);
    picks = SportsChannelPicks.load(storage);
  });
  tearDown(() => guide.dispose());
  for (final background in [false, true]) {
    SportsChannelMatcher create() {
      final matcher = background
          ? SportsChannelMatcher.background(guide, clock: () => now)
          : SportsChannelMatcher(guide, clock: () => now);
      addTearDown(matcher.dispose);
      return matcher;
    }

    Future<List<ChannelMatch>> match(
            SportsChannelMatcher matcher, SportsGame event) async =>
        (await matcher.matchDay([event], picks,
            includeGuide: false,
            includePossible: true,
            limit: 20))['nhl:game']!;
    Object signature(List<ChannelMatch> rows) => [
          for (final row in rows)
            (row.channel.id, row.reason, row.score, row.detail, row.isConfident)
        ];

    test('name facts do not freeze live/post eligibility; worker=$background',
        () async {
      final channels = [
        channel('1', fixture),
        channel('2', 'Replay: $fixture'),
        channel('3', 'End | $fixture'),
        channel('4', '$fixture Offline'),
      ];
      final reused = create();
      await reused.prepare(channels);
      for (final state in [
        GameState.live,
        GameState.post,
        GameState.pre,
        GameState.live
      ]) {
        final event = game(state: state);
        final actual = await match(reused, event);
        final fresh = create();
        await fresh.prepare(channels);
        expect(signature(actual), signature(await match(fresh, event)));
        expect(actual.map((m) => m.channel.id), isNot(contains('4')));
        if (state != GameState.post) {
          expect(actual.map((m) => m.channel.id), isNot(contains('2')));
          expect(actual.map((m) => m.channel.id), isNot(contains('3')));
        } else {
          expect(actual.map((m) => m.channel.id), containsAll(['2', '3']));
        }
      }
    });

    test(
        'same-size catalogue edits and reordering reset name facts; worker=$background',
        () async {
      final matcher = create();
      await matcher
          .prepare([channel('1', fixture), channel('2', '$fixture Offline')]);
      expect((await match(matcher, game())).map((m) => m.channel.id), ['1']);
      await matcher
          .prepare([channel('1', '$fixture Offline'), channel('2', fixture)]);
      expect((await match(matcher, game())).map((m) => m.channel.id), ['2']);
      await matcher
          .prepare([channel('2', fixture), channel('1', '$fixture Offline')]);
      expect((await match(matcher, game())).map((m) => m.channel.id), ['2']);
    });

    test('cached name flags still check each event date; worker=$background',
        () async {
      final matcher = create();
      await matcher.prepare(
          [channel('1', fixture), channel('2', '$fixture | 2026-10-31')]);
      expect((await match(matcher, game())).map((m) => m.channel.id),
          contains('2'));
      expect(
          (await match(matcher, game(start: now.add(const Duration(days: 5)))))
              .map((m) => m.channel.id),
          isNot(contains('2')));
      expect((await match(matcher, game())).map((m) => m.channel.id),
          contains('2'));
    });

    test(
        'channel facts retain tie ranking after catalogue edits; '
        'worker=$background', () async {
      final matcher = create();
      final catalogues = [
        [
          channel('1', 'UK: A $fixture HD'),
          channel('2', 'UK: A $fixture FHD'),
          channel('3', 'UK: B $fixture HD'),
          channel('4', 'UK: A $fixture | 2026-10-20'),
        ],
        [
          channel('3', 'UK: A $fixture HD'),
          channel('2', 'UK: B $fixture FHD'),
          channel('1', 'UK: B $fixture HD'),
          channel('4', 'UK: A $fixture | 2026-10-20'),
        ],
      ];
      for (final channels in [...catalogues, catalogues.first]) {
        await matcher.prepare(channels);
        final actual = await match(matcher, game());
        final fresh = create();
        await fresh.prepare(channels);
        expect(signature(actual), signature(await match(fresh, game())));
        expect(actual.map((m) => m.channel.id), isNot(contains('4')));
        // Equal-quality evidence must still show different feeds before
        // another quality version, even after channel IDs/names move.
        expect(actual.take(2).map((m) => m.channel.id).toSet(), {'2', '3'});
      }
    });

    test(
        'long live events recompute date scope as the clock moves; worker=$background',
        () async {
      final matcher = create();
      final event = game(
          start: now.subtract(const Duration(days: 1)),
          end: now.add(const Duration(days: 3)));
      await matcher.prepare(
          [channel('1', fixture), channel('2', '$fixture | 2026-10-30')]);
      expect((await match(matcher, event)).map((m) => m.channel.id),
          contains('2'));
      now = now.add(const Duration(days: 1));
      expect((await match(matcher, event)).map((m) => m.channel.id),
          isNot(contains('2')));
      now = now.subtract(const Duration(days: 1));
      expect((await match(matcher, event)).map((m) => m.channel.id),
          contains('2'));
    });
  }
}
