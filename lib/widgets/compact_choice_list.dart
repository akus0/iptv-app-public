import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class CompactChoice {
  const CompactChoice(
      {required this.id,
      required this.title,
      required this.onTap,
      this.subtitle,
      this.group,
      this.leading,
      this.trailing});
  final String id, title;
  final String? subtitle, group;
  final Widget? leading, trailing;
  final VoidCallback onTap;
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
      this.resetScrollKey});
  final List<CompactChoice> choices;
  final String? selected;
  final double rowHeight;
  final bool polished;
  final Object? resetScrollKey;
  @override
  State<CompactChoiceList> createState() => _CompactChoiceListState();
}

class _CompactChoiceListState extends State<CompactChoiceList> {
  final _scroll = ScrollController();
  final _nodes = <String, FocusNode>{};
  final _rows = <({int index, String? heading, double top})>[];
  final _offsets = <double>[];
  int _index = 0, _focusRequest = 0;
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
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus(_index);
    });
  }

  @override
  void didUpdateWidget(CompactChoiceList old) {
    super.didUpdateWidget(old);
    final focused =
        _nodes.entries.where((e) => e.value.hasFocus).firstOrNull?.key;
    if (focused != null && !identical(old.choices, widget.choices)) {
      final index = widget.choices.indexWhere((choice) => choice.id == focused);
      if (index >= 0) _index = index;
    }
    _index =
        _index.clamp(0, widget.choices.isEmpty ? 0 : widget.choices.length - 1);
    ++_focusRequest;
    if (!identical(old.choices, widget.choices) ||
        old.rowHeight != widget.rowHeight) {
      _layout();
    }
    if (old.resetScrollKey != widget.resetScrollKey) {
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
        _rows.add((index: i, heading: next, top: top));
        top += 24;
      }
      group = next;
      _offsets.add(top);
      _childIndices['choice-focus-${widget.choices[i].id}'] = _rows.length;
      _rows.add((index: i, heading: null, top: top));
      top += widget.rowHeight;
    }
  }

  void _focus(int index) {
    final token = ++_focusRequest;
    if (widget.choices.isEmpty) return;
    if (index < 0 || index >= widget.choices.length) {
      FocusScope.of(context).focusInDirection(
          index < 0 ? TraversalDirection.up : TraversalDirection.down);
      return;
    }
    _index = index.clamp(0, widget.choices.length - 1);
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
    _scroll.dispose();
    ++_focusRequest;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.arrowDown): () =>
            _focus(_index + 1),
        const SingleActivator(LogicalKeyboardKey.arrowUp): () =>
            _focus(_index - 1),
      },
      child: ListView.builder(
        controller: _scroll,
        padding: EdgeInsets.zero,
        itemCount: _rows.length,
        findChildIndexCallback: (key) =>
            key is ValueKey<String> ? _childIndices[key.value] : null,
        itemExtentBuilder: (i, _) =>
            _rows[i].heading == null ? widget.rowHeight : 24,
        itemBuilder: (context, i) {
          final row = _rows[i];
          if (row.heading != null) {
            return Padding(
                padding: const EdgeInsets.fromLTRB(8, 5, 8, 2),
                child: Text(row.heading!,
                    style: TextStyle(
                        fontSize: 11,
                        color: scheme.primary,
                        fontWeight: FontWeight.w600)));
          }
          final choice = widget.choices[row.index];
          return _ChoiceFocus(
              key: ValueKey('choice-focus-${choice.id}'),
              id: choice.id,
              register: _register,
              unregister: _unregister,
              builder: (context, node) {
                final selected = choice.id == widget.selected;
                return Material(
                    borderRadius:
                        widget.polished ? BorderRadius.circular(3) : null,
                    color: node.hasFocus
                        ? widget.polished
                            ? scheme.primary.withValues(alpha: .15)
                            : scheme.primaryContainer
                        : widget.polished && selected
                            ? scheme.primary.withValues(alpha: .07)
                            : Colors.transparent,
                    child: InkWell(
                      key: ValueKey(choice.id),
                      borderRadius:
                          widget.polished ? BorderRadius.circular(3) : null,
                      focusNode: node,
                      onFocusChange: (focused) {
                        if (focused) _index = row.index;
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
                                        ? scheme.primary.withValues(alpha: .14)
                                        : Colors.transparent)),
                        child: Row(children: [
                          if (choice.leading != null) ...[
                            choice.leading!,
                            const SizedBox(width: 8)
                          ],
                          Expanded(
                              child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                Text(choice.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                        fontSize: widget.polished ? 12.5 : 13,
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
              });
        },
      ),
    );
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
