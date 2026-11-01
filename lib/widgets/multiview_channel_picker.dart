import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../models/channel.dart';
import '../models/m3u_group.dart';
import '../utils/live_category_folders.dart';
import 'live_category_icon.dart';
import '../services/epg_service.dart';
import '../services/storage_service.dart';
import '../services/app_preferences.dart';
import 'live_category_folders.dart';
import 'live_navigation_body.dart';
import '../services/playback_service.dart';
import '../services/playlist_manager.dart';
import '../services/multiview_sports.dart';
import 'cached_channel_logo.dart';
import 'compact_choice_list.dart';
import 'tv_text_field_gate.dart';
import 'player_dialog.dart';
import '../screens/tv_home_screen.dart'
    show LiveGuideSelectionViewport, LiveGuideSelectionViewportState;
import '../screens/sports_screen.dart';

class MultiviewChannelPicker extends StatefulWidget {
  const MultiviewChannelPicker(
      {super.key,
      required this.screenNumber,
      this.selectedIds = const {},
      this.currentChannel,
      this.initialGuideView = true,
      this.unavailableReason});
  final int screenNumber;
  final Set<String> selectedIds;
  final Channel? currentChannel;
  final bool initialGuideView;
  final String? Function(Channel)? unavailableReason;
  @override
  State<MultiviewChannelPicker> createState() => _MultiviewChannelPickerState();
}

class _MultiviewChannelPickerState extends State<MultiviewChannelPicker> {
  late bool _guideView = widget.initialGuideView;
  final _guide = GlobalKey<LiveGuideSelectionViewportState>();
  final _tabs =
      List.generate(3, (i) => FocusNode(debugLabel: 'multiview-view-$i'));
  final _query = TextEditingController();
  final _search = FocusNode(debugLabel: 'multiview-search');
  final _results = FocusNode(debugLabel: 'multiview-results');
  final _scroll = ScrollController();
  final _emptyAction = FocusNode(debugLabel: 'multiview-empty-action');
  final _highlight = ValueNotifier<int>(-1);
  final _shelves =
      List.generate(5, (i) => FocusNode(debugLabel: 'multiview-shelf-$i'));
  List<Channel> _catalog = const [], _rows = const [];
  List<Channel> _recent = const [];
  final Map<String, String> _groups = {};
  final Map<String, List<Channel>> _byGroup = {};
  final Map<String, M3uGroup> _groupModels = {};
  final Map<String, String> _groupSections = {};
  List<Channel> _favourites = const [];
  List<Channel>? _sports;
  List<Channel>? _selectedGroupRows;
  bool _sportsOpen = false, _railOpen = true;
  Widget? _railWidget;
  (String?, String)? _railSelection;
  List<M3uGroup> _categoryGroups = const [];
  Map<String, String> _layouts = const {}, _playlistNames = const {};
  final _railNodes = <String, FocusNode>{};
  bool get _wide => MediaQuery.sizeOf(context).width >= 650;
  bool get _tv => context.read<AppPreferences>().isTelevision;
  String _shelf = 'Recent';
  String? _group;
  Timer? _debounce;
  int _generation = 0, _index = 0;
  bool _loading = true, _indexing = true;
  String? _loadError;
  bool _explaining = false;
  static String _groupKey(Channel c) => '${c.playlistId}\u0000${c.group}';
  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _indexing = true;
      _loadError = null;
    });
    try {
      final p = context.read<PlaylistManager>();
      await p.ensureLiveChannelsLoaded();
      if (!mounted) return;
      _catalog = p.visibleLiveChannels;
      final history = context.read<PlaybackService>().recentlyPlayed;
      final recentIds = history.map((c) => c.id).toSet();
      final currentRecent = <String, Channel>{};
      final playable = <Channel>[], favourites = <Channel>[];
      _groups.clear();
      _byGroup.clear();
      _groupModels.clear();
      _groupSections.clear();
      final names = {
        for (final profile in p.profiles) profile.id: profile.name
      };
      for (var i = 0; i < _catalog.length; i++) {
        if (i % 512 == 511) {
          await Future<void>.delayed(Duration.zero);
          if (!mounted) return;
        }
        final c = _catalog[i];
        if (!Channel.isLiveId(c.rawId) || c.name.trimLeft().startsWith('###')) {
          continue;
        }
        playable.add(c);
        if (c.isFavorite) favourites.add(c);
        if (recentIds.contains(c.id)) currentRecent[c.id] = c;
        (_byGroup[_groupKey(c)] ??= []).add(c);
      }
      _catalog = playable;
      _favourites = favourites;
      _sports = null;
      final metadata = [
        for (final channels in _byGroup.values)
          M3uGroup(
              title: channels.first.group,
              playlistId: channels.first.playlistId,
              channels: channels)
      ];
      _railWidget = null;
      _categoryGroups = metadata;
      _playlistNames = names;
      _layouts = {
        for (final profile in p.profiles) profile.id: profile.categoryLayout
      };
      final tree = buildLiveCategoryTree(metadata, layouts: _layouts);
      void indexGroups(LiveCategoryNode node, List<String> path) {
        final group = node.group;
        if (group != null) {
          final key = '${group.playlistId}\u0000${group.title}';
          _groupModels[key] = group;
          _groups[key] = group is LiveCategoryCollection
              ? group.displayName
              : liveCategoryLabel(group.title, inFolder: path.isNotEmpty);
          _groupSections[key] = [
            if (names.length > 1) names[group.playlistId] ?? '',
            ...path
          ].join(' · ');
        } else {
          for (final child in node.children) {
            indexGroups(child, [...path, node.label]);
          }
        }
      }

      for (final node in tree) {
        indexGroups(node, const []);
      }
      final current = widget.currentChannel;
      if (current != null && _group == null) {
        _group = _groupKey(current);
        _selectedGroupRows = _byGroup[_group];
        _shelf = 'All';
      }
      _recent = [
        for (final old in history)
          if (currentRecent[old.id] case final current?) current
      ];
      if (_recent.isEmpty && _shelf == 'Recent') {
        _shelf = 'All';
      }
      _indexing = false;
      await _filter();
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _indexing = false;
          _loadError = 'Channels could not be loaded.';
        });
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _results.hasFocus) _emptyAction.requestFocus();
        });
      }
    }
  }

  @override
  void dispose() {
    _generation++;
    _debounce?.cancel();
    _query.dispose();
    _search.dispose();
    _results.dispose();
    _scroll.dispose();
    _emptyAction.dispose();
    _highlight.dispose();
    for (final node in [..._shelves, ..._tabs, ..._railNodes.values]) {
      node.dispose();
    }
    super.dispose();
  }

  Future<void> _filter() async {
    _debounce?.cancel();
    if (!mounted || _indexing) return;
    final selection = (_group, _shelf);
    if (_railSelection != selection) {
      _railSelection = selection;
      _railWidget = null;
    }
    final generation = ++_generation;
    final q = _query.text.trim().toLowerCase();
    final group = _group, shelf = _shelf;
    setState(() => _loading = true);
    if (group == null && q.isEmpty && shelf == 'Sports' && _sports == null) {
      final rows = <Channel>[];
      for (var i = 0; i < _catalog.length; i++) {
        if (i % 256 == 255) {
          await Future<void>.delayed(Duration.zero);
          if (!mounted || generation != _generation) return;
        }
        if (MultiviewSports.isSports(_catalog[i])) rows.add(_catalog[i]);
      }
      _sports = rows;
    }
    final source = group != null
        ? (_selectedGroupRows ?? _byGroup[group] ?? const <Channel>[])
        : q.isNotEmpty
            ? _catalog
            : switch (shelf) {
                'Recent' => _recent,
                'Favourites' => _favourites,
                'Sports' => _sports ?? const <Channel>[],
                _ => _catalog,
              };
    // Shelf changes reuse bounded indices; only a nonempty query scans rows.
    final found = q.isEmpty ? source : <Channel>[];
    final programmeMatches = <String, bool>{};
    final epg = context.read<EpgService>();
    if (q.isNotEmpty) {
      for (var i = 0; i < source.length; i++) {
        if (i % 256 == 255) {
          await Future<void>.delayed(Duration.zero);
          if (!mounted || generation != _generation) return;
        }
        final c = source[i];
        if (c.name.toLowerCase().contains(q) ||
            programmeMatches.putIfAbsent(c.epgId, () {
              final now = epg.getCurrentProgram(c.epgId);
              return now != null &&
                  (now.title.toLowerCase().contains(q) ||
                      (now.description?.toLowerCase().contains(q) ?? false));
            })) {
          found.add(c);
        }
      }
    }
    if (!mounted || generation != _generation) return;
    setState(() {
      _rows = found;
      _loading = false;
      _index = 0;
    });
    _highlight.value = _results.hasFocus ? 0 : -1;
    if (_scroll.hasClients) _scroll.jumpTo(0);
    if (_results.hasFocus) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _focusResults();
      });
    }
  }

  void _focusResults() {
    if (_guideView && !_loading && _rows.isNotEmpty) {
      _guide.currentState?.focusEntry();
      return;
    }
    if (!_loading && _rows.isEmpty) {
      _emptyAction.requestFocus();
    } else {
      _results.requestFocus();
    }
  }

  void _searchChanged(String _) {
    _generation++;
    // An OK press during debounce must not select a row from the old query.
    setState(() => _loading = true);
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 220), _filter);
  }

  Future<void> _clearSearch() async {
    _query.clear();
    await _filter();
    if (mounted) _focusResults();
  }

  Future<void> _choose(Channel c, {bool fromSports = false}) async {
    if (_loading || _explaining) return;
    final reason = widget.unavailableReason?.call(c) ??
        (widget.selectedIds.contains(c.id)
            ? 'This channel is already playing in another screen. Choose a different channel here.'
            : null);
    if (reason == null) {
      Navigator.pop(context, c);
      return;
    }
    _explaining = true;
    await showDialog<void>(
        context: context,
        builder: (ctx) => PlayerDialog(
            title: 'Choose another channel',
            icon: Icons.info_outline,
            child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(reason),
                      const SizedBox(height: 12),
                      TextButton(
                          autofocus: true,
                          onPressed: () => Navigator.pop(ctx),
                          child: const Text('Back to channels')),
                    ]))));
    _explaining = false;
    if (mounted && !fromSports) _focusResults();
  }

  Future<void> _openSports() async {
    if (_sportsOpen) return;
    _sportsOpen = true;
    final channel = await Navigator.of(context).push<Channel>(PageRouteBuilder(
        transitionDuration: Duration.zero,
        reverseTransitionDuration: Duration.zero,
        pageBuilder: (_, __, ___) => SportsScreen(
            selectionTitle: 'Sports · screen ${widget.screenNumber}',
            onChooseChannel: (c) => _choose(c, fromSports: true))));
    _sportsOpen = false;
    if (!mounted) return;
    if (channel != null) {
      await _choose(channel);
    } else {
      _tabs[1].requestFocus();
    }
  }

  void _move(int delta, double rowHeight) {
    if (_rows.isEmpty) return;
    _index = (_index + delta).clamp(0, _rows.length - 1);
    _highlight.value = _index;
    if (!_scroll.hasClients) return;
    final p = _scroll.position, top = _index * rowHeight;
    if (top < p.pixels) {
      _scroll.jumpTo(top.clamp(0, p.maxScrollExtent));
    } else if (top + rowHeight > p.pixels + p.viewportDimension) {
      _scroll.jumpTo(
          (top + rowHeight - p.viewportDimension).clamp(0, p.maxScrollExtent));
    }
  }

  Future<void> _pickGroup() async {
    final filter = TextEditingController();
    final entries = _groups.entries.toList();
    final group = await showDialog<String>(
        context: context,
        builder: (ctx) => StatefulBuilder(builder: (ctx, update) {
              final query = filter.text.trim().toLowerCase();
              final matches = entries
                  .where((e) => '${e.value} ${_groupSections[e.key] ?? ''}'
                      .toLowerCase()
                      .contains(query))
                  .toList();
              return Dialog(
                  child: SizedBox(
                      width: 520,
                      height: MediaQuery.sizeOf(ctx).height * .8,
                      child: Column(children: [
                        Padding(
                            padding: const EdgeInsets.fromLTRB(16, 12, 4, 0),
                            child: Row(children: [
                              const Expanded(
                                  child: Text('Channel group',
                                      style: TextStyle(
                                          fontSize: 16,
                                          fontWeight: FontWeight.w600))),
                              IconButton(
                                  tooltip: 'Close',
                                  onPressed: () => Navigator.pop(ctx),
                                  icon: const Icon(Icons.close))
                            ])),
                        Padding(
                            padding: const EdgeInsets.all(12),
                            child: FocusNodeOwner(
                                builder: (_, node) => TvTextFieldGate(
                                    focusNode: node,
                                    builder: (_, readOnly) => TextField(
                                        controller: filter,
                                        focusNode: node,
                                        readOnly: readOnly,
                                        decoration: const InputDecoration(
                                            prefixIcon: Icon(Icons.search),
                                            hintText: 'Find group'),
                                        onChanged: (_) => update(() {}))))),
                        Expanded(
                            child: CompactChoiceList(
                                choices: [
                              CompactChoice(
                                  id: '',
                                  leading: const Icon(Icons.list, size: 20),
                                  title: 'All channels',
                                  onTap: () => Navigator.pop(ctx, '')),
                              for (final e in matches)
                                CompactChoice(
                                    id: e.key,
                                    title: e.value,
                                    group:
                                        _groupSections[e.key]?.isEmpty == true
                                            ? null
                                            : _groupSections[e.key],
                                    leading: LiveCategoryIcon(label: e.value),
                                    trailing: _group == e.key
                                        ? const Icon(Icons.check, size: 16)
                                        : null,
                                    onTap: () => Navigator.pop(ctx, e.key))
                            ],
                                rowHeight: 42,
                                polished: true,
                                resetScrollKey: query,
                                selected: _group)),
                      ])));
            }));
    // TextField remains mounted for the dialog's reverse transition.
    await Future<void>.delayed(const Duration(milliseconds: 250));
    filter.dispose();
    if (!mounted || group == null) return;
    await _selectGroup(group.isEmpty ? null : group);
  }

  Future<void> _selectGroup(String? group, {M3uGroup? model}) async {
    _railWidget = null;
    setState(() {
      _group = group;
      _shelf = 'All';
      _query.clear();
      _loading = true;
    });
    final selected = model ?? _groupModels[_group];
    if (selected is LiveCategoryCollection) {
      // Resolve a collection once on selection, never during guide rendering.
      final rows = <Channel>[];
      final token = ++_generation;
      for (var i = 0; i < _catalog.length; i++) {
        if (i % 384 == 383) {
          await Future<void>.delayed(Duration.zero);
          if (!mounted || token != _generation) return;
        }
        if (selected.contains(_catalog[i])) rows.add(_catalog[i]);
      }
      _selectedGroupRows = selected
          .select(rows)
          .where((c) => !c.name.trimLeft().startsWith('###'))
          .toList();
    } else {
      _selectedGroupRows = _group == null ? null : _byGroup[_group];
    }
    await _filter();
    if (mounted) _focusResults();
  }

  Future<void> _selectShelf(String shelf) async {
    _railWidget = null;
    setState(() {
      _shelf = shelf;
      _group = null;
      _selectedGroupRows = null;
      _query.clear();
    });
    await _filter();
    if (mounted) _focusResults();
  }

  void _showCategories() {
    if (!_wide) {
      _shelves[4].requestFocus();
      return;
    }
    if (!_railOpen) setState(() => _railOpen = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final node = _railNodes[_group];
      if (node?.context != null) {
        node!.requestFocus();
      } else {
        _shelves[_group == null
                ? ['Recent', 'Favourites', 'Sports', 'All']
                    .indexOf(_shelf)
                    .clamp(0, 3)
                : 3]
            .requestFocus();
      }
    });
  }

  Widget _categoryRail() => Focus(
        onKeyEvent: (_, event) {
          if (event is KeyUpEvent) return KeyEventResult.ignored;
          if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
            _focusResults();
            return KeyEventResult.handled;
          }
          if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
            Navigator.of(context).maybePop();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: ColoredBox(
          color: const Color(0xFF141D26),
          child: SingleChildScrollView(
            key: const ValueKey('multiview-category-rail'),
            padding: const EdgeInsets.fromLTRB(5, 4, 5, 8),
            child: Column(children: [
              for (final item in [
                ('Favourites', Icons.star, 'Favourites'),
                ('Recent', Icons.history, 'History'),
                ('All', Icons.list, 'All channels'),
                ('Sports', Icons.sports, 'Sport channels'),
              ])
                _MultiviewCategoryRow(
                  label: item.$3,
                  leading: Icon(item.$2, size: 18),
                  node: _shelves[['Recent', 'Favourites', 'Sports', 'All']
                      .indexOf(item.$1)],
                  selected: _group == null && _shelf == item.$1,
                  onTap: () => _selectShelf(item.$1),
                ),
              LiveCategoryFolders(
                groups: _categoryGroups,
                layouts: _layouts,
                storage: context.read<StorageService>(),
                selectedKey: _group?.replaceFirst('\u0000', '::'),
                playlistName: (id) => _playlistNames[id] ?? '',
                rowBuilder: (group, label) {
                  final key = '${group.playlistId}\u0000${group.title}';
                  return _MultiviewCategoryRow(
                    label: label ?? group.title,
                    leading: LiveCategoryIcon(
                        label: group is LiveCategoryCollection
                            ? group.sources.firstOrNull?.title ??
                                group.displayName
                            : group.title),
                    node: _railNodes.putIfAbsent(key,
                        () => FocusNode(debugLabel: 'multiview-category-$key')),
                    selected: _group == key,
                    onTap: () => _selectGroup(key, model: group),
                  );
                },
              ),
            ]),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final epg = context.read<EpgService>();
    final rowHeight = 64.0 +
        (MediaQuery.textScalerOf(context).scale(12) - 12).clamp(0, 12) * 3;
    final wide = MediaQuery.sizeOf(context).width >= 650;
    final sources = Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Focus(
            onKeyEvent: (_, e) {
              if (e is KeyUpEvent) return KeyEventResult.ignored;
              final at = _tabs.indexWhere((n) => n.hasFocus);
              if (at < 0) return KeyEventResult.ignored;
              if (e.logicalKey == LogicalKeyboardKey.arrowDown) {
                _search.requestFocus();
              } else if (e.logicalKey == LogicalKeyboardKey.arrowLeft ||
                  e.logicalKey == LogicalKeyboardKey.arrowRight) {
                _tabs[(at +
                            (e.logicalKey == LogicalKeyboardKey.arrowRight
                                ? 1
                                : -1))
                        .clamp(0, 2)]
                    .requestFocus();
              } else {
                return KeyEventResult.ignored;
              }
              return KeyEventResult.handled;
            },
            child: Row(children: [
              Expanded(
                  child: TextButton.icon(
                      focusNode: _tabs[0],
                      style: TextButton.styleFrom(
                          backgroundColor: _guideView
                              ? Theme.of(context)
                                  .colorScheme
                                  .primary
                                  .withValues(alpha: .12)
                              : null,
                          visualDensity: VisualDensity.compact,
                          minimumSize: const Size(0, 32),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(5)),
                          textStyle: const TextStyle(fontSize: 12),
                          padding: const EdgeInsets.symmetric(horizontal: 6)),
                      onPressed: () {
                        setState(() => _guideView = true);
                        WidgetsBinding.instance.addPostFrameCallback((_) {
                          if (mounted) _focusResults();
                        });
                      },
                      icon: const Icon(Icons.live_tv, size: 18),
                      label: const Text('Live TV guide'))),
              const SizedBox(width: 8),
              Expanded(
                  child: TextButton.icon(
                      focusNode: _tabs[1],
                      style: TextButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          minimumSize: const Size(0, 32),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(5)),
                          textStyle: const TextStyle(fontSize: 12),
                          padding: const EdgeInsets.symmetric(horizontal: 6)),
                      onPressed: _loading ? null : _openSports,
                      icon: const Icon(Icons.sports, size: 18),
                      label: const Text('Sports events'))),
              IconButton(
                  focusNode: _tabs[2],
                  visualDensity: VisualDensity.compact,
                  tooltip: _guideView
                      ? 'Compact channel list'
                      : 'Show programme guide',
                  icon: Icon(
                      _guideView
                          ? Icons.view_list_outlined
                          : Icons.calendar_view_week,
                      size: 20),
                  onPressed: () => setState(() => _guideView = !_guideView)),
            ])));
    return PopScope(
        canPop: !wide || _railOpen,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop && wide && !_railOpen) _showCategories();
        },
        child: Scaffold(
            backgroundColor: const Color(0xFF111820),
            appBar: AppBar(
                title: Text(
                    '${widget.currentChannel == null ? 'Add channel' : 'Change channel'} · screen ${widget.screenNumber}',
                    style: const TextStyle(fontSize: 15)),
                toolbarHeight: 42,
                actions: wide ? [SizedBox(width: 350, child: sources)] : null),
            body: SafeArea(
                child: Row(children: [
              if (wide)
                Offstage(
                  offstage: _tv && !_railOpen,
                  child: SizedBox(
                      width: _tv ? 210 : 180,
                      child: _railWidget ??= _categoryRail()),
                ),
              Expanded(
                  child: Column(children: [
                if (!wide) sources,
                Padding(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
                    child: Focus(
                        onKeyEvent: (_, e) {
                          if (e is KeyDownEvent &&
                              e.logicalKey == LogicalKeyboardKey.arrowUp &&
                              _search.hasFocus) {
                            _tabs[0].requestFocus();
                            return KeyEventResult.handled;
                          }
                          if (e is KeyDownEvent &&
                              e.logicalKey == LogicalKeyboardKey.arrowDown &&
                              _search.hasFocus) {
                            wide ? _focusResults() : _shelves[0].requestFocus();
                            return KeyEventResult.handled;
                          }
                          return KeyEventResult.ignored;
                        },
                        child: TvTextFieldGate(
                            focusNode: _search,
                            builder: (_, readOnly) => TextField(
                                key: const ValueKey('multiview-channel-search'),
                                controller: _query,
                                focusNode: _search,
                                readOnly: readOnly,
                                style: const TextStyle(fontSize: 13),
                                decoration: InputDecoration(
                                    contentPadding: const EdgeInsets.symmetric(
                                        horizontal: 10, vertical: 8),
                                    prefixIconConstraints: const BoxConstraints(
                                        minWidth: 36, minHeight: 36),
                                    suffixIconConstraints: const BoxConstraints(
                                        minWidth: 36, minHeight: 36),
                                    filled: true,
                                    fillColor: Theme.of(context)
                                        .colorScheme
                                        .surfaceContainerLow,
                                    border: OutlineInputBorder(
                                        borderRadius: BorderRadius.circular(5),
                                        borderSide: BorderSide.none),
                                    isDense: true,
                                    prefixIcon:
                                        const Icon(Icons.search, size: 20),
                                    hintText: _group == null
                                        ? 'Search channels or current programmes'
                                        : 'Search channels or programmes in this group',
                                    suffixIcon: _query.text.isEmpty
                                        ? null
                                        : IconButton(
                                            tooltip: 'Clear search',
                                            onPressed: _clearSearch,
                                            icon: const Icon(Icons.close,
                                                size: 18))),
                                onChanged: _searchChanged,
                                onSubmitted: (_) async {
                                  _debounce?.cancel();
                                  await _filter();
                                  if (mounted) _focusResults();
                                })))),
                if (!wide)
                  Focus(
                      onKeyEvent: (_, e) {
                        if (e is KeyUpEvent) return KeyEventResult.ignored;
                        final at = _shelves.indexWhere((n) => n.hasFocus);
                        if (at < 0) return KeyEventResult.ignored;
                        final k = e.logicalKey;
                        if (k == LogicalKeyboardKey.arrowDown) {
                          _focusResults();
                        } else if (k == LogicalKeyboardKey.arrowUp) {
                          _search.requestFocus();
                        } else if (k == LogicalKeyboardKey.arrowLeft ||
                            k == LogicalKeyboardKey.arrowRight) {
                          _shelves[(at +
                                      (k == LogicalKeyboardKey.arrowRight
                                          ? 1
                                          : -1))
                                  .clamp(0, 4)]
                              .requestFocus();
                        } else {
                          return KeyEventResult.ignored;
                        }
                        return KeyEventResult.handled;
                      },
                      child: SizedBox(
                          height: 36,
                          child: ListView(
                              scrollDirection: Axis.horizontal,
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 12),
                              children: [
                                for (final shelf in [
                                  'Recent',
                                  'Favourites',
                                  'Sports',
                                  'All'
                                ])
                                  Padding(
                                      padding: const EdgeInsets.only(right: 5),
                                      child: TextButton(
                                          focusNode: _shelves[[
                                            'Recent',
                                            'Favourites',
                                            'Sports',
                                            'All'
                                          ].indexOf(shelf)],
                                          style: TextButton.styleFrom(
                                              visualDensity:
                                                  VisualDensity.compact,
                                              shape: RoundedRectangleBorder(
                                                  borderRadius:
                                                      BorderRadius.circular(5)),
                                              backgroundColor: _group == null &&
                                                      (_query.text.trim().isEmpty
                                                          ? _shelf == shelf
                                                          : shelf == 'All')
                                                  ? Theme.of(context)
                                                      .colorScheme
                                                      .primary
                                                      .withValues(alpha: .16)
                                                  : null),
                                          onPressed: () {
                                            setState(() {
                                              _shelf = shelf;
                                              _group = null;
                                              _selectedGroupRows = null;
                                              _query.clear();
                                            });
                                            _filter();
                                          },
                                          child: Text(
                                              shelf == 'Sports' ? 'Sport channels' : shelf,
                                              style: const TextStyle(fontSize: 12)))),
                                TextButton.icon(
                                    focusNode: _shelves[4],
                                    onPressed: _indexing ? null : _pickGroup,
                                    icon: const Icon(Icons.folder_outlined,
                                        size: 16),
                                    label: const Text('Categories',
                                        style: TextStyle(fontSize: 12))),
                              ]))),
                Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                    child: Row(children: [
                      Expanded(
                          child: Text(
                              _group == null
                                  ? _query.text.trim().isNotEmpty
                                      ? 'Search results'
                                      : widget.currentChannel != null
                                          ? 'Replacing ${widget.currentChannel!.name}'
                                          : 'Choose a channel'
                                  : _groups[_group] ??
                                      widget.currentChannel?.group ??
                                      '',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  fontSize: 11, color: Colors.white54))),
                      Text(
                          _loading
                              ? 'Searching…'
                              : '${_rows.length} ${_rows.length == 1 ? 'channel' : 'channels'}',
                          style: const TextStyle(
                              fontSize: 11, color: Colors.white54)),
                    ])),
                Expanded(
                    child: Focus(
                        focusNode: _results,
                        autofocus: true,
                        onFocusChange: (_) {
                          _highlight.value = _results.hasFocus ? _index : -1;
                          if (wide && _tv && _results.hasFocus && _railOpen) {
                            setState(() => _railOpen = false);
                          }
                        },
                        onKeyEvent: (_, e) {
                          if (e is KeyUpEvent) return KeyEventResult.ignored;
                          final k = e.logicalKey;
                          if (wide &&
                              _results.hasPrimaryFocus &&
                              k == LogicalKeyboardKey.arrowLeft) {
                            _showCategories();
                            return KeyEventResult.handled;
                          }
                          if (wide &&
                              k == LogicalKeyboardKey.arrowUp &&
                              (!_results.hasPrimaryFocus || _index == 0)) {
                            _search.requestFocus();
                            return KeyEventResult.handled;
                          }
                          if (!_results.hasPrimaryFocus) {
                            if (k == LogicalKeyboardKey.arrowUp) {
                              _shelves[_group == null
                                      ? [
                                          'Recent',
                                          'Favourites',
                                          'Sports',
                                          'All'
                                        ].indexOf(_shelf)
                                      : 4]
                                  .requestFocus();
                              return KeyEventResult.handled;
                            }
                            return KeyEventResult.ignored;
                          }
                          if (k == LogicalKeyboardKey.arrowUp) {
                            if (_index == 0) {
                              _shelves[_group == null
                                      ? [
                                          'Recent',
                                          'Favourites',
                                          'Sports',
                                          'All'
                                        ].indexOf(_shelf)
                                      : 4]
                                  .requestFocus();
                            } else {
                              _move(-1, rowHeight);
                            }
                          } else if (k == LogicalKeyboardKey.arrowDown) {
                            _move(1, rowHeight);
                          } else if (k == LogicalKeyboardKey.pageUp) {
                            _move(-8, rowHeight);
                          } else if (k == LogicalKeyboardKey.pageDown) {
                            _move(8, rowHeight);
                          } else if (k == LogicalKeyboardKey.select ||
                              k == LogicalKeyboardKey.enter) {
                            if (e is KeyDownEvent &&
                                !_loading &&
                                _rows.isNotEmpty) {
                              _choose(_rows[_index]);
                            }
                          } else if (k != LogicalKeyboardKey.arrowLeft &&
                              k != LogicalKeyboardKey.arrowRight) {
                            return KeyEventResult.ignored;
                          }
                          return KeyEventResult.handled;
                        },
                        child: _loadError != null
                            ? Center(
                                child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                    Text(_loadError!),
                                    TextButton(
                                        focusNode: _emptyAction,
                                        onPressed: _load,
                                        child: const Text('Try again'))
                                  ]))
                            : _rows.isEmpty
                                ? Center(
                                    child: Padding(
                                        padding: const EdgeInsets.all(20),
                                        child: Column(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Text(
                                                  _loading
                                                      ? 'Loading channels…'
                                                      : _query.text
                                                              .trim()
                                                              .isNotEmpty
                                                          ? 'No matching channels'
                                                          : _shelf ==
                                                                  'Favourites'
                                                              ? 'No favourite channels yet'
                                                              : 'No channels in this view',
                                                  textAlign: TextAlign.center),
                                              if (!_loading)
                                                TextButton(
                                                    focusNode: _emptyAction,
                                                    onPressed: _query.text
                                                            .trim()
                                                            .isNotEmpty
                                                        ? _clearSearch
                                                        : () async {
                                                            setState(() {
                                                              _group = null;
                                                              _shelf = 'All';
                                                            });
                                                            await _filter();
                                                            if (mounted) {
                                                              _focusResults();
                                                            }
                                                          },
                                                    child: Text(_query.text
                                                            .trim()
                                                            .isNotEmpty
                                                        ? 'Clear search'
                                                        : 'Browse all channels')),
                                            ])))
                                : _guideView
                                    ? IgnorePointer(
                                        ignoring: _loading,
                                        child: ExcludeFocus(
                                            excluding: _loading,
                                            child: LiveGuideSelectionViewport(
                                                key: _guide,
                                                channels: _rows,
                                                onChoose: _choose,
                                                initialChannelId:
                                                    widget.currentChannel?.id,
                                                statusFor: (c) => widget.selectedIds
                                                        .contains(c.id)
                                                    ? 'In use'
                                                    : widget.unavailableReason
                                                                ?.call(c) !=
                                                            null
                                                        ? 'In use'
                                                        : widget.currentChannel?.id ==
                                                                c.id
                                                            ? 'This screen'
                                                            : null,
                                                onSearch: () =>
                                                    _search.requestFocus(),
                                                onCategories: wide
                                                    ? _showCategories
                                                    : null,
                                                onToolbar: () => wide
                                                    ? _search.requestFocus()
                                                    : _shelves[_group != null
                                                            ? 4
                                                            : [
                                                                'Recent',
                                                                'Favourites',
                                                                'Sports',
                                                                'All'
                                                              ]
                                                                .indexOf(_shelf)
                                                                .clamp(0, 3)]
                                                        .requestFocus())))
                                    : ListView.builder(
                                        controller: _scroll,
                                        itemExtent: rowHeight,
                                        itemCount: _rows.length,
                                        itemBuilder: (_, i) {
                                          final c = _rows[i],
                                              selected = widget.selectedIds
                                                  .contains(c.id);
                                          final unavailable = widget
                                                  .unavailableReason
                                                  ?.call(c) !=
                                              null;
                                          final current =
                                              widget.currentChannel?.id == c.id;
                                          final now =
                                              epg.getCurrentProgram(c.epgId);
                                          return GestureDetector(
                                              onTap: _loading
                                                  ? null
                                                  : () => _choose(c),
                                              child: ValueListenableBuilder<
                                                      int>(
                                                  valueListenable: _highlight,
                                                  builder:
                                                      (_, highlighted, child) {
                                                    final focused =
                                                        highlighted == i;
                                                    return Container(
                                                        margin: const EdgeInsets
                                                            .symmetric(
                                                            horizontal: 12,
                                                            vertical: 2),
                                                        padding:
                                                            const EdgeInsets
                                                                .symmetric(
                                                                horizontal: 10),
                                                        decoration: BoxDecoration(
                                                            color: focused
                                                                ? const Color(
                                                                    0xFF29455B)
                                                                : const Color(
                                                                    0xFF19232D),
                                                            borderRadius:
                                                                BorderRadius
                                                                    .circular(
                                                                        4),
                                                            border: Border.all(
                                                                color: focused
                                                                    ? const Color(
                                                                        0xFF9BCEF4)
                                                                    : const Color(
                                                                        0xFF28343F))),
                                                        child: child);
                                                  },
                                                  child: Row(children: [
                                                    SizedBox(
                                                        width: 32,
                                                        height: 32,
                                                        child:
                                                            CachedChannelLogo(
                                                                url:
                                                                    c.logoUrl)),
                                                    const SizedBox(width: 10),
                                                    Expanded(
                                                        child: Column(
                                                            mainAxisAlignment:
                                                                MainAxisAlignment
                                                                    .center,
                                                            crossAxisAlignment:
                                                                CrossAxisAlignment
                                                                    .start,
                                                            children: [
                                                          Text(c.name,
                                                              maxLines: 1,
                                                              overflow:
                                                                  TextOverflow
                                                                      .ellipsis,
                                                              style: const TextStyle(
                                                                  fontSize: 13,
                                                                  fontWeight:
                                                                      FontWeight
                                                                          .w600)),
                                                          const SizedBox(
                                                              height: 3),
                                                          Text(
                                                              now?.title ??
                                                                  c.group,
                                                              maxLines: 1,
                                                              overflow:
                                                                  TextOverflow
                                                                      .ellipsis,
                                                              style: const TextStyle(
                                                                  fontSize: 11,
                                                                  color: Colors
                                                                      .white60)),
                                                        ])),
                                                    if (selected ||
                                                        unavailable ||
                                                        current)
                                                      Padding(
                                                          padding:
                                                              const EdgeInsets
                                                                  .only(
                                                                  left: 8),
                                                          child: Text(
                                                              selected
                                                                  ? 'In use'
                                                                  : unavailable
                                                                      ? 'In use'
                                                                      : 'This screen',
                                                              style: const TextStyle(
                                                                  fontSize: 10,
                                                                  color: Colors
                                                                      .white54))),
                                                  ])));
                                        }))),
              ])),
            ]))));
  }
}

class _MultiviewCategoryRow extends StatefulWidget {
  const _MultiviewCategoryRow(
      {required this.label,
      required this.leading,
      required this.node,
      required this.selected,
      required this.onTap});
  final String label;
  final Widget leading;
  final FocusNode node;
  final bool selected;
  final VoidCallback onTap;
  @override
  State<_MultiviewCategoryRow> createState() => _MultiviewCategoryRowState();
}

class _MultiviewCategoryRowState extends State<_MultiviewCategoryRow> {
  bool _focused = false;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 1),
        child: InkWell(
          focusNode: widget.node,
          onTap: widget.onTap,
          onFocusChange: (value) {
            setState(() => _focused = value);
            if (value) {
              Scrollable.ensureVisible(context,
                  alignmentPolicy:
                      ScrollPositionAlignmentPolicy.keepVisibleAtEnd);
            }
          },
          child: LiveNavigationBody(
              label: widget.label,
              leading: widget.leading,
              collapsed: false,
              focused: _focused,
              selected: widget.selected),
        ),
      );
}
