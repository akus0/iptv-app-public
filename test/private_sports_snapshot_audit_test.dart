import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:nox_iptv/models/sports.dart';
import '../tools/tv_sports_alias_audit.dart' as audit;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const source = String.fromEnvironment('SPORTS_SNAPSHOT_FILE');
  const report = String.fromEnvironment('SPORTS_SNAPSHOT_REPORT');
  test('snapshot preserves matching evidence and absolute fixture times', () {
    const team = SportsTeam(
        id: 'a',
        name: 'Alpha',
        shortName: 'Alpha',
        abbreviation: 'ALP',
        location: 'City',
        matchingNames: ['Alternate']);
    final game = SportsGame(
        id: 'fixture',
        league: sportsLeagueById('nba')!,
        start: DateTime(2026, 11, 7, 12),
        state: GameState.live,
        statusText: 'Suspended',
        home: team,
        away: team,
        source: 'ESPN',
        broadcasts: const ['Network'],
        scoreboardBroadcasts: const [
          SportsBroadcast('Network',
              source: 'ESPN',
              country: 'AU',
              medium: 'TV',
              market: 'national',
              language: 'en',
              requiresGuide: true,
              tournamentOnly: true)
        ],
        event: const SportsEventInfo(title: 'Tournament', playActive: false));
    final encoded = audit.gameJson(game);
    expect(encoded['start'], endsWith('Z'));
    final restored = audit.gameFrom(jsonDecode(jsonEncode(encoded)));
    expect(restored.start.isAtSameMomentAs(game.start), true);
    expect(restored.statusText, game.statusText);
    expect(restored.source, game.source);
    expect(restored.isLive, false);
    expect(restored.home.matchingNames, team.matchingNames);
    expect(restored.scoreboardBroadcasts.single.evidenceKey,
        game.scoreboardBroadcasts.single.evidenceKey);
  });
  test('older snapshots retain safe defaults', () {
    final old = audit.gameJson(SportsGame(
        id: 'old',
        league: sportsLeagueById('nba')!,
        start: DateTime.utc(2026),
        state: GameState.pre,
        statusText: '',
        home: const SportsTeam(
            id: 'h', name: 'Home', shortName: 'Home', abbreviation: ''),
        away: const SportsTeam(
            id: 'a', name: 'Away', shortName: 'Away', abbreviation: '')))
      ..remove('scoreboardBroadcasts')
      ..remove('source')
      ..remove('statusText');
    final restored = audit.gameFrom(old);
    expect(restored.source, 'ESPN');
    expect(restored.scoreboardBroadcasts, isEmpty);
    expect(restored.statusText, '');
  });
  test('frozen guide and fixture discovery audit', () async {
    final result = await audit.measure(await File(source).readAsString());
    await File(report).writeAsString(jsonEncode(result));
    expect(result['queries'], result['events'] == 0 ? 0 : 1);
    expect(result['discoveryReused'], true);
    expect(result['guideBindingQueries'], 0);
    expect(result['boundGuideEvents'], result['discoveredEvents']);
  }, skip: source.isEmpty ? 'Optional private guide snapshot.' : false);
}
