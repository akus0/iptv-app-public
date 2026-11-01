import 'package:flutter_test/flutter_test.dart';
import 'package:nox_iptv/services/epg_database.dart';
import 'package:nox_iptv/services/sports_guide_search_index.dart';
import 'package:nox_iptv/utils/sports_title_matcher.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Database db;
  late _ObservedDatabase observed;
  late EpgDatabase guide;
  late SportsGuideSearchIndex index;
  late List<EpgRow> rows;
  const titles = [
    '鹿島アントラーズ対セレッソ大阪',
    '전북 현대 모터스 대 대전 하나 시티즌',
    'NCAA: Duke vs North Carolina',
    'テニス: João',
    'ten xx enn xx nni xx nis', // FTS false positive, never an exact hit.
    'Evening news',
    'Kelvin İSTANBUL',
    'Live.*[sport]',
  ];
  setUp(() async {
    sqfliteFfiInit();
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await db.execute('CREATE TABLE programme('
        'channel_id TEXT, start INTEGER, stop INTEGER, title TEXT, '
        'descr TEXT, live INTEGER, PRIMARY KEY(channel_id,start)) WITHOUT ROWID');
    index = SportsGuideSearchIndex();
    await index.maintain(db);
    rows = [
      for (var i = 0; i < 3000; i++)
        (
          channelId: 'selected',
          startMs: i * 1000,
          stopMs: i * 1000 + 1500,
          title: titles[i % titles.length],
          description: 'Slot $i',
          isLive: i.isEven,
        ),
      (
        channelId: 'selected',
        startMs: -10000,
        stopMs: 500000,
        title: 'Tennis long coverage',
        description: null,
        isLive: true
      ),
      (
        channelId: 'selected',
        startMs: -2000,
        stopMs: 9000,
        title: '日本 ${'x' * 1600}',
        description: null,
        isLive: false
      ),
      for (var i = 0; i < 2200; i++)
        (
          channelId: 'excluded',
          startMs: i * 1000,
          stopMs: i * 1000 + 1500,
          title: 'Unrelated pending title $i',
          description: null,
          isLive: false
        ),
    ];
    final batch = db.batch();
    for (final r in rows) {
      batch.rawInsert('INSERT INTO programme VALUES (?,?,?,?,?,?)', [
        r.channelId,
        r.startMs,
        r.stopMs,
        r.title,
        r.description,
        r.isLive ? 1 : 0
      ]);
    }
    await batch.commit(noResult: true);
    observed = _ObservedDatabase(db);
    guide = EpgDatabase.withConnection(observed);
  });
  tearDown(() async {
    index.dispose();
    await db.close();
  });

  Future<void> clean() async => expect(
      await db.rawQuery(
          "SELECT name FROM sqlite_temp_master WHERE name LIKE 'sports_title_hits_%'"),
      isEmpty);
  Future<void> check(int from, int to, List<String> terms) async {
    final matcher = SportsTitleMatcher(terms);
    final expected = rows
        .where((r) =>
            terms.isNotEmpty &&
            r.channelId == 'selected' &&
            r.startMs < to &&
            r.stopMs > from &&
            matcher.matches(r.title))
        .toList()
      ..sort((a, b) => a.startMs.compareTo(b.startMs));
    expect(
        await guide.programmesStartingWithTitle(from, to, terms,
            channelIds: ['selected', 'selected']),
        expected,
        reason: '$from/$to $terms');
    await clean();
  }

  test(
      'adaptive narrow and broad reads preserve exact language and overlap semantics',
      () async {
    for (final terms in <List<String>>[
      ['tennis'],
      ['kashima antlers', 'jeonbuk'],
      ['鹿島', '전북'],
      ['NCAA', 'João'],
      ['K', 'İ'],
      ['.*['],
      ['x'],
      [''],
      [],
      ['missing'],
      ['日本']
    ]) {
      await check(0, 12000, terms);
      await check(-20000, 4000000, terms);
    }
    expect(observed.probes.any((p) => p.$1 < p.$2), isTrue);
    expect(observed.probes.any((p) => p.$1 == p.$2), isTrue);
    await index.maintain(db);
    guide = EpgDatabase.withConnection(observed);
    for (final terms in <List<String>>[
      ['tennis'],
      ['kashima antlers', 'jeonbuk'],
      ['NCAA'],
      []
    ]) {
      await check(0, 12000, terms);
      await check(-20000, 4000000, terms);
    }
  });

  test('multi-day windows retain the original plan without a scope probe',
      () async {
    await check(-20000, const Duration(days: 3).inMilliseconds, ['tennis']);
    expect(observed.probes, isEmpty);
  });

  test('candidate deferral is explicit and default results stay exact',
      () async {
    for (final defer in [true, false]) {
      final result = (await index.candidates(db, ['tennis'],
          verifyProgrammes: (table, count) async {
        expect(count, greaterThan(1024));
        return defer;
      }))!;
      expect(result.verified, !defer);
      final titles = (await db.rawQuery('SELECT title FROM ${result.table}'))
          .map((r) => r['title'] as String)
          .toSet();
      final exact = rows
          .map((r) => r.title)
          .where(SportsTitleMatcher(['tennis']).matches)
          .toSet();
      expect(
          titles.where(SportsTitleMatcher(['tennis']).matches).toSet(), exact);
      if (defer) {
        expect(titles.length, greaterThan(exact.length));
      } else {
        expect(titles, exact);
      }
      await db.execute('DROP TABLE ${result.table}');
      await clean();
    }
  });

  test(
      'failed optional probe or scope falls back and cursor failure releases the queue',
      () async {
    observed.failProbe = true;
    await check(0, 12000, ['tennis', 'NCAA']);
    observed.failProbe = false;
    observed.failScope = true;
    await check(0, 12000, ['tennis', 'NCAA']);
    observed.failScope = false;
    observed.failProgrammeCursor = true;
    await expectLater(
        guide.programmesStartingWithTitle(0, 12000, ['tennis'],
            channelIds: ['selected']),
        throwsStateError);
    await clean();
    observed.failProgrammeCursor = false;
    await check(0, 12000, ['tennis', 'NCAA']);
  });

  test('later edits and pending additions never reuse title match decisions',
      () async {
    await check(0, 12000, ['new competition']);
    const replacement = (
      channelId: 'selected',
      startMs: 0,
      stopMs: 1500,
      title: 'New competition LIVE',
      description: 'Corrected',
      isLive: true
    );
    await db.rawUpdate(
        'UPDATE programme SET title=?,descr=?,live=1 WHERE channel_id=? AND start=0',
        [replacement.title, replacement.description, replacement.channelId]);
    rows[0] = replacement;
    await check(0, 12000, ['new competition']);
    await check(0, 12000, ['kashima antlers']);
    await Future.wait([
      check(0, 12000, ['tennis']),
      check(0, 12000, ['jeonbuk'])
    ]);
  });
}

class _ObservedDatabase implements Database {
  _ObservedDatabase(this.db);
  final Database db;
  final probes = <(int, int)>[];
  bool failProbe = false, failScope = false, failProgrammeCursor = false;
  @override
  Future<List<Map<String, Object?>>> rawQuery(String sql,
      [List<Object?>? arguments]) async {
    final probe =
        sql.startsWith('SELECT COUNT(*) FROM (SELECT 1 FROM programme');
    if (probe && failProbe) throw StateError('Injected optional probe failure');
    final rows = await db.rawQuery(sql, arguments);
    if (probe) {
      probes.add((rows.single.values.single as int, arguments!.last as int));
    }
    return rows;
  }

  @override
  Future<void> execute(String sql, [List<Object?>? arguments]) {
    if (failScope &&
        sql.startsWith('CREATE TEMP TABLE') &&
        sql.contains('_channels(')) {
      throw StateError('Injected optional scope failure');
    }
    return db.execute(sql, arguments);
  }

  @override
  Future<int> rawInsert(String sql, [List<Object?>? arguments]) =>
      db.rawInsert(sql, arguments);
  @override
  Batch batch() => db.batch();
  @override
  Future<QueryCursor> rawQueryCursor(String sql, List<Object?>? arguments,
      {int? bufferSize}) {
    if (failProgrammeCursor && sql.startsWith('SELECT channel_id,')) {
      throw StateError('Injected programme cursor failure');
    }
    return db.rawQueryCursor(sql, arguments, bufferSize: bufferSize);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}
