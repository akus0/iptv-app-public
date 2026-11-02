import '../models/sports.dart';
import '../models/sports_details.dart';

/// Presentation profiles only: source numbers and order are never recalculated.
class SportsDetailProfile {
  const SportsDetailProfile(
      this.statistics, this.players, this.periods, this.keyStats);
  final String statistics, players, periods;
  final List<String> keyStats;
}

SportsDetailProfile sportsDetailProfile(SportsLeague league) =>
    switch (league.espnPath.split('/').first) {
      'soccer' => const SportsDetailProfile('Match stats', 'Lineups', 'By half',
          ['possession', 'shotsontarget', 'shotson', 'totalshots', 'fouls']),
      'basketball' => const SportsDetailProfile('Team stats', 'Players',
          'By period', ['rebounds', 'assists', 'turnovers', 'fieldgoalpct']),
      'football' => const SportsDetailProfile(
          'Team stats',
          'Players',
          'By quarter',
          ['totalyards', 'passingyards', 'rushingyards', 'turnovers']),
      'baseball' => const SportsDetailProfile('Team stats', 'Box score',
          'By inning', ['hits', 'runs', 'errors', 'strikeouts']),
      'hockey' => const SportsDetailProfile('Team stats', 'Players',
          'By period', ['shots', 'powerplay', 'faceoff', 'hits']),
      'rugby' => const SportsDetailProfile('Match stats', 'Lineups', 'By half',
          ['possession', 'territory', 'tackles', 'penalties']),
      'racing' =>
        const SportsDetailProfile('Results', 'Drivers', 'Sessions', []),
      'golf' =>
        const SportsDetailProfile('Leaderboard', 'Players', 'Rounds', []),
      'tennis' => const SportsDetailProfile('Match stats', 'Players', 'By set',
          ['aces', 'doublefaults', 'firstserve', 'breakpoints']),
      _ => const SportsDetailProfile('Statistics', 'Players', 'By period', []),
    };

final _statCharacters = RegExp('[^a-z]');

List<SportsDetailRow> sportsKeyStatistics(
    SportsLeague league, SportsDetailSection section) {
  final priorities = sportsDetailProfile(league).keyStats;
  final result = <SportsDetailRow>[];
  final normalized = [
    for (final row in section.rows)
      (
        row,
        (row.id?.split(':').last ?? row.label)
            .toLowerCase()
            .replaceAll(_statCharacters, '')
      )
  ];
  for (final term in priorities) {
    // Exact names keep hits distinct from sacrifice hits and similar substats.
    final match = normalized.where((entry) => entry.$2 == term).firstOrNull ??
        normalized.where((entry) => entry.$2.startsWith(term)).firstOrNull;
    if (match != null && !result.contains(match.$1)) result.add(match.$1);
    if (result.length == 3) break;
  }
  return result;
}

bool sportsPlayerSection(SportsDetailSection section) =>
    section.kind == SportsDetailKind.players ||
    section.kind == SportsDetailKind.lineup;

/// A provider snapshot already attached to the fixture; never an extra lookup.
String? sportsFixtureInsight(SportsGame game, {required bool hideScores}) {
  if (game.state != GameState.pre && !hideScores) {
    if (game.situation?.text case final text? when text.isNotEmpty) return text;
    if (game.leaders.firstOrNull case final leader?) {
      return '${leader.stat} · ${leader.name} ${leader.value}';
    }
    if (game.event?.leaders.firstOrNull case final leader?) {
      return '${game.state == GameState.post ? '1st' : 'Leader'} · ${leader.name}${leader.value == null ? '' : ' · ${leader.value}'}';
    }
  }
  if (game.state == GameState.pre && !hideScores) {
    final records = [
      for (final team in [game.first, game.second])
        if (team.record?.isNotEmpty == true)
          '${team.abbreviation.isEmpty ? team.shortName : team.abbreviation} ${team.record}'
    ];
    if (records.isNotEmpty) return records.join(' · ');
  }
  final event = game.event;
  final context = [event?.session, event?.venue, event?.court]
      .whereType<String>()
      .where((s) => s.isNotEmpty)
      .toSet();
  if (context.isNotEmpty) return context.join(' · ');
  return game.broadcasts.isNotEmpty
      ? game.broadcasts.take(2).join(' · ')
      : null;
}
