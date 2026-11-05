import 'sports_guide_search_index.dart';
import '../utils/sports_language.dart';
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
  EpgDatabase();

  /// Exercises query/failure paths against an existing SQLite connection,
  /// without changing normal database opening or recovery.
  @visibleForTesting
  EpgDatabase.withConnection(Database connection) : _db = connection;

  Database? _db;
  final _sportsSearch = SportsGuideSearchIndex();
  Future<void> _scopedTitleRead = Future<void>.value();

  Future<void> warmSportsSearch({bool Function()? cancelled}) async =>
      _sportsSearch.maintain(await _database, cancelled: cancelled);

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
    // Retain one native cursor. Repeating a sorted range query for every page
    // can repeatedly scan/sort the guide; bounded cursor transfers keep the UI
    // responsive without repeating the database work.
    final cursor = await db.rawQueryCursor(
        'SELECT channel_id, start, stop, title, descr, live FROM programme '
        'WHERE stop > ? AND start < ? ORDER BY channel_id,start',
        [fromMs, toMs],
        bufferSize: 512);
    final slice = Stopwatch()..start();
    try {
      while (await cursor.moveNext()) {
        final r = cursor.current;
        final id = r['channel_id'] as String;
        (result[id] ??= []).add((
          channelId: id,
          startMs: r['start'] as int,
          stopMs: r['stop'] as int,
          title: r['title'] as String,
          description: r['descr'] as String?,
          isLive: r['live'] == 1,
        ));
        if (slice.elapsedMilliseconds >= 2) {
          await Future<void>.delayed(Duration.zero);
          slice.reset();
        }
      }
    } finally {
      await cursor.close();
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
      // A retained cursor can lock SQLite's temporary schema, including other
      // requests' tables. Keep each title query's creation/read/cleanup together.
      // Other guide reads still run between this query's bounded transfers.
      final read = _scopedTitleRead
          .then((_) => _channelTitleMatches(fromMs, toMs, terms, channelIds));
      _scopedTitleRead =
          read.then<void>((_) {}, onError: (Object _, StackTrace __) {});
      return read;
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
        if (sportsTitleMatches(pattern, r['title'] as String)) {
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

  Future<String?> _titleChannelScope(
      Database db, String table, List<String> ids) async {
    try {
      await db.execute(
          'CREATE TEMP TABLE $table(id TEXT PRIMARY KEY) WITHOUT ROWID');
      // Bound both SQL parameters and each platform transfer. These IDs
      // are query-local; no insert IDs or transaction are needed. A failed
      // batch is discarded below before using the ordinary scoped cursor.
      const idsPerStatement = 500, statementsPerBatch = 8;
      for (var offset = 0;
          offset < ids.length;
          offset += idsPerStatement * statementsPerBatch) {
        final batch = db.batch();
        final end = (offset + idsPerStatement * statementsPerBatch)
            .clamp(0, ids.length);
        for (var at = offset; at < end; at += idsPerStatement) {
          final part = ids.sublist(at, (at + idsPerStatement).clamp(0, end));
          batch.rawInsert(
              'INSERT INTO $table VALUES ${List.filled(part.length, '(?)').join(',')}',
              part);
        }
        await batch.apply(noResult: true);
      }
      return table;
    } catch (_) {
      await db.execute('DROP TABLE IF EXISTS $table');
    }
    return null;
  }

  /// Sports can only play channels in the active catalogue. Seek those IDs
  /// through the primary key instead of transferring the entire provider guide
  /// to Dart and discarding unrelated channels in the matching worker later.
  /// Keep every overlapping slot, including long events starting before today.
  Future<List<EpgRow>> _channelTitleMatches(
      int fromMs, int toMs, List<String> terms, List<String> channelIds) async {
    final audit = const bool.fromEnvironment('IPTV_PROFILE_SPORTS')
        ? (Stopwatch()..start())
        : null;
    var rowsRead = 0, lastReport = 0;
    final uniqueIds = <String>{};
    final deduplication = Stopwatch()..start();
    for (var i = 0; i < channelIds.length; i++) {
      uniqueIds.add(channelIds[i]);
      if (i % 512 == 0 && deduplication.elapsedMilliseconds >= 2) {
        await Future<void>.delayed(Duration.zero);
        deduplication.reset();
      }
    }
    var ids = uniqueIds.toList();
    if (ids.isEmpty) return const [];
    final db = await _database;
    final result = <EpgRow>[];
    String? indexedTitles;
    final titles = <String, bool>{};
    String? scopedChannels;
    final slice = Stopwatch()..start();
    try {
      // Measuring a multi-day scope adds a potentially large scan of its own.
      // Keep the original dictionary path for those windows. Within one day,
      // actual row cardinality still decides whether deferring work is useful.
      final measureScope =
          toMs - fromMs <= const Duration(days: 1).inMilliseconds;
      final candidates = await _sportsSearch.candidates(db, terms,
          verifyProgrammes: measureScope
              ? (table, titleCount) async {
                  // One dictionary batch is already cheap. For larger sets, bound the
                  // probe by the amount of exact title work we would otherwise perform.
                  // Wide windows/duplicate broadcasts keep dictionary verification when
                  // they would transfer and check more programme rows than unique titles.
                  if (titleCount <= 1024) return false;
                  scopedChannels =
                      await _titleChannelScope(db, '${table}_channels', ids);
                  if (scopedChannels == null) return false;
                  final count = Sqflite.firstIntValue(await db.rawQuery(
                      'SELECT COUNT(*) FROM (SELECT 1 FROM programme '
                      'WHERE channel_id IN (SELECT id FROM $scopedChannels) '
                      'AND start < ? AND stop > ? '
                      'AND title IN (SELECT title FROM $table) LIMIT ?)',
                      [toMs, fromMs, titleCount + 1]))!;
                  return count <= titleCount;
                }
              : null);
      indexedTitles = candidates?.table;
      if (candidates != null && !candidates.hasMatches) {
        if (audit != null) {
          debugPrint(
              'IPTV_SQL_TITLE empty_dictionary elapsed_ms=${audit.elapsedMilliseconds}');
        }
        return const [];
      }
      if (indexedTitles != null && scopedChannels == null) {
        scopedChannels =
            await _titleChannelScope(db, '${indexedTitles}_channels', ids);
      }
      final verifyTitles = candidates?.verified != true;
      final pending = <Map<String, Object?>>[];
      Future<void> flush() async {
        if (pending.isEmpty) return;
        // Share the dictionary's bounded worker and language cache. Only title
        // strings cross isolates; cursors, programme rows and ordering stay here.
        final unknown = verifyTitles
            ? {
                for (final row in pending)
                  if (!titles.containsKey(row['title'])) row['title'] as String
              }
            : const <String>{};
        final matched = unknown.isEmpty
            ? const <String>{}
            : (await _sportsSearch.matchTitles(terms, unknown.toList()))
                .toSet();
        for (final row in pending) {
          final title = row['title'] as String;
          if (!verifyTitles || (titles[title] ?? matched.contains(title))) {
            result.add((
              channelId: row['channel_id'] as String,
              startMs: row['start'] as int,
              stopMs: row['stop'] as int,
              title: title,
              description: row['descr'] as String?,
              isLive: row['live'] == 1,
            ));
          }
        }
        // Cache query-local decisions only after consuming the whole batch, so
        // eviction cannot change a decision used by a later duplicate row.
        for (final title in unknown) {
          if (title.length > 1024) continue;
          if (titles.length >= 2048) {
            for (final key in titles.keys.take(512).toList(growable: false)) {
              titles.remove(key);
            }
          }
          titles[title] = matched.contains(title);
        }
        pending.clear();
      }

      // A single scoped cursor avoids hundreds of empty platform round trips
      // for selective searches. Bound parameters/transfers, not query count.
      // The indexed query orders the complete result in SQLite. Sorting its
      // large channel scope again on the UI isolate adds no ordering guarantee.
      // Only the fallback joins separately ordered channel chunks; preserve its
      // global order and move large sorts away from input/frame handling.
      if (scopedChannels == null) {
        if (ids.length > 1024) {
          try {
            ids = await compute(_sortGuideChannelIds, ids);
          } catch (_) {
            // An optional worker failure must not lose guide coverage.
            ids.sort();
          }
        } else {
          ids.sort();
        }
      }
      final chunk = scopedChannels == null ? 128 : ids.length;
      for (var offset = 0; offset < ids.length; offset += chunk) {
        final part = scopedChannels == null
            ? ids.skip(offset).take(chunk).toList()
            : <String>[];
        // Retain the native cursor between bounded transfers. Reissuing the
        // query for each page repeatedly seeks/scans the same channel schedules.
        // No transaction or additional connection; always release on failure.
        final cursor = await db.rawQueryCursor(
            'SELECT channel_id, start, stop, title, substr(descr,1,320) AS descr, live '
            'FROM programme WHERE channel_id IN (${scopedChannels == null ? List.filled(part.length, '?').join(',') : 'SELECT id FROM $scopedChannels'}) '
            'AND start < ? AND stop > ? '
            '${indexedTitles == null ? '' : 'AND title IN (SELECT title FROM $indexedTitles) '}'
            'ORDER BY channel_id,start',
            [...part, toMs, fromMs],
            bufferSize: 512);
        try {
          while (await cursor.moveNext()) {
            pending.add(cursor.current);
            if (pending.length == 512) await flush();
            if (audit != null) {
              rowsRead++;
              if (audit.elapsedMilliseconds - lastReport >= 2000) {
                lastReport = audit.elapsedMilliseconds;
                debugPrint(
                    'IPTV_SQL_TITLE cursor ids=$offset/${ids.length} rows=$rowsRead hits=${result.length} elapsed_ms=$lastReport');
              }
            }
            if (slice.elapsedMilliseconds >= 2) {
              await Future<void>.delayed(Duration.zero);
              slice.reset();
            }
          }
          await flush();
        } finally {
          await cursor.close();
        }
      }
    } finally {
      if (scopedChannels != null) {
        await db.execute('DROP TABLE IF EXISTS $scopedChannels');
      }
      if (indexedTitles != null) {
        await db.execute('DROP TABLE IF EXISTS $indexedTitles');
      }
    }
    if (audit != null) {
      debugPrint(
          'IPTV_SQL_TITLE done indexed=${indexedTitles != null} rows=$rowsRead hits=${result.length} elapsed_ms=${audit.elapsedMilliseconds}');
    }
    return result;
  }

  /// Distinct channel ids that still have any programme ending after
  /// [minStopMs] — the "does this channel have EPG at all" answer for
  /// callers that need it for every channel at once (auto-pair).
  Future<Set<String>> channelIdsWithData(int minStopMs) async {
    final db = await _database;
    final cursor = await db.rawQueryCursor(
        'SELECT DISTINCT channel_id FROM programme WHERE stop > ?', [minStopMs],
        bufferSize: 256);
    final ids = <String>{};
    final slice = Stopwatch()..start();
    try {
      while (await cursor.moveNext()) {
        ids.add(cursor.current['channel_id'] as String);
        // Release the native query queue between bounded cursor transfers so
        // visible rows need not wait for the entire guide directory.
        if (slice.elapsedMilliseconds >= 4) {
          await Future<void>.delayed(Duration.zero);
          slice.reset();
        }
      }
    } finally {
      await cursor.close();
    }
    return ids;
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

List<String> _sortGuideChannelIds(List<String> ids) => ids..sort();
