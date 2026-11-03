import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../models/sports.dart';
import '../models/sports_details.dart';

/// No polling, startup calls, linked-resource traversal or per-player requests.
/// Each explicit selection requires at most one bounded provider response.
class SportsDetailsService {
  SportsDetailsService(
      {http.Client? client,
      DateTime Function()? clock,
      this.timeout = const Duration(seconds: 12)})
      : _client = client ?? http.Client(),
        _clock = clock ?? DateTime.now;
  static SportsDetailsService? _shared;
  static SportsDetailsService get instance =>
      _shared ??= SportsDetailsService();
  final http.Client _client;
  final DateTime Function() _clock;
  final Duration timeout;
  final _cache = <String, (SportsDetails, DateTime, Duration)>{};
  final _flights = <String, Future<SportsDetails>>{};
  final _queue = Queue<Completer<void>>();
  final _aborts = <Completer<void>>{};
  var _active = 0;
  bool _closed = false;

  static bool _supported(SportsLeague league, String id) =>
      league.source == 'ESPN' &&
      league.kind == SportsKind.team &&
      RegExp(r'^[0-9]+$').hasMatch(id) &&
      RegExp(r'^(soccer|basketball|football|hockey|baseball|rugby|volleyball|lacrosse|field-hockey|australian-football)/[a-z0-9.-]+$')
          .hasMatch(league.espnPath);

  Future<SportsDetails> game(SportsGame game, {bool refresh = false}) {
    final fallback = SportsDetails(
        title: '${game.away.name} at ${game.home.name}',
        subtitle: game.statusText,
        source: game.source,
        fetchedAt: _clock());
    if (!_supported(game.league, game.id) || game.source != 'ESPN') {
      return Future.value(_unavailable(
          fallback, 'Extra game details are not available from this source.'));
    }
    final ttl = game.state == GameState.post
        ? const Duration(hours: 6)
        : const Duration(minutes: 2);
    return _get(
        'game:${game.league.espnPath}:${game.id}',
        Uri.https(
            'site.api.espn.com',
            '/apis/site/v2/sports/${game.league.espnPath}/summary',
            {'event': game.id}),
        fallback,
        ttl,
        refresh,
        game: game);
  }

  Future<SportsDetails> team(SportsLeague league, SportsTeam team,
      {bool refresh = false}) {
    final fallback = SportsDetails(
        title: team.name,
        subtitle: league.name,
        source: league.source,
        fetchedAt: _clock());
    if (!_supported(league, team.id)) {
      return Future.value(_unavailable(
          fallback, 'Extra team details are not available from this source.'));
    }
    return _get(
        'team:${league.espnPath}:${team.id}',
        Uri.https(
            'site.api.espn.com',
            '/apis/site/v2/sports/${league.espnPath}/teams/${team.id}',
            {'enable': 'roster'}),
        fallback,
        const Duration(hours: 1),
        refresh,
        team: team);
  }

  SportsDetails _unavailable(SportsDetails data, String message) =>
      SportsDetails(
          title: data.title,
          subtitle: data.subtitle,
          source: data.source,
          fetchedAt: data.fetchedAt,
          unsupported: true,
          message: message);

  Future<SportsDetails> _get(
      String key, Uri uri, SportsDetails basic, Duration ttl, bool refresh,
      {SportsGame? game, SportsTeam? team}) {
    if (_closed) return Future.value(_failure(basic));
    final now = _clock(), cached = _cache[key];
    if (!refresh &&
        cached != null &&
        !now.isBefore(cached.$2) &&
        now.difference(cached.$2) < cached.$3) {
      _cache.remove(key);
      _cache[key] = cached;
      return Future.value(cached.$1);
    }
    return _flights.putIfAbsent(
        key,
        () => _load(key, uri, basic, ttl, game: game, team: team)
                .whenComplete(() {
              _flights.remove(key);
            }));
  }

  Future<void> _acquire() async {
    if (_closed) throw StateError('Details service closed');
    if (_active < 2) {
      _active++;
      return;
    }
    final waiter = Completer<void>();
    _queue.add(waiter);
    await waiter.future;
    if (_closed) {
      _release();
      throw StateError('Details service closed');
    }
  }

  void _release() {
    if (_queue.isNotEmpty) {
      _queue.removeFirst().complete();
    } else {
      _active--;
    }
  }

  Future<Uint8List> _read(Uri uri) async {
    final abort = Completer<void>();
    _aborts.add(abort);
    try {
      return await (() async {
        final response = await _client.send(
            http.AbortableRequest('GET', uri, abortTrigger: abort.future));
        if (response.statusCode != 200) {
          await response.stream.listen(null).cancel();
          if (response.statusCode == 404 || response.statusCode == 400) {
            throw const _Unavailable();
          }
          throw StateError('Details request failed');
        }
        final bytes = BytesBuilder(copy: false);
        await for (final chunk in response.stream) {
          if (bytes.length + chunk.length > 2 * 1024 * 1024) {
            throw StateError('Details response too large');
          }
          bytes.add(chunk);
        }
        return bytes.takeBytes();
      })()
          .timeout(timeout);
    } finally {
      if (!abort.isCompleted) abort.complete();
      _aborts.remove(abort);
    }
  }

  Future<SportsDetails> _load(
      String key, Uri uri, SportsDetails basic, Duration ttl,
      {SportsGame? game, SportsTeam? team}) async {
    var acquired = false;
    SportsDetails result;
    try {
      await _acquire();
      acquired = true;
      final bytes = await _read(uri);
      result = await compute(_parse, (bytes, basic, game, team, _clock()));
    } on _Unavailable {
      result = _unavailable(
          basic, 'The provider does not have details for this selection.');
    } catch (_) {
      result = _failure(basic);
    } finally {
      if (acquired) _release();
    }
    final old = _cache[key]?.$1;
    if ((result.failed || result.unsupported) &&
        old != null &&
        !old.unsupported &&
        old.sections.isNotEmpty) {
      result = old.withRefreshFailure();
    }
    if (!_closed) {
      _cache.remove(key);
      _cache[key] =
          (result, _clock(), result.failed ? const Duration(seconds: 30) : ttl);
      while (_cache.length > 24) {
        _cache.remove(_cache.keys.first);
      }
    }
    return result;
  }

  SportsDetails _failure(SportsDetails basic) => SportsDetails(
      title: basic.title,
      subtitle: basic.subtitle,
      source: basic.source,
      fetchedAt: basic.fetchedAt,
      failed: true,
      message: 'Details could not be loaded. Try again.');

  void close() {
    _closed = true;
    for (final abort in _aborts) {
      if (!abort.isCompleted) abort.complete();
    }
    _client.close();
    _cache.clear();
  }
}

class _Unavailable implements Exception {
  const _Unavailable();
}

Map<String, dynamic> _map(dynamic value) =>
    value is Map<String, dynamic> ? value : const {};
List<dynamic> _list(dynamic value) => value is List ? value : const [];
String _text(dynamic value, [int max = 160]) {
  if (value is! String && value is! num) return '';
  final text = '$value'
      .replaceAll(RegExp(r'<[^>]*>'), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  return text.length <= max ? text : '${text.substring(0, max - 1)}…';
}

String _name(Map<String, dynamic> value) =>
    _text(value['displayName'] ?? value['fullName'] ?? value['name']);
String _position(Map<String, dynamic> value) {
  final p = _map(value['position']);
  return _text(p['abbreviation'] ?? p['displayName'] ?? p['name']);
}

SportsDetails _parse(
    (Uint8List, SportsDetails, SportsGame?, SportsTeam?, DateTime) args) {
  final root = _map(jsonDecode(utf8.decode(args.$1)));
  if (root.isEmpty) throw const FormatException('Empty details response');
  return args.$3 != null
      ? _game(root, args.$2, args.$3!, args.$5)
      : _team(root, args.$2, args.$4!, args.$5);
}

SportsDetails _game(Map<String, dynamic> root, SportsDetails basic,
    SportsGame game, DateTime now) {
  final header = _map(root['header']);
  if (_text(header['id']) != game.id) {
    throw const FormatException('Different event');
  }
  final competition = _list(header['competitions'])
      .map(_map)
      .where((c) => _text(c['id']) == game.id)
      .firstOrNull;
  if (competition == null) throw const FormatException('Missing event');
  final identities = {game.home.id, game.away.id};
  final sides = _list(competition['competitors']).map(_map).toList();
  if (sides.length != 2 ||
      !sides.every((c) => identities.contains(_text(_map(c['team'])['id']))) ||
      sides.map((c) => _text(_map(c['team'])['id'])).toSet().length != 2) {
    throw const FormatException('Different matchup');
  }
  final sections = <SportsDetailSection>[];
  final status = _map(_map(competition['status'])['type']);
  final info = _map(root['gameInfo']),
      venue = _map(_map(root['gameInfo'])['venue']);
  final infoRows = <SportsDetailRow>[];
  void infoRow(String label, dynamic value) {
    final text = _text(value, 240);
    if (text.isNotEmpty) infoRows.add(SportsDetailRow(label, [text]));
  }

  final statusLabel = status['state'] == 'pre'
      ? status['description'] ?? 'Scheduled'
      : status['detail'] ?? status['description'];
  infoRow('Status', statusLabel);
  infoRow('Venue', venue['fullName']);
  final address = _map(venue['address']);
  infoRow(
      'Location',
      [address['city'], address['state'], address['country']]
          .whereType<String>()
          .where((s) => s.isNotEmpty)
          .join(', '));
  infoRow('Attendance', info['attendance']);
  final officials = _list(info['officials'])
      .map(_map)
      .map((o) => _text(o['displayName'] ?? o['fullName']))
      .where((s) => s.isNotEmpty)
      .take(8)
      .join(', ');
  infoRow('Officials', officials);
  // Headlines only: no article-body copying, external content or media requests.
  infoRow('Headline', _map(root['article'])['headline']);
  if (infoRows.isNotEmpty) {
    sections.add(SportsDetailSection('Game information',
        kind: SportsDetailKind.information,
        columns: const ['Details'],
        rows: infoRows));
  }
  final box = _map(root['boxscore']);
  final order =
      game.league.soccer ? [game.home, game.away] : [game.away, game.home];
  final stats = <String, Map<String, (String, String)>>{};
  for (final entry in _list(box['teams']).map(_map).take(2)) {
    final id = _text(_map(entry['team'])['id']);
    if (!identities.contains(id)) continue;
    stats[id] = _statistics(entry['statistics']);
  }
  final statKeys = <String>{for (final side in order) ...?stats[side.id]?.keys};
  final comparison = <SportsDetailRow>[];
  for (final key in statKeys.take(60)) {
    final label =
        stats[order[0].id]?[key]?.$1 ?? stats[order[1].id]?[key]?.$1 ?? '';
    if (label.isEmpty) continue;
    comparison.add(SportsDetailRow(
        label, [for (final side in order) stats[side.id]?[key]?.$2 ?? '—'],
        id: key));
  }
  if (comparison.isNotEmpty) {
    sections.add(SportsDetailSection(
        status['state'] == 'pre' ? 'Pregame comparison' : 'Match statistics',
        kind: SportsDetailKind.comparison,
        columns: [
          for (final side in order)
            side.abbreviation.isEmpty ? side.shortName : side.abbreviation
        ],
        rows: comparison));
  }

  final periods = <String, List<String>>{};
  for (final side in sides) {
    final values = _list(side['linescores'])
        .map(_map)
        .take(16)
        .map((line) => _text(line['displayValue'] ?? line['value'], 16))
        .toList();
    if (values.isNotEmpty) periods[_text(_map(side['team'])['id'])] = values;
  }
  if (status['state'] != 'pre' && periods.length == 2) {
    final count = periods.values
        .map((values) => values.length)
        .reduce((a, b) => a > b ? a : b);
    final sport = game.league.espnPath.split('/').first;
    final regulation = sport == 'baseball'
        ? 9
        : sport == 'hockey'
            ? 3
            : sport == 'soccer' ||
                    sport == 'rugby' ||
                    game.league.espnPath == 'basketball/mens-college-basketball'
                ? 2
                : 4;
    final prefix = sport == 'baseball'
        ? ''
        : sport == 'hockey'
            ? 'P'
            : regulation == 2
                ? 'H'
                : 'Q';
    sections.add(SportsDetailSection(
        sport == 'baseball' ? 'Innings' : 'Scoring by period',
        kind: SportsDetailKind.periods,
        columns: [
          for (var i = 0; i < count; i++)
            i < regulation || sport == 'baseball'
                ? '$prefix${i + 1}'
                : 'OT${i - regulation + 1}'
        ],
        rows: [
          for (final side in order)
            SportsDetailRow(
                side.abbreviation,
                [
                  for (var i = 0; i < count; i++)
                    i < periods[side.id]!.length ? periods[side.id]![i] : '–'
                ],
                id: side.id)
        ]));
  }

  for (final team in _list(box['players']).map(_map).take(2)) {
    final id = _text(_map(team['team'])['id']);
    if (!identities.contains(id)) continue;
    final teamName = _name(_map(team['team']));
    for (final category in _list(team['statistics']).map(_map).take(8)) {
      final allColumns =
          _list(category['labels']).map((v) => _text(v, 32)).toList();
      if (allColumns.isEmpty) continue;
      final indices = _columnIndices(
          allColumns, _list(category['keys']), game.league.espnPath);
      final rows = <SportsDetailRow>[];
      for (final player in _list(category['athletes']).map(_map).take(100)) {
        final athlete = _map(player['athlete']),
            name = _name(_map(player['athlete']));
        if (name.isEmpty) continue;
        final values = _list(player['stats']);
        if (values.length != allColumns.length &&
            player['didNotPlay'] != true) {
          continue;
        }
        rows.add(SportsDetailRow(
            name,
            [
              for (final i in indices)
                player['didNotPlay'] == true ? '—' : _text(values[i], 40)
            ],
            id: _text(athlete['id']),
            detail: [
              _position(athlete),
              if (player['starter'] == true) 'Starter',
              if (player['didNotPlay'] == true) 'Did not play'
            ].where((s) => s.isNotEmpty).join(' · ')));
      }
      if (rows.isNotEmpty) {
        sections.add(SportsDetailSection(
            '$teamName · ${_text(category['name'] ?? category['type'] ?? 'Players')}',
            kind: SportsDetailKind.players,
            teamId: id,
            columns: [for (final i in indices) allColumns[i]],
            rows: rows));
      }
    }
  }
  for (final roster in _list(root['rosters']).map(_map).take(2)) {
    if (!identities.contains(_text(_map(roster['team'])['id']))) continue;
    final rows = <SportsDetailRow>[];
    for (final player in _list(roster['roster']).map(_map).take(100)) {
      final athlete = _map(player['athlete']),
          name = _name(_map(player['athlete']));
      if (name.isEmpty) continue;
      rows.add(SportsDetailRow(
          name,
          [
            _text(player['jersey'] ?? athlete['jersey']),
            _position(player).isEmpty ? _position(athlete) : _position(player)
          ],
          id: _text(athlete['id']),
          detail: [
            if (player['starter'] == true) 'Starter',
            if (player['captain'] == true) 'Captain',
            if (player['subbedIn'] == true) 'Substituted on',
            if (player['subbedOut'] == true) 'Substituted off'
          ].join(' · ')));
    }
    if (rows.isNotEmpty) {
      sections.add(SportsDetailSection(
          '${_name(_map(roster['team']))} · Lineup',
          kind: SportsDetailKind.lineup,
          teamId: _text(_map(roster['team'])['id']),
          columns: const ['#', 'Position'],
          rows: rows));
    }
  }
  return SportsDetails(
      title:
          _text(header['name']).isEmpty ? basic.title : _text(header['name']),
      subtitle:
          _text(statusLabel).isEmpty ? basic.subtitle : _text(statusLabel),
      scoreLine: status['state'] == 'pre'
          ? null
          : order.map((side) {
              final competitor = sides
                  .firstWhere((c) => _text(_map(c['team'])['id']) == side.id);
              final score = _text(competitor['score']);
              return '${side.name}  ${score.isEmpty ? '–' : score}';
            }).join('\n'),
      source: 'ESPN',
      fetchedAt: now,
      scores: status['state'] == 'pre'
          ? const {}
          : {
              for (final side in sides)
                _text(_map(side['team'])['id']): _text(side['score'])
            },
      sections: sections.take(24).toList(),
      message: sections.isEmpty
          ? 'No extra details have been published for this game.'
          : null);
}

Map<String, (String, String)> _statistics(dynamic input) {
  final result = <String, (String, String)>{};
  for (final stat in _list(input).map(_map).take(80)) {
    final nested = _list(stat['stats']);
    final category = _text(stat['displayName'] ?? stat['name']);
    for (final item in nested.isEmpty ? [stat] : nested.map(_map).take(80)) {
      final key = _text(item['name']);
      final value = _text(item['displayValue'], 40);
      final label = _text(item['label'] ??
          item['displayName'] ??
          item['abbreviation'] ??
          item['name']);
      if (key.isEmpty || value.isEmpty || label.isEmpty) continue;
      result[nested.isEmpty ? key : '$category:$key'] =
          (nested.isEmpty ? label : '$category · $label', value);
      if (result.length >= 80) return result;
    }
  }
  return result;
}

List<int> _columnIndices(List<String> labels, List<dynamic> keys, String path) {
  // Keep useful sporting metrics visible on TV without dropping their original
  // column indices. Unknown sports retain the first six supplied columns.
  final preferred = path.startsWith('basketball/')
      ? [
          'points',
          'rebounds',
          'assists',
          'minutes',
          'fieldGoalsMade-fieldGoalsAttempted',
          'plusMinus'
        ]
      : path.startsWith('hockey/')
          ? [
              'goals',
              'assists',
              'shotsTotal',
              'plusMinus',
              'timeOnIce',
              'saves',
              'savePct',
              'goalsAgainst'
            ]
          : path.startsWith('baseball/')
              ? [
                  'atBats',
                  'runs',
                  'hits',
                  'RBIs',
                  'homeRuns',
                  'avg',
                  'innings',
                  'earnedRuns',
                  'strikeouts'
                ]
              : const <String>[];
  final indices = <int>[];
  for (final key in preferred) {
    final i = keys.indexOf(key);
    if (i >= 0 && i < labels.length && !indices.contains(i)) indices.add(i);
    if (indices.length == 6) break;
  }
  for (var i = 0; i < labels.length && indices.length < 6; i++) {
    if (!indices.contains(i)) indices.add(i);
  }
  return indices;
}

SportsDetails _team(Map<String, dynamic> root, SportsDetails basic,
    SportsTeam selected, DateTime now) {
  final team = _map(root['team']);
  if (_text(team['id']) != selected.id) {
    throw const FormatException('Different team');
  }
  final sections = <SportsDetailSection>[], info = <SportsDetailRow>[];
  final summary = _text(team['standingSummary']);
  if (summary.isNotEmpty) info.add(SportsDetailRow('Standing', [summary]));
  for (final record in _list(_map(team['record'])['items']).map(_map).take(8)) {
    final value = _text(record['summary']);
    if (value.isNotEmpty) {
      info.add(SportsDetailRow(
          _text(record['description'] ?? record['name'] ?? 'Record'), [value]));
    }
  }
  if (info.isNotEmpty) {
    sections.add(SportsDetailSection('Team record',
        kind: SportsDetailKind.record, columns: const ['Record'], rows: info));
  }
  final roster = <SportsDetailRow>[], seen = <String>{};
  for (final athlete in _list(team['athletes']).map(_map).take(200)) {
    final id = _text(athlete['id']), name = _name(athlete);
    if (id.isEmpty || name.isEmpty || !seen.add(id)) continue;
    roster.add(SportsDetailRow(
        name, [_text(athlete['jersey']), _position(athlete)],
        id: id, detail: _text(_map(athlete['status'])['name'])));
  }
  if (roster.isNotEmpty) {
    sections.add(SportsDetailSection('Roster',
        kind: SportsDetailKind.lineup,
        teamId: selected.id,
        columns: const ['#', 'Position'],
        rows: roster));
  }
  return SportsDetails(
      title: _name(team).isEmpty ? basic.title : _name(team),
      subtitle: basic.subtitle,
      source: 'ESPN',
      fetchedAt: now,
      sections: sections,
      message: sections.isEmpty
          ? 'No roster or extra team details have been published.'
          : null);
}
