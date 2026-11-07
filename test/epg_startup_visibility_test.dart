import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:nox_iptv/services/epg_database.dart';
import 'package:nox_iptv/services/epg_service.dart';
import 'package:nox_iptv/services/storage_service.dart';

class StartupGuide extends EpgDatabase {
  Completer<void>? opening;
  Completer<Set<String>>? directory;
  final snapshot = Completer<Map<String, List<EpgRow>>>();
  final rows = Completer<Map<String, List<EpgRow>>>();
  final started = Completer<void>();
  int reads = 0;
  List<String> expectedIds = ['visible'];
  @override
  Future<void> open() async {
    await opening?.future;
  }

  @override
  Future<Set<String>> channelIdsWithData(int from) async =>
      directory == null ? {'visible', 'other'} : await directory!.future;
  @override
  Future<void> clearAll() async {}
  @override
  Future<Map<String, List<EpgRow>>> programmesBetween(int from, int to) =>
      snapshot.future;
  @override
  Future<Map<String, List<EpgRow>>> programmesFor(List<String> ids, int from) {
    reads++;
    if (!started.isCompleted) started.complete();
    expect(ids, expectedIds);
    return rows.future;
  }
}

class StartupStorage extends StorageService {
  @override
  Future<void> deleteCacheFile(String name) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
      'visible requests wait only for database open, not the channel directory',
      () async {
    SharedPreferences.setMockInitialValues({});
    final storage = StartupStorage();
    await storage.init();
    final db = StartupGuide()
      ..opening = Completer<void>()
      ..directory = Completer<Set<String>>()
      ..expectedIds = ['visible', 'absent'];
    final guide = EpgService(storage, database: db);
    addTearDown(guide.dispose);
    var ready = false;
    final init = guide.init().then((_) => ready = true);
    for (var i = 0; i < 10; i++) {
      expect(guide.getPrograms('visible'), isEmpty);
      expect(guide.getPrograms('absent'), isEmpty);
    }
    await Future<void>.delayed(Duration.zero);
    expect(db.reads, 0);
    db.opening!.complete();
    await db.started.future;
    expect(db.reads, 1);
    final loaded = Completer<void>();
    guide.guideRowsLoaded.addListener(() {
      if (!loaded.isCompleted) loaded.complete();
    });
    final now = DateTime.now().millisecondsSinceEpoch;
    db.rows.complete({
      'visible': [
        (
          channelId: 'visible',
          startMs: now - 1000,
          stopMs: now + 3600000,
          title: 'Visible before directory',
          description: 'Full cached details',
          isLive: true
        )
      ]
    });
    await loaded.future;
    expect(ready, isFalse);
    expect(
        guide.getPrograms('visible').single.title, 'Visible before directory');
    for (var i = 0; i < 10; i++) {
      expect(guide.getPrograms('absent'), isEmpty);
    }
    db.directory!.complete({'visible'});
    db.snapshot.complete({});
    await init;
    expect(
        guide.getPrograms('visible').single.description, 'Full cached details');
    expect(db.reads, 1,
        reason: 'Repeated and missing IDs share one bounded lookup');
  });

  test(
      'clear invalidates early rows still in flight before directory readiness',
      () async {
    SharedPreferences.setMockInitialValues({});
    final storage = StartupStorage();
    await storage.init();
    final db = StartupGuide()..directory = Completer<Set<String>>();
    final guide = EpgService(storage, database: db);
    addTearDown(guide.dispose);
    final init = guide.init();
    guide.getPrograms('visible');
    await db.started.future;
    expect(db.reads, 1);
    await guide.clearAll();
    final now = DateTime.now().millisecondsSinceEpoch;
    db.rows.complete({
      'visible': [
        (
          channelId: 'visible',
          startMs: now - 1000,
          stopMs: now + 3600000,
          title: 'Cleared listing',
          description: null,
          isLive: false
        )
      ]
    });
    db.directory!.complete({'visible'});
    db.snapshot.complete({});
    await init;
    await Future<void>.delayed(Duration.zero);
    expect(guide.getPrograms('visible'), isEmpty);
    expect(guide.hasPrograms('visible'), isFalse);
  });
  for (final clearDuringDirectory in [true, false]) {
    test(
        'clearing during startup cannot restore old guide data: '
        '$clearDuringDirectory', () async {
      SharedPreferences.setMockInitialValues({});
      final storage = StartupStorage();
      await storage.init();
      final db = StartupGuide();
      if (clearDuringDirectory) db.directory = Completer<Set<String>>();
      final guide = EpgService(storage, database: db);
      addTearDown(guide.dispose);
      final init = guide.init();
      await Future<void>.delayed(Duration.zero);
      await guide.clearAll();
      db.directory?.complete({'visible'});
      db.snapshot.complete({});
      await init;
      expect(guide.hasPrograms('visible'), isFalse);
      expect(guide.getPrograms('visible'), isEmpty);
      await Future<void>.delayed(Duration.zero);
      expect(db.reads, 0);
    });
  }
  for (final finishRowsFirst in [true, false]) {
    test(
        'visible guide reads finish around snapshot completion: $finishRowsFirst',
        () async {
      SharedPreferences.setMockInitialValues({});
      final storage = StartupStorage();
      await storage.init();
      final db = StartupGuide();
      final guide = EpgService(storage, database: db);
      addTearDown(guide.dispose);
      var ready = false;
      final init = guide.init().then((_) => ready = true);
      await Future<void>.delayed(Duration.zero);
      expect(ready, isFalse);
      expect(guide.hasPrograms('visible'), isTrue);
      expect(guide.getPrograms('visible'), isEmpty);
      expect(guide.getPrograms('absent'), isEmpty);
      await Future<void>.delayed(Duration.zero);
      expect(db.reads, 1);
      final now = DateTime.now().millisecondsSinceEpoch;
      final data = {
        'visible': <EpgRow>[
          (
            channelId: 'visible',
            startMs: now - 1000,
            stopMs: now + 3600000,
            title: 'Visible programme',
            description: 'Complete description',
            isLive: true
          )
        ]
      };
      final loaded = Completer<void>();
      guide.guideRowsLoaded.addListener(() {
        if (!loaded.isCompleted) loaded.complete();
      });
      if (finishRowsFirst) {
        db.rows.complete(data);
        await loaded.future;
        expect(ready, isFalse);
      }
      db.snapshot.complete({});
      await init;
      if (!finishRowsFirst) {
        db.rows.complete(data);
        await loaded.future;
      }
      expect(guide.getPrograms('visible').single.title, 'Visible programme');
      expect(guide.getCurrentProgram('visible')?.description,
          'Complete description');
      await Future<void>.delayed(Duration.zero);
      expect(db.reads, 1,
          reason:
              'Initial snapshot must retain visible rows and in-flight reads');
    });
  }
}
