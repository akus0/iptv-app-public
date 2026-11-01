import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/m3u_group.dart';
import '../utils/library_categories.dart';
import 'live_category_folders.dart';
import 'live_navigation_body.dart';
import 'live_category_icon.dart';
import '../utils/interface_colors.dart';

IconData libraryCategoryIcon(String title) {
  final text = title.toLowerCase();
  if (RegExp(r'kids|children|family|disney').hasMatch(text)) {
    return Icons.family_restroom;
  }
  if (RegExp(r'anim|cartoon').hasMatch(text)) return Icons.animation;
  if (RegExp(r'document|nature|history').hasMatch(text)) return Icons.public;
  if (RegExp(r'comedy|stand.?up').hasMatch(text)) {
    return Icons.sentiment_very_satisfied_outlined;
  }
  if (RegExp(r'horror|thriller').hasMatch(text)) {
    return Icons.nights_stay_outlined;
  }
  if (RegExp(r'sci.?fi|fantasy').hasMatch(text)) {
    return Icons.auto_awesome_outlined;
  }
  if (RegExp(r'action|adventure|western').hasMatch(text)) {
    return Icons.explore_outlined;
  }
  if (RegExp(r'romance|drama').hasMatch(text)) {
    return Icons.theater_comedy_outlined;
  }
  if (RegExp(r'music|concert').hasMatch(text)) return Icons.music_note_outlined;
  if (RegExp(r'sport').hasMatch(text)) return Icons.sports;
  if (RegExp(r'4k|uhd').hasMatch(text)) return Icons.hd_outlined;
  if (RegExp(r'new|202[5-9]|latest|recent').hasMatch(text)) {
    return Icons.new_releases_outlined;
  }
  return Icons.movie_outlined;
}

/// Virtual, in-place tree: focus movement never queries a catalogue.
class LibraryCategoryRail extends StatefulWidget {
  const LibraryCategoryRail(
      {super.key,
      required this.tree,
      required this.selected,
      required this.focusNode,
      required this.onSelect,
      required this.onBrowse,
      required this.onMainMenu,
      required this.names,
      this.onSearch,
      this.autofocus = false,
      this.showPaths = false});
  final LibraryCategoryTree tree;
  final M3uGroup? selected;
  final FocusNode focusNode;
  final ValueChanged<M3uGroup> onSelect;
  final VoidCallback onBrowse, onMainMenu;
  final VoidCallback? onSearch;
  final Map<String, String> names;
  final bool autofocus, showPaths;
  @override
  State<LibraryCategoryRail> createState() => LibraryCategoryRailState();
}

class LibraryCategoryRailState extends State<LibraryCategoryRail> {
  final _scroll = ScrollController();
  final _highlight = ValueNotifier<int>(0);
  final _open = <String>{};
  final _selectedParents = <String>{};
  List<({LibraryCategoryNode node, int depth})> _rows = [];
  final _extents = <String, double>{};
  final _offsets = <double>[0];
  double _width = 208;
  Object? _layoutKey;

  String? _detail(M3uGroup? group) {
    if (group == null) return null;
    final text = <String>[
      if (widget.showPaths && widget.tree.path(group).isNotEmpty)
        widget.tree.path(group),
      if (widget.tree.sourceCount > 1) widget.names[group.playlistId] ?? '',
    ].where((s) => s.isNotEmpty).join(' · ');
    return text.isEmpty ? null : text;
  }

  double _extentAt(int index) {
    final row = _rows[index], n = row.node;
    return _extents.putIfAbsent(n.id, () {
      var trailing = 0.0;
      if (n.isFolder) {
        final count = TextPainter(
            textDirection: Directionality.of(context),
            textScaler: MediaQuery.textScalerOf(context),
            text: TextSpan(
                text: '${n.categoryCount}',
                style: DefaultTextStyle.of(context)
                    .style
                    .merge(const TextStyle(fontSize: 10))))
          ..layout();
        trailing = count.width + 3 + 15;
        count.dispose();
      }
      final metrics = LiveNavigationMetrics(context,
          nested: row.depth > 0, collapsed: false);
      // Reserve the focused label width too so moving focus cannot resize rows.
      return metrics.measureHeight(context,
              label: n.title,
              width: _width - row.depth * 14 - 4,
              emphasized: true,
              subtitle: _detail(n.group),
              trailingWidth: trailing,
              leadingHeight: (n.isFolder ? 20 : 22) - (row.depth > 0 ? 2 : 0)) +
          2;
    });
  }

  double _topAt(int index) {
    while (_offsets.length <= index) {
      final i = _offsets.length - 1;
      _offsets.add(_offsets.last + _extentAt(i));
    }
    return _offsets[index];
  }

  void _flatten({String? focus}) {
    final rows = <({LibraryCategoryNode node, int depth})>[];
    void add(LibraryCategoryNode n, int depth) {
      rows.add((node: n, depth: depth));
      if (_open.contains(n.id)) {
        for (final child in n.children) {
          add(child, depth + 1);
        }
      }
    }

    for (final n in widget.tree.roots) {
      add(n, 0);
    }
    _rows = rows;
    _offsets
      ..clear()
      ..add(0);
    final index = rows.indexWhere((r) => r.node.id == focus);
    _highlight.value = index >= 0 ? index : 0;
  }

  void _revealSelection() {
    _selectedParents.clear();
    final id = widget.selected == null
        ? null
        : LibraryCategoryTree.key(widget.selected!);
    bool find(LibraryCategoryNode n) {
      if (n.id == id) return true;
      for (final child in n.children) {
        if (find(child)) {
          _selectedParents.add(n.id);
          _open.add(n.id);
          return true;
        }
      }
      return false;
    }

    for (final n in widget.tree.roots) {
      if (find(n)) break;
    }
    _flatten(focus: id);
    _scheduleReveal();
  }

  void _scheduleReveal() => WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _reveal();
      });
  @override
  void initState() {
    super.initState();
    _revealSelection();
  }

  @override
  void didUpdateWidget(LibraryCategoryRail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.tree, widget.tree) ||
        oldWidget.selected != widget.selected) {
      _extents.clear();
      _revealSelection();
    }
  }

  void _reveal() {
    if (!_scroll.hasClients) return;
    final top = _topAt(_highlight.value), p = _scroll.position;
    final height = _rows.isEmpty ? 0.0 : _extentAt(_highlight.value);
    if (top < p.pixels) {
      _scroll.jumpTo(top.clamp(0, p.maxScrollExtent));
    } else if (top + height > p.pixels + p.viewportDimension) {
      _scroll.jumpTo(
          (top + height - p.viewportDimension).clamp(0, p.maxScrollExtent));
    }
  }

  void _toggle(LibraryCategoryNode node) {
    setState(() {
      if (!_open.remove(node.id)) _open.add(node.id);
      _flatten(focus: node.id);
    });
    _scheduleReveal();
  }

  void _activate(int i) {
    final node = _rows[i].node;
    if (node.group != null) {
      widget.onSelect(node.group!);
      return;
    }
    _toggle(node);
    widget.focusNode.requestFocus();
  }

  @override
  void dispose() {
    _scroll.dispose();
    _highlight.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SizedBox(
          height: 26,
          child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(children: [
                Text('Categories',
                    style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                        color: colors.onSurfaceVariant)),
                const SizedBox(width: 8),
                Expanded(
                    child: Divider(
                        height: 1,
                        color: colors.outlineVariant.withValues(alpha: .25)))
              ]))),
      Expanded(
          child: Focus(
              focusNode: widget.focusNode,
              autofocus: widget.autofocus,
              onFocusChange: (_) => setState(() {}),
              onKeyEvent: (_, e) {
                if (e is KeyUpEvent) return KeyEventResult.ignored;
                final key = e.logicalKey;
                if (key == LogicalKeyboardKey.arrowLeft) {
                  if (e is KeyDownEvent) widget.onMainMenu();
                } else if (key == LogicalKeyboardKey.arrowRight) {
                  if (e is KeyDownEvent) widget.onBrowse();
                } else if (key == LogicalKeyboardKey.arrowDown ||
                    key == LogicalKeyboardKey.arrowUp) {
                  if (key == LogicalKeyboardKey.arrowUp &&
                      _highlight.value == 0 &&
                      widget.onSearch != null) {
                    widget.onSearch!();
                  } else if (_rows.isNotEmpty) {
                    _highlight.value = (_highlight.value +
                            (key == LogicalKeyboardKey.arrowDown ? 1 : -1))
                        .clamp(0, _rows.length - 1);
                    _reveal();
                  }
                } else if (key == LogicalKeyboardKey.select ||
                    key == LogicalKeyboardKey.enter) {
                  if (e is KeyDownEvent && _rows.isNotEmpty) {
                    _activate(_highlight.value);
                  }
                } else {
                  return KeyEventResult.ignored;
                }
                return KeyEventResult.handled;
              },
              child: LayoutBuilder(builder: (context, constraints) {
                final key = (
                  constraints.maxWidth,
                  MediaQuery.sizeOf(context),
                  MediaQuery.textScalerOf(context),
                  DefaultTextStyle.of(context).style
                );
                if (_layoutKey != key) {
                  _layoutKey = key;
                  _width = constraints.maxWidth;
                  _extents.clear();
                  _offsets
                    ..clear()
                    ..add(0);
                  _scheduleReveal();
                }
                return ListView.builder(
                    controller: _scroll,
                    itemExtentBuilder: (index, _) =>
                        index < _rows.length ? _extentAt(index) : null,
                    itemCount: _rows.length,
                    itemBuilder: (_, index) {
                      final row = _rows[index], node = row.node, g = node.group;
                      final selected = g != null &&
                          g.title == widget.selected?.title &&
                          g.playlistId == widget.selected?.playlistId;
                      return Semantics(
                          button: true,
                          expanded:
                              node.isFolder ? _open.contains(node.id) : null,
                          selected: selected,
                          child: GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTap: () => _activate(index),
                              child: LiveCategoryBranch(
                                  depth: row.depth,
                                  folder: node.isFolder,
                                  collapsed: false,
                                  child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 2, vertical: 1),
                                      child: ValueListenableBuilder<int>(
                                          valueListenable: _highlight,
                                          builder: (_, highlighted, child) {
                                            final focused =
                                                widget.focusNode.hasFocus &&
                                                    highlighted == index;
                                            if (node.isFolder) {
                                              return LiveCategoryFolderBody(
                                                  label: node.title,
                                                  count: node.categoryCount,
                                                  open: _open.contains(node.id),
                                                  selected: _selectedParents
                                                      .contains(node.id),
                                                  collapsed: false,
                                                  focused: focused);
                                            }
                                            return LiveNavigationBody(
                                                label: node.title,
                                                subtitle: _detail(g),
                                                leading: LiveCategoryIcon(
                                                    label: node.title,
                                                    color: focused
                                                        ? colors
                                                            .onPrimaryContainer
                                                        : selected
                                                            ? colors.tertiary
                                                            : interfaceColor(
                                                                context,
                                                                Colors
                                                                    .white70)),
                                                collapsed: false,
                                                focused: focused,
                                                selected: selected);
                                          })))));
                    });
              }))),
    ]);
  }
}
