import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:nox_iptv/models/epg_program.dart';
import 'package:nox_iptv/services/epg_service.dart';
import 'package:nox_iptv/services/m3u_parser.dart';
import 'package:nox_iptv/services/motorsport_schedule_service.dart';
import 'package:nox_iptv/services/sports_channel_matcher.dart';
import 'package:nox_iptv/services/storage_service.dart';

class _Guide extends EpgService {
  _Guide(super.storage, this.rows, this.now);
  final List<EpgProgram> rows;
  final DateTime now;
  @override
  EpgProgram? getCurrentProgram(String id) => rows
      .where((p) =>
          normalizeEpgId(p.channelId) == normalizeEpgId(id) &&
          p.isNowPlaying(now))
      .firstOrNull;
  @override
  Future<List<EpgProgram>> findProgrammesByTitle(
          DateTime from, DateTime to, List<String> terms,
          {List<String>? channelIds}) async =>
      rows.where((p) => p.stop.isAfter(from) && p.start.isBefore(to)).toList();
  @override
  Future<List<EpgProgram>> findSportsProgrammesForChannels(
          List<String> ids, DateTime from, DateTime to) async =>
      rows.where((p) => p.stop.isAfter(from) && p.start.isBefore(to)).toList();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const enabled = bool.fromEnvironment('PRIVATE_MOTORSPORT_AUDIT');
  test(
      'saved playlist and guide resolve Gold Coast practice and qualifying offline',
      () async {
    await HttpOverrides.runZoned(() async {
      SharedPreferences.setMockInitialValues({});
      final storage = StorageService();
      await storage.init();
      final channels = M3uParser.parse(
          await File(const String.fromEnvironment(
                  'PRIVATE_MOTORSPORT_PLAYLIST_FILE'))
              .readAsString(),
          playlistId: 'offline');
      final raw = jsonDecode(await File(
              const String.fromEnvironment('PRIVATE_MOTORSPORT_GUIDE_FILE'))
          .readAsString()) as List;
      final rows = [
        for (final r in raw)
          EpgProgram(
              channelId: r[0],
              start: DateTime.fromMillisecondsSinceEpoch(r[1]),
              stop: DateTime.fromMillisecondsSinceEpoch(r[2]),
              title: r[3],
              description: r[4],
              isLive: r[5] == 1)
      ];
      final reports = <Object>[];
      for (final now in [
        DateTime.utc(2026, 10, 23, 4),
        DateTime.utc(2026, 10, 23, 6, 15)
      ]) {
        final service = MotorsportScheduleService(
            MockClient((_) async => http.Response.bytes(
                await File(const String.fromEnvironment(
                        'PRIVATE_MOTORSPORT_CALENDAR_FILE'))
                    .readAsBytes(),
                200)),
            clock: () => now);
        await service.warm(cancelled: () => false);
        final game = service.gamesForDay(now.toLocal()).firstWhere((g) =>
            g.league.id == 'racing.supercars' &&
            g.statusText == 'Scheduled now');
        final epg = _Guide(storage, rows, now);
        final matcher = SportsChannelMatcher.background(epg, clock: () => now);
        try {
          await matcher.prepare(channels);
          final watch = Stopwatch()..start();
          final result = (await matcher
                  .matchDay([game], SportsChannelPicks.load(storage)))[
              SportsChannelPicks.eventKey(game)]!;
          expect(result.where((m) => m.isConfident), isNotEmpty);
          reports.add({
            'session': game.event!.session,
            'channels': channels.length,
            'matchingMs': watch.elapsedMilliseconds,
            'confirmed': result.where((m) => m.isConfident).length,
            'top': result
                .take(5)
                .map((m) => {
                      'name': m.channel.name,
                      'reason': m.reason.name,
                      'programme': m.programme?.title
                    })
                .toList()
          });
        } finally {
          matcher.dispose();
          epg.dispose();
        }
      }
      await File(const String.fromEnvironment('PRIVATE_MOTORSPORT_REPORT'))
          .writeAsString(jsonEncode(reports));
      // ignore: avoid_print
      print(jsonEncode(reports));
    },
        createHttpClient: (_) =>
            throw StateError('Offline audit: network disabled'));
  }, skip: !enabled);
}
