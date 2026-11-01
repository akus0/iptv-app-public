import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../models/archive_models.dart';

/// SQLite cache of Archive catalog rows, so the Archive tab's grid draws
/// at once from disk on startup and refreshes from the network behind it.
/// Its own file (`vesper_archive.db`), separate from `CatalogDatabase`:
/// nothing here belongs to a playlist, and everything is re-fetchable —
/// a database that won't open is simply deleted and rebuilt.
class ArchiveCache {
  Database? _db;
  static const _version = 1;

  Future<Database> get _database async {
    final existing = _db;
    if (existing != null) return existing;
    final dir = await getApplicationDocumentsDirectory();
    final path = p.join(dir.path, 'vesper_archive.db');
    try {
      _db = await _open(path);
    } catch (e) {
      debugPrint('ArchiveCache: reopening after ${e.runtimeType}');
      await deleteDatabase(path);
      _db = await _open(path);
    }
    return _db!;
  }

  Future<Database> _open(String path) => openDatabase(
        path,
        version: _version,
        onCreate: (db, _) async {
          await db.execute('''
            CREATE TABLE catalog_items (
              source_key TEXT NOT NULL,
              catalog_type TEXT NOT NULL,
              catalog_id TEXT NOT NULL,
              position INTEGER NOT NULL,
              meta_json TEXT NOT NULL,
              PRIMARY KEY (source_key, catalog_type, catalog_id, position)
            )''');
          await db.execute('''
            CREATE TABLE catalog_fetches (
              source_key TEXT NOT NULL,
              catalog_type TEXT NOT NULL,
              catalog_id TEXT NOT NULL,
              fetched_at INTEGER NOT NULL,
              PRIMARY KEY (source_key, catalog_type, catalog_id)
            )''');
        },
      );

  /// The cached rows of one catalog, in the source's order. Empty when
  /// never fetched.
  Future<List<ArchiveMeta>> read(
      String sourceKey, ArchiveCatalog catalog) async {
    final db = await _database;
    final rows = await db.query(
      'catalog_items',
      columns: ['meta_json'],
      where: 'source_key = ? AND catalog_type = ? AND catalog_id = ?',
      whereArgs: [sourceKey, catalog.wire, catalog.slug],
      orderBy: 'position',
    );
    final out = <ArchiveMeta>[];
    for (final r in rows) {
      try {
        final m = ArchiveMeta.fromJson(
            Map<String, dynamic>.from(jsonDecode(r['meta_json'] as String)),
            fallbackType: catalog.type,
            fallbackWire: catalog.wire);
        if (m != null) out.add(m);
      } catch (_) {
        // One bad row shouldn't hide the rest.
      }
    }
    return out;
  }

  /// When [catalog] was last saved, or null if never.
  Future<DateTime?> fetchedAt(String sourceKey, ArchiveCatalog catalog) async {
    final db = await _database;
    final rows = await db.query(
      'catalog_fetches',
      columns: ['fetched_at'],
      where: 'source_key = ? AND catalog_type = ? AND catalog_id = ?',
      whereArgs: [sourceKey, catalog.wire, catalog.slug],
    );
    if (rows.isEmpty) return null;
    return DateTime.fromMillisecondsSinceEpoch(rows.first['fetched_at'] as int);
  }

  /// Replaces one catalog's rows in a single transaction.
  Future<void> write(
      String sourceKey, ArchiveCatalog catalog, List<ArchiveMeta> items) async {
    final db = await _database;
    await db.transaction((txn) async {
      await txn.delete(
        'catalog_items',
        where: 'source_key = ? AND catalog_type = ? AND catalog_id = ?',
        whereArgs: [sourceKey, catalog.wire, catalog.slug],
      );
      final batch = txn.batch();
      for (var i = 0; i < items.length; i++) {
        batch.insert('catalog_items', {
          'source_key': sourceKey,
          'catalog_type': catalog.wire,
          'catalog_id': catalog.slug,
          'position': i,
          'meta_json': jsonEncode(items[i].toJson()),
        });
      }
      batch.insert(
        'catalog_fetches',
        {
          'source_key': sourceKey,
          'catalog_type': catalog.wire,
          'catalog_id': catalog.slug,
          'fetched_at': DateTime.now().millisecondsSinceEpoch,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      await batch.commit(noResult: true);
    });
  }

  /// Drops every cached row (Settings > Archive sources > Clear archives).
  Future<void> clear() async {
    final db = await _database;
    await db.delete('catalog_items');
    await db.delete('catalog_fetches');
  }

  /// Drops everything cached for a removed source.
  Future<void> deleteSource(String sourceKey) async {
    final db = await _database;
    await db.delete('catalog_items',
        where: 'source_key = ?', whereArgs: [sourceKey]);
    await db.delete('catalog_fetches',
        where: 'source_key = ?', whereArgs: [sourceKey]);
  }
}
