import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';
import '../utils/sports_language.dart';
import 'sports_title_filter.dart';

/// Optional, derived title dictionary. FTS4 works on older Android SQLite.
/// Encoded trigrams narrow literal substring searches; the original matcher
/// verifies every candidate. Pending/native titles always take the exact path.
/// Failure must never enter the guide database's destructive recovery path.
class SportsGuideSearchIndex {
  Future<void>? _maintenance;
  final _titleFilter = SportsTitleFilter();

  void dispose() => _titleFilter.dispose();

  /// Exact verification for scoped programme batches uses the same worker as
  /// dictionary candidates, including its bounded language cache and fallback.
  Future<List<String>> matchTitles(List<String> terms, List<String> titles) =>
      _titleFilter.matches(terms, titles);
  static int _sequence = 0;

  Future<bool> available(Database db) async {
    try {
      // A marker alone cannot detect a missing tracking trigger. In that case
      // new programmes would otherwise be silently absent from indexed search.
      return Sqflite.firstIntValue(await db.rawQuery(
              "SELECT COUNT(*) FROM sqlite_master WHERE "
              "(type='table' AND name IN ('sports_title_ready_v1',"
              "'sports_title_doc','sports_title_fts')) OR "
              "(type='trigger' AND name IN ('sports_title_insert','sports_title_update'))")) ==
          5;
    } catch (_) {
      return false;
    }
  }

  /// Called after visible work, not awaited by the first sports screen.
  Future<void> maintain(Database db, {bool Function()? cancelled}) =>
      _maintenance ??=
          _maintain(db, cancelled).whenComplete(() => _maintenance = null);

  Future<void> _maintain(Database db, bool Function()? cancelled) async {
    final audit = const bool.fromEnvironment('IPTV_PROFILE_SPORTS')
        ? (Stopwatch()..start())
        : null;
    var indexed = 0;
    try {
      if (cancelled?.call() == true) return;
      if (!await available(db)) {
        await db.transaction((txn) async {
          // Rebuild only derived state; the ordinary guide remains authoritative.
          for (final name in ['insert', 'update']) {
            await txn.execute('DROP TRIGGER IF EXISTS sports_title_$name');
          }
          for (final name in ['fts', 'doc', 'ready_v1']) {
            await txn.execute('DROP TABLE IF EXISTS sports_title_$name');
          }
          await txn.execute('CREATE TABLE IF NOT EXISTS sports_title_doc ('
              'id INTEGER PRIMARY KEY, title TEXT NOT NULL UNIQUE, '
              'indexed INTEGER NOT NULL DEFAULT 0, fallback INTEGER NOT NULL DEFAULT 1)');
          try {
            await txn.execute(
                'CREATE VIRTUAL TABLE IF NOT EXISTS sports_title_fts USING fts4(tokens)');
          } catch (_) {
            await txn.execute(
                'CREATE VIRTUAL TABLE IF NOT EXISTS sports_title_fts USING fts5(tokens)');
          }
          await txn.execute(
              'CREATE INDEX IF NOT EXISTS sports_title_pending ON sports_title_doc(id) WHERE indexed=0');
          await txn.execute(
              'CREATE INDEX IF NOT EXISTS sports_title_fallback ON sports_title_doc(id) WHERE fallback=1');
          for (final operation in ['INSERT', 'UPDATE OF title']) {
            final name = operation == 'INSERT' ? 'insert' : 'update';
            await txn.execute('CREATE TRIGGER IF NOT EXISTS sports_title_$name '
                'AFTER $operation ON programme BEGIN '
                'INSERT INTO sports_title_doc(title) SELECT new.title '
                'WHERE NOT EXISTS (SELECT 1 FROM sports_title_doc WHERE title=new.title); END');
          }
          await txn.execute(
              'INSERT OR IGNORE INTO sports_title_doc(title) SELECT DISTINCT title FROM programme');
          await txn
              .execute('CREATE TABLE sports_title_ready_v1 (ready INTEGER)');
        });
      }
      // Prune derived titles after long-running guide refreshes. One set
      // difference avoids a correlated full programme scan for every title.
      final count = Sqflite.firstIntValue(
              await db.rawQuery('SELECT COUNT(*) FROM sports_title_doc')) ??
          0;
      if (count > 100000) {
        await db.transaction((txn) async {
          await txn.execute('CREATE TEMP TABLE sports_title_stale AS '
              'SELECT id FROM sports_title_doc WHERE title NOT IN (SELECT DISTINCT title FROM programme)');
          await txn.execute(
              'DELETE FROM sports_title_fts WHERE rowid IN (SELECT id FROM sports_title_stale)');
          await txn.execute(
              'DELETE FROM sports_title_doc WHERE id IN (SELECT id FROM sports_title_stale)');
          await txn.execute('DROP TABLE sports_title_stale');
        });
      }
      // A bounded batch limits worker memory and each write transaction. New
      // titles are searchable immediately, before their derived tokens exist.
      while (cancelled?.call() != true) {
        final rows = await db.rawQuery(
            'SELECT id,title FROM sports_title_doc WHERE indexed=0 LIMIT 256');
        if (rows.isEmpty) break;
        final encoded = await compute(_encodeTitles, rows);
        if (cancelled?.call() == true) break;
        await db.transaction((txn) async {
          final batch = txn.batch();
          for (final row in encoded) {
            batch.rawInsert(
                'INSERT OR REPLACE INTO sports_title_fts(rowid,tokens) VALUES (?,?)',
                [row.$1, row.$2]);
            batch.rawUpdate(
                'UPDATE sports_title_doc SET indexed=1,fallback=? WHERE id=?',
                [row.$3 ? 1 : 0, row.$1]);
          }
          await batch.commit(noResult: true);
        });
        indexed += rows.length;
        await Future<void>.delayed(const Duration(milliseconds: 8));
      }
    } catch (_) {
      // Optional acceleration: all ordinary guide data and queries survive.
    } finally {
      if (audit != null && indexed > 0) {
        debugPrint(
            'IPTV_SEARCH_INDEX built=$indexed elapsed_ms=${audit.elapsedMilliseconds}');
      }
    }
  }

  /// Returns title candidates, or null to use the original cursor. An
  /// empty result can skip programme reads. The caller always owns table cleanup.
  /// Serialize complete query lifetimes, including the caller's cursor/cleanup.
  /// By default every title is exact. A scoped caller can elect to verify
  /// programme rows instead, after measuring the conservative candidate set.
  Future<({String table, bool hasMatches, bool verified})?> candidates(
      Database db, List<String> terms,
      {Future<bool> Function(String table, int titleCount)?
          verifyProgrammes}) async {
    if (!await available(db)) return null;
    final table = 'sports_title_hits_${++_sequence}';
    final prefilter = '${table}_ids';
    var hasPrefilter = false, hasRawTitles = false;
    final rawTitles = '${table}_raw';
    var resultTable = table, retainRawTitles = false;
    final audit = const bool.fromEnvironment('IPTV_PROFILE_SPORTS')
        ? (Stopwatch()..start())
        : null;
    var verified = 0;
    try {
      var hasMatches = false, exact = true;
      final expressions = <String>{};
      var scanDictionary = terms.isEmpty;
      for (final term in terms) {
        // Non-Unicode RegExp case folding cannot turn a non-ASCII keyword
        // into an ASCII match. Native titles (including translated variants)
        // and pending rows are already included by fallback=1. One accented
        // surname must not make every other keyword scan the whole dictionary.
        if (_nonAscii.hasMatch(term)) continue;
        if (term.length < 3) {
          scanDictionary = true;
          break;
        }
        // Every literal hit contains all these trigrams. Spread a bounded
        // number across the keyword to reject common-prefix noise in SQLite,
        // before transferring titles to Dart for the exact check. Tokens may
        // occur in different order; verification still decides the match.
        final text = term.toLowerCase();
        final last = text.length - 3;
        final grams = {
          for (final at in {0, last ~/ 3, last * 2 ~/ 3, last}) _gram(text, at)
        };
        expressions.add(grams.join(' '));
      }
      Future<void> collect(String sql, List<Object?> args) async {
        if (verifyProgrammes != null) {
          await db.execute('CREATE TEMP TABLE $rawTitles('
              'title TEXT PRIMARY KEY) WITHOUT ROWID');
          hasRawTitles = true;
          await db.rawInsert('INSERT OR IGNORE INTO $rawTitles $sql', args);
          final count = Sqflite.firstIntValue(
                  await db.rawQuery('SELECT COUNT(*) FROM $rawTitles')) ??
              0;
          if (count == 0 || await verifyProgrammes(rawTitles, count)) {
            resultTable = rawTitles;
            hasMatches = count != 0;
            exact = count == 0;
            return;
          }
          sql = 'SELECT title FROM $rawTitles';
          args = const [];
        }
        await db.execute(
            'CREATE TEMP TABLE $table(title TEXT PRIMARY KEY) WITHOUT ROWID');
        // One native transfer fills one bounded filtering batch. Smaller
        // cursor pages add platform round trips before the worker can start.
        const titlesPerBatch = 1024;
        final cursor =
            await db.rawQueryCursor(sql, args, bufferSize: titlesPerBatch);
        var titles = <String>[];
        Future<void> flush() async {
          final matches = await _titleFilter.matches(terms, titles);
          titles = <String>[];
          hasMatches |= matches.isNotEmpty;
          for (var at = 0; at < matches.length; at += 256) {
            final hits = matches.skip(at).take(256).toList();
            await db.rawInsert(
                'INSERT OR IGNORE INTO $table VALUES '
                '${List.filled(hits.length, '(?)').join(',')}',
                hits);
          }
        }

        try {
          while (await cursor.moveNext()) {
            titles.add(cursor.current['title'] as String);
            if (audit != null) verified++;
            // Bounded copies keep peak memory independent of guide size. The
            // native cursor remains here; only exact text checks run off-thread.
            if (titles.length >= titlesPerBatch) await flush();
          }
          if (titles.isNotEmpty) await flush();
        } finally {
          await cursor.close();
        }
      }

      if (scanDictionary) {
        await collect('SELECT title FROM sports_title_doc', []);
      } else {
        await db
            .execute('CREATE TEMP TABLE $prefilter(id INTEGER PRIMARY KEY)');
        hasPrefilter = true;
        final tokens = expressions.toList();
        // Implicit conjunction works with FTS4's basic parser too: some
        // Android builds silently interpret explicit AND/parentheses as text.
        // Combine alternatives in SQL instead, with bounded compound queries.
        for (var offset = 0; offset < tokens.length; offset += 16) {
          final part = tokens.skip(offset).take(16).toList();
          await db.rawInsert(
              'INSERT OR IGNORE INTO $prefilter '
              '${List.filled(part.length, 'SELECT rowid FROM sports_title_fts WHERE sports_title_fts MATCH ?').join(' UNION ALL ')}',
              part);
        }
        // Several keywords can point to the same title. Union integer IDs in
        // SQLite so each title crosses the platform boundary and is verified
        // once, rather than once per keyword batch. Pending/native rows remain
        // exact and do not depend on a completed FTS entry.
        await collect(
            'SELECT title FROM sports_title_doc WHERE fallback=1 '
            'UNION ALL SELECT title FROM sports_title_doc '
            'WHERE id IN (SELECT id FROM $prefilter) AND fallback=0',
            []);
      }
      if (audit != null) {
        debugPrint('IPTV_TITLE_SEARCH scan=$scanDictionary rows=$verified '
            'ms=${audit.elapsedMilliseconds}');
      }
      retainRawTitles = resultTable == rawTitles;
      return (table: resultTable, hasMatches: hasMatches, verified: exact);
    } catch (_) {
      try {
        await db.execute('DROP TABLE IF EXISTS $table');
      } catch (_) {}
      return null;
    } finally {
      if (hasRawTitles && !retainRawTitles) {
        try {
          await db.execute('DROP TABLE IF EXISTS $rawTitles');
        } catch (_) {}
      }
      if (hasPrefilter) {
        try {
          await db.execute('DROP TABLE IF EXISTS $prefilter');
        } catch (_) {}
      }
    }
  }
}

final _nonAscii = RegExp(r'[^\x00-\x7f]');
String _gram(String text, int at) =>
    'g${text.codeUnitAt(at).toRadixString(16).padLeft(2, '0')}'
    '${text.codeUnitAt(at + 1).toRadixString(16).padLeft(2, '0')}'
    '${text.codeUnitAt(at + 2).toRadixString(16).padLeft(2, '0')}';

List<(int, String, bool)> _encodeTitles(List<Map<String, Object?>> rows) => [
      for (final row in rows)
        _encodeTitle(row['id'] as int, row['title'] as String)
    ];

(int, String, bool) _encodeTitle(int id, String title) {
  // Keep Unicode regex case folding and unusual/oversized titles exact.
  if (_nonAscii.hasMatch(title) || title.length > 1024) return (id, '', true);
  final translated = sportsLanguageText(title);
  final texts = {
    title.toLowerCase(),
    if (translated != title) normalizeSportsName(translated).toLowerCase()
  };
  final grams = <String>{};
  for (final text in texts) {
    for (var i = 0; i + 2 < text.length; i++) {
      grams.add(_gram(text, i));
    }
  }
  return (id, grams.join(' '), false);
}
