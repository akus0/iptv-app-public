import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:nox_iptv/models/sports.dart';
import 'package:nox_iptv/services/sports_channel_matcher.dart';
import 'package:nox_iptv/services/storage_service.dart';

SportsGame game(String id, {String league = 'nfl'}) => SportsGame(
    id: id,
    league: sportsLeagueById(league)!,
    start: DateTime.now(),
    state: GameState.pre,
    statusText: '',
    home:
        const SportsTeam(id: 'a', name: 'A', shortName: 'A', abbreviation: 'A'),
    away: const SportsTeam(
        id: 'b', name: 'B', shortName: 'B', abbreviation: 'B'));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late StorageService storage;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    storage = StorageService();
    await storage.init();
  });

  test('independent picker saves retain both choices without awaiting writes',
      () async {
    final a = SportsChannelPicks.load(storage);
    final b = SportsChannelPicks.load(storage);
    final first = game('one'), second = game('two');
    await Future.wait([
      a.pickForGame(first, 'p::first'),
      b.pickForGame(second, 'p::second'),
    ]);
    final saved = SportsChannelPicks.load(storage);
    expect(saved.channelIdFor(first), 'p::first');
    expect(saved.channelIdFor(second), 'p::second');
  });

  test('an older picker cannot resurrect a cleared choice', () async {
    final a = SportsChannelPicks.load(storage), first = game('one');
    await a.pickForGame(first, 'p::first');
    final stale = SportsChannelPicks.load(storage);
    await a.clearFor(first);
    await stale.pickForGame(game('two'), 'p::second');
    final saved = SportsChannelPicks.load(storage);
    expect(saved.channelIdFor(first), isNull);
    expect(saved.channelIdFor(game('two')), 'p::second');
  });

  test('team preference replaces its event choice and retains another event',
      () async {
    final first = game('one'), second = game('two');
    final a = SportsChannelPicks.load(storage);
    await a.pickForGame(first, 'p::old');
    final stale = SportsChannelPicks.load(storage);
    await a.pickForGame(second, 'p::second');
    await stale.pickForTeam(first, first.home, 'p::team');
    final saved = SportsChannelPicks.load(storage);
    expect(saved.channelIdFor(first), 'p::team');
    expect(saved.channelIdFor(second), 'p::second');
  });

  test('series preference and reset preserve unrelated saved choices',
      () async {
    final first = game('one', league: 'tennis.atp');
    final second = game('two');
    final a = SportsChannelPicks.load(storage);
    final b = SportsChannelPicks.load(storage);
    await a.pickForGame(second, 'p::second');
    await b.pickForSeries(first, 'p::tour');
    expect(SportsChannelPicks.load(storage).channelIdFor(second), 'p::second');
    await a.clearFor(first);
    final saved = SportsChannelPicks.load(storage);
    expect(saved.channelIdFor(first), isNull);
    expect(saved.channelIdFor(second), 'p::second');
  });

  test('legacy network preference does not overwrite newer event choices',
      () async {
    final a = SportsChannelPicks.load(storage);
    final b = SportsChannelPicks.load(storage);
    final first = game('one');
    await a.pickForGame(first, 'p::first');
    await b.setRedZone('p::network');
    expect(SportsChannelPicks.load(storage).channelIdFor(first), 'p::first');
    await a.setRedZone(null);
    final saved = SportsChannelPicks.load(storage);
    expect(saved.redZoneChannelId, isNull);
    expect(saved.channelIdFor(first), 'p::first');
  });
}
