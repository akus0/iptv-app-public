import 'package:flutter_test/flutter_test.dart';
import 'package:nox_iptv/models/sports.dart';
import 'package:nox_iptv/models/sports_details.dart';
import 'package:nox_iptv/utils/sports_detail_presentation.dart';

void main() {
  const league = SportsLeague(
      id: 'nba',
      espnPath: 'basketball/nba',
      name: 'NBA',
      shortName: 'NBA',
      logoUrl: '');
  SportsGame fixture(GameState state) => SportsGame(
      id: '1',
      league: league,
      start: DateTime.utc(2026),
      state: state,
      statusText: '',
      home: const SportsTeam(
          id: 'h',
          name: 'Home',
          shortName: 'Home',
          abbreviation: 'H',
          record: '8-2'),
      away: const SportsTeam(
          id: 'a',
          name: 'Away',
          shortName: 'Away',
          abbreviation: 'A',
          record: '7-3'),
      broadcasts: const ['Local coverage']);
  test('pregame record context uses fixture snapshot and respects score hiding',
      () {
    expect(sportsFixtureInsight(fixture(GameState.pre), hideScores: false),
        contains('8-2'));
    expect(sportsFixtureInsight(fixture(GameState.pre), hideScores: true),
        'Local coverage');
    expect(sportsFixtureInsight(fixture(GameState.post), hideScores: false),
        'Local coverage');
  });
  test('baseball summary prefers hits over sacrifice hits', () {
    const baseball = SportsLeague(
        id: 'mlb',
        espnPath: 'baseball/mlb',
        name: 'MLB',
        shortName: 'MLB',
        logoUrl: '');
    const section = SportsDetailSection('Stats', rows: [
      SportsDetailRow('Sacrifice hits', ['0', '0'], id: 'Batting:sacHits'),
      SportsDetailRow('Hits', ['7', '9'], id: 'Batting:hits'),
      SportsDetailRow('Runs', ['4', '1'], id: 'Batting:runs'),
    ]);
    expect(sportsKeyStatistics(baseball, section).map((row) => row.label),
        ['Hits', 'Runs']);
  });
  test('sport terminology distinguishes innings, lineups and player tables',
      () {
    expect(sportsDetailProfile(league).players, 'Players');
    expect(
        sportsDetailProfile(const SportsLeague(
                id: 'mlb',
                espnPath: 'baseball/mlb',
                name: 'MLB',
                shortName: 'MLB',
                logoUrl: ''))
            .periods,
        'By inning');
    expect(
        sportsDetailProfile(const SportsLeague(
                id: 'eng.1',
                espnPath: 'soccer/eng.1',
                name: 'Premier League',
                shortName: 'EPL',
                logoUrl: ''))
            .players,
        'Lineups');
  });
}
