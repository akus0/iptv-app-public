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
  _Guide(super.storage, this.current);
  final Map<String, EpgProgram> current;
  @override
  EpgProgram? getCurrentProgram(String id) => current[normalizeEpgId(id)];
  @override
  EpgProgram? getNextProgram(String id) => null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const playlistPath = String.fromEnvironment('PRIVATE_PLAYLIST_FILE');
  const guidePath = String.fromEnvironment('PRIVATE_GUIDE_FILE');
  const reportPath = String.fromEnvironment('PRIVATE_AUDIT_REPORT');
  const at = String.fromEnvironment('AUDIT_AT');
  test('saved guide discovery audit, with network forbidden', () async {
    await HttpOverrides.runZoned(() async {
      SharedPreferences.setMockInitialValues({});
      final storage = StorageService();
      await storage.init();
      final channels = M3uParser.parse(await File(playlistPath).readAsString(),
          playlistId: 'audit');
      final data = jsonDecode(await File(guidePath).readAsString());
      final reports = <Map<String, Object?>>[];
      for (final snapshot in data is List ? data : [data]) {
        final now = DateTime.parse(at.isEmpty ? snapshot['at'] : at);
        final current = <String, EpgProgram>{};
        for (final row in snapshot['rows']) {
          final p = EpgProgram(
              channelId: row[0],
              start: DateTime.fromMillisecondsSinceEpoch(row[1], isUtc: true),
              stop: DateTime.fromMillisecondsSinceEpoch(row[2], isUtc: true),
              title: row[3],
              description: row[4],
              isLive: row[5] == 1);
          if (!p.isNowPlaying(now)) continue;
          final id = normalizeEpgId(p.channelId),
              old = current[normalizeEpgId(p.channelId)];
          if (old == null || p.start.isAfter(old.start)) current[id] = p;
        }
        final guide = _Guide(storage, current);
        final matcher = SportsChannelMatcher(guide, clock: () => now);
        try {
          await matcher.prepare(channels);
          final watch = Stopwatch()..start();
          final games = await matcher.discoverGuideEvents();
          reports.add({
            'at': now.toIso8601String(),
            'channels': channels.length,
            'currentGuideIds': current.length,
            'discoveryMs': watch.elapsedMilliseconds,
            'sports': {
              for (final id in games.map((g) => g.league.id).toSet())
                id: games.where((g) => g.league.id == id).length
            },
            'programmes': [
              for (final g in games)
                {
                  'title': g.title,
                  'league': g.league.id,
                  'status': g.statusText,
                  'guideSlots': g.guideProgrammes.length
                }
            ]
          });
          expect(identical(games, await matcher.discoverGuideEvents()), true);
        } finally {
          matcher.dispose();
          guide.dispose();
        }
      }
      if (reportPath.isNotEmpty) {
        await File(reportPath).writeAsString(jsonEncode(reports));
      }
      // No addresses or credentials in reports or logs.
      // ignore: avoid_print
      print(jsonEncode(
          [for (final r in reports) Map.of(r)..remove('programmes')]));
    }, createHttpClient: (_) => throw StateError('Network forbidden'));
  },
      skip: playlistPath.isEmpty || guidePath.isEmpty
          ? 'Optional offline saved-playlist audit'
          : false);
}
