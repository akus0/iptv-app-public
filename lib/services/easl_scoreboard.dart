import 'dart:convert';

import '../models/sports.dart';

/// EASL's public website scoreboard supplies the current season in one reply.
/// DRAFT fixtures have no confirmed teams/time and must stay out of Events.
List<SportsGame> parseEaslScoreboard(String body, SportsLeague league) {
  final rows = jsonDecode(body);
  if (rows is! List) throw const FormatException('Expected EASL schedule');
  final games = <SportsGame>[];
  final seen = <String>{};
  for (final row in rows) {
    if (row is! Map) continue;
    try {
      final state = switch (row['status']) {
        'SCHEDULED' => GameState.pre,
        'IN_PROGRESS' => GameState.live,
        'CONFIRMED' => GameState.post,
        _ => null,
      };
      final id = row['fixtureId']?.toString().trim() ?? '';
      final stamp = row['startTimeUTC']?.toString().trim() ?? '';
      if (state == null || id.isEmpty || stamp.isEmpty) continue;
      // The field is explicitly UTC; the website omits its trailing Z.
      final start = DateTime.parse(
          RegExp(r'(?:Z|[+-]\d\d:\d\d)$').hasMatch(stamp)
              ? stamp
              : '${stamp}Z');
      final competitors = row['competitors'];
      if (competitors is! List || competitors.length != 2) continue;
      SportsTeam? home, away;
      for (final side in competitors) {
        if (side is! Map || side['isHome'] is! bool) continue;
        final names = [side['nameFullLatin'], side['nameFullLocal']]
            .whereType<String>()
            .map((s) => s.trim())
            .where((s) => s.isNotEmpty)
            .toList();
        // Some teams reverse the feed's Latin/local fields. Prefer the English
        // name when supplied, retaining the original name as a fallback.
        final name =
            names.where((s) => RegExp(r'[A-Za-z]').hasMatch(s)).firstOrNull ??
                names.firstOrNull ??
                '';
        final teamId =
            (side['teamId'] ?? side['entityId'])?.toString().trim() ?? '';
        if (name.isEmpty || teamId.isEmpty) continue;
        final score = int.tryParse('${side['score']}');
        final team = SportsTeam(
            id: 'easl:$teamId',
            name: name,
            shortName: name,
            abbreviation: [side['codeLatin'], side['codeLocal']]
                    .whereType<String>()
                    .where((s) => s.trim().isNotEmpty)
                    .firstOrNull ??
                '',
            score: state != GameState.pre && score != null && score >= 0
                ? '$score'
                : null);
        if (side['isHome'] == true) {
          home = team;
        } else {
          away = team;
        }
      }
      if (home == null || away == null || !seen.add(id)) continue;
      games.add(SportsGame(
          id: 'easl:$id',
          league: league,
          start: start.toUtc(),
          state: state,
          statusText: switch (state) {
            GameState.pre => 'Scheduled',
            GameState.live => 'Live',
            GameState.post => 'Final',
          },
          home: home,
          away: away,
          source: 'EASL'));
    } catch (_) {
      // Skip incomplete fixtures independently of the rest of the season.
    }
  }
  return games;
}
