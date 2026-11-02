import 'dart:convert';
import 'dart:typed_data';
import '../models/sports.dart';
import 'sports_standings_service.dart';

/// Published RugbyPass tables are accepted only with the expected competition,
/// season, membership and unique existing ESPN identities.
LeagueStandings parseRugbyPassStandings(
    (Uint8List, LeagueStandings, int, String) input) {
  final (bytes, directory, requestedYear, leagueId) = input;
  final config = switch (leagueId) {
    'rugby.270563' => (
        'bunnings-npc',
        1001,
        'New Zealand NPC',
        14,
        'NPC Table'
      ),
    'rugby.270559' => ('top-14', 1002, 'Top 14', 14, 'Top 14 Standings'),
    'rugby.289262' => (
        'major-league-rugby',
        1174,
        'Major League Rugby',
        6,
        'Major League Rugby Standings'
      ),
    _ => null,
  };
  if (config == null) return directory;
  final html = utf8.decode(bytes);
  final canonical = RegExp(r'<link\s+rel="canonical"\s+href="([^"]+)"\s*/?>')
      .firstMatch(html)
      ?.group(1);
  if (canonical != 'https://www.rugbypass.com/${config.$1}/standings/') {
    return directory;
  }
  const init = 'CompStandings.init(';
  final seasonStart = html.indexOf(init);
  final seasonEnd = seasonStart < 0 ? -1 : html.indexOf(')', seasonStart);
  if (seasonStart < 0 ||
      seasonEnd < seasonStart ||
      seasonEnd - seasonStart > 8192) {
    return directory;
  }
  final arguments =
      jsonDecode('[${html.substring(seasonStart + init.length, seasonEnd)}]');
  if (arguments is! List ||
      arguments.length != 2 ||
      arguments[0] is! List ||
      arguments[1] is! String) {
    return directory;
  }
  final seasonLabel = arguments[1] as String;
  final parts = seasonLabel.split('/');
  final year = int.tryParse(parts.first);
  final endYear = int.tryParse(parts.last);
  final crossYear = leagueId == 'rugby.270559';
  if (year == null ||
      endYear == null ||
      parts.length != (crossYear ? 2 : 1) ||
      endYear != year + (crossYear ? 1 : 0) ||
      year > requestedYear ||
      endYear < requestedYear - (crossYear ? 0 : 1) ||
      !html.contains('${config.$5} $year')) {
    return directory;
  }
  final seasons = (arguments[0] as List).whereType<Map>().where((season) =>
      season['label'] == seasonLabel &&
      season['season'] == year * 100 + (crossYear ? 1 : 0) &&
      season['standings'] == 1 &&
      season['started'] == 1);
  if (seasons.length != 1) return directory;
  final marker =
      RegExp(r'<div\b[^>]*\bid="standings-data"[^>]*>').firstMatch(html);
  if (marker == null) return directory;
  final end = html.indexOf('</div>', marker.end);
  if (end < marker.end || end - marker.end > 256 * 1024) return directory;
  final root = jsonDecode(html.substring(marker.end, end));
  if (root is! Map ||
      root['ovalId'] != config.$2 ||
      root['hasStandings'] != true ||
      root['standingsConference'] != false ||
      root['standingsData'] is! Map) {
    return directory;
  }
  final entries = root['standingsData']['standings'];
  if (entries is! List || entries.length != config.$4) return directory;
  // The page supplies its own province crests. ESPN's rugby directory can
  // contain national flags for these IDs, so use the independently joined
  // logo record without changing the team's existing identity.
  final logos = <int, Map>{};
  final duplicateLogoIds = <int>{};
  if (root['standings'] is List) {
    for (final row in root['standings']) {
      if (row is! Map || row['id'] is! int) continue;
      final id = row['id'] as int;
      if (logos.containsKey(id)) duplicateLogoIds.add(id);
      logos[id] = row;
    }
  }
  final teams = <String, StandingTeam>{};
  final byName = <String, Set<String>>{};
  for (final table in directory.tables) {
    for (final row in table.rows) {
      teams[row.team.id] = row;
      for (final name in {
        row.team.name,
        row.team.shortName,
        ...row.nameAliases
      }) {
        if (name.isNotEmpty) {
          byName.putIfAbsent(normalRugbyTeam(name), () => {}).add(row.team.id);
        }
      }
    }
  }
  final rows = <StandingTeam>[], seen = <String>{};
  final positions = <int>{};
  final sourceIds = <int>{};
  for (final entry in entries) {
    if (entry is! Map || entry['name'] != config.$3 || entry['team'] is! Map) {
      return directory;
    }
    final shortName = entry['team']['shortName'];
    final sourceId = entry['team']['id'];
    if (sourceId is! int || sourceId < 1 || !sourceIds.add(sourceId)) {
      return directory;
    }
    final ids = <String>{};
    for (final value in [entry['team']['name'], shortName]) {
      if (value is String) {
        final name = normalRugbyTeam(value);
        ids.addAll(byName[name] ?? const {});
      }
    }
    final rank = entry['position'];
    if (ids.length != 1 ||
        rank is! int ||
        rank < 1 ||
        rank > config.$4 ||
        !seen.add(ids.single) ||
        !positions.add(rank)) {
      return directory;
    }
    final stats = <String, String>{};
    for (final field in const {
      'played': 'gamesPlayed',
      'won': 'wins',
      'drawn': 'ties',
      'lost': 'losses',
      'pointsDiff': 'pointDifferential',
      'points': 'points',
      'bonus': 'bonusPoints',
      'pointsFor': 'pointsFor',
      'pointsAgainst': 'pointsAgainst',
    }.entries) {
      final value = entry[field.key];
      if (value is! int ||
          value.abs() > 10000 ||
          (value < 0 && field.key != 'points' && field.key != 'pointsDiff')) {
        return directory;
      }
      stats[field.value] = '$value';
    }
    final team = teams[ids.single]!;
    final sourceTeam = entry['team'] as Map;
    final logoRow = logos[sourceTeam['id']];
    String logoName(String name) => normalRugbyTeam(name).replaceAll("'", '');
    final suppliedLogo = logoRow?['logo'];
    final logoUri = suppliedLogo is String ? Uri.tryParse(suppliedLogo) : null;
    final matchingLogo = logoRow?['name'] is String &&
        [sourceTeam['name'], shortName].whereType<String>().any(
            (name) => logoName(name) == logoName(logoRow!['name'] as String));
    final useLogo = !duplicateLogoIds.contains(sourceTeam['id']) &&
        matchingLogo &&
        logoUri?.scheme == 'https' &&
        logoUri?.host == 'eu-cdn.rugbypass.com' &&
        logoUri!.userInfo.isEmpty &&
        !logoUri.hasPort &&
        logoUri.path.startsWith('/webp-images/images/team-images/logos/');
    final original = team.team;
    final displayedTeam = useLogo
        ? SportsTeam(
            id: original.id,
            name: original.name,
            shortName: original.shortName,
            abbreviation: original.abbreviation,
            location: original.location,
            logoUrl: suppliedLogo as String,
            color: original.color,
            record: original.record,
            score: original.score)
        : original;
    rows.add(StandingTeam(displayedTeam, Map.unmodifiable(stats), rank,
        nameAliases: team.nameAliases,
        statLabels: const {
          'gamesPlayed': 'Games played',
          'wins': 'Wins',
          'ties': 'Draws',
          'losses': 'Losses',
          'pointDifferential': 'Points difference',
          'points': 'Points',
          'bonusPoints': 'Bonus points',
          'pointsFor': 'Points for',
          'pointsAgainst': 'Points against',
        }));
  }
  rows.sort((a, b) => a.position!.compareTo(b.position!));
  return LeagueStandings(
      season: seasonLabel,
      previousSeason: endYear < requestedYear,
      sourceName: 'RugbyPass',
      tables: [
        // This is a complete league table. Older ESPN directory members may
        // have been relegated or left the competition, so do not append them.
        StandingTable('Regular season', List.unmodifiable(rows)),
      ]);
}

/// Match only case, common accents and punctuation differences; never use
/// substrings or mascots to choose between different team identities.
String normalRugbyTeam(String name) {
  var value = name.trim().toLowerCase();
  const accents = {
    'ū': 'u',
    'é': 'e',
    'è': 'e',
    'ê': 'e',
    'ë': 'e',
    'à': 'a',
    'â': 'a',
    'ä': 'a',
    'ô': 'o',
    'ö': 'o',
    'î': 'i',
    'ï': 'i',
    'ç': 'c'
  };
  for (final accent in accents.entries) {
    value = value.replaceAll(accent.key, accent.value);
  }
  final normalized = value
      .replaceAll("'", '')
      .replaceAll('’', '')
      .replaceAll('-', ' ')
      .replaceAll(RegExp(r'\s+'), ' ');
  // Exact club aliases confirmed by the publisher's paired ID/name records.
  // These also prevent duplicate ESPN scoreboard aliases replacing favourites.
  return const {
        'section paloise': 'pau',
        'bordeaux': 'bordeaux begles',
        'stade francais': 'stade francais paris',
        'clermont': 'clermont auvergne',
        'castres': 'castres olympique',
        'anthem rc': 'anthem rugby carolina',
      }[normalized] ??
      normalized;
}

/// Supplement an incomplete collection with identities supplied by the league
/// scoreboard. Existing collection identities take precedence over duplicate
/// scoreboard aliases, keeping saved follows stable.
LeagueStandings supplementRugbyTeams(
    (Uint8List, LeagueStandings, String, int) input) {
  final (bytes, directory, leagueId, year) = input;
  final slug = switch (leagueId) {
    'rugby.270559' => '270559',
    'rugby.289262' => '289262',
    _ => null,
  };
  if (slug == null) return directory;
  final root = jsonDecode(utf8.decode(bytes));
  if (root is! Map || root['leagues'] is! List || root['events'] is! List) {
    return directory;
  }
  final leagues = root['leagues'] as List;
  if (leagues.length != 1 ||
      leagues.single is! Map ||
      leagues.single['slug'] != slug ||
      leagues.single['season']?['year'] != year ||
      (root['events'] as List).length > 1000) {
    return directory;
  }
  final teams = {
    for (final table in directory.tables)
      for (final row in table.rows) row.team.id: row
  };
  final existingNames = {
    for (final row in teams.values)
      for (final name in {
        row.team.name,
        row.team.shortName,
        ...row.nameAliases
      })
        if (name.isNotEmpty) normalRugbyTeam(name)
  };
  for (final event in root['events']) {
    if (event is! Map ||
        (event['season']?['year'] != year &&
            !(leagueId == 'rugby.270559' &&
                event['season']?['year'] == year + 1)) ||
        event['competitions'] is! List) {
      continue;
    }
    for (final competition in event['competitions']) {
      if (competition is! Map || competition['competitors'] is! List) continue;
      for (final competitor in competition['competitors']) {
        if (competitor is! Map || competitor['team'] is! Map) continue;
        final raw = competitor['team'] as Map;
        final id = raw['id'], name = raw['displayName'];
        if (id is! String ||
            !RegExp(r'^[1-9]\d{0,8}$').hasMatch(id) ||
            raw['uid'] != 's:300~t:$id' ||
            name is! String ||
            name.isEmpty ||
            teams.containsKey(id)) {
          continue;
        }
        final shortName = raw['shortDisplayName'] as String? ?? name;
        if ([name, shortName]
            .any((value) => existingNames.contains(normalRugbyTeam(value)))) {
          continue;
        }
        teams[id] = StandingTeam(
            SportsTeam(
                id: id,
                name: name,
                shortName: shortName,
                abbreviation: raw['abbreviation'] as String? ?? '',
                logoUrl: raw['logo'] as String?),
            const {},
            null);
      }
    }
  }
  if (teams.length > 200) return directory;
  return LeagueStandings(directory: true, tables: [
    StandingTable('Teams', List.unmodifiable(teams.values)),
  ]);
}
