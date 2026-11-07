import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:nox_iptv/models/channel.dart';
import 'package:nox_iptv/models/epg_program.dart';
import 'package:nox_iptv/models/sports.dart';
import 'package:nox_iptv/services/sports_channel_matcher.dart';
import 'package:nox_iptv/services/sports_match_inputs.dart';
import 'package:nox_iptv/utils/sports_title_matcher.dart';

final _at = DateTime.utc(2026, 11, 6, 12);

class _Guide implements SportsMatchGuide {
  final rows = <EpgProgram>[];
  @override
  int get changeRevision => 1;
  @override
  DateTime? get lastUpdated => _at;
  @override
  EpgProgram? getCurrentProgram(String id) => null;
  @override
  EpgProgram? getNextProgram(String id) => null;
  @override
  Future<List<EpgProgram>> findProgrammesByTitle(
      DateTime from, DateTime to, List<String> terms) async {
    final matcher = SportsTitleMatcher(terms, precomputeTransitions: true);
    return rows.where((p) => matcher.matches(p.title)).toList();
  }

  @override
  Future<List<EpgProgram>> findSportsProgrammesForChannels(
          List<String> ids, DateTime from, DateTime to) async =>
      [];
}

class _Picks implements SportsMatchPicks {
  @override
  String? channelIdFor(SportsGame g) => null;
}

SportsTeam _team(Map t) => SportsTeam(
    id: t['id'],
    name: t['displayName'] ?? t['name'],
    shortName: t['shortDisplayName'] ?? t['name'],
    abbreviation: t['abbreviation'] ?? '',
    location: t['location']);

// Deliberately independent display variants for captured identities. The report
// distinguishes these synthetic guide spellings from observed broadcast titles.
String _guideSpelling(String value, {required bool soccer}) {
  var result = value.replaceAllMapped(RegExp(r'\b(?:[A-Za-z]\.\s*)+[A-Za-z]\.'),
      (m) => '${m[0]!.replaceAll(RegExp(r'[.\s]'), '')} ');
  if (soccer) {
    result = result
        .replaceAll(RegExp(r'(?<=\S\s)United\b', caseSensitive: false), 'Utd')
        .replaceAll(RegExp(r'\bSaint\b', caseSensitive: false), 'St');
  }
  return result.replaceAll(RegExp(r'\s+'), ' ').trim();
}

String _campusSpelling(String value) => value
    .replaceAll('UC Davis', 'California Davis')
    .replaceAll('UC Irvine', 'California Irvine')
    .replaceAll('UC Riverside', 'California Riverside')
    .replaceAll('UC San Diego', 'California San Diego')
    .replaceAll('UC Santa Barbara', 'California Santa Barbara')
    .replaceAll('UCLA', 'California Los Angeles');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const source = String.fromEnvironment('SPORTS_TEAM_DIRECTORY_FILE');
  const report = String.fromEnvironment('SPORTS_TEAM_DIRECTORY_REPORT');
  test(
      'audit every recorded team directory against guide identities and wrong opponents',
      () async {
    final directories = jsonDecode(await File(source).readAsString()) as List;
    final output = <Map<String, Object?>>[];
    for (final directory in directories) {
      final league = sportsLeagueById(directory['league']['id']);
      if (league == null) continue;
      final teams = directory['teams'] as List;
      final row = <String, Object?>{
        'league': league.id,
        'kind': league.kind.name,
        'source': league.source,
        'directoryStatus': directory['status'],
        'teams': teams.length
      };
      output.add(row);
      if (teams.length < 2) continue;
      final guide = _Guide();
      final engine = SportsChannelMatcher(guide, clock: () => _at);
      final channels = <Channel>[], games = <SportsGame>[];
      final variants = <String, String>{};
      final campuses = <String, String>{};
      void add(String id, String title) {
        channels.add(Channel(
            id: id,
            rawId: id,
            playlistId: 'audit',
            name: 'Event Feed $id',
            group: 'Sports',
            url: 'https://example.invalid/$id'));
        guide.rows.add(EpgProgram(
            channelId: id,
            title: title,
            start: _at,
            stop: _at.add(const Duration(hours: 2))));
      }

      for (var i = 0; i + 1 < teams.length; i += 2) {
        final home = _team(teams[i]), away = _team(teams[i + 1]);
        final g = SportsGame(
            id: '$i',
            league: league,
            start: _at,
            state: GameState.live,
            statusText: '',
            home: home,
            away: away);
        games.add(g);
        add('full-$i', '${league.name}: ${home.name} vs ${away.name}');
        add('short-$i',
            '${league.name}: ${home.shortName} vs ${away.shortName}');
        final homeVariant = _guideSpelling(home.name, soccer: league.soccer);
        final awayVariant = _guideSpelling(away.name, soccer: league.soccer);
        if (homeVariant != home.name.trim().replaceAll(RegExp(r'\s+'), ' ') ||
            awayVariant != away.name.trim().replaceAll(RegExp(r'\s+'), ' ')) {
          variants[g.id] = '${league.name}: $homeVariant vs $awayVariant';
          add('spelling-$i', variants[g.id]!);
        }
        if (league.id.contains('ncaa') || league.espnPath.contains('college')) {
          final title = '${league.name}: ${home.name} vs ${away.name}';
          final campus = _campusSpelling(title);
          if (campus != title) {
            campuses[g.id] = campus;
            add('campus-$i', campus);
          }
        }
        if (teams.length > 2) {
          add('wrong-$i',
              '${league.name}: ${home.name} vs ${_team(teams[(i + 2) % teams.length]).name}');
        }
      }
      try {
        await engine.prepare(channels);
        final matched = await engine.matchDay(games, _Picks());
        final misses = <Map<String, Object?>>[], wrong = <String>[];
        var full = 0, short = 0, spelling = 0, campus = 0;
        final campusMisses = <String>[];
        final spellingMisses = <String>[];
        for (final g in games) {
          final ids = matched[SportsChannelPicks.eventKey(g)]!
              .where((m) => m.reason == MatchReason.guide)
              .map((m) => m.channel.id)
              .toSet();
          if (campuses.containsKey(g.id)) {
            if (ids.contains('campus-${g.id}')) {
              campus++;
            } else {
              campusMisses.add(campuses[g.id]!);
            }
          }
          if (variants.containsKey(g.id)) {
            if (ids.contains('spelling-${g.id}')) {
              spelling++;
            } else {
              spellingMisses.add(variants[g.id]!);
            }
          }
          if (ids.contains('full-${g.id}')) full++;
          if (ids.contains('short-${g.id}')) short++;
          if (ids.contains('wrong-${g.id}')) wrong.add(g.title);
          if (!ids.contains('full-${g.id}') || !ids.contains('short-${g.id}')) {
            misses.add({
              'home': g.home.name,
              'away': g.away.name,
              'homeShort': g.home.shortName,
              'awayShort': g.away.shortName,
              'full': ids.contains('full-${g.id}'),
              'short': ids.contains('short-${g.id}')
            });
          }
        }
        row.addAll({
          'fixtures': games.length,
          'fullMatches': full,
          'shortMatches': short,
          'misses': misses,
          'wrongOpponents': wrong,
          'campusCases': campuses.length,
          'campusMatches': campus,
          'campusMisses': campusMisses,
          'spellingCases': variants.length,
          'spellingMatches': spelling,
          'spellingMisses': spellingMisses
        });
      } finally {
        engine.dispose();
      }
    }
    await File(report).writeAsString(jsonEncode(output));
    // This diagnostic records ambiguous/missing labels separately; it must not
    // train the matcher to accept every short name from an external feed.
    expect(output.length, directories.length);
  },
      skip:
          source.isEmpty ? 'Optional captured public team directories.' : false,
      timeout: const Timeout(Duration(minutes: 10)));
}
