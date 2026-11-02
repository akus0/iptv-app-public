import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../models/sports.dart';
import '../models/sports_details.dart';
import '../services/app_preferences.dart';
import '../services/sports_standings_service.dart';
import '../utils/guarded_dialog.dart';
import '../utils/sports_detail_presentation.dart';
import '../utils/sports_fixture_presentation.dart';
import '../utils/time_format.dart';
import 'compact_choice_list.dart';
import 'sports_header_controls.dart';
import 'sports_widgets.dart';

class SportsDetailSummary extends StatelessWidget {
  const SportsDetailSummary(
      {super.key,
      required this.league,
      required this.sections,
      required this.onSection,
      this.game,
      this.team,
      this.standing,
      this.data,
      this.onFixtures,
      this.onRecord});
  final SportsLeague league;
  final SportsGame? game;
  final SportsTeam? team;
  final StandingTeam? standing;
  final SportsDetails? data;
  final List<SportsDetailSection> sections;
  final ValueChanged<int> onSection;
  final VoidCallback? onFixtures, onRecord;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final profile = sportsDetailProfile(league);
    final g = game;
    final snapshot =
        data != null && !data!.unsupported && (!data!.failed || data!.stale);
    final comparison = sections
        .where((s) => s.kind == SportsDetailKind.comparison)
        .firstOrNull;
    final featured = comparison == null
        ? const <SportsDetailRow>[]
        : sportsKeyStatistics(league, comparison);
    final information = sections
        .where((s) => s.kind == SportsDetailKind.information)
        .firstOrNull;
    Widget heading(String text) => Padding(
        padding: const EdgeInsets.only(top: 12, bottom: 6),
        child: Text(text,
            style: TextStyle(
                fontSize: 10.5,
                fontWeight: FontWeight.w600,
                color: colors.onSurfaceVariant)));
    Widget link(String title, IconData icon, VoidCallback action) => Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: TextButton(
            style: sportsPopupButtonStyle(context),
            onPressed: action,
            child: Row(children: [
              Icon(icon, size: 15),
              const SizedBox(width: 8),
              Expanded(
                  child: Text(title, style: const TextStyle(fontSize: 11.5))),
              const Icon(Icons.chevron_right, size: 16)
            ])));
    return ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          if (g != null) ...[
            Row(children: [
              Expanded(
                  child: Text(
                      '${DateFormat('EEE d MMM').format(g.start.toLocal())} · ${sportsFixtureHasUnknownTime(g) ? 'TBD' : TimeFormat.hm.format(g.start.toLocal())}',
                      style: TextStyle(
                          fontSize: 11, color: colors.onSurfaceVariant))),
              Expanded(
                  child: Text(
                      snapshot && data!.subtitle.isNotEmpty
                          ? data!.subtitle
                          : sportsFixtureStatus(g),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.end,
                      style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: colors.primary)))
            ]),
            const SizedBox(height: 8),
            if (!league.isField) ...[
              DecoratedBox(
                  decoration: BoxDecoration(
                      color: colors.onSurface.withValues(alpha: .025),
                      borderRadius: BorderRadius.circular(5),
                      border: Border.all(
                          color: colors.outlineVariant.withValues(alpha: .4))),
                  child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 4),
                      child: Column(children: [
                        for (final side in [g.first, g.second])
                          _IdentityLine(
                              team: side,
                              score: snapshot
                                  ? data!.scores[side.id]
                                  : g.state == GameState.pre
                                      ? null
                                      : side.score),
                      ]))),
              if (snapshot && data!.scores.isEmpty && data!.scoreLine != null)
                Text(data!.scoreLine!,
                    style: const TextStyle(
                        fontSize: 12, fontWeight: FontWeight.w600)),
            ] else
              Text(g.event?.title ?? g.title,
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w600)),
            if (g.event?.session case final session?)
              Text(session,
                  style:
                      TextStyle(fontSize: 11, color: colors.onSurfaceVariant)),
          ],
          if (team != null) ...[
            _IdentityLine(team: team!),
            if (standing != null)
              Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Wrap(spacing: 8, runSpacing: 6, children: [
                    if (standing!.position != null)
                      _Metric(
                          label: 'Position', value: '#${standing!.position}'),
                    for (final key in [
                      'wins',
                      'ties',
                      'losses',
                      'points',
                      'winPercent'
                    ])
                      if (standing!.stats[key] case final value?)
                        _Metric(
                            label: const {
                              'wins': 'Won',
                              'ties': 'Drawn',
                              'losses': 'Lost',
                              'points': 'Points',
                              'winPercent': 'Win %'
                            }[key]!,
                            value: value),
                  ])),
          ],
          if (featured.isNotEmpty) ...[
            heading(comparison!.title == 'Pregame comparison'
                ? 'Season comparison'
                : 'At a glance'),
            DecoratedBox(
                decoration: BoxDecoration(
                    color: colors.onSurface.withValues(alpha: .025),
                    borderRadius: BorderRadius.circular(5),
                    border: Border.all(
                        color: colors.outlineVariant.withValues(alpha: .4))),
                child: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    child: Column(children: [
                      _SummaryComparisonRow('', comparison.columns,
                          heading: true),
                      for (final row in featured)
                        _SummaryComparisonRow(row.label, row.values),
                    ]))),
          ],
          if (g?.event?.leaders.isNotEmpty == true) ...[
            heading(league.kind == SportsKind.golf
                ? 'Leaderboard'
                : g!.state == GameState.post
                    ? 'Result'
                    : 'Running order'),
            for (final leader in g!.event!.leaders)
              Padding(
                  padding: const EdgeInsets.symmetric(vertical: 5),
                  child: Row(children: [
                    SizedBox(
                        width: 28,
                        child: Text(leader.position,
                            style: TextStyle(
                                fontSize: 11, color: colors.primary))),
                    Expanded(
                        child: Text(leader.name,
                            style: const TextStyle(fontSize: 12))),
                    if (leader.value != null)
                      Text(leader.value!,
                          style: const TextStyle(
                              fontSize: 12, fontWeight: FontWeight.w600))
                  ])),
          ],
          if (information != null || g?.event?.venue != null) ...[
            heading('Event information'),
            if (information != null)
              for (final row in information.rows.where((r) =>
                  const ['Venue', 'Location', 'Attendance'].contains(r.label)))
                _InformationLine(row.label, row.values.join(' · ')),
            if (information == null && g?.event?.venue != null)
              _InformationLine('Venue', g!.event!.venue!),
          ],
          if (g?.broadcasts.isNotEmpty == true)
            _InformationLine('TV listings', g!.broadcasts.take(3).join(' · ')),
          if (sections.isNotEmpty || onFixtures != null || onRecord != null)
            heading('More details'),
          if (onRecord != null)
            link('League record', Icons.table_chart_outlined, onRecord!),
          if (onFixtures != null)
            link('Upcoming fixtures', Icons.event_note_outlined, onFixtures!),
          for (final (i, section) in sections.indexed)
            link(
                section.kind == SportsDetailKind.comparison &&
                        section.title != 'Pregame comparison'
                    ? profile.statistics
                    : section.title,
                sportsPlayerSection(section)
                    ? Icons.groups_outlined
                    : Icons.table_rows_outlined,
                () => onSection(i)),
          if (g != null)
            Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text('Times are local · schedules can change',
                    style: TextStyle(
                        fontSize: 10, color: colors.onSurfaceVariant))),
        ]);
  }
}

class _SummaryComparisonRow extends StatelessWidget {
  const _SummaryComparisonRow(this.label, this.values, {this.heading = false});
  final String label;
  final List<String> values;
  final bool heading;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
        padding: EdgeInsets.symmetric(vertical: heading ? 3 : 7),
        child: Row(children: [
          Expanded(
              flex: 2,
              child: Text(values.firstOrNull ?? '–',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontSize: heading ? 10 : 13,
                      fontWeight: FontWeight.w600,
                      color:
                          heading ? colors.onSurfaceVariant : colors.onSurface,
                      fontFeatures: const [FontFeature.tabularFigures()]))),
          Expanded(
              flex: 5,
              child: Text(label,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style:
                      TextStyle(fontSize: 11, color: colors.onSurfaceVariant))),
          Expanded(
              flex: 2,
              child: Text(values.length > 1 ? values[1] : '–',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontSize: heading ? 10 : 13,
                      fontWeight: FontWeight.w600,
                      color:
                          heading ? colors.onSurfaceVariant : colors.onSurface,
                      fontFeatures: const [FontFeature.tabularFigures()]))),
        ]));
  }
}

class _IdentityLine extends StatelessWidget {
  const _IdentityLine({required this.team, this.score});
  final SportsTeam team;
  final String? score;
  @override
  Widget build(BuildContext context) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(children: [
        SportsLogo(
            url: team.logoUrl,
            size: 26,
            fallback: team.abbreviation,
            animate: false),
        const SizedBox(width: 8),
        Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(team.name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  fontSize: 13, fontWeight: FontWeight.w600, height: 1.15)),
          if (team.record?.isNotEmpty == true)
            Text(team.record!,
                style: TextStyle(
                    fontSize: 10,
                    color: Theme.of(context).colorScheme.onSurfaceVariant))
        ])),
        if (score?.isNotEmpty == true)
          Padding(
              padding: const EdgeInsets.only(left: 10),
              child: Text(score!,
                  style: const TextStyle(
                      fontSize: 21,
                      fontWeight: FontWeight.w700,
                      fontFeatures: [FontFeature.tabularFigures()]))),
      ]));
}

class _Metric extends StatelessWidget {
  const _Metric({required this.label, required this.value});
  final String label, value;
  @override
  Widget build(BuildContext context) => Container(
      constraints: const BoxConstraints(minWidth: 70, maxWidth: 210),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
          color:
              Theme.of(context).colorScheme.onSurface.withValues(alpha: .035),
          borderRadius: BorderRadius.circular(4)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(value,
            style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                fontFeatures: [FontFeature.tabularFigures()])),
        Text(label,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                fontSize: 10,
                color: Theme.of(context).colorScheme.onSurfaceVariant))
      ]));
}

class _InformationLine extends StatelessWidget {
  const _InformationLine(this.label, this.value);
  final String label, value;
  @override
  Widget build(BuildContext context) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(
            width: 76,
            child: Text(label,
                style: TextStyle(
                    fontSize: 10.5,
                    color: Theme.of(context).colorScheme.onSurfaceVariant))),
        Expanded(
            child: Text(value,
                style: const TextStyle(fontSize: 11.5, height: 1.25)))
      ]));
}

class SportsDetailTable extends StatelessWidget {
  const SportsDetailTable({super.key, required this.section});
  final SportsDetailSection section;
  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, box) {
        final colors = Theme.of(context).colorScheme;
        final tv = context.read<AppPreferences>().isTelevision;
        final scale = MediaQuery.textScalerOf(context).scale(12) / 12;
        final comparison = section.kind == SportsDetailKind.comparison;
        final periods = section.kind == SportsDetailKind.periods;
        final count = math.min(
            section.columns.length,
            math.max(
                1,
                ((box.maxWidth / scale - (periods ? 72 : 130)) /
                        (periods ? 28 : 48))
                    .floor()));
        final cellWidth =
            (box.maxWidth * (periods ? .80 : .56) / math.max(count, 1));
        Widget cells(List<String> values, {bool heading = false}) =>
            Row(mainAxisSize: MainAxisSize.min, children: [
              for (var i = 0; i < count; i++)
                SizedBox(
                    width: cellWidth,
                    child: Text(i < values.length ? values[i] : '–',
                        textAlign: TextAlign.center,
                        maxLines: heading ? 2 : 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: heading ? 10 : 11.5,
                            color: heading
                                ? colors.onSurfaceVariant
                                : colors.onSurface,
                            fontWeight:
                                heading ? FontWeight.w500 : FontWeight.w600,
                            fontFeatures: const [
                              FontFeature.tabularFigures()
                            ])))
            ]);
        Widget comparisonRow(String label, List<String> values,
                {bool heading = false}) =>
            Row(children: [
              Expanded(
                  flex: 2,
                  child: Text(values.firstOrNull ?? '–',
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: heading ? 10 : 12,
                          fontWeight:
                              heading ? FontWeight.w500 : FontWeight.w600,
                          color: heading
                              ? colors.onSurfaceVariant
                              : colors.onSurface))),
              Expanded(
                  flex: 5,
                  child: Text(label,
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: heading ? 10 : 11,
                          color: colors.onSurfaceVariant))),
              Expanded(
                  flex: 2,
                  child: Text(values.length > 1 ? values[1] : '–',
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: heading ? 10 : 12,
                          fontWeight:
                              heading ? FontWeight.w500 : FontWeight.w600,
                          color: heading
                              ? colors.onSurfaceVariant
                              : colors.onSurface))),
            ]);
        final labels = <String, int>{};
        for (final row in section.rows) {
          labels.update(row.id ?? row.label, (v) => v + 1, ifAbsent: () => 1);
        }
        return Column(children: [
          Padding(
              padding: EdgeInsets.fromLTRB(9, 8, comparison ? 9 : 27, 6),
              child: comparison
                  ? comparisonRow('Statistic', section.columns, heading: true)
                  : Row(children: [
                      Expanded(
                          child: Text(
                              sportsPlayerSection(section)
                                  ? 'Player'
                                  : periods
                                      ? 'Team'
                                      : 'Detail',
                              style: TextStyle(
                                  fontSize: 10,
                                  color: colors.onSurfaceVariant))),
                      cells(section.columns, heading: true)
                    ])),
          if (count < section.columns.length && !comparison)
            Align(
                alignment: Alignment.centerLeft,
                child: Text(
                    'Select a row for all ${section.columns.length} statistics',
                    style: TextStyle(
                        fontSize: 10, color: colors.onSurfaceVariant))),
          Expanded(
              child: CompactChoiceList(
                  polished: true,
                  striped: true,
                  rowHeight: (tv ? 40 : 52) * scale,
                  choices: [
                for (final (index, row) in section.rows.indexed)
                  CompactChoice(
                      id:
                          'detail-${row.id ?? row.label}${labels[row.id ?? row.label] == 1 ? '' : ':$index'}',
                      title: row.label,
                      subtitle: row.detail?.isEmpty == true ? null : row.detail,
                      trailing:
                          comparison || count == 0 ? null : cells(row.values),
                      content: comparison
                          ? comparisonRow(row.label, row.values)
                          : null,
                      onTap: () => showGuardedDialog<void>(
                          context: context,
                          builder: (context) => SportsCompactDialog(
                              title: row.label,
                              child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    if (row.detail?.isNotEmpty == true)
                                      Padding(
                                          padding:
                                              const EdgeInsets.only(bottom: 6),
                                          child: Text(row.detail!,
                                              style: const TextStyle(
                                                  fontSize: 11))),
                                    for (final (i, value) in row.values.indexed)
                                      _InformationLine(
                                          i < section.columns.length
                                              ? section.columns[i]
                                              : '',
                                          value),
                                  ]))))
              ])),
        ]);
      });
}
