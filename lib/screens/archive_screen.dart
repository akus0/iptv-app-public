import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../l10n/l10n.dart';
import '../models/archive_models.dart';
import '../services/archive_service.dart';
import '../widgets/detail_header.dart';
import '../widgets/live_resume_hint.dart';
import '../widgets/poster_card.dart';
import '../widgets/tv_text_field_gate.dart';
import 'archive_detail_screen.dart';
import 'archive_playback.dart';
import 'settings/archive_sources_screen.dart';
import 'settings/media_server_screen.dart';

/// Media Hub catalogues from configured sources, independent of IPTV playlists. Use
/// explicit navigation between the rail and catalogue rows, revealing lazy cards before
/// focusing them.
class ArchiveScreen extends StatefulWidget {
  const ArchiveScreen({super.key});

  @override
  State<ArchiveScreen> createState() => _ArchiveScreenState();
}

class _ArchiveScreenState extends State<ArchiveScreen> {
  ArchiveType _type = ArchiveType.movie;
  final _railScope = FocusScopeNode(debugLabel: 'archive-rail');
  final _contentScope = FocusScopeNode(debugLabel: 'archive-content');
  final _firstRailNode = FocusNode(debugLabel: 'archive-rail-first');
  final _emptyActionNode = FocusNode(debugLabel: 'archive-empty-action');
  final _barScope = FocusScopeNode(debugLabel: 'archive-bar');
  final _barSearchNode = FocusNode(debugLabel: 'archive-bar-search');
  final _barClearNode = FocusNode(debugLabel: 'archive-bar-clear');
  final _barGenreNode = FocusNode(debugLabel: 'archive-bar-genre');

  /// The floating bar's row jumps ("Popular", "New"...), by row key.
  final Map<String, FocusNode> _barRowNodes = {};
  final _scroll = ScrollController();

  /// Card focus nodes by row key, created on demand.
  final Map<String, List<FocusNode>> _nodes = {};

  /// Last focused card index per row, so Up/Down lands where you were.
  final Map<String, int> _lastIndex = {};
  final Map<String, GlobalKey> _rowKeys = {};
  final Map<String, ScrollController> _rowScrolls = {};

  int _focusedRow = 0;
  ArchiveMeta? _focused;
  ArchiveSource? _focusedSource;
  late final VoidCallback _releaseResumeHint;

  @override
  void initState() {
    super.initState();
    _releaseResumeHint = LiveResumeHint.hideWhileMounted();
    // PopScope's canPop reads _contentScope.hasFocus at build time; moving
    // focus rows -> rail doesn't rebuild by itself, which left Back stuck
    // sending focus to the rail forever. Rebuild whenever that flips.
    _contentScope.addListener(_onContentFocus);
    _barScope.addListener(_onContentFocus);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      context.read<ArchiveService>().open();
      _firstRailNode.requestFocus();
    });
  }

  bool _contentHadFocus = false;

  /// Rows or the floating bar focused: Back goes to the rail first.
  bool get _awayFromRail => _contentScope.hasFocus || _barScope.hasFocus;

  void _onContentFocus() {
    final has = _awayFromRail;
    if (has == _contentHadFocus || !mounted) return;
    _contentHadFocus = has;
    setState(() {});
  }

  @override
  void dispose() {
    _contentScope.removeListener(_onContentFocus);
    _barScope.removeListener(_onContentFocus);
    _releaseResumeHint();
    _barScope.dispose();
    _barSearchNode.dispose();
    _barClearNode.dispose();
    _barGenreNode.dispose();
    for (final n in _barRowNodes.values) {
      n.dispose();
    }
    _railScope.dispose();
    _contentScope.dispose();
    _firstRailNode.dispose();
    _emptyActionNode.dispose();
    _scroll.dispose();
    for (final c in _rowScrolls.values) {
      c.dispose();
    }
    for (final list in _nodes.values) {
      for (final n in list) {
        n.dispose();
      }
    }
    super.dispose();
  }

  FocusNode _node(String rowKey, int i) {
    final list = _nodes.putIfAbsent(rowKey, () => []);
    while (list.length <= i) {
      list.add(FocusNode(debugLabel: 'archive-card'));
    }
    return list[i];
  }

  GlobalKey _rowKey(String key) => _rowKeys.putIfAbsent(key, GlobalKey.new);

  ScrollController _rowScroll(String key) =>
      _rowScrolls.putIfAbsent(key, ScrollController.new);

  /// Card slot width in a row: the card plus its 4 px padding each side.
  static const _cardExtent = PosterCard.width + 8;
  static const _rowPadding = 20.0;

  /// Scrolls [row] so card [i] is on screen (with a card of room past it),
  /// then focuses it — after a frame when the jump had to build it.
  void _focusCard(ArchiveRow row, int i) {
    final c = _rowScrolls[row.key];
    if (c != null && c.hasClients) {
      final pos = c.position;
      final start = _rowPadding + i * _cardExtent;
      double? to;
      if (start - _cardExtent < pos.pixels) {
        to = start - _cardExtent;
      } else if (start + 2 * _cardExtent > pos.pixels + pos.viewportDimension) {
        to = start + 2 * _cardExtent - pos.viewportDimension;
      }
      if (to != null) c.jumpTo(to.clamp(0.0, pos.maxScrollExtent));
    }
    final node = _node(row.key, i);
    if (node.context != null) {
      node.requestFocus();
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) node.requestFocus();
      });
    }
  }

  /// Provider rows ("Popular", "New", "Featured") are translated; a
  /// source's own catalog names are shown as sent. With a genre picked the
  /// rows say so: "Popular · Horror".
  String _rowTitle(ArchiveService service, ArchiveRow row) {
    if (row.isSearch) {
      return tr('Results for "{query}"', {'query': row.searchQuery});
    }
    if (row.isHistory) return tr('Recently watched');
    final title = row.source.streamOnly || row.source.tracker != null
        ? tr(row.title)
        : row.title;
    final genre = service.genre(_type);
    return genre == null ? title : '$title · ${_genreName(genre)}';
  }

  /// A genre's display name. Genres are ids sent to the source, so they're
  /// translated under `genre.` keys ("History" alone is watch history);
  /// one the dictionaries don't know (a source's own) is shown as sent.
  static String _genreName(String genre) {
    if (genre == ArchiveService.otherGenre) return tr('Other');
    final key = 'genre.$genre';
    final s = tr(key);
    return s == key ? genre : s;
  }

  /// Genre filter, in the floating bar's style: "All genres" then every
  /// genre the rows can be narrowed to, as a grid of pills (equal cells, so
  /// the D-pad moves predictably). Rows that can't be narrowed (the
  /// provider's "New") hide while a genre is picked.
  Future<void> _pickGenre(ArchiveService service) async {
    final type = _type;
    final current = service.genre(type);
    final genres = ['', ...service.genres(type)]; // '' = All genres
    final narrow = MediaQuery.sizeOf(context).width < 700;
    final picked = await showDialog<String>(
      context: context,
      barrierColor: Colors.black54,
      builder: (ctx) => _FloatingPanel(
        title: type == ArchiveType.movie
            ? tr('Movie genres')
            : tr('TV show genres'),
        width: narrow ? 360 : 660,
        child: Flexible(
          child: GridView.builder(
            shrinkWrap: true,
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: narrow ? 2 : 3,
              mainAxisExtent: 50,
              crossAxisSpacing: 8,
              mainAxisSpacing: 8,
            ),
            itemCount: genres.length,
            itemBuilder: (_, i) {
              final g = genres[i];
              final selected = g == (current ?? '');
              return _BarButton(
                autofocus: selected,
                expand: true,
                icon: i == 0
                    ? Icons.apps
                    : selected
                        ? Icons.check
                        : Icons.category_outlined,
                label: i == 0 ? tr('All genres') : _genreName(g),
                active: selected,
                onTap: () => Navigator.of(ctx).pop(g),
              );
            },
          ),
        ),
      ),
    );
    if (picked == null || !mounted || type != _type) return;
    setState(() {
      _focusedRow = 0;
      _focused = null;
      _focusedSource = null;
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
    await service.setGenre(type, picked.isEmpty ? null : picked);
  }

  /// Search for the current category: a field plus that category's recent
  /// searches as one-press pills (the first focused when there are any, so
  /// the keyboard doesn't open by itself).
  Future<void> _openSearch(ArchiveService service) async {
    final type = _type;
    final query = await showDialog<String>(
      context: context,
      barrierColor: Colors.black54,
      builder: (_) => _SearchPanel(
        title: type == ArchiveType.movie
            ? tr('Search movies')
            : tr('Search TV shows'),
        initial: service.searchQuery(type) ?? '',
        recent: service.recentSearches(type),
        onForgetRecent: () => service.forgetRecentSearches(type),
      ),
    );
    if (query == null || query.trim().isEmpty || !mounted) return;
    setState(() => _focusedRow = 0);
    if (_scroll.hasClients) _scroll.jumpTo(0);
    await service.search(type, query);
    if (!mounted || type != _type) return;
    final rows = service.rows(type);
    if (rows.isNotEmpty && rows.first.isSearch) {
      _lastIndex[rows.first.key] = 0;
      _rowScrolls[rows.first.key]?.jumpTo(0);
      _focusRow(rows, 0);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content:
              Text(tr('No results for "{query}"', {'query': query.trim()}))));
    }
  }

  void _clearSearch(ArchiveService service) {
    setState(() => _focusedRow = 0);
    if (_scroll.hasClients) _scroll.jumpTo(0);
    service.clearSearch(_type);
  }

  void _setType(ArchiveType type) {
    if (type == _type) return;
    setState(() {
      _type = type;
      _focusedRow = 0;
      _focused = null;
      _focusedSource = null;
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  /// Focuses row [r]'s remembered card and scrolls the row into view.
  void _focusRow(List<ArchiveRow> rows, int r) {
    if (rows.isEmpty) return;
    r = r.clamp(0, rows.length - 1);
    final row = rows[r];
    final i = (_lastIndex[row.key] ?? 0).clamp(0, row.items.length - 1);
    final ctx = _rowKey(row.key).currentContext;
    if (ctx != null) Scrollable.ensureVisible(ctx, alignment: 0.05);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusCard(row, i);
    });
  }

  KeyEventResult _onContentKey(
      List<ArchiveRow> rows, FocusNode _, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (rows.isEmpty) return KeyEventResult.ignored;
    final row = rows[_focusedRow.clamp(0, rows.length - 1)];
    final i = _lastIndex[row.key] ?? 0;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowDown) {
      if (_focusedRow < rows.length - 1) _focusRow(rows, _focusedRow + 1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      if (_focusedRow > 0) {
        _focusRow(rows, _focusedRow - 1);
      } else {
        _focusBar();
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowRight) {
      if (i < row.items.length - 1) _focusCard(row, i + 1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft) {
      if (i > 0) {
        _focusCard(row, i - 1);
      } else {
        _railScope.requestFocus();
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// Shows open the regular series page (episode cards, Play SxEy);
  /// movies the Archive movie page.
  void _open(ArchiveSource source, ArchiveMeta meta) {
    if (meta.type == ArchiveType.series) {
      openArchiveSeries(context, source, meta);
      return;
    }
    Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => ArchiveDetailScreen(source: source, preview: meta)));
  }

  void _openSources() {
    Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => const ArchiveSourcesScreen()));
  }

  /// Sign in to a Jellyfin/Emby server; its libraries become rows.
  void _connectMediaServer() {
    Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => const MediaServerScreen()));
  }

  @override
  Widget build(BuildContext context) {
    final service = context.watch<ArchiveService>();
    final rows = service.rows(_type);
    final narrow = MediaQuery.sizeOf(context).width < 700;
    final scheme = Theme.of(context).colorScheme;

    final focused = _focused;
    final backdrop = focused?.backgroundUrl ?? focused?.posterUrl;

    return PopScope(
      // Back from the rows (or the bar) goes to the rail first, then leaves.
      canPop: !_awayFromRail,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_awayFromRail) {
          _railScope.requestFocus();
        } else {
          // canPop was stale (built while the rows had focus): leave anyway.
          Navigator.of(context).pop();
        }
      },
      // Support Esc and a clickable Back action on desktop: rows -> rail -> exit.
      child: CallbackShortcuts(
        bindings: {
          if (Platform.isWindows)
            const SingleActivator(LogicalKeyboardKey.escape): () =>
                Navigator.of(context).maybePop(),
        },
        child: Scaffold(
          backgroundColor: Colors.black,
          body: Stack(
            children: [
              if (backdrop != null)
                Positioned(
                  top: 0,
                  right: 0,
                  left: narrow ? 0 : MediaQuery.sizeOf(context).width * 0.35,
                  height: MediaQuery.sizeOf(context).height * 0.6,
                  child: DetailBackdrop(url: backdrop, fadeLeft: true),
                ),
              SafeArea(
                child: narrow
                    ? Column(children: [
                        _buildTopBar(service),
                        _buildFloatingBar(service, rows),
                        Expanded(child: _buildContent(service, rows, scheme)),
                      ])
                    : Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          SizedBox(
                              width: 190, child: _buildRail(service, rows)),
                          Expanded(
                            child: Column(children: [
                              _buildFloatingBar(service, rows),
                              Expanded(
                                  child: _buildContent(service, rows, scheme)),
                            ]),
                          ),
                        ],
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildRail(ArchiveService service, List<ArchiveRow> rows) {
    return FocusScope(
      node: _railScope,
      child: Focus(
        // Right from anywhere in the rail = into the rows.
        onKeyEvent: (_, event) {
          if (event is KeyDownEvent &&
              event.logicalKey == LogicalKeyboardKey.arrowRight) {
            if (rows.isNotEmpty) {
              _focusRow(rows, _focusedRow);
            } else if (_emptyActionNode.context != null) {
              _emptyActionNode.requestFocus();
            }
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: Container(
          color: Colors.black.withValues(alpha: 0.55),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(10, 16, 10, 16),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(6, 0, 6, 12),
                child: Row(children: [
                  if (Platform.isWindows)
                    ExcludeFocus(
                      child: IconButton(
                        tooltip: tr('Back'),
                        icon: const Icon(Icons.arrow_back),
                        onPressed: () => Navigator.of(context).maybePop(),
                      ),
                    ),
                  Text(tr('Media Hub'),
                      style: const TextStyle(
                          fontSize: 20, fontWeight: FontWeight.w700)),
                ]),
              ),
              _RailTile(
                focusNode: _firstRailNode,
                icon: Icons.movie,
                label: tr('Movies'),
                selected: _type == ArchiveType.movie,
                onTap: () => _setType(ArchiveType.movie),
              ),
              _RailTile(
                icon: Icons.video_library,
                label: tr('TV Shows'),
                selected: _type == ArchiveType.series,
                onTap: () => _setType(ArchiveType.series),
              ),
              const Divider(height: 20, color: Colors.white24),
              _RailTile(
                icon: Icons.refresh,
                label: service.refreshing ? tr('Updating…') : tr('Refresh'),
                small: true,
                onTap: () => service.refresh(force: true),
              ),
              _RailTile(
                icon: Icons.extension_outlined,
                label: tr('Media Hub sources'),
                small: true,
                onTap: _openSources,
              ),
              _RailTile(
                icon: Icons.dns_outlined,
                label: tr('Connect Jellyfin / Emby'),
                small: true,
                onTap: _connectMediaServer,
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Phone / narrow window: the rail's two choices + sources as a row.
  Widget _buildTopBar(ArchiveService service) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
      child: FocusScope(
        node: _railScope,
        child: Row(children: [
          IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () => Navigator.of(context).maybePop(),
          ),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(children: [
                _RailTile(
                  focusNode: _firstRailNode,
                  icon: Icons.movie,
                  label: tr('Movies'),
                  selected: _type == ArchiveType.movie,
                  onTap: () => _setType(ArchiveType.movie),
                ),
                const SizedBox(width: 8),
                _RailTile(
                  icon: Icons.video_library,
                  label: tr('TV Shows'),
                  selected: _type == ArchiveType.series,
                  onTap: () => _setType(ArchiveType.series),
                ),
              ]),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () => service.refresh(force: true),
          ),
          IconButton(
            icon: const Icon(Icons.extension_outlined),
            onPressed: _openSources,
          ),
          IconButton(
            tooltip: tr('Connect Jellyfin / Emby'),
            icon: const Icon(Icons.dns_outlined),
            onPressed: _connectMediaServer,
          ),
        ]),
      ),
    );
  }

  /// Rows that get a jump button in the floating bar: all but search
  /// results (the lit Search button stands for those).
  List<int> _barRows(List<ArchiveRow> rows) => [
        for (var r = 0; r < rows.length; r++)
          if (!rows[r].isSearch) r,
      ];

  FocusNode _barRowNode(String rowKey) => _barRowNodes.putIfAbsent(
      rowKey, () => FocusNode(debugLabel: 'archive-bar-row'));

  /// A row's jump label: its own title, without the " · Genre" suffix
  /// (the Genre button shows that).
  String _barRowLabel(ArchiveRow row) {
    if (row.isHistory) return tr('Recently watched');
    return row.source.streamOnly || row.source.tracker != null
        ? tr(row.title)
        : row.title;
  }

  /// The floating bar's buttons, in order (for explicit Left/Right).
  List<FocusNode> _barNodes(ArchiveService service, List<ArchiveRow> rows) => [
        for (final r in _barRows(rows)) _barRowNode(rows[r].key),
        if (service.canSearch(_type)) _barSearchNode,
        if (service.searchQuery(_type) != null) _barClearNode,
        if (service.genres(_type).isNotEmpty) _barGenreNode,
      ];

  /// Up into the bar lands on the current row's jump button (else the
  /// first button).
  void _focusBar() {
    final service = context.read<ArchiveService>();
    final rows = service.rows(_type);
    final nodes = _barNodes(service, rows);
    if (nodes.isEmpty) return;
    final r = _focusedRow;
    final current = r >= 0 && r < rows.length && !rows[r].isSearch
        ? _barRowNodes[rows[r].key]
        : null;
    _focusBarNode(current ?? nodes.first);
  }

  /// The bar scrolls sideways when a source has many catalogs: bring the
  /// newly focused button into view.
  void _focusBarNode(FocusNode node) {
    node.requestFocus();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = node.context;
      if (mounted && ctx != null) {
        Scrollable.ensureVisible(ctx, alignment: 0.5);
      }
    });
  }

  /// The category's row jumps (Popular / New / Featured / Recently
  /// watched...) plus Search and Genre, centred at the top in the phone
  /// tab bar's floating pill. D-pad: Left/Right along it (Left past the
  /// first = rail), Down = the rows.
  Widget _buildFloatingBar(ArchiveService service, List<ArchiveRow> rows) {
    final nodes = _barNodes(service, rows);
    if (nodes.isEmpty) return const SizedBox.shrink();
    final narrow = MediaQuery.sizeOf(context).width < 700;
    final barRows = _barRows(rows);
    final hasTools =
        service.canSearch(_type) || service.genres(_type).isNotEmpty;
    void move(int delta) {
      final i = nodes.indexWhere((n) => n.hasFocus);
      final to = i + delta;
      if (to >= 0 && to < nodes.length) {
        _focusBarNode(nodes[to]);
      } else if (to < 0 && !narrow) {
        _railScope.requestFocus();
      }
    }

    final query = service.searchQuery(_type);
    final genre = service.genre(_type);
    final movies = _type == ArchiveType.movie;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      child: Center(
        child: FocusScope(
          node: _barScope,
          child: CallbackShortcuts(
            bindings: {
              const SingleActivator(LogicalKeyboardKey.arrowLeft): () =>
                  move(-1),
              const SingleActivator(LogicalKeyboardKey.arrowRight): () =>
                  move(1),
              const SingleActivator(LogicalKeyboardKey.arrowDown): () {
                if (rows.isNotEmpty) {
                  _focusRow(rows, _focusedRow);
                } else if (_emptyActionNode.context != null) {
                  _emptyActionNode.requestFocus();
                }
              },
              const SingleActivator(LogicalKeyboardKey.arrowUp): () {},
            },
            child: Container(
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                gradient: LinearGradient(colors: [
                  Colors.white.withValues(alpha: 0.10),
                  Colors.white.withValues(alpha: 0.04),
                ]),
                color: Colors.black,
                borderRadius: BorderRadius.circular(34),
                border: Border.all(color: Colors.white24),
                boxShadow: const [
                  BoxShadow(color: Colors.black54, blurRadius: 12),
                ],
              ),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final r in barRows)
                      _BarButton(
                        focusNode: _barRowNode(rows[r].key),
                        icon: rows[r].isHistory
                            ? Icons.history
                            : Icons.grid_view_rounded,
                        label: _barRowLabel(rows[r]),
                        onTap: () => _focusRow(rows, r),
                      ),
                    if (barRows.isNotEmpty && hasTools)
                      Container(
                        width: 1,
                        height: 24,
                        margin: const EdgeInsets.symmetric(horizontal: 6),
                        color: Colors.white24,
                      ),
                    if (service.canSearch(_type))
                      _BarButton(
                        focusNode: _barSearchNode,
                        icon: Icons.search,
                        label: service.searching
                            ? tr('Searching…')
                            : query ??
                                (movies
                                    ? tr('Search movies')
                                    : tr('Search TV shows')),
                        active: query != null,
                        onTap: () => _openSearch(service),
                      ),
                    if (query != null)
                      _BarButton(
                        focusNode: _barClearNode,
                        icon: Icons.close,
                        tooltip: tr('Clear search'),
                        onTap: () {
                          _clearSearch(service);
                          _focusBarNode(_barSearchNode);
                        },
                      ),
                    if (service.genres(_type).isNotEmpty)
                      _BarButton(
                        focusNode: _barGenreNode,
                        icon: Icons.category_outlined,
                        label: genre == null
                            ? (movies
                                ? tr('Movie genres')
                                : tr('TV show genres'))
                            : _genreName(genre),
                        active: genre != null,
                        onTap: () => _pickGenre(service),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildContent(
      ArchiveService service, List<ArchiveRow> rows, ColorScheme scheme) {
    if (service.sources.isEmpty) {
      return _EmptyState(
        text: tr(
            'Add a source to browse films and series. Any source that follows the catalog/stream add-on format works.'),
        action: tr('Add a source'),
        onAction: _openSources,
        focusNode: _emptyActionNode,
      );
    }
    if (rows.isEmpty) {
      if (service.refreshing) {
        return const Center(child: CircularProgressIndicator());
      }
      return _EmptyState(
        text: service.hasAny(_type)
            ? (service.lastError != null
                ? tr("Couldn't load the catalog: {error}",
                    {'error': service.lastError})
                : tr('Nothing here yet.'))
            : (_type == ArchiveType.movie
                ? tr('None of your sources has movies.')
                : tr('None of your sources has TV shows.')),
        action: tr('Refresh'),
        onAction: () => service.refresh(force: true),
        focusNode: _emptyActionNode,
        onUp: _focusBar,
      );
    }

    final focused = _focused;
    return FocusScope(
      node: _contentScope,
      child: Focus(
        onKeyEvent: (node, e) => _onContentKey(rows, node, e),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Hero: the focused title.
            SizedBox(
              height: 150,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 8),
                child: focused == null
                    ? const SizedBox.shrink()
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(focused.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  fontSize: 26, fontWeight: FontWeight.w700)),
                          const SizedBox(height: 6),
                          Wrap(spacing: 6, runSpacing: 4, children: [
                            if (focused.year != null)
                              DetailMetaChip(
                                  scale: 1, label: focused.year!, strong: true),
                            if (focused.runtime != null)
                              DetailMetaChip(scale: 1, label: focused.runtime!),
                            for (final g in focused.genres.take(3))
                              DetailMetaChip(scale: 1, label: g),
                            if (_focusedSource != null)
                              DetailMetaChip(
                                  scale: 1, label: _focusedSource!.name),
                          ]),
                          const SizedBox(height: 8),
                          if (focused.description != null)
                            Flexible(
                              child: SizedBox(
                                width: 560,
                                child: Text(focused.description!,
                                    maxLines: 3,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                        fontSize: 13, color: Colors.white70)),
                              ),
                            ),
                        ],
                      ),
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                controller: _scroll,
                padding: const EdgeInsets.only(bottom: 40),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (var r = 0; r < rows.length; r++)
                      _buildRow(service, rows, r, scheme),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRow(ArchiveService service, List<ArchiveRow> rows, int r,
      ColorScheme scheme) {
    final row = rows[r];
    return Column(
      key: _rowKey(row.key),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 14, 24, 6),
          child: Text(_rowTitle(service, row),
              style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: r == _focusedRow && _contentScope.hasFocus
                      ? scheme.primary
                      : Colors.white)),
        ),
        SizedBox(
          height: PosterCard.height + 16,
          child: ListView.builder(
            controller: _rowScroll(row.key),
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: _rowPadding),
            itemCount: row.items.length,
            itemBuilder: (_, i) {
              final meta = row.items[i];
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: PosterCard(
                  focusNode: _node(row.key, i),
                  title: meta.name,
                  imageUrl: meta.posterUrl,
                  rating: meta.year,
                  tapToPreview:
                      Theme.of(context).platform == TargetPlatform.android &&
                          MediaQuery.sizeOf(context).width < 700,
                  onTap: () => _open(row.sourceAt(i), meta),
                  // Hold OK on a watched title: out of the history.
                  onToggleFavorite: row.isHistory
                      ? () => context
                          .read<ArchiveService>()
                          .removeFromHistory(row.sourceAt(i), meta)
                      : null,
                  onFocusGained: () {
                    _lastIndex[row.key] = i;
                    if (i >= row.items.length - 12) {
                      context.read<ArchiveService>().loadMore(row);
                    }
                    if (_focused?.id == meta.id && _focusedRow == r) return;
                    setState(() {
                      _focusedRow = r;
                      _focused = meta;
                      _focusedSource = row.sourceAt(i);
                    });
                  },
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// A button of the floating Search / Genre bar: the phone tab bar's pill
/// look, gold outline when focused, lit when its filter is on.
class _BarButton extends StatefulWidget {
  const _BarButton({
    this.focusNode,
    required this.icon,
    required this.onTap,
    this.label,
    this.tooltip,
    this.active = false,
    this.autofocus = false,
    this.expand = false,
  });

  final FocusNode? focusNode;
  final bool autofocus;

  /// Fill the width (grid cells), content centred.
  final bool expand;
  final IconData icon;
  final String? label;
  final String? tooltip;
  final bool active;
  final VoidCallback onTap;

  @override
  State<_BarButton> createState() => _BarButtonState();
}

class _BarButtonState extends State<_BarButton> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final lit = _focused || widget.active;
    final button = InkWell(
      focusNode: widget.focusNode,
      autofocus: widget.autofocus,
      onFocusChange: (f) => setState(() => _focused = f),
      onTap: widget.onTap,
      borderRadius: BorderRadius.circular(28),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: EdgeInsets.symmetric(
            horizontal: widget.label == null ? 10 : 18, vertical: 9),
        decoration: BoxDecoration(
          color:
              lit ? Colors.white.withValues(alpha: 0.14) : Colors.transparent,
          borderRadius: BorderRadius.circular(28),
          border: Border.all(
              color: _focused
                  ? scheme.primary
                  : widget.active
                      ? Colors.white24
                      : Colors.transparent,
              width: _focused ? 2 : 1),
        ),
        child: Row(
            mainAxisSize: widget.expand ? MainAxisSize.max : MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(widget.icon,
                  size: 20, color: lit ? scheme.primary : Colors.white70),
              if (widget.label != null) ...[
                const SizedBox(width: 8),
                ConstrainedBox(
                  constraints: BoxConstraints(
                      maxWidth: widget.expand ? double.infinity : 220),
                  child: Text(widget.label!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          color: lit ? Colors.white : Colors.white70,
                          fontSize: 14,
                          fontWeight: widget.active
                              ? FontWeight.w700
                              : FontWeight.w500)),
                ),
              ],
            ]),
      ),
    );
    return widget.tooltip == null
        ? button
        : Tooltip(message: widget.tooltip!, child: button);
  }
}

/// A dialog in the floating bar's style: the same dark gradient pill
/// shape, rounded, with a title.
class _FloatingPanel extends StatelessWidget {
  const _FloatingPanel(
      {required this.title, required this.child, this.width = 520});

  final String title;
  final Widget child;
  final double width;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      child: ConstrainedBox(
        constraints: BoxConstraints(
            maxWidth: width,
            maxHeight: MediaQuery.sizeOf(context).height * 0.8),
        child: Container(
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Colors.white.withValues(alpha: 0.12),
                Colors.white.withValues(alpha: 0.04),
              ],
            ),
            color: const Color(0xF20D0D10),
            borderRadius: BorderRadius.circular(28),
            border: Border.all(color: Colors.white24),
            boxShadow: const [BoxShadow(color: Colors.black87, blurRadius: 24)],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(6, 0, 6, 14),
                child: Text(title,
                    style: const TextStyle(
                        fontSize: 18, fontWeight: FontWeight.w700)),
              ),
              child,
            ],
          ),
        ),
      ),
    );
  }
}

/// Search box + the category's recent searches. Pops the query to search.
class _SearchPanel extends StatefulWidget {
  const _SearchPanel({
    required this.title,
    required this.initial,
    required this.recent,
    required this.onForgetRecent,
  });

  final String title;
  final String initial;
  final List<String> recent;
  final Future<void> Function() onForgetRecent;

  @override
  State<_SearchPanel> createState() => _SearchPanelState();
}

class _SearchPanelState extends State<_SearchPanel> {
  late final _controller = TextEditingController(text: widget.initial);
  final _fieldNode = FocusNode(debugLabel: 'archive-search-field');
  final _firstRecentNode = FocusNode(debugLabel: 'archive-search-recent');
  late List<String> _recent = widget.recent;

  @override
  void dispose() {
    _controller.dispose();
    _fieldNode.dispose();
    _firstRecentNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return _FloatingPanel(
      title: widget.title,
      child: Flexible(
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Down from the field = the recent searches (a text field
              // keeps the arrows otherwise).
              CallbackShortcuts(
                bindings: {
                  if (_recent.isNotEmpty)
                    const SingleActivator(LogicalKeyboardKey.arrowDown): () =>
                        _firstRecentNode.requestFocus(),
                },
                child: TvTextFieldGate(
                  focusNode: _fieldNode,
                  builder: (context, readOnly) => TextField(
                    controller: _controller,
                    focusNode: _fieldNode,
                    readOnly: readOnly,
                    autofocus: _recent.isEmpty,
                    textInputAction: TextInputAction.search,
                    decoration: InputDecoration(
                      hintText: tr('Title'),
                      prefixIcon: const Icon(Icons.search),
                      filled: true,
                      fillColor: Colors.white.withValues(alpha: 0.06),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(28),
                        borderSide: const BorderSide(color: Colors.white24),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(28),
                        borderSide: const BorderSide(color: Colors.white24),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(28),
                        borderSide: BorderSide(color: scheme.primary, width: 2),
                      ),
                    ),
                    onSubmitted: (v) => Navigator.of(context).pop(v),
                  ),
                ),
              ),
              if (_recent.isNotEmpty) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 16, 8, 8),
                  child: Text(tr('Recent searches'),
                      style:
                          const TextStyle(fontSize: 13, color: Colors.white54)),
                ),
                for (final (i, q) in _recent.indexed)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: _BarButton(
                      focusNode: i == 0 ? _firstRecentNode : null,
                      autofocus: i == 0,
                      expand: true,
                      icon: Icons.history,
                      label: q,
                      onTap: () => Navigator.of(context).pop(q),
                    ),
                  ),
                _BarButton(
                  expand: true,
                  icon: Icons.delete_outline,
                  label: tr('Clear recent searches'),
                  onTap: () async {
                    await widget.onForgetRecent();
                    if (!mounted) return;
                    setState(() => _recent = const []);
                    _fieldNode.requestFocus();
                  },
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// A rail row: same focus look as the detail pages' pills.
class _RailTile extends StatefulWidget {
  const _RailTile({
    required this.icon,
    required this.label,
    required this.onTap,
    this.selected = false,
    this.small = false,
    this.focusNode,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool selected;
  final bool small;
  final FocusNode? focusNode;

  @override
  State<_RailTile> createState() => _RailTileState();
}

class _RailTileState extends State<_RailTile> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fg = (_focused || widget.selected) ? scheme.primary : Colors.white;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: InkWell(
        focusNode: widget.focusNode,
        onFocusChange: (f) => setState(() => _focused = f),
        onTap: widget.onTap,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: EdgeInsets.symmetric(
              horizontal: 10, vertical: widget.small ? 7 : 10),
          decoration: detailFocusDecoration(scheme,
              focused: _focused, selected: widget.selected, radius: 10),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(widget.icon, size: widget.small ? 16 : 20, color: fg),
            const SizedBox(width: 10),
            Flexible(
              child: Text(widget.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: fg,
                      fontSize: widget.small ? 13 : 15,
                      fontWeight:
                          widget.selected ? FontWeight.w700 : FontWeight.w500)),
            ),
          ]),
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState(
      {required this.text,
      required this.action,
      required this.onAction,
      required this.focusNode,
      this.onUp});

  final FocusNode focusNode;
  final VoidCallback? onUp;
  final String text;
  final String action;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.local_movies_outlined,
              size: 48, color: Colors.white38),
          const SizedBox(height: 12),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Text(text,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70)),
          ),
          const SizedBox(height: 16),
          CallbackShortcuts(
            bindings: {
              if (onUp != null)
                const SingleActivator(LogicalKeyboardKey.arrowUp): onUp!,
            },
            child: OutlinedButton(
                focusNode: focusNode, onPressed: onAction, child: Text(action)),
          ),
        ]),
      ),
    );
  }
}
