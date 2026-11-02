import '../utils/interface_colors.dart';
import 'package:flutter/material.dart';

@immutable
class GuideBrowsePosition {
  const GuideBrowsePosition(
      {required this.row,
      required this.total,
      required this.category,
      required this.channel,
      required this.fast});
  final int row, total;
  final String category, channel;
  final bool fast;
}

/// Position feedback overlays the guide; it never shifts rows or takes focus.
class GuideBrowsePositionOverlay extends StatelessWidget {
  const GuideBrowsePositionOverlay({super.key, required this.position});
  final ValueNotifier<GuideBrowsePosition?> position;

  @override
  Widget build(BuildContext context) => IgnorePointer(
          child: ValueListenableBuilder<GuideBrowsePosition?>(
        valueListenable: position,
        builder: (context, value, _) {
          if (value == null) return const SizedBox.shrink();
          final accent = Theme.of(context).colorScheme.primary;
          return Stack(children: [
            Positioned(
                top: 12,
                bottom: 12,
                right: 3,
                child: SizedBox(
                    width: 4,
                    child: LayoutBuilder(
                        builder: (_, box) => Stack(children: [
                              Positioned.fill(
                                  child: ColoredBox(color: interfaceColor(context, Colors.white12))),
                              Positioned(
                                  top: (box.maxHeight - 20)
                                          .clamp(0, double.infinity) *
                                      (value.total < 2
                                          ? 0
                                          : value.row / (value.total - 1)),
                                  child: Container(
                                      width: 4, height: 20, color: accent)),
                            ])))),
            Positioned(
                top: 8,
                right: 16,
                child: Container(
                    key: const ValueKey('guide-browse-position'),
                    width: 278,
                    padding: const EdgeInsets.fromLTRB(12, 9, 12, 9),
                    decoration: BoxDecoration(
                        color: const Color(0xF018222D),
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(color: interfaceColor(context, Colors.white24))),
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Row(children: [
                            Icon(
                                value.fast
                                    ? Icons.swap_vert_rounded
                                    : Icons.location_on_outlined,
                                size: 15,
                                color: accent),
                            const SizedBox(width: 6),
                            Expanded(
                                child: Text(
                                    value.fast
                                        ? 'Fast browse'
                                        : 'Channel position',
                                    style: TextStyle(
                                        fontSize: 10, color: interfaceColor(context, Colors.white60)))),
                            Text(
                                '${_number(value.row + 1)} / ${_number(value.total)}',
                                style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                    color: accent)),
                          ]),
                          const SizedBox(height: 5),
                          Text(value.category,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: 11, color: interfaceColor(context, Colors.white70))),
                          const SizedBox(height: 2),
                          Text(value.channel,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                  color: interfaceColor(context, Colors.white))),
                        ]))),
          ]);
        },
      ));

  static String _number(int value) => value
      .toString()
      .replaceAllMapped(RegExp(r'(\d)(?=(\d{3})+(?!\d))'), (m) => '${m[1]},');
}
