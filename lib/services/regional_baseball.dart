import 'dart:convert';
import 'dart:typed_data';
import 'package:xml/xml.dart';
import '../models/sports.dart';
import 'sports_standings_service.dart';

// Team codes are the leagues' published identifiers, shared by standings and
// schedules. Explicit bilingual aliases avoid fuzzy cross-team joins.
const _npb = <String, (String, List<String>)>{
  't': ('Hanshin Tigers', ['Hanshin', '阪神']),
  'g': ('Yomiuri Giants', ['Yomiuri', '巨人', '読売']),
  'db': ('Yokohama DeNA BayStars', ['DeNA', '横浜DeNA']),
  'c': ('Hiroshima Toyo Carp', ['Hiroshima', '広島']),
  's': ('Tokyo Yakult Swallows', ['Yakult', 'ヤクルト']),
  'd': ('Chunichi Dragons', ['Chunichi', '中日']),
  'h': ('Fukuoka SoftBank Hawks', ['SoftBank', 'ソフトバンク']),
  'l': ('Saitama Seibu Lions', ['Seibu', '西武']),
  'f': ('Hokkaido Nippon-Ham Fighters', ['Nippon-Ham', '日本ハム']),
  'b': ('Orix Buffaloes', ['ORIX', 'オリックス']),
  'm': ('Chiba Lotte Marines', ['Lotte', 'ロッテ']),
  'e': ('Tohoku Rakuten Golden Eagles', ['Rakuten', '楽天']),
};
const _kbo = <String, (String, List<String>)>{
  'KT': ('KT Wiz', ['KT', 'kt']),
  'SS': ('Samsung Lions', ['SAMSUNG', '삼성']),
  'HT': ('Kia Tigers', ['KIA', '기아']),
  'LG': ('LG Twins', ['LG']),
  'OB': ('Doosan Bears', ['DOOSAN', '두산']),
  'SK': ('SSG Landers', ['SSG']),
  'LT': ('Lotte Giants', ['LOTTE', '롯데']),
  'NC': ('NC Dinos', ['NC']),
  'HH': ('Hanwha Eagles', ['HANWHA', '한화']),
  'WO': ('Kiwoom Heroes', ['KIWOOM', '키움']),
};
String? _code(String name, Map<String, (String, List<String>)> teams) =>
    teams.entries
        .where((e) =>
            e.value.$1.toLowerCase() == name.toLowerCase() ||
            e.value.$2.any((n) => n.toLowerCase() == name.toLowerCase()))
        .firstOrNull
        ?.key;
SportsTeam _team(String source, String code, {String? score, String? logo}) {
  final info = (source == 'NPB' ? _npb : _kbo)[code]!;
  return SportsTeam(
      id: '${source.toLowerCase()}:$code',
      name: info.$1,
      shortName: info.$1,
      abbreviation: code.toUpperCase(),
      logoUrl: logo,
      score: score);
}

String _text(XmlElement e) =>
    e.innerText.replaceAll(RegExp(r'\s+'), ' ').trim();
XmlElement _fragment(String html) => XmlDocument.parse(html
    .replaceAll('&nbsp;', '&#160;')
    .replaceAll(RegExp(r'<br\s*>', caseSensitive: false), '<br/>')
    .replaceAllMapped(
        RegExp(r'<img\b[^>]*>', caseSensitive: false),
        (m) => m[0]!.endsWith('/>')
            ? m[0]!
            : '${m[0]!.substring(0, m[0]!.length - 1)}/>')).rootElement;
Iterable<String> _tables(String html) =>
    RegExp(r'<table\b[^>]*>[\s\S]*?</table>', caseSensitive: false)
        .allMatches(html)
        .map((m) => m[0]!);
String _classText(XmlElement e, String name) =>
    e.descendants
        .whereType<XmlElement>()
        .where((n) => (n.getAttribute('class') ?? '').split(' ').contains(name))
        .map(_text)
        .firstOrNull ??
    '';
Map<String, String> _logos(String html, String source) {
  final result = <String, String>{};
  for (final match in RegExp(r'<img\b[^>]*src="([^"]+)"').allMatches(html)) {
    final raw = match[1]!;
    final uri = Uri.tryParse(raw.startsWith('//') ? 'https:$raw' : raw);
    if (uri == null || uri.scheme != 'https') continue;
    final id = source == 'NPB'
        ? RegExp(r'/logo_([a-z]+)_m\.gif$').firstMatch(uri.path)?.group(1)
        : RegExp(r'/ebl_(?:ft|h31)_([A-Z]+)\.png$')
            .firstMatch(uri.path)
            ?.group(1);
    final validHost = source == 'NPB'
        ? uri.host == 'p.npb.jp'
        : uri.host == '6ptotvmi5753.edge.naverncp.com';
    if (id != null && validHost) result[id] = uri.toString();
  }
  return result;
}

Map<String, String> _record(List<String> values) {
  if (values.length != 6) {
    throw const FormatException('Incomplete baseball record');
  }
  final counts = values.take(4).map(int.tryParse).toList();
  final pct = double.tryParse(values[4]);
  if (counts.any((n) => n == null || n < 0 || n > 200) ||
      counts[0] != counts[1]! + counts[2]! + counts[3]! ||
      pct == null ||
      pct < 0 ||
      pct > 1 ||
      (values[5] != '-' && double.tryParse(values[5]) == null)) {
    throw const FormatException('Invalid baseball record');
  }
  return {
    'gamesPlayed': values[0],
    'wins': values[1],
    'losses': values[2],
    'ties': values[3],
    'winPercent': values[4],
    'gamesBehind': values[5]
  };
}

LeagueStandings parseNpbStandings((Uint8List, int) input) {
  final (bytes, year) = input;
  final html = utf8.decode(bytes);
  if (!html.contains('<title>$year Regular Season | NPB.jp')) {
    throw const FormatException('Unexpected NPB season');
  }
  final logos = _logos(html, 'NPB'), seen = <String>{};
  final tables = <StandingTable>[];
  for (final raw in _tables(html)) {
    final table = _fragment(raw);
    final headings = table
        .findAllElements('thead')
        .firstOrNull
        ?.findAllElements('th')
        .map(_text)
        .join('|');
    if (headings != '|G|W|L|T|PCT|GB') continue;
    final rows = <StandingTeam>[];
    for (final tr
        in table.findAllElements('tbody').expand((e) => e.findElements('tr'))) {
      final name = tr
          .findElements('th')
          .first
          .findElements('span')
          .first
          .innerText
          .trim();
      final code = _code(name, _npb);
      if (code == null || !seen.add(code)) {
        throw const FormatException('Unknown NPB team');
      }
      final central = const {'t', 'g', 'db', 'c', 's', 'd'}.contains(code);
      if (central != tables.isEmpty) {
        throw const FormatException('Mixed NPB leagues');
      }
      rows.add(StandingTeam(_team('NPB', code, logo: logos[code]),
          _record(tr.findElements('td').map(_text).toList()), rows.length + 1,
          nameAliases: _npb[code]!.$2.toSet()));
    }
    if (rows.length != 6) throw const FormatException('Incomplete NPB table');
    tables.add(StandingTable(
        tables.isEmpty ? 'Central League' : 'Pacific League', rows));
  }
  if (tables.length != 2 || seen.length != 12) {
    throw const FormatException('Missing NPB standings');
  }
  return LeagueStandings(tables: tables, season: '$year', sourceName: 'NPB');
}

LeagueStandings parseKboStandings(Uint8List bytes) {
  final html = utf8.decode(bytes);
  final year = RegExp(r'id="[^"]*_inputYear"[^>]*value="(\d{4})"')
      .firstMatch(html)
      ?.group(1);
  if (year == null) throw const FormatException('Missing KBO season');
  final logos = _logos(html, 'KBO'), seen = <String>{};
  final rows = <StandingTeam>[];
  for (final raw in _tables(html)) {
    final table = _fragment(raw);
    for (final tr in table.findAllElements('tr')) {
      final cells = {
        for (final td in tr.findElements('td'))
          td.getAttribute('title'): _text(td)
      };
      if (!cells.containsKey('GAMES') || !cells.containsKey('PCT')) continue;
      final code = _code(cells['TEAM'] ?? '', _kbo),
          rank = int.tryParse(cells['RK'] ?? '');
      if (code == null ||
          rank == null ||
          rank < 1 ||
          rank > 10 ||
          !seen.add(code)) {
        throw const FormatException('Invalid KBO team');
      }
      rows.add(StandingTeam(
          _team('KBO', code, logo: logos[code]),
          _record([
            for (final key in ['GAMES', 'W', 'L', 'D', 'PCT', 'GB'])
              cells[key] ?? ''
          ]),
          rank,
          nameAliases: _kbo[code]!.$2.toSet()));
    }
  }
  if (rows.length != 10) throw const FormatException('Incomplete KBO table');
  return LeagueStandings(
      tables: [StandingTable('KBO League', rows)],
      season: year,
      sourceName: 'KBO');
}

/// Korea/Japan do not observe daylight-saving time. Validate calendar input
/// before converting the supplied local kickoff; never invent a midnight game.
DateTime? _start(int year, int month, int day, String time) {
  final clock = RegExp(r'^(\d{1,2}):(\d{2})$').firstMatch(time);
  if (clock == null) return null;
  final hour = int.parse(clock[1]!), minute = int.parse(clock[2]!);
  final date = DateTime.utc(year, month, day, hour, minute);
  if (date.year != year ||
      date.month != month ||
      date.day != day ||
      hour > 23 ||
      minute > 59) {
    return null;
  }
  return date.subtract(const Duration(hours: 9));
}

List<SportsGame> parseNpbScoreboard(String html, SportsLeague league,
    {DateTime? now}) {
  final canonical = RegExp(
          r'<link rel="canonical" href="https://npb.jp/games/(\d{4})/schedule_(\d{2})_detail.html">')
      .firstMatch(html);
  if (canonical == null) throw const FormatException('Unexpected NPB schedule');
  final year = int.parse(canonical[1]!), month = int.parse(canonical[2]!);
  final games = <SportsGame>[], seen = <String>{};
  final table = _tables(html).singleOrNull;
  if (table == null) throw const FormatException('Missing NPB schedule');
  final xml = _fragment(table);
  for (final tr in xml.findAllElements('tr')) {
    final date =
        RegExp(r'^date(\d{2})(\d{2})$').firstMatch(tr.getAttribute('id') ?? '');
    if (date == null) continue;
    final homeCode = _code(_classText(tr, 'team1'), _npb),
        awayCode = _code(_classText(tr, 'team2'), _npb);
    final start = _start(
        year, int.parse(date[1]!), int.parse(date[2]!), _classText(tr, 'time'));
    if (homeCode == null ||
        awayCode == null ||
        homeCode == awayCode ||
        start == null ||
        int.parse(date[1]!) != month) {
      continue;
    }
    final homeScore = int.tryParse(_classText(tr, 'score1')),
        awayScore = int.tryParse(_classText(tr, 'score2'));
    final text = _text(tr), stateText = _classText(tr, 'state');
    if (text.contains('中止') || text.contains('予備日') || text.contains('ノーゲーム')) {
      continue;
    }
    // Completed rows have numeric scores and '-' between them. An unplayed
    // past placeholder (e.g. an unnecessary Japan Series game) is not a fixture.
    final finished = homeScore != null && awayScore != null && stateText == '-';
    if (!finished &&
        (homeScore != null ||
            awayScore != null ||
            start.isBefore(now ?? DateTime.now().toUtc()))) {
      continue;
    }
    final id =
        'npb:$year${date[1]}${date[2]}:$homeCode:$awayCode:${start.hour}:${start.minute}';
    if (!seen.add(id)) continue;
    games.add(SportsGame(
        id: id,
        league: league,
        start: start,
        state: finished ? GameState.post : GameState.pre,
        statusText: finished ? 'Final' : 'Scheduled',
        home: _team('NPB', homeCode, score: finished ? '$homeScore' : null),
        away: _team('NPB', awayCode, score: finished ? '$awayScore' : null),
        source: 'NPB'));
  }
  return games;
}

List<SportsGame> parseKboScoreboard(String html, SportsLeague league) {
  final date = RegExp(
          r'value="(\d{4})\.(\d{2})\.(\d{2})\([A-Z]+\)"[^>]*id="[^"]*_txtSearchDate"')
      .firstMatch(html);
  if (date == null) throw const FormatException('Missing KBO schedule date');
  final games = <SportsGame>[], seen = <String>{};
  final blocks = html.split('<div class="scoreboard_time">');
  if (blocks.length == 1 && !html.contains('_pNoGmae')) {
    throw const FormatException('Missing KBO scoreboard');
  }
  for (final block in blocks.skip(1)) {
    final end = block.indexOf('<div class="tbl_common');
    if (end < 0) continue;
    final xml = _fragment(
        '<root><div class="scoreboard_time">${block.substring(0, end)}</root>');
    final names = xml
        .findAllElements('span')
        .where((e) => e.getAttribute('class') == 'team_name')
        .map(_text)
        .toList();
    if (names.length != 2) continue;
    final awayCode = _code(names[0], _kbo), homeCode = _code(names[1], _kbo);
    final time = RegExp(r'(\d{1,2}:\d{2})$')
        .firstMatch(_classText(xml, 'local_time'))
        ?.group(1);
    final start = _start(int.parse(date[1]!), int.parse(date[2]!),
        int.parse(date[3]!), time ?? '');
    if (awayCode == null ||
        homeCode == null ||
        awayCode == homeCode ||
        start == null) {
      continue;
    }
    final timer = _classText(xml, 'timer');
    final state = timer == 'FINAL'
        ? GameState.post
        : RegExp(r'^\d{1,2}:\d{2}$').hasMatch(timer)
            ? GameState.pre
            : RegExp(r'^(TOP|BOTTOM|BOT)\s*\d', caseSensitive: false)
                    .hasMatch(timer)
                ? GameState.live
                : null;
    if (state == null) continue;
    final scores = xml
        .findAllElements('span')
        .where((e) => e.getAttribute('class') == 'team_score')
        .map(_text)
        .toList();
    if (state != GameState.pre &&
        (scores.length != 2 || scores.any((s) => int.tryParse(s) == null))) {
      continue;
    }
    final logos = _logos('<div class="scoreboard_time">$block', 'KBO');
    final id =
        'kbo:${date[1]}${date[2]}${date[3]}:$awayCode:$homeCode:${start.hour}:${start.minute}';
    if (!seen.add(id)) continue;
    games.add(SportsGame(
        id: id,
        league: league,
        start: start,
        state: state,
        statusText: state == GameState.post
            ? 'Final'
            : state == GameState.pre
                ? 'Scheduled'
                : timer,
        home: _team('KBO', homeCode,
            score: state == GameState.pre ? null : scores[1],
            logo: logos[homeCode]),
        away: _team('KBO', awayCode,
            score: state == GameState.pre ? null : scores[0],
            logo: logos[awayCode]),
        source: 'KBO'));
  }
  return games;
}

int ablSeasonYear(DateTime date) => date.month < 7 ? date.year - 1 : date.year;
SportsTeam? _ablTeam(dynamic raw, {String? score}) {
  if (raw is! Map ||
      raw['id'] is! int ||
      raw['league']?['id'] != 595 ||
      raw['sport']?['id'] != 17) {
    return null;
  }
  final name = raw['name'];
  if (name is! String || name.trim().isEmpty) return null;
  return SportsTeam(
      id: 'abl:${raw['id']}',
      name: name,
      shortName: raw['shortName'] is String ? raw['shortName'] : name,
      abbreviation: raw['abbreviation'] is String ? raw['abbreviation'] : '',
      score: score);
}

LeagueStandings parseAblStandings((Uint8List, int, bool) input) {
  final (bytes, year, previous) = input;
  final root = jsonDecode(utf8.decode(bytes));
  if (root is! Map || root['records'] is! List) {
    throw const FormatException('Invalid ABL standings');
  }
  final rows = <StandingTeam>[], seen = <String>{};
  for (final group in root['records']) {
    if (group is! Map ||
        group['league']?['id'] != 595 ||
        group['sport']?['id'] != 17 ||
        group['teamRecords'] is! List) {
      continue;
    }
    for (final row in group['teamRecords']) {
      if (row is! Map || '${row['season']}' != '$year') {
        throw const FormatException('Unexpected ABL season');
      }
      final team = _ablTeam(row['team']),
          rank = int.tryParse('${row['leagueRank']}');
      final record = row['leagueRecord'];
      if (team == null ||
          rank == null ||
          rank < 1 ||
          rank > 16 ||
          record is! Map ||
          !seen.add(team.id)) {
        throw const FormatException('Invalid ABL team');
      }
      rows.add(StandingTeam(
          team,
          _record([
            '${row['gamesPlayed']}',
            '${record['wins']}',
            '${record['losses']}',
            '${record['ties']}',
            '${record['pct']}',
            '${row['leagueGamesBack']}'
          ]),
          rank));
    }
  }
  if (rows.isNotEmpty && (rows.length < 4 || rows.length > 12)) {
    throw const FormatException('Incomplete ABL table');
  }
  rows.sort((a, b) => a.position!.compareTo(b.position!));
  return LeagueStandings(
      tables: rows.isEmpty
          ? const []
          : [StandingTable('Australian Baseball League', rows)],
      season: '$year–${year + 1}',
      previousSeason: previous,
      sourceName: 'ABL / MLB');
}

List<SportsGame> parseAblScoreboard(String body, SportsLeague league) {
  final root = jsonDecode(body);
  if (root is! Map || root['dates'] is! List) {
    throw const FormatException('Invalid ABL schedule');
  }
  final games = <SportsGame>[], seen = <String>{};
  for (final day in root['dates']) {
    if (day is! Map || day['games'] is! List) continue;
    for (final row in day['games']) {
      if (row is! Map ||
          row['gamePk'] is! int ||
          row['status'] is! Map ||
          row['status']['startTimeTBD'] == true) {
        continue;
      }
      final status = row['status'];
      if (['Postponed', 'Cancelled', 'Suspended']
          .contains(status['detailedState'])) {
        continue;
      }
      final state = switch (status['abstractGameState']) {
        'Preview' => GameState.pre,
        'Live' => GameState.live,
        'Final' => GameState.post,
        _ => null
      };
      final stamp = row['gameDate'];
      final start = stamp is String && stamp.endsWith('Z')
          ? DateTime.tryParse(stamp)
          : null;
      if (state == null || start == null) continue;
      final home = row['teams']?['home'], away = row['teams']?['away'];
      if (home is! Map || away is! Map) continue;
      final ht = _ablTeam(home['team'],
          score: state != GameState.pre && home['score'] is int
              ? '${home['score']}'
              : null);
      final at = _ablTeam(away['team'],
          score: state != GameState.pre && away['score'] is int
              ? '${away['score']}'
              : null);
      final id = 'abl:${row['gamePk']}';
      if (ht == null || at == null || ht.id == at.id || !seen.add(id)) continue;
      games.add(SportsGame(
          id: id,
          league: league,
          start: start.toUtc(),
          state: state,
          statusText: '${status['detailedState']}',
          home: ht,
          away: at,
          source: 'ABL'));
    }
  }
  return games;
}
