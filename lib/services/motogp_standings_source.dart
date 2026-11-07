import 'dart:convert';
import 'package:flutter/foundation.dart';
import '../models/sports.dart';
import 'sports_standings_service.dart';

const motoGpStandingsClasses = {
  'racing.motogp': 'MotoGP',
  'racing.moto2': 'Moto2',
  'racing.moto3': 'Moto3',
};

/// Uses the standings service's bounded transport and two-request load limit.
/// Shared metadata avoids repeating season/category lookups for each class.
class MotoGpStandingsSource {
  MotoGpStandingsSource(this.read, {DateTime Function()? clock})
      : _clock = clock ?? DateTime.now;
  final Future<Uint8List> Function(Uri) read;
  final DateTime Function() _clock;
  final _metadata = <String, (dynamic, DateTime)>{};
  final _pending = <String, Future<dynamic>>{};
  static const _host = 'api.pulselive.motogp.com';
  Uri _uri(String path, [Map<String, String> query = const {}]) =>
      Uri.https(_host, '/motogp/v1/results/$path', query);

  Future<dynamic> _meta(Uri uri) {
    final key = uri.toString(), cached = _metadata[uri.toString()];
    final age = cached == null ? null : _clock().difference(cached.$2);
    if (age != null && !age.isNegative && age < const Duration(hours: 24)) {
      return Future.value(cached!.$1);
    }
    return _pending.putIfAbsent(
        key,
        () => (() async {
              final data = await compute(_decode, await read(uri));
              if (data is! List || data.length > 100) {
                throw const FormatException('Invalid MotoGP metadata');
              }
              _metadata.remove(key);
              _metadata[key] = (data, _clock());
              while (_metadata.length > 4) {
                _metadata.remove(_metadata.keys.first);
              }
              return data;
            })()
                .whenComplete(() {
              _pending.remove(key);
            }));
  }

  Future<LeagueStandings> load(SportsLeague league, int year) async {
    final categoryName = motoGpStandingsClasses[league.id];
    if (categoryName == null) {
      throw const FormatException('Unsupported MotoGP class');
    }
    final seasons = await _meta(_uri('seasons')) as List;
    final matches =
        seasons.whereType<Map>().where((s) => s['year'] == year).toList();
    if (matches.length != 1 || !_uuid(matches.single['id'])) {
      throw const FormatException('MotoGP season unavailable');
    }
    final seasonId = matches.single['id'] as String;
    final categories =
        await _meta(_uri('categories', {'seasonUuid': seasonId})) as List;
    final matching = categories
        .whereType<Map>()
        .where((c) => '${c['name']}'.replaceAll('™', '').trim() == categoryName)
        .toList();
    if (matching.length != 1 || !_uuid(matching.single['id'])) {
      throw const FormatException('MotoGP category unavailable');
    }
    return compute(parseMotoGpStandings, (
      await read(_uri('standings', {
        'seasonUuid': seasonId,
        'categoryUuid': matching.single['id'] as String,
      })),
      year,
      categoryName
    ));
  }
}

dynamic _decode(Uint8List bytes) => jsonDecode(utf8.decode(bytes));
bool _uuid(dynamic value) =>
    value is String &&
    RegExp(r'^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$')
        .hasMatch(value);

LeagueStandings parseMotoGpStandings((Uint8List, int, String) input) {
  final root = _decode(input.$1);
  if (root is! Map || root['classification'] is! List) {
    throw const FormatException('Invalid MotoGP standings');
  }
  final file = Uri.tryParse('${root['file']}');
  // The publisher's own classification document identifies both year and class.
  if (file?.scheme != 'https' ||
      file?.host != 'resources.motogp.com' ||
      !RegExp('^/files/results/${input.$2}/[A-Z0-9]+/${input.$3}/(?:RAC|SPR)/worldstanding\\.pdf\$')
          .hasMatch(file!.path)) {
    throw const FormatException('Different MotoGP season or class');
  }
  final rows = <StandingTeam>[], ids = <String>{};
  for (final raw in root['classification'] as List) {
    if (raw is! Map || raw['rider'] is! Map) {
      throw const FormatException('Invalid rider');
    }
    final rider = raw['rider'] as Map, team = raw['team'];
    final id = rider['id'], name = rider['full_name'];
    final rank = raw['position'], points = raw['points'];
    if (!_uuid(id) ||
        !ids.add(id as String) ||
        name is! String ||
        name.trim().isEmpty ||
        name.length > 150 ||
        rank is! int ||
        rank < 1 ||
        rank > 200 ||
        points is! num ||
        !points.isFinite ||
        points < 0 ||
        points > 2000 ||
        team is! Map ||
        team['season'] is! Map ||
        team['season']['year'] != input.$2) {
      throw const FormatException('Invalid MotoGP rider standing');
    }
    final stats = <String, String>{'points': '$points'};
    for (final field
        in const {'race_wins': 'wins', 'podiums': 'podiums'}.entries) {
      final value = raw[field.key];
      if (value is num && value.isFinite && value >= 0 && value <= 100) {
        stats[field.value] = '$value';
      }
    }
    rows.add(StandingTeam(
        SportsTeam(
            id: 'motogp:$id',
            name: name.trim(),
            shortName: name.trim(),
            abbreviation: '${rider['number'] ?? ''}'),
        stats,
        rank));
  }
  if (rows.length < 10 || rows.length > 120) {
    throw const FormatException('Incomplete MotoGP standings');
  }
  return LeagueStandings(
      tables: [StandingTable('Riders', rows)],
      season: '${input.$2}',
      sourceName: 'MotoGP');
}
