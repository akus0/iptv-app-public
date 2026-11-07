import 'dart:convert';

import '../models/sports.dart';

/// The official schedule endpoint returns one month in Korea Standard Time.
/// Its explicit period codes determine live state, never the scheduled clock.
List<SportsGame> parseKLeagueScoreboard(String body, SportsLeague league) {
  final json = jsonDecode(body);
  if (json is! Map || json['resultCode']?.toString() != '200') {
    throw const FormatException('K League schedule unavailable');
  }
  final data = json['data'];
  final rows = data is Map ? data['scheduleList'] : null;
  if (rows is! List) {
    throw const FormatException('Expected K League schedule');
  }
  final games = <SportsGame>[];
  final seen = <String>{};
  for (final row in rows) {
    if (row is! Map) continue;
    try {
      if (row['leagueId']?.toString() != league.id.split('.').last) continue;
      final date = row['gameDate']?.toString() ?? '';
      final time = row['gameTime']?.toString() ?? '';
      if (!RegExp(r'^\d{4}\.\d{2}\.\d{2}$').hasMatch(date) ||
          !RegExp(r'^(?:[01]\d|2[0-3]):[0-5]\d$').hasMatch(time)) {
        continue;
      }
      final start =
          DateTime.parse('${date.replaceAll('.', '-')}T$time:00+09:00');
      final local = start.add(const Duration(hours: 9));
      if (local.toIso8601String().substring(0, 10) !=
          date.replaceAll('.', '-')) {
        continue;
      }
      final gameId = row['gameId']?.toString() ?? '';
      if (gameId.isEmpty) continue;
      final id = 'kleague:${local.year}:${league.id}:$gameId';
      final status = row['gameStatus']?.toString().trim() ?? '';
      final finished = status == 'FE' || row['endYn'] == 'Y';
      final period = RegExp(r'^([1-4])([SE])\s*(\d{1,3})?$').firstMatch(status);
      // Unknown non-empty states may mean postponement or suspension.
      if (!finished && status.isNotEmpty && period == null) continue;
      final live = !finished && period != null;
      final phase = period?[1];
      final minute = period?[3];
      final statusText = finished
          ? 'Final'
          : !live
              ? 'Scheduled'
              : status == '1E'
                  ? 'Half-time'
                  : '${switch (phase) {
                      '1' => '1st half',
                      '2' => '2nd half',
                      _ => 'Extra time',
                    }}${minute == null ? '' : ' · $minute′'}';
      SportsTeam team(String side) {
        final teamId = row['${side}Team']?.toString().trim() ?? '';
        final name = row['${side}TeamName']?.toString().trim() ?? '';
        if (teamId.isEmpty || name.isEmpty) {
          throw const FormatException('Missing K League team');
        }
        final score = int.tryParse('${row['${side}Goal']}');
        return SportsTeam(
            id: 'kleague:$teamId',
            name: name,
            shortName: name == 'DAEJEON HANA' ? 'Daejeon' : name,
            abbreviation: '',
            score: (live || finished) && score != null && score >= 0
                ? '$score'
                : null);
      }

      final home = team('home'), away = team('away');
      if (!seen.add(id)) continue;
      games.add(SportsGame(
          id: id,
          league: league,
          start: start,
          state: finished
              ? GameState.post
              : live
                  ? GameState.live
                  : GameState.pre,
          statusText: statusText,
          home: home,
          away: away,
          source: 'K League',
          broadcasts: (row['broadcastName']?.toString() ?? '')
              .split('//')
              .map((s) => s.trim())
              .where((s) => s.isNotEmpty && s != 'null')
              .toSet()
              .toList()));
    } catch (_) {
      // An incomplete fixture must not hide the rest of the schedule.
    }
  }
  return games;
}
