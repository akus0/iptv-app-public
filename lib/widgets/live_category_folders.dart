import '../utils/interface_colors.dart';
import 'live_navigation_body.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../models/m3u_group.dart';
import '../services/storage_service.dart';
import '../utils/live_category_folders.dart';
import 'live_category_icon.dart';

/// Only expanded branches build rows. Cached paths reveal selections in O(depth).
class LiveCategoryFolders extends StatefulWidget {
  const LiveCategoryFolders(
      {super.key,
      required this.groups,
      required this.storage,
      required this.rowBuilder,
      required this.selectedKey,
      this.revealKey,
      this.forceFlat = false,
      this.layouts = const {},
      this.collapsed = false,
      required this.playlistName});
  final List<M3uGroup> groups;
  final Map<String, String> layouts;
  final StorageService storage;
  final Widget Function(M3uGroup, String? label) rowBuilder;
  final String? selectedKey, revealKey;
  final bool forceFlat, collapsed;
  final String Function(String) playlistName;
  @override
  State<LiveCategoryFolders> createState() => _LiveCategoryFoldersState();
}

class _LiveCategoryFoldersState extends State<LiveCategoryFolders> {
  List<LiveCategoryNode> _tree = [];
  final _paths = <String, List<String>>{};
  late String _viewer;
  late bool _folders;
  late Set<String> _open;
  @override
  void initState() {
    super.initState();
    _readPreferences();
    _rebuildTree();
    _reveal(widget.revealKey ?? widget.selectedKey);
  }

  void _readPreferences() {
    _viewer = widget.storage.getActiveViewerId();
    _folders = widget.storage.getLiveCategoryFolders();
    _open = widget.storage.getOpenLiveCategoryFolders();
    for (final key in _open.toList()) {
      const renamed = {
        '/Sports/Sports networks': '/Sports/Sports channels',
        '/Sports/Sports services': '/Sports/Sports channels',
        '/Streaming & PPV': '/Live events & PPV',
        '/Entertainment/Streaming channels': '/Entertainment',
        '/Entertainment/TV channels': '/Entertainment',
        '/Sports/Leagues & college': '/Sports/College & school',
      };
      for (final entry in renamed.entries) {
        if (key.endsWith(entry.key)) {
          _open.remove(key);
          _open.add(
              '${key.substring(0, key.length - entry.key.length)}${entry.value}');
          break;
        }
      }
      const oldRoot = '/Australia & New Zealand';
      if (key.endsWith('$oldRoot/Australia')) {
        _open.add(
            '${key.substring(0, key.length - '$oldRoot/Australia'.length)}/Australia');
        _open.remove(key);
      } else if (key.endsWith('$oldRoot/New Zealand')) {
        _open.add(
            '${key.substring(0, key.length - '$oldRoot/New Zealand'.length)}/New Zealand');
        _open.remove(key);
      } else if (key.endsWith(oldRoot)) {
        _open.remove(key);
      }
    }
  }

  void _rebuildTree() {
    _tree = buildLiveCategoryTree(widget.groups, layouts: widget.layouts);
    _paths.clear();
    void index(LiveCategoryNode n, List<String> path) {
      if (n.group != null) {
        _paths[n.key] = path;
        if (n.group case final LiveCategoryCollection collection) {
          for (final source in collection.sources) {
            _paths['${source.playlistId}::${source.title}'] = path;
          }
        }
        return;
      }
      final next = [...path, n.key];
      for (final child in n.children) {
        index(child, next);
      }
    }

    for (final node in _tree) {
      index(node, const []);
    }
  }

  void _reveal(String? key) => _open.addAll(_paths[key] ?? const []);

  @override
  void didUpdateWidget(LiveCategoryFolders oldWidget) {
    super.didUpdateWidget(oldWidget);
    final viewerChanged = _viewer != widget.storage.getActiveViewerId();
    if (viewerChanged) {
      _readPreferences();
    }
    final oldPath = _paths[widget.revealKey ?? widget.selectedKey];
    final changed = !listEquals(oldWidget.groups, widget.groups) ||
        !mapEquals(oldWidget.layouts, widget.layouts);
    if (changed) _rebuildTree();
    if (viewerChanged ||
        oldWidget.selectedKey != widget.selectedKey ||
        oldWidget.revealKey != widget.revealKey ||
        (changed &&
            !listEquals(
                oldPath, _paths[widget.revealKey ?? widget.selectedKey]))) {
      _reveal(widget.revealKey ?? widget.selectedKey);
    }
  }

  void _toggle(String key) {
    setState(() {
      if (!_open.remove(key)) _open.add(key);
    });
    widget.storage.setOpenLiveCategoryFolders(_open);
  }

  @override
  Widget build(BuildContext context) {
    final hasFolders = _tree.length != widget.groups.length ||
        _tree.any((n) => n.group == null || n.group is LiveCategoryCollection);
    if (!hasFolders) {
      return Column(
          mainAxisSize: MainAxisSize.min, children: _leaves(widget.groups));
    }
    final selectedPath = _paths[widget.selectedKey] ?? const <String>[];
    final rows = <Widget>[];
    String? playlistId;
    final multi = widget.groups.map((g) => g.playlistId).toSet().length > 1;
    void add(LiveCategoryNode n, int depth) {
      if (n.group case final g?) {
        rows.add(LiveCategoryBranch(
            key: ValueKey(n.key),
            depth: depth,
            folder: false,
            collapsed: widget.collapsed,
            child: widget.rowBuilder(
                g,
                g is LiveCategoryCollection
                    ? g.displayName
                    : liveCategoryLabel(g.title, inFolder: depth > 0))));
        return;
      }
      final open = _open.contains(n.key);
      rows.add(LiveCategoryBranch(
          key: ValueKey(n.key),
          depth: depth,
          folder: true,
          collapsed: widget.collapsed,
          child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 1),
              child: _FolderTile(
                  node: n,
                  open: open,
                  collapsed: widget.collapsed,
                  selected: selectedPath.contains(n.key),
                  onTap: () => _toggle(n.key)))));
      if (open) {
        for (final child in n.children) {
          add(child, depth + 1);
        }
      }
    }

    if (_folders && !widget.forceFlat) {
      for (final node in _tree) {
        if (multi && node.playlistId != playlistId) {
          rows.add(_divider(node.playlistId));
        }
        playlistId = node.playlistId;
        add(node, 0);
      }
    } else {
      rows.addAll(_leaves(widget.groups));
    }
    return Column(mainAxisSize: MainAxisSize.min, children: [
      SizedBox(
          key: const ValueKey('live-category-toolbar'),
          height: 26,
          child: Padding(
              padding:
                  EdgeInsets.symmetric(horizontal: widget.collapsed ? 0 : 8),
              child: Row(children: [
                if (!widget.collapsed) ...[
                  Text('Categories',
                      style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                          color:
                              Theme.of(context).colorScheme.onSurfaceVariant)),
                  const SizedBox(width: 8),
                  Expanded(
                      child: Divider(
                          height: 1,
                          color: Theme.of(context)
                              .dividerColor
                              .withValues(alpha: .25))),
                  const SizedBox(width: 4),
                ] else
                  const Spacer(),
                SizedBox(
                    width: 26,
                    height: 26,
                    child: IconButton(
                        tooltip: _folders
                            ? 'Show original category list'
                            : 'Group categories into folders',
                        style: IconButton.styleFrom(
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                        constraints: const BoxConstraints.tightFor(
                            width: 26, height: 26),
                        padding: EdgeInsets.zero,
                        iconSize: 15,
                        icon: Icon(_folders
                            ? Icons.folder_copy_outlined
                            : Icons.format_list_bulleted),
                        onPressed: widget.forceFlat
                            ? null
                            : () {
                                setState(() => _folders = !_folders);
                                widget.storage.setLiveCategoryFolders(_folders);
                              })),
                if (widget.collapsed) const Spacer(),
              ]))),
      ...rows,
    ]);
  }

  Widget _divider(String id) => widget.collapsed
      ? const Divider(height: 8, indent: 6, endIndent: 6)
      : Padding(
          padding: const EdgeInsets.fromLTRB(9, 6, 8, 3),
          child: Text(widget.playlistName(id),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 10,
                  color: interfaceColor(context, Colors.white54))));
  List<Widget> _leaves(List<M3uGroup> groups) {
    final multi = groups.map((g) => g.playlistId).toSet().length > 1;
    String? previous;
    final rows = <Widget>[];
    for (final g in groups) {
      if (isLivePlaylistInformation(g.title)) continue;
      if (multi && previous != g.playlistId) rows.add(_divider(g.playlistId));
      previous = g.playlistId;
      rows.add(widget.rowBuilder(g, null));
    }
    return rows;
  }
}

class _FolderTile extends StatefulWidget {
  const _FolderTile(
      {required this.node,
      required this.open,
      required this.collapsed,
      required this.selected,
      required this.onTap});
  final LiveCategoryNode node;
  final bool open, collapsed, selected;
  final VoidCallback onTap;
  @override
  State<_FolderTile> createState() => _FolderTileState();
}

class _FolderTileState extends State<_FolderTile> {
  bool _focused = false;
  final _focus = FocusNode();
  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
        button: true,
        label: widget.node.label,
        expanded: widget.open,
        selected: widget.selected,
        child: Material(
            color: Colors.transparent,
            animationDuration: Duration.zero,
            child: InkWell(
                focusNode: _focus,
                splashFactory: NoSplash.splashFactory,
                highlightColor: Colors.transparent,
                onTap: () {
                  _focus.requestFocus();
                  widget.onTap();
                },
                onFocusChange: (value) {
                  setState(() => _focused = value);
                  if (value) {
                    Scrollable.ensureVisible(context,
                        alignmentPolicy:
                            ScrollPositionAlignmentPolicy.keepVisibleAtEnd);
                    Scrollable.ensureVisible(context,
                        alignmentPolicy:
                            ScrollPositionAlignmentPolicy.keepVisibleAtStart);
                  }
                },
                child: LiveCategoryFolderBody(
                    label: widget.node.label,
                    count: widget.node.count,
                    open: widget.open,
                    selected: widget.selected,
                    collapsed: widget.collapsed,
                    focused: _focused))));
  }
}

/// Identical folder appearance in Live TV and the library's virtual tree.
class LiveCategoryFolderBody extends StatelessWidget {
  const LiveCategoryFolderBody(
      {super.key,
      required this.label,
      required this.count,
      required this.open,
      required this.selected,
      required this.collapsed,
      required this.focused});
  final String label;
  final int count;
  final bool open, selected, collapsed, focused;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final ink = focused
        ? scheme.onPrimaryContainer
        : selected
            ? scheme.primary
            : scheme.onSurfaceVariant;
    final chevron = Icon(open ? Icons.expand_more : Icons.chevron_right,
        size: collapsed ? 12 : 15, color: ink);
    return LiveNavigationBody(
        label: label,
        focused: focused,
        selected: selected,
        collapsed: collapsed,
        leading: collapsed
            ? Stack(clipBehavior: Clip.none, children: [
                LiveCategoryIcon(label: label, color: ink, size: 18),
                Positioned(
                    right: -3,
                    bottom: -4,
                    child: Icon(open ? Icons.expand_more : Icons.chevron_right,
                        size: 9, color: ink)),
              ])
            : LiveCategoryIcon(label: label, color: ink, size: 18),
        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
          Text('$count',
              style: TextStyle(fontSize: 10, color: ink.withValues(alpha: .6))),
          const SizedBox(width: 3),
          chevron,
        ]));
  }
}

/// Static tree guides make the parent relationship legible without animations,
/// extra focus stops or work proportional to the playlist's channel count.
class LiveCategoryBranch extends StatelessWidget {
  const LiveCategoryBranch(
      {super.key,
      required this.depth,
      required this.folder,
      required this.collapsed,
      required this.child});
  final int depth;
  final bool folder, collapsed;
  final Widget child;
  @override
  Widget build(BuildContext context) => LiveCategoryLevel(
      depth: depth,
      folder: folder,
      child: CustomPaint(
          painter: !collapsed && depth > 0
              ? _BranchPainter(
                  depth,
                  Theme.of(context)
                      .colorScheme
                      .onSurface
                      .withValues(alpha: .13))
              : null,
          child: Padding(
              padding: EdgeInsets.only(left: collapsed ? 0 : depth * 14.0),
              child: child)));
}

class _BranchPainter extends CustomPainter {
  const _BranchPainter(this.depth, this.color);
  final int depth;
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1;
    for (var level = 0; level < depth; level++) {
      final x = 8.0 + level * 14;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
    final x = 8.0 + (depth - 1) * 14;
    canvas.drawLine(
        Offset(x, size.height / 2), Offset(x + 6, size.height / 2), paint);
  }

  @override
  bool shouldRepaint(_BranchPainter oldDelegate) =>
      depth != oldDelegate.depth || color != oldDelegate.color;
}
