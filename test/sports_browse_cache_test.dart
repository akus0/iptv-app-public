import 'package:flutter_test/flutter_test.dart';
import 'package:nox_iptv/models/channel.dart';
import 'package:nox_iptv/models/epg_program.dart';
import 'package:nox_iptv/models/sports.dart';
import 'package:nox_iptv/services/sports_browse_cache.dart';
import 'package:nox_iptv/services/sports_channel_matcher.dart';
import 'package:nox_iptv/services/sports_match_inputs.dart';
import 'package:nox_iptv/services/sports_match_session.dart';

class Picks implements SportsMatchPicks {
  String? picked;
  @override
  String? channelIdFor(SportsGame game) => picked;
}

void main() {
  final now = DateTime.utc(2026, 10, 26, 10);
  final channel = Channel(
      id: 'one',
      rawId: 'one',
      playlistId: 'p',
      name: 'Event feed',
      group: 'Sports',
      url: 'https://example.invalid');
  SportsGame game(
          {String id = 'one',
          String away = 'Leeds',
          List<SportsBroadcast> online = const []}) =>
      SportsGame(
          id: id,
          league: sportsLeagueById('eng.1')!,
          start: now,
          state: GameState.live,
          statusText: 'Live',
          onlineBroadcasts: online,
          home: const SportsTeam(
              id: 'h',
              name: 'Everton',
              shortName: 'Everton',
              abbreviation: 'EVE'),
          away: SportsTeam(
              id: 'a', name: away, shortName: away, abbreviation: 'LEE'));
  late SportsBrowseCache cache;
  late SportsMatchSession session;
  late Picks picks;
  setUp(() {
    cache = SportsBrowseCache();
    picks = Picks();
    session = SportsMatchSession();
    session.updateInputs([game()], picks, 1, now);
    session.apply({
      'eng.1:one': [
        ChannelMatch(channel, MatchReason.guide, 500,
            programme: EpgProgram(
                channelId: 'one',
                title: 'Everton v Leeds',
                start: now,
                stop: now.add(const Duration(minutes: 2))))
      ]
    }, session.identities, 1, now, complete: true);
    cache.save('today', session, [], 'signature', now, games: [game()]);
  });
  test('restores completed results without sharing mutable route state', () {
    final restored = cache.read('today', now)!.restoreSession(at: now);
    restored.updateInputs([game()], picks, 1, now);
    expect(restored.checked, {'eng.1:one'});
    expect(restored.matches, same(session.matches));
    restored
        .apply({'eng.1:one': []}, restored.identities, 1, now, complete: true);
    expect(session.matches.values.single, hasLength(1));
    expect(
        cache.read('today', now)!.restoreSession(at: now).matches.values.single,
        hasLength(1));
  });
  test(
      'programme end, fixture and catalogue changes cannot revive old evidence',
      () {
    for (var change = 0; change < 3; change++) {
      final restored = cache.read('today', now)!.restoreSession(at: now);
      restored.updateInputs(
          [game(away: change == 1 ? 'Fulham' : 'Leeds')],
          picks,
          change == 2 ? 2 : 1,
          change == 0 ? now.add(const Duration(minutes: 2)) : now);
      expect(restored.matches.values.expand((m) => m), isEmpty);
      expect(restored.checked, isEmpty);
    }
  });
  test(
      'manual pick changes invalidate completion without dropping alternatives',
      () {
    final restored = cache.read('today', now)!.restoreSession(at: now);
    picks.picked = 'different';
    restored.updateInputs([game()], picks, 1, now);
    expect(restored.checked, isEmpty);
    expect(restored.matches.values.single, hasLength(1));
  });
  test(
      'bounded age, clock rollback, scope and memory pressure invalidate snapshots',
      () {
    expect(cache.read('different-guide-or-playlist', now), isNull);
    expect(cache.read('today', now.add(const Duration(minutes: 5))), isNull);
    cache.save('today', session, [], 'signature', now, games: [game()]);
    expect(
        cache.read('today', now.subtract(const Duration(seconds: 1))), isNull);
    for (var i = 0; i < 3; i++) {
      cache.save(i, session, [], 's', now, games: [game()]);
    }
    expect(cache.read(0, now), isNull);
    expect(cache.read(1, now), isNotNull);
    cache.didHaveMemoryPressure();
    expect(cache.read(1, now), isNull);
  });
  test('partial results survive a route change without becoming completed', () {
    final partial = SportsMatchSession()..updateInputs([game()], picks, 1, now);
    partial.apply(session.matches, partial.identities, 1, now, complete: false);
    cache.save('partial', partial, [game()], null, now, games: [game()]);
    final restored = cache.read('partial', now)!.restoreSession(at: now);
    restored.updateInputs([game()], picks, 1, now);
    expect(restored.matches.values.single, hasLength(1));
    expect(restored.checked, isEmpty);
    expect(cache.read('partial', now)!.guideGames, hasLength(1));
    expect(cache.read('partial', now)!.signature, isNull);
  });
  test('online boundary expires its event without discarding the snapshot', () {
    cache.save('online', session, [], 's', now,
        games: [
          game(online: [
            SportsBroadcast('Sky',
                source: 'listing',
                expiresAt: now.add(const Duration(seconds: 10)))
          ])
        ]);
    expect(
        cache.read('online', now.add(const Duration(seconds: 9))), isNotNull);
    final at = now.add(const Duration(seconds: 10));
    final restored = cache.read('online', at)!.restoreSession(at: at);
    expect(restored.matches, isEmpty);
    expect(restored.checked, isEmpty);
    expect(
        cache.read('today', at)!.restoreSession(at: at).checked, {'eng.1:one'});
  });
  test('one fixture boundary preserves other matches in the same snapshot', () {
    final expiring = game(online: [
      SportsBroadcast('Sky',
          source: 'listing', expiresAt: now.add(const Duration(seconds: 10)))
    ]);
    final other = game(id: 'two', away: 'Fulham');
    final both = SportsMatchSession()
      ..updateInputs([expiring, other], picks, 1, now);
    both.apply({
      'eng.1:one': session.matches['eng.1:one']!,
      'eng.1:two': session.matches['eng.1:one']!
    }, both.identities, 1, now, complete: true);
    cache.save('both', both, [], 's', now, games: [expiring, other]);
    final at = now.add(const Duration(seconds: 10));
    final restored = cache.read('both', at)!.restoreSession(at: at);
    expect(restored.checked, {'eng.1:two'});
    expect(restored.matches.keys, ['eng.1:two']);
    expect(
        cache.read('both', now)!.restoreSession(at: now).checked, hasLength(2));
  });
}
