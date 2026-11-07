import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqflite/sqflite.dart' show Sqflite;
import 'package:nox_iptv/services/sports_guide_search_index.dart';
import 'package:nox_iptv/utils/sports_title_matcher.dart';
import 'package:nox_iptv/utils/sports_language.dart';
import 'dart:math';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Database db;
  late SportsGuideSearchIndex index;
  setUp(() async {
    sqfliteFfiInit();
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await db.execute(
        'CREATE TABLE programme(channel_id TEXT PRIMARY KEY,title TEXT NOT NULL)');
    index = SportsGuideSearchIndex();
  });
  tearDown(() async {
    index.dispose();
    await db.close();
  });

  Future<Set<String>?> search(List<String> terms) async {
    final candidates = await index.candidates(db, terms);
    if (candidates == null) return null;
    expect(candidates.verified, isTrue);
    final table = candidates.table;
    try {
      final titles = (await db.rawQuery('SELECT title FROM $table'))
          .map((r) => r['title'] as String)
          .toSet();
      expect(candidates.hasMatches, titles.isNotEmpty);
      return titles;
    } finally {
      await db.execute('DROP TABLE $table');
    }
  }

  test(
      'persistent candidate search preserves substring, native and translated matches',
      () async {
    final titles = [
      'F1TV live',
      'footballers',
      'ATP:Basel',
      'ATP - Basel',
      'TENNIS live',
      'tenis de mesa',
      'Fútbol: Atlético',
      'テニス',
      'ฟุตบอล',
      'Basketball',
      'Straße',
      'İSTANBUL',
      'Kelvin K',
      'Live.*[sport]',
      '100% coverage',
      '',
      'soccer versus football',
      for (var i = 0; i < 700; i++) 'Programme $i'
    ];
    final batch = db.batch();
    for (var i = 0; i < titles.length; i++) {
      batch.rawInsert('INSERT INTO programme VALUES (?,?)', ['$i', titles[i]]);
    }
    await batch.commit(noResult: true);
    expect(await search(['tennis']), isNull);
    await index.maintain(db);
    expect(await index.available(db), isTrue);
    for (final terms in [
      ['tennis'],
      ['atp'],
      ['foot'],
      ['f1'],
      ['tenis'],
      ['soccer'],
      ['テニス'],
      ['K'],
      ['İ'],
      ['.*['],
      ['100%'],
      [''],
      ['missing'],
      ['basketball', 'tennis', 'soccer'],
      List.generate(200, (i) => 'Programme $i')
    ]) {
      final expected = titles.where(SportsTitleMatcher(terms).matches).toSet();
      expect(await search(terms), expected, reason: terms.toString());
    }
    // A new service instance uses the persistent dictionary without rebuilding.
    index.dispose();
    index = SportsGuideSearchIndex();
    expect(await search(['atp']), {'ATP:Basel', 'ATP - Basel'});
  });

  test(
      'native club identities survive pending, indexed and reopened guide searches',
      () async {
    final titles = {
      'kashima antlers': '鹿島アントラーズ対セレッソ大阪',
      'jeonbuk': '전북 현대 모터스 대 대전 하나 시티즌',
      'taipei fubon braves': '台北富邦勇士對桃園璞園領航猿',
    };
    await index.maintain(db);
    for (final entry in titles.entries) {
      await db.rawInsert(
          'INSERT INTO programme VALUES (?,?)', [entry.key, entry.value]);
    }
    for (var stage = 0; stage < 3; stage++) {
      if (stage == 1) await index.maintain(db);
      if (stage == 2) {
        index.dispose();
        index = SportsGuideSearchIndex();
      }
      for (final entry in titles.entries) {
        expect(await search([entry.key]), {entry.value});
      }
      expect(await search(['gamba osaka']), isEmpty);
    }
  });

  test('worker batches retain all pending titles and a short final batch',
      () async {
    await index.maintain(db);
    final titles = [
      for (var i = 0; i < 2079; i++)
        switch (i % 3) {
          0 => 'テニス: João $i',
          1 => 'Football fixture $i',
          _ => 'Evening bulletin $i',
        },
      'Tennis final tail',
    ];
    final batch = db.batch();
    for (var i = 0; i < titles.length; i++) {
      batch.rawInsert('INSERT INTO programme VALUES (?,?)', ['$i', titles[i]]);
    }
    await batch.commit(noResult: true);
    // Pending rows exercise the full candidate stream without depending on
    // background indexing, including two full transfers and a local tail.
    for (final terms in <List<String>>[
      ['tennis'],
      ['football'],
      ['João', 'bulletin'],
      [],
    ]) {
      final pattern =
          RegExp(terms.map(RegExp.escape).join('|'), caseSensitive: false);
      final expected =
          titles.where((t) => sportsTitleMatches(pattern, t)).toSet();
      expect(await search(terms), expected);
    }
    expect(
        await db.rawQuery(
            "SELECT name FROM sqlite_temp_master WHERE name LIKE 'sports_title_hits_%'"),
        isEmpty);
  });

  test('new and edited titles remain searchable before background maintenance',
      () async {
    await db
        .rawInsert('INSERT INTO programme VALUES (?,?)', ['a', 'ATP Basel']);
    await index.maintain(db);
    final before = await db.rawQuery(
        'SELECT id FROM sports_title_doc WHERE title=?', ['ATP Basel']);
    // Outer REPLACE must not replace the dictionary entry or orphan its FTS row.
    await db.rawInsert(
        'INSERT OR REPLACE INTO programme VALUES (?,?)', ['a', 'ATP Basel']);
    expect(
        await db.rawQuery(
            'SELECT id FROM sports_title_doc WHERE title=?', ['ATP Basel']),
        before);
    await db.rawInsert(
        'INSERT OR REPLACE INTO programme VALUES (?,?)', ['a', 'WTA Tokyo']);
    await db
        .rawInsert('INSERT INTO programme VALUES (?,?)', ['b', 'New tennis']);
    await db.rawUpdate(
        'UPDATE programme SET title=? WHERE channel_id=?', ['テニス', 'b']);
    expect(await search(['wta']), contains('WTA Tokyo'));
    expect(await search(['tennis']), contains('テニス'));
    await index.maintain(db);
    expect(await search(['wta']), contains('WTA Tokyo'));
    await db.delete('programme');
    final table = (await index.candidates(db, ['tennis', 'wta']))!.table;
    expect(
        await db.rawQuery(
            'SELECT * FROM programme WHERE title IN (SELECT title FROM $table)'),
        isEmpty);
    await db.execute('DROP TABLE $table');
  });

  test('mixed scripts and case folding preserve the exact title search',
      () async {
    final titles = [
      'Tennis: ATP Basel',
      'TENNIS',
      'tenis de mesa',
      'pista 3',
      'Fútbol: Atlético',
      'Tênis: João',
      'Joa\u0303o',
      'テニス',
      '足球',
      'ТЕННИС',
      '한국프로야구',
      'Ｔｅｎｎｉｓ',
      'ฟุตบอล',
      'İSTANBUL',
      'ıstanbul',
      'ISTANBUL',
      'Kelvin',
      'Kelvin',
      'ſport',
      'SPORT',
      'Straße',
      'STRASSE',
      'Maße',
      'MASSE',
      'ABC αβγ',
      'abc ΑΒΓ',
      'a.*[b]',
      '',
      for (var i = 0; i < 400; i++) 'Unrelated programme $i',
    ];
    final batch = db.batch();
    for (var i = 0; i < titles.length; i++) {
      batch.rawInsert('INSERT INTO programme VALUES (?,?)', ['$i', titles[i]]);
    }
    await batch.commit(noResult: true);
    await index.maintain(db);
    for (final terms in <List<String>>[
      [],
      [''],
      ['tennis', 'João'],
      ['soccer', '足球'],
      ['table tennis', 'テニス'],
      ['court', 'İ'],
      ['baseball', '한국'],
      ['f1', 'ТЕННИС'],
      ['tennis', 'K'],
      ['tennis', 'ſ'],
      ['tennis', 'ı'],
      ['tennis', 'ß'],
      ['tennis', 'αβγ'],
      ['a.*[', 'João'],
      ['tennis', '不存在'],
      ['tennis', 'João', 'İ', 'K', 'ſ', 'ß', 'ı', 'αβγ'],
    ]) {
      final reference =
          RegExp(terms.map(RegExp.escape).join('|'), caseSensitive: false);
      expect(await search(terms),
          titles.where((title) => sportsTitleMatches(reference, title)).toSet(),
          reason: terms.toString());
    }
  });

  test('bounded trigram conjunctions retain punctuation and overlapping hits',
      () async {
    final random = Random(158);
    const alphabet = 'aAbBcCdD .+|[]';
    String word(int length) =>
        List.generate(length, (_) => alphabet[random.nextInt(alphabet.length)])
            .join();
    final terms = List.generate(160, (_) => word(3 + random.nextInt(24)));
    final titles = [
      for (final term in terms) 'Live: $term coverage',
      for (var i = 0; i < 200; i++) word(80),
      // All required grams can exist without the whole keyword being present.
      'ten xx enn xx nni xx nis', 'TENNIS', 'tennis documentary',
      'Programme prefix-only noise',
    ];
    final batch = db.batch();
    for (var i = 0; i < titles.length; i++) {
      batch.rawInsert('INSERT INTO programme VALUES (?,?)', ['$i', titles[i]]);
    }
    await batch.commit(noResult: true);
    await index.maintain(db);
    for (final query in [
      terms,
      ['tennis'],
      [...terms, 'tennis', 'João']
    ]) {
      final reference =
          RegExp(query.map(RegExp.escape).join('|'), caseSensitive: false);
      expect(
          await search(query),
          titles
              .where((title) => sportsTitleMatches(reference, title))
              .toSet());
    }
  });

  test(
      'optional index failure returns the legacy path without deleting guide data',
      () async {
    await db
        .rawInsert('INSERT INTO programme VALUES (?,?)', ['a', 'ATP Basel']);
    await index.maintain(db);
    await db.execute('DROP TABLE sports_title_fts');
    expect(await search(['tennis']), isNull);
    expect(await db.query('programme'), hasLength(1));
    expect(
        await db.rawQuery(
            "SELECT name FROM sqlite_temp_master WHERE name LIKE 'sports_title_hits_%'"),
        isEmpty);
    await index.maintain(db);
    expect(await search(['atp']), {'ATP Basel'});
    expect(await db.query('programme'), hasLength(1));
  });

  test('failed FTS reads clean both temporary tables and preserve guide rows',
      () async {
    await db
        .rawInsert('INSERT INTO programme VALUES (?,?)', ['a', 'ATP Basel']);
    await index.maintain(db);
    // Simulate an incompatible/corrupt optional index that passes the schema
    // presence check but fails when MATCH executes, after temp-table creation.
    await db.execute('DROP TABLE sports_title_fts');
    await db.execute('CREATE TABLE sports_title_fts(tokens TEXT)');
    expect(await index.available(db), isTrue);
    expect(await search(['tennis', 'atp']), isNull);
    expect(await db.query('programme'), hasLength(1));
    expect(
        await db.rawQuery(
            "SELECT name FROM sqlite_temp_master WHERE name LIKE 'sports_title_hits_%'"),
        isEmpty);
  });

  test('candidate unions also work with the FTS5 fallback index', () async {
    final titles = [
      'Tennis quarter final',
      'ten xx enn xx nni xx nis',
      'Football league',
      'テニス',
      'News',
    ];
    for (var i = 0; i < titles.length; i++) {
      await db
          .rawInsert('INSERT INTO programme VALUES (?,?)', ['$i', titles[i]]);
    }
    await index.maintain(db);
    final tokens =
        await db.rawQuery('SELECT rowid,tokens FROM sports_title_fts');
    await db.execute('DROP TABLE sports_title_fts');
    await db
        .execute('CREATE VIRTUAL TABLE sports_title_fts USING fts5(tokens)');
    for (final row in tokens) {
      await db.rawInsert(
          'INSERT INTO sports_title_fts(rowid,tokens) VALUES (?,?)',
          [row['rowid'], row['tokens']]);
    }
    for (final terms in [
      ['tennis'],
      ['football', 'João'],
      ['f1'],
      ['missing']
    ]) {
      expect(await search(terms),
          titles.where(SportsTitleMatcher(terms).matches).toSet());
    }
  });

  for (final operation in ['insert', 'update']) {
    test('a missing $operation trigger falls back and repairs derived data',
        () async {
      await db.rawInsert('INSERT INTO programme VALUES (?,?)', ['a', 'News']);
      await index.maintain(db);
      await db.execute('DROP TRIGGER sports_title_$operation');
      if (operation == 'insert') {
        await db.rawInsert(
            'INSERT INTO programme VALUES (?,?)', ['b', 'Tennis LIVE']);
      } else {
        await db.rawUpdate('UPDATE programme SET title=? WHERE channel_id=?',
            ['Tennis LIVE', 'a']);
      }
      final original = await db.query('programme');
      expect(await search(['tennis']), isNull);
      await index.maintain(db);
      expect(await search(['tennis']), {'Tennis LIVE'});
      expect(await db.query('programme'), original);
    });
  }

  test('interrupted token work leaves pending titles searchable and resumes',
      () async {
    final titles = List.generate(600, (i) => 'Tennis match $i');
    final batch = db.batch();
    for (var i = 0; i < titles.length; i++) {
      batch.rawInsert('INSERT INTO programme VALUES (?,?)', ['$i', titles[i]]);
    }
    await batch.commit(noResult: true);
    var checks = 0;
    await index.maintain(db, cancelled: () => ++checks >= 3);
    expect(
        Sqflite.firstIntValue(await db
            .rawQuery('SELECT COUNT(*) FROM sports_title_doc WHERE indexed=1')),
        0);
    expect(await search(['tennis']), titles.toSet());
    await index.maintain(db);
    expect(
        Sqflite.firstIntValue(await db
            .rawQuery('SELECT COUNT(*) FROM sports_title_doc WHERE indexed=0')),
        0);
    expect(await search(['tennis']), titles.toSet());
  });
}
