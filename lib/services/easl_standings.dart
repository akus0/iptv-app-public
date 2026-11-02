import 'dart:convert';
import 'dart:typed_data';
import '../models/sports.dart';
import 'sports_standings_service.dart';

/// The current-season feed used by EASL's own website. Team UUIDs also appear
/// in its schedule, so following a row retains the same event identity.
LeagueStandings parseEaslStandings(Uint8List bytes) {
  final entries = jsonDecode(utf8.decode(bytes));
  if (entries is! List || entries.isEmpty || entries.length > 64) {
    throw const FormatException('Invalid EASL standings');
  }
  final groups = <String, List<StandingTeam>>{};
  final ids = <String>{};
  final ranks = <String, Set<int>>{};
  for (final entry in entries) {
    if (entry is! Map ||
        entry['team'] is! Map ||
        entry['pool'] is! Map ||
        entry['stats'] is! Map) {
      throw const FormatException('Invalid EASL row');
    }
    final team = entry['team'] as Map, pool = entry['pool'] as Map;
    final id = team['id'], name = team['name'], group = pool['name'];
    final position = entry['position'];
    if (id is! String ||
        !RegExp(r'^[a-f0-9-]{36}$').hasMatch(id) ||
        !ids.add(id) ||
        name is! String ||
        name.trim().isEmpty ||
        group is! String ||
        group.trim().isEmpty ||
        position is! int ||
        position < 1 ||
        position > 64 ||
        !ranks.putIfAbsent(group, () => {}).add(position)) {
      throw const FormatException('Invalid EASL identity or position');
    }
    final rawStats = entry['stats'] as Map;
    final stats = <String, String>{};
    for (final field in const {
      'gamePlayed': 'gamesPlayed',
      'wins': 'wins',
      'losses': 'losses',
      'pointDifference': 'pointDifferential',
      'pointsFor': 'pointsFor',
      'pointsAgainst': 'pointsAgainst',
    }.entries) {
      final value = rawStats[field.key];
      if (value is! int ||
          value.abs() > 100000 ||
          (field.key != 'pointDifference' && value < 0)) {
        throw const FormatException('Invalid EASL statistic');
      }
      stats[field.value] = '$value';
    }
    final percent = rawStats['winPercentage'];
    if (percent is! num || !percent.isFinite || percent < 0 || percent > 1) {
      throw const FormatException('Invalid EASL percentage');
    }
    stats['winPercent'] = percent.toStringAsFixed(3);
    final logo = team['logo'] is String ? Uri.tryParse(team['logo']) : null;
    groups.putIfAbsent(group, () => []).add(StandingTeam(
          SportsTeam(
              id: 'easl:$id',
              name: name,
              shortName: name,
              abbreviation: team['code'] is String ? team['code'] : '',
              logoUrl: logo?.scheme == 'https' &&
                      logo!.host.isNotEmpty &&
                      logo.userInfo.isEmpty
                  ? logo.toString()
                  : null),
          Map.unmodifiable(stats),
          position,
          statLabels: const {
            'gamesPlayed': 'Games played',
            'wins': 'Wins',
            'losses': 'Losses',
            'winPercent': 'Win percentage',
            'pointDifferential': 'Points difference',
            'pointsFor': 'Points for',
            'pointsAgainst': 'Points against'
          },
        ));
  }
  final names = groups.keys.toList()..sort();
  // The endpoint deliberately has no season year. Do not infer one from dates
  // of recent matches, which can span two calendar years.
  return LeagueStandings(sourceName: 'EASL', tables: [
    for (final name in names)
      StandingTable(
          name,
          List.unmodifiable(groups[name]!
            ..sort((a, b) => a.position!.compareTo(b.position!)))),
  ]);
}
