import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:nox_iptv/models/epg_program.dart';
import 'package:nox_iptv/services/epg_service.dart';
import 'package:nox_iptv/services/m3u_parser.dart';
import 'package:nox_iptv/services/sports_channel_matcher.dart';
import 'package:nox_iptv/services/storage_service.dart';

class _Guide extends EpgService {
  _Guide(super.storage, this.rows);
  final Map<String, EpgProgram> rows;
  @override
  EpgProgram? getCurrentProgram(String id) => rows[normalizeEpgId(id)];
  @override
  EpgProgram? getNextProgram(String id) => null;
  @override
  Future<List<EpgProgram>> findProgrammesByTitle(
          DateTime from, DateTime to, List<String> terms,
          {List<String>? channelIds}) =>
      throw StateError('Unexpected SQL');
  @override
  Future<List<EpgProgram>> findSportsProgrammesForChannels(
          List<String> ids, DateTime from, DateTime to) =>
      throw StateError('Unexpected SQL');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
      'saved local guide discovers extra sports without any network connection',
      () async {
    await HttpOverrides.runZoned(() async {
      SharedPreferences.setMockInitialValues({});
      final storage = StorageService();
      await storage.init();
      final channels = M3uParser.parse(
          await File(const String.fromEnvironment(
                  'PRIVATE_DISCOVERY_PLAYLIST_FILE'))
              .readAsString(),
          playlistId: 'offline');
      final snapshots = jsonDecode(await File(
              const String.fromEnvironment('PRIVATE_DISCOVERY_GUIDE_FILE'))
          .readAsString()) as List;
      final reports = <Object>[];
      for (final snapshot in snapshots) {
        final now = DateTime.parse(snapshot['at']);
        final rows = <String, EpgProgram>{
          for (final r in snapshot['rows'])
            normalizeEpgId(r[0]): EpgProgram(
                channelId: r[0],
                start: DateTime.fromMillisecondsSinceEpoch(r[1]),
                stop: DateTime.fromMillisecondsSinceEpoch(r[2]),
                title: r[3],
                description: r[4],
                isLive: r[5] == 1)
        };
        final guide = _Guide(storage, rows);
        final matcher =
            SportsChannelMatcher.background(guide, clock: () => now);
        try {
          await matcher.prepare(channels);
          await matcher.primeGuide();
          final clock = Stopwatch()..start();
          final games = await matcher.discoverGuideEvents();
          final discoveryMs = clock.elapsedMilliseconds;
          final matches =
              await matcher.matchDay(games, SportsChannelPicks.load(storage));
          expect(games, isNotEmpty);
          expect(
              matches.values.every((v) => v.isNotEmpty && v.first.isConfident),
              isTrue);
          final counts = <String, int>{};
          for (final g in games) {
            counts.update(g.league.id, (n) => n + 1, ifAbsent: () => 1);
          }
          reports.add({
            'at': snapshot['at'],
            'channels': channels.length,
            'guideRows': rows.length,
            'discoveryMs': discoveryMs,
            'sports': counts,
            'programmes': [
              for (final g in games)
                {
                  'title': g.title,
                  'status': g.statusText,
                  'sport': g.league.id,
                  'channels': matches[SportsChannelPicks.eventKey(g)]!.length
                }
            ]
          });
        } finally {
          matcher.dispose();
          guide.dispose();
        }
      }
      await File(const String.fromEnvironment('PRIVATE_DISCOVERY_REPORT'))
          .writeAsString(jsonEncode(reports));
      // ignore: avoid_print
      print(jsonEncode(reports));
    },
        createHttpClient: (_) =>
            throw StateError('No network permitted in saved-guide audit'));
  }, skip: !const bool.fromEnvironment('PRIVATE_GUIDE_DISCOVERY_AUDIT'));
}
