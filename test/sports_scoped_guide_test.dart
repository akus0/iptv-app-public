import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:nox_iptv/services/epg_database.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('catalogue-scoped guide lookup preserves every eligible result',
      () async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final directory = await Directory.systemTemp.createTemp('sports-guide-');
    const method = MethodChannel('plugins.flutter.io/path_provider');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(method, (_) async => directory.path);
    addTearDown(() async {
      final sql = await openDatabase('${directory.path}/vesper_epg.db');
      await sql.close();
      messenger.setMockMethodCallHandler(method, null);
      await directory.delete(recursive: true);
    });
    final db = EpgDatabase();
    final ids = [for (var c = 0; c < 140; c++) 'channel-$c'];
    final rows = <EpgRow>[
      for (var c = 0; c < 200; c++)
        for (var slot = 0; slot < (c == 0 ? 700 : 12); slot++)
          (
            channelId: 'channel-$c',
            startMs: slot * 1000,
            stopMs: slot * 1000 + 5000,
            title: slot.isEven ? 'Tennis [Live] Café' : 'News',
            description: 'Programme $slot',
            isLive: slot % 3 == 0
          ),
      (
        channelId: 'channel-0',
        startMs: -1000000000,
        stopMs: 200000,
        title: 'Tennis marathon',
        description: 'Long event',
        isLive: true
      ),
    ];
    for (var offset = 0; offset < rows.length; offset += 400) {
      await db.insertBatch(rows.skip(offset).take(400).toList(), 'fixture', 1);
    }
    final all = await db.programmesStartingWithTitle(
        5000, 800000, ['tennis', '[Live]', 'café']);
    final scoped = await db.programmesStartingWithTitle(
        5000, 800000, ['tennis', '[Live]', 'café'],
        channelIds: [...ids, ids.first, 'absent']);
    expect(scoped.toSet(),
        all.where((row) => ids.contains(row.channelId)).toSet());
    expect(scoped.length, scoped.toSet().length);
    expect(scoped.any((row) => row.startMs < -86400000), true);
    expect(
        await db.programmesStartingWithTitle(5000, 800000, ['tennis'],
            channelIds: []),
        isEmpty);
    expect(
        await db.programmesStartingWithTitle(5000, 800000, ['[absent]'],
            channelIds: ids),
        isEmpty);
  });
}
