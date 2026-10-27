import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:nox_iptv/models/sports.dart';
import 'package:nox_iptv/services/epg_database.dart';
import 'package:nox_iptv/services/epg_service.dart';
import 'package:nox_iptv/services/m3u_parser.dart';
import 'package:nox_iptv/services/sports_channel_matcher.dart';
import 'package:nox_iptv/services/sports_service.dart';
import 'package:nox_iptv/services/storage_service.dart';

// Optional local performance audit: saved metadata only, no stream/provider
// requests. The fixture database is a disposable copy, never the user's app DB.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const directory = String.fromEnvironment('PRIVATE_EPG_DB_DIR');
  const playlistPath = String.fromEnvironment('PRIVATE_PLAYLIST_FILE');
  const scoresDirectory = String.fromEnvironment('PRIVATE_SCORES_DIR');
  test('large saved guide uses paged search and real offline channel matching',
      () async {
    await HttpOverrides.runZoned(() async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      const method = MethodChannel('plugins.flutter.io/path_provider');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(method, (_) async => directory);
      addTearDown(() => messenger.setMockMethodCallHandler(method, null));
      final db = EpgDatabase();
      await db.open();
      final sql = await openDatabase('$directory/vesper_epg.db');
      final terms =
          (jsonDecode(await File('$directory/terms.json').readAsString())
                  as List)
              .cast<String>();
      final from = DateTime.utc(2026, 10, 22, 10).millisecondsSinceEpoch;
      final to = from + const Duration(hours: 24).inMilliseconds;
      final watch = Stopwatch()..start();
      final old = <String>{};
      for (var i = 0; i < terms.length; i += 400) {
        final part = terms.skip(i).take(400).toList();
        final rows = await sql.rawQuery(
            'SELECT channel_id, start, stop, title, substr(descr,1,320) AS descr, live FROM programme WHERE stop > ? AND start < ? AND (${List.filled(part.length, 'title LIKE ?').join(' OR ')})',
            [from, to, for (final term in part) '%$term%']);
        old.addAll(rows.map((r) => '${r['channel_id']}|${r['start']}'));
      }
      final before = watch.elapsedMilliseconds;
      var ticks = 0;
      final pulse =
          Timer.periodic(const Duration(milliseconds: 5), (_) => ticks++);
      watch.reset();
      final rows = await db.programmesStartingWithTitle(from, to, terms);
      final after = watch.elapsedMilliseconds;
      pulse.cancel();
      expect(rows.map((r) => '${r.channelId}|${r.startMs}').toSet(), old);
      debugPrint(
          'Saved guide: ${terms.length} terms, ${rows.length} hits; old query ${before}ms; paged query ${after}ms; input ticks $ticks');
      if (playlistPath.isEmpty || scoresDirectory.isEmpty) return;
      SharedPreferences.setMockInitialValues({});
      final storage = StorageService();
      await storage.init();
      final epg = EpgService(storage);
      addTearDown(epg.dispose);
      final channels = M3uParser.parse(await File(playlistPath).readAsString(),
          playlistId: 'offline');
      final parsed = [
        for (final tour in ['atp', 'wta'])
          ...parseEspnScoreboard((
            await File('$scoresDirectory/$tour.json').readAsString(),
            sportsLeagueById('tennis.$tour')!
          ))
      ];
      final games = parsed
          .where((g) =>
              g.start.toUtc().year == 2026 &&
              g.start.toUtc().month == 10 &&
              g.start.toUtc().day == 22)
          .toList();
      expect(games, isNotEmpty);
      debugPrint(
          'Selected-day fixtures: ${games.length} of ${parsed.length} tournament fixtures');
      const background = bool.fromEnvironment('BACKGROUND_MATCHING');
      final matcher = background
          ? SportsChannelMatcher.background(epg,
              clock: () => DateTime.utc(2026, 10, 22, 12, 30))
          : SportsChannelMatcher(epg,
              clock: () => DateTime.utc(2026, 10, 22, 12, 30));
      addTearDown(matcher.dispose);
      watch.reset();
      await matcher.prepare(channels);
      final indexMs = watch.elapsedMilliseconds;
      watch.reset();
      final picks = SportsChannelPicks.load(storage);
      final matches =
          await matcher.matchDay(games, picks, includePossible: true);
      final matchMs = watch.elapsedMilliseconds;
      watch.reset();
      final cached =
          await matcher.matchDay(games, picks, includePossible: true);
      expect({
        for (final e in cached.entries)
          e.key: [for (final m in e.value) (m.channel.id, m.score, m.reason)]
      }, {
        for (final e in matches.entries)
          e.key: [for (final m in e.value) (m.channel.id, m.score, m.reason)]
      });
      debugPrint(
          'Real offline match: ${channels.length} channels, ${games.length} tennis fixtures; index ${indexMs}ms; match ${matchMs}ms; cached ${watch.elapsedMicroseconds}us');
    },
        createHttpClient: (_) =>
            throw StateError('Offline audit: network forbidden'));
  },
      timeout: const Timeout(Duration(minutes: 4)),
      skip: directory.isEmpty
          ? 'Requires a saved, disposable SQLite guide fixture.'
          : false);
}
