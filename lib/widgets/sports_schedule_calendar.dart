import 'dart:math' as math;
import 'package:flutter/services.dart';
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

class SportsScheduleCalendar extends StatefulWidget {
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
      this.onLoadMonth,
      this.onStop,
      this.onExitUp});
  final DateTime from, today, selected;
  final int days;
  final String? sport;
  final Map<DateTime, SportsScheduleSummary> summaries;
  final ValueChanged<DateTime> onSelected;
  final bool loading;
  final VoidCallback? onLoadWeek, onLoadMonth, onStop, onExitUp;
  @override
  State<SportsScheduleCalendar> createState() => SportsScheduleCalendarState();
}

class SportsScheduleCalendarState extends State<SportsScheduleCalendar> {
  final _scroll = ScrollController();
  final _loadFocus = FocusNode(debugLabel: 'calendar-load');
  final _nodes = <int, FocusNode>{};
  int _columns = 7, _leading = 0, _focusRequest = 0;
  double _extent = 68;
  bool get _month => widget.days > 7;
  bool get _hasLoad => widget.loading
      ? widget.onStop != null
      : (_month ? widget.onLoadMonth : widget.onLoadWeek) != null;
  FocusNode _node(int index) => _nodes.putIfAbsent(
      index, () => FocusNode(debugLabel: 'calendar-day-$index'));

  @override
  void didUpdateWidget(SportsScheduleCalendar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.from != widget.from || oldWidget.days != widget.days) {
      _focusRequest++;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _scroll.hasClients) _scroll.jumpTo(0);
      });
    }
  }

  @override
  void dispose() {
    _focusRequest++;
    _scroll.dispose();
    _loadFocus.dispose();
    for (final node in _nodes.values) {
      node.dispose();
    }
    super.dispose();
  }

  void focusEntry() =>
      _focusDay(sportsCalendarDayOffset(widget.from, widget.selected)
          .clamp(0, widget.days - 1));

  void _focusDay(int index) {
    if (!mounted || index < 0 || index >= widget.days) return;
    final request = ++_focusRequest;
    var scrolled = false;
    if (_scroll.hasClients) {
      final position = _scroll.position;
      final rows = ((_leading + widget.days) / _columns).ceil();
      // Sliver extent includes the small legend/header before the grid. This
      // reveals an unmounted destination without building preceding dates.
      final header = math.max(
          0.0,
          position.maxScrollExtent +
              position.viewportDimension -
              (rows * _extent + 2));
      final top = header + ((index + _leading) ~/ _columns) * _extent;
      final bottom = top + _extent - 4;
      var offset = position.pixels;
      if (top < offset) offset = top;
      if (bottom > offset + position.viewportDimension) {
        offset = bottom - position.viewportDimension;
      }
      final target = offset.clamp(0.0, position.maxScrollExtent);
      if ((target - position.pixels).abs() > .5) {
        _scroll.jumpTo(target);
        scrolled = true;
      }
    }
    void focus() {
      if (!mounted || request != _focusRequest) return;
      final node = _node(index);
      if (node.context != null) {
        node.requestFocus();
        Scrollable.ensureVisible(node.context!,
            alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd);
      }
    }

    if (!scrolled && _node(index).context != null) {
      focus();
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) => focus());
    }
  }

  KeyEventResult _dayKey(int index, KeyEvent event) {
    final key = event.logicalKey;
    final delta = key == LogicalKeyboardKey.arrowLeft
        ? -1
        : key == LogicalKeyboardKey.arrowRight
            ? 1
            : key == LogicalKeyboardKey.arrowUp
                ? -_columns
                : key == LogicalKeyboardKey.arrowDown
                    ? _columns
                    : null;
    if (delta == null) return KeyEventResult.ignored;
    if (event is KeyUpEvent) return KeyEventResult.handled;
    final target = index + delta;
    if (target < 0 && key == LogicalKeyboardKey.arrowUp) {
      if (_hasLoad) {
        _loadFocus.requestFocus();
        if (_scroll.hasClients) _scroll.jumpTo(0);
      } else if (widget.onExitUp != null) {
        widget.onExitUp!();
      } else {
        return KeyEventResult.ignored;
      }
    } else if (target >= 0 && target < widget.days) {
      _focusDay(target);
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final scale = MediaQuery.textScalerOf(context).scale(11) / 11;
    _leading = _month ? widget.from.weekday - 1 : 0;
    _extent = (_month ? 64 : 72) * scale + 4;
    return LayoutBuilder(builder: (context, constraints) {
      _columns = _month
          ? 7
          : constraints.maxWidth < 500
              ? 1
              : constraints.maxWidth < 900
                  ? 2
                  : 3;
      return CustomScrollView(
          controller: _scroll,
          key: ValueKey('schedule-calendar-${widget.days}-${widget.from}'),
          slivers: [
            SliverToBoxAdapter(
                child: Padding(
                    padding: const EdgeInsets.fromLTRB(10, 2, 8, 6),
                    child: Row(children: [
                      Expanded(
                          child: Text(
                              _month
                                  ? 'Fixtures per day · — not loaded · ~ partial'
                                  : 'Daily fixtures by sport',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: 10,
                                  color: colors.onSurfaceVariant))),
                      if (_hasLoad)
                        Focus(
                            onKeyEvent: (_, event) {
                              if (event.logicalKey ==
                                  LogicalKeyboardKey.arrowDown) {
                                if (event is! KeyUpEvent) focusEntry();
                                return KeyEventResult.handled;
                              }
                              if (event.logicalKey ==
                                      LogicalKeyboardKey.arrowUp &&
                                  widget.onExitUp != null) {
                                if (event is! KeyUpEvent) widget.onExitUp!();
                                return KeyEventResult.handled;
                              }
                              return KeyEventResult.ignored;
                            },
                            child: TextButton.icon(
                                key: ValueKey(_month
                                    ? 'schedule-load-month'
                                    : 'schedule-load-week'),
                                focusNode: _loadFocus,
                                style: TextButton.styleFrom(
                                    animationDuration: Duration.zero,
                                    minimumSize: const Size(0, 32),
                                    tapTargetSize:
                                        MaterialTapTargetSize.shrinkWrap,
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 8)),
                                onPressed: widget.loading
                                    ? widget.onStop
                                    : _month
                                        ? widget.onLoadMonth
                                        : widget.onLoadWeek,
                                icon: Icon(
                                    widget.loading
                                        ? Icons.stop_circle_outlined
                                        : Icons.refresh,
                                    size: 14),
                                label: Text(
                                    widget.loading
                                        ? 'Stop'
                                        : _month
                                            ? 'Load month'
                                            : 'Load week',
                                    style: const TextStyle(fontSize: 10)))),
                    ]))),
            if (_month)
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
                                          color: colors.onSurfaceVariant)))),
                      ]))),
            SliverPadding(
                padding: const EdgeInsets.fromLTRB(6, 0, 6, 6),
                sliver: SliverGrid.builder(
                    itemCount: _leading + widget.days,
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: _columns,
                        mainAxisExtent: _extent - 4,
                        crossAxisSpacing: 4,
                        mainAxisSpacing: 4),
                    itemBuilder: (context, index) {
                      if (index < _leading) return const SizedBox.shrink();
                      final dayIndex = index - _leading;
                      final day = sportsCalendarDay(widget.from, dayIndex);
                      final summary = widget.summaries[day];
                      final sports = (summary?.sports.entries ??
                              const <MapEntry<String, int>>[])
                          .where((e) =>
                              widget.sport == null || e.key == widget.sport)
                          .toList()
                        ..sort((a, b) {
                          final count = b.value.compareTo(a.value);
                          return count != 0 ? count : a.key.compareTo(b.key);
                        });
                      final total = sports.fold(0, (n, e) => n + e.value);
                      final detail = summary == null
                          ? 'Not loaded · open day'
                          : '${summary.incomplete ? 'Partial · ' : ''}$total fixtures${sports.isEmpty ? '' : ' · ${sports.map((e) => '${sportLabel(e.key)} ${e.value}').join(', ')}'}';
                      final active = day == widget.selected;
                      final label = DateFormat('EEEE d MMMM').format(day);
                      final node = _node(dayIndex);
                      return Focus(
                          onKeyEvent: (_, event) => _dayKey(dayIndex, event),
                          child: ListenableBuilder(
                              listenable: node,
                              builder: (context, _) => Tooltip(
                                  message: '$label · $detail',
                                  child: Material(
                                      animationDuration: Duration.zero,
                                      color: node.hasFocus
                                          ? colors.primaryContainer
                                          : active
                                              ? colors.primary
                                                  .withValues(alpha: .09)
                                              : colors.onSurface
                                                  .withValues(alpha: .025),
                                      shape: RoundedRectangleBorder(
                                          borderRadius:
                                              BorderRadius.circular(5),
                                          side: BorderSide(
                                              width: node.hasFocus ? 1.5 : 1,
                                              color: node.hasFocus
                                                  ? colors.primary
                                                  : active
                                                      ? colors.primary
                                                          .withValues(alpha: .6)
                                                      : colors.outlineVariant
                                                          .withValues(
                                                              alpha: .4))),
                                      clipBehavior: Clip.antiAlias,
                                      child: InkWell(
                                          key: ValueKey(
                                              'schedule-calendar-day-${DateFormat('yyyy-MM-dd').format(day)}'),
                                          focusNode: node,
                                          onTap: () => widget.onSelected(day),
                                          onFocusChange: (focused) {
                                            if (focused &&
                                                node.context != null) {
                                              Scrollable.ensureVisible(
                                                  node.context!,
                                                  alignmentPolicy:
                                                      ScrollPositionAlignmentPolicy
                                                          .keepVisibleAtEnd);
                                            }
                                          },
                                          child: Semantics(
                                              label: '$label · $detail',
                                              button: true,
                                              selected: active,
                                              excludeSemantics: true,
                                              child: Padding(
                                                  padding: EdgeInsets.all(
                                                      _month ? 5 : 8),
                                                  child: Column(
                                                      crossAxisAlignment:
                                                          CrossAxisAlignment
                                                              .start,
                                                      children: [
                                                        Text(
                                                            _month
                                                                ? '${day.day}'
                                                                : '${day == widget.today ? 'Today · ' : ''}${DateFormat('EEE d MMM').format(day)}',
                                                            maxLines: 1,
                                                            overflow:
                                                                TextOverflow
                                                                    .ellipsis,
                                                            style: TextStyle(
                                                                fontSize: 12,
                                                                fontWeight:
                                                                    FontWeight
                                                                        .w600,
                                                                color: node
                                                                        .hasFocus
                                                                    ? colors
                                                                        .onPrimaryContainer
                                                                    : day == widget.today ||
                                                                            active
                                                                        ? colors
                                                                            .primary
                                                                        : colors
                                                                            .onSurface)),
                                                        const SizedBox(
                                                            height: 4),
                                                        Text(
                                                            summary == null
                                                                ? (_month
                                                                    ? '—'
                                                                    : 'Open to load fixtures')
                                                                : _month
                                                                    ? '${summary.incomplete ? '~' : ''}$total'
                                                                    : '$total fixtures${summary.incomplete ? ' · partial' : ''}',
                                                            maxLines: 1,
                                                            overflow:
                                                                TextOverflow
                                                                    .ellipsis,
                                                            style: TextStyle(
                                                                fontSize: _month
                                                                    ? 11
                                                                    : 12,
                                                                color: node
                                                                        .hasFocus
                                                                    ? colors
                                                                        .onPrimaryContainer
                                                                    : colors
                                                                        .onSurfaceVariant)),
                                                        const Spacer(),
                                                        if (sports.isNotEmpty)
                                                          _month
                                                              ? Row(children: [
                                                                  for (final e
                                                                      in sports
                                                                          .take(
                                                                              2))
                                                                    Expanded(
                                                                        child: Icon(
                                                                            sportIcon(e
                                                                                .key),
                                                                            size:
                                                                                12,
                                                                            color: node.hasFocus
                                                                                ? colors.onPrimaryContainer
                                                                                : colors.onSurfaceVariant))
                                                                ])
                                                              : Text(
                                                                  sports
                                                                      .take(3)
                                                                      .map((e) =>
                                                                          '${shortSportLabel(e.key)} ${e.value}')
                                                                      .join(
                                                                          ' · '),
                                                                  maxLines: 1,
                                                                  overflow:
                                                                      TextOverflow
                                                                          .ellipsis,
                                                                  style: TextStyle(
                                                                      fontSize:
                                                                          10,
                                                                      color: node.hasFocus
                                                                          ? colors
                                                                              .onPrimaryContainer
                                                                          : colors
                                                                              .onSurfaceVariant)),
                                                      ]))))))));
                    })),
          ]);
    });
  }
}
