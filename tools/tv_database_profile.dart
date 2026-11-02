// Temporary synthetic databases only. Run before app.main opens any database.
// Never included in the normal application entry point.
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

/// Disposable title-only index. The application database is opened read-only;
/// no guide text or identifiers are logged, and the index is never persisted.
Future<void> profileGuideFts() async {
  final path = '${(await getApplicationSupportDirectory()).path}/vesper_epg.db';
  if (!await File(path).exists()) return;
  final db = await openDatabase(path, readOnly: true, singleInstance: false);
  try {
    await db.execute('CREATE VIRTUAL TABLE temp.title_probe USING '
        'fts4(title, tokenize=unicode61)');
    final now = DateTime.now().millisecondsSinceEpoch;
    final watch = Stopwatch()..start();
    await db.rawInsert(
        'INSERT INTO temp.title_probe(title) '
        'SELECT DISTINCT title FROM main.programme WHERE stop > ? AND start < ?',
        [now - 86400000, now + 86400000]);
    final buildMs = watch.elapsedMilliseconds;
    final count = Sqflite.firstIntValue(
        await db.rawQuery('SELECT count(*) FROM temp.title_probe'));
    final samples = <Map<String, Object?>>[];
    // Literal substring and token matching deliberately differ. Counts make
    // that distinction visible rather than claiming equivalent retrieval.
    for (final term in ['tennis', 'football', 'f1', 'united', 'atp']) {
      for (final mode in ['substring', 'token']) {
        final times = <int>[];
        int? hits;
        for (var i = 0; i < 3; i++) {
          watch.reset();
          hits = Sqflite.firstIntValue(await db.rawQuery(
              mode == 'token'
                  ? 'SELECT count(*) FROM temp.title_probe WHERE title MATCH ?'
                  : 'SELECT count(*) FROM temp.title_probe WHERE title LIKE ?',
              [mode == 'token' ? term : '%$term%']));
          times.add(watch.elapsedMicroseconds);
        }
        samples.add({'term': term, 'mode': mode, 'hits': hits, 'us': times});
      }
    }
    // ignore: avoid_print
    print('IPTV_FTS ${jsonEncode({
          'titles': count,
          'build_ms': buildMs,
          'queries': samples
        })}');
  } catch (error) {
    // Do not print a database exception: it can contain source data.
    // ignore: avoid_print
    print('IPTV_FTS unavailable=${error.runtimeType}');
  } finally {
    await db.close();
  }
}

/// Read-only inspection of the existing guide. Never prints guide IDs, titles,
/// descriptions, sources or account data, and never runs schema maintenance.
Future<void> profileGuideReadPlans() async {
  final path = '${(await getApplicationSupportDirectory()).path}/vesper_epg.db';
  if (!await File(path).exists()) return;
  final db = await openDatabase(path, readOnly: true, singleInstance: false);
  try {
    final now = DateTime.now().millisecondsSinceEpoch;
    final until = now + const Duration(hours: 4).inMilliseconds;
    final ids = (await db
            .rawQuery('SELECT DISTINCT channel_id FROM programme LIMIT 128'))
        .map((r) => r['channel_id'])
        .toList();
    if (ids.isEmpty) return;
    final queries = <String, (String, List<Object?>)>{
      'now_next': (
        'SELECT channel_id,start,stop,title,descr,live FROM programme '
            'WHERE stop > ? AND start < ? ORDER BY channel_id,start LIMIT 512',
        [now, until]
      ),
      'sports': (
        'SELECT channel_id,start,stop,title,substr(descr,1,320),live '
            'FROM programme WHERE channel_id IN (${List.filled(ids.length, '?').join(',')}) '
            'AND start < ? AND stop > ? ORDER BY channel_id,start LIMIT 512',
        [...ids, until, now]
      ),
      'visible_channel': (
        'SELECT channel_id,start,stop,title,descr,live FROM programme '
            'WHERE channel_id = ? AND stop > ? ORDER BY channel_id,start',
        [ids.first, now]
      ),
    };
    final version = (await db.rawQuery('SELECT sqlite_version() AS version'))
        .single['version'];
    final indexes = (await db.rawQuery('PRAGMA index_list(programme)'))
        .map((r) => r['name'])
        .toList();
    for (final entry in queries.entries) {
      final (sql, args) = entry.value;
      final plan = (await db.rawQuery('EXPLAIN QUERY PLAN $sql', args))
          .map((r) => r['detail'])
          .toList();
      final times = <int>[];
      var count = 0;
      for (var i = 0; i < 3; i++) {
        final watch = Stopwatch()..start();
        count = (await db.rawQuery(sql, args)).length;
        times.add(watch.elapsedMicroseconds);
      }
      // ignore: avoid_print
      print('IPTV_INDEX ${jsonEncode({
            'sqlite': version,
            'indexes': indexes,
            'query': entry.key,
            'plan': plan,
            'rows': count,
            'times_us': times
          })}');
    }
  } finally {
    await db.close();
  }
}

Future<void> profileDatabaseWorkers() async {
  const channel = MethodChannel('com.tekartik.sqflite');
  final root = await Directory((await getTemporaryDirectory()).path)
      .createTemp('iptv-db-profile-');
  final guidePath = '${root.path}/guide.db';
  final artworkPath = '${root.path}/artwork.db';
  try {
    var guide = await openDatabase(guidePath);
    await guide
        .execute('CREATE TABLE programme (id INTEGER PRIMARY KEY, title TEXT)');
    await guide.execute(
        'WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM n WHERE x<50000) '
        "INSERT INTO programme SELECT x, 'Synthetic programme ' || x FROM n");
    await guide.close();
    final artwork = await openDatabase(artworkPath);
    await artwork
        .execute('CREATE TABLE image (id INTEGER PRIMARY KEY, size INTEGER)');
    await artwork.execute('INSERT INTO image VALUES (1, 42)');
    await artwork.close();
    final predicates =
        List.generate(48, (i) => "title LIKE '%fixture$i%'").join(' OR ');
    // Repeat pool sizes so a warm filesystem does not favour only the last one.
    for (final workers in [1, 2, 4, 1, 2, 4]) {
      await channel
          .invokeMethod<void>('options', {'androidThreadCount': workers});
      guide = await openDatabase(guidePath);
      final art = await openDatabase(artworkPath);
      try {
        for (var round = 0; round < 3; round++) {
          final watch = Stopwatch()..start();
          final heavy = guide
              .rawQuery('SELECT count(*) FROM programme WHERE $predicates')
              .then((_) => watch.elapsedMicroseconds / 1000);
          await Future<void>.delayed(const Duration(milliseconds: 5));
          final point = Stopwatch()..start();
          final rows = await art.rawQuery('SELECT size FROM image WHERE id=1');
          final otherMs = point.elapsedMicroseconds / 1000;
          if (rows.single['size'] != 42) {
            throw StateError('Unexpected fixture result');
          }
          final guideMs = await heavy;
          // ignore: avoid_print
          print('IPTV_DB ${jsonEncode({
                'workers': workers,
                'round': round,
                'guide_ms': guideMs,
                'other_ms': otherMs
              })}');
        }
      } finally {
        await art.close();
        await guide.close();
      }
    }
  } finally {
    await deleteDatabase(guidePath);
    await deleteDatabase(artworkPath);
    await root.delete(recursive: true);
    await channel.invokeMethod<void>('options', {'androidThreadCount': 1});
  }
}

/// Compare bounded IN batches on the real guide without changing its schema.
Future<void> profileGuideBatchReads() async {
  final path = '${(await getApplicationSupportDirectory()).path}/vesper_epg.db';
  if (!await File(path).exists()) return;
  final db = await openDatabase(path, readOnly: true, singleInstance: false);
  try {
    final ids = (await db
            .rawQuery('SELECT DISTINCT channel_id FROM programme LIMIT 2000'))
        .map((r) => r['channel_id'])
        .toList();
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final hours in [4, 24]) {
      for (final size in [128, 500, 128, 500]) {
        final watch = Stopwatch()..start();
        var count = 0, calls = 0, checksum = 0;
        for (var offset = 0; offset < ids.length; offset += size) {
          final part = ids.skip(offset).take(size).toList();
          Object? cursorId, cursorStart;
          while (true) {
            final rows = await db.rawQuery(
                'SELECT channel_id,start,stop,title,substr(descr,1,320) AS descr,live '
                'FROM programme WHERE channel_id IN (${List.filled(part.length, '?').join(',')}) '
                'AND start < ? AND stop > ? '
                '${cursorId == null ? '' : 'AND channel_id >= ? AND (channel_id > ? OR start > ?) '}'
                'ORDER BY channel_id,start LIMIT 512',
                [
                  ...part,
                  now + hours * 3600000,
                  now,
                  if (cursorId != null) ...[cursorId, cursorId, cursorStart]
                ]);
            calls++;
            count += rows.length;
            for (final row in rows) {
              checksum ^= Object.hash(row['channel_id'], row['start'],
                  row['stop'], row['title'], row['descr'], row['live']);
            }
            if (rows.length < 512) break;
            cursorId = rows.last['channel_id'];
            cursorStart = rows.last['start'];
          }
        }
        // ignore: avoid_print
        print('IPTV_SQL_BATCH ${jsonEncode({
              'hours': hours,
              'batch': size,
              'rows': count,
              'calls': calls,
              'ms': watch.elapsedMilliseconds,
              'checksum': checksum
            })}');
      }
    }
  } finally {
    await db.close();
  }
}
