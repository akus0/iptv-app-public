import '../utils/guarded_dialog.dart';
import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:provider/provider.dart';
import '../models/m3u_group.dart';
import '../models/channel.dart';
import '../models/xtream_series.dart';
import '../services/playback_service.dart';
import '../services/app_preferences.dart';
import '../services/catalog_database.dart';
import '../services/playlist_manager.dart';
import '../services/storage_service.dart';
import '../utils/display_title.dart';
import '../utils/image_urls.dart';
import '../utils/tv_theme.dart';
import '../widgets/hd_network_image.dart';
import '../widgets/iptv_bottom_bar.dart';
import '../widgets/tv_text_field_gate.dart';
import '../widgets/hold_to_activate.dart';
import '../widgets/player_dialog.dart';
import '../widgets/tv_menu_tile.dart';
import '../widgets/library_category_rail.dart';
import '../widgets/main_navigation_rail.dart';
import '../utils/library_categories.dart';
import 'movie_detail_screen.dart';
import 'series_detail_screen.dart';

/// A bounded, on-demand library. No timers, hover metadata requests or bulk
/// warm-up; the remote walks a virtual grid with explicit row/column movement.
String? _ratingLabel(String? value) {
  final parsed = double.tryParse(value ?? '');
  return parsed == null || !parsed.isFinite || parsed <= 0
      ? null
      : parsed.toStringAsFixed(1);
}

enum LibraryShelf { categories, favorites, continueWatching }

class _BrowsePosition {
  const _BrowsePosition(this.group, this.sort, this.shelf, this.offset,
      this.query, this.scroll, this.focused);
  final M3uGroup? group;
  final LibrarySort sort;
  final LibraryShelf shelf;
  final int offset, focused;
  final String query;
  final double scroll;
}

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key, this.initialSeries = false});
  final bool initialSeries;
  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  static const _pageSize = 60;
  late bool _series = widget.initialSeries;
  final _scroll = ScrollController();
  final _search = TextEditingController();
  final _searchFocus = FocusNode();
  final _categoryFocus = FocusNode(debugLabel: 'library-category-button');
  final _categoryRailFocus = FocusNode(debugLabel: 'library-categories');
  final _refreshFocus = FocusNode(debugLabel: 'library-refresh');
  final _sortFocus = FocusNode(debugLabel: 'library-sort');
  final _searchButtonFocus = FocusNode(debugLabel: 'library-search-button');
  final _navigationNodes =
      List.generate(5, (i) => FocusNode(debugLabel: 'library-navigation-$i'));
  int _navigationDepth = 0;
  bool _exitReady = false;
  bool get _tv => context.read<AppPreferences>().isTelevision;

  void _showNavigation(int depth) {
    setState(() => _navigationDepth = depth);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (depth == 0) {
        _navigationNodes[_series ? 3 : 2].requestFocus();
      } else if (_shelf == LibraryShelf.categories && _groups.isNotEmpty) {
        _categoryRailFocus.requestFocus();
      } else {
        _shelfNodes[_shelf.index].requestFocus();
      }
    });
  }

  void _enterPosters() {
    if (_tv && _navigationDepth != 2) {
      setState(() => _navigationDepth = 2);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (_length > 0) {
          _focusItem(_focused);
        } else {
          _shelfNodes[_shelf.index].requestFocus();
        }
      });
    } else {
      _focusItem(_focused);
    }
  }

  void _back() {
    if (_tv && _navigationDepth > 0) {
      _showNavigation(
          _navigationDepth == 2 && _shelf == LibraryShelf.categories ? 1 : 0);
    } else {
      setState(() => _exitReady = true);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.of(context).pop();
      });
    }
  }

  void _selectCategory(M3uGroup chosen) {
    if (_categoriesBusy) return;
    if (chosen.playlistId == _group?.playlistId &&
        chosen.title == _group?.title &&
        _shelf == LibraryShelf.categories &&
        _search.text.isEmpty) {
      _enterPosters();
      return;
    }
    _debounce?.cancel();
    _focusRequest++;
    setState(() {
      _shelf = LibraryShelf.categories;
      _group = chosen;
      _offset = 0;
      _focused = 0;
      _search.clear();
      _page = const LibraryPage(total: 0);
      if (_tv) _navigationDepth = 2;
    });
    _rememberCategory();
    _focusedTitle.value = '';
    _shelfNodes[0].requestFocus();
    _loadPage(focusFirst: true);
  }

  final _shelfNodes = [
    for (final shelf in LibraryShelf.values)
      FocusNode(debugLabel: 'library-shelf-${shelf.name}')
  ];
  final _nextFocus = FocusNode();
  final _previousFocus = FocusNode();
  final _nodes =
      List.generate(_pageSize, (i) => FocusNode(debugLabel: 'library-item-$i'));
  List<M3uGroup> _groups = [];
  LibraryCategoryTree _categoryTree =
      LibraryCategoryTree([], organise: (_) => false);
  final _railKey = GlobalKey<LibraryCategoryRailState>();
  M3uGroup? _group;
  LibraryPage _page = const LibraryPage(total: 0);
  LibrarySort _sort = LibrarySort.provider;
  LibraryShelf _shelf = LibraryShelf.categories;
  bool _busy = true, _categoriesBusy = true;
  bool _searchVisible = false;
  String? _error;
  int _offset = 0, _generation = 0, _columns = 4, _focused = 0;
  double _rowExtent = 210;
  Timer? _debounce;
  final _positions = <bool, _BrowsePosition>{};
  final _focusedTitle = ValueNotifier<String>('');
  double? _restoreScroll;
  int _focusRequest = 0;

  void _rememberCategory() {
    final group = _group;
    if (group == null) return;
    unawaited(context.read<StorageService>().setLibraryBrowseSelection(
        _series, [group.playlistId, group.title, _sort.name]));
  }

  void _restoreSelection() {
    final saved =
        context.read<StorageService>().getLibraryBrowseSelection(_series);
    if (saved.length != 3) return;
    _group = M3uGroup(playlistId: saved[0], title: saved[1], channels: []);
    _sort = LibrarySort.values.where((v) => v.name == saved[2]).firstOrNull ??
        LibrarySort.provider;
  }

  void _positionAfterLoad(double offset, {bool focusFirst = false}) {
    final generation = _generation;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || generation != _generation) return;
      if (_scroll.hasClients) {
        _scroll.jumpTo(offset.clamp(0, _scroll.position.maxScrollExtent));
      }
      if (focusFirst && _length > 0) _focusItem(0);
    });
  }

  void _stampFavorites() {
    final storage = context.read<StorageService>();
    final movies = storage.getFavorites();
    final series = storage.getFavoriteSeries();
    for (final item in _page.movies) {
      item.isFavorite = movies.contains(item.id);
    }
    for (final item in _page.series) {
      item.isFavorite = series.contains(item.id);
    }
  }

  void _selectShelf(LibraryShelf shelf) {
    if (shelf == _shelf) return;
    _debounce?.cancel();
    _focusRequest++;
    _shelf = shelf;
    _offset = 0;
    _focusedTitle.value = '';
    _search.clear();
    _page = const LibraryPage(total: 0);
    _loadPage();
  }

  String get _type => _series ? 'series' : 'vod';
  String get _title => _series ? 'Series' : 'Movies';
  int get _length => _series ? _page.series.length : _page.movies.length;

  @override
  void initState() {
    super.initState();
    _categoryFocus.onKeyEvent = (_, event) {
      if (event is KeyUpEvent) return KeyEventResult.ignored;
      final key = event.logicalKey;
      if (key == LogicalKeyboardKey.arrowDown) {
        if (_searchVisible) {
          _searchFocus.requestFocus();
        } else {
          _enterPosters();
        }
      } else if (key == LogicalKeyboardKey.arrowUp) {
        _shelfNodes[_shelf.index].requestFocus();
      } else if (key == LogicalKeyboardKey.arrowRight) {
        _sortFocus.requestFocus();
      } else if (key == LogicalKeyboardKey.arrowLeft && _tv) {
        _showNavigation(1);
      } else {
        return KeyEventResult.ignored;
      }
      return KeyEventResult.handled;
    };
    for (var i = 0; i < _shelfNodes.length; i++) {
      _shelfNodes[i].onKeyEvent = (_, event) {
        if (event is KeyUpEvent) return KeyEventResult.ignored;
        final key = event.logicalKey;
        if (key == LogicalKeyboardKey.arrowDown) {
          if (_shelf == LibraryShelf.categories) {
            _categoryFocus.requestFocus();
          } else if (_searchVisible) {
            _searchFocus.requestFocus();
          } else {
            _enterPosters();
          }
        } else if (key == LogicalKeyboardKey.arrowRight) {
          (i < 2 ? _shelfNodes[i + 1] : _refreshFocus).requestFocus();
        } else if (key == LogicalKeyboardKey.arrowLeft && i > 0) {
          _shelfNodes[i - 1].requestFocus();
        } else {
          return KeyEventResult.ignored;
        }
        return KeyEventResult.handled;
      };
    }
    for (final node in [_refreshFocus, _sortFocus, _searchButtonFocus]) {
      node.onKeyEvent = (_, event) {
        if (event is KeyUpEvent) return KeyEventResult.ignored;
        final key = event.logicalKey;
        if (key == LogicalKeyboardKey.arrowDown) {
          if (node == _refreshFocus) {
            _searchButtonFocus.requestFocus();
          } else if (_searchVisible) {
            _searchFocus.requestFocus();
          } else {
            _enterPosters();
          }
        } else if (key == LogicalKeyboardKey.arrowUp) {
          _refreshFocus.requestFocus();
        } else if (key == LogicalKeyboardKey.arrowLeft) {
          (node == _refreshFocus
                  ? _shelfNodes.last
                  : node == _sortFocus
                      ? _categoryFocus
                      : _shelf == LibraryShelf.categories
                          ? _sortFocus
                          : _shelfNodes[_shelf.index])
              .requestFocus();
        } else if (key == LogicalKeyboardKey.arrowRight) {
          if (node == _sortFocus) _searchButtonFocus.requestFocus();
        } else {
          return KeyEventResult.ignored;
        }
        return KeyEventResult.handled;
      };
    }
    _restoreSelection();
    _loadCategories();
  }

  @override
  void dispose() {
    _generation++;
    _focusRequest++;
    _focusedTitle.dispose();
    _debounce?.cancel();
    _scroll.dispose();
    _search.dispose();
    _searchFocus.dispose();
    _categoryFocus.dispose();
    _categoryRailFocus.dispose();
    _refreshFocus.dispose();
    _sortFocus.dispose();
    _searchButtonFocus.dispose();
    for (final node in _navigationNodes) {
      node.dispose();
    }
    for (final node in _shelfNodes) {
      node.dispose();
    }
    _nextFocus.dispose();
    _previousFocus.dispose();
    for (final n in _nodes) {
      n.dispose();
    }
    super.dispose();
  }

  Future<void> _loadCategories({bool refresh = false}) async {
    final manager = context.read<PlaylistManager>();
    final generation = ++_generation;
    setState(() {
      _busy = true;
      _categoriesBusy = true;
      _error = null;
    });
    String? failure;
    try {
      await manager.ensureLibraryCategories(refresh: refresh);
    } catch (_) {
      failure =
          'Some libraries could not be reached. Check your connection and retry.';
    }
    if (!mounted || generation != _generation) return;
    final groups = (_series ? manager.seriesGroups : manager.vodGroups)
        .where((g) => !g.isHidden)
        .toList();
    setState(() {
      _groups = groups;
      _categoryTree = LibraryCategoryTree(groups,
          organise: (id) => manager.categoryLayoutFor(id) == 'organised');
      _group = groups
              .where((g) =>
                  g.playlistId == _group?.playlistId &&
                  g.title == _group?.title)
              .firstOrNull ??
          groups.firstOrNull;
      _categoriesBusy = false;
      _error = failure;
    });
    if (_group != null) {
      final scroll = _restoreScroll;
      _restoreScroll = null;
      await _loadPage(restoreScroll: scroll);
    } else {
      setState(() => _busy = false);
    }
  }

  Future<void> _loadPage(
      {bool refresh = false,
      bool focusFirst = false,
      double? restoreScroll}) async {
    final group = _group;
    if (_shelf != LibraryShelf.categories) {
      await _loadSaved(focusFirst: focusFirst, restoreScroll: restoreScroll);
      return;
    }
    if (group == null) return;
    final generation = ++_generation;
    final manager = context.read<PlaylistManager>();
    final db = context.read<CatalogDatabase>();
    final series = _series;
    final scroll =
        restoreScroll ?? (refresh && _scroll.hasClients ? _scroll.offset : 0.0);
    final offset = _offset;
    final query = _search.text;
    final sort = _sort;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      String? warning;
      try {
        await manager.loadLibraryCategory(group.playlistId, group.title, _type,
            refresh: refresh);
      } catch (_) {
        warning = 'Could not update. Showing saved titles.';
      }
      if (!mounted || generation != _generation) return;
      var page = await db.libraryPage(
          playlistId: group.playlistId,
          category: group.title,
          series: series,
          query: query,
          sort: sort,
          offset: offset,
          limit: _pageSize);
      if (!mounted || generation != _generation) return;
      var nextOffset = offset;
      if (offset > 0 && offset >= page.total) {
        nextOffset =
            page.total == 0 ? 0 : ((page.total - 1) ~/ _pageSize) * _pageSize;
        page = await db.libraryPage(
            playlistId: group.playlistId,
            category: group.title,
            series: series,
            query: query,
            sort: sort,
            offset: nextOffset,
            limit: _pageSize);
        if (!mounted || generation != _generation) return;
      }
      setState(() {
        _offset = nextOffset;
        _page = page;
        _stampFavorites();
        _busy = false;
        _error = warning;
      });
      _positionAfterLoad(scroll, focusFirst: focusFirst);
    } catch (_) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _busy = false;
        _error =
            'Unable to load this category. Your saved library is kept. Try again.';
      });
    }
  }

  Future<void> _loadSaved(
      {bool focusFirst = false, double? restoreScroll}) async {
    final generation = ++_generation;
    final db = context.read<CatalogDatabase>();
    final storage = context.read<StorageService>();
    final allowed = {for (final g in _groups) '${g.playlistId}::${g.title}'};
    final query = _search.text.trim().toLowerCase();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      List<Channel> movies = [];
      List<XtreamSeries> series = [];
      if (_shelf == LibraryShelf.favorites) {
        final ids =
            (_series ? storage.getFavoriteSeries() : storage.getFavorites())
                .toList();
        for (var i = 0; i < ids.length; i += 200) {
          if (!mounted || generation != _generation) return;
          final chunk = ids.skip(i).take(200).toList();
          if (_series) {
            series.addAll(await db.getSeriesByIds(chunk));
          } else {
            movies.addAll(await db.getVodByIds(chunk));
          }
        }
      } else {
        final recent = context.read<PlaybackService>().recentlyPlayed;
        final seen = <String>{};
        for (final c in recent) {
          if (storage.getLastPosition(c.id) <= 0) continue;
          if (!_series &&
              c.rawId.startsWith('xt_vod_') &&
              !storage.isFullyWatched(c.id)) {
            movies.add(c);
          }
          if (_series && c.seriesId != null && c.rawId.startsWith('xt_ep_')) {
            seen.add('${c.playlistId}::series_${c.seriesId}');
          }
        }
        if (seen.isNotEmpty) {
          final loaded = await db.getSeriesByIds(seen.toList());
          final byId = {for (final item in loaded) item.id: item};
          series = [
            for (final id in seen)
              if (byId[id] != null) byId[id]!
          ];
        }
      }
      movies = movies
          .where((c) =>
              allowed.contains('${c.playlistId}::${c.group}') &&
              c.name.toLowerCase().contains(query))
          .toList();
      series = series
          .where((c) =>
              allowed.contains('${c.playlistId}::${c.categoryId}') &&
              c.name.toLowerCase().contains(query))
          .toList();
      if (!mounted || generation != _generation) return;
      final total = _series ? series.length : movies.length;
      if (_offset >= total) {
        _offset = total == 0 ? 0 : ((total - 1) ~/ _pageSize) * _pageSize;
      }
      setState(() {
        _page = LibraryPage(
            total: total,
            movies: movies.skip(_offset).take(_pageSize).toList(),
            series: series.skip(_offset).take(_pageSize).toList());
        _stampFavorites();
        _busy = false;
      });
      _positionAfterLoad(restoreScroll ?? 0, focusFirst: focusFirst);
    } catch (_) {
      if (mounted && generation == _generation) {
        setState(() {
          _busy = false;
          _error = 'Could not read saved titles. Try again.';
        });
      }
    }
  }

  void _navigate(String destination) {
    if (destination == 'movies' || destination == 'series') {
      final series = destination == 'series';
      if (series == _series) return;
      _debounce?.cancel();
      _focusRequest++;
      _positions[_series] = _BrowsePosition(_group, _sort, _shelf, _offset,
          _search.text, _scroll.hasClients ? _scroll.offset : 0, _focused);
      final saved = _positions[series];
      setState(() {
        _series = series;
        _shelf = saved?.shelf ?? LibraryShelf.categories;
        _group = saved?.group;
        _groups = [];
        _categoryTree = LibraryCategoryTree([], organise: (_) => false);
        _offset = saved?.offset ?? 0;
        _sort = saved?.sort ?? LibrarySort.provider;
        _search.text = saved?.query ?? '';
        _focused = saved?.focused ?? 0;
        _restoreScroll = saved?.scroll;
        _focusedTitle.value = '';
        _page = const LibraryPage(total: 0);
        if (saved == null) _restoreSelection();
      });
      _loadCategories();
    } else {
      Navigator.of(context).pop(destination);
    }
  }

  void _focusItem(int index) {
    if (_length == 0) return;
    index = index.clamp(0, _length - 1);
    _focused = index;
    if (_scroll.hasClients) {
      final top = (index ~/ _columns) * _rowExtent;
      final p = _scroll.position;
      if (top < p.pixels) {
        _scroll.jumpTo(top.clamp(0, p.maxScrollExtent));
      } else if (top + _rowExtent > p.pixels + p.viewportDimension) {
        _scroll.jumpTo((top + _rowExtent - p.viewportDimension)
            .clamp(0, p.maxScrollExtent));
      }
    }
    final request = ++_focusRequest;
    void requestFocus() {
      if (mounted && request == _focusRequest && index < _length) {
        _nodes[index].requestFocus();
      }
    }

    if (_nodes[index].context != null) {
      requestFocus();
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) => requestFocus());
      WidgetsBinding.instance.scheduleFrame();
    }
  }

  KeyEventResult _gridKey(int index, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.pageDown ||
        key == LogicalKeyboardKey.pageUp) {
      if (!_busy) {
        final forward = key == LogicalKeyboardKey.pageDown;
        if (forward ? _offset + _length < _page.total : _offset > 0) {
          _offset = math.max(0, _offset + (forward ? _pageSize : -_pageSize));
          _loadPage(focusFirst: true);
        }
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      if (index ~/ _columns < (_length - 1) ~/ _columns) {
        _focusItem(math.min(index + _columns, _length - 1));
      } else if (_offset + _length < _page.total) {
        _nextFocus.requestFocus();
      } else if (_offset > 0) {
        _previousFocus.requestFocus();
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      if (index < _columns) {
        (_shelf == LibraryShelf.categories && !_tv
                ? _categoryFocus
                : _shelfNodes[_shelf.index])
            .requestFocus();
      } else {
        _focusItem(index - _columns);
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.arrowRight) {
      final delta = key == LogicalKeyboardKey.arrowLeft ? -1 : 1;
      if (delta < 0 && index % _columns == 0 && _tv) {
        _showNavigation(_shelf == LibraryShelf.categories ? 1 : 0);
        return KeyEventResult.handled;
      }
      final next = index + delta;
      if (next >= 0 &&
          next < _length &&
          next ~/ _columns == index ~/ _columns) {
        _focusItem(next);
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Future<void> _chooseCategory() async {
    final manager = context.read<PlaylistManager>();
    final names = {for (final p in manager.profiles) p.id: p.name};
    final chosen = await showGuardedDialog<M3uGroup>(
        context: context,
        builder: (context) => _CategoryDialog(
            groups: _groups,
            tree: _categoryTree,
            selected: _group,
            names: names));
    if (!mounted || chosen == null) return;
    _selectCategory(chosen);
  }

  Future<void> _chooseSort() async {
    final sort = await showGuardedDialog<LibrarySort>(
        context: context,
        builder: (ctx) => SwallowHeldActivate(
            child: PlayerDialog(
                title: 'Sort titles',
                icon: Icons.sort,
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  for (final option in LibrarySort.values)
                    TvMenuTile(
                        autofocus: option == _sort,
                        icon: option == _sort
                            ? Icons.check_circle_outline
                            : Icons.radio_button_unchecked,
                        title: switch (option) {
                          LibrarySort.provider => 'Provider order',
                          LibrarySort.newest => 'Recently added',
                          LibrarySort.name => 'Title A–Z'
                        },
                        onTap: () => Navigator.pop(ctx, option)),
                ]))));
    if (!mounted) return;
    _sortFocus.requestFocus();
    if (sort == null || sort == _sort) return;
    _sort = sort;
    _rememberCategory();
    _offset = 0;
    _loadPage();
  }

  void _submitSearch() {
    _debounce?.cancel();
    _offset = 0;
    _searchFocus.unfocus();
    SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
    _loadPage(focusFirst: true);
  }

  bool _openingDetails = false;
  Future<void> _open(int index) async {
    if (_busy ||
        _openingDetails ||
        index < 0 ||
        index >= _length ||
        ModalRoute.of(context)?.isCurrent == false) {
      return;
    }
    _openingDetails = true;
    // Snapshot the selected item before a pending category/search update can
    // replace the page used by the route builder.
    final page = _series
        ? SeriesDetailScreen(series: _page.series[index])
        : MovieDetailScreen(channel: _page.movies[index]);
    final route = MaterialPageRoute<void>(builder: (_) => page);
    try {
      await Navigator.of(context).push(route);
      await route.completed;
      if (!mounted) return;
      if (_shelf != LibraryShelf.categories) {
        await _loadSaved(
            restoreScroll: _scroll.hasClients ? _scroll.offset : 0);
      } else {
        setState(_stampFavorites);
      }
      if (mounted && ModalRoute.of(context)?.isCurrent != false) {
        _focusItem(index);
      }
    } finally {
      _openingDetails = false;
    }
  }

  Future<void> _favorite(int index) async {
    final manager = context.read<PlaylistManager>();
    if (_series) {
      await manager.toggleSeriesFavorite(_page.series[index]);
    } else {
      await manager.toggleFavorite(_page.movies[index]);
    }
    if (!mounted) return;
    if (_shelf == LibraryShelf.favorites) {
      await _loadSaved(restoreScroll: _scroll.hasClients ? _scroll.offset : 0);
      if (mounted) _focusItem(index);
    } else {
      setState(() {});
    }
  }

  Widget _pageButton({required bool forward, required bool compact}) => Focus(
      onKeyEvent: (_, event) {
        if (event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.arrowUp) {
          _focusItem(_focused);
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: TextButton.icon(
          focusNode: forward ? _nextFocus : _previousFocus,
          style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              textStyle: const TextStyle(fontSize: 12)),
          onPressed: _busy ||
                  (forward ? _offset + _length >= _page.total : _offset == 0)
              ? null
              : () {
                  _offset =
                      math.max(0, _offset + (forward ? _pageSize : -_pageSize));
                  _loadPage(focusFirst: true);
                },
          icon: Icon(forward ? Icons.chevron_right : Icons.chevron_left,
              size: 18),
          label: Text(forward
              ? 'Next'
              : compact
                  ? 'Prev'
                  : 'Previous')));

  Widget _shelfTabs(ColorScheme scheme) => SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(children: [
        for (final shelf in LibraryShelf.values)
          Padding(
              padding: const EdgeInsets.only(right: 3),
              child: Focus(
                  onKeyEvent: (_, event) {
                    if (event is KeyUpEvent) return KeyEventResult.ignored;
                    if (event.logicalKey == LogicalKeyboardKey.arrowLeft &&
                        shelf.index == 0 &&
                        _tv) {
                      _showNavigation(
                          _shelf == LibraryShelf.categories ? 1 : 0);
                      return KeyEventResult.handled;
                    }
                    return KeyEventResult.ignored;
                  },
                  child: TextButton(
                    key: ValueKey('library-shelf-${shelf.name}'),
                    focusNode: _shelfNodes[shelf.index],
                    onPressed:
                        _categoriesBusy ? null : () => _selectShelf(shelf),
                    style: ButtonStyle(
                        minimumSize: const WidgetStatePropertyAll(Size(0, 32)),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        padding: const WidgetStatePropertyAll(
                            EdgeInsets.symmetric(horizontal: 10)),
                        textStyle: const WidgetStatePropertyAll(TextStyle(
                            fontSize: 12, fontWeight: FontWeight.w600)),
                        foregroundColor: WidgetStatePropertyAll(_shelf == shelf
                            ? scheme.primary
                            : scheme.onSurfaceVariant),
                        backgroundColor: WidgetStateProperty.resolveWith(
                            (states) => states.contains(WidgetState.focused)
                                ? scheme.primaryContainer
                                : _shelf == shelf
                                    ? scheme.surfaceContainerHighest
                                    : Colors.transparent),
                        shape: WidgetStatePropertyAll(RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(4),
                            side: BorderSide(
                                color: _shelf == shelf
                                    ? scheme.primary.withValues(alpha: .4)
                                    : Colors.transparent)))),
                    child: Semantics(
                        selected: _shelf == shelf,
                        child: Text(switch (shelf) {
                          LibraryShelf.categories => 'Browse',
                          LibraryShelf.favorites => 'Favourites',
                          LibraryShelf.continueWatching => 'Continue'
                        })),
                  )))
      ]));

  Widget _mainNavigation(AppPreferences prefs) => SizedBox(
      key: const ValueKey('library-navigation'),
      width: _tv ? 145 : 48,
      child: Row(children: [
        Expanded(
            child: Padding(
                padding: EdgeInsets.fromLTRB(
                    _tv ? 12 : 0, _tv ? 12 : 4, 0, _tv ? 12 : 4),
                child: MainNavigationRail(
                    selected: _series ? 'series' : 'movies',
                    collapsed: !_tv,
                    autofocus: _tv,
                    focusNodes: {
                      for (var i = 0; i < MainNavigationRail.items.length; i++)
                        MainNavigationRail.items[i].id: _navigationNodes[i]
                    },
                    onEnter: () => _showNavigation(1),
                    onSelect: (destination) {
                      if (destination == (_series ? 'series' : 'movies')) {
                        _showNavigation(1);
                      } else {
                        _navigate(destination);
                      }
                    }))),
        const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: VerticalDivider(width: 1)),
      ]));

  @override
  Widget build(BuildContext context) {
    final prefs = context.watch<AppPreferences>();
    final portrait =
        !prefs.isTelevision && MediaQuery.sizeOf(context).width < 600;
    final scheme = Theme.of(context).colorScheme;
    final libraryActions = <Widget>[
      IconButton(
          focusNode: _refreshFocus,
          tooltip: _shelf == LibraryShelf.categories
              ? 'Refresh this category'
              : 'Refresh saved titles',
          onPressed: _busy
              ? null
              : () {
                  _loadPage(
                      refresh: true,
                      restoreScroll: _scroll.hasClients ? _scroll.offset : 0);
                },
          icon: const Icon(Icons.refresh, size: 20)),
    ];
    final content =
        Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (!portrait)
        Row(children: [
          if (_tv && _navigationDepth == 2)
            IconButton(
                tooltip: 'Show navigation',
                onPressed: () => _showNavigation(0),
                icon: const Icon(Icons.menu, size: 19)),
          Text(_title,
              style:
                  const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          const SizedBox(width: 16),
          Expanded(child: _shelfTabs(scheme)),
          ...libraryActions,
        ]),
      if (portrait)
        Row(children: [
          Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                Text(_title,
                    maxLines: 1,
                    style: const TextStyle(
                        fontSize: 22, fontWeight: FontWeight.w700)),
              ])),
          ...libraryActions,
        ]),
      if (portrait)
        Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: _shelfTabs(scheme)),
      Row(children: [
        if (_shelf == LibraryShelf.categories)
          Expanded(
              child: TextButton.icon(
                  key: const ValueKey('library-category-button'),
                  focusNode: _categoryFocus,
                  autofocus: !_tv,
                  onPressed: _categoriesBusy
                      ? null
                      : _tv
                          ? () => _showNavigation(1)
                          : _chooseCategory,
                  icon:
                      Icon(libraryCategoryIcon(_group?.title ?? ''), size: 18),
                  label: Row(children: [
                    Expanded(
                        child: Text(
                            _shelf == LibraryShelf.categories
                                ? (_group == null
                                    ? 'Choose category'
                                    : [
                                        if (_categoryTree
                                            .path(_group!)
                                            .isNotEmpty)
                                          _categoryTree.path(_group!),
                                        _categoryTree.label(_group!)
                                      ].join(' › '))
                                : _shelf == LibraryShelf.favorites
                                    ? 'Favourites'
                                    : 'Continue watching',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis)),
                    const Icon(Icons.expand_more, size: 18)
                  ]))),
        if (_shelf != LibraryShelf.categories)
          Expanded(
              child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(
                      _shelf == LibraryShelf.favorites
                          ? 'Your favourites'
                          : 'Continue watching',
                      style: const TextStyle(
                          fontSize: 14, fontWeight: FontWeight.w600)))),
        if (_shelf == LibraryShelf.categories) const SizedBox(width: 8),
        if (_shelf == LibraryShelf.categories)
          TextButton.icon(
              focusNode: _sortFocus,
              onPressed: _busy ? null : _chooseSort,
              icon: const Icon(Icons.sort, size: 19),
              label: Text(switch (_sort) {
                LibrarySort.provider => 'Sort',
                LibrarySort.newest => 'Newest',
                LibrarySort.name => 'A–Z'
              })),
        if (!portrait)
          IconButton(
              tooltip: 'Search titles',
              focusNode: _searchButtonFocus,
              onPressed: () {
                setState(() => _searchVisible = true);
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted) _searchFocus.requestFocus();
                });
              },
              icon: const Icon(Icons.search, size: 20)),
      ]),
      if (portrait || _searchVisible) const SizedBox(height: 6),
      if (portrait || _searchVisible)
        TvTextFieldGate(
            focusNode: _searchFocus,
            builder: (context, readOnly) => TextField(
                controller: _search,
                focusNode: _searchFocus,
                readOnly: readOnly,
                textInputAction: TextInputAction.search,
                onSubmitted: (_) => _submitSearch(),
                onChanged: (_) {
                  _debounce?.cancel();
                  _generation++;
                  _focusedTitle.value = '';
                  _debounce = Timer(const Duration(milliseconds: 350), () {
                    _offset = 0;
                    _loadPage();
                  });
                },
                decoration: InputDecoration(
                    isDense: true,
                    hintText: _shelf == LibraryShelf.categories
                        ? 'Search this category'
                        : 'Search saved titles',
                    prefixIcon: const Icon(Icons.search, size: 20),
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 10),
                    suffixIcon: Row(mainAxisSize: MainAxisSize.min, children: [
                      IconButton(
                          tooltip: 'Clear search',
                          icon: const Icon(Icons.close, size: 18),
                          onPressed: () {
                            _search.clear();
                            _submitSearch();
                            if (!portrait) {
                              setState(() => _searchVisible = false);
                            }
                          }),
                      IconButton(
                          tooltip: 'Search',
                          icon: const Icon(Icons.arrow_forward, size: 19),
                          onPressed: _submitSearch),
                    ])))),
      SizedBox(
          height: 24,
          child: Align(
              alignment: Alignment.centerLeft,
              child: _busy
                  ? Row(children: [
                      const SizedBox(
                          width: 10,
                          height: 10,
                          child: CircularProgressIndicator(strokeWidth: 1.5)),
                      const SizedBox(width: 8),
                      Text(
                          _categoriesBusy
                              ? 'Loading categories…'
                              : 'Loading titles…',
                          style: const TextStyle(fontSize: 11))
                    ])
                  : ValueListenableBuilder<String>(
                      valueListenable: _focusedTitle,
                      builder: (_, title, child) => Row(children: [
                            Expanded(
                                child: Text(
                                    _error ??
                                        (!portrait && title.isNotEmpty
                                            ? title
                                            : '${_page.total} titles'),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                        fontSize: 11,
                                        color: _error != null
                                            ? scheme.error
                                            : scheme.onSurfaceVariant))),
                            if (!portrait && title.isNotEmpty && _error == null)
                              Text('${_page.total} titles',
                                  style: TextStyle(
                                      fontSize: 10,
                                      color: scheme.onSurfaceVariant)),
                          ])))),
      Expanded(
          child: _busy && _length == 0
              ? const SizedBox.shrink()
              : _error != null && _length == 0
                  ? Center(
                      child: FilledButton.tonalIcon(
                          onPressed: () => _categoriesBusy || _groups.isEmpty
                              ? _loadCategories()
                              : _loadPage(refresh: true),
                          icon: const Icon(Icons.refresh),
                          label: const Text('Try again')))
                  : _length == 0
                      ? Center(
                          child: Padding(
                              padding: const EdgeInsets.all(24),
                              child: Text(
                                  _groups.isEmpty
                                      ? 'No $_title categories available. Add an Xtream playlist in Settings, or check which categories are enabled.'
                                      : _search.text.isNotEmpty
                                          ? 'No titles match your search.'
                                          : _shelf == LibraryShelf.categories
                                              ? 'This category is empty. Choose another category.'
                                              : _shelf == LibraryShelf.favorites
                                                  ? 'Save favourites from a title’s details, or hold a poster.'
                                                  : 'Titles you start watching will appear here.',
                                  textAlign: TextAlign.center)))
                      : LayoutBuilder(builder: (context, constraints) {
                          _columns = math.max(
                              2,
                              (constraints.maxWidth / (portrait ? 115 : 110))
                                  .floor());
                          final width =
                              (constraints.maxWidth - (_columns - 1) * 10) /
                                  _columns;
                          _rowExtent = width * 1.4 + 64;
                          return GridView.builder(
                              controller: _scroll,
                              scrollCacheExtent:
                                  ScrollCacheExtent.pixels(_rowExtent),
                              itemCount: _length,
                              gridDelegate:
                                  SliverGridDelegateWithFixedCrossAxisCount(
                                      crossAxisCount: _columns,
                                      mainAxisExtent: _rowExtent - 10,
                                      crossAxisSpacing: 10,
                                      mainAxisSpacing: 10),
                              itemBuilder: (context, index) {
                                final movie =
                                    _series ? null : _page.movies[index];
                                final series =
                                    _series ? _page.series[index] : null;
                                final storage = context.read<StorageService>();
                                return Focus(
                                    key: ValueKey(movie?.id ?? series!.id),
                                    onKeyEvent: (_, event) =>
                                        _gridKey(index, event),
                                    child: _LibraryCard(
                                        title: cleanDisplayTitle(
                                            movie?.name ?? series!.name),
                                        year: (movie?.releaseDate ??
                                                    series?.releaseDate)
                                                ?.year
                                                .toString() ??
                                            RegExp(r'\((19|20)\d{2}\)')
                                                .firstMatch(
                                                    movie?.name ?? series!.name)
                                                ?.group(0)
                                                ?.replaceAll(
                                                    RegExp(r'[()]'), ''),
                                        image: movie?.posterUrl ??
                                            movie?.logoUrl ??
                                            series?.posterUrl ??
                                            series?.coverUrl,
                                        rating: _ratingLabel(
                                            movie?.rating ?? series?.rating),
                                        favorite: movie?.isFavorite ??
                                            series!.isFavorite,
                                        progress: movie == null
                                            ? null
                                            : storage
                                                .getWatchedFraction(movie.id),
                                        focusNode: _nodes[index],
                                        onFocus: () {
                                          if (_tv && _navigationDepth != 2) {
                                            setState(
                                                () => _navigationDepth = 2);
                                          }
                                          _focused = index;
                                          _focusedTitle.value =
                                              cleanDisplayTitle(
                                                  movie?.name ?? series!.name);
                                        },
                                        onOpen: () => _open(index),
                                        onFavorite: () => _favorite(index)));
                              });
                        })),
      if (_page.total > _pageSize)
        SizedBox(
            height: 42,
            child: Row(children: [
              _pageButton(forward: false, compact: portrait),
              Expanded(
                  child: Text(
                      '${_offset + 1}–${_offset + _length} of ${_page.total}',
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 11))),
              _pageButton(forward: true, compact: portrait),
            ])),
    ]);
    return Theme(
        data: buildAppTheme(prefs.palette),
        child: PopScope(
            canPop: !_tv || _exitReady || _navigationDepth == 0,
            onPopInvokedWithResult: (didPop, _) {
              if (!didPop) _back();
            },
            child: Scaffold(
              bottomNavigationBar: portrait
                  ? Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      child: IptvBottomBar(
                          selected: _series ? 'series' : 'movies',
                          onSelect: _navigate))
                  : null,
              body: SafeArea(
                  child: Row(children: [
                if (!portrait)
                  Offstage(
                      offstage: _tv && _navigationDepth != 0,
                      child: ExcludeFocus(
                          excluding: _tv && _navigationDepth != 0,
                          child: _mainNavigation(prefs))),
                if (!portrait)
                  Offstage(
                      offstage: (_tv && _navigationDepth >= 2) ||
                          _shelf != LibraryShelf.categories,
                      child: ExcludeFocus(
                          excluding: (_tv && _navigationDepth >= 2) ||
                              _shelf != LibraryShelf.categories,
                          child: SizedBox(
                              width: _tv ? 208 : 174,
                              child: LibraryCategoryRail(
                                  key: _railKey,
                                  tree: _categoryTree,
                                  selected: _group,
                                  focusNode: _categoryRailFocus,
                                  names: {
                                    for (final p in context
                                        .read<PlaylistManager>()
                                        .profiles)
                                      p.id: p.name
                                  },
                                  onSelect: _selectCategory,
                                  onBrowse: _enterPosters,
                                  onMainMenu: () => _showNavigation(0))))),
                Expanded(
                    child: Padding(
                        padding: const EdgeInsets.all(10), child: content)),
              ])),
            )));
  }
}

class _LibraryCard extends StatefulWidget {
  const _LibraryCard(
      {required this.title,
      required this.image,
      required this.rating,
      required this.year,
      required this.favorite,
      required this.progress,
      required this.focusNode,
      required this.onFocus,
      required this.onOpen,
      required this.onFavorite});
  final String title;
  final String? image, rating, year;
  final bool favorite;
  final double? progress;
  final FocusNode focusNode;
  final VoidCallback onFocus, onOpen, onFavorite;
  @override
  State<_LibraryCard> createState() => _LibraryCardState();
}

class _LibraryCardState extends State<_LibraryCard>
    with AutomaticKeepAliveClientMixin {
  // Only visited posters in the current 60-title page are retained. Reversing
  // direction reuses their element/image trees; changing pages releases them.
  @override
  bool get wantKeepAlive => true;

  bool _focused = false;
  // Retain the exact artwork widget across remote focus changes. Only the
  // border and text surface repaint; decoding and image layout stay isolated.
  late Widget _artwork = _buildArtwork();
  Widget _buildArtwork() => RepaintBoundary(
      child: widget.image?.isNotEmpty == true
          ? HdNetworkImage(
              url: widget.image!,
              kind: ImageKind.poster,
              decodeWidth: 240,
              fit: BoxFit.cover,
              fadeInDuration: Duration.zero,
              errorWidget: (_) =>
                  const Center(child: Icon(Icons.movie_outlined, size: 32)))
          : const Center(child: Icon(Icons.movie_outlined, size: 32)));

  @override
  void didUpdateWidget(_LibraryCard old) {
    super.didUpdateWidget(old);
    if (old.image != widget.image) _artwork = _buildArtwork();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final scheme = Theme.of(context).colorScheme;
    final ink = _focused ? scheme.onPrimaryContainer : scheme.onSurface;
    return HoldToActivate(
        onTap: widget.onOpen,
        onHold: widget.onFavorite,
        child: Focus(
            focusNode: widget.focusNode,
            onFocusChange: (value) {
              if (_focused != value) setState(() => _focused = value);
              if (value) widget.onFocus();
            },
            child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: widget.onOpen,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                      color: _focused
                          ? scheme.primaryContainer
                          : scheme.surfaceContainer,
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(
                          width: 2,
                          color: _focused
                              ? scheme.primary
                              : scheme.outlineVariant)),
                  child: Padding(
                      padding: const EdgeInsets.all(2),
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Expanded(
                                child: Stack(fit: StackFit.expand, children: [
                              _artwork,
                              if (widget.favorite)
                                const Positioned(
                                    top: 5,
                                    right: 5,
                                    child: DecoratedBox(
                                        decoration: BoxDecoration(
                                            color: Colors.black87,
                                            borderRadius: BorderRadius.all(
                                                Radius.circular(3))),
                                        child: Padding(
                                            padding: EdgeInsets.all(3),
                                            child: Icon(Icons.star,
                                                color: Colors.amber,
                                                size: 14)))),
                              if ((widget.progress ?? 0) > 0)
                                Positioned(
                                    bottom: 0,
                                    left: 0,
                                    right: 0,
                                    child: LinearProgressIndicator(
                                        value: widget.progress!.clamp(0, 1),
                                        minHeight: 3)),
                            ])),
                            SizedBox(
                                height: 50,
                                child: Padding(
                                    padding:
                                        const EdgeInsets.fromLTRB(5, 4, 5, 3),
                                    child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Expanded(
                                              child: Text(widget.title,
                                                  maxLines: 2,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: TextStyle(
                                                      fontSize: 11.5,
                                                      height: 1.2,
                                                      fontWeight:
                                                          FontWeight.w600,
                                                      color: ink))),
                                          Row(children: [
                                            Expanded(
                                                child: Text(widget.year ?? '',
                                                    style: TextStyle(
                                                        fontSize: 10,
                                                        color: ink.withValues(
                                                            alpha: .7)))),
                                            if (widget.rating != null)
                                              Text('★ ${widget.rating}',
                                                  style: TextStyle(
                                                      fontSize: 10,
                                                      color: ink.withValues(
                                                          alpha: .8))),
                                          ]),
                                        ]))),
                          ])),
                ))));
  }
}

class _CategoryDialog extends StatefulWidget {
  const _CategoryDialog(
      {required this.groups,
      required this.tree,
      required this.selected,
      required this.names});
  final List<M3uGroup> groups;
  final LibraryCategoryTree tree;
  final M3uGroup? selected;
  final Map<String, String> names;
  @override
  State<_CategoryDialog> createState() => _CategoryDialogState();
}

class _CategoryDialogState extends State<_CategoryDialog> {
  String _query = '';
  final _search = TextEditingController();
  final _focus = FocusNode();
  final _railFocus = FocusNode();
  final _railKey = GlobalKey<LibraryCategoryRailState>();
  late final _indexed = [
    for (final g in widget.groups)
      (
        g,
        '${g.title} ${widget.tree.label(g)} ${widget.tree.path(g)} ${widget.names[g.playlistId] ?? ''}'
            .toLowerCase()
      )
  ];
  @override
  void dispose() {
    _search.dispose();
    _focus.dispose();
    _railFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final groups = _indexed
        .where((entry) => entry.$2.contains(_query))
        .map((e) => e.$1)
        .toList();
    final scheme = Theme.of(context).colorScheme;
    return Dialog(
        child: SizedBox(
            width: 520,
            height: math.min(560, MediaQuery.sizeOf(context).height * .85),
            child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(children: [
                        const Text('Categories',
                            style: TextStyle(
                                fontSize: 18, fontWeight: FontWeight.w700)),
                        const SizedBox(width: 8),
                        Expanded(
                            child: Text('${groups.length}',
                                style: TextStyle(
                                    fontSize: 12,
                                    color: scheme.onSurfaceVariant))),
                        IconButton(
                            tooltip: 'Close',
                            onPressed: () => Navigator.pop(context),
                            icon: const Icon(Icons.close, size: 20)),
                      ]),
                      TvTextFieldGate(
                          focusNode: _focus,
                          builder: (context, readOnly) => TextField(
                              controller: _search,
                              focusNode: _focus,
                              readOnly: readOnly,
                              textInputAction: TextInputAction.search,
                              onSubmitted: (_) {
                                SystemChannels.textInput
                                    .invokeMethod<void>('TextInput.hide');
                                _railFocus.requestFocus();
                              },
                              onChanged: (v) => setState(
                                  () => _query = v.trim().toLowerCase()),
                              decoration: InputDecoration(
                                  isDense: true,
                                  hintText: 'Find a category',
                                  prefixIcon:
                                      const Icon(Icons.search, size: 20),
                                  suffixIcon: _query.isEmpty
                                      ? null
                                      : IconButton(
                                          tooltip: 'Clear category search',
                                          icon:
                                              const Icon(Icons.close, size: 18),
                                          onPressed: () {
                                            _search.clear();
                                            setState(() => _query = '');
                                          })))),
                      const SizedBox(height: 8),
                      Expanded(
                          child: groups.isEmpty
                              ? const Center(
                                  child: Text('No matching categories'))
                              : LibraryCategoryRail(
                                  key: _railKey,
                                  tree: _query.isEmpty
                                      ? widget.tree
                                      : LibraryCategoryTree.filtered(
                                          groups, widget.tree),
                                  selected: widget.selected,
                                  focusNode: _railFocus,
                                  autofocus: _query.isEmpty,
                                  showPaths: _query.isNotEmpty,
                                  names: widget.names,
                                  onSelect: (group) =>
                                      Navigator.pop(context, group),
                                  onBrowse: () {},
                                  onMainMenu: () => _focus.requestFocus(),
                                  onSearch: () => _focus.requestFocus())),
                    ]))));
  }
}
