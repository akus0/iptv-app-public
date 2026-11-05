import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter/services.dart';
import 'package:intl/intl.dart' show DateFormat;
import '../utils/sports_calendar.dart';
import 'sports_toolbar_navigation.dart';

/// Selecting a date filters the loaded window; it never loads another feed.
class SportsScheduleDays extends StatefulWidget {
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
      this.dense = false,
      this.entryFocus});
  final DateTime from, today;
  final FocusNode? entryFocus;
  final int days;
  final bool showAll, showCounts, compact, dense;
  final Map<DateTime, int> counts;
  final DateTime? selected;
  final ValueChanged<DateTime?> onSelected;
  @override
  State<SportsScheduleDays> createState() => _SportsScheduleDaysState();
}

class _SportsScheduleDaysState extends State<SportsScheduleDays> {
  final _scroll = ScrollController();
  final _nodes = <int, FocusNode>{};
  int _focused = 0, _focusRequest = 0;
  double _extent = 64;
  int get _count => widget.days + (widget.showAll ? 1 : 0);
  int get _selectedIndex => widget.selected == null
      ? 0
      : sportsCalendarDayOffset(widget.from, widget.selected!) +
          (widget.showAll ? 1 : 0);
  FocusNode _node(int index) => index == 0 && widget.entryFocus != null
      ? widget.entryFocus!
      : _nodes.putIfAbsent(
          index, () => FocusNode(debugLabel: 'schedule-date-$index'));

  void _reveal(int index, {bool focus = false}) {
    if (index < 0 || index >= _count || !_scroll.hasClients) return;
    final position = _scroll.position;
    final start = index * _extent, end = start + _extent;
    final offset = start < position.pixels
        ? start
        : end > position.pixels + position.viewportDimension
            ? end - position.viewportDimension
            : position.pixels;
    if (offset != position.pixels) {
      _scroll.jumpTo(offset.clamp(0.0, position.maxScrollExtent));
    }
    if (!focus) return;
    _focused = index;
    final request = ++_focusRequest;
    void apply() {
      if (!mounted || request != _focusRequest) return;
      final node = _node(index);
      if (sportsFocusAttached(node)) node.requestFocus();
    }

    if (sportsFocusAttached(_node(index))) {
      apply();
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) => apply());
    }
  }

  void _revealSelected() => WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _reveal(_selectedIndex);
      });
  @override
  void initState() {
    super.initState();
    _revealSelected();
  }

  @override
  void didUpdateWidget(SportsScheduleDays oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selected != widget.selected ||
        oldWidget.from != widget.from ||
        oldWidget.days != widget.days ||
        oldWidget.showAll != widget.showAll) {
      _revealSelected();
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
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final scale = MediaQuery.textScalerOf(context);
    // Fixed extents let a remote jump to an unmounted day without laying out
    // the intervening dates. Size for the longest label, including larger text.
    final labelStyle =
        (Theme.of(context).textTheme.labelLarge ?? const TextStyle())
            .copyWith(fontSize: 10.5, fontWeight: FontWeight.w600, height: 1.2);
    final metrics = _dayMetrics(scale, Directionality.of(context),
        Localizations.localeOf(context).toString(), labelStyle);
    _extent = metrics.width + 4;
    final minimum = widget.compact && !widget.showCounts
        ? 34.0
        : widget.dense
            ? 36.0
            : 48.0;
    final height = math.max(
        widget.dense ? minimum : 48.0,
        metrics.labelHeight +
            (widget.showCounts ? metrics.countHeight : 0) +
            8);
    return SizedBox(
        height: height,
        child: Focus(
            canRequestFocus: false,
            onKeyEvent: (_, event) {
              if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
                return KeyEventResult.ignored;
              }
              final delta = event.logicalKey == LogicalKeyboardKey.arrowRight
                  ? 1
                  : event.logicalKey == LogicalKeyboardKey.arrowLeft
                      ? -1
                      : 0;
              final next = _focused + delta;
              if (delta == 0 || next < 0 || next >= _count) {
                return KeyEventResult.ignored;
              }
              _reveal(next, focus: true);
              return KeyEventResult.handled;
            },
            child: ListView.builder(
                controller: _scroll,
                scrollDirection: Axis.horizontal,
                padding: EdgeInsets.zero,
                itemExtent: _extent,
                scrollCacheExtent: ScrollCacheExtent.pixels(_extent),
                itemCount: _count,
                addAutomaticKeepAlives: false,
                itemBuilder: (context, index) {
                  final date = widget.showAll && index == 0
                      ? null
                      : sportsCalendarDay(
                          widget.from, index - (widget.showAll ? 1 : 0));
                  final active = widget.selected == date;
                  final count = date == null
                      ? widget.counts.values.fold(0, (a, b) => a + b)
                      : widget.counts[date] ?? 0;
                  return Padding(
                      padding: const EdgeInsets.only(right: 4),
                      child: TextButton(
                          key: ValueKey(date == null
                              ? 'schedule-day-all'
                              : 'schedule-day-${DateFormat('yyyy-MM-dd').format(date)}'),
                          focusNode: _node(index),
                          onFocusChange: (focused) {
                            if (focused) _focused = index;
                          },
                          onPressed: () => widget.onSelected(date),
                          style: TextButton.styleFrom(
                              minimumSize: Size(54, minimum),
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 4),
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(4),
                                  side: BorderSide(
                                      color: active
                                          ? colors.primary.withValues(alpha: .6)
                                          : Colors.transparent)),
                              foregroundColor: active
                                  ? colors.primary
                                  : colors.onSurfaceVariant,
                              backgroundColor: active
                                  ? colors.primary.withValues(alpha: .10)
                                  : colors.onSurface.withValues(alpha: .025)),
                          child:
                              Column(mainAxisSize: MainAxisSize.min, children: [
                            Text(
                                date == null
                                    ? 'All dates'
                                    : date == widget.today
                                        ? 'Today'
                                        : DateFormat('EEE d').format(date),
                                maxLines: 1,
                                style: labelStyle.copyWith(
                                    color: active
                                        ? colors.primary
                                        : colors.onSurfaceVariant)),
                            if (widget.showCounts)
                              Text('$count',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: labelStyle.copyWith(
                                      fontSize: 10,
                                      color: colors.onSurfaceVariant,
                                      fontFeatures: const [
                                        FontFeature.tabularFigures()
                                      ]))
                          ])));
                })));
  }
}

typedef _DayMetrics = ({double width, double labelHeight, double countHeight});
final _metrics =
    <(TextScaler, TextDirection, String, TextStyle), _DayMetrics>{};
_DayMetrics _dayMetrics(TextScaler scale, TextDirection direction,
    String locale, TextStyle labelStyle) {
  final key = (scale, direction, locale, labelStyle);
  if (_metrics[key] case final cached?) return cached;
  final painter = TextPainter(textDirection: direction, textScaler: scale);
  var width = 54.0, labelHeight = 0.0;
  for (final label in [
    'Today',
    'All dates',
    for (var i = 0; i < 7; i++)
      '${DateFormat('EEE', locale).format(DateTime(2024, 1, 1 + i))} 88'
  ]) {
    painter.text = TextSpan(text: label, style: labelStyle);
    painter.layout();
    width = math.max(width, painter.width.ceilToDouble() + 16);
    labelHeight = math.max(labelHeight, painter.height.ceilToDouble());
  }
  painter.text =
      TextSpan(text: '9999', style: labelStyle.copyWith(fontSize: 10));
  painter.layout();
  final result = (
    width: width,
    labelHeight: labelHeight,
    countHeight: painter.height.ceilToDouble()
  );
  painter.dispose();
  if (_metrics.length >= 8) _metrics.remove(_metrics.keys.first);
  return _metrics[key] = result;
}
