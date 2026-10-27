import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nox_iptv/models/channel.dart';
import 'package:nox_iptv/models/epg_program.dart';
import 'package:nox_iptv/models/sports.dart';
import 'package:nox_iptv/services/sports_channel_matcher.dart';
import 'package:nox_iptv/services/sports_match_inputs.dart';
import 'package:nox_iptv/services/sports_match_session.dart';
import 'package:nox_iptv/utils/sports_scroll_anchor.dart';

class _Picks implements SportsMatchPicks {
  String? picked;
  @override
  String? channelIdFor(SportsGame g) => picked;
}

void main() {
  final now = DateTime.utc(2026, 10, 24, 10);
  final channel = Channel(
      id: 'one',
      rawId: 'one',
      playlistId: 'p',
      name: 'Event feed',
      group: 'Sport',
      url: 'https://example.invalid');
  SportsGame game(
          {String away = 'Leeds',
          String score = '0',
          List<SportsBroadcast> online = const []}) =>
      SportsGame(
          id: 'one',
          league: sportsLeagueById('eng.1')!,
          start: now,
          state: GameState.live,
          statusText: 'Live',
          onlineBroadcasts: online,
          home: SportsTeam(
              id: 'home',
              name: 'Everton',
              shortName: 'Everton',
              abbreviation: 'EVE',
              score: score),
          away: SportsTeam(
              id: 'away', name: away, shortName: away, abbreviation: 'LEE'));
  final strong = ChannelMatch(channel, MatchReason.guide, 500,
      programme: EpgProgram(
          channelId: 'one',
          title: 'Everton vs Leeds',
          start: now,
          stop: now.add(const Duration(hours: 2))));
  final weak = ChannelMatch(channel, MatchReason.sport, 80);
  late SportsMatchSession session;
  setUp(() {
    session = SportsMatchSession();
    session.updateInputs([game()], _Picks(), 1, now);
  });
  Map<String, List<ChannelMatch>> batch(List<ChannelMatch> matches) =>
      {'eng.1:one': matches};
  void complete(List<ChannelMatch> matches) =>
      session.apply(batch(matches), session.identities, 1, now, complete: true);

  test('partial refresh cannot downgrade a completed match; final evidence can',
      () {
    complete([strong]);
    final original = session.matches;
    session.apply(batch([weak]), session.identities, 1, now, complete: false);
    expect(session.matches, same(original));
    session.apply(batch([]), session.identities, 1, now, complete: false);
    expect(session.matches, same(original));
    complete([weak]);
    expect(session.matches.values.single.single.isConfident, false);
  });
  test('score updates preserve identity and result list objects', () {
    complete([strong]);
    final original = session.matches, identities = session.identities;
    session.updateInputs([game(score: '1')], _Picks(), 1, now);
    expect(session.identities, same(identities));
    expect(session.matches, same(original));
    expect(session.checked, {'eng.1:one'});
    expect(session.apply(batch([strong]), identities, 1, now, complete: true),
        false);
  });
  test('enrichment keeps guide evidence while old-input replies are rejected',
      () {
    complete([strong]);
    final old = session.identities;
    session.updateInputs([
      game(online: [const SportsBroadcast('Sky Sports', source: 'test')])
    ], _Picks(), 1, now);
    expect(session.matches.values.single.single, same(strong));
    expect(session.checked, isEmpty);
    expect(session.apply(batch([]), old, 1, now, complete: true), false);
    expect(session.matches.values.single.single, same(strong));
  });
  test('fixture and catalogue changes invalidate old evidence', () {
    complete([strong]);
    final old = session.identities;
    session.updateInputs([game(away: 'Fulham')], _Picks(), 1, now);
    expect(session.matches, isEmpty);
    expect(session.apply(batch([strong]), old, 1, now, complete: true), false);
    complete([strong]);
    session.updateInputs([game(away: 'Fulham')], _Picks(), 2, now);
    expect(session.matches, isEmpty);
    expect(
        session.apply(batch([strong]), session.identities, 1, now,
            complete: true),
        false);
  });
  test('retention is bounded by programme end and stale age', () {
    final short = ChannelMatch(channel, MatchReason.guide, 500,
        programme: EpgProgram(
            channelId: 'one',
            title: 'Everton vs Leeds',
            start: now,
            stop: now.add(const Duration(seconds: 30))));
    complete([short]);
    session.updateInputs(
        [game()], _Picks(), 1, now.add(const Duration(seconds: 31)));
    expect(session.matches.values.single, isEmpty);
    expect(session.checked, isEmpty);
    complete([strong]);
    session.updateInputs(
        [game()], _Picks(), 1, now.add(const Duration(minutes: 6)));
    expect(session.matches.values.single, [strong]);
    expect(session.checked, isEmpty);
    session.updateInputs(
        [game()], _Picks(), 1, now.add(const Duration(minutes: 7)));
    expect(session.matches.values.single, isEmpty);
  });
  test('reused model inputs still detect pick changes and evidence expiry', () {
    final fixture = game(), picks = _Picks();
    session.updateInputs([fixture], picks, 1, now);
    complete([strong]);
    final original = session.identities;
    session.updateInputs([fixture], picks, 1, now);
    expect(session.identities, same(original));
    picks.picked = 'another-channel';
    session.updateInputs([fixture], picks, 1, now);
    expect(session.identities, isNot(original));
    expect(session.matches.values.single, [strong]);
    expect(session.checked, isEmpty);
    picks.picked = null;
    session.updateInputs([fixture], picks, 1, now);
    complete([strong]);
    session
        .updateInputs([fixture], picks, 1, now.add(const Duration(minutes: 6)));
    expect(session.matches.values.single, [strong]);
    expect(session.checked, isEmpty);
    session
        .updateInputs([fixture], picks, 1, now.add(const Duration(minutes: 7)));
    expect(session.matches.values.single, isEmpty);
    expect(session.checked, isEmpty);
  });
  test(
      'trying and replacing a pick retains alternatives and rejects stale work',
      () {
    final picks = _Picks();
    final other = Channel(
        id: 'two',
        rawId: 'two',
        playlistId: 'p',
        name: 'Other feed',
        group: 'Sport',
        url: 'https://example.invalid');
    final alternative = ChannelMatch(other, MatchReason.tournament, 300);
    complete([strong, alternative]);
    final old = session.identities;
    picks.picked = 'two';
    session.updateInputs([game()], picks, 1, now);
    expect(
        session.matches.values.single.map((m) => m.channel.id), ['two', 'one']);
    expect(session.matches.values.single.first.reason, MatchReason.pick);
    expect(session.checked, isEmpty);
    expect(session.apply(batch([]), old, 1, now, complete: true), false);
    session.apply(batch([]), session.identities, 1, now, complete: false);
    expect(session.matches.values.single.length, 2);
    complete([ChannelMatch(other, MatchReason.pick, 1000), strong]);
    picks.picked = 'one';
    session.updateInputs([game()], picks, 1, now);
    expect(session.matches.values.single.first.channel.id, 'one');
    expect(
        session.matches.values.single.every(
            (m) => m.reason != MatchReason.pick || m.channel.id == 'one'),
        true);
    session.apply(batch([]), session.identities, 1, now, complete: false);
    expect(session.matches.values.single.first.channel.id, 'one');
    complete([ChannelMatch(channel, MatchReason.pick, 1000), alternative]);
    picks.picked = null;
    session.updateInputs([game()], picks, 1, now);
    expect(session.matches.values.single, [alternative]);
    complete([strong, alternative]);
    expect(session.matches.values.single, [strong, alternative]);
  });
  test('resume grace rejects partial downgrades and accepts completed recheck',
      () {
    complete([strong]);
    final resumed = now.add(const Duration(minutes: 6));
    session.updateInputs([game()], _Picks(), 1, resumed);
    expect(session.recheckingCount, 1);
    session.apply(batch([weak]), session.identities, 1, resumed,
        complete: false);
    expect(session.matches.values.single, [strong]);
    session.apply(batch([strong]), session.identities, 1, resumed,
        complete: true);
    expect(session.checked, {'eng.1:one'});
    expect(session.recheckingCount, 0);
    session.updateInputs(
        [game()], _Picks(), 1, resumed.add(const Duration(seconds: 40)));
    expect(session.matches.values.single, [strong]);
    session.apply(batch([]), session.identities, 1, resumed, complete: true);
    expect(session.matches.values.single, isEmpty);
  });
  test('resume grace is not renewed by polls and never extends programme end',
      () {
    final ending = ChannelMatch(channel, MatchReason.guide, 500,
        programme: EpgProgram(
            channelId: 'one',
            title: 'Everton vs Leeds',
            start: now,
            stop: now.add(const Duration(minutes: 6, seconds: 20))));
    complete([ending]);
    session.updateInputs(
        [game()], _Picks(), 1, now.add(const Duration(minutes: 6)));
    expect(session.matches.values.single, [ending]);
    session.updateInputs([game()], _Picks(), 1,
        now.add(const Duration(minutes: 6, seconds: 21)));
    expect(session.matches.values.single, isEmpty);
    complete([strong]);
    for (final seconds in [360, 380, 400, 420, 440]) {
      session.updateInputs(
          [game()], _Picks(), 1, now.add(Duration(seconds: seconds)));
    }
    expect(session.matches.values.single, isEmpty);
  });
  test('bursts coalesce to one running job and only the latest follow-up',
      () async {
    final work = SportsMatchWork(), gate = Completer<void>();
    final calls = <int>[];
    final first = work.request(() async {
      calls.add(0);
      await gate.future;
    });
    await Future<void>.delayed(Duration.zero);
    final futures = [first];
    for (var i = 1; i <= 1000; i++) {
      final value = i;
      futures.add(work.request(() async => calls.add(value)));
    }
    gate.complete();
    await Future.wait(futures);
    expect(calls, [0, 1000]);
    await work.request(() async => calls.add(1001));
    expect(calls.last, 1001);
  });
  test('a failed job does not poison later retries', () async {
    final work = SportsMatchWork();
    await expectLater(
        work.request(() async => throw StateError('failed')), throwsStateError);
    var completed = false;
    await work.request(() async {
      completed = true;
    });
    expect(completed, true);
  });
  test('repeated input checks keep a large completed session stable', () {
    final games = [
      for (var i = 0; i < 300; i++)
        SportsGame(
            id: 'fixture-$i',
            league: sportsLeagueById('eng.1')!,
            start: now,
            state: GameState.live,
            statusText: 'Live',
            home: game().home,
            away: game().away)
    ];
    final picks = _Picks();
    session.updateInputs(games, picks, 1, now);
    final results = {
      for (final g in games) SportsChannelPicks.eventKey(g): [strong]
    };
    session.apply(results, session.identities, 1, now, complete: true);
    final original = session.matches;
    final clock = Stopwatch()..start();
    for (var i = 0; i < 100; i++) {
      session.updateInputs(games, picks, 1, now);
      session.apply(results, session.identities, 1, now, complete: false);
    }
    clock.stop();
    expect(session.matches, same(original));
    expect(session.checked, hasLength(300));
    debugPrint('300 events / 100 unchanged input + progress updates: '
        '${clock.elapsedMicroseconds}us');
  });
  test('anchors compensate removals above and leave appends alone', () {
    expect(
        sportsAnchorDelta(
            {'a': 0, 'b': 100, 'c': 200}, {'b': 0, 'c': 100}, 125, 100),
        -100);
    expect(
        sportsAnchorDelta(
            {'a': 0, 'b': 100}, {'a': 0, 'b': 100, 'c': 200}, 125, 100),
        0);
    expect(
        sportsAnchorDelta(
            {'a': 0, 'b': 100, 'c': 200}, {'a': 0, 'c': 100}, 125, 100),
        -100);
    expect(sportsAnchorDelta({'a': 0, 'b': 100}, {}, 125, 100), 0);
  });
}
