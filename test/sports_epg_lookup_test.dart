import 'dart:io';
import 'dart:async';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:nox_iptv/services/epg_service.dart';
import 'package:nox_iptv/services/storage_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:nox_iptv/services/epg_database.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('v1 guide migration preserves rows and XMLTV live survives cache reload',
      () async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final dir =
        await Directory.systemTemp.createTemp('replay-guide-migration-');
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (_) async => dir.path);
    final path = '${dir.path}/vesper_epg.db';
    final now = DateTime.now().toUtc();
    final start = now.subtract(const Duration(hours: 1));
    final stop = now.add(const Duration(hours: 1));
    final old = await openDatabase(path, version: 1, onCreate: (db, _) async {
      await db.execute(
          'CREATE TABLE programme (channel_id TEXT NOT NULL, start INTEGER NOT NULL, '
          'stop INTEGER NOT NULL, title TEXT NOT NULL, descr TEXT, source_url TEXT NOT NULL, '
          'gen INTEGER NOT NULL, PRIMARY KEY(channel_id,start)) WITHOUT ROWID');
    });
    await old.insert('programme', {
      'channel_id': 'old',
      'start': start.millisecondsSinceEpoch,
      'stop': stop.millisecondsSinceEpoch,
      'title': 'NBA: Boston at New York',
      'source_url': 'old-fixture',
      'gen': 1
    });
    await old.close();
    final db = EpgDatabase();
    final kept = await db.programmesBetween(
        start.millisecondsSinceEpoch, stop.millisecondsSinceEpoch);
    expect(kept['old']!.single.title, 'NBA: Boston at New York');
    expect(kept['old']!.single.isLive, isFalse);
    SharedPreferences.setMockInitialValues({});
    final storage = StorageService();
    await storage.init();
    final guide = EpgService(storage);
    addTearDown(() async {
      guide.dispose();
      messenger.setMockMethodCallHandler(channel, null);
      await databaseFactory.deleteDatabase(path);
      await dir.delete(recursive: true);
    });
    String stamp(DateTime value) =>
        '${value.toIso8601String().replaceAll(RegExp(r'[-:T]'), '').substring(0, 14)} +0000';
    final xml =
        '<tv><programme channel="LIVE" start="${stamp(start)}" stop="${stamp(stop)}">'
        '<title>College Football: Ohio State at Indiana</title><live/></programme>'
        '<programme channel="repeat" start="${stamp(start)}" stop="${stamp(stop)}">'
        '<title>NBA: Boston at New York (Replay)</title></programme></tv>';
    var requests = 0;
    await http.runWithClient(
        () => guide.refresh('https://example.invalid/guide',
            knownChannelIds: {'live', 'repeat'}),
        () => MockClient((_) async {
              requests++;
              return http.Response(xml, 200);
            }));
    expect(requests, 1);
    expect(guide.error, isNull);
    expect(guide.getCurrentProgram('live')!.isLive, isTrue);
    expect(guide.getCurrentProgram('repeat')!.isLive, isFalse);
    expect(guide.getCurrentProgram('old'), isNotNull);
    final stored =
        await db.programmesFor(['live'], start.millisecondsSinceEpoch);
    expect(stored['live']!.single.isLive, isTrue);
  });
  test(
      'sports SQL includes overlapping sessions and excludes ended/future slots',
      () async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final dir = await Directory.systemTemp.createTemp('sports-epg-test-');
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (_) async => dir.path);
    addTearDown(() async {
      messenger.setMockMethodCallHandler(channel, null);
      await databaseFactory.deleteDatabase('${dir.path}/vesper_epg.db');
      await dir.delete(recursive: true);
    });
    final db = EpgDatabase();
    final start = DateTime.utc(2026, 10, 10, 12).millisecondsSinceEpoch;
    const hour = 60 * 60 * 1000;
    await db.insertBatch([
      for (final slot in [
        ('overlap', -4, 6),
        ('ended', -4, -2),
        ('later', 6, 9),
        ('during', 0, 2),
      ])
        (
          channelId: slot.$1,
          startMs: start + slot.$2 * hour,
          stopMs: start + slot.$3 * hour,
          title: 'ATP Shanghai Tennis',
          isLive: false,
          description: 'Coverage notes ${'x' * 400}'
        ),
    ], 'offline-fixture', 1);
    final rows = await db.programmesStartingWithTitle(
        start - hour, start + 4 * hour, ['tennis']);
    expect(
        rows.map((r) => r.channelId), unorderedEquals(['overlap', 'during']));
    expect(
        rows.every((r) => r.description!.startsWith('Coverage notes')), true);
    expect(rows.every((r) => r.description!.length == 320), true);
    final narrow = await db.programmesForSportsChannels(
        ['during', 'later', 'ended'], start, start + hour);
    expect(narrow.map((r) => r.channelId), ['during']);
    expect(narrow.single.description!.length, greaterThan(320));
  });
  test('paged title search keeps tied timestamps, literal terms and yields',
      () async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final dir = await Directory.systemTemp.createTemp('sports-paged-guide-');
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (_) async => dir.path);
    addTearDown(() async {
      messenger.setMockMethodCallHandler(channel, null);
      await databaseFactory.deleteDatabase('${dir.path}/vesper_epg.db');
      await dir.delete(recursive: true);
    });
    final db = EpgDatabase();
    await db.insertBatch([
      for (var i = 0; i < 2100; i++)
        (
          channelId: 'channel-$i',
          startMs: 1000,
          stopMs: 5000,
          title: i.isEven
              ? 'TENNIS: 100% court_1 (live)'
              : 'Tennis: 1000 court21 live',
          description: 'Details',
          isLive: true,
        )
    ], 'fixture', 1);
    var ticks = 0;
    final heartbeat =
        Timer.periodic(const Duration(milliseconds: 1), (_) => ticks++);
    final rows =
        await db.programmesStartingWithTitle(2000, 3000, ['100%', 'court_1']);
    heartbeat.cancel();
    expect(rows, hasLength(1050));
    expect(rows.map((r) => r.channelId).toSet(), hasLength(1050));
    expect(rows.every((r) => r.isLive), true);
    expect(ticks, greaterThan(1));
    final all =
        await db.programmesStartingWithTitle(2000, 3000, ['tennis', 'TENNIS']);
    expect(all, hasLength(2100));
    expect(
        await db.programmesStartingWithTitle(5000, 6000, ['tennis']), isEmpty);
  });

  test(
      'replay snapshot reads current cached slots and respects newer full rows',
      () async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final dir = await Directory.systemTemp.createTemp('sports-replay-guide-');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    messenger.setMockMethodCallHandler(channel, (_) async => dir.path);
    SharedPreferences.setMockInitialValues({});
    final storage = StorageService();
    await storage.init();
    final guide = EpgService(storage);
    addTearDown(() async {
      guide.dispose();
      messenger.setMockMethodCallHandler(channel, null);
      await databaseFactory.deleteDatabase('${dir.path}/vesper_epg.db');
      await dir.delete(recursive: true);
    });
    final db = EpgDatabase();
    final now = DateTime.now();
    final start = now.millisecondsSinceEpoch;
    const hour = 3600000;
    await db.insertBatch([
      for (final slot in [('sport', -1, 1), ('ended', -2, -1), ('later', 1, 2)])
        (
          channelId: slot.$1,
          startMs: start + slot.$2 * hour,
          stopMs: start + slot.$3 * hour,
          title: 'Tennis: Alcaraz v Sinner (Replay)',
          isLive: false,
          description: 'Full replay.'
        ),
    ], 'offline', 1);
    await guide.init();
    expect(
        guide.cachedCurrentProgrammes(now).map((p) => p.channelId), ['sport']);
    await db.insertBatch([
      (
        channelId: 'sport',
        startMs: start - hour,
        stopMs: start + hour,
        title: 'NCAA Volleyball: Texas v Stanford (Replay)',
        isLive: false,
        description: 'Corrected guide.'
      ),
    ], 'offline', 2);
    final loaded = Completer<void>();
    void listener() {
      if (!loaded.isCompleted) loaded.complete();
    }

    guide.guideRowsLoaded.addListener(listener);
    guide.getPrograms('sport');
    await loaded.future.timeout(const Duration(seconds: 5));
    guide.guideRowsLoaded.removeListener(listener);
    final snapshot = guide.cachedCurrentProgrammes(now).toList();
    expect(snapshot, hasLength(1));
    expect(snapshot.single.title, contains('Volleyball'));
    expect(snapshot.single, same(guide.getCurrentProgram('sport')));
  });
  test(
      'paged guide reads retain every overlapping row across page/channel boundaries',
      () async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final dir = await Directory.systemTemp.createTemp('iptv-paged-guide-');
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (_) async => dir.path);
    addTearDown(() async {
      messenger.setMockMethodCallHandler(channel, null);
      await databaseFactory.deleteDatabase('${dir.path}/vesper_epg.db');
      await dir.delete(recursive: true);
    });
    final db = EpgDatabase();
    final from = DateTime.utc(2026, 10, 24).millisecondsSinceEpoch;
    final rows = <EpgRow>[
      for (var i = 0; i < 1600; i++)
        (
          channelId: 'channel${i % 17}',
          startMs: from + i * 1000,
          stopMs: from + i * 1000 + 1000,
          title: 'Programme $i',
          description: 'Details $i',
          isLive: i.isEven
        ),
    ];
    await db.insertBatch(rows.reversed.toList(), 'fixture', 1);
    final got = await db.programmesBetween(from + 750, from + 1599500);
    expect(got.values.expand((v) => v).toSet(), rows.toSet());
    for (final timeline in got.values) {
      expect(timeline.map((r) => r.startMs),
          orderedEquals([...timeline.map((r) => r.startMs)]..sort()));
    }
    final exact = await db.programmesBetween(from + 1000, from + 2000);
    expect(exact.values.expand((v) => v).single.title, 'Programme 1');
  });
}
