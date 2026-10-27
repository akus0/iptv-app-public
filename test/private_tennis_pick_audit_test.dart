import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:nox_iptv/models/epg_program.dart';
import 'package:nox_iptv/models/sports.dart';
import 'package:nox_iptv/services/m3u_parser.dart';
import 'package:nox_iptv/services/sports_service.dart';
import 'package:nox_iptv/services/sports_channel_matcher.dart';
import 'package:nox_iptv/services/sports_match_inputs.dart';

class _Guide implements SportsMatchGuide {
  _Guide(this.rows, this.now);
  final List<EpgProgram> rows;
  final DateTime now;
  @override
  int get changeRevision => 1;
  @override
  DateTime? get lastUpdated => now;
  late final Map<String, EpgProgram> current = () {
    final result = <String, EpgProgram>{};
    for (final p in rows) {
      if (p.isNowPlaying(now)) result.putIfAbsent(p.channelId, () => p);
    }
    return result;
  }();
  @override
  EpgProgram? getCurrentProgram(String id) => current[id];
  @override
  EpgProgram? getNextProgram(String id) => null;
  @override
  Future<List<EpgProgram>> findProgrammesByTitle(
          DateTime from, DateTime to, List<String> terms,
          {List<String>? channelIds}) async =>
      rows
          .where((p) =>
              p.start.isBefore(to) &&
              p.stop.isAfter(from) &&
              terms.any((t) => p.title.toLowerCase().contains(t)))
          .toList();
  @override
  Future<List<EpgProgram>> findSportsProgrammesForChannels(
      List<String> ids, DateTime from, DateTime to) async {
    final set = ids.toSet();
    return rows
        .where((p) =>
            set.contains(p.channelId) &&
            p.start.isBefore(to) &&
            p.stop.isAfter(from))
        .toList();
  }
}

class _Picks implements SportsMatchPicks {
  String? picked;
  @override
  String? channelIdFor(SportsGame game) =>
      game.id.contains('185018') ? picked : null;
}

void main() {
  const enabled = bool.fromEnvironment('PRIVATE_TENNIS_AUDIT');
  test(
      'saved private Almaty metadata retains alternatives after choosing a feed',
      () async {
    await HttpOverrides.runZoned(() async {
      final data = jsonDecode(
          await File(const String.fromEnvironment('PRIVATE_TENNIS_GUIDE_FILE'))
              .readAsString()) as Map;
      final now = DateTime.parse(data['at']);
      final rows = [
        for (final r in data['rows'])
          EpgProgram(
              channelId: r[0],
              start: DateTime.fromMillisecondsSinceEpoch(r[1]),
              stop: DateTime.fromMillisecondsSinceEpoch(r[2]),
              title: r[3],
              description: r[4],
              isLive: r[5] == 1)
      ];
      final games = parseEspnScoreboard((
        await File(const String.fromEnvironment('PRIVATE_TENNIS_SCORES_FILE'))
            .readAsString(),
        sportsLeagueById('tennis.atp')!
      )).where((g) => g.start.toUtc().day == 23).toList();
      final channels = M3uParser.parse(
          await File(
                  const String.fromEnvironment('PRIVATE_TENNIS_PLAYLIST_FILE'))
              .readAsString(),
          playlistId: 'audit');
      final matcher = SportsChannelMatcher(_Guide(rows, now), clock: () => now);
      await matcher.prepare(channels);
      final picks = _Picks();
      final timer = Stopwatch()..start();
      final before =
          await matcher.matchDay(games, picks, includePossible: true);
      final elapsed = timer.elapsedMilliseconds;
      final game = games.firstWhere((g) => g.id.contains('185018'));
      final key = SportsChannelPicks.eventKey(game);
      final matches = before[key]!;
      expect(matches.length, greaterThan(1));
      picks.picked = matches[1].channel.id;
      final after =
          (await matcher.matchDay(games, picks, includePossible: true))[key]!;
      expect(after.first.reason, MatchReason.pick);
      expect(after.map((m) => m.channel.id).toSet(),
          containsAll(matches.map((m) => m.channel.id)));
      timer.reset();
      final expanded = await matcher.alternativesFor(game, matches: after);
      final expandedMs = timer.elapsedMilliseconds;
      expect(expanded.length, greaterThan(8));
      expect(expanded.first.reason, MatchReason.pick);
      expect(expanded.map((m) => m.channel.id),
          containsAll(after.map((m) => m.channel.id)));
      final report = {
        'expandedCount': expanded.length,
        'expandedMs': expandedMs,
        'expandedTop': [
          for (final m in expanded.take(12))
            {
              'channel': m.channel.name,
              'reason': m.reason.name,
              'score': m.score,
              'programme': m.programme?.title
            }
        ],
        'fixture': '${game.home.name} vs ${game.away.name}',
        'tournament': game.event?.title,
        'channelCount': channels.length,
        'guideRows': rows.length,
        'matchMs': elapsed,
        'before': [
          for (final m in matches)
            {
              'channel': m.channel.name,
              'reason': m.reason.name,
              'score': m.score,
              'programme': m.programme?.title
            }
        ],
        'after': [
          for (final m in after)
            {
              'channel': m.channel.name,
              'reason': m.reason.name,
              'score': m.score,
              'programme': m.programme?.title
            }
        ]
      };
      await File(const String.fromEnvironment('PRIVATE_TENNIS_REPORT'))
          .writeAsString(jsonEncode(report));
      // ignore: avoid_print
      print(jsonEncode(report));
      matcher.dispose();
    },
        createHttpClient: (_) =>
            throw StateError('Network forbidden in saved tennis audit'));
  },
      skip: enabled ? false : 'Optional private saved tennis metadata',
      timeout: const Timeout(Duration(minutes: 2)));
}
