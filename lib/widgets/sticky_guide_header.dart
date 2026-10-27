import 'live_channel_logo.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import '../utils/guide_section_index.dart';
import '../utils/live_guide_search.dart';

/// An overlay, so the two guide columns keep identical row/scroll coordinates.
/// Most scroll ticks only run a binary lookup: rebuild on a section change or
/// while the next section is pushing this heading out of the viewport.
class StickyGuideHeader extends StatefulWidget {
  const StickyGuideHeader(
      {super.key,
      required this.index,
      required this.controller,
      required this.rowHeight});
  final GuideSectionIndex index;
  final ScrollController controller;
  final double rowHeight;
  @override
  State<StickyGuideHeader> createState() => _StickyGuideHeaderState();
}

class _StickyGuideHeaderState extends State<StickyGuideHeader> {
  Drag? _drag;
  final _position = ValueNotifier<PinnedGuideSection?>(null);
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_update);
    _update();
  }

  @override
  void didUpdateWidget(StickyGuideHeader oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      _drag?.cancel();
      _drag = null;
      oldWidget.controller.removeListener(_update);
      widget.controller.addListener(_update);
    }
    _update();
  }

  void _update() => _position.value = widget.index.pinned(
      widget.controller.hasClients ? widget.controller.offset : 0,
      widget.rowHeight);
  @override
  void dispose() {
    _drag?.cancel();
    widget.controller.removeListener(_update);
    _position.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
      child: Listener(
          onPointerSignal: (event) {
            if (event is PointerScrollEvent && widget.controller.hasClients) {
              GestureBinding.instance.pointerSignalResolver.register(
                  event,
                  (_) => widget.controller.position
                      .pointerScroll(event.scrollDelta.dy));
            }
          },
          child: GestureDetector(
              // Keep the recogniser mounted as headings change mid-drag. Only
              // the visible heading receives hits; the remaining guide is free.
              behavior: HitTestBehavior.deferToChild,
              onTap: () {},
              onVerticalDragStart: (details) {
                if (!widget.controller.hasClients) return;
                _drag?.cancel();
                _drag = widget.controller.position
                    .drag(details, () => _drag = null);
              },
              onVerticalDragUpdate: (details) => _drag?.update(details),
              onVerticalDragEnd: (details) => _drag?.end(details),
              onVerticalDragCancel: () => _drag?.cancel(),
              child: ClipRect(
                  child: ValueListenableBuilder(
                      valueListenable: _position,
                      builder: (context, position, _) {
                        if (position == null) return const SizedBox.shrink();
                        final span = widget.index.sections[position.section];
                        final colors = Theme.of(context).colorScheme;
                        return Align(
                            alignment: Alignment.topLeft,
                            child: Transform.translate(
                                offset: Offset(0, position.displacement),
                                child: Container(
                                    key: const ValueKey('guide-sticky-section'),
                                    height: widget.rowHeight,
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 10),
                                    decoration: BoxDecoration(
                                        color: Color.alphaBlend(
                                            colors.primary
                                                .withValues(alpha: .10),
                                            colors.surface),
                                        border: Border(
                                            bottom: BorderSide(
                                                color: colors.primary
                                                    .withValues(alpha: .24)))),
                                    child: Row(children: [
                                      SizedBox(
                                          width: 28,
                                          height: 28,
                                          child: (span.header.logoUrl
                                                      ?.isNotEmpty ??
                                                  false)
                                              ? LiveChannelLogo(
                                                  url: span.header.logoUrl!,
                                                  icon: Icons.segment)
                                              : Icon(Icons.segment,
                                                  size: 19,
                                                  color: colors.primary)),
                                      const SizedBox(width: 8),
                                      Expanded(
                                          child: Text(
                                              guideSectionTitle(span.header),
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(
                                                  fontSize: 12,
                                                  fontWeight: FontWeight.w700,
                                                  color: colors.primary))),
                                    ]))));
                      })))));
}
