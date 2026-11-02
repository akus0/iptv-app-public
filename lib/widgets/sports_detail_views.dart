import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../models/sports.dart';
import '../models/sports_details.dart';
import '../services/app_preferences.dart';
import '../services/sports_standings_service.dart';
import '../utils/sports_detail_presentation.dart';
import '../utils/sports_fixture_presentation.dart';
import '../utils/time_format.dart';
import 'compact_choice_list.dart';
import 'sports_header_controls.dart';
import 'sports_widgets.dart';
import 'standings_team_tile.dart';

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
    final record = team == null
        ? null
        : sections.where((s) => s.kind == SportsDetailKind.record).firstOrNull;
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
    final links = <Widget>[
      if (onRecord != null)
        _DetailLink('Standings breakdown', 'All available league statistics',
            Icons.table_chart_outlined, onRecord!),
      if (onFixtures != null)
        _DetailLink('Upcoming fixtures', 'Next 30 days',
            Icons.event_note_outlined, onFixtures!),
      for (final (i, section) in sections.indexed)
        _DetailLink(
            section.kind == SportsDetailKind.comparison &&
                    section.title != 'Pregame comparison'
                ? profile.statistics
                : section.title,
            sportsPlayerSection(section)
                ? '${section.rows.length} players'
                : '${section.rows.length} ${section.kind == SportsDetailKind.record ? 'records' : 'entries'}',
            sportsPlayerSection(section)
                ? Icons.groups_outlined
                : Icons.table_rows_outlined,
            () => onSection(i)),
    ];
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
          if (team != null)
            _TeamOverview(
                team: team!,
                league: league,
                standing: standing,
                record: record),
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
          if (g?.situation case final situation?
              when g!.state != GameState.pre) ...[
            if (situation.text?.isNotEmpty == true ||
                situation.lastPlay?.isNotEmpty == true ||
                situation.possessionTeamId != null) ...[
              heading('Game situation'),
              if (situation.text?.isNotEmpty == true)
                _InformationLine(situation.redZone ? 'Red zone' : 'In play',
                    situation.text!),
              if (situation.possessionTeamId != null)
                for (final side in [g.home, g.away])
                  if (side.id == situation.possessionTeamId)
                    _InformationLine('Possession', side.shortName),
              if (situation.lastPlay?.isNotEmpty == true)
                _InformationLine('Last play', situation.lastPlay!),
            ],
          ],
          if (g != null && g.leaders.isNotEmpty) ...[
            heading(g.state == GameState.pre
                ? 'Season leaders'
                : 'Scoreboard leaders'),
            for (final leader in g.leaders
                .where((l) =>
                    l.teamId == null ||
                    l.teamId == g.home.id ||
                    l.teamId == g.away.id)
                .take(12))
              Padding(
                  padding: const EdgeInsets.symmetric(vertical: 5),
                  child: Row(children: [
                    SizedBox(
                        width: 44,
                        child: Text(leader.stat,
                            style: TextStyle(
                                fontSize: 10.5,
                                color: colors.primary,
                                fontWeight: FontWeight.w600))),
                    Expanded(
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                          Text(leader.name,
                              style: const TextStyle(
                                  fontSize: 12, fontWeight: FontWeight.w600)),
                          Text(
                              [
                                if (leader.teamId == g.home.id)
                                  g.home.shortName
                                else if (leader.teamId == g.away.id)
                                  g.away.shortName,
                                if (leader.position != null) leader.position!
                              ].join(' · '),
                              style: TextStyle(
                                  fontSize: 10,
                                  color: colors.onSurfaceVariant)),
                        ])),
                    const SizedBox(width: 8),
                    Flexible(
                        child: Text(leader.value,
                            textAlign: TextAlign.end,
                            style: const TextStyle(
                                fontSize: 12,
                                fontFeatures: [FontFeature.tabularFigures()]))),
                  ])),
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
          if (links.isNotEmpty) ...[
            heading('Explore'),
            LayoutBuilder(builder: (context, box) {
              final columns = box.maxWidth >=
                      400 * MediaQuery.textScalerOf(context).scale(1)
                  ? 2
                  : 1;
              final width = (box.maxWidth - (columns - 1) * 6) / columns;
              return Wrap(spacing: 6, runSpacing: 6, children: [
                for (final link in links) SizedBox(width: width, child: link),
              ]);
            }),
          ],
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
            fallback: team.abbreviation.isEmpty ? team.name : team.abbreviation,
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

/// Uses only the records already loaded for this team. The sport's existing
/// standings profile chooses useful statistics without interpreting scores.
class _TeamOverview extends StatelessWidget {
  const _TeamOverview(
      {required this.team, required this.league, this.standing, this.record});
  final SportsTeam team;
  final SportsLeague league;
  final StandingTeam? standing;
  final SportsDetailSection? record;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final records = [
      for (final row in record?.rows.take(4) ?? const <SportsDetailRow>[])
        if (row.values.any((value) => value.trim().isNotEmpty))
          (row.label, row.values.join(' · ')),
    ];
    if (records.isEmpty && team.record?.isNotEmpty == true) {
      records.add(('Overall', team.record!));
    }
    if (standing?.position case final position?) {
      if (!records.any((entry) =>
          RegExp(r'position|rank|seed', caseSensitive: false)
              .hasMatch(entry.$1))) {
        records.insert(0, ('Position', '#$position'));
      }
    }
    final stats = standing?.stats ?? const <String, String>{};
    final columns = visibleStandingsColumns(stats.keys.toSet(), 1000,
        sport: league.espnPath.split('/').first, leagueId: league.id)
      ..sort((a, b) => a.priority.compareTo(b.priority));
    final metrics = [
      for (final column in columns.take(4))
        if (stats[column.key]?.trim().isNotEmpty == true)
          (column.description, standingColumnValue(standing!, column)),
    ];
    if (records.isEmpty && metrics.isEmpty) {
      return const SizedBox.shrink();
    }
    Widget values(List<(String, String)> entries, {required bool primary}) =>
        LayoutBuilder(builder: (context, box) {
          final scale = MediaQuery.textScalerOf(context).scale(1);
          final count = (box.maxWidth / (110 * scale))
              .floor()
              .clamp(1, math.min(4, entries.length));
          final width = (box.maxWidth - (count - 1) * 8) / count;
          return Wrap(spacing: 8, runSpacing: 10, children: [
            for (final (label, value) in entries)
              SizedBox(
                  width: width,
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Tooltip(
                            message: value,
                            child: Text(value,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    fontSize: primary ? 23 : 16,
                                    height: 1.15,
                                    color: primary ? colors.primary : null,
                                    fontWeight: FontWeight.w600,
                                    fontFeatures: const [
                                      FontFeature.tabularFigures()
                                    ]))),
                        const SizedBox(height: 4),
                        Text(label,
                            style: TextStyle(
                                fontSize: 10.5,
                                height: 1.2,
                                color: colors.onSurfaceVariant)),
                      ])),
          ]);
        });
    return Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
            color: colors.primary.withValues(alpha: .045),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: colors.primary.withValues(alpha: .16))),
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Icon(Icons.bar_chart_rounded, size: 15, color: colors.primary),
            const SizedBox(width: 6),
            Text('Team record',
                style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: colors.onSurfaceVariant)),
          ]),
          const SizedBox(height: 10),
          if (records.isNotEmpty) values(records, primary: true),
          if (records.isNotEmpty && metrics.isNotEmpty)
            Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Divider(
                    height: 1,
                    color: colors.outlineVariant.withValues(alpha: .4))),
          if (metrics.isNotEmpty) values(metrics, primary: records.isEmpty),
        ]));
  }
}

class _DetailLink extends StatelessWidget {
  const _DetailLink(this.title, this.subtitle, this.icon, this.action);
  final String title, subtitle;
  final IconData icon;
  final VoidCallback action;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return TextButton(
        style: sportsPopupButtonStyle(context).copyWith(
            padding: const WidgetStatePropertyAll(EdgeInsets.all(10)),
            backgroundColor: WidgetStateProperty.resolveWith((states) =>
                states.contains(WidgetState.focused) ||
                        states.contains(WidgetState.pressed)
                    ? colors.primary.withValues(alpha: .16)
                    : colors.onSurface.withValues(alpha: .035))),
        onPressed: action,
        child: Row(children: [
          Icon(icon, size: 19),
          const SizedBox(width: 10),
          Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                Text(title,
                    style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                        color: colors.onSurface)),
                const SizedBox(height: 2),
                Text(subtitle,
                    style: TextStyle(
                        fontSize: 10, color: colors.onSurfaceVariant)),
              ])),
          const SizedBox(width: 6),
          Icon(Icons.chevron_right, size: 16, color: colors.onSurfaceVariant),
        ]));
  }
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
          DecoratedBox(
              decoration: BoxDecoration(
                  color: colors.surfaceContainerHighest.withValues(alpha: .28),
                  border: Border(
                      bottom: BorderSide(
                          color:
                              colors.outlineVariant.withValues(alpha: .45)))),
              child: Padding(
                  padding: EdgeInsets.fromLTRB(9, 8, comparison ? 9 : 27, 6),
                  child: comparison
                      ? comparisonRow('Statistic', section.columns,
                          heading: true)
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
                        ]))),
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
                  showNavigation: tv,
                  rowHeight: (tv
                          ? 40
                          : compactSportsControls(context)
                              ? 44
                              : 52) *
                      scale,
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
                      onTap: () => showSportsDialog<void>(
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
