import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../models/sports.dart';
import '../utils/sports_detail_presentation.dart';
import '../utils/sports_fixture_presentation.dart';
import '../utils/time_format.dart';
import 'sports_widgets.dart';

/// Flat surfaces share the Sports palette without adding animated layers.
class SportsDetailSurface extends StatelessWidget {
  const SportsDetailSurface(
      {super.key,
      required this.child,
      this.accent = false,
      this.padding = const EdgeInsets.all(10)});
  final Widget child;
  final bool accent;
  final EdgeInsetsGeometry padding;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
        padding: padding,
        decoration: BoxDecoration(
          color: (accent ? colors.primary : colors.onSurface)
              .withValues(alpha: .035),
          border: Border.all(
              color: (accent ? colors.primary : colors.outlineVariant)
                  .withValues(alpha: accent ? .2 : .3)),
          borderRadius: BorderRadius.circular(5),
        ),
        child: child);
  }
}

class SportsDetailHeading extends StatelessWidget {
  const SportsDetailHeading(this.title, {super.key, this.detail});
  final String title;
  final String? detail;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
        padding: const EdgeInsets.only(top: 12, bottom: 7),
        child: Row(children: [
          Container(
              width: 2,
              height: 12,
              color: colors.primary.withValues(alpha: .7)),
          const SizedBox(width: 7),
          Expanded(
              child: Text(title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: colors.onSurface))),
          if (detail != null)
            Flexible(
                child: Text(detail!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.end,
                    style: TextStyle(
                        fontSize: 10, color: colors.onSurfaceVariant))),
        ]));
  }
}

/// Small, bounded record groups; long rosters use SportsDetailTable instead.
class SportsDetailMetrics extends StatelessWidget {
  const SportsDetailMetrics(
      {super.key, required this.entries, this.primary = false});
  final List<(String, String)> entries;
  final bool primary;
  @override
  Widget build(BuildContext context) {
    if (entries.isEmpty) return const SizedBox.shrink();
    final colors = Theme.of(context).colorScheme;
    return LayoutBuilder(builder: (context, box) {
      final scale = MediaQuery.textScalerOf(context).scale(1);
      final columns = (box.maxWidth / (112 * scale))
          .floor()
          .clamp(1, math.min(4, entries.length));
      final width = (box.maxWidth - (columns - 1) * 6) / columns;
      return Wrap(spacing: 6, runSpacing: 6, children: [
        for (final (label, value) in entries)
          SizedBox(
              width: width,
              child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
                  decoration: BoxDecoration(
                      color: colors.onSurface.withValues(alpha: .035),
                      borderRadius: BorderRadius.circular(4),
                      border: Border(
                          left: BorderSide(
                              width: 2,
                              color: primary
                                  ? colors.primary.withValues(alpha: .55)
                                  : colors.outlineVariant
                                      .withValues(alpha: .5)))),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(label,
                            style: TextStyle(
                                fontSize: 10.5,
                                height: 1.2,
                                color: colors.onSurfaceVariant)),
                        const SizedBox(height: 5),
                        Text(value,
                            style: TextStyle(
                                fontSize: primary ? 22 : 16,
                                height: 1.1,
                                fontWeight: FontWeight.w600,
                                color:
                                    primary ? colors.primary : colors.onSurface,
                                fontFeatures: const [
                                  FontFeature.tabularFigures()
                                ])),
                      ]))),
      ]);
    });
  }
}

/// Numeric bars indicate share, never which side performed better. Compound
/// scores, ranks, missing values and negative statistics remain text only.
class SportsDetailComparisonRow extends StatelessWidget {
  const SportsDetailComparisonRow(this.label, this.values,
      {super.key, this.heading = false});
  final String label;
  final List<String> values;
  final bool heading;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final share = heading ? null : sportsComparisonShare(values);
    Widget number(int index) => Expanded(
        flex: 2,
        child: Text(
            index < values.length && values[index].isNotEmpty
                ? values[index]
                : '–',
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                fontSize: heading ? 10 : 14,
                height: 1.15,
                fontWeight: heading ? FontWeight.w500 : FontWeight.w600,
                color: heading ? colors.onSurfaceVariant : colors.onSurface,
                fontFeatures: const [FontFeature.tabularFigures()])));
    return Column(mainAxisSize: MainAxisSize.min, children: [
      Row(children: [
        number(0),
        Expanded(
            flex: 5,
            child: Text(label,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: heading ? 10 : 11,
                    height: 1.2,
                    color: colors.onSurfaceVariant))),
        number(1)
      ]),
      if (share != null) ...[
        const SizedBox(height: 5),
        ExcludeSemantics(
            child: Row(children: [
          Expanded(
              child: Align(
                  alignment: Alignment.centerRight,
                  child: FractionallySizedBox(
                      widthFactor: share,
                      child: ColoredBox(
                          color: colors.primary.withValues(alpha: .65),
                          child: const SizedBox(height: 2))))),
          const SizedBox(width: 3),
          Expanded(
              child: Align(
                  alignment: Alignment.centerLeft,
                  child: FractionallySizedBox(
                      widthFactor: 1 - share,
                      child: ColoredBox(
                          color: colors.onSurfaceVariant.withValues(alpha: .5),
                          child: const SizedBox(height: 2))))),
        ])),
      ],
    ]);
  }
}

/// Uses the fixture snapshot and cached logos, with no detail/score requests.
class SportsDetailFixtureRow extends StatelessWidget {
  const SportsDetailFixtureRow(
      {super.key, required this.game, required this.hideScores});
  final SportsGame game;
  final bool hideScores;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final date = game.start.toLocal();
    final scored = !hideScores && game.state != GameState.pre;
    Widget side(SportsTeam team) => Row(children: [
          SportsLogo(
              url: team.logoUrl,
              size: 18,
              fallback: team.abbreviation,
              animate: false),
          const SizedBox(width: 6),
          Expanded(
              child: Text(team.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 11.5, fontWeight: FontWeight.w500))),
          if (scored && team.score != null)
            Padding(
                padding: const EdgeInsets.only(left: 6),
                child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 65),
                    child: Text(team.score!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            fontFeatures: [FontFeature.tabularFigures()])))),
        ]);
    return Row(children: [
      SizedBox(
          width: 48,
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            Text(DateFormat('d').format(date),
                style: TextStyle(
                    fontSize: 19,
                    height: 1.1,
                    fontWeight: FontWeight.w600,
                    color: colors.primary)),
            Text(DateFormat('EEE MMM').format(date),
                maxLines: 1,
                style:
                    TextStyle(fontSize: 8.5, color: colors.onSurfaceVariant)),
            const SizedBox(height: 3),
            Text(
                sportsFixtureHasUnknownTime(game)
                    ? 'TBD'
                    : TimeFormat.hm.format(date),
                style:
                    TextStyle(fontSize: 9.5, color: colors.onSurfaceVariant)),
          ])),
      Container(
          width: 1,
          height: 36,
          margin: const EdgeInsets.symmetric(horizontal: 9),
          color: colors.outlineVariant.withValues(alpha: .45)),
      Expanded(
          child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
            if (game.league.isField)
              Text(game.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 12, fontWeight: FontWeight.w500))
            else ...[
              side(game.first),
              const SizedBox(height: 3),
              side(game.second)
            ],
            if (!hideScores && game.state != GameState.pre) ...[
              const SizedBox(height: 2),
              Text(sportsFixtureStatus(game),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style:
                      TextStyle(fontSize: 9, color: colors.onSurfaceVariant)),
            ],
          ])),
      Icon(Icons.chevron_right, size: 16, color: colors.onSurfaceVariant),
    ]);
  }
}

/// A bounded preview of supplied period scores. Opening it exposes every column
/// in the regular, remotely navigable table without fetching another snapshot.
class SportsDetailPeriodSummary extends StatelessWidget {
  const SportsDetailPeriodSummary(
      {super.key,
      required this.title,
      required this.columns,
      required this.rows,
      required this.onOpen});
  final String title;
  final List<String> columns;
  final List<(String, List<String>)> rows;
  final VoidCallback onOpen;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return TextButton(
        style: TextButton.styleFrom(
            animationDuration: Duration.zero,
            foregroundColor: colors.onSurface,
            padding: const EdgeInsets.all(10),
            backgroundColor: colors.onSurface.withValues(alpha: .025),
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(5))),
        onPressed: onOpen,
        child: LayoutBuilder(builder: (context, box) {
          final scale = MediaQuery.textScalerOf(context).scale(1);
          final count = math.min(columns.length,
              math.max(1, ((box.maxWidth / scale - 70) / 35).floor()));
          Widget line(String label, List<String> values,
                  {bool heading = false}) =>
              Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(children: [
                    SizedBox(
                        width: box.maxWidth * .25,
                        child: Text(label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 10.5,
                                color: colors.onSurfaceVariant))),
                    for (var i = 0; i < count; i++)
                      Expanded(
                          child: Text(i < values.length ? values[i] : '–',
                              textAlign: TextAlign.center,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: heading ? 10 : 12,
                                  fontWeight: heading
                                      ? FontWeight.w400
                                      : FontWeight.w600,
                                  color: heading
                                      ? colors.onSurfaceVariant
                                      : colors.onSurface,
                                  fontFeatures: const [
                                    FontFeature.tabularFigures()
                                  ]))),
                  ]));
          return Column(children: [
            Row(children: [
              Expanded(
                  child: Text(title,
                      style: const TextStyle(
                          fontSize: 11, fontWeight: FontWeight.w600))),
              Text('View all',
                  style: TextStyle(fontSize: 10, color: colors.primary)),
              const SizedBox(width: 3),
              Icon(Icons.chevron_right, size: 15, color: colors.primary)
            ]),
            const SizedBox(height: 5),
            line('', columns, heading: true),
            for (final (label, values) in rows.take(2)) line(label, values),
          ]);
        }));
  }
}
