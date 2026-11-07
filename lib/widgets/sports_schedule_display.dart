import 'package:flutter/material.dart';
import '../utils/guarded_dialog.dart';
import 'sports_header_controls.dart';

/// Local presentation options; opening this panel never requests fixtures.
class SportsScheduleDisplay extends StatelessWidget {
  const SportsScheduleDisplay(
      {super.key,
      required this.height,
      required this.canGroup,
      required this.grouped,
      required this.completed,
      required this.onGroup,
      required this.onCompleted});
  final double height;
  final bool canGroup, grouped, completed;
  final ValueChanged<bool> onGroup, onCompleted;
  @override
  Widget build(BuildContext context) => Tooltip(
      message:
          '${canGroup && grouped ? 'Grouped by sport' : 'Time order'} · Completed ${completed ? 'shown' : 'hidden'}',
      child: TextButton.icon(
        key: const ValueKey('schedule-display'),
        style: TextButton.styleFrom(
            minimumSize: Size(0, height),
            padding: const EdgeInsets.symmetric(horizontal: 8),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap),
        icon: const Icon(Icons.tune, size: 17),
        label: const Text('Display', style: TextStyle(fontSize: 11)),
        onPressed: () {
          var group = grouped, show = completed;
          showSportsDialog<void>(
              context: context,
              builder: (dialogContext) => StatefulBuilder(
                  builder: (context, update) => SportsCompactDialog(
                        title: 'Schedule display',
                        actions: [
                          TextButton(
                              onPressed: () => popRouteIfCurrent(dialogContext),
                              child: const Text('Done'))
                        ],
                        child: SizedBox(
                            width: 340,
                            child: Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  if (canGroup) ...[
                                    const Text('Order',
                                        style: TextStyle(
                                            fontSize: 11,
                                            fontWeight: FontWeight.w600)),
                                    const SizedBox(height: 6),
                                    Wrap(spacing: 6, runSpacing: 6, children: [
                                      for (final value in [false, true])
                                        SportsOptionButton(
                                            autofocus: !value,
                                            key: ValueKey(
                                                'schedule-order-${value ? 'sport' : 'time'}'),
                                            label: value
                                                ? 'Group by sport'
                                                : 'Time order',
                                            selected: group == value,
                                            onPressed: () {
                                              if (group == value) return;
                                              update(() => group = value);
                                              onGroup(value);
                                            }),
                                    ]),
                                    const SizedBox(height: 14),
                                  ],
                                  const Text('Completed games',
                                      style: TextStyle(
                                          fontSize: 11,
                                          fontWeight: FontWeight.w600)),
                                  const SizedBox(height: 6),
                                  Wrap(spacing: 6, runSpacing: 6, children: [
                                    for (final value in [false, true])
                                      SportsOptionButton(
                                          autofocus: !canGroup && !value,
                                          key: ValueKey(
                                              'schedule-completed-${value ? 'show' : 'hide'}'),
                                          label: value ? 'Show' : 'Hide',
                                          selected: show == value,
                                          onPressed: () {
                                            if (show == value) return;
                                            update(() => show = value);
                                            onCompleted(value);
                                          }),
                                  ]),
                                  const SizedBox(height: 10),
                                  const Text('Changes apply immediately.',
                                      style: TextStyle(fontSize: 11)),
                                ])),
                      )));
        },
      ));
}
