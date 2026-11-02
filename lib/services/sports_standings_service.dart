import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../models/sports.dart';
import 'ncaa_soccer_rankings.dart';
import 'ncaa_field_hockey_rankings.dart';
import 'k_league_standings.dart';
import 'npc_standings.dart';
import 'rugby_pass_standings.dart';
import 'easl_standings.dart';
import 'regional_baseball.dart';
import 'b_league.dart';
import 'motogp_standings_source.dart';

class StandingTeam {
  const StandingTeam(this.team, this.stats, this.position,
      {this.statLabels = const {}, this.nameAliases = const {}});
  final SportsTeam team;
  final Map<String, String> stats;
  final int? position;
  final Map<String, String> statLabels;
  final Set<String> nameAliases;
}

class StandingTable {
  const StandingTable(this.name, this.rows);
  final String name;
  final List<StandingTeam> rows;
}

class LeagueStandings {
  const LeagueStandings(
      {this.tables = const [],
      this.season,
      this.previousSeason,
      this.directory = false,
      this.failed = false,
      this.fallbackYear,
      this.fallbackIsPreviousSeason = true,
      this.rankings = false,
      this.rankingTitle,
      this.sourceName,
      this.updatedAt});
  final List<StandingTable> tables;
  final String? season;
  final bool? previousSeason;
  final bool directory, failed;
  final int? fallbackYear;
  final bool fallbackIsPreviousSeason;
  final bool rankings;
  final String? rankingTitle;
  final String? sourceName;
  final DateTime? updatedAt;
  bool get hasRows => tables.any((table) => table.rows.isNotEmpty);

  LeagueStandings withRefreshFailure() => LeagueStandings(
      tables: tables,
      season: season,
      previousSeason: previousSeason,
      directory: directory,
      failed: true,
      fallbackYear: fallbackYear,
      fallbackIsPreviousSeason: fallbackIsPreviousSeason,
      rankings: rankings,
      rankingTitle: rankingTitle,
      sourceName: sourceName,
      updatedAt: updatedAt);
}

class _StandingsUnavailable implements Exception {
  const _StandingsUnavailable();
}

/// Created only when Standings is opened. No timers, startup hooks, score polling
/// or matching work. Coalesced requests and a bounded cache isolate optional data.
class SportsStandingsService {
  SportsStandingsService(
      {http.Client? client,
      DateTime Function()? clock,
      this.timeout = const Duration(seconds: 12)})
      : _client = client ?? http.Client(),
        _clock = clock ?? DateTime.now;
  static SportsStandingsService? _shared;
  static SportsStandingsService get instance =>
      _shared ??= SportsStandingsService();
  final http.Client _client;
  late final _motoGp = MotoGpStandingsSource(_read, clock: _clock);
  final DateTime Function() _clock;
  final Duration timeout;
  final _cache = <String, (LeagueStandings, DateTime)>{};
  final _flights = <String, Future<LeagueStandings>>{};
  final _queue = Queue<Completer<void>>();
  int _active = 0;
  String? lastLeagueId;
  Future<LeagueStandings> load(SportsLeague league, {bool refresh = false}) {
    lastLeagueId = league.id;
    final cached = _cache[league.id];
    final now = _clock();
    if (!refresh &&
        cached != null &&
        !now.isBefore(cached.$2) &&
        now.difference(cached.$2) <
            (cached.$1.failed
                ? const Duration(seconds: 30)
                : const Duration(minutes: 30))) {
      return Future.value(cached.$1);
    }
    return _flights.putIfAbsent(
        league.id,
        () => _load(league).whenComplete(() {
              _flights.remove(league.id);
            }));
  }

  Future<void> _acquire() async {
    if (_active < 2) {
      _active++;
      return;
    }
    final waiter = Completer<void>();
    _queue.add(waiter);
    await waiter.future;
  }

  void _release() {
    if (_queue.isNotEmpty) {
      _queue.removeFirst().complete();
    } else {
      _active--;
    }
  }

  Future<Uint8List> _read(Uri uri,
      {String method = 'GET', Map<String, String> headers = const {}}) async {
    final abort = Completer<void>();
    try {
      return await (() async {
        final request =
            http.AbortableRequest(method, uri, abortTrigger: abort.future)
              ..headers.addAll(headers);
        final response = await _client.send(request);
        if (response.statusCode != 200) {
          await response.stream.listen(null).cancel();
          if (response.statusCode == 404 || response.statusCode == 410) {
            throw const _StandingsUnavailable();
          }
          throw StateError('Standings request failed');
        }
        // College feeds include every conference and substantially more team
        // metadata. Keep a measured upper bound without truncating valid tables.
        final maxBytes = switch (uri.path) {
          '/apis/v2/sports/football/college-football/standings' =>
            4 * 1024 * 1024,
          '/apis/site/v2/sports/field-hockey/womens-college-field-hockey/scoreboard' =>
            4 * 1024 * 1024,
          '/apis/site/v2/sports/rugby/270559/scoreboard' => 4 * 1024 * 1024,
          '/apis/v2/sports/basketball/mens-college-basketball/standings' ||
          '/apis/v2/sports/basketball/womens-college-basketball/standings' =>
            8 * 1024 * 1024,
          _ => 2 * 1024 * 1024,
        };
        final bytes = BytesBuilder(copy: false);
        await for (final chunk in response.stream) {
          if (bytes.length + chunk.length > maxBytes) {
            throw StateError('Standings response too large');
          }
          bytes.add(chunk);
        }
        return bytes.takeBytes();
      })()
          .timeout(timeout);
    } finally {
      if (!abort.isCompleted) abort.complete();
    }
  }

  Future<LeagueStandings> _load(SportsLeague league) async {
    await _acquire();
    LeagueStandings result;
    try {
      result = const LeagueStandings();
      if (motoGpStandingsClasses.containsKey(league.id)) {
        result = await _motoGp.load(league, _clock().year);
      } else if (league.source == 'B.League' &&
          league.id == 'basketball.bleague') {
        result = await compute(parseBLeagueStandings,
            await _read(Uri.https('www.bleague.jp', '/en/standings-stats/')));
      }
      if (league.source == 'NPB' && league.id == 'baseball.npb') {
        final year = _clock().month < 3 ? _clock().year - 1 : _clock().year;
        result = await compute(parseNpbStandings,
            (await _read(Uri.https('npb.jp', '/bis/eng/$year/stats/')), year));
      }
      if (league.source == 'KBO' && league.id == 'baseball.kbo') {
        result = await compute(
            parseKboStandings,
            await _read(Uri.https(
                'eng.koreabaseball.com', '/Standings/TeamStandings.aspx')));
      }
      if (league.source == 'ABL' && league.id == 'baseball.abl') {
        final year = ablSeasonYear(_clock());
        Future<LeagueStandings> fetch(int season, bool previous) async =>
            compute(parseAblStandings, (
              await _read(Uri.https('statsapi.mlb.com', '/api/v1/standings', {
                'leagueId': '595',
                'season': '$season',
                'standingsTypes': 'regularSeason',
                'hydrate': 'team',
              })),
              season,
              previous
            ));
        result = await fetch(year, false);
        if (!result.hasRows) result = await fetch(year - 1, true);
      }
      if (league.source == 'EASL' && league.id == 'basketball.easl') {
        result = await compute(parseEaslStandings,
            await _read(Uri.https('easl.joshricha.com', '/api/v1/standings')));
      }
      if (league.source == 'K League' &&
          (league.id == 'kor.1' || league.id == 'kor.2')) {
        final year = _clock().year;
        result = await compute(parseKLeagueStandings, (
          await _read(
              Uri.https('www.kleague.com', '/record/teamRank.do', {
                'leagueId': league.id == 'kor.1' ? '1' : '2',
                'year': '$year',
                'stadium': 'all',
                'recordType': 'rank',
                'lang': 'en',
              }),
              method: 'POST',
              headers: const {'Accept-Language': 'en'}),
          league,
          year,
        ));
      }
      // Friendly internationals have teams, not a single league table.
      if (league.source == 'ESPN' &&
          league.hasStandings &&
          league.id != 'field-hockey.womens-college-field-hockey' &&
          league.id != 'rugby.289234') {
        final uri = Uri.parse(
            'https://site.api.espn.com/apis/v2/sports/${league.espnPath}/standings');
        try {
          result = await compute(parseLeagueStandings,
              (await _read(uri), league, _clock(), false));
          final year = result.fallbackYear;
          // One season retry: correct a premature rollover before considering
          // a previous season. Never crawl through historical seasons.
          if ((!result.hasRows || result.previousSeason == true) &&
              year != null &&
              league.id != 'rugby.270559' &&
              league.id != 'rugby.289262') {
            final older = await compute(parseLeagueStandings, (
              await _read(uri.replace(queryParameters: {'season': '$year'})),
              league,
              _clock(),
              false
            ));
            if (older.hasRows) {
              result = LeagueStandings(
                  tables: older.tables,
                  season: older.season ?? '$year',
                  previousSeason:
                      older.previousSeason ?? result.fallbackIsPreviousSeason);
            }
          }
        } on _StandingsUnavailable {
          // An absent table can still have a usable team directory. Network
          // errors and rate limits keep the existing short failure cooldown.
        }
      }
      if (league.source == 'ESPN' &&
          league.id != 'field-hockey.womens-college-field-hockey' &&
          !result.hasRows &&
          league.kind == SportsKind.team) {
        result = await compute(parseLeagueStandings, (
          await _read(Uri.parse(
              'https://site.api.espn.com/apis/site/v2/sports/${league.espnPath}/teams?limit=1000')),
          league,
          _clock(),
          true
        ));
      }
      if (league.id == 'field-hockey.womens-college-field-hockey' &&
          (!result.hasRows || result.directory)) {
        try {
          if (!result.hasRows) {
            result = await compute(parseFieldHockeyTeams, (
              await _read(Uri.parse(
                  'https://site.api.espn.com/apis/site/v2/sports/${league.espnPath}/scoreboard?dates=${_clock().year}&limit=1000')),
              _clock().year,
            ));
          }
          if (result.hasRows) {
            result = await compute(parseFieldHockeyRankings, (
              await _read(Uri.parse(
                  'https://www.ncaa.com/rankings/fieldhockey/d1/ncaa-field-hockey-rpi')),
              result,
              _clock(),
            ));
          }
        } catch (_) {
          // The optional national ranking must not remove known ESPN teams.
        }
      }
      if (league.id == 'rugby.289234' && result.hasRows) {
        try {
          result = await compute(parseWorldRugbyRankings, (
            await _read(Uri.parse(
                'https://api.wr-rims-prod.pulselive.com/rugby/v3/rankings/mru?language=en')),
            result,
          ));
        } catch (_) {
          // Rankings are optional enrichment. The fetched team directory remains
          // usable when this independent public feed is temporarily unavailable.
        }
      }
      if ((league.id == 'rugby.270559' || league.id == 'rugby.289262') &&
          result.hasRows &&
          !result.directory) {
        // These annual leagues also have stale seasons[] metadata on ESPN.
        // A 2023 table is historical even when that list claims it is newest.
        final now = _clock();
        final tableYear = int.tryParse(
            RegExp(r'\d{4}').firstMatch(result.season ?? '')?.group(0) ?? '');
        final expectedYear = league.id == 'rugby.270559' && now.month < 8
            ? now.year - 1
            : now.year;
        if (tableYear != null && tableYear < expectedYear) {
          result = LeagueStandings(
              tables: result.tables,
              season: result.season,
              previousSeason: true);
        }
      }
      if ((league.id == 'rugby.270559' || league.id == 'rugby.289262') &&
          (!result.hasRows ||
              result.directory ||
              result.previousSeason == true)) {
        try {
          var directory = result.directory
              ? result
              : await compute(parseLeagueStandings, (
                  await _read(Uri.parse(
                      'https://site.api.espn.com/apis/site/v2/sports/${league.espnPath}/teams?limit=1000')),
                  league,
                  _clock(),
                  true,
                ));
          final slug =
              league.id == 'rugby.270559' ? 'top-14' : 'major-league-rugby';
          final page = await _read(
              Uri.parse('https://www.rugbypass.com/$slug/standings/'));
          var current = await compute(parseRugbyPassStandings,
              (page, directory, _clock().year, league.id));
          if (current.sourceName != 'RugbyPass') {
            directory = await compute(supplementRugbyTeams, (
              await _read(Uri.parse(
                  'https://site.api.espn.com/apis/site/v2/sports/${league.espnPath}/scoreboard?dates=${_clock().year}&limit=1000')),
              directory,
              league.id,
              _clock().year,
            ));
            current = await compute(parseRugbyPassStandings,
                (page, directory, _clock().year, league.id));
          }
          if (current.sourceName == 'RugbyPass') {
            // The verified table is complete. The directory may also contain
            // relegated clubs or franchises from earlier seasons.
            result = current;
          }
        } catch (_) {
          // Keep the explicitly labelled historical table if today's complete
          // publication or its missing ESPN identities cannot be verified.
        }
      }
      if (league.id == 'rugby.270563' && result.directory && result.hasRows) {
        try {
          result = await compute(parseNpcStandings, (
            await _read(
                Uri.parse('https://www.rugbypass.com/bunnings-npc/standings/')),
            result,
            _clock().year,
          ));
        } catch (_) {
          // A changed or unavailable external table must not remove the known
          // teams or assign identities/ranks from incomplete information.
        }
      }
      if (result.directory &&
          result.hasRows &&
          (league.id == 'usa.ncaa.m.1' || league.id == 'usa.ncaa.w.1')) {
        final gender = league.id == 'usa.ncaa.m.1' ? 'men' : 'women';
        final poll =
            gender == 'men' ? 'united-soccer-coaches' : 'iwsoc-coaches-poll';
        try {
          result = await compute(parseNcaaSoccerRankings, (
            await _read(Uri.parse(
                'https://www.ncaa.com/rankings/soccer-$gender/d1/$poll')),
            result,
            gender,
          ));
        } catch (_) {
          // The official poll is optional; never hide the available teams when
          // the publisher changes its table format or cannot be reached.
        }
      }
    } catch (_) {
      result = (_cache[league.id]?.$1 ?? const LeagueStandings())
          .withRefreshFailure();
    } finally {
      _release();
    }
    final old = _cache[league.id]?.$1;
    if (old != null &&
        old.hasRows &&
        !old.directory &&
        (!result.hasRows ||
            result.directory ||
            (result.previousSeason == true && old.previousSeason != true))) {
      result = old.withRefreshFailure();
    }
    _cache.remove(league.id);
    _cache[league.id] = (result, _clock());
    while (_cache.length > 16) {
      _cache.remove(_cache.keys.first);
    }
    return result;
  }

  void close() => _client.close();
}

/// Parse and sort away from the UI isolate; retain provider ranks and conference
/// boundaries rather than constructing a national table from unrelated records.
LeagueStandings parseLeagueStandings(
    (Uint8List, SportsLeague, DateTime, bool) input) {
  final (body, league, now, directory) = input;
  final root = jsonDecode(utf8.decode(body));
  if (root is! Map) throw const FormatException('Expected standings object');
  SportsTeam? team(Object? value) {
    if (value is! Map) return null;
    final id = value['id']?.toString();
    final name = (value['displayName'] ?? value['name'])?.toString();
    if (id == null || name == null || name.isEmpty) return null;
    String? image(Object? item) {
      final raw = item is Map ? item['href'] : item;
      if (raw is! String) return null;
      final uri = Uri.tryParse(raw);
      return uri != null &&
              uri.scheme == 'https' &&
              uri.host.isNotEmpty &&
              uri.userInfo.isEmpty
          ? raw
          : null;
    }

    final logos = value['logos'];
    final logo = image(value['logo']) ??
        (logos is List
            ? logos.map(image).whereType<String>().firstOrNull
            : null) ??
        image(value['headshot']) ??
        image(value['flag']);
    return SportsTeam(
        logoUrl: logo,
        color: value['color']?.toString(),
        id: id,
        name: name,
        shortName: (value['shortDisplayName'] ?? value['shortName'] ?? name)
            .toString(),
        abbreviation: (value['abbreviation'] ?? '').toString());
  }

  if (directory) {
    final teams = <String, SportsTeam>{};
    final aliases = <String, Set<String>>{};
    for (final sport in (root['sports'] as List?) ?? const []) {
      if (sport is! Map) continue;
      for (final item in (sport['leagues'] as List?) ?? const []) {
        if (item is! Map) continue;
        for (final entry in (item['teams'] as List?) ?? const []) {
          if (entry is! Map) continue;
          final parsed = team(entry['team']);
          if (parsed != null) {
            teams[parsed.id] = parsed;
            final raw = entry['team'];
            aliases[parsed.id] = Set.unmodifiable({
              if (raw is Map)
                for (final key in ['name', 'location'])
                  if (raw[key] is String && (raw[key] as String).isNotEmpty)
                    raw[key] as String,
            });
          }
        }
      }
    }
    final rows = teams.values.toList()
      ..sort((a, b) => a.name.compareTo(b.name));
    return LeagueStandings(directory: true, tables: [
      StandingTable(
          'Teams',
          List.unmodifiable([
            for (final item in rows)
              StandingTeam(item, const {}, null,
                  nameAliases: aliases[item.id] ?? const {})
          ]))
    ]);
  }
  final tables = <StandingTable>[];
  final tableYears = <int>{};
  final tableLabels = <String>{};
  final rootSeason = root['season'];
  String? season = rootSeason is Map
      ? (rootSeason['displayName'] ?? rootSeason['year'])?.toString()
      : null;
  void walk(Map node, int depth) {
    if (depth > 8) return;
    final standings = node['standings'];
    if (standings is Map && standings['entries'] is List) {
      season ??= standings['seasonDisplayName']?.toString() ??
          standings['season']?.toString();
      final rows = <StandingTeam>[];
      for (final entry in standings['entries'] as List) {
        if (entry is! Map) continue;
        final parsed = team(entry['team'] ?? entry['athlete']);
        if (parsed == null) continue;
        final stats = <String, String>{};
        final labels = <String, String>{};
        for (final stat in (entry['stats'] as List?) ?? const []) {
          if (stat is! Map) continue;
          final name = (stat['name'] ?? stat['type'])?.toString();
          if (name != null) {
            if (stat['displayName'] is String) {
              labels[name] = stat['displayName'] as String;
            }
            stats.putIfAbsent(
                name,
                () => (stat['displayValue'] ??
                        stat['summary'] ??
                        stat['value'] ??
                        '')
                    .toString());
          }
        }
        // ESPN uses different field names for rugby and some football feeds.
        // Preserve the reported values; only normalise their column names.
        for (final alias in const {
          'gamesWon': 'wins',
          'gamesLost': 'losses',
          'gamesDrawn': 'ties',
          'pointsDifference': 'pointDifferential',
        }.entries) {
          final value = stats[alias.key];
          if (value != null) {
            stats.putIfAbsent(alias.value, () => value);
            final label = labels[alias.key];
            if (label != null) labels.putIfAbsent(alias.value, () => label);
          }
        }
        final rank = int.tryParse(stats['rank'] ?? stats['playoffSeed'] ?? '');
        rows.add(StandingTeam(parsed, Map.unmodifiable(stats),
            rank != null && rank > 0 ? rank : null,
            statLabels: Map.unmodifiable(labels)));
      }
      if (rows.isNotEmpty) {
        final tableYear = int.tryParse('${standings['season']}');
        final tableLabel = standings['seasonDisplayName']?.toString();
        if (tableYear != null) tableYears.add(tableYear);
        if (tableLabel != null && tableLabel.isNotEmpty) {
          tableLabels.add(tableLabel);
        }
        if (rows.every((r) => r.position != null)) {
          rows.sort((a, b) => a.position!.compareTo(b.position!));
        }
        tables.add(StandingTable(
            (node['name'] ?? league.name).toString(), List.unmodifiable(rows)));
      }
    }
    for (final child in (node['children'] as List?) ?? const []) {
      if (child is Map) walk(child, depth + 1);
    }
  }

  walk(root, 0);
  final available = <int>[];
  for (final item in (root['seasons'] as List?) ?? const []) {
    if (item is! Map) continue;
    final year = int.tryParse('${item['year']}');
    final start = DateTime.tryParse('${item['startDate']}');
    if (year != null && start != null && !start.isAfter(now)) {
      available.add(year);
    }
  }
  available.sort((a, b) => b.compareTo(a));
  final rootYear =
      rootSeason is Map ? int.tryParse('${rootSeason['year']}') : null;
  final futureRollover =
      rootYear != null && available.isNotEmpty && rootYear > available.first;
  // Root metadata can already describe next season while the actual rows still
  // belong to a completed season. The table's own season identifies its data.
  if (tableYears.length > 1) {
    throw const FormatException('Standings contain different seasons');
  }
  final tableYear = tableYears.firstOrNull;
  season = tableLabels.length == 1
      ? tableLabels.single
      : tableYear?.toString() ?? season;
  final staleTable = tableYear != null && available.isNotEmpty
      ? tableYear < available.first
      : null;
  return LeagueStandings(
      tables: List.unmodifiable(tables),
      season: season,
      previousSeason: staleTable,
      fallbackYear: futureRollover || staleTable == true
          ? available.first
          : available
              .where((year) => year < (rootYear ?? available.first))
              .firstOrNull,
      fallbackIsPreviousSeason: !futureRollover && staleTable != true);
}

/// World Rugby supplies global positions, not a league table. Join only exact,
/// unique country names to the already loaded ESPN directory so favourites keep
/// their existing identities. Unknown or ambiguous countries remain unranked.
LeagueStandings parseWorldRugbyRankings((Uint8List, LeagueStandings) input) {
  final (body, directory) = input;
  final root = jsonDecode(utf8.decode(body));
  if (root is! Map ||
      root['label']?.toString().replaceAll("'", '').toLowerCase() !=
          'mens rugby union' ||
      root['entries'] is! List) {
    return directory;
  }
  final effective = root['effective'];
  final date =
      effective is Map ? DateTime.tryParse('${effective['label']}') : null;
  if (date == null) return directory;
  String country(String name) {
    final normal = name.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
    return normal == 'united states of america' ? 'usa' : normal;
  }

  final byName = <String, List<Map>>{};
  for (final entry in root['entries'] as List) {
    if (entry is! Map || entry['team'] is! Map) continue;
    final name = entry['team']['name'];
    if (name is String && name.isNotEmpty) {
      byName.putIfAbsent(country(name), () => []).add(entry);
    }
  }
  final directoryNames = <String, int>{};
  for (final table in directory.tables) {
    for (final row in table.rows) {
      directoryNames.update(country(row.team.name), (count) => count + 1,
          ifAbsent: () => 1);
    }
  }
  final ranked = <StandingTeam>[], unranked = <StandingTeam>[];
  for (final table in directory.tables) {
    for (final row in table.rows) {
      final name = country(row.team.name),
          matches = byName[country(row.team.name)];
      final match = directoryNames[name] == 1 && matches?.length == 1
          ? matches!.single
          : null;
      final rank = match?['pos'], points = match?['pts'];
      if (rank is! int ||
          rank < 1 ||
          rank > 500 ||
          points is! num ||
          !points.isFinite ||
          points < 0 ||
          points > 200) {
        unranked.add(row);
        continue;
      }
      ranked.add(StandingTeam(
          row.team, {'rankingPoints': points.toStringAsFixed(2)}, rank,
          statLabels: const {'rankingPoints': 'Rating points'}));
    }
  }
  if (ranked.isEmpty) return directory;
  ranked.sort((a, b) => a.position!.compareTo(b.position!));
  return LeagueStandings(
      rankings: true,
      rankingTitle: 'World rankings',
      sourceName: 'World Rugby',
      updatedAt: date,
      tables: [
        StandingTable(
            'World rankings · available teams', List.unmodifiable(ranked)),
        if (unranked.isNotEmpty)
          StandingTable('Other available teams', List.unmodifiable(unranked)),
      ]);
}
