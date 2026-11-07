// Device-only diagnostics: freezes channel/guide metadata for repeatable A/B
// matching. Never exports stream URLs, headers, account IDs or preferences.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:nox_iptv/models/channel.dart';
import 'package:nox_iptv/models/epg_program.dart';
import 'package:nox_iptv/models/sports.dart';
import 'package:nox_iptv/screens/tv_home_screen.dart';
import 'package:nox_iptv/services/epg_service.dart';
import 'package:nox_iptv/services/playlist_manager.dart';
import 'package:nox_iptv/services/sports_service.dart';
import 'package:nox_iptv/services/sports_channel_matcher.dart';
import 'package:nox_iptv/services/sports_match_inputs.dart';
import 'package:nox_iptv/utils/sports_title_matcher.dart';
import 'package:nox_iptv/utils/extended_sports.dart';
import 'tv_profile.dart' as profile;

void logAudit(Map<String, Object?> data) {
  // ignore: avoid_print
  print('IPTV_ALIAS_AUDIT ${jsonEncode(data)}');
}

Future<void> main() async {
  await profile.main();
  var tries = 0;
  Timer.periodic(const Duration(seconds: 1), (timer) {
    if (++tries > 120) {
      timer.cancel();
      return;
    }
    void visit(Element e) {
      if (e.widget is TvHomeScreen) {
        timer.cancel();
        unawaited(audit(e.read<PlaylistManager>(), e.read<EpgService>())
            .catchError((Object e) {
          logAudit({'error': e.runtimeType.toString()});
        }));
        return;
      }
      e.visitChildren(visit);
    }

    WidgetsBinding.instance.rootElement?.visitChildren(visit);
  });
}

Map<String, Object?> teamJson(SportsTeam t) => {
      'id': t.id,
      'name': t.name,
      'short': t.shortName,
      'abbreviation': t.abbreviation,
      'location': t.location,
      'aliases': t.matchingNames
    };
SportsTeam teamFrom(Map t) => SportsTeam(
    id: t['id'],
    name: t['name'],
    shortName: t['short'],
    abbreviation: t['abbreviation'],
    location: t['location'],
    matchingNames: List<String>.from(t['aliases'] ?? []));
Map<String, Object?> broadcastJson(SportsBroadcast b) => {
      'name': b.name,
      'source': b.source,
      'country': b.country,
      'medium': b.medium,
      'market': b.market,
      'language': b.language,
      'requiresGuide': b.requiresGuide,
      'tournamentOnly': b.tournamentOnly,
    };
SportsBroadcast broadcastFrom(Map b) => SportsBroadcast(b['name'],
    source: b['source'],
    country: b['country'],
    medium: b['medium'],
    market: b['market'],
    language: b['language'],
    requiresGuide: b['requiresGuide'],
    tournamentOnly: b['tournamentOnly']);
Map<String, Object?> gameJson(SportsGame g) => {
      'id': g.id,
      'league': g.league.id,
      'start': g.start.toUtc().toIso8601String(),
      'end': g.end?.toUtc().toIso8601String(),
      'state': g.state.name,
      'statusText': g.statusText,
      'source': g.source,
      'playActive': g.event?.playActive,
      'scoreboardBroadcasts': [
        for (final b in g.scoreboardBroadcasts) broadcastJson(b)
      ],
      'home': teamJson(g.home),
      'away': teamJson(g.away),
      'broadcasts': g.broadcasts,
      'title': g.event?.title,
      'venue': g.event?.venue,
      'court': g.event?.court,
      'session': g.event?.session,
      'matchingNames': g.event?.matchingNames
    };
SportsGame gameFrom(Map g) => SportsGame(
    id: g['id'],
    league: sportsLeagueById(g['league'])!,
    start: DateTime.parse(g['start']),
    end: g['end'] == null ? null : DateTime.parse(g['end']),
    state: GameState.values.byName(g['state']),
    statusText: g['statusText'] ?? '',
    source: g['source'] ?? 'ESPN',
    scoreboardBroadcasts: [
      for (final b in g['scoreboardBroadcasts'] ?? []) broadcastFrom(b)
    ],
    home: teamFrom(g['home']),
    away: teamFrom(g['away']),
    broadcasts: List<String>.from(g['broadcasts']),
    event: g['title'] == null
        ? null
        : SportsEventInfo(
            title: g['title'],
            playActive: g['playActive'] ?? true,
            venue: g['venue'],
            court: g['court'],
            session: g['session'],
            matchingNames: List<String>.from(g['matchingNames'] ?? [])));
Future<void> audit(PlaylistManager playlist, EpgService epg) async {
  await playlist.whenRestored;
  await playlist.ensureLiveChannelsLoaded();
  await epg.init();
  final directory = (await getExternalStorageDirectory())!;
  final snapshot = File('${directory.path}/sports-alias-snapshot.json');
  if (!await snapshot.exists()) {
    final leagues =
        sportsBrowseLeagues.where(supportsSportsScoreboard).toList();
    final games = <SportsGame>[];
    final coverage = <Map<String, Object?>>[];
    final day = DateTime.now();
    for (var offset = 0; offset < leagues.length; offset += 4) {
      await Future.wait(leagues.skip(offset).take(4).map((league) async {
        final watch = Stopwatch()..start();
        try {
          final found = await SportsService.instance.gamesForDayWhileActive(
              [league], day,
              shouldContinue: () => true);
          games.addAll(found);
          coverage.add({
            'league': league.id,
            'events': found.length,
            'ms': watch.elapsedMilliseconds,
            'status': found.isEmpty ? 'no-events-returned' : 'events'
          });
        } catch (e) {
          coverage
              .add({'league': league.id, 'status': e.runtimeType.toString()});
        }
      }));
      logAudit({
        'stage': 'feeds',
        'checked': coverage.length,
        'total': leagues.length,
        'events': games.length
      });
    }
    final now = DateTime.now();
    final source = playlist.visibleLiveChannels;
    final ids = <String, String>{};
    String guideId(String id) =>
        ids.putIfAbsent(normalizeEpgId(id), () => 'g${ids.length}');
    final channels = <Map<String, Object?>>[];
    final rows = <String, List<Object?>>{};
    void add(EpgProgram? p) {
      if (p == null) return;
      final id = guideId(p.channelId);
      rows['$id:${p.start.millisecondsSinceEpoch}'] = [
        id,
        p.title,
        p.description,
        p.start.millisecondsSinceEpoch,
        p.stop.millisecondsSinceEpoch,
        p.isLive
      ];
    }

    for (var i = 0; i < source.length; i++) {
      final c = source[i];
      channels.add({
        'id': '$i',
        'name': c.name,
        'group': c.group,
        'epg': guideId(c.epgId)
      });
      add(epg.getCurrentProgram(c.epgId));
      add(epg.getNextProgram(c.epgId));
      if (i % 512 == 0) await Future<void>.delayed(Duration.zero);
    }
    final body = {
      'at': now.toUtc().toIso8601String(),
      'guideUpdated': epg.lastUpdated?.toUtc().toIso8601String(),
      'guideRevision': epg.changeRevision,
      'channels': channels,
      'rows': rows.values.toList(),
      'games': games.map(gameJson).toList(),
      'coverage': coverage
    };
    final encoded = await Isolate.run(() => jsonEncode(body));
    await snapshot.writeAsString(encoded);
    logAudit({
      'stage': 'snapshot',
      'channels': channels.length,
      'programmes': rows.length,
      'events': games.length
    });
  }
  final raw = await snapshot.readAsString();
  const label =
      String.fromEnvironment('IPTV_ALIAS_LABEL', defaultValue: 'updated');
  for (var run = 0; run < 3; run++) {
    final before = ProcessInfo.currentRss;
    final result = await Isolate.run(() => measure(raw));
    result['rssBefore'] = before;
    result['rssAfter'] = ProcessInfo.currentRss;
    await File('${directory.path}/sports-alias-$label-$run.json')
        .writeAsString(jsonEncode(result));
    logAudit({
      'stage': 'complete',
      'label': label,
      'run': run,
      ...Map.of(result)
        ..remove('matches')
        ..remove('guideEvents')
        ..remove('guideClassifications')
    });
    await Future<void>.delayed(const Duration(seconds: 2));
  }
}

class _Picks implements SportsMatchPicks {
  @override
  String? channelIdFor(SportsGame g) => null;
}

class _Guide implements SportsMatchGuide {
  _Guide(this.rows, this.now);
  final List<EpgProgram> rows;
  final DateTime now;
  int queries = 0;
  late final current = {
    for (final p in rows)
      if (p.isNowPlaying(now)) p.channelId: p
  };
  late final next = {
    for (final p in rows.reversed)
      if (p.start.isAfter(now)) p.channelId: p
  };
  @override
  int get changeRevision => 1;
  @override
  DateTime? get lastUpdated => now;
  @override
  EpgProgram? getCurrentProgram(String id) => current[id];
  @override
  EpgProgram? getNextProgram(String id) => next[id];
  @override
  Future<List<EpgProgram>> findProgrammesByTitle(
      DateTime from, DateTime to, List<String> terms) async {
    queries++;
    final matcher = SportsTitleMatcher(terms, precomputeTransitions: true);
    return rows
        .where((p) =>
            p.stop.isAfter(from) &&
            p.start.isBefore(to) &&
            matcher.matches(p.title))
        .toList();
  }

  @override
  Future<List<EpgProgram>> findSportsProgrammesForChannels(
      List<String> ids, DateTime from, DateTime to) async {
    final wanted = ids.toSet();
    return rows
        .where((p) =>
            wanted.contains(p.channelId) &&
            p.stop.isAfter(from) &&
            p.start.isBefore(to))
        .toList();
  }
}

Future<Map<String, Object?>> measure(String raw) async {
  final data = jsonDecode(raw) as Map;
  final now = DateTime.parse(data['at']);
  final channels = [
    for (final c in data['channels'])
      Channel(
          id: c['id'],
          rawId: c['id'],
          playlistId: 'audit',
          name: c['name'],
          group: c['group'],
          epgIdOverride: c['epg'],
          url: 'https://example.invalid/stream')
  ];
  final rows = [
    for (final p in data['rows'])
      EpgProgram(
          channelId: p[0],
          title: p[1],
          description: p[2],
          start: DateTime.fromMillisecondsSinceEpoch(p[3]),
          stop: DateTime.fromMillisecondsSinceEpoch(p[4]),
          isLive: p[5])
  ];
  final games = [for (final g in data['games']) gameFrom(g)];
  final guide = _Guide(rows, now), picks = _Picks();
  final matcher = SportsChannelMatcher(guide, clock: () => now);
  try {
    final timer = Stopwatch()..start();
    await matcher.prepare(channels);
    final index = timer.elapsedMicroseconds;
    timer.reset();
    final result = await matcher.matchDay(games, picks, includePossible: true);
    final cold = timer.elapsedMicroseconds;
    timer.reset();
    await matcher.matchDay(games, picks, includePossible: true);
    final cached = timer.elapsedMicroseconds;
    final discovery = <String, Object?>{};
    if (const bool.fromEnvironment('IPTV_AUDIT_GUIDE_DISCOVERY')) {
      timer.reset();
      final discovered = await matcher.discoverGuideEvents();
      discovery['discoveryUs'] = timer.elapsedMicroseconds;
      timer.reset();
      final repeated = await matcher.discoverGuideEvents();
      discovery['discoveryCachedUs'] = timer.elapsedMicroseconds;
      discovery['discoveryReused'] = identical(discovered, repeated);
      discovery['discoveredEvents'] = discovered.length;
      final queriesBefore = guide.queries;
      final bindings = await matcher.matchDay(discovered, picks);
      discovery['guideBindingQueries'] = guide.queries - queriesBefore;
      discovery['boundGuideEvents'] = bindings.values
          .where((matches) => matches.any((m) => m.reason == MatchReason.guide))
          .length;
      discovery['guideEvents'] = [
        for (final g in discovered)
          {
            'id': g.id,
            'title': g.title,
            'league': g.league.id,
            'status': g.statusText,
            'programmes': [
              for (final p in g.guideProgrammes)
                [p.channelId, p.start.millisecondsSinceEpoch, p.title]
            ],
          }
      ];
      discovery['guideClassifications'] = [
        for (final p in rows)
          [
            p.channelId,
            p.start.millisecondsSinceEpoch,
            extendedGuideSport(p.title, p.description ?? '',
                includeSessionCoverage: true)
          ]
      ];
    }
    return {
      ...discovery,
      'channels': channels.length,
      'programmes': rows.length,
      'events': games.length,
      'indexUs': index,
      'matchUs': cold,
      'cachedUs': cached,
      'queries': guide.queries,
      'exactEvents': result.values
          .where((ms) => ms.any((m) =>
              m.reason == MatchReason.guide || m.reason == MatchReason.name))
          .length,
      'matches': {
        for (final e in result.entries)
          e.key: [
            for (final m in e.value)
              {
                'channel': m.channel.id,
                'reason': m.reason.name,
                'score': m.score,
                'programme': m.programme?.title
              }
          ]
      }
    };
  } finally {
    matcher.dispose();
  }
}
