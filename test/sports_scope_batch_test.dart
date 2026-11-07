import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:nox_iptv/services/epg_database.dart';

// Delegate to real SQLite, adding a temporary trigger that fails the second
// scope INSERT. This exercises a partially applied native batch, not a mocked
// query result; the production fallback must still return every eligible row.
class _ScopeFaults {
  bool failNextScope = false;
  int? partialRows;
}

class _ScopeFaultDatabase implements Database {
  _ScopeFaultDatabase(this.delegate, this.faults);
  final Database delegate;
  final _ScopeFaults faults;
  String? _failingTable;

  @override
  Future<void> execute(String sql, [List<Object?>? arguments]) async {
    if (sql == 'DROP TABLE IF EXISTS $_failingTable') {
      final rows =
          await delegate.rawQuery('SELECT COUNT(*) AS n FROM $_failingTable');
      faults.partialRows = rows.single['n'] as int;
      _failingTable = null;
    }
    await delegate.execute(sql, arguments);
    final match =
        RegExp(r'^CREATE TEMP TABLE (sports_title_hits_\d+_channels)\(')
            .firstMatch(sql);
    if (faults.failNextScope && match != null) {
      faults.failNextScope = false;
      _failingTable = match[1]!;
      await delegate.execute('CREATE TEMP TRIGGER fail_scope_insert '
          'BEFORE INSERT ON $_failingTable WHEN new.id=\'feed00500\' '
          "BEGIN SELECT RAISE(ABORT, 'injected scope failure'); END");
    }
  }

  @override
  Batch batch() => delegate.batch();
  @override
  Future<List<Map<String, Object?>>> rawQuery(String sql,
          [List<Object?>? arguments]) =>
      delegate.rawQuery(sql, arguments);
  @override
  Future<int> rawInsert(String sql, [List<Object?>? arguments]) =>
      delegate.rawInsert(sql, arguments);
  @override
  Future<QueryCursor> rawQueryCursor(String sql, List<Object?>? arguments,
          {int? bufferSize}) =>
      delegate.rawQueryCursor(sql, arguments, bufferSize: bufferSize);
  @override
  Future<T> transaction<T>(Future<T> Function(Transaction txn) action,
          {bool? exclusive}) =>
      delegate.transaction(action, exclusive: exclusive);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late EpgDatabase guide;
  late Database sql;
  late _ScopeFaults faults;
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
  String id(int i) => 'feed${i.toString().padLeft(5, '0')}';

  setUp(() async {
    sqfliteFfiInit();
    dir = await Directory.systemTemp.createTemp('sports-scope-batch-');
    messenger.setMockMethodCallHandler(pathProvider, (_) async => dir.path);
    databaseFactory = databaseFactoryFfi;
    await EpgDatabase().open();
    sql = await databaseFactoryFfi.openDatabase('${dir.path}/vesper_epg.db');
    faults = _ScopeFaults();
    guide = EpgDatabase.withConnection(_ScopeFaultDatabase(sql, faults));
  });
  tearDown(() async {
    messenger.setMockMethodCallHandler(pathProvider, null);
    await databaseFactoryFfi.deleteDatabase('${dir.path}/vesper_epg.db');
    databaseFactory = databaseFactoryFfi;
    await dir.delete(recursive: true);
  });

  Future<List<EpgRow>> seed() async {
    final rows = <EpgRow>[
      for (final i in [0, 499, 500, 999, 3999, 4000, 7999, 8000, 8002, 9000])
        (
          channelId: id(i),
          startMs: 1000,
          stopMs: 5000,
          title: 'テニス ATP court $i',
          description: 'Guide $i',
          isLive: i.isEven
        ),
      (
        channelId: "特殊 'quoted' feed",
        startMs: 1000,
        stopMs: 5000,
        title: 'Tennis final',
        description: null,
        isLive: false
      ),
    ];
    await guide.insertBatch(rows, 'fixture', 1);
    await guide.warmSportsSearch();
    return rows;
  }

  Future<void> expectClean() async {
    expect(
        await sql.rawQuery("SELECT name FROM sqlite_temp_master "
            "WHERE name LIKE 'sports_title_hits_%' OR name='fail_scope_insert'"),
        isEmpty);
  }

  test('scope batches retain boundary IDs, tails and changing catalogues',
      () async {
    final rows = await seed();
    final ids = [for (var i = 0; i < 8003; i++) id(i), "特殊 'quoted' feed"];
    final expected = rows.where((r) => ids.contains(r.channelId)).toSet();
    final actual = await guide.programmesStartingWithTitle(
        2000, 4000, ['tennis'],
        channelIds: [...ids.reversed, ids.first]);
    expect(actual.toSet(), expected);
    expect(actual.length, expected.length);
    await expectClean();
    // A different catalogue must rebuild its own scope, even when queued while
    // another request is reading. No scope or negative result is cached.
    final changed = [...ids.where((v) => v != id(0)), id(9000)];
    final results = await Future.wait([
      guide.programmesStartingWithTitle(2000, 4000, ['tennis'],
          channelIds: ids),
      guide.programmesStartingWithTitle(2000, 4000, ['tennis'],
          channelIds: changed),
    ]);
    expect(results[0].toSet(), expected);
    expect(results[1].toSet(),
        rows.where((r) => changed.contains(r.channelId)).toSet());
    await expectClean();
  });

  test('partial native batch failure discards scope and retries exact reads',
      () async {
    final rows = await seed();
    final ids = [for (var i = 0; i < 4003; i++) id(i)];
    final expected = rows.where((r) => ids.contains(r.channelId)).toSet();
    faults.failNextScope = true;
    final actual = await guide
        .programmesStartingWithTitle(2000, 4000, ['tennis'], channelIds: ids);
    expect(faults.partialRows, 500);
    expect(actual.toSet(), expected);
    expect(actual.length, expected.length);
    await expectClean();
    expect(
        (await guide.programmesStartingWithTitle(2000, 4000, ['tennis'],
                channelIds: ids))
            .toSet(),
        expected);
    expect(
        (await sql.rawQuery('SELECT COUNT(*) AS n FROM programme')).single['n'],
        rows.length);
    await expectClean();
  });
}
