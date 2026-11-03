import 'dart:convert';
import 'dart:typed_data';
import 'package:xml/xml.dart';
import '../models/sports.dart';
import 'sports_standings_service.dart';

/// ESPN's field-hockey team collection is empty, while its season scoreboard
/// supplies the same team identities used by live events and favourites.
LeagueStandings parseFieldHockeyTeams((Uint8List, int) input) {
  final (bytes, year) = input;
  final root = jsonDecode(utf8.decode(bytes));
  if (root is! Map || root['leagues'] is! List || root['events'] is! List) {
    return const LeagueStandings();
  }
  final leagues = root['leagues'] as List;
  if (leagues.length != 1 ||
      leagues.single is! Map ||
      leagues.single['id'] != '802' ||
      leagues.single['slug'] != 'womens-college-field-hockey' ||
      leagues.single['season']?['year'] != year ||
      (root['events'] as List).length > 1000) {
    return const LeagueStandings();
  }
  final teams = <String, StandingTeam>{};
  for (final event in root['events']) {
    if (event is! Map ||
        event['season']?['year'] != year ||
        event['competitions'] is! List) {
      continue;
    }
    for (final competition in event['competitions']) {
      if (competition is! Map || competition['competitors'] is! List) continue;
      for (final competitor in competition['competitors']) {
        if (competitor is! Map || competitor['team'] is! Map) continue;
        final raw = competitor['team'] as Map;
        final id = raw['id'],
            name = raw['displayName'],
            location = raw['location'];
        if (id is! String ||
            !RegExp(r'^[1-9]\d{0,8}$').hasMatch(id) ||
            raw['uid'] != 's:800~l:802~t:$id' ||
            name is! String ||
            name.isEmpty ||
            location is! String ||
            location.isEmpty) {
          continue;
        }
        teams[id] = StandingTeam(
            SportsTeam(
              id: id,
              name: name,
              shortName: raw['shortDisplayName'] as String? ?? location,
              location: location,
              abbreviation: raw['abbreviation'] as String? ?? '',
              logoUrl: raw['logo'] as String?,
              color: raw['color'] as String?,
            ),
            const {},
            null,
            nameAliases: {
              location,
              if (raw['abbreviation'] is String) raw['abbreviation'] as String,
            });
      }
    }
  }
  if (teams.length > 200) return const LeagueStandings();
  final rows = teams.values.toList()
    ..sort((a, b) => a.team.name.compareTo(b.team.name));
  return LeagueStandings(directory: true, season: '$year', tables: [
    StandingTable('Teams', List.unmodifiable(rows)),
  ]);
}

/// The NCAA RPI ranks the whole Division I field, not conference positions.
/// Preserve published ranks and records and require every school to join to an
/// existing ESPN identity before replacing the usable team directory.
LeagueStandings parseFieldHockeyRankings(
    (Uint8List, LeagueStandings, DateTime) input) {
  final (bytes, directory, now) = input;
  final html = utf8.decode(bytes);
  final canonical = RegExp(r'<link\s+rel="canonical"\s+href="([^"]+)"\s*/?>')
      .firstMatch(html)
      ?.group(1);
  if (canonical !=
      'https://www.ncaa.com/rankings/fieldhockey/d1/ncaa-field-hockey-rpi') {
    return directory;
  }
  final updated = RegExp(
          r'<figure\s+class="rankings-last-updated"[^>]*>\s*Through Games\s+([A-Za-z]+)\.?\s+(\d{1,2}),?\s+(\d{4})\s*</figure>')
      .firstMatch(html);
  const months = [
    'JAN',
    'FEB',
    'MAR',
    'APR',
    'MAY',
    'JUN',
    'JUL',
    'AUG',
    'SEP',
    'OCT',
    'NOV',
    'DEC'
  ];
  final month = months.indexOf(updated?.group(1)?.toUpperCase() ?? '') + 1;
  final day = int.tryParse(updated?.group(2) ?? '');
  final year = int.tryParse(updated?.group(3) ?? '');
  if (month == 0 ||
      day == null ||
      year == null ||
      '$year' != directory.season) {
    return directory;
  }
  final date = DateTime(year, month, day);
  if (date.day != day ||
      date.month != month ||
      date.isAfter(now.add(const Duration(days: 1)))) {
    return directory;
  }
  final start = html.indexOf('<table'), end = html.indexOf('</table>');
  if (start < 0 || end <= start || end - start > 128 * 1024) return directory;
  final xml = html
      .substring(start, end + 8)
      .replaceAll('&nbsp;', '&#160;')
      .replaceAll(
          RegExp(r'&(?!#\d+;|#x[0-9a-fA-F]+;|amp;|lt;|gt;|quot;|apos;)'),
          '&amp;');
  final table = XmlDocument.parse(xml).rootElement;
  if (table
          .findAllElements('th')
          .map((e) => e.innerText.trim().toUpperCase())
          .join('|') !=
      'RANK|SCHOOL|RECORD|CONF|ROAD|NEUTRAL|HOME|NON-DIV I|PREV') {
    return directory;
  }
  String normal(String name) =>
      name.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
  const aliases = {
    'penn st.': 'penn state',
    'ohio st.': 'ohio state',
    'michigan st.': 'michigan state',
    'kent st.': 'kent state',
    'ball st.': 'ball state',
    'boston u.': 'boston university',
    'queens (nc)': 'queens university',
    'central mich.': 'central michigan',
  };
  final teams = <String, StandingTeam>{};
  final names = <String, Set<String>>{};
  for (final group in directory.tables) {
    for (final row in group.rows) {
      teams[row.team.id] = row;
      for (final name in {
        row.team.name,
        row.team.shortName,
        ...row.nameAliases
      }) {
        if (name.isNotEmpty) {
          names.putIfAbsent(normal(name), () => {}).add(row.team.id);
        }
      }
    }
  }
  final ranked = <StandingTeam>[], seen = <String>{};
  for (final row in table
      .findAllElements('tbody')
      .expand((body) => body.findElements('tr'))) {
    final cells =
        row.findElements('td').map((e) => e.innerText.trim()).toList();
    if (cells.length != 9) return directory;
    final rank = int.tryParse(cells[0]);
    final name = normal(cells[1]);
    final ids = names[aliases[name] ?? name];
    final record = RegExp(r'^(\d{1,2})-(\d{1,2})$').firstMatch(cells[2]);
    if (rank == null ||
        rank < 1 ||
        rank > 82 ||
        ids?.length != 1 ||
        record == null ||
        !seen.add(ids!.single) ||
        (rank != ranked.length + 1 &&
            (ranked.isEmpty || rank != ranked.last.position))) {
      return directory;
    }
    final original = teams[ids.single]!;
    ranked.add(StandingTeam(
        original.team,
        {
          'wins': record.group(1)!,
          'losses': record.group(2)!,
          'overall': cells[2],
        },
        rank,
        nameAliases: original.nameAliases,
        statLabels: const {
          'wins': 'Wins',
          'losses': 'Losses',
          'overall': 'Record (W-L)',
        }));
  }
  // The verified Division I publication contains 82 schools. A partial table
  // or changed competition membership should fall back instead of hiding teams.
  if (ranked.length != 82) return directory;
  final others =
      teams.values.where((row) => !seen.contains(row.team.id)).toList();
  return LeagueStandings(
      rankings: true,
      rankingTitle: 'National RPI rankings',
      sourceName: 'NCAA',
      updatedAt: date,
      season: '$year',
      tables: [
        StandingTable(
            'Division I national RPI rankings', List.unmodifiable(ranked)),
        if (others.isNotEmpty)
          StandingTable('Other available teams', List.unmodifiable(others)),
      ]);
}
