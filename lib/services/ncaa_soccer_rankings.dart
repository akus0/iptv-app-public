import 'dart:convert';
import 'dart:typed_data';
import 'package:xml/xml.dart';
import 'sports_standings_service.dart';

/// The NCAA publishes these polls as small HTML tables, rather than a standings
/// API. Accept the verified structure only; a changed page leaves teams usable.
LeagueStandings parseNcaaSoccerRankings(
    (Uint8List, LeagueStandings, String) input) {
  final (bytes, directory, gender) = input;
  final html = utf8.decode(bytes);
  final canonical = RegExp(r'<link\s+rel="canonical"\s+href="([^"]+)"\s*/?>')
      .firstMatch(html)
      ?.group(1);
  final uri = canonical == null ? null : Uri.tryParse(canonical);
  if ((gender != 'men' && gender != 'women') ||
      uri?.host != 'www.ncaa.com' ||
      !uri!.path.startsWith('/rankings/soccer-$gender/d1/')) {
    return directory;
  }
  final source = switch (uri.pathSegments.last) {
    'united-soccer-coaches' => 'United Soccer Coaches',
    'iwsoc-coaches-poll' => 'IWSOC Coaches Poll',
    _ => null,
  };
  if (source == null) return directory;
  final updated = RegExp(
          r'<figure\s+class="rankings-last-updated"[^>]*>\s*Through Games\s+([A-Z]+)\.?\s+(\d{1,2}),\s+(\d{4})\s*</figure>')
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
  final month = updated == null ? 0 : months.indexOf(updated.group(1)!) + 1;
  final day = int.tryParse(updated?.group(2) ?? '');
  final year = int.tryParse(updated?.group(3) ?? '');
  if (month == 0 || day == null || year == null) return directory;
  final date = DateTime(year, month, day);
  if (date.day != day || date.month != month) return directory;
  final start = html.indexOf('<table'), end = html.indexOf('</table>');
  if (start < 0 || end <= start || end - start > 128 * 1024) return directory;
  final table = XmlDocument.parse(
          html.substring(start, end + 8).replaceAll('&nbsp;', '&#160;'))
      .rootElement;
  final headings = table
      .findAllElements('th')
      .map((node) => node.innerText.trim().toUpperCase())
      .toList();
  if (headings.length != 6 ||
      headings.join('|') !=
          'RANK|SCHOOL|FIRST-PLACE VOTES|RECORD|PREVIOUS|POINTS') {
    return directory;
  }
  String normal(String name) =>
      name.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
  final teams = <String, StandingTeam>{};
  final byName = <String, Set<String>>{};
  for (final group in directory.tables) {
    for (final row in group.rows) {
      teams[row.team.id] = row;
      for (final name in {
        row.team.name,
        row.team.shortName,
        ...row.nameAliases
      }) {
        if (name.isNotEmpty) {
          byName.putIfAbsent(normal(name), () => {}).add(row.team.id);
        }
      }
    }
  }
  final ranked = <StandingTeam>[];
  final seen = <String>{};
  for (final row in table
      .findAllElements('tbody')
      .expand((body) => body.findElements('tr'))) {
    final cells =
        row.findElements('td').map((cell) => cell.innerText.trim()).toList();
    if (cells.length != headings.length) return directory;
    final position = RegExp(r'^T?(\d{1,2})$').firstMatch(cells[0]);
    final rank = int.tryParse(position?.group(1) ?? '');
    final ids = byName[normal(cells[1])];
    final record =
        RegExp(r'^(\d{1,2})-(\d{1,2})-(\d{1,2})$').firstMatch(cells[3]);
    final points = int.tryParse(cells[5]);
    if (rank == null ||
        rank < 1 ||
        rank > 25 ||
        ids?.length != 1 ||
        record == null ||
        points == null ||
        points < 0 ||
        !seen.add(ids!.single)) {
      return directory;
    }
    final team = teams[ids.single]!;
    ranked.add(StandingTeam(
        team.team,
        {
          'wins': record.group(1)!,
          'losses': record.group(2)!,
          'ties': record.group(3)!,
          'pollPoints': '$points',
          'overall': cells[3],
        },
        rank,
        statLabels: const {
          'wins': 'Wins',
          'losses': 'Losses',
          'ties': 'Draws',
          'pollPoints': 'Poll points',
          'overall': 'Record (W-L-T)',
        },
        nameAliases: team.nameAliases));
  }
  // Ties can increase the number of schools in a top-25 poll. Partial or unknown
  // tables must not silently become a complete-looking national ranking.
  if (ranked.length < 25 || ranked.length > 40) return directory;
  final others =
      teams.values.where((row) => !seen.contains(row.team.id)).toList();
  return LeagueStandings(
      rankings: true,
      rankingTitle: 'National rankings',
      sourceName: source,
      updatedAt: date,
      tables: [
        StandingTable(
            'Division I national rankings', List.unmodifiable(ranked)),
        if (others.isNotEmpty)
          StandingTable('Other available teams', List.unmodifiable(others)),
      ]);
}
