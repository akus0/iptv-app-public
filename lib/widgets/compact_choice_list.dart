import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'hold_to_activate.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter/services.dart';

class CompactChoice {
  const CompactChoice(
      {required this.id,
      required this.title,
      required this.onTap,
      this.subtitle,
      this.group,
      this.markerBefore,
      this.leading,
      this.trailing,
      this.content,
      this.contentBuilder,
      this.onHold})
      : assert(content == null || contentBuilder == null);
  final String id, title;
  final String? subtitle, group;
  final Widget? leading, trailing;
  final Widget? markerBefore;
  final Widget? content;

  /// Expensive presentation belongs to mounted rows, not the whole result set.
  final WidgetBuilder? contentBuilder;
  final VoidCallback onTap;
  final VoidCallback? onHold;
}

/// Lazy, fixed-height choices with explicit remote navigation. Even a long
/// channel list only builds the visible rows; focus can cross virtual boundaries.
class CompactChoiceList extends StatefulWidget {
  const CompactChoiceList(
      {super.key,
      required this.choices,
      this.selected,
      this.rowHeight = 48,
      this.polished = false,
      this.striped = false,
      this.showNavigation = false,
      this.autofocus = true,
      this.resetScrollKey,
      this.onExitUp,
      this.onExitDown,
      this.onActiveIndexChanged,
      this.trailingMarker,
      this.cacheExtent,
      this.controller});
  final List<CompactChoice> choices;
  final String? selected;
  final double rowHeight;
  final bool polished, striped;
  final bool showNavigation;
  final bool autofocus;
  final Object? resetScrollKey;
  final VoidCallback? onExitUp;
  final VoidCallback? onExitDown;
  final ValueChanged<int>? onActiveIndexChanged;
  final Widget? trailingMarker;
  final double? cacheExtent;
  final ScrollController? controller;
  @override
  State<CompactChoiceList> createState() => CompactChoiceListState();
}

class CompactChoiceListState extends State<CompactChoiceList> {
  late final _scroll = widget.controller ?? ScrollController();
  final _nodes = <String, FocusNode>{};
  final _rows = <({int index, String? heading, Widget? marker, double top})>[];
  final _offsets = <double>[];
  int _index = 0, _focusRequest = 0;
  double _contentExtent = 0;
  final _pageFocus = FocusNode();
  bool get _navigation => widget.showNavigation && widget.choices.length > 30;

  void _rememberIndex(int index) {
    _index = index;
    _reportIndex(index);
  }

  int? _reportedIndex;
  void _reportIndex(int index) {
    if (_reportedIndex == index || widget.onActiveIndexChanged == null) return;
    _reportedIndex = index;
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _reportedIndex == index) {
          widget.onActiveIndexChanged?.call(index);
        }
      });
    } else {
      widget.onActiveIndexChanged?.call(index);
    }
  }

  int get firstVisibleIndex {
    if (_offsets.isEmpty || !_scroll.hasClients) return 0;
    var low = 0, high = _offsets.length;
    while (low < high) {
      final mid = (low + high) ~/ 2;
      if (_offsets[mid] <= _scroll.offset) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    return (low - 1).clamp(0, _offsets.length - 1);
  }

  void _reportScroll() {
    if (widget.onActiveIndexChanged != null && _offsets.isNotEmpty) {
      _reportIndex(firstVisibleIndex);
    }
  }

  /// Reveal an indexed row without mounting preceding entries or stealing focus.
  void revealIndex(int index, {bool requestFocus = false}) {
    if (index < 0 || index >= _offsets.length || !_scroll.hasClients) return;
    if (requestFocus) {
      _focus(index);
      return;
    }
    _scroll
        .jumpTo(_offsets[index].clamp(0.0, _scroll.position.maxScrollExtent));
    _reportScroll();
  }

  void _page(int direction) {
    if (!_scroll.hasClients || _offsets.isEmpty) return;
    final distance = (_scroll.position.viewportDimension - widget.rowHeight)
        .clamp(widget.rowHeight, double.infinity);
    final position = _scroll.position;
    final focusedTop = _offsets[_index];
    final origin = focusedTop < position.pixels ||
            focusedTop >= position.pixels + position.viewportDimension
        ? position.pixels
        : focusedTop;
    final target = origin + distance * direction;
    // Group headings have their own height. Search the existing offset index
    // instead of walking or mounting rows to determine a page boundary.
    var low = 0, high = _offsets.length;
    while (low < high) {
      final middle = (low + high) ~/ 2;
      if (_offsets[middle] < target) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    _focus(low.clamp(0, widget.choices.length - 1));
  }

  Widget _navigationBar() => Focus(
      canRequestFocus: false,
      onKeyEvent: (_, event) {
        if (event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.arrowUp) {
          _focus(_index);
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Builder(builder: (context) {
        final colors = Theme.of(context).colorScheme;
        Widget button(String label, IconData icon, VoidCallback action,
                {FocusNode? focus}) =>
            IconButton(
                key: ValueKey('list-$label'),
                tooltip: label,
                focusNode: focus,
                style: IconButton.styleFrom(
                    minimumSize: const Size(32, 30),
                    maximumSize: const Size(32, 30),
                    padding: EdgeInsets.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                onPressed: action,
                icon: Icon(icon, size: 16));
        return DecoratedBox(
            decoration: BoxDecoration(
                border: Border(
                    top: BorderSide(
                        color: colors.outlineVariant.withValues(alpha: .35)))),
            child: Row(children: [
              const SizedBox(width: 8),
              Expanded(
                  child: Tooltip(
                      message:
                          'Right for list navigation · channel or page keys to skip a page',
                      child: Text('${widget.choices.length} results',
                          maxLines: 1,
                          style: TextStyle(
                              fontSize: 10,
                              color: colors.onSurfaceVariant,
                              fontFeatures: const [
                                FontFeature.tabularFigures()
                              ])))),
              button('First result', Icons.first_page, () => _focus(0)),
              button('Previous page', Icons.keyboard_double_arrow_up,
                  () => _page(-1)),
              button(
                  'Next page', Icons.keyboard_double_arrow_down, () => _page(1),
                  focus: _pageFocus),
              button('Last result', Icons.last_page,
                  () => _focus(widget.choices.length - 1)),
            ]));
      }));
  final _childIndices = <String, int>{};
  @visibleForTesting
  int get mountedFocusNodeCount => _nodes.length;
  void _register(String id, FocusNode node) => _nodes[id] = node;
  void _unregister(String id, FocusNode node) {
    if (identical(_nodes[id], node)) _nodes.remove(id);
  }

  @override
  void initState() {
    super.initState();
    _index = widget.choices.indexWhere((c) => c.id == widget.selected);
    if (_index < 0) _index = 0;
    _layout();
    _scroll.addListener(_reportScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        if (widget.autofocus) _focus(_index);
        _reportScroll();
      }
    });
  }

  @override
  void didUpdateWidget(CompactChoiceList oldWidget) {
    super.didUpdateWidget(oldWidget);
    final focused =
        _nodes.entries.where((e) => e.value.hasFocus).firstOrNull?.key;
    if (focused != null && !identical(oldWidget.choices, widget.choices)) {
      final index = widget.choices.indexWhere((choice) => choice.id == focused);
      if (index >= 0) _index = index;
    }
    _index =
        _index.clamp(0, widget.choices.isEmpty ? 0 : widget.choices.length - 1);
    ++_focusRequest;
    if (focused != null && !widget.choices.any((c) => c.id == focused)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && (ModalRoute.of(context)?.isCurrent ?? true)) {
          if (widget.choices.isEmpty) {
            widget.onExitUp?.call();
          } else {
            _focus(_index);
          }
        }
      });
    }
    if (!identical(oldWidget.choices, widget.choices) ||
        oldWidget.rowHeight != widget.rowHeight ||
        oldWidget.trailingMarker != widget.trailingMarker) {
      _layout();
      if (widget.onActiveIndexChanged != null) {
        _reportedIndex = null;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _reportScroll();
        });
      }
    }
    if (oldWidget.resetScrollKey != widget.resetScrollKey) {
      _index = 0;
      if (_scroll.hasClients) _scroll.jumpTo(0);
    }
  }

  void _layout() {
    _childIndices.clear();
    _rows.clear();
    _offsets.clear();
    String? group;
    var top = 0.0;
    for (var i = 0; i < widget.choices.length; i++) {
      final next = widget.choices[i].group;
      if (next != null && next != group) {
        _rows.add((index: i, heading: next, marker: null, top: top));
        top += 24;
      }
      group = next;
      if (widget.choices[i].markerBefore case final marker?) {
        _rows.add((index: i, heading: '', marker: marker, top: top));
        top += 24;
      }
      _offsets.add(top);
      _childIndices['choice-focus-${widget.choices[i].id}'] = _rows.length;
      _rows.add((index: i, heading: null, marker: null, top: top));
      top += widget.rowHeight;
    }
    if (widget.trailingMarker case final marker?) {
      _rows.add((
        index: widget.choices.length,
        heading: '',
        marker: marker,
        top: top
      ));
      top += 24;
    }
    _contentExtent = top;
  }

  void _focus(int index) {
    final token = ++_focusRequest;
    if (widget.choices.isEmpty) return;
    if (index < 0 && widget.onExitUp != null) {
      widget.onExitUp!();
      return;
    }
    if (index >= widget.choices.length && widget.onExitDown != null) {
      widget.onExitDown!();
      return;
    }
    if (index < 0 || index >= widget.choices.length) {
      FocusScope.of(context).focusInDirection(
          index < 0 ? TraversalDirection.up : TraversalDirection.down);
      return;
    }
    _rememberIndex(index.clamp(0, widget.choices.length - 1));
    if (_scroll.hasClients) {
      final p = _scroll.position;
      final top = _offsets[_index];
      if (top < p.pixels) _scroll.jumpTo(top.clamp(0.0, p.maxScrollExtent));
      if (top + widget.rowHeight > p.pixels + p.viewportDimension) {
        _scroll.jumpTo((top + widget.rowHeight - p.viewportDimension)
            .clamp(0.0, p.maxScrollExtent));
      }
    }
    void request() {
      if (!mounted ||
          token != _focusRequest ||
          _index >= widget.choices.length ||
          !(ModalRoute.of(context)?.isCurrent ?? true)) {
        return;
      }
      _nodes[widget.choices[_index].id]?.requestFocus();
    }

    if (_nodes[widget.choices[_index].id]?.context != null) {
      request();
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) => request());
    }
  }

  @override
  void dispose() {
    _scroll.removeListener(_reportScroll);
    if (widget.controller == null) _scroll.dispose();
    _pageFocus.dispose();
    ++_focusRequest;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final list = CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.arrowDown): () =>
            _focus(_index + 1),
        const SingleActivator(LogicalKeyboardKey.arrowUp): () =>
            _focus(_index - 1),
        const SingleActivator(LogicalKeyboardKey.pageDown): () => _page(1),
        const SingleActivator(LogicalKeyboardKey.channelDown): () => _page(1),
        const SingleActivator(LogicalKeyboardKey.pageUp): () => _page(-1),
        const SingleActivator(LogicalKeyboardKey.channelUp): () => _page(-1),
        const SingleActivator(LogicalKeyboardKey.home): () => _focus(0),
        const SingleActivator(LogicalKeyboardKey.end): () =>
            _focus(widget.choices.length - 1),
        if (_navigation)
          const SingleActivator(LogicalKeyboardKey.arrowRight):
              _pageFocus.requestFocus,
      },
      child: ListView.custom(
        controller: _scroll,
        scrollCacheExtent: widget.cacheExtent == null
            ? null
            : ScrollCacheExtent.pixels(widget.cacheExtent!),
        padding: EdgeInsets.zero,
        semanticChildCount: _rows.length,
        itemExtentBuilder: (i, _) =>
            _rows[i].heading == null ? widget.rowHeight : 24,
        childrenDelegate: _IndexedChoiceDelegate(
          (context, i) {
            final row = _rows[i];
            if (row.heading != null) {
              if (row.marker != null) return row.marker!;
              return Padding(
                  padding: const EdgeInsets.fromLTRB(8, 5, 8, 2),
                  child: Text(row.heading!,
                      style: TextStyle(
                          fontSize: 11,
                          color: scheme.primary,
                          fontWeight: FontWeight.w600)));
            }
            final choice = widget.choices[row.index];
            // Keep the content widget outside focus paints. A lazy builder should
            // run when the row mounts/changes, not on every remote focus update.
            final content = choice.content ??
                (choice.contentBuilder == null
                    ? null
                    : Builder(builder: choice.contentBuilder!));
            return _ChoiceFocus(
                key: ValueKey('choice-focus-${choice.id}'),
                id: choice.id,
                register: _register,
                unregister: _unregister,
                builder: (context, node) {
                  final selected = choice.id == widget.selected;
                  final tile = Material(
                      borderRadius:
                          widget.polished ? BorderRadius.circular(3) : null,
                      color: node.hasFocus
                          ? widget.polished
                              ? scheme.primary.withValues(alpha: .15)
                              : scheme.primaryContainer
                          : widget.polished && selected
                              ? scheme.primary.withValues(alpha: .07)
                              : widget.striped && row.index.isOdd
                                  ? scheme.onSurface.withValues(alpha: .025)
                                  : Colors.transparent,
                      child: InkWell(
                        key: ValueKey(choice.id),
                        borderRadius:
                            widget.polished ? BorderRadius.circular(3) : null,
                        focusNode: node,
                        onFocusChange: (focused) {
                          if (focused) _rememberIndex(row.index);
                        },
                        onTap: choice.onTap,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                              borderRadius: widget.polished
                                  ? BorderRadius.circular(3)
                                  : null,
                              border: Border.all(
                                  color: node.hasFocus
                                      ? scheme.primary
                                      : widget.polished && selected
                                          ? scheme.primary
                                              .withValues(alpha: .14)
                                          : Colors.transparent)),
                          child: content ??
                              Row(children: [
                                if (choice.leading != null) ...[
                                  choice.leading!,
                                  const SizedBox(width: 8)
                                ],
                                Expanded(
                                    child: Column(
                                        mainAxisAlignment:
                                            MainAxisAlignment.center,
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                      Text(choice.title,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                              fontSize:
                                                  widget.polished ? 12.5 : 13,
                                              height: 1.2,
                                              fontWeight: selected
                                                  ? FontWeight.w600
                                                  : FontWeight.w500)),
                                      if (choice.subtitle != null)
                                        Text(choice.subtitle!,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(
                                                fontSize: 10.5,
                                                color: Colors.white60)),
                                    ])),
                                if (choice.trailing != null) ...[
                                  SizedBox(width: widget.polished ? 5 : 8),
                                  choice.trailing!
                                ],
                                SizedBox(
                                    width: widget.polished ? 18 : 20,
                                    child: selected
                                        ? Icon(Icons.check,
                                            size: 16, color: scheme.primary)
                                        : null),
                              ]),
                        ),
                      ));
                  return choice.onHold == null
                      ? tile
                      : HoldToActivate(
                          onTap: choice.onTap,
                          onHold: choice.onHold!,
                          child: tile);
                });
          },
          childCount: _rows.length,
          extent: _contentExtent,
          findChildIndexCallback: (key) =>
              key is ValueKey<String> ? _childIndices[key.value] : null,
        ),
      ),
    );
    return _navigation
        ? Column(children: [Expanded(child: list), _navigationBar()])
        : list;
  }
}

// A recycled row releases its focus node; browsing a long catalogue no longer
// retains a node for every choice that has ever appeared.
class _ChoiceFocus extends StatefulWidget {
  const _ChoiceFocus(
      {super.key,
      required this.id,
      required this.register,
      required this.unregister,
      required this.builder});
  final String id;
  final void Function(String, FocusNode) register, unregister;
  final Widget Function(BuildContext, FocusNode) builder;
  @override
  State<_ChoiceFocus> createState() => _ChoiceFocusState();
}

class _ChoiceFocusState extends State<_ChoiceFocus> {
  late final _node = FocusNode(debugLabel: 'choice-${widget.id}');
  @override
  void initState() {
    super.initState();
    widget.register(widget.id, _node);
  }

  @override
  void dispose() {
    widget.unregister(widget.id, _node);
    _node.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
      listenable: _node,
      builder: (context, _) => widget.builder(context, _node));
}

// Group headings and choices already have exact indexed heights. Supplying the
// total avoids average-height estimates clamping a remote jump before its row.
class _IndexedChoiceDelegate extends SliverChildBuilderDelegate {
  _IndexedChoiceDelegate(super.builder,
      {required super.childCount,
      required this.extent,
      super.findChildIndexCallback});
  final double extent;

  @override
  double estimateMaxScrollOffset(int firstIndex, int lastIndex,
          double leadingScrollOffset, double trailingScrollOffset) =>
      extent;
}
