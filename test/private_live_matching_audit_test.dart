import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:nox_iptv/models/epg_program.dart';
import 'package:nox_iptv/models/sports.dart';
import 'package:nox_iptv/services/epg_database.dart';
import 'package:nox_iptv/services/epg_service.dart';
import 'package:nox_iptv/services/m3u_parser.dart';
import 'package:nox_iptv/services/sports_channel_matcher.dart';
import 'package:nox_iptv/services/sports_service.dart';
import 'package:nox_iptv/services/storage_service.dart';

// Explicit opt-in, disposable saved metadata only. Never contacts a provider,
// opens a stream, or writes channel URLs to the audit report.
class _SnapshotGuide extends EpgService {
  _SnapshotGuide(super.storage, this.current);
  final Map<String, EpgProgram> current;
  @override
  EpgProgram? getCurrentProgram(String id) => current[normalizeEpgId(id)];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const dir = String.fromEnvironment('PRIVATE_LIVE_AUDIT_DIR');
  const label = String.fromEnvironment('AUDIT_LABEL', defaultValue: 'current');
  test('saved live fixtures run through the production matcher offline',
      () async {
    await HttpOverrides.runZoned(() async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      const method = MethodChannel('plugins.flutter.io/path_provider');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(method, (_) async => dir);
      addTearDown(() => messenger.setMockMethodCallHandler(method, null));
      final snapshot =
          jsonDecode(await File('$dir/snapshot.json').readAsString()) as Map;
      final now = DateTime.parse(snapshot['at'] as String);
      final db = EpgDatabase();
      final currentRows = await db.programmesBetween(
          now.millisecondsSinceEpoch, now.millisecondsSinceEpoch + 1);
      final current = <String, EpgProgram>{
        for (final rows in currentRows.values)
          for (final r in rows)
            r.channelId: EpgProgram(
                channelId: r.channelId,
                title: r.title,
                description: r.description,
                start: DateTime.fromMillisecondsSinceEpoch(r.startMs),
                stop: DateTime.fromMillisecondsSinceEpoch(r.stopMs),
                isLive: r.isLive)
      };
      SharedPreferences.setMockInitialValues({});
      final storage = StorageService();
      await storage.init();
      final epg = _SnapshotGuide(storage, current);
      addTearDown(epg.dispose);
      final games = <SportsGame>[
        for (final id in (snapshot['leagues'] as List).cast<String>())
          if (await File('$dir/$id.json').exists())
            ...parseEspnScoreboard((
              await File('$dir/$id.json').readAsString(),
              sportsLeagueById(id)!
            ))
      ].where((g) => g.state == GameState.live).toList();
      final reports = <Object>[];
      for (final playlist in ['playlist.m3u', 'cached-playlist.m3u']) {
        final file = File('$dir/$playlist');
        if (!await file.exists()) continue;
        final channels =
            M3uParser.parse(await file.readAsString(), playlistId: 'offline');
        final matcher = SportsChannelMatcher.background(epg, clock: () => now);
        final watch = Stopwatch()..start();
        await matcher.prepare(channels);
        final indexMs = watch.elapsedMilliseconds;
        watch.reset();
        final matches = await matcher.matchDay(
            games, SportsChannelPicks.load(storage),
            includePossible: true);
        final matchMs = watch.elapsedMilliseconds;
        watch.reset();
        final cached = await matcher.matchDay(
            games, SportsChannelPicks.load(storage),
            includePossible: true);
        final cachedUs = watch.elapsedMicroseconds;
        expect({
          for (final e in cached.entries)
            e.key: [for (final m in e.value) (m.channel.id, m.reason, m.score)]
        }, {
          for (final e in matches.entries)
            e.key: [for (final m in e.value) (m.channel.id, m.reason, m.score)]
        });
        const expectedConfirmed =
            int.fromEnvironment('AUDIT_EXPECTED_CONFIRMED', defaultValue: -1);
        if (expectedConfirmed >= 0) {
          expect(
              matches.values.where((m) => m.any((v) => v.isConfident)).length,
              expectedConfirmed);
        }
        final result = [
          for (final g in games)
            {
              'id': SportsChannelPicks.eventKey(g),
              'event': '${g.away.name} at ${g.home.name}',
              'matches': [
                for (final m in matches[SportsChannelPicks.eventKey(g)] ??
                    <ChannelMatch>[])
                  {
                    'channel': m.channel.name,
                    'epgId': m.channel.epgId,
                    'reason': m.reason.name,
                    'score': m.score,
                    'programme': m.programme?.title,
                    'description': m.programme?.description,
                  }
              ]
            }
        ];
        reports.add({
          'playlist': playlist,
          'channels': channels.length,
          'indexMs': indexMs,
          'matchMs': matchMs,
          'cachedUs': cachedUs,
          'events': result
        });
        // ignore: avoid_print
        print(
            '$playlist: ${games.length} live fixtures; ${channels.length} channels; index ${indexMs}ms, match ${matchMs}ms; confident ${matches.values.where((m) => m.any((v) => v.isConfident)).length}');
        matcher.dispose();
      }
      await File('$dir/report-$label.json')
          .writeAsString(const JsonEncoder.withIndent('  ').convert(reports));
      expect(games, isNotEmpty);
    },
        createHttpClient: (_) =>
            throw StateError('Offline audit: network forbidden'));
  },
      timeout: const Timeout(Duration(minutes: 4)),
      skip: dir.isEmpty ? 'Requires private saved metadata' : false);
}
