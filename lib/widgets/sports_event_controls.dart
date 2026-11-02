import 'sports_header_controls.dart';
import 'package:flutter/material.dart';
import '../utils/sports_time_filter.dart';
import '../utils/sports_channel_filter.dart';
import '../utils/guarded_dialog.dart';

class SportsTimeControl extends StatelessWidget {
  const SportsTimeControl(
      {super.key,
      required this.value,
      required this.onChoose,
      required this.focusNode});
  final SportsTimeFilter value;
  final VoidCallback onChoose;
  final FocusNode focusNode;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Tooltip(
        message: 'Show events: ${value.label}',
        child: TextButton(
            focusNode: focusNode,
            onPressed: onChoose,
            style: TextButton.styleFrom(
                animationDuration: Duration.zero,
                padding: const EdgeInsets.symmetric(horizontal: 4),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                foregroundColor: value == SportsTimeFilter.all
                    ? colors.onSurfaceVariant
                    : colors.primary,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(6))),
            child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              const Icon(Icons.schedule, size: 13),
              const SizedBox(width: 4),
              Flexible(
                  child: Text(
                      value == SportsTimeFilter.soon ? 'Soon' : value.label,
                      maxLines: 1,
                      style: const TextStyle(
                          fontSize: 10.5, fontWeight: FontWeight.w600))),
            ])));
  }
}

/// Applies choices immediately. Opening or dismissing never loads sports data.
Future<void> showSportsEventFilters(
  BuildContext context, {
  required SportsTimeFilter time,
  required SportsChannelFilter channels,
  required ValueChanged<SportsTimeFilter> onTime,
  required ValueChanged<SportsChannelFilter> onChannels,
}) =>
    showSportsDialog<void>(
        context: context,
        builder: (_) => _EventFilters(
            time: time,
            channels: channels,
            onTime: onTime,
            onChannels: onChannels));

class _EventFilters extends StatefulWidget {
  const _EventFilters(
      {required this.time,
      required this.channels,
      required this.onTime,
      required this.onChannels});
  final SportsTimeFilter time;
  final SportsChannelFilter channels;
  final ValueChanged<SportsTimeFilter> onTime;
  final ValueChanged<SportsChannelFilter> onChannels;
  @override
  State<_EventFilters> createState() => _EventFiltersState();
}

class _EventFiltersState extends State<_EventFilters> {
  late var time = widget.time;
  late var channels = widget.channels;
  @override
  Widget build(BuildContext context) {
    Widget choice(String key, String label, String description, bool selected,
            VoidCallback select) =>
        SportsOptionButton(
            key: ValueKey(key),
            label: label,
            selected: selected,
            tooltip: description,
            onPressed: select);
    return SportsCompactDialog(
      title: 'Event filters',
      actions: [
        TextButton(
            style: sportsPopupButtonStyle(context),
            onPressed: () => popRouteIfCurrent(context),
            child: const Text('Done'))
      ],
      child: SizedBox(
          width: 380,
          child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Showing',
                    style:
                        TextStyle(fontSize: 10.5, fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                Wrap(spacing: 6, runSpacing: 6, children: [
                  for (final mode in [
                    SportsTimeFilter.all,
                    SportsTimeFilter.live,
                    SportsTimeFilter.liveAndSoon,
                    SportsTimeFilter.soon
                  ])
                    choice(
                        'time-filter-${mode.name}',
                        switch (mode) {
                          SportsTimeFilter.all => 'All',
                          SportsTimeFilter.soon => 'Soon',
                          _ => mode.label,
                        },
                        mode.description,
                        time == mode, () {
                      setState(() => time = mode);
                      widget.onTime(mode);
                    }),
                ]),
                const SizedBox(height: 12),
                const Text('Channel matches',
                    style:
                        TextStyle(fontSize: 10.5, fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                Wrap(spacing: 6, runSpacing: 6, children: [
                  for (final mode in SportsChannelFilter.values)
                    choice(
                        'channel-filter-${mode.name}',
                        switch (mode) {
                          SportsChannelFilter.matched => 'Matched',
                          SportsChannelFilter.possible => 'Possible',
                          SportsChannelFilter.all => 'Any',
                        },
                        mode.description,
                        channels == mode, () {
                      setState(() => channels = mode);
                      widget.onChannels(mode);
                    }),
                ]),
              ])),
    );
  }
}
