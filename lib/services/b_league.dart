import 'dart:convert';
import 'dart:typed_data';
import 'package:xml/xml.dart';
import '../models/sports.dart';
import 'sports_standings_service.dart';

// Official club-directory IDs and crest codes join both published tables and
// schedules without a metadata request per team. Unknown clubs fail closed.
const _clubs = <String, (String, String)>{
  'lh': ('702', 'LEVANGA HOKKAIDO'),
  'se': ('692', 'SENDAI 89ERS'),
  'an': ('693', 'AKITA NORTHERN HAPPINETS'),
  'ir': ('712', 'IBARAKI ROBOTS'),
  'ub': ('703', 'UTSUNOMIYA BREX'),
  'gc': ('713', 'GUNMA CRANE THUNDERS'),
  'ac': ('2486', 'ALTIRI CHIBA'),
  'cj': ('704', 'CHIBA JETS'),
  'at': ('706', 'ALVARK TOKYO'),
  'sr': ('726', 'TOKYO SUNROCKERS'),
  'kb': ('727', 'KAWASAKI BRAVE THUNDERS'),
  'yb': ('694', 'YOKOHAMA B-CORSAIRS'),
  'tg': ('696', 'TOYAMA GROUSES'),
  'bw': ('716', 'SHINSHU BRAVE WARRIORS'),
  'sn': ('697', 'SAN-EN NEOPHOENIX'),
  'sm': ('728', 'SEAHORSES MIKAWA'),
  'dd': ('729', 'NAGOYA DIAMOND DOLPHINS'),
  'ls': ('698', 'SHIGA LAKES'),
  'kh': ('699', 'KYOTO HANNARYZ'),
  'oe': ('700', 'OSAKA EVESSA'),
  'ns': ('718', 'KOBE STORKS'),
  'ss': ('720', 'SHIMANE SUSANOO MAGIC'),
  'hd': ('721', 'HIROSHIMA DRAGONFLIES'),
  'sg': ('1638', 'SAGA BALLOONERS'),
  'nv': ('2488', 'NAGASAKI VELCA'),
  'rg': ('701', 'RYUKYU GOLDEN KINGS'),
};

String _text(XmlElement element) =>
    element.innerText.replaceAll(RegExp(r'\s+'), ' ').trim();
XmlElement _html(String raw) => XmlDocument.parse(raw
    .replaceAll(RegExp(r'\sdata-wovn-src:[^=\s]+="[^"]*"'), '')
    .replaceAll('&nbsp;', '&#160;')
    .replaceAll(RegExp(r'<br\s*>'), '<br/>')
    .replaceAllMapped(
        RegExp(r'<img\b[^>]*>'),
        (m) => m[0]!.endsWith('/>')
            ? m[0]!
            : '${m[0]!.substring(0, m[0]!.length - 1)}/>')).rootElement;
bool _hasClass(XmlElement element, String value) =>
    (element.getAttribute('class') ?? '').split(' ').contains(value);
XmlElement? _class(XmlElement parent, String value) => parent.descendants
    .whereType<XmlElement>()
    .where((e) => _hasClass(e, value))
    .firstOrNull;
SportsTeam? _team(XmlElement parent, {String? score}) {
  final src = parent.findAllElements('img').firstOrNull?.getAttribute('src');
  final uri = src == null ? null : Uri.tryParse(src);
  if (uri?.scheme != 'https' || uri?.host != 'bleague.bl.kuroco-img.app') {
    return null;
  }
  final code = RegExp(r'/logo/\d{4}/s/([a-z0-9]+)\.png$')
      .firstMatch(uri!.path)
      ?.group(1);
  final info = _clubs[code];
  if (info == null) return null;
  return SportsTeam(
      id: 'bleague:${info.$1}',
      name: info.$2,
      shortName: info.$2,
      abbreviation: code!.toUpperCase(),
      logoUrl: uri.toString(),
      score: score);
}

final _broadcastPanels = RegExp(
    r'<main\b[^>]*\bid="modal-filter-detail-content-(\d+)"[^>]*>[\s\S]*?</main>');

// These per-game panels are already in the downloaded schedule. Only explicit
// live terrestrial/BS/CS listings identify a linear channel; streaming brands
// and recorded broadcasts must not become television matches.
Map<String, List<SportsBroadcast>> _liveBroadcasts(
    String html, Set<String> gameIds) {
  if (!html.contains('modal-filter-detail-content-')) return const {};
  final result = <String, List<SportsBroadcast>>{}, seen = <String>{};
  for (final match in _broadcastPanels.allMatches(html)) {
    final id = match[1]!;
    if (!gameIds.contains(id)) continue;
    if (!seen.add(id)) {
      result.remove(id);
      continue;
    }
    if (match.end - match.start > 32768) continue;
    try {
      final panel = _html(match[0]!);
      final live = _class(panel, 'modal-live-contents');
      if (live == null) continue;
      final title = _class(live, 'modal-title');
      if (title == null ||
          !const {'LIVE Broadcast', 'LIVE放送'}.contains(_text(title))) {
        continue;
      }
      final names = <String>{};
      for (final item in live.findAllElements('li')) {
        final icon = Uri.tryParse(
            item.findElements('img').firstOrNull?.getAttribute('src') ?? '');
        if (icon?.host != 'bleague.bl.kuroco-img.app' ||
            !const {'icon_chijouha.svg', 'icon_bs.svg', 'icon_cs.svg'}
                .contains(icon?.pathSegments.lastOrNull)) {
          continue;
        }
        for (final label in item.descendants
            .whereType<XmlElement>()
            .where((e) => _hasClass(e, 'link-line'))) {
          final name = _text(label);
          if (name.isNotEmpty && name.length <= 100) names.add(name);
        }
      }
      result[id] = [
        for (final name in names.take(16))
          SportsBroadcast(name,
              source: 'B.League', country: 'Japan', medium: 'TV'),
      ];
    } on XmlException {
      // Optional broadcast markup cannot prevent valid fixtures from loading.
      continue;
    }
  }
  return result;
}

LeagueStandings parseBLeagueStandings(Uint8List bytes) {
  final html = utf8.decode(bytes);
  if (!html.contains('B.LEAGUE')) {
    throw const FormatException('Unexpected B.League page');
  }
  final stamp = RegExp(r'(\d{4})年(\d{2})月(\d{2})日 全試合終了時点').firstMatch(html);
  if (stamp == null) {
    throw const FormatException('Missing B.League update date');
  }
  final date = DateTime(
      int.parse(stamp[1]!), int.parse(stamp[2]!), int.parse(stamp[3]!));
  final groups = <StandingTable>[], seen = <String>{};
  for (final raw
      in RegExp(r'<table class="table table-ranking[^>]*>[\s\S]*?</table>')
          .allMatches(html)) {
    final table = _html(raw[0]!), rows = <StandingTeam>[];
    for (final tr in table.findAllElements('tr')) {
      final cells = tr.findElements('td').toList();
      if (cells.isEmpty) continue;
      if (cells.length != 4) {
        throw const FormatException('Changed B.League table');
      }
      final team = _team(cells[1]);
      final id = RegExp(r'TeamID=(\d+)')
          .firstMatch(
              cells[1].findAllElements('a').firstOrNull?.getAttribute('href') ??
                  '')
          ?.group(1);
      final rank = int.tryParse(_text(cells[0])),
          wins = int.tryParse(_text(cells[2])),
          losses = int.tryParse(_text(cells[3]));
      if (team == null ||
          team.id != 'bleague:$id' ||
          rank == null ||
          rank < 1 ||
          rank > 13 ||
          wins == null ||
          losses == null ||
          wins < 0 ||
          losses < 0 ||
          wins + losses > 100 ||
          !seen.add(team.id)) {
        throw const FormatException('Invalid B.League team');
      }
      rows.add(StandingTeam(team, {'wins': '$wins', 'losses': '$losses'}, rank,
          nameAliases: {_text(cells[1])}));
    }
    if (rows.length != 13) {
      throw const FormatException('Incomplete B.League conference');
    }
    groups.add(StandingTable(groups.isEmpty ? 'East' : 'West', rows));
  }
  if (groups.length != 2 || seen.length != 26) {
    throw const FormatException('Incomplete B.League standings');
  }
  return LeagueStandings(
      tables: groups, sourceName: 'B.LEAGUE', updatedAt: date);
}

List<SportsGame> parseBLeagueScoreboard(String html, SportsLeague league,
    {DateTime? now}) {
  int? field(String key) => int.tryParse(
      RegExp("var $key = '(\\d+)';").firstMatch(html)?.group(1) ?? '');
  final year = field('year'), month = field('mon'), day = field('day');
  if (year == null ||
      month == null ||
      day == null ||
      !html.contains('B.LEAGUE')) {
    throw const FormatException('Missing B.League schedule date');
  }
  // Game links contain nested lists; stop at the matching outer list, not
  // its first closing tag, and read only direct game children.
  final opening = RegExp(r'<ul[^>]*id="schedule-b1"[^>]*>').firstMatch(html);
  if (opening == null) throw const FormatException('Missing B.League schedule');
  var depth = 1, end = -1;
  for (final tag in RegExp(r'</?ul\b[^>]*>').allMatches(html, opening.end)) {
    depth += tag[0]!.startsWith('</') ? -1 : 1;
    if (depth == 0) {
      end = tag.end;
      break;
    }
  }
  if (end < 0) throw const FormatException('Incomplete B.League schedule');
  final list = _html(html.substring(opening.start, end));
  final broadcasts = _liveBroadcasts(html, {
    for (final row in list.findElements('li'))
      if (row.getAttribute('id') case final String id) id,
  });
  final games = <SportsGame>[], seen = <String>{};
  for (final row in list.findElements('li')) {
    final key = row.getAttribute('id');
    if (!_hasClass(row, 'list-item') ||
        key == null ||
        !RegExp(r'^\d+$').hasMatch(key)) {
      continue;
    }
    final home = _class(row, 'home'),
        away = _class(row, 'away'),
        info = _class(row, 'info-arena');
    if (home == null || away == null || info == null) continue;
    final time = RegExp(r'(\d{1,2}):(\d{2})$').firstMatch(_text(info));
    if (time == null) continue;
    final hour = int.parse(time[1]!), minute = int.parse(time[2]!);
    final local = DateTime.utc(year, month, day, hour, minute);
    if (local.year != year ||
        local.month != month ||
        local.day != day ||
        hour > 23 ||
        minute > 59) {
      continue;
    }
    final start = local.subtract(const Duration(hours: 9));
    final status = _class(row, 'info-scorestate');
    if (status == null) continue;
    final label = _text(status);
    if (label.contains('中止') ||
        label.contains('CANCELLED') ||
        label.contains('POSTPONED')) {
      continue;
    }
    final hs = int.tryParse(
        _text(_class(row, 'home-score') ?? XmlElement(XmlName('empty'))));
    final aws = int.tryParse(
        _text(_class(row, 'away-score') ?? XmlElement(XmlName('empty'))));
    final state = label == 'FINAL'
        ? GameState.post
        : RegExp(r'^(?:[1-4]Q|Q[1-4]|OT)\b').hasMatch(label)
            ? GameState.live
            : const {'Attractions', '見どころ'}.contains(label) &&
                    start.isAfter(now ?? DateTime.now().toUtc()) &&
                    hs == null &&
                    aws == null
                ? GameState.pre
                : null;
    if (state == null ||
        (state != GameState.pre &&
            (hs == null || aws == null || hs < 0 || aws < 0))) {
      continue;
    }
    final ht = _team(home, score: state == GameState.pre ? null : '$hs'),
        at = _team(away, score: state == GameState.pre ? null : '$aws');
    if (ht == null || at == null || ht.id == at.id) {
      throw const FormatException('Unknown B.League club');
    }
    final id = 'bleague:$key';
    if (!seen.add(id)) continue;
    games.add(SportsGame(
        id: id,
        league: league,
        start: start,
        state: state,
        statusText: state == GameState.pre
            ? 'Scheduled'
            : state == GameState.post
                ? 'Final'
                : label,
        home: ht,
        away: at,
        broadcasts: [for (final b in broadcasts[key] ?? const []) b.name],
        scoreboardBroadcasts: broadcasts[key] ?? const [],
        source: 'B.League'));
  }
  return games;
}
