import 'package:flutter/material.dart';
import 'live_channel_logo.dart';
import 'package:flutter/services.dart';
import 'hold_to_activate.dart';

typedef GuideSection = ({int index, String title, String? logoUrl});

/// A bounded, lazy list; selecting a section only moves the guide.
class GuideSectionPicker extends StatefulWidget {
  const GuideSectionPicker(
      {super.key, required this.sections, required this.current});
  final List<GuideSection> sections;
  final int current;
  @override
  State<GuideSectionPicker> createState() => _GuideSectionPickerState();
}

class _GuideSectionPickerState extends State<GuideSectionPicker> {
  late final ScrollController _scroll;
  final _nodes = <int, FocusNode>{};
  late int _index;
  static const _rowHeight = 40.0;
  @override
  void initState() {
    super.initState();
    _index = widget.current.clamp(0, widget.sections.length - 1);
    _scroll = ScrollController(initialScrollOffset: _index * _rowHeight);
  }

  void _move(int delta) {
    final next = (_index + delta).clamp(0, widget.sections.length - 1);
    _index = next;
    if (_scroll.hasClients) {
      final pos = _scroll.position;
      final top = next * _rowHeight;
      if (top < pos.pixels) _scroll.jumpTo(top);
      if (top + _rowHeight > pos.pixels + pos.viewportDimension) {
        _scroll.jumpTo((top + _rowHeight - pos.viewportDimension)
            .clamp(0.0, pos.maxScrollExtent));
      }
    }
    final node = _nodes[next];
    if (node?.context != null) {
      node!.requestFocus();
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _nodes[next]?.requestFocus();
      });
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    for (final node in _nodes.values) {
      node.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SwallowHeldActivate(
        child: Dialog(
          key: const ValueKey('guide-section-picker'),
          insetPadding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
          child: SizedBox(
            width: 420,
            height: (48 + widget.sections.length * _rowHeight).clamp(128.0,
                (MediaQuery.sizeOf(context).height * .72).clamp(128.0, 560.0)),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(6, 2, 6, 6),
              child: Column(children: [
                SizedBox(
                    height: 40,
                    child: Row(children: [
                      const SizedBox(width: 6),
                      const Expanded(
                          child: Text('Jump to section',
                              style: TextStyle(
                                  fontSize: 16, fontWeight: FontWeight.w600))),
                      IconButton(
                          tooltip: 'Close sections',
                          onPressed: () => Navigator.pop(context),
                          icon: const Icon(Icons.close, size: 19)),
                    ])),
                Expanded(
                    child: CallbackShortcuts(
                  bindings: {
                    const SingleActivator(LogicalKeyboardKey.arrowDown): () =>
                        _move(1),
                    const SingleActivator(LogicalKeyboardKey.arrowUp): () =>
                        _move(-1),
                  },
                  child: ListView.builder(
                    padding: EdgeInsets.zero,
                    controller: _scroll,
                    itemExtent: _rowHeight,
                    itemCount: widget.sections.length,
                    itemBuilder: (context, i) {
                      final section = widget.sections[i];
                      return HoldToActivate(
                        onTap: () => Navigator.pop(context, section.index),
                        child: ListTile(
                          key: ValueKey('guide-section-${section.index}'),
                          focusNode: _nodes.putIfAbsent(i, () => FocusNode()),
                          autofocus: i == _index,
                          selected: i == widget.current,
                          dense: true,
                          minTileHeight: _rowHeight,
                          minVerticalPadding: 0,
                          minLeadingWidth: 28,
                          horizontalTitleGap: 8,
                          contentPadding:
                              const EdgeInsets.symmetric(horizontal: 6),
                          leading: SizedBox(
                              width: 28,
                              height: 28,
                              child: section.logoUrl?.isNotEmpty == true
                                  ? LiveChannelLogo(
                                      url: section.logoUrl!,
                                      icon: Icons.segment)
                                  : const Icon(Icons.segment, size: 18)),
                          title: Text(section.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 12.5)),
                          onFocusChange: (focused) {
                            if (focused) _index = i;
                          },
                          onTap: () => Navigator.pop(context, section.index),
                        ),
                      );
                    },
                  ),
                )),
              ]),
            ),
          ),
        ),
      );
}
