import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../models/channel.dart';
import '../models/xtream_series.dart';

/// On-disk VOD/series catalogue queried on demand by category. This avoids deserializing
/// every cached title on startup; live channels retain their separate cache.
enum LibrarySort { provider, newest, name }

class LibraryPage {
  const LibraryPage(
      {this.movies = const [], this.series = const [], required this.total});
  final List<Channel> movies;
  final List<XtreamSeries> series;
  final int total;
}

class CatalogDatabase {
  Database? _db;

  /// Stamp favourites from the active viewer's current id sets when reading rows. A persisted
  /// single is_favorite bit cannot represent multiple viewers; use it only when no lookup is
  /// installed.
  bool Function(String channelId)? isVodFavorite;
  bool Function(String seriesId)? isSeriesFavorite;

  Future<Database>? _opening;
  Future<Database> get _database {
    final existing = _db;
    if (existing != null) return Future.value(existing);
    return _opening ??= _openDatabase().whenComplete(() => _opening = null);
  }

  Future<Database> _openDatabase() async {
    final dir = await getApplicationDocumentsDirectory();
    final path = p.join(dir.path, 'nox_catalog.db');
    try {
      _db = await _open(path);
    } catch (e) {
      // Everything in here is re-derivable from the provider, so a
      // database that won't open is worth strictly less than the cost of
      // not opening it: every catalog read for every playlist fails, and
      // it surfaces as categories that load forever rather than as
      // anything that looks like a storage problem. Start over instead.
      debugPrint('CatalogDatabase: reopening from scratch after ${e.runtimeType}');
      await deleteDatabase(path);
      _db = await _open(path);
    }
    return _db!;
  }

  Future<Database> _open(String path) async {
    final db = await openDatabase(
      path,
      version: 10,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE vod_channels (
            id TEXT PRIMARY KEY,
            playlist_id TEXT NOT NULL,
            category_name TEXT NOT NULL,
            name TEXT NOT NULL,
            url TEXT NOT NULL,
            logo_url TEXT,
            subtitle_url TEXT,
            is_favorite INTEGER NOT NULL DEFAULT 0,
            rating TEXT,
            added_at INTEGER,
            series_id INTEGER,
            series_name TEXT,
            series_cover_url TEXT,
            tmdb_id TEXT,
            release_date INTEGER,
            poster_url TEXT,
            backdrop_url TEXT,
            provider_poster_url TEXT,
            provider_backdrop_url TEXT
          )
        ''');
        await db.execute(
            'CREATE INDEX idx_vod_category ON vod_channels(category_name)');
        await db.execute(
            'CREATE INDEX idx_vod_playlist ON vod_channels(playlist_id)');

        await db.execute('''
          CREATE TABLE series_items (
            id TEXT PRIMARY KEY,
            series_id INTEGER NOT NULL,
            playlist_id TEXT NOT NULL,
            category_name TEXT NOT NULL,
            name TEXT NOT NULL,
            cover_url TEXT,
            is_favorite INTEGER NOT NULL DEFAULT 0,
            rating TEXT,
            added_at INTEGER,
            tmdb_id TEXT,
            release_date INTEGER,
            poster_url TEXT,
            backdrop_url TEXT,
            provider_backdrop_url TEXT
          )
        ''');
        await db.execute(
            'CREATE INDEX idx_series_category ON series_items(category_name)');
        await db.execute(
            'CREATE INDEX idx_series_playlist ON series_items(playlist_id)');
        await _createLibraryIndexes(db);
      },
      // v1 -> v2 adds series ratings. v2 -> v3 rebuilds this re-fetchable
      // cache for playlist-scoped IDs. Later nullable columns use ALTER TABLE
      // to retain cached content and avoid a forced full catalogue download.
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await db.execute('ALTER TABLE series_items ADD COLUMN rating TEXT');
        }
        if (oldVersion < 3) {
          await db.execute('DROP TABLE IF EXISTS vod_channels');
          await db.execute('DROP TABLE IF EXISTS series_items');
          await db.execute('''
            CREATE TABLE vod_channels (
              id TEXT PRIMARY KEY,
              playlist_id TEXT NOT NULL,
              category_name TEXT NOT NULL,
              name TEXT NOT NULL,
              url TEXT NOT NULL,
              logo_url TEXT,
              subtitle_url TEXT,
              is_favorite INTEGER NOT NULL DEFAULT 0,
              rating TEXT,
              series_id INTEGER,
              series_name TEXT,
              series_cover_url TEXT
            )
          ''');
          await db.execute(
              'CREATE INDEX idx_vod_category ON vod_channels(category_name)');
          await db.execute(
              'CREATE INDEX idx_vod_playlist ON vod_channels(playlist_id)');
          await db.execute('''
            CREATE TABLE series_items (
              id TEXT PRIMARY KEY,
              series_id INTEGER NOT NULL,
              playlist_id TEXT NOT NULL,
              category_name TEXT NOT NULL,
              name TEXT NOT NULL,
              cover_url TEXT,
              is_favorite INTEGER NOT NULL DEFAULT 0,
              rating TEXT
            )
          ''');
          await db.execute(
              'CREATE INDEX idx_series_category ON series_items(category_name)');
          await db.execute(
              'CREATE INDEX idx_series_playlist ON series_items(playlist_id)');
        }
        if (oldVersion < 4) {
          // Re-runnable on purpose. A migration that throws takes the
          // whole database open down with it, and every catalog read for
          // every playlist with it — which presents as categories that
          // never finish loading rather than as anything database-shaped.
          // This one can genuinely find the column already there: an
          // earlier build of this same version did a drop + recreate that
          // created the tables *with* `added_at`, and a process killed
          // between that statement and sqflite committing the new version
          // number leaves exactly that state behind.
          await _addColumnIfMissing(db, 'vod_channels', 'added_at', 'INTEGER');
          await _addColumnIfMissing(db, 'series_items', 'added_at', 'INTEGER');
        }
        if (oldVersion < 5) {
          // Channel.tmdbId/releaseDate — see their doc comments. Plain
          // ALTER TABLE ADD COLUMN, same reasoning as v3 -> v4: no
          // structural change, every existing row just gets these as
          // NULL, which the enrichment lookup already treats as "hasn't
          // run for this item yet" rather than anything needing a backfill
          // migration of its own.
          await _addColumnIfMissing(db, 'vod_channels', 'tmdb_id', 'TEXT');
          await _addColumnIfMissing(
              db, 'vod_channels', 'release_date', 'INTEGER');
          await _addColumnIfMissing(db, 'series_items', 'tmdb_id', 'TEXT');
          await _addColumnIfMissing(
              db, 'series_items', 'release_date', 'INTEGER');
        }
        if (oldVersion < 6) {
          // Channel.posterUrl — same reasoning as v4 -> v5 just above.
          await _addColumnIfMissing(db, 'vod_channels', 'poster_url', 'TEXT');
          await _addColumnIfMissing(db, 'series_items', 'poster_url', 'TEXT');
        }
        if (oldVersion < 7) {
          // Channel.backdropUrl — same reasoning as v5 -> v6 just above.
          await _addColumnIfMissing(db, 'vod_channels', 'backdrop_url', 'TEXT');
          await _addColumnIfMissing(db, 'series_items', 'backdrop_url', 'TEXT');
        }
        if (oldVersion < 8) {
          // Channel.providerPosterUrl/providerBackdropUrl and
          // XtreamSeries.providerBackdropUrl (keyless provider HD art) —
          // same plain nullable ADD COLUMN as v6 -> v7.
          await _addColumnIfMissing(
              db, 'vod_channels', 'provider_poster_url', 'TEXT');
          await _addColumnIfMissing(
              db, 'vod_channels', 'provider_backdrop_url', 'TEXT');
          await _addColumnIfMissing(
              db, 'series_items', 'provider_backdrop_url', 'TEXT');
        }
        if (oldVersion < 9) await _createLibraryIndexes(db);
        if (oldVersion >= 9 && oldVersion < 10) {
          await _createProviderOrderIndexes(db);
        }
      },
    );
    return db;
  }

  // SQLite indexes include rowid implicitly. This narrow index filters the
  // source/category while retaining provider order, without scanning other
  // categories or sorting a whole category for each 60-title page.
  static Future<void> _createProviderOrderIndexes(Database db) async {
    for (final table in ['vod_channels', 'series_items']) {
      await db.execute('CREATE INDEX IF NOT EXISTS idx_${table}_provider '
          'ON $table(playlist_id, category_name)');
    }
  }

  static Future<void> _createLibraryIndexes(Database db) async {
    await _createProviderOrderIndexes(db);
    for (final table in ['vod_channels', 'series_items']) {
      await db.execute('CREATE INDEX IF NOT EXISTS idx_${table}_browse '
          'ON $table(playlist_id, category_name, name COLLATE NOCASE, id)');
      await db.execute('CREATE INDEX IF NOT EXISTS idx_${table}_recent '
          'ON $table(playlist_id, category_name, added_at DESC, id)');
    }
  }

  /// `ALTER TABLE ... ADD COLUMN` has no `IF NOT EXISTS` in SQLite, and
  /// adding one that's already there throws. Asking the table what it has
  /// first is the only way to make the step idempotent.
  static Future<void> _addColumnIfMissing(
      Database db, String table, String column, String type) async {
    final columns = await db.rawQuery('PRAGMA table_info($table)');
    final exists = columns.any((c) => c['name'] == column);
    if (exists) return;
    await db.execute('ALTER TABLE $table ADD COLUMN $column $type');
  }

  Map<String, Object?> _channelToRow(String categoryName, Channel c) => {
        'id': c.id,
        'playlist_id': c.playlistId,
        'category_name': categoryName,
        'name': c.name,
        'url': c.url,
        'logo_url': c.logoUrl,
        'subtitle_url': c.subtitleUrl,
        'is_favorite': c.isFavorite ? 1 : 0,
        'rating': c.rating,
        'added_at': c.addedAt?.millisecondsSinceEpoch,
        'series_id': c.seriesId,
        'series_name': c.seriesName,
        'series_cover_url': c.seriesCoverUrl,
        'tmdb_id': c.tmdbId,
        'release_date': c.releaseDate?.millisecondsSinceEpoch,
        'poster_url': c.posterUrl,
        'backdrop_url': c.backdropUrl,
        'provider_poster_url': c.providerPosterUrl,
        'provider_backdrop_url': c.providerBackdropUrl,
      };

  Channel _rowToChannel(Map<String, Object?> row) {
    final id = row['id'] as String;
    final playlistId = row['playlist_id'] as String;
    // Strip the playlist prefix back off — same '$playlistId::$rawId'
    // scheme every id is built with (see Channel.playlistId's doc
    // comment); only the first '::' matters, playlist ids don't contain
    // the delimiter themselves.
    final prefix = '$playlistId::';
    final rawId = id.startsWith(prefix) ? id.substring(prefix.length) : id;
    final addedAt = row['added_at'] as int?;
    final releaseDate = row['release_date'] as int?;
    return Channel(
      id: id,
      rawId: rawId,
      playlistId: playlistId,
      name: row['name'] as String,
      group: row['category_name'] as String,
      url: row['url'] as String,
      logoUrl: row['logo_url'] as String?,
      subtitleUrl: row['subtitle_url'] as String?,
      isFavorite: isVodFavorite?.call(id) ?? (row['is_favorite'] as int) == 1,
      rating: row['rating'] as String?,
      addedAt:
          addedAt != null ? DateTime.fromMillisecondsSinceEpoch(addedAt) : null,
      seriesId: row['series_id'] as int?,
      seriesName: row['series_name'] as String?,
      seriesCoverUrl: row['series_cover_url'] as String?,
      tmdbId: row['tmdb_id'] as String?,
      releaseDate: releaseDate != null
          ? DateTime.fromMillisecondsSinceEpoch(releaseDate)
          : null,
      posterUrl: row['poster_url'] as String?,
      backdropUrl: row['backdrop_url'] as String?,
      providerPosterUrl: row['provider_poster_url'] as String?,
      providerBackdropUrl: row['provider_backdrop_url'] as String?,
    );
  }

  Map<String, Object?> _seriesToRow(String categoryName, XtreamSeries s) => {
        'id': s.id,
        'series_id': s.seriesId,
        'playlist_id': s.playlistId,
        'category_name': categoryName,
        'name': s.name,
        'cover_url': s.coverUrl,
        'is_favorite': s.isFavorite ? 1 : 0,
        'rating': s.rating,
        'added_at': s.addedAt?.millisecondsSinceEpoch,
        'tmdb_id': s.tmdbId,
        'release_date': s.releaseDate?.millisecondsSinceEpoch,
        'poster_url': s.posterUrl,
        'backdrop_url': s.backdropUrl,
        'provider_backdrop_url': s.providerBackdropUrl,
      };

  XtreamSeries _rowToSeries(Map<String, Object?> row) {
    final addedAt = row['added_at'] as int?;
    final releaseDate = row['release_date'] as int?;
    final id = row['id'] as String;
    return XtreamSeries(
      seriesId: row['series_id'] as int,
      playlistId: row['playlist_id'] as String,
      name: row['name'] as String,
      categoryId: row['category_name'] as String,
      coverUrl: row['cover_url'] as String?,
      isFavorite:
          isSeriesFavorite?.call(id) ?? (row['is_favorite'] as int) == 1,
      rating: row['rating'] as String?,
      addedAt:
          addedAt != null ? DateTime.fromMillisecondsSinceEpoch(addedAt) : null,
      tmdbId: row['tmdb_id'] as String?,
      releaseDate: releaseDate != null
          ? DateTime.fromMillisecondsSinceEpoch(releaseDate)
          : null,
      posterUrl: row['poster_url'] as String?,
      backdropUrl: row['backdrop_url'] as String?,
      providerBackdropUrl: row['provider_backdrop_url'] as String?,
    );
  }

  /// Replaces (not merges) a category's rows — a re-fetch (e.g. "Update
  /// Content") should fully reflect the provider's current item list, not
  /// leave stale rows behind for items the provider removed. Scoped by
  /// `(category_name, playlist_id)` together — deleting by category name
  /// alone would also wipe a different playlist's same-named category.
  Future<void> upsertVodCategory(
      String playlistId, String categoryName, List<Channel> items) async {
    final db = await _database;
    await db.transaction((txn) async {
      await txn.delete('vod_channels',
          where: 'category_name = ? AND playlist_id = ?',
          whereArgs: [categoryName, playlistId]);
      for (var start = 0; start < items.length; start += 200) {
        final batch = txn.batch();
        for (final c in items.skip(start).take(200)) {
          batch.insert('vod_channels', _channelToRow(categoryName, c),
              conflictAlgorithm: ConflictAlgorithm.replace);
        }
        await batch.commit(noResult: true);
      }
    });
  }

  Future<List<Channel>> getVodCategory(String playlistId, String categoryName,
      {int? limit}) async {
    final db = await _database;
    final rows = await db.query('vod_channels',
        where: 'category_name = ? AND playlist_id = ?',
        whereArgs: [categoryName, playlistId],
        limit: limit);
    return rows.map(_rowToChannel).toList();
  }

  /// The category's *real* item count, ignoring [getVodCategory]'s
  /// `limit` — used so the UI can show a category's true size (a
  /// provider's actual "5,000 movies in this one category" figure)
  /// instead of the display-side render cap, which callers otherwise
  /// have no way to distinguish from the true count (both look like
  /// "here are some items", nothing says "there were more").
  Future<int> getVodCategoryCount(
      String playlistId, String categoryName) async {
    final db = await _database;
    final result = await db.rawQuery(
        'SELECT COUNT(*) AS cnt FROM vod_channels WHERE category_name = ? AND playlist_id = ?',
        [categoryName, playlistId]);
    return Sqflite.firstIntValue(result) ?? 0;
  }

  /// SQL does filtering and ordering before materializing at most one page.
  /// Stable tie-breakers prevent repeats/skips between pages of equal names.
  Future<LibraryPage> libraryPage(
      {required String playlistId,
      required String category,
      required bool series,
      String query = '',
      LibrarySort sort = LibrarySort.provider,
      int offset = 0,
      int limit = 60}) async {
    final db = await _database;
    final table = series ? 'series_items' : 'vod_channels';
    final escaped = query
        .trim()
        .replaceAll('\\', '\\\\')
        .replaceAll('%', '\\%')
        .replaceAll('_', '\\_');
    final where = 'playlist_id = ? AND category_name = ?'
        "${escaped.isEmpty ? '' : " AND name LIKE ? ESCAPE '\\'"}";
    final args = <Object>[
      playlistId,
      category,
      if (escaped.isNotEmpty) '%$escaped%'
    ];
    final order = switch (sort) {
      LibrarySort.provider => 'rowid',
      LibrarySort.newest => 'added_at DESC, id',
      LibrarySort.name => 'name COLLATE NOCASE, id',
    };
    return db.transaction((txn) async {
      final count = Sqflite.firstIntValue(await txn.rawQuery(
              'SELECT COUNT(*) FROM $table WHERE $where', args)) ??
          0;
      final rows = await txn.query(table,
          where: where,
          whereArgs: args,
          orderBy: order,
          offset: offset < 0 ? 0 : offset,
          limit: limit.clamp(1, 120));
      return LibraryPage(
          total: count,
          movies: series ? const [] : rows.map(_rowToChannel).toList(),
          series: series ? rows.map(_rowToSeries).toList() : const []);
    });
  }

  /// Search the persisted catalogue in SQL, including categories not loaded into memory.
  /// In-memory browse limits must not restrict search results.
  Future<List<Channel>> searchVod(String query, List<String> playlistIds,
      {int limit = 200}) async {
    if (playlistIds.isEmpty) return [];
    final db = await _database;
    final placeholders = List.filled(playlistIds.length, '?').join(', ');
    final rows = await db.query(
      'vod_channels',
      where: 'name LIKE ? AND playlist_id IN ($placeholders)',
      whereArgs: ['%$query%', ...playlistIds],
      limit: limit,
    );
    return rows.map(_rowToChannel).toList();
  }

  /// Looks up specific VOD items by their composite [Channel.id] —
  /// `PlaylistManager`'s curated "What's New" selection persists an
  /// ordered id list (see `AppConstants.keyWhatsNewVodIds`'s doc
  /// comment), not full `Channel` objects, and the matched item's own
  /// category might not even be loaded into memory this session (it was
  /// matched via a full-catalog [searchVod], independent of what's
  /// currently warmed) — this is the DB-level read that list needs to
  /// become real `Channel`s again. Result order is *not* guaranteed to
  /// match [ids]' order (SQL `IN` doesn't promise that) — callers that
  /// care re-order by id themselves.
  Future<List<Channel>> getVodByIds(List<String> ids) async {
    if (ids.isEmpty) return [];
    final db = await _database;
    final placeholders = List.filled(ids.length, '?').join(', ');
    final rows = await db.query('vod_channels',
        where: 'id IN ($placeholders)', whereArgs: ids);
    return rows.map(_rowToChannel).toList();
  }

  /// Category-name substrings the "What's New" carousel refuses to
  /// surface, however recently something in them was added — an
  /// auto-playing slideshow the user didn't ask to browse into is a
  /// different thing from the category existing at all, so this doesn't
  /// hide the category itself (see `PlaylistSession.hiddenGroups` for
  /// that, a separate, deliberate per-category opt-out) — it just keeps
  /// this one uninvited surface from dipping into it. SQLite's `LIKE` is
  /// already case-insensitive for plain ASCII text like these.
  static const _adultCategoryKeywords = ['XXX', 'ADULT', 'PORN', '18+'];

  static String _excludeAdultCategoriesClause() => _adultCategoryKeywords
      .map((_) => 'category_name NOT LIKE ?')
      .join(' AND ');

  static List<String> _excludeAdultCategoriesArgs() =>
      _adultCategoryKeywords.map((k) => '%$k%').toList();

  /// The newest movies the provider has, newest first — what the TV
  /// layout's "What's New" carousel shows. Scoped to [playlistIds] (the
  /// currently-enabled ones) exactly like [searchVod]; rows with no
  /// `added_at` are skipped outright rather than sorted as if they were
  /// ancient, so a provider that doesn't report the field contributes
  /// nothing here instead of filling the carousel with arbitrary titles.
  Future<List<Channel>> getRecentlyAddedVod(List<String> playlistIds,
      {int limit = 5}) async {
    if (playlistIds.isEmpty) return [];
    final db = await _database;
    final placeholders = List.filled(playlistIds.length, '?').join(', ');
    final rows = await db.query(
      'vod_channels',
      where: 'playlist_id IN ($placeholders) AND added_at IS NOT NULL'
          ' AND ${_excludeAdultCategoriesClause()}',
      whereArgs: [...playlistIds, ..._excludeAdultCategoriesArgs()],
      orderBy: 'added_at DESC',
      limit: limit,
    );
    return rows.map(_rowToChannel).toList();
  }

  Future<void> upsertSeriesCategory(
      String playlistId, String categoryName, List<XtreamSeries> items) async {
    final db = await _database;
    await db.transaction((txn) async {
      await txn.delete('series_items',
          where: 'category_name = ? AND playlist_id = ?',
          whereArgs: [categoryName, playlistId]);
      for (var start = 0; start < items.length; start += 200) {
        final batch = txn.batch();
        for (final s in items.skip(start).take(200)) {
          batch.insert('series_items', _seriesToRow(categoryName, s),
              conflictAlgorithm: ConflictAlgorithm.replace);
        }
        await batch.commit(noResult: true);
      }
    });
  }

  Future<List<XtreamSeries>> getSeriesCategory(
      String playlistId, String categoryName,
      {int? limit}) async {
    final db = await _database;
    final rows = await db.query('series_items',
        where: 'category_name = ? AND playlist_id = ?',
        whereArgs: [categoryName, playlistId],
        limit: limit);
    return rows.map(_rowToSeries).toList();
  }

  /// See [searchVod]'s doc comment — same idea for series.
  Future<List<XtreamSeries>> searchSeries(
      String query, List<String> playlistIds,
      {int limit = 200}) async {
    if (playlistIds.isEmpty) return [];
    final db = await _database;
    final placeholders = List.filled(playlistIds.length, '?').join(', ');
    final rows = await db.query(
      'series_items',
      where: 'name LIKE ? AND playlist_id IN ($placeholders)',
      whereArgs: ['%$query%', ...playlistIds],
      limit: limit,
    );
    return rows.map(_rowToSeries).toList();
  }

  /// See [getVodByIds]'s doc comment — same idea for series.
  Future<List<XtreamSeries>> getSeriesByIds(List<String> ids) async {
    if (ids.isEmpty) return [];
    final db = await _database;
    final placeholders = List.filled(ids.length, '?').join(', ');
    final rows = await db.query('series_items',
        where: 'id IN ($placeholders)', whereArgs: ids);
    return rows.map(_rowToSeries).toList();
  }

  /// See [getRecentlyAddedVod]'s doc comment — same idea for series.
  Future<List<XtreamSeries>> getRecentlyAddedSeries(List<String> playlistIds,
      {int limit = 5}) async {
    if (playlistIds.isEmpty) return [];
    final db = await _database;
    final placeholders = List.filled(playlistIds.length, '?').join(', ');
    final rows = await db.query(
      'series_items',
      where: 'playlist_id IN ($placeholders) AND added_at IS NOT NULL'
          ' AND ${_excludeAdultCategoriesClause()}',
      whereArgs: [...playlistIds, ..._excludeAdultCategoriesArgs()],
      orderBy: 'added_at DESC',
      limit: limit,
    );
    return rows.map(_rowToSeries).toList();
  }

  /// See [getVodCategoryCount]'s doc comment — same idea for series.
  Future<int> getSeriesCategoryCount(
      String playlistId, String categoryName) async {
    final db = await _database;
    final result = await db.rawQuery(
        'SELECT COUNT(*) AS cnt FROM series_items WHERE category_name = ? AND playlist_id = ?',
        [categoryName, playlistId]);
    return Sqflite.firstIntValue(result) ?? 0;
  }

  /// Every favorited movie regardless of whether its category has been
  /// opened this session — unlike the old in-memory-scan approach, this
  /// sees the whole catalog since it's a direct query, not a scan of
  /// whatever's currently paged into memory. [playlistIds] restricts to
  /// currently-*enabled* playlists — see [searchVod]'s doc comment.
  Future<List<Channel>> getAllFavoriteVod(List<String> playlistIds) async {
    if (playlistIds.isEmpty) return [];
    final db = await _database;
    final placeholders = List.filled(playlistIds.length, '?').join(', ');
    final rows = await db.query('vod_channels',
        where: 'is_favorite = 1 AND playlist_id IN ($placeholders)',
        whereArgs: playlistIds);
    return rows.map(_rowToChannel).toList();
  }

  Future<List<XtreamSeries>> getAllFavoriteSeries(
      List<String> playlistIds) async {
    if (playlistIds.isEmpty) return [];
    final db = await _database;
    final placeholders = List.filled(playlistIds.length, '?').join(', ');
    final rows = await db.query('series_items',
        where: 'is_favorite = 1 AND playlist_id IN ($placeholders)',
        whereArgs: playlistIds);
    return rows.map(_rowToSeries).toList();
  }

  /// Caches one item's TMDB-fetched real release date — see
  /// `Channel.releaseDate`'s doc comment. Written once per item (the
  /// lookup never needs to repeat once cached), not folded into
  /// [upsertVodCategory]'s wholesale replace, since enrichment runs as its
  /// own separate, slower, network-bound pass well after the catalog sync
  /// itself has already populated this row.
  Future<void> setVodReleaseDate(String id, DateTime date) async {
    final db = await _database;
    await db.update(
        'vod_channels', {'release_date': date.millisecondsSinceEpoch},
        where: 'id = ?', whereArgs: [id]);
  }

  Future<void> setSeriesReleaseDate(String id, DateTime date) async {
    final db = await _database;
    await db.update(
        'series_items', {'release_date': date.millisecondsSinceEpoch},
        where: 'id = ?', whereArgs: [id]);
  }

  Future<void> setVodPosterUrl(String id, String url) async {
    final db = await _database;
    await db.update('vod_channels', {'poster_url': url},
        where: 'id = ?', whereArgs: [id]);
  }

  Future<void> setSeriesPosterUrl(String id, String url) async {
    final db = await _database;
    await db.update('series_items', {'poster_url': url},
        where: 'id = ?', whereArgs: [id]);
  }

  Future<void> setVodBackdropUrl(String id, String url) async {
    final db = await _database;
    await db.update('vod_channels', {'backdrop_url': url},
        where: 'id = ?', whereArgs: [id]);
  }

  Future<void> setSeriesBackdropUrl(String id, String url) async {
    final db = await _database;
    await db.update('series_items', {'backdrop_url': url},
        where: 'id = ?', whereArgs: [id]);
  }

  /// Provider HD art from `get_vod_info` — see
  /// `Channel.providerPosterUrl`. Null arguments leave that column alone.
  Future<void> setVodProviderImages(String id,
      {String? posterUrl, String? backdropUrl}) async {
    final values = <String, Object?>{
      if (posterUrl != null) 'provider_poster_url': posterUrl,
      if (backdropUrl != null) 'provider_backdrop_url': backdropUrl,
    };
    if (values.isEmpty) return;
    final db = await _database;
    await db.update('vod_channels', values, where: 'id = ?', whereArgs: [id]);
  }

  /// See `XtreamSeries.providerBackdropUrl`.
  Future<void> setSeriesProviderBackdropUrl(String id, String url) async {
    final db = await _database;
    await db.update('series_items', {'provider_backdrop_url': url},
        where: 'id = ?', whereArgs: [id]);
  }

  /// Caches a TMDB id [TmdbEnrichmentService] resolved itself (via a title
  /// search) for an item the provider never tagged with one — see
  /// `Channel.tmdbId`'s doc comment. Same "write once, separate from the
  /// wholesale category replace" reasoning as [setVodReleaseDate].
  Future<void> setVodTmdbId(String id, String tmdbId) async {
    final db = await _database;
    await db.update('vod_channels', {'tmdb_id': tmdbId},
        where: 'id = ?', whereArgs: [id]);
  }

  Future<void> setSeriesTmdbId(String id, String tmdbId) async {
    final db = await _database;
    await db.update('series_items', {'tmdb_id': tmdbId},
        where: 'id = ?', whereArgs: [id]);
  }

  Future<void> setVodFavorite(String id, bool value) async {
    final db = await _database;
    await db.update('vod_channels', {'is_favorite': value ? 1 : 0},
        where: 'id = ?', whereArgs: [id]);
  }

  /// Keyed by the composite `XtreamSeries.id` now, not the bare (not
  /// safely-unique-across-providers) `seriesId` int.
  Future<void> setSeriesFavorite(String id, bool value) async {
    final db = await _database;
    await db.update('series_items', {'is_favorite': value ? 1 : 0},
        where: 'id = ?', whereArgs: [id]);
  }

  /// Deletes every row belonging to one playlist — used when that playlist
  /// is removed entirely (`PlaylistManager.removePlaylist`), so its cached
  /// catalog doesn't linger for a disabled/deleted playlist.
  Future<void> clearForPlaylist(String playlistId) async {
    final db = await _database;
    await db.delete('vod_channels',
        where: 'playlist_id = ?', whereArgs: [playlistId]);
    await db.delete('series_items',
        where: 'playlist_id = ?', whereArgs: [playlistId]);
  }

  Future<void> clearAll() async {
    final db = await _database;
    await db.delete('vod_channels');
    await db.delete('series_items');
  }
}
