// Temporary synthetic databases only. Run before app.main opens any database.
// Never included in the normal application entry point.
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

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
