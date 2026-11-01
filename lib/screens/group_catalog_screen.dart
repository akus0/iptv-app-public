import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/channel.dart';
import '../models/xtream_series.dart';
import '../services/catalog_database.dart';
import '../services/playlist_manager.dart';
import '../services/storage_service.dart';
import '../services/tmdb_enrichment_service.dart';
import '../utils/tv_theme.dart';
import '../widgets/poster_card.dart';
import '../widgets/settings_scaffold.dart';
import 'movie_detail_screen.dart';
import 'series_detail_screen.dart';
import '../l10n/l10n.dart';

/// Catalogue ordering: [addedDate] uses provider ingestion timestamps; [tmdb] uses actual
/// release dates obtained by TmdbEnrichmentService with a configured API key.
enum _SortMode { none, aToZ, zToA, rating, addedDate, tmdb }

/// Expanded poster grid for one catalogue group. A pushed route preserves normal Back
/// navigation to the browse screen.
class GroupCatalogScreen extends StatefulWidget {
  const GroupCatalogScreen({
    super.key,
    required this.category,
    required this.playlistId,
    required this.title,
  });

  /// 'vod' or 'series'.
  final String category;
  final String playlistId;
  final String title;

  @override
  State<GroupCatalogScreen> createState() => _GroupCatalogScreenState();
}

class _GroupCatalogScreenState extends State<GroupCatalogScreen> {
  /// Focus the title/back action explicitly on entry instead of allowing lazy-grid contents
  /// to determine initial focus.
  final FocusNode _backButtonFocus = FocusNode();

  /// Preserve provider order by default. Sorting is opt-in through the toolbar.
  _SortMode _sort = _SortMode.none;

  /// Set only once real TMDB-fetched dates start arriving, so the grid
  /// doesn't re-sort to "everything with no date yet" the instant the user
  /// picks Release Date, before any lookups have actually completed.
  bool _enrichmentStarted = false;

  /// Non-null while enrichment is running. Progress distinguishes an incomplete incremental
  /// sort from the final order.
  int? _enrichDone;
  int? _enrichTotal;

  /// Query the full category from CatalogDatabase. Browse-row caches are bounded by
  /// PlaylistSession._maxItemsPerCategory and cannot supply a complete expanded grid.
  List<Channel> _vodItems = [];
  List<XtreamSeries> _seriesItems = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadItems();
  }

  Future<void> _loadItems() async {
    final db = context.read<CatalogDatabase>();
    if (widget.category == 'vod') {
      final items = await db.getVodCategory(widget.playlistId, widget.title);
      if (!mounted) return;
      setState(() {
        _vodItems = items;
        _loading = false;
      });
    } else {
      final items = await db.getSeriesCategory(widget.playlistId, widget.title);
      if (!mounted) return;
      setState(() {
        _seriesItems = items;
        _loading = false;
      });
    }
  }

  @override
  void dispose() {
    _backButtonFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return withTvThemeIfNeeded(
        context,
        (context) => Stack(
              children: [
                const Positioned.fill(child: SettingsGradientBackground()),
                Scaffold(
                  backgroundColor: Colors.transparent,
                  appBar: AppBar(
                    backgroundColor: Colors.transparent,
                    elevation: 0,
                    leading: IconButton(
                      focusNode: _backButtonFocus,
                      autofocus: true,
                      icon: const Icon(Icons.arrow_back),
                      onPressed: () => Navigator.maybePop(context),
                    ),
                    title: Text(widget.title,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    actions: [
                      PopupMenuButton<_SortMode>(
                        icon: const Icon(Icons.sort),
                        tooltip: tr('Sort'),
                        initialValue: _sort,
                        onSelected: _onSortSelected,
                        itemBuilder: (context) => [
                          PopupMenuItem(
                              value: _SortMode.none,
                              child: Text(tr('Default'))),
                          PopupMenuItem(
                              value: _SortMode.aToZ, child: Text(tr('A to Z'))),
                          PopupMenuItem(
                              value: _SortMode.zToA, child: Text(tr('Z to A'))),
                          PopupMenuItem(
                              value: _SortMode.rating,
                              child: Text(tr('Rating (high to low)'))),
                          PopupMenuItem(
                              value: _SortMode.addedDate,
                              child: Text(tr('Date added/updated'))),
                          const PopupMenuItem(
                              value: _SortMode.tmdb, child: Text('TMDB')),
                        ],
                      ),
                    ],
                  ),
                  body: _loading
                      ? const Center(child: CircularProgressIndicator())
                      : Column(
                          children: [
                            if (_enrichDone != null && _enrichTotal != null)
                              _buildEnrichmentBanner(context),
                            Expanded(
                              child: widget.category == 'vod'
                                  ? _buildVodGrid(context)
                                  : _buildSeriesGrid(context),
                            ),
                          ],
                        ),
                ),
              ],
            ));
  }

  void _onSortSelected(_SortMode mode) {
    setState(() => _sort = mode);
    if (mode == _SortMode.tmdb && !_enrichmentStarted) {
      _enrichmentStarted = true;
      _startEnrichment();
    }
  }

  /// Kicks off TMDB enrichment for exactly this category's items — see
  /// `TmdbEnrichmentService`'s doc comment for why this is the *only*
  /// place that ever triggers a TMDB lookup at all (never proactively for
  /// a whole catalog, never for a hidden group). Items re-sort
  /// incrementally as each lookup resolves rather than waiting for the
  /// whole category to finish, so the grid visibly settles into place
  /// over a few seconds instead of looking frozen.
  void _startEnrichment() {
    final storage = context.read<StorageService>();
    final db = context.read<CatalogDatabase>();
    final service = TmdbEnrichmentService(storage, db);

    // Throttle re-sorting and UI updates independently of enrichment requests so large
    // categories do not rebuild once per resolved item.
    var lastUiUpdate = DateTime.fromMillisecondsSinceEpoch(0);
    const uiThrottle = Duration(milliseconds: 400);
    void onProgress(int done, int total) {
      if (!mounted) return;
      final isDone = done >= total;
      final now = DateTime.now();
      if (!isDone && now.difference(lastUiUpdate) < uiThrottle) return;
      lastUiUpdate = now;
      setState(() {
        if (isDone) {
          // Done (or nothing needed enrichment at all) — drop the banner
          // rather than leaving it stuck at "100%" forever.
          _enrichDone = null;
          _enrichTotal = null;
        } else {
          _enrichDone = done;
          _enrichTotal = total;
        }
      });
    }

    if (widget.category == 'vod') {
      service.enrichVod(_vodItems, onProgress: onProgress);
    } else {
      service.enrichSeries(_seriesItems, onProgress: onProgress);
    }
  }

  Widget _buildEnrichmentBanner(BuildContext context) {
    final done = _enrichDone!;
    final total = _enrichTotal!;
    return Container(
      width: double.infinity,
      color: Colors.black.withValues(alpha: 0.4),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
              tr('Fetching TMDB release dates... {done}/{total}',
                  {'done': done, 'total': total}),
              style: const TextStyle(fontSize: 12)),
          const SizedBox(height: 4),
          LinearProgressIndicator(value: total == 0 ? null : done / total),
        ],
      ),
    );
  }

  Widget _buildVodGrid(BuildContext context) {
    final playlist = context.read<PlaylistManager>();
    final storage = context.read<StorageService>();
    final items = _sortedChannels(_vodItems);
    return _posterGrid(
      items,
      (c) => PosterCard(
        title: c.name,
        // TMDB's own poster, when enrichment has found one, over the
        // provider's — see `Channel.posterUrl`'s doc comment.
        imageUrl: c.posterUrl ?? c.logoUrl,
        rating: c.rating,
        watched: storage.isFullyWatched(c.id),
        progressFraction: storage.getWatchedFraction(c.id),
        isFavorite: c.isFavorite,
        onToggleFavorite: () =>
            _toggleFavoriteWithFeedback(context, playlist, c),
        onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => MovieDetailScreen(channel: c))),
        onFocusGained: () {},
      ),
    );
  }

  Widget _buildSeriesGrid(BuildContext context) {
    final playlist = context.read<PlaylistManager>();
    final items = _sortedSeries(_seriesItems);
    return _posterGrid(
      items,
      (s) => PosterCard(
        title: s.name,
        imageUrl: s.posterUrl ?? s.coverUrl,
        rating: s.rating,
        isFavorite: s.isFavorite,
        onToggleFavorite: () => _toggleSeriesFavoriteWithFeedback(playlist, s),
        onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => SeriesDetailScreen(series: s))),
        onFocusGained: () {},
      ),
    );
  }

  /// A new list, never mutating [items] in place — [items] here is the
  /// *live* list `PlaylistManager`/the catalog database hands back, and
  /// sorting it directly would silently reorder that shared data for
  /// every other screen reading the same group.
  List<Channel> _sortedChannels(List<Channel> items) {
    final sorted = List<Channel>.from(items);
    switch (_sort) {
      case _SortMode.none:
        break;
      case _SortMode.aToZ:
        sorted.sort(
            (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      case _SortMode.zToA:
        sorted.sort(
            (a, b) => b.name.toLowerCase().compareTo(a.name.toLowerCase()));
      case _SortMode.rating:
        sorted.sort((a, b) => (double.tryParse(b.rating ?? '') ?? -1)
            .compareTo(double.tryParse(a.rating ?? '') ?? -1));
      case _SortMode.addedDate:
        sorted.sort((a, b) => _compareNullableDates(a.addedAt, b.addedAt));
      case _SortMode.tmdb:
        // No release date yet (lookup still running, or TMDB had nothing
        // for it) sorts to the end rather than being treated as "ancient"
        // — same reasoning `getRecentlyAddedVod` already uses for a
        // missing `added_at`.
        sorted.sort(
            (a, b) => _compareNullableDates(a.releaseDate, b.releaseDate));
    }
    return sorted;
  }

  /// Newest first; a null date (not yet fetched/not reported) always
  /// sorts last rather than being treated as oldest.
  static int _compareNullableDates(DateTime? a, DateTime? b) {
    if (a == null && b == null) return 0;
    if (a == null) return 1;
    if (b == null) return -1;
    return b.compareTo(a);
  }

  List<XtreamSeries> _sortedSeries(List<XtreamSeries> items) {
    final sorted = List<XtreamSeries>.from(items);
    switch (_sort) {
      case _SortMode.none:
        break;
      case _SortMode.aToZ:
        sorted.sort(
            (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      case _SortMode.zToA:
        sorted.sort(
            (a, b) => b.name.toLowerCase().compareTo(a.name.toLowerCase()));
      case _SortMode.rating:
        sorted.sort((a, b) => (double.tryParse(b.rating ?? '') ?? -1)
            .compareTo(double.tryParse(a.rating ?? '') ?? -1));
      case _SortMode.addedDate:
        sorted.sort((a, b) => _compareNullableDates(a.addedAt, b.addedAt));
      case _SortMode.tmdb:
        sorted.sort(
            (a, b) => _compareNullableDates(a.releaseDate, b.releaseDate));
    }
    return sorted;
  }

  // These two mutate-then-setState directly rather than going through
  // `context.watch<PlaylistManager>()` — this screen's items are its own
  // `_vodItems`/`_seriesItems` queried straight from `CatalogDatabase` (see
  // that fields' doc comment), not `PlaylistManager`'s capped in-memory
  // lists, so a `PlaylistManager.notifyListeners()` rebuild wouldn't pick
  // up the change here anyway.
  void _toggleFavoriteWithFeedback(
      BuildContext context, PlaylistManager playlist, Channel channel) {
    playlist.toggleFavorite(channel);
    setState(() {});
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(channel.isFavorite
          ? tr('Added to Favorites')
          : tr('Removed from Favorites')),
      duration: const Duration(seconds: 2),
    ));
  }

  void _toggleSeriesFavoriteWithFeedback(
      PlaylistManager playlist, XtreamSeries series) {
    playlist.toggleSeriesFavorite(series);
    setState(() {});
  }

  /// Same shape as `TvHomeScreen._posterGrid` — a plain rectangular grid
  /// (not a row-per-category layout), which default D-pad traversal
  /// handles reliably on its own; the unbounded-search failure mode this
  /// app has repeatedly hit elsewhere is specifically about *many rows of
  /// differing length*, not a single regular grid like this one.
  Widget _posterGrid<T>(List<T> items, Widget Function(T) posterBuilder) {
    if (items.isEmpty) {
      return Center(child: Text(tr('No items in this group.')));
    }
    return GridView.builder(
      padding: const EdgeInsets.all(16),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: PosterCard.width + 12,
        mainAxisExtent: PosterCard.height + 12,
      ),
      itemCount: items.length,
      itemBuilder: (context, i) => posterBuilder(items[i]),
    );
  }
}
