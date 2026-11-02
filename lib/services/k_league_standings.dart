import 'dart:convert';
import 'dart:typed_data';
import '../models/sports.dart';
import 'sports_standings_service.dart';

/// The official league website publishes the same team IDs used by its schedule
/// feed. Retain published positions and final-round groups, including deductions.
LeagueStandings parseKLeagueStandings((Uint8List, SportsLeague, int) input) {
  final (bytes, league, requestedYear) = input;
  final root = jsonDecode(utf8.decode(bytes));
  if (root is! Map ||
      '${root['resultCode']}' != '200' ||
      root['data'] is! Map) {
    throw const FormatException('Invalid K League standings');
  }
  final data = root['data'] as Map;
  final year = int.tryParse('${data['year']}');
  final leagueId = league.id == 'kor.1'
      ? 1
      : league.id == 'kor.2'
          ? 2
          : null;
  final entries = data['teamRank'];
  if (leagueId == null ||
      year == null ||
      year < 2000 ||
      year > requestedYear ||
      entries is! List ||
      data['isSplitRank'] is! bool ||
      entries.length > 64) {
    throw const FormatException('Unexpected K League standings');
  }
  final split = data['isSplitRank'] == true;
  final groups = <String, List<StandingTeam>>{};
  final ids = <String>{};
  for (final entry in entries) {
    if (entry is! Map ||
        int.tryParse('${entry['leagueId']}') != leagueId ||
        int.tryParse('${entry['year']}') != year) {
      throw const FormatException('Unexpected K League team');
    }
    final id = entry['teamId'], name = entry['teamName'];
    final rank = int.tryParse('${entry['rank']}');
    if (id is! String ||
        !RegExp(r'^K\d{2,4}$').hasMatch(id) ||
        name is! String ||
        name.trim().isEmpty ||
        !ids.add(id) ||
        rank == null ||
        rank < 0 ||
        rank > 64) {
      throw const FormatException('Invalid K League team');
    }
    final group = split
        ? switch (int.tryParse('${entry['assignGameType']}')) {
            23 => 'Final A',
            24 => 'Final B',
            _ => null,
          }
        : league.name;
    if (group == null) throw const FormatException('Unknown K League phase');
    final stats = <String, String>{};
    for (final field in const {
      'gameCount': 'gamesPlayed',
      'winCnt': 'wins',
      'tieCnt': 'ties',
      'lossCnt': 'losses',
      'gapCnt': 'pointDifferential',
      'gainPoint': 'points',
      'gainGoal': 'pointsFor',
      'lossGoal': 'pointsAgainst',
    }.entries) {
      final value = int.tryParse('${entry[field.key]}');
      if (value == null) {
        throw const FormatException('Invalid K League statistic');
      }
      stats[field.value] = '$value';
    }
    groups.putIfAbsent(group, () => []).add(StandingTeam(
            SportsTeam(
                id: 'kleague:$id',
                name: name,
                shortName: name,
                abbreviation: '',
                logoUrl:
                    'https://www.kleague.com/assets/images/emblem/emblem_$id.png'),
            Map.unmodifiable(stats),
            rank == 0 ? null : rank,
            statLabels: const {
              'gamesPlayed': 'Games played',
              'wins': 'Wins',
              'ties': 'Draws',
              'losses': 'Losses',
              'pointDifferential': 'Goal difference',
              'points': 'Points',
              'pointsFor': 'Goals for',
              'pointsAgainst': 'Goals against',
            }));
  }
  final order = split ? ['Final A', 'Final B'] : [league.name];
  return LeagueStandings(
      season: '$year',
      previousSeason: year < requestedYear,
      sourceName: 'K League',
      tables: [
        for (final name in order)
          if (groups[name] case final rows?)
            StandingTable(name, List.unmodifiable(rows)),
      ]);
}
