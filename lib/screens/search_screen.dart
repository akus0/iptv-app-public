import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/channel.dart';
import '../models/xtream_series.dart';
import '../services/app_preferences.dart';
import '../services/catalog_database.dart';
import '../services/desktop_mini_player.dart';
import '../services/playlist_manager.dart';
import '../services/storage_service.dart';
import '../utils/tv_theme.dart';
import '../widgets/poster_card.dart';
import '../widgets/settings_scaffold.dart';
import '../widgets/tv_text_field_gate.dart';
import 'desktop_player_screen.dart';
import 'player_screen.dart';
import 'series_detail_screen.dart';
import '../l10n/l10n.dart';

/// Full-screen search — a search bar plus every matching result grouped
/// into its own horizontally-scrolling poster row (Live TV, Movies, TV
/// Shows — in that order, each shown only when it actually has matches),
/// instead of the old single flat list gated behind a scope switch. Every
/// content type is visible at once now, the same way a modern TV app's
/// search results page reads.
class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key, required this.initialScope});

  /// Kept for call-site compatibility (callers still pass the tab the user
  /// was on) but no longer used to gate results — every type now shows
  /// together regardless of where search was opened from.
  final String initialScope;

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

/// One row's worth of built poster cards plus its first card's focus node
/// — the latter is what [_SearchScreenState._moveRowFocus] jumps to
/// explicitly, the same "never rely on default directional search across
/// an arbitrary number of posters" principle `tv_home_screen.dart`'s own
/// browse rows already established (see that file's `_browseRowKeys` doc
/// comment) — this screen builds the same shape of problem (an unknown,
/// potentially large number of focusable tiles across several rows) and
/// gets the same fix.
class _ResultRow {
  _ResultRow(this.label, this.rowKey, this.firstFocusNode, this.children);
  final String label;

  /// Wraps this row's header + horizontal list — see
  /// [_SearchScreenState._ensureRowVisible]'s doc comment for why this
  /// needs to be the whole row, not just whichever card is focused. Built
  /// before the row's children (not inside this constructor) since the
  /// children's own `onFocusGained` closures need to reference it too.
  final GlobalKey rowKey;
  final FocusNode firstFocusNode;
  final List<Widget> children;
}

class _SearchScreenState extends State<SearchScreen> {
  final _controller = TextEditingController();
  final _searchFieldFocus = FocusNode();

  /// The first "Recent searches" chip — Down from the empty search field.
  final _recentFirstFocus = FocusNode(debugLabel: 'recent-search-0');

  /// Holds focus (not a text field) while a picked recent search loads.
  /// The picked chip leaves the tree with the results, and focus then went
  /// back to the search field, reopening the keyboard.
  final _resultsHolder =
      FocusNode(debugLabel: 'search-results-holder', skipTraversal: true);

  /// Set by a picked recent search: focus the first result row once built.
  bool _focusResultsWhenReady = false;
  String _query = '';
  List<String> _recentSearches = [];

  /// Xtream Movies/TV Shows results, queried from [CatalogDatabase]
  /// directly rather than `PlaylistManager.allCachedVod`/`allCachedSeries`
  /// — those only ever reflect whatever's paged into memory this session,
  /// capped at 300 items per category even then, so a title anywhere past
  /// that cap in a large category was invisible to search even though it
  /// was fully synced to disk. Null means "no query run yet for the
  /// current text" (shows a brief loading spinner), distinct from an
  /// empty list (a real "nothing found").
  List<Channel>? _dbVodResults;
  List<XtreamSeries>? _dbSeriesResults;
  Timer? _searchDebounce;

  /// -1 means the search field/suggestion pills, otherwise an index into
  /// whichever `_ResultRow` list [build] most recently produced — see
  /// [_moveRowFocus].
  int _focusedZone = -1;

  /// playlistId → playlist name, set by [_buildRows] only while two or
  /// more playlists are enabled (null = no source line on the cards).
  Map<String, String>? _sourceNames;

  @override
  void initState() {
    super.initState();
    _recentSearches = context.read<StorageService>().getRecentSearches();
    // Needed for a live-channel search to find anything at all — see
    // PlaylistManager.ensureLiveChannelsLoaded's doc comment.
    unawaited(context.read<PlaylistManager>().ensureLiveChannelsLoaded());
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _controller.dispose();
    _searchFieldFocus.dispose();
    _recentFirstFocus.dispose();
    _resultsHolder.dispose();
    super.dispose();
  }

  /// Debounced so a real database query (SQL `LIKE` scan over a
  /// potentially 100k+ row table) doesn't fire on every single keystroke
  /// — only once typing actually pauses. Selecting a recent search
  /// ([_runSearch]) is a deliberate one-shot action instead, so that path
  /// searches immediately with no debounce.
  void _onQueryChanged(String value) {
    setState(() => _query = value);
    _searchDebounce?.cancel();
    final trimmed = value.trim();
    if (trimmed.isEmpty || !context.read<PlaylistManager>().isXtream) {
      setState(() {
        _dbVodResults = null;
        _dbSeriesResults = null;
      });
      return;
    }
    _searchDebounce =
        Timer(const Duration(milliseconds: 250), () => _runDbSearch(trimmed));
  }

  Future<void> _runDbSearch(String query) async {
    // Settings > General hides Movies/TV Shows: no catalog scan either.
    if (context.read<AppPreferences>().hideMoviesShows) return;
    final playlist = context.read<PlaylistManager>();
    // Restricted to enabled playlists — a disabled playlist's stale
    // cached rows shouldn't surface in search results.
    final playlistIds = playlist.profiles
        .where((p) => p.enabled && p.isXtream)
        .map((p) => p.id)
        .toList();
    // Goes through PlaylistManager, not CatalogDatabase directly — see
    // PlaylistManager.searchVisibleVod's doc comment for why a direct DB
    // search has no hidden-group awareness at all.
    final vod = await playlist.searchVisibleVod(query, playlistIds);
    final series = await playlist.searchVisibleSeries(query, playlistIds);
    // The query field may have moved on to something else (or been
    // cleared) by the time this actually returns — a stale result
    // overwriting a newer/empty one would flash wrong results on screen.
    if (!mounted || _query.trim() != query) return;
    setState(() {
      _dbVodResults = vod;
      _dbSeriesResults = series;
    });
  }

  /// Records a completed search (explicit submit, or picking a result) for
  /// the quick-access pills shown while the field is empty — not on every
  /// keystroke, which would just fill history with partial fragments.
  void _recordSearch(String query) {
    if (query.trim().isEmpty) return;
    context.read<StorageService>().addRecentSearch(query).then((_) {
      if (mounted) {
        setState(() => _recentSearches =
            context.read<StorageService>().getRecentSearches());
      }
    });
  }

  void _runSearch(String query) {
    _controller.text = query;
    _controller.selection = TextSelection.collapsed(offset: query.length);
    setState(() => _query = query);
    _searchDebounce?.cancel();
    if (context.read<PlaylistManager>().isXtream) {
      unawaited(_runDbSearch(query.trim()));
    }
  }

  Future<void> _openChannel(Channel channel) async {
    if (ModalRoute.of(context)?.isCurrent == false) return;
    _recordSearch(_query);
    // Use the desktop player on Windows; video_player_hdr does not provide a Windows
    // implementation.
    if (Platform.isWindows) {
      DesktopMiniPlayer.instance.clear();
      Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => DesktopPlayerScreen(channel: channel)));
      return;
    }
    // Let the guarded player own connection setup immediately. Awaiting play
    // here allowed later search taps (or Back) to start competing requests and
    // reopen a player after the user had already left the results.
    await PlayerScreen.open(Navigator.of(context), channel);
  }

  void _openSeries(XtreamSeries series) {
    if (ModalRoute.of(context)?.isCurrent == false) return;
    _recordSearch(_query);
    Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => SeriesDetailScreen(series: series)));
  }

  void _toggleSeriesFavorite(XtreamSeries series) {
    context.read<PlaylistManager>().toggleSeriesFavorite(series);
  }

  /// Explicit Up/Down between the search field and each result row — see
  /// [_ResultRow]'s doc comment for why this can't be left to default
  /// traversal. `-1` (the search field) is one end of the range, the last
  /// built row is the other; a plain `setState`-free field assignment
  /// (`_focusedZone`) tracks whichever currently has focus, updated by
  /// every row's first poster *and* the search field's own focus change.
  void _moveRowFocus(int delta, List<_ResultRow> rows) {
    final target = _focusedZone + delta;
    // Nothing typed: the recent-search chips are the one row below the
    // field (after Back closed the keyboard, Down went nowhere).
    if (rows.isEmpty && _query.trim().isEmpty && _recentSearches.isNotEmpty) {
      if (target < -1 || target > 0) return;
      _focusedZone = target;
      (target == -1 ? _searchFieldFocus : _recentFirstFocus).requestFocus();
      return;
    }
    if (target < -1 || target >= rows.length) return;
    // Set directly rather than relying on a focus-change callback to do
    // it as a side effect — `TextField` only exposes `onTap`, which never
    // fires for a `requestFocus()` triggered programmatically from here,
    // so without this the search field's zone would never actually
    // update and the very next Down press would skip row 0 entirely.
    _focusedZone = target;
    if (target == -1) {
      _searchFieldFocus.requestFocus();
    } else {
      rows[target].firstFocusNode.requestFocus();
    }
  }

  /// Keep the row header visible when a card gains focus. Run after the frame so Flutter's
  /// minimal focused-card scroll does not override the row alignment.
  void _ensureRowVisible(GlobalKey rowKey) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = rowKey.currentContext;
      if (ctx != null) {
        Scrollable.ensureVisible(ctx,
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
            alignment: 0);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final playlist = context.watch<PlaylistManager>();
    final scheme = Theme.of(context).colorScheme;
    final q = _query.trim().toLowerCase();
    final rows = q.isEmpty ? const <_ResultRow>[] : _buildRows(playlist, q);
    if (_focusResultsWhenReady && rows.isNotEmpty) {
      _focusResultsWhenReady = false;
      final first = rows.first.firstFocusNode;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_resultsHolder.hasFocus) return;
        _focusedZone = 0;
        first.requestFocus();
      });
    }

    // Missed in the original Settings-family gradient redesign — Search
    // isn't a Settings screen, it's reached straight from the main tabs,
    // so it wasn't in that pass at all. Same Stack-behind-a-transparent-
    // Scaffold approach as SettingsScaffold itself (not that widget
    // directly: this AppBar's title is a live TextField, not a plain
    // string, which SettingsScaffold's API doesn't have a slot for).
    return withTvThemeIfNeeded(
        context,
        (context) => Stack(
              children: [
                const Positioned.fill(child: SettingsGradientBackground()),
                // A low-opacity radial tint gives search a distinct backdrop without changing
                // the shared theme.
                Positioned.fill(
                  child: IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: RadialGradient(
                          center: Alignment.topRight,
                          radius: 1.4,
                          colors: [
                            Colors.deepPurple.withValues(alpha: 0.16),
                            Colors.transparent,
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                // Around the whole Scaffold, not just the body: the search
                // field lives in the AppBar, and Up/Down from it must be
                // caught here too (closer than the app-level text-editing
                // shortcuts, so it wins over the field's own arrow keys).
                CallbackShortcuts(
                  bindings: {
                    const SingleActivator(LogicalKeyboardKey.arrowUp): () =>
                        _moveRowFocus(-1, rows),
                    const SingleActivator(LogicalKeyboardKey.arrowDown): () =>
                        _moveRowFocus(1, rows),
                  },
                  child: Scaffold(
                    backgroundColor: Colors.transparent,
                    appBar: AppBar(
                      backgroundColor: Colors.transparent,
                      elevation: 0,
                      // On TV, focus the field on entry but open the keyboard only on OK.
                      title: TvTextFieldGate(
                        focusNode: _searchFieldFocus,
                        builder: (context, readOnly) => TextField(
                          controller: _controller,
                          focusNode: _searchFieldFocus,
                          readOnly: readOnly,
                          autofocus: true,
                          textInputAction: TextInputAction.search,
                          decoration: InputDecoration(
                            // readOnly = a TV box until OK is pressed.
                            hintText: readOnly
                                ? tr('Search everything... (press OK to type)')
                                : tr('Search everything...'),
                            border: InputBorder.none,
                            hintStyle: TextStyle(
                                color: Theme.of(context)
                                    .appBarTheme
                                    .foregroundColor
                                    ?.withValues(alpha: 0.6)),
                          ),
                          style: TextStyle(
                            color:
                                Theme.of(context).appBarTheme.foregroundColor,
                            fontSize: 18,
                          ),
                          onChanged: _onQueryChanged,
                          onSubmitted: _recordSearch,
                          onTap: () => _focusedZone = -1,
                        ),
                      ),
                      actions: [
                        if (_query.isNotEmpty)
                          IconButton(
                            icon: const Icon(Icons.clear),
                            onPressed: () {
                              _searchDebounce?.cancel();
                              setState(() {
                                _controller.clear();
                                _query = '';
                                _dbVodResults = null;
                                _dbSeriesResults = null;
                              });
                            },
                          ),
                      ],
                    ),
                    body: Focus(
                      focusNode: _resultsHolder,
                      child: Column(
                        children: [
                          if (q.isEmpty) _buildSuggestionPills(scheme),
                          if (playlist.isXtream && playlist.isWarmingCatalog)
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 16, vertical: 4),
                              child: Row(
                                children: [
                                  const SizedBox(
                                      width: 14,
                                      height: 14,
                                      child: CircularProgressIndicator(
                                          strokeWidth: 2)),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Text(
                                      tr(
                                          'Still loading the full catalog in the background ({warmCatalogDone}/{warmCatalogTotal} categories) — some results may not show up yet.',
                                          {
                                            'warmCatalogDone':
                                                playlist.warmCatalogDone,
                                            'warmCatalogTotal':
                                                playlist.warmCatalogTotal
                                          }),
                                      style:
                                          Theme.of(context).textTheme.bodySmall,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          Expanded(
                            child: q.isEmpty
                                ? (_recentSearches.isEmpty
                                    ? Center(
                                        child: Text(tr(
                                            'Search Live TV, Movies & TV Shows')))
                                    : const SizedBox())
                                : _buildResultRows(rows),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ));
  }

  Widget _buildSuggestionPills(ColorScheme scheme) {
    if (_recentSearches.isEmpty) return const SizedBox();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(tr('Recent searches'),
                    style: Theme.of(context).textTheme.labelLarge),
              ),
              TextButton(
                onPressed: () {
                  context.read<StorageService>().clearRecentSearches();
                  setState(() => _recentSearches = []);
                },
                child: Text(tr('Clear')),
              ),
            ],
          ),
          const SizedBox(height: 4),
          SizedBox(
            height: 40,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: _recentSearches.length,
              separatorBuilder: (_, __) => const SizedBox(width: 8),
              itemBuilder: (context, i) {
                final term = _recentSearches[i];
                return ActionChip(
                  focusNode: i == 0 ? _recentFirstFocus : null,
                  avatar: const Icon(Icons.history, size: 16),
                  label: Text(term),
                  onPressed: () {
                    _resultsHolder.requestFocus();
                    // Up from here goes back to the field (zone -1).
                    _focusedZone = 0;
                    _focusResultsWhenReady = true;
                    _runSearch(term);
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  /// Render non-empty result rows in order: compact live channels, movies, then series.
  List<_ResultRow> _buildRows(PlaylistManager playlist, String q) {
    final rows = <_ResultRow>[];
    // With two or more playlists on, every card names its playlist.
    final enabled = playlist.profiles.where((p) => p.enabled).toList();
    _sourceNames =
        enabled.length > 1 ? {for (final p in enabled) p.id: p.name} : null;

    // visibleChannels, not the raw `channels` getter — that one bypasses
    // hidden-group/hidden-channel filtering entirely, which would otherwise
    // let a restricted viewer search their way straight to a hidden
    // channel without ever un-hiding its group.
    final channelMatches = playlist
        .visibleChannels(category: 'tv')
        .where((c) => c.name.toLowerCase().contains(q))
        .toList();
    if (channelMatches.isNotEmpty) {
      rows.add(_buildChannelRow(rows.length, tr('Live TV'), channelMatches));
    }
    final prefs = context.read<AppPreferences>();
    if (prefs.hideMoviesShows) return rows;

    final vodMatches = playlist.isXtream
        ? _dbVodResults
        : playlist
            .visibleChannels(category: 'vod')
            .where((c) => c.name.toLowerCase().contains(q))
            .toList();
    if (!prefs.hideMovies && vodMatches != null && vodMatches.isNotEmpty) {
      rows.add(_buildChannelRow(rows.length, tr('Movies'), vodMatches,
          isPoster: true));
    }

    if (prefs.hideShows) {
      // Settings > General hides TV Shows: no series row.
    } else if (playlist.isXtream) {
      final seriesMatches = _dbSeriesResults;
      if (seriesMatches != null && seriesMatches.isNotEmpty) {
        rows.add(_buildSeriesRow(rows.length, tr('TV Shows'), seriesMatches));
      }
    } else {
      final seriesMatches = playlist
          .visibleChannels(category: 'series')
          .where((c) => c.name.toLowerCase().contains(q))
          .toList();
      if (seriesMatches.isNotEmpty) {
        rows.add(_buildChannelRow(rows.length, tr('TV Shows'), seriesMatches,
            isPoster: true));
      }
    }

    return rows;
  }

  /// [rowIndex] is this row's final position in the list [_buildRows] is
  /// assembling — known at build time (`rows.length` right before this
  /// row is appended), so every poster's `onFocusGained` can close over
  /// the correct, stable index directly instead of inferring it from
  /// whatever `ListView.builder` happened to lay out most recently (which
  /// doesn't reliably match the focused widget's actual row once lazy
  /// building and scrolling are involved).
  _ResultRow _buildChannelRow(int rowIndex, String label, List<Channel> items,
      {bool isPoster = false}) {
    final rowKey = GlobalKey();
    final firstFocusNode = FocusNode();
    final children = <Widget>[
      for (var i = 0; i < items.length; i++)
        PosterCard(
          key: ValueKey('${label}_${items[i].id}'),
          focusNode: i == 0 ? firstFocusNode : null,
          title: items[i].name,
          sourceLabel: _sourceNames?[items[i].playlistId],
          imageUrl: items[i].logoUrl,
          rating: isPoster ? items[i].rating : null,
          cardWidth: isPoster ? PosterCard.width : 64,
          cardPosterHeight: isPoster ? PosterCard.posterHeight : 64,
          fit: isPoster ? BoxFit.cover : BoxFit.contain,
          onTap: () => _openChannel(items[i]),
          onFocusGained: () {
            _focusedZone = rowIndex;
            _ensureRowVisible(rowKey);
          },
        ),
    ];
    return _ResultRow(label, rowKey, firstFocusNode, children);
  }

  _ResultRow _buildSeriesRow(
      int rowIndex, String label, List<XtreamSeries> items) {
    final rowKey = GlobalKey();
    final firstFocusNode = FocusNode();
    final children = <Widget>[
      for (var i = 0; i < items.length; i++)
        PosterCard(
          key: ValueKey('series_${items[i].id}'),
          focusNode: i == 0 ? firstFocusNode : null,
          title: items[i].name,
          sourceLabel: _sourceNames?[items[i].playlistId],
          imageUrl: items[i].coverUrl,
          isFavorite: items[i].isFavorite,
          onToggleFavorite: () => _toggleSeriesFavorite(items[i]),
          onTap: () => _openSeries(items[i]),
          onFocusGained: () {
            _focusedZone = rowIndex;
            _ensureRowVisible(rowKey);
          },
        ),
    ];
    return _ResultRow(label, rowKey, firstFocusNode, children);
  }

  Widget _buildResultRows(List<_ResultRow> rows) {
    if (rows.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.search_off,
                  size: 48, color: Theme.of(context).disabledColor),
              const SizedBox(height: 12),
              Text(tr('Nothing found')),
            ],
          ),
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.only(top: 8, bottom: 24),
      itemCount: rows.length,
      itemBuilder: (context, rowIndex) {
        final row = rows[rowIndex];
        return Padding(
          key: row.rowKey,
          padding: const EdgeInsets.only(bottom: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(row.label,
                    style: Theme.of(context)
                        .textTheme
                        .titleMedium
                        ?.copyWith(fontWeight: FontWeight.bold)),
              ),
              const SizedBox(height: 8),
              SizedBox(
                height: PosterCard.height +
                    12 +
                    (_sourceNames == null ? 0 : PosterCard.sourceHeight),
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  children: row.children,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
