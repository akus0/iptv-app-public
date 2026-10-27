import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:nox_iptv/models/epg_program.dart';
import 'package:nox_iptv/services/epg_service.dart';
import 'package:nox_iptv/services/m3u_parser.dart';
import 'package:nox_iptv/services/motorsport_schedule_service.dart';
import 'package:nox_iptv/services/sports_channel_matcher.dart';
import 'package:nox_iptv/services/storage_service.dart';

class _Guide extends EpgService {
  _Guide(super.storage, this.rows);
  final Map<String, EpgProgram> rows;
  @override
  EpgProgram? getCurrentProgram(String id) => rows[normalizeEpgId(id)];
  @override
  EpgProgram? getNextProgram(String id) => null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
      'saved support coverage matches the actual guide channel, entirely offline',
      () async {
    await HttpOverrides.runZoned(() async {
      SharedPreferences.setMockInitialValues({});
      final storage = StorageService();
      await storage.init();
      final channels = M3uParser.parse(
          await File(const String.fromEnvironment(
                  'PRIVATE_COVERAGE_PLAYLIST_FILE'))
              .readAsString(),
          playlistId: 'offline');
      final raw = jsonDecode(await File(
              const String.fromEnvironment('PRIVATE_COVERAGE_GUIDE_FILE'))
          .readAsString()) as List;
      DateTime stamp(String s) =>
          DateTime.parse('${s.substring(0, 8)}T${s.substring(8, 14)}Z');
      final now = DateTime.utc(2026, 10, 25, 3, 10);
      final rows = <String, EpgProgram>{};
      for (final r in raw) {
        final p = EpgProgram(
            channelId: r['id'],
            start: stamp(r['start']),
            stop: stamp(r['stop']),
            title: r['title'],
            description: r['description'],
            isLive: r['live']);
        if (p.isNowPlaying(now)) rows[normalizeEpgId(p.channelId)] = p;
      }
      final guide = _Guide(storage, rows);
      final matcher = SportsChannelMatcher.background(guide, clock: () => now);
      try {
        await matcher.prepare(channels);
        final games = await matcher.discoverGuideEvents();
        final support =
            games.singleWhere((g) => g.title.contains('Gold Coast Supports'));
        final matches = (await matcher
                .matchDay([support], SportsChannelPicks.load(storage)))
            .values
            .single;
        expect(matches, isNotEmpty);
        expect(
            matches.every(
                (m) => m.isConfident && m.programme?.title == support.title),
            isTrue);
        final calendar = parseMotorsportCalendar(await File(
                const String.fromEnvironment('PRIVATE_COVERAGE_CALENDAR_FILE'))
            .readAsBytes());
        final report = {
          'calendar_sessions': calendar.length,
          'calendar_series_with_timed_sessions':
              calendar.map((s) => s.league.id).toSet().length,
          'channels': channels.length,
          'event': support.title,
          'status': support.statusText,
          'matches': matches.map((m) => m.channel.name).toList()
        };
        await File(const String.fromEnvironment('PRIVATE_COVERAGE_REPORT'))
            .writeAsString(jsonEncode(report));
        // ignore: avoid_print
        print(jsonEncode(report));
      } finally {
        matcher.dispose();
        guide.dispose();
      }
    },
        createHttpClient: (_) =>
            throw StateError('Offline audit must not open connections'));
  }, skip: !const bool.fromEnvironment('PRIVATE_MOTORSPORT_COVERAGE_AUDIT'));
}
