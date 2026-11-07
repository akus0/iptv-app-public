// Device-only guide diagnostics; never used by the published entry point.
// Build --release -t tools/tv_guide_import_profile.dart with
// --dart-define=IPTV_DISABLE_AUTOPLAY=true. Touch guide-profile-start in the
// app's external files directory to run. Uses an isolated in-memory database
// and loopback HTTP; never changes viewer preferences, guides or playlists.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:nox_iptv/models/epg_source_status.dart';
import 'package:nox_iptv/services/epg_database.dart';
import 'package:nox_iptv/services/epg_service.dart';
import 'package:nox_iptv/services/storage_service.dart';
import 'tv_profile.dart' as profile;

class _Storage extends StorageService {
  @override
  DateTime? getEpgLastUpdated() => null;
  @override
  Future<void> setEpgLastUpdated(DateTime time) async {}
  @override
  Future<void> deleteCacheFile(String name) async {}
}

Future<void> main() async {
  await profile.main();
  final directory = await getExternalStorageDirectory();
  if (directory == null) return;
  final trigger = File('${directory.path}/guide-profile-start');
  var running = false;
  Timer.periodic(const Duration(seconds: 1), (_) async {
    if (running || !await trigger.exists()) return;
    running = true;
    await trigger.delete();
    try {
      final result = await _run();
      await File('${directory.path}/guide-profile-result.json')
          .writeAsString(jsonEncode(result));
      // ignore: avoid_print
      print('IPTV_GUIDE_PROFILE ${jsonEncode(result)}');
    } catch (e) {
      // ignore: avoid_print
      print('IPTV_GUIDE_PROFILE_ERROR ${e.runtimeType}');
    } finally {
      running = false;
    }
  });
}

List<int> _fixture(DateTime now) {
  String stamp(DateTime d) =>
      '${d.toUtc().toIso8601String().replaceAll(RegExp(r'[-:T]'), '').substring(0, 14)} +0000';
  final out = StringBuffer('<tv>');
  for (var i = 0; i < 3000; i++) {
    out.write(
        '<channel id="feed-$i"><display-name>AU <![CDATA[Fixture]]> $i HD</display-name></channel>');
  }
  // Duplicate names must never publish a name assignment.
  for (final id in ['ambiguous-a', 'ambiguous-b']) {
    out.write(
        '<channel id="$id"><display-name>Ambiguous</display-name></channel>');
  }
  for (var i = 0; i < 3000; i++) {
    for (var slot = 0; slot < 10; slot++) {
      final start = now.add(Duration(minutes: slot * 30 - 15));
      out.write(
          '<programme channel="feed-$i" start="${stamp(start)}" stop="${stamp(start.add(const Duration(minutes: 30)))}"><title>Fixture $i slot $slot</title></programme>');
    }
  }
  out.write('</tv>');
  return utf8.encode(out.toString());
}

Future<Map<String, Object>> _run() async {
  final now = DateTime.now();
  final bytes = await Isolate.run(() => _fixture(now));
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  var fail = false, requests = 0;
  server.listen((request) async {
    requests++;
    if (fail) {
      request.response.statusCode = 503;
    } else {
      request.response.headers.contentType = ContentType('application', 'xml');
      for (var offset = 0; offset < bytes.length; offset += 32768) {
        request.response.add(
            bytes.sublist(offset, (offset + 32768).clamp(0, bytes.length)));
        await request.response.flush();
      }
    }
    await request.response.close();
  });
  final connection = await openDatabase(inMemoryDatabasePath,
      singleInstance: false, version: 1, onCreate: (db, _) async {
    await db.execute(
        'CREATE TABLE programme (channel_id TEXT NOT NULL, start INTEGER NOT NULL, stop INTEGER NOT NULL, title TEXT NOT NULL, descr TEXT, live INTEGER NOT NULL DEFAULT 0, source_url TEXT NOT NULL, gen INTEGER NOT NULL, PRIMARY KEY (channel_id, start)) WITHOUT ROWID');
    await db.execute('CREATE INDEX idx_programme_stop ON programme(stop)');
    await db.execute(
        'CREATE INDEX idx_programme_source ON programme(source_url, gen)');
  });
  final epg = EpgService(
      _Storage(), // Isolated synthetic database; never opens the installed guide.
      // ignore: invalid_use_of_visible_for_testing_member
      database: EpgDatabase.withConnection(connection));
  const prefix = 'iptv-custom-probe:';
  final url = 'http://127.0.0.1:${server.port}/guide.xml#iptv-app-custom-probe';
  final samples = <Map<String, Object>>[];
  var names = false;
  epg.startAutoRefresh(
      360,
      () => [
            EpgSource(
              url: url,
              knownChannelIds: names
                  ? {'${prefix}provider-only'}
                  : {for (var i = 0; i < 1000; i++) '${prefix}feed-$i'},
              knownChannelNames: names
                  ? {
                      for (var i = 0; i < 1000; i++) 'au fixture $i hd',
                      'ambiguous'
                    }
                  : const {},
            )
          ]);
  epg.stopAutoRefresh();
  try {
    await epg.init();
    for (var run = 0; run < 8; run++) {
      names = run.isOdd;
      final watch = Stopwatch()..start();
      await epg.refreshAll();
      watch.stop();
      final status = epg.sourceStatus(url)!;
      if (status.state != EpgSourceState.updated ||
          status.programmes != 10000 ||
          epg.getCurrentProgram('${prefix}feed-0') == null ||
          epg.customGuideChannelId(url, 'Ambiguous') != null ||
          (names &&
              epg.customGuideChannelId(url, 'AU Fixture 0 HD') !=
                  '${prefix}feed-0')) {
        throw StateError('Guide import assertions failed');
      }
      samples.add({
        'names': names,
        'ms': watch.elapsedMilliseconds,
        'stored': status.programmes!
      });
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    fail = true;
    await epg.refreshAll();
    final retained = epg.getCurrentProgram('${prefix}feed-0') != null &&
        epg.sourceStatus(url)?.httpStatus == 503;
    if (!retained) throw StateError('Failed refresh did not retain data');
    return {
      'samples': samples,
      'requests': requests,
      'retained_on_failure': retained,
      'input_programmes': 30000,
      'input_bytes': bytes.length
    };
  } finally {
    epg.dispose();
    await connection.close();
    await server.close(force: true);
  }
}
