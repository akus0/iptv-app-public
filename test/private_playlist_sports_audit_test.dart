import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:nox_iptv/models/epg_program.dart';
import 'package:nox_iptv/services/epg_service.dart';
import 'package:nox_iptv/services/m3u_parser.dart';
import 'package:nox_iptv/services/sports_replay_service.dart';
import 'package:nox_iptv/services/storage_service.dart';
import 'package:nox_iptv/services/sports_channel_matcher.dart';
import 'package:nox_iptv/services/sports_match_inputs.dart';
import 'package:nox_iptv/services/sports_service.dart';
import 'package:nox_iptv/models/sports.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class _Guide extends EpgService {
  _Guide(super.storage, this.programmes);
  final List<EpgProgram> programmes;
  late final _byId = {
    for (final p in programmes) normalizeEpgId(p.channelId): p
  };
  @override
  Iterable<EpgProgram> cachedCurrentProgrammes(DateTime at) =>
      programmes.where((p) => p.isNowPlaying(at));
  @override
  EpgProgram? getCurrentProgram(String id) => _byId[normalizeEpgId(id)];
  @override
  EpgProgram? getNextProgram(String id) => null;
  @override
  Future<List<EpgProgram>> findProgrammesByTitle(
          DateTime from, DateTime to, List<String> terms, {List<String>? channelIds}) async =>
      programmes;
  @override
  Future<List<EpgProgram>> findSportsProgrammesForChannels(
          List<String> ids, DateTime from, DateTime to) async =>
      programmes;
}

class _NoPicks implements SportsMatchPicks {
  @override
  String? channelIdFor(SportsGame game) => null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const playlistPath = String.fromEnvironment('PRIVATE_PLAYLIST_FILE');
  const guidePath = String.fromEnvironment('PRIVATE_GUIDE_FILE');
  const reportPath = String.fromEnvironment('PRIVATE_AUDIT_REPORT');
  test(
      'saved private playlist runs through the app parser and replay matcher offline',
      () async {
    await HttpOverrides.runZoned(() async {
      SharedPreferences.setMockInitialValues({});
      final storage = StorageService();
      await storage.init();
      final timer = Stopwatch()..start();
      final channels = M3uParser.parse(await File(playlistPath).readAsString(),
          playlistId: 'audit');
      final parseMs = timer.elapsedMilliseconds;
      final data = jsonDecode(await File(guidePath).readAsString()) as Map;
      final programmes = [
        for (final row in data['rows'] as List)
          EpgProgram(
            channelId: row['channelId'],
            title: row['title'][0]['text'],
            description: row['desc']?[0]['text'],
            start: DateTime.parse(row['start']),
            stop: DateTime.parse(row['stop']),
            isLive: row['live'] != null,
          )
      ];
      final guide = _Guide(storage, programmes);
      try {
        final service = SportsReplayService(guide);
        timer.reset();
        final snapshot = await service.load(channels,
            revision: 1, at: DateTime.parse(data['at']));
        final loadMs = timer.elapsedMilliseconds;
        timer.reset();
        final reused = await service.load(channels,
            revision: 1, at: DateTime.parse(data['at']));
        expect(identical(snapshot, reused), true);
        final summary = {
          'channels': channels.length,
          'guideSlots': programmes.length,
          'snapshotAt': data['at'],
          'playlistParseMs': parseMs,
          'replayLoadMs': loadMs,
          'cachedLoadUs': timer.elapsedMicroseconds,
          'replays': snapshot.events.length,
          'highlights': snapshot.highlights.length,
          'likelyReplays': snapshot.events
              .where((e) => e.evidence == ReplayEvidence.likely)
              .length,
        };
        const scoresPath = String.fromEnvironment('PRIVATE_SCORES_DIR');
        if (scoresPath.isNotEmpty) {
          final matcher = SportsChannelMatcher(guide,
              clock: () => DateTime.parse(data['at']));
          try {
            await matcher.prepare(channels);
            final discovery = await matcher.discoverGuideEvents();
            summary['guideEvents'] = [
              for (final g in discovery)
                {'title': g.title, 'league': g.league.id}
            ];
            final client = MockClient((r) async => http.Response(
                await File(
                        '$scoresPath/${r.url.path.contains('/mma/') ? 'mma-ufc' : 'soccer-eng.2'}.json')
                    .readAsString(),
                200,
                headers: {'content-type': 'application/json; charset=utf-8'}));
            try {
              final scores = SportsService.withClient(client);
              final games = [
                for (final id in ['mma.ufc', 'eng.2'])
                  ...await scores.replayGames(
                      sportsLeagueById(id)!, DateTime.parse(data['at']))
              ];
              timer.reset();
              final matches = await matcher.matchDay(games, _NoPicks(),
                  limit: 30, includePossible: true);
              summary['matchMs'] = timer.elapsedMilliseconds;
              summary['scoredGames'] = [
                for (final g in games)
                  {
                    'title': g.title,
                    'state': g.state.name,
                    'score': '${g.home.score} – ${g.away.score}',
                    'matches': [
                      for (final m in matches[SportsChannelPicks.eventKey(g)] ??
                          <ChannelMatch>[])
                        {
                          'channel': m.channel.name,
                          'confirmed': m.isConfident,
                          'reason': m.reason.name,
                          'programme': m.programme?.title
                        }
                    ]
                  }
              ];
            } finally {
              client.close();
            }
          } finally {
            matcher.dispose();
          }
        }
        // Only metadata enters the optional report; never URLs or credentials.
        if (reportPath.isNotEmpty) {
          await File(reportPath).writeAsString(jsonEncode({
            ...summary,
            'unclassified': [
              for (final p in programmes)
                if (RegExp(r'\b(sport|sports|replay|highlights|poker|golf|tennis|football|soccer|boxing|ufc|round|championship|baseball|basketball|rugby|classic)\b',
                            caseSensitive: false)
                        .hasMatch('${p.title} ${p.description ?? ''}') &&
                    classifySportsReplay(p, allowLikely: true) == null &&
                    classifySportsHighlights(p) == null &&
                    !isLiveSportsProgramme(p))
                  {
                    'channelId': p.channelId,
                    'title': p.title,
                    'description': p.description
                  },
            ],
            'events': [
              for (final e in snapshot.events)
                {
                  'title': e.title,
                  'reason': e.reason,
                  'evidence': e.evidence.name,
                  'channels': [for (final b in e.broadcasts) b.channel.name],
                  'guide': [
                    for (final b in e.broadcasts)
                      {
                        'title': b.programme.title,
                        'description': b.programme.description
                      }
                  ],
                }
            ],
            'highlightsList': [
              for (final e in snapshot.highlights)
                {
                  'title': e.title,
                  'channels': [for (final b in e.broadcasts) b.channel.name],
                }
            ],
          }));
        }
        // ignore: avoid_print
        print(jsonEncode({
          for (final e in summary.entries)
            if (e.value is! List) e.key: e.value
        }));
      } finally {
        guide.dispose();
      }
    },
        createHttpClient: (_) =>
            throw StateError('Network forbidden in private playlist audit'));
  },
      skip: playlistPath.isEmpty || guidePath.isEmpty
          ? 'Optional local private playlist/guide audit'
          : false);
}
