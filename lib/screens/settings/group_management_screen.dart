import 'dart:async';
import '../../utils/interface_colors.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../../models/m3u_group.dart';
import '../../services/playlist_manager.dart';
import '../../services/app_preferences.dart';
import '../../widgets/tv_text_field_gate.dart';
import '../../widgets/settings_scaffold.dart';
import '../../l10n/l10n.dart';

/// Visibility is saved as it changes. Done exits without another confirmation.
class GroupManagementScreen extends StatefulWidget {
  const GroupManagementScreen(
      {super.key, required this.playlistId, this.deferLoading = false});
  final String playlistId;
  final bool deferLoading;
  @override
  State<GroupManagementScreen> createState() => _GroupManagementScreenState();
}

class _GroupManagementScreenState extends State<GroupManagementScreen>
    with SingleTickerProviderStateMixin {
  static const _types = ['tv', 'vod', 'series'];
  late final TabController _tabs;
  final _search =
      List.generate(3, (i) => FocusNode(debugLabel: 'group-search-$i'));
  final _done = FocusNode(debugLabel: 'group-mgmt-done');
  final _visited = <int>{0};
  int _pending = 0;
  bool _allowPop = false;
  late String _playlistId;
  final _ready = <String>{};
  final _loading = <String>{};
  final _failed = <String>{};
  bool get _categoriesLoading => _loading.contains(_playlistId);
  bool get _categoriesFailed => _failed.contains(_playlistId);

  @override
  void initState() {
    super.initState();
    _playlistId = widget.playlistId;
    _tabs =
        TabController(length: 3, vsync: this, animationDuration: Duration.zero);
    _tabs.addListener(_tabChanged);
  }

  void _tabChanged() {
    setState(() => _visited.add(_tabs.index));
    if (_tabs.index != 0) unawaited(_loadCategories());
  }

  void _selectPlaylist(String? id) {
    if (id == null || id == _playlistId || _pending != 0) return;
    setState(() {
      _playlistId = id;
      _visited
        ..clear()
        ..add(_tabs.index);
    });
    if (_tabs.index != 0) unawaited(_loadCategories());
  }

  Future<void> _loadCategories() async {
    final id = _playlistId;
    if (_loading.contains(id) || _ready.contains(id)) return;
    setState(() {
      _loading.add(id);
      _failed.remove(id);
    });
    try {
      await context.read<PlaylistManager>().ensureLibraryCategoriesFor(id);
      _ready.add(id);
    } catch (_) {
      _failed.add(id);
    } finally {
      _loading.remove(id);
      if (mounted) setState(() {});
    }
  }

  Future<void> _save(Future<void> Function() action) async {
    setState(() => _pending++);
    try {
      await action();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content:
                Text('Could not save category visibility. Please try again.')));
      }
    } finally {
      if (mounted) setState(() => _pending--);
    }
  }

  void _finish() {
    if (_pending != 0 || _allowPop) return;
    setState(() => _allowPop = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.of(context).pop(true);
    });
  }

  @override
  void dispose() {
    _tabs.dispose();
    for (final node in _search) {
      node.dispose();
    }
    _done.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final playlist = context.watch<PlaylistManager>();
    final profiles = playlist.profiles;
    final keyboard = MediaQuery.viewInsetsOf(context).bottom > 0;
    final wide = MediaQuery.sizeOf(context).width >= 460 &&
        MediaQuery.textScalerOf(context).scale(12) <= 14.4;
    final tv = context.read<AppPreferences>().isTelevision;
    final tabs = TabBar(controller: _tabs, tabs: [
      for (final label in ['Live TV', 'Movies', 'Series'])
        Tab(height: 36, text: tr(label))
    ]);
    final provider = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: profiles.any((p) => p.id == _playlistId)
          ? DropdownButtonFormField<String>(
              key: ValueKey('category-playlist-$_playlistId'),
              initialValue: _playlistId,
              isExpanded: true,
              decoration: InputDecoration(
                labelText: tr('Playlist'),
                isDense: true,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              ),
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(fontSize: 13),
              items: [
                for (final p in profiles)
                  DropdownMenuItem(
                      value: p.id,
                      child: Text(
                          p.enabled ? p.name : '${p.name} · ${tr('Disabled')}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis))
              ],
              onChanged:
                  _pending == 0 && profiles.length > 1 ? _selectPlaylist : null,
            )
          : const SizedBox.shrink(),
    );
    final hasProvider = profiles.any((p) => p.id == _playlistId);
    return withSettingsTheme(
        context,
        (context) => PopScope(
              canPop: _allowPop,
              onPopInvokedWithResult: (didPop, _) {
                if (!didPop && TvTextFieldGate.editingFocusedField) return;
                if (!didPop) _finish();
              },
              child: SettingsScaffold(
                title: tr('Manage categories'),
                bottom: keyboard
                    ? null
                    : PreferredSize(
                        preferredSize: Size.fromHeight(hasProvider && !wide
                            ? 90
                            : hasProvider
                                ? 52
                                : 38),
                        child: !hasProvider
                            ? tabs
                            : wide
                                ? Row(children: [
                                    Expanded(flex: 4, child: provider),
                                    Expanded(flex: 5, child: tabs)
                                  ])
                                : Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [provider, tabs]),
                      ),
                body: Column(children: [
                  if (_tabs.index != 0 && _categoriesLoading)
                    const LinearProgressIndicator(),
                  if (_tabs.index != 0 && _categoriesFailed)
                    TextButton(
                        onPressed: _loadCategories,
                        child: const Text('Could not load categories. Retry')),
                  Expanded(
                      child: ListenableBuilder(
                          listenable: _search[_tabs.index],
                          child: IndexedStack(index: _tabs.index, children: [
                            for (var i = 0; i < 3; i++)
                              if (!_visited.contains(i))
                                const SizedBox.shrink()
                              else
                                _GroupList(
                                  key: ValueKey('$_playlistId/${_types[i]}'),
                                  searchFocus: _search[i],
                                  type: _types[i],
                                  onSave: _save,
                                  onDone: _done.requestFocus,
                                  groups: playlist.groupsForPlaylist(
                                      _playlistId, _types[i]),
                                  playlist: playlist,
                                  playlistId: _playlistId,
                                  // Library categories are metadata only; opening Movies/Series loads titles on demand.
                                  deferLoading: widget.deferLoading || i != 0,
                                )
                          ]),
                          builder: (context, child) => CallbackShortcuts(
                                bindings: _search[_tabs.index].hasFocus
                                    ? const {}
                                    : {
                                        const SingleActivator(
                                                LogicalKeyboardKey.contextMenu):
                                            _done.requestFocus,
                                        const SingleActivator(
                                                LogicalKeyboardKey.home):
                                            _search[_tabs.index].requestFocus,
                                        const SingleActivator(
                                                LogicalKeyboardKey.end):
                                            _done.requestFocus,
                                        for (var i = 0; i < 3; i++)
                                          SingleActivator([
                                            LogicalKeyboardKey.digit1,
                                            LogicalKeyboardKey.digit2,
                                            LogicalKeyboardKey.digit3
                                          ][i]): () => _tabs.index = i,
                                      },
                                child: child!,
                              ))),
                  Padding(
                    padding: EdgeInsets.fromLTRB(12, 4, 12, keyboard ? 0 : 6),
                    child: Row(children: [
                      Expanded(
                          child: Text(
                        tv
                            ? tr('← Search · → Done')
                            : tr('Changes save automatically'),
                        style: Theme.of(context)
                            .textTheme
                            .bodySmall
                            ?.copyWith(fontSize: 11),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      )),
                      TextButton.icon(
                        onPressed: _search[_tabs.index].requestFocus,
                        icon: const Icon(Icons.search, size: 17),
                        label: Text(tr('Search')),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(
                        key: const ValueKey('group-done'),
                        focusNode: _done,
                        onPressed: _pending == 0 ? _finish : null,
                        child:
                            Text(_pending == 0 ? tr('Done') : tr('Saving...')),
                      ),
                    ]),
                  ),
                ]),
              ),
            ));
  }
}

class _GroupList extends StatefulWidget {
  const _GroupList({
    super.key,
    required this.searchFocus,
    required this.type,
    required this.onSave,
    required this.onDone,
    required this.groups,
    required this.playlist,
    required this.playlistId,
    this.deferLoading = false,
  });

  final VoidCallback onDone;
  final FocusNode searchFocus;
  final String type;
  final Future<void> Function(Future<void> Function()) onSave;
  final List<M3uGroup> groups;
  final PlaylistManager playlist;
  final String playlistId;
  final bool deferLoading;

  @override
  State<_GroupList> createState() => _GroupListState();
}

class _GroupListState extends State<_GroupList>
    with AutomaticKeepAliveClientMixin {
  final _search = TextEditingController();
  final _scroll = ScrollController(keepScrollOffset: false);
  List<String> _terms = const [];
  late List<String> _labels;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _indexLabels();
  }

  @override
  void didUpdateWidget(_GroupList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.groups, widget.groups)) _indexLabels();
  }

  void _indexLabels() => _labels =
      widget.groups.map((group) => group.title.toLowerCase()).toList();

  void _filter(String value) {
    final query = value.trim().toLowerCase();
    setState(
        () => _terms = query.isEmpty ? const [] : query.split(RegExp(r'\s+')));
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  void _clearSearch() {
    _search.clear();
    _filter('');
    widget.searchFocus.requestFocus();
  }

  @override
  void dispose() {
    _search.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final tv = context.read<AppPreferences>().isTelevision;
    if (widget.groups.isEmpty) {
      return Center(
          child: Text(tr('No categories yet — load a playlist first.')));
    }
    // Search is local to this list: typing never reloads the playlist or
    // rebuilds the parent settings screen. Hidden groups remain searchable.
    final filtered = _terms.isNotEmpty;
    final groups = !filtered
        ? widget.groups
        : [
            for (var i = 0; i < widget.groups.length; i++)
              if (_terms.every(_labels[i].contains)) widget.groups[i],
          ];
    final titles = groups.map((group) => group.title);
    final hidden = groups.where((group) => group.isHidden).length;
    return LayoutBuilder(builder: (context, constraints) {
      // Keep the field and results usable when a landscape keyboard leaves
      // little height. Bulk actions return as soon as the keyboard closes.
      final compact = constraints.maxHeight < 140 ||
          (MediaQuery.viewInsetsOf(context).bottom > 0 &&
              constraints.maxHeight < 220);
      return Column(
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(12, compact || tv ? 4 : 8, 12, 0),
            child: TvTextFieldGate(
              focusNode: widget.searchFocus,
              builder: (context, readOnly) => TextField(
                key: const ValueKey('group-search'),
                controller: _search,
                focusNode: widget.searchFocus,
                readOnly: readOnly,
                onChanged: _filter,
                textInputAction: TextInputAction.search,
                style: const TextStyle(fontSize: 13),
                decoration: InputDecoration(
                  isDense: true,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  labelText: tr('Search categories'),
                  prefixIcon: const Icon(Icons.search, size: 18),
                  suffixIcon: _search.text.isEmpty
                      ? null
                      : IconButton(
                          tooltip: tr('Clear search'),
                          icon: const Icon(Icons.clear),
                          onPressed: _clearSearch,
                        ),
                ),
              ),
            ),
          ),
          if (!compact)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 2, 12, 2),
              child: Row(children: [
                Expanded(
                    child: Text(
                  tr('{count} of {total} categories', {
                    'count': '${groups.length}',
                    'total': '${widget.groups.length}',
                  }),
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(fontSize: 11),
                )),
                ConstrainedBox(
                    constraints: BoxConstraints(
                        maxWidth: (constraints.maxWidth - 24) * .3),
                    child: OutlinedButton(
                      onPressed: hidden == 0
                          ? null
                          : () => widget.onSave(() => widget.playlist
                              .setGroupsHidden(widget.playlistId, titles, false,
                                  loadImmediately: !widget.deferLoading,
                                  type: widget.type)),
                      child: Text(tr(filtered ? 'Show matches' : 'Show All')),
                    )),
                const SizedBox(width: 6),
                ConstrainedBox(
                    constraints: BoxConstraints(
                        maxWidth: (constraints.maxWidth - 24) * .3),
                    child: OutlinedButton(
                      onPressed: hidden == groups.length
                          ? null
                          : () => widget.onSave(() => widget.playlist
                              .setGroupsHidden(widget.playlistId, titles, true,
                                  loadImmediately: !widget.deferLoading,
                                  type: widget.type)),
                      child: Text(tr(filtered ? 'Hide matches' : 'Hide All')),
                    )),
              ]),
            ),
          Expanded(
            child: groups.isEmpty
                ? Center(
                    child: SingleChildScrollView(
                        child:
                            Column(mainAxisSize: MainAxisSize.min, children: [
                    Text(tr('No categories match your search.')),
                    TextButton(
                        onPressed: _clearSearch,
                        child: Text(tr('Clear search'))),
                  ])))
                : CallbackShortcuts(
                    bindings: {
                        const TvNavigationActivator(
                            LogicalKeyboardKey.arrowRight): widget.onDone,
                        const TvNavigationActivator(
                                LogicalKeyboardKey.arrowLeft):
                            widget.searchFocus.requestFocus
                      },
                    child: ListView.builder(
                      controller: _scroll,
                      itemCount: groups.length,
                      itemBuilder: (context, index) {
                        final group = groups[index];
                        // Keep row identity across visibility changes; the icon alone
                        // changes. Actions always address the original provider title.
                        return ListTile(
                          key: ValueKey(group.title),
                          minTileHeight: tv ? 40 : 48,
                          minVerticalPadding: 4,
                          contentPadding:
                              const EdgeInsets.symmetric(horizontal: 12),
                          tileColor: index.isOdd
                              ? Theme.of(context)
                                  .colorScheme
                                  .onSurface
                                  .withValues(alpha: .025)
                              : null,
                          title: Text(group.title,
                              maxLines: tv ? 1 : 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: tv ? 12 : 13,
                                  fontWeight: FontWeight.w400)),
                          trailing: RepaintBoundary(
                            key: ValueKey(group.isHidden),
                            child: Icon(
                              group.isHidden
                                  ? Icons.circle_outlined
                                  : Icons.check_circle,
                              size: 19,
                              color: group.isHidden
                                  ? interfaceColor(context, Colors.white54)
                                  : Theme.of(context).colorScheme.primary,
                            ),
                          ),
                          onTap: () => widget
                              .onSave(() => widget.playlist.setGroupHidden(
                                    widget.playlistId,
                                    group.title,
                                    !group.isHidden,
                                    loadImmediately: !widget.deferLoading,
                                    type: widget.type,
                                  )),
                        );
                      },
                    )),
          ),
        ],
      );
    });
  }
}
