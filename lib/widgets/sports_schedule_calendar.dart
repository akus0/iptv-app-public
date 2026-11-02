import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'sports_filter_picker.dart';
import '../utils/sports_calendar.dart';

/// Counts only: calendar browsing does not retain or build fixture rows.
class SportsScheduleSummary {
  const SportsScheduleSummary(this.sports,
      {required this.incomplete, required this.at});
  final Map<String, int> sports;
  final bool incomplete;
  final DateTime at;
}

class SportsScheduleCalendar extends StatelessWidget {
  const SportsScheduleCalendar(
      {super.key,
      required this.from,
      required this.days,
      required this.today,
      required this.selected,
      required this.summaries,
      required this.onSelected,
      required this.loading,
      this.sport,
      this.onLoadWeek,
      this.onStop});
  final DateTime from, today, selected;
  final int days;
  final String? sport;
  final Map<DateTime, SportsScheduleSummary> summaries;
  final ValueChanged<DateTime> onSelected;
  final bool loading;
  final VoidCallback? onLoadWeek, onStop;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final month = days > 7;
    final scale = MediaQuery.textScalerOf(context).scale(11) / 11;
    final leading = month ? from.weekday - 1 : 0;
    return LayoutBuilder(builder: (context, constraints) {
      final columns = month
          ? 7
          : constraints.maxWidth < 500
              ? 1
              : constraints.maxWidth < 900
                  ? 2
                  : 3;
      return CustomScrollView(
          key: ValueKey('schedule-calendar-$days-$from'),
          slivers: [
            SliverToBoxAdapter(
                child: Padding(
                    padding: const EdgeInsets.fromLTRB(10, 2, 8, 6),
                    child: Row(children: [
                      Expanded(
                          child: Text(
                              month
                                  ? 'Fixtures per day · — not loaded · ~ partial'
                                  : 'Daily fixtures by sport',
                              style: TextStyle(
                                  fontSize: 10,
                                  color: colors.onSurfaceVariant))),
                      if (onLoadWeek != null || onStop != null)
                        TextButton.icon(
                            key: const ValueKey('schedule-load-week'),
                            style: TextButton.styleFrom(
                                minimumSize: const Size(0, 32),
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                padding:
                                    const EdgeInsets.symmetric(horizontal: 8)),
                            onPressed: loading ? onStop : onLoadWeek,
                            icon: Icon(
                                loading
                                    ? Icons.stop_circle_outlined
                                    : Icons.refresh,
                                size: 14),
                            label: Text(loading ? 'Stop' : 'Load week',
                                style: const TextStyle(fontSize: 10))),
                    ]))),
            if (month)
              SliverToBoxAdapter(
                  child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      child: Row(children: [
                        for (final day in ['M', 'T', 'W', 'T', 'F', 'S', 'S'])
                          Expanded(
                              child: Padding(
                                  padding: const EdgeInsets.only(bottom: 6),
                                  child: Text(day,
                                      textAlign: TextAlign.center,
                                      style: TextStyle(
                                          fontSize: 10,
                                          color: colors.onSurfaceVariant))))
                      ]))),
            SliverPadding(
                padding: const EdgeInsets.fromLTRB(6, 0, 6, 6),
                sliver: SliverGrid.builder(
                    itemCount: leading + days,
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: columns,
                        mainAxisExtent: (month ? 64 : 72) * scale,
                        crossAxisSpacing: 4,
                        mainAxisSpacing: 4),
                    itemBuilder: (context, index) {
                      if (index < leading) return const SizedBox.shrink();
                      final day = sportsCalendarDay(from, index - leading);
                      final summary = summaries[day];
                      final sports = (summary?.sports.entries ??
                              const <MapEntry<String, int>>[])
                          .where((e) => sport == null || e.key == sport)
                          .toList()
                        ..sort((a, b) {
                          final count = b.value.compareTo(a.value);
                          return count != 0 ? count : a.key.compareTo(b.key);
                        });
                      final total = sports.fold(0, (n, e) => n + e.value);
                      final detail = summary == null
                          ? 'Not loaded · open day'
                          : '${summary.incomplete ? 'Partial · ' : ''}$total fixtures${sports.isEmpty ? '' : ' · ${sports.map((e) => '${sportLabel(e.key)} ${e.value}').join(', ')}'}';
                      final active = day == selected;
                      final label = DateFormat('EEEE d MMMM').format(day);
                      return Tooltip(
                          message: '$label · $detail',
                          child: Material(
                              color: active
                                  ? colors.primary.withValues(alpha: .09)
                                  : colors.onSurface.withValues(alpha: .025),
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(5),
                                  side: BorderSide(
                                      color: active
                                          ? colors.primary.withValues(alpha: .6)
                                          : colors.outlineVariant
                                              .withValues(alpha: .4))),
                              clipBehavior: Clip.antiAlias,
                              child: InkWell(
                                  key: ValueKey(
                                      'schedule-calendar-day-${DateFormat('yyyy-MM-dd').format(day)}'),
                                  onTap: () => onSelected(day),
                                  onFocusChange: (focused) {
                                    if (focused) {
                                      Scrollable.ensureVisible(context,
                                          alignmentPolicy:
                                              ScrollPositionAlignmentPolicy
                                                  .keepVisibleAtEnd);
                                    }
                                  },
                                  child: Semantics(
                                      label: '$label · $detail',
                                      button: true,
                                      excludeSemantics: true,
                                      child: Padding(
                                          padding:
                                              EdgeInsets.all(month ? 5 : 8),
                                          child: Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                Text(
                                                    month
                                                        ? '${day.day}'
                                                        : '${day == today ? 'Today · ' : ''}${DateFormat('EEE d MMM').format(day)}',
                                                    maxLines: 1,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                    style: TextStyle(
                                                        fontSize: 12,
                                                        fontWeight:
                                                            FontWeight.w600,
                                                        color: day == today ||
                                                                active
                                                            ? colors.primary
                                                            : colors
                                                                .onSurface)),
                                                const SizedBox(height: 4),
                                                Text(
                                                    summary == null
                                                        ? (month
                                                            ? '—'
                                                            : 'Open to load fixtures')
                                                        : month
                                                            ? '${summary.incomplete ? '~' : ''}$total'
                                                            : '$total fixtures${summary.incomplete ? ' · partial' : ''}',
                                                    maxLines: 1,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                    style: TextStyle(
                                                        fontSize:
                                                            month ? 11 : 12,
                                                        color: colors
                                                            .onSurfaceVariant)),
                                                const Spacer(),
                                                if (sports.isNotEmpty)
                                                  month
                                                      ? Row(children: [
                                                          for (final e
                                                              in sports.take(2))
                                                            Expanded(
                                                                child: Icon(
                                                                    sportIcon(
                                                                        e.key),
                                                                    size: 12,
                                                                    color: colors
                                                                        .onSurfaceVariant))
                                                        ])
                                                      : Text(
                                                          sports
                                                              .take(3)
                                                              .map((e) =>
                                                                  '${shortSportLabel(e.key)} ${e.value}')
                                                              .join(' · '),
                                                          maxLines: 1,
                                                          overflow: TextOverflow
                                                              .ellipsis,
                                                          style: TextStyle(
                                                              fontSize: 10,
                                                              color: colors
                                                                  .onSurfaceVariant)),
                                              ]))))));
                    })),
          ]);
    });
  }
}
