import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

/// One programme row as stored in [EpgDatabase] — times are epoch
/// milliseconds (UTC), so reading a row back never goes through
/// `DateTime.parse` (the old JSON cache paid ~430k of those per cold start).
typedef EpgRow = ({
  String channelId,
  int startMs,
  int stopMs,
  String title,
  String? description,
  bool isLive,
});

/// On-disk EPG store — replaces the single big JSON cache file that
/// `EpgService.init()` used to fully decode on every cold start (measured
/// ~58 s on a Formuler before the guide appeared). The guide is now only
/// ever *queried* for the channels actually on screen, the same way the
/// VOD/series catalog moved into [CatalogDatabase].
///
/// Only a rolling window is kept (see `AppConstants.epgPastRetention` /
/// `epgFutureWindow`) — the past side is a constant on purpose so a later
/// catch-up feature can simply widen it.
///
/// Fully re-derivable from the EPG URLs, so a database that won't open is
/// deleted and recreated rather than surfaced as an error.
class EpgDatabase {
  Database? _db;

  Future<Database> get _database async {
    final existing = _db;
    if (existing != null) return existing;
    // Application *support* dir, not the temporary/cache dir the old JSON
    // file lived in: Android may purge the cache dir at any time, which
    // left the guide empty until the next refresh.
    final dir = await getApplicationSupportDirectory();
    final path = p.join(dir.path, 'vesper_epg.db');
    try {
      _db = await _open(path);
    } catch (e) {
      debugPrint('EpgDatabase: reopening from scratch after ${e.runtimeType}');
      await deleteDatabase(path);
      _db = await _open(path);
    }
    return _db!;
  }

  Future<Database> _open(String path) => openDatabase(
        path,
        version: 2,
        onUpgrade: (db, oldVersion, newVersion) async {
          if (oldVersion < 2) {
            await db.execute(
                'ALTER TABLE programme ADD COLUMN live INTEGER NOT NULL DEFAULT 0');
          }
        },
        onCreate: (db, version) async {
          // (channel_id, start) is the natural key and also exactly the
          // lookup every read does — WITHOUT ROWID stores rows in that
          // order, so "programmes for these channels" is an index range
          // scan with no extra table lookup.
          await db.execute('''
            CREATE TABLE programme (
              channel_id TEXT NOT NULL,
              start INTEGER NOT NULL,
              stop INTEGER NOT NULL,
              title TEXT NOT NULL,
              descr TEXT,
              live INTEGER NOT NULL DEFAULT 0,
              source_url TEXT NOT NULL,
              gen INTEGER NOT NULL,
              PRIMARY KEY (channel_id, start)
            ) WITHOUT ROWID
          ''');
          await db
              .execute('CREATE INDEX idx_programme_stop ON programme(stop)');
          await db.execute(
              'CREATE INDEX idx_programme_source ON programme(source_url, gen)');
        },
      );

  Future<void> open() async => _database;

  /// Every programme for [channelIds] that hasn't ended before [minStopMs],
  /// ordered by channel then start. Chunked to stay under SQLite's bound
  /// parameter limit.
  Future<Map<String, List<EpgRow>>> programmesFor(
      List<String> channelIds, int minStopMs) async {
    final db = await _database;
    final result = <String, List<EpgRow>>{};
    const chunk = 500;
    for (var i = 0; i < channelIds.length; i += chunk) {
      final ids = channelIds.sublist(
          i, i + chunk > channelIds.length ? channelIds.length : i + chunk);
      final placeholders = List.filled(ids.length, '?').join(',');
      final rows = await db.rawQuery(
        'SELECT channel_id, start, stop, title, descr, live FROM programme '
        'WHERE channel_id IN ($placeholders) AND stop > ? '
        'ORDER BY channel_id, start',
        [...ids, minStopMs],
      );
      for (final r in rows) {
        final id = r['channel_id'] as String;
        (result[id] ??= []).add((
          channelId: id,
          startMs: r['start'] as int,
          stopMs: r['stop'] as int,
          title: r['title'] as String,
          description: r['descr'] as String?,
          isLive: r['live'] == 1,
        ));
      }
    }
    return result;
  }

  /// Every channel's programmes overlapping [fromMs, toMs) — the small
  /// "now / next" slice `EpgService` preloads for *all* channels at startup
  /// (a few rows per channel instead of the whole window).
  Future<Map<String, List<EpgRow>>> programmesBetween(
      int fromMs, int toMs) async {
    final db = await _database;
    final result = <String, List<EpgRow>>{};
    String? afterChannel;
    int? afterStart;
    // Bound each platform-channel response so a large guide cannot monopolise
    // the UI isolate while decoding one enormous SQLite result.
    const pageSize = 512;
    while (true) {
      final rows = await db.rawQuery(
        'SELECT channel_id, start, stop, title, descr, live FROM programme '
        'WHERE stop > ? AND start < ? '
        '${afterChannel == null ? '' : 'AND (channel_id, start) > (?, ?) '}'
        'ORDER BY channel_id, start LIMIT ?',
        [
          fromMs,
          toMs,
          if (afterChannel != null) ...[afterChannel, afterStart],
          pageSize
        ],
      );
      for (final r in rows) {
        final id = r['channel_id'] as String;
        (result[id] ??= []).add((
          channelId: id,
          startMs: r['start'] as int,
          stopMs: r['stop'] as int,
          title: r['title'] as String,
          description: r['descr'] as String?,
          isLive: r['live'] == 1,
        ));
      }
      if (rows.length < pageSize) break;
      afterChannel = rows.last['channel_id'] as String;
      afterStart = rows.last['start'] as int;
      await Future<void>.delayed(Duration.zero);
    }
    return result;
  }

  /// One indexed, paged pass through the overlapping guide. Hundreds of
  /// SQL LIKE alternatives caused long blocking queries on Android TVs. Match
  /// literal keywords with one compiled expression instead, yielding between
  /// pages. Keyset pagination also avoids rescanning earlier pages (OFFSET).
  Future<List<EpgRow>> programmesStartingWithTitle(
      int fromMs, int toMs, List<String> terms,
      {List<String>? channelIds}) async {
    if (terms.isEmpty || fromMs >= toMs) return const [];
    if (channelIds != null) {
      return _channelTitleMatches(fromMs, toMs, terms, channelIds);
    }
    final pattern = RegExp(terms.toSet().map(RegExp.escape).join('|'),
        caseSensitive: false);
    final db = await _database;
    final result = <EpgRow>[];
    const pageSize = 512;
    // Scalar comparisons keep this compatible with older Android SQLite.
    // Repeat the stop lower bound explicitly so the planner seeks into its
    // index rather than evaluating the cursor after scanning previous pages.
    List<Object?>? cursor;
    final slice = Stopwatch()..start();
    while (true) {
      final rows = await db.rawQuery(
        'SELECT channel_id, start, stop, title, substr(descr, 1, 320) AS descr, live '
        'FROM programme WHERE stop ${cursor == null ? '>' : '>='} ? AND start < ? '
        '${cursor == null ? '' : 'AND (stop > ? OR (stop = ? AND (channel_id > ? OR (channel_id = ? AND start > ?)))) '}'
        'ORDER BY stop, channel_id, start LIMIT $pageSize',
        [
          cursor == null ? fromMs : cursor.first,
          toMs,
          if (cursor != null) ...[
            cursor[0],
            cursor[0],
            cursor[1],
            cursor[1],
            cursor[2]
          ],
        ],
      );
      for (final r in rows) {
        if (pattern.hasMatch(r['title'] as String)) {
          result.add((
            channelId: r['channel_id'] as String,
            startMs: r['start'] as int,
            stopMs: r['stop'] as int,
            title: r['title'] as String,
            description: r['descr'] as String?,
            isLive: r['live'] == 1,
          ));
        }
        if (slice.elapsedMilliseconds >= 4) {
          await Future<void>.delayed(Duration.zero);
          slice.reset();
        }
      }
      if (rows.length < pageSize) break;
      final last = rows.last;
      cursor = [last['stop'], last['channel_id'], last['start']];
      await Future<void>.delayed(Duration.zero);
      slice.reset();
    }
    return result;
  }

  /// Sports can only play channels in the active catalogue. Seek those IDs
  /// through the primary key instead of transferring the entire provider guide
  /// to Dart and discarding unrelated channels in the matching worker later.
  /// Keep every overlapping slot, including long events starting before today.
  Future<List<EpgRow>> _channelTitleMatches(
      int fromMs, int toMs, List<String> terms, List<String> channelIds) async {
    final ids = channelIds.toSet().toList()..sort();
    if (ids.isEmpty) return const [];
    final pattern = RegExp(terms.toSet().map(RegExp.escape).join('|'),
        caseSensitive: false);
    final db = await _database;
    final result = <EpgRow>[];
    // Regional/quality variants repeat the same titles thousands of times.
    // Cache both hits and misses for this query only; guide edits, terms and
    // time windows cannot reuse an old decision. Bound retained strings on TVs.
    final titles = <String, bool>{};
    final slice = Stopwatch()..start();
    for (var offset = 0; offset < ids.length; offset += 128) {
      final part = ids.skip(offset).take(128).toList();
      String? afterChannel;
      int? afterStart;
      while (true) {
        final rows = await db.rawQuery(
            'SELECT channel_id, start, stop, title, substr(descr,1,320) AS descr, live '
            'FROM programme WHERE channel_id IN (${List.filled(part.length, '?').join(',')}) '
            'AND start < ? AND stop > ? '
            '${afterChannel == null ? '' : 'AND channel_id >= ? AND (channel_id > ? OR start > ?) '}'
            'ORDER BY channel_id,start LIMIT 512',
            [
              ...part,
              toMs,
              fromMs,
              if (afterChannel != null) afterChannel,
              if (afterChannel != null) afterChannel,
              if (afterChannel != null) afterStart
            ]);
        for (final row in rows) {
          final title = row['title'] as String;
          var matches = titles[title];
          if (matches == null) {
            matches = pattern.hasMatch(title);
            if (titles.length >= 2048) titles.clear();
            if (title.length <= 1024) titles[title] = matches;
          }
          if (matches) {
            result.add((
              channelId: row['channel_id'] as String,
              startMs: row['start'] as int,
              stopMs: row['stop'] as int,
              title: row['title'] as String,
              description: row['descr'] as String?,
              isLive: row['live'] == 1
            ));
          }
          if (slice.elapsedMilliseconds >= 2) {
            await Future<void>.delayed(Duration.zero);
            slice.reset();
          }
        }
        if (rows.length < 512) break;
        afterChannel = rows.last['channel_id'] as String;
        afterStart = rows.last['start'] as int;
        await Future<void>.delayed(Duration.zero);
        slice.reset();
      }
    }
    return result;
  }

  /// Distinct channel ids that still have any programme ending after
  /// [minStopMs] — the "does this channel have EPG at all" answer for
  /// callers that need it for every channel at once (auto-pair).
  Future<Set<String>> channelIdsWithData(int minStopMs) async {
    final db = await _database;
    final rows = await db.rawQuery(
        'SELECT DISTINCT channel_id FROM programme WHERE stop > ?',
        [minStopMs]);
    return {for (final r in rows) r['channel_id'] as String};
  }

  /// Narrow ID/time lookup for tennis feeds whose generic titles contain no
  /// player names. Uses the existing channel/start primary key, not descr LIKE
  /// across the entire guide. Limits also bound malformed provider schedules.
  Future<List<EpgRow>> programmesForSportsChannels(
      List<String> ids, int fromMs, int toMs) async {
    final db = await _database;
    final result = <EpgRow>[];
    final bounded = ids.take(512).toList();
    for (var i = 0; i < bounded.length && result.length < 4096; i += 128) {
      final part = bounded.skip(i).take(128).toList();
      final rows = await db.rawQuery(
          'SELECT channel_id, start, stop, title, substr(descr,1,640) AS descr, live '
          'FROM programme WHERE channel_id IN (${List.filled(part.length, '?').join(',')}) '
          'AND start < ? AND start >= ? AND stop > ? '
          'ORDER BY channel_id,start LIMIT ?',
          [...part, toMs, fromMs - 86400000, fromMs, 4096 - result.length]);
      for (final r in rows) {
        result.add((
          channelId: r['channel_id'] as String,
          startMs: r['start'] as int,
          stopMs: r['stop'] as int,
          title: r['title'] as String,
          description: r['descr'] as String?,
          isLive: r['live'] == 1
        ));
      }
    }
    return result;
  }

  Future<bool> isEmpty() async {
    final db = await _database;
    final rows = await db.rawQuery('SELECT 1 FROM programme LIMIT 1');
    return rows.isEmpty;
  }

  /// Writes one batch of parsed rows in a single transaction. A re-sent
  /// programme (same channel + start) replaces the old row and takes the
  /// new [gen], which is what [deleteStaleFromSource] keys off.
  ///
  /// Two *different* sources covering the same channel + start overwrite
  /// each other's row ("last refresh wins") — harmless for display, and
  /// either source's next refresh puts its own version back.
  ///
  /// Keep batches small (~1000 rows): sqflite has one connection, so a
  /// long commit would stall the guide's reads behind it.
  Future<void> insertBatch(List<EpgRow> rows, String sourceUrl, int gen) async {
    if (rows.isEmpty) return;
    final db = await _database;
    final batch = db.batch();
    for (final r in rows) {
      batch.rawInsert(
        'INSERT OR REPLACE INTO programme '
        '(channel_id, start, stop, title, descr, live, source_url, gen) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
        [
          r.channelId,
          r.startMs,
          r.stopMs,
          r.title,
          r.description,
          r.isLive ? 1 : 0,
          sourceUrl,
          gen
        ],
      );
    }
    await batch.commit(noResult: true);
  }

  /// After a *successful* refresh of [sourceUrl]: drops every row that
  /// source wrote in an earlier refresh but didn't re-send this time
  /// (channel removed from the feed, programme rescheduled). Never touches
  /// another source's rows. A failed/aborted refresh skips this, so the
  /// previous data survives a network error.
  Future<void> deleteStaleFromSource(String sourceUrl, int gen) async {
    final db = await _database;
    await db.delete('programme',
        where: 'source_url = ? AND gen <> ?', whereArgs: [sourceUrl, gen]);
  }

  /// Rolling-window trim: drops programmes that ended before [minStopMs].
  Future<void> deleteEndedBefore(int minStopMs) async {
    final db = await _database;
    await db.delete('programme', where: 'stop < ?', whereArgs: [minStopMs]);
  }

  Future<void> clearAll() async {
    final db = await _database;
    await db.delete('programme');
  }
}
