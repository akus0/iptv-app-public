import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../utils/sports_calendar.dart';

/// Selecting a date filters the loaded window; it never loads another feed.
class SportsScheduleDays extends StatelessWidget {
  const SportsScheduleDays(
      {super.key,
      required this.from,
      required this.days,
      required this.today,
      required this.counts,
      required this.selected,
      required this.onSelected,
      this.showAll = true,
      this.showCounts = true,
      this.compact = false,
      this.portrait = false});
  final DateTime from, today;
  final int days;
  final bool showAll, showCounts, compact, portrait;
  final Map<DateTime, int> counts;
  final DateTime? selected;
  final ValueChanged<DateTime?> onSelected;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    Widget day(DateTime? date) {
      final active = selected == date;
      final count = date == null
          ? counts.values.fold(0, (a, b) => a + b)
          : counts[date] ?? 0;
      return Padding(
          padding: const EdgeInsets.only(right: 4),
          child: TextButton(
              key: ValueKey(date == null
                  ? 'schedule-day-all'
                  : 'schedule-day-${DateFormat('yyyy-MM-dd').format(date)}'),
              onPressed: () => onSelected(date),
              style: TextButton.styleFrom(
                  minimumSize: Size(
                      54,
                      compact && !showCounts
                          ? 34
                          : portrait
                              ? 36
                              : 48),
                  tapTargetSize:
                      portrait ? MaterialTapTargetSize.shrinkWrap : null,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(4),
                      side: BorderSide(
                          color: active
                              ? colors.primary.withValues(alpha: .6)
                              : Colors.transparent)),
                  foregroundColor:
                      active ? colors.primary : colors.onSurfaceVariant,
                  backgroundColor: active
                      ? colors.primary.withValues(alpha: .10)
                      : colors.onSurface.withValues(alpha: .025)),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Text(
                    date == null
                        ? 'All dates'
                        : date == today
                            ? 'Today'
                            : DateFormat('EEE d').format(date),
                    style: const TextStyle(
                        fontSize: 10.5, fontWeight: FontWeight.w600)),
                if (showCounts)
                  Text('$count',
                      style: TextStyle(
                          fontSize: 10,
                          color: colors.onSurfaceVariant,
                          fontFeatures: const [FontFeature.tabularFigures()])),
              ])));
    }

    return SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(children: [
          if (showAll) day(null),
          for (var i = 0; i < days; i++) day(sportsCalendarDay(from, i))
        ]));
  }
}
