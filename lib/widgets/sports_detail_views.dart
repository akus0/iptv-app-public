import 'dart:math' as math;
import 'sports_detail_components.dart';
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
    final periodsIndex =
        sections.indexWhere((s) => s.kind == SportsDetailKind.periods);
    final information = sections
        .where((s) => s.kind == SportsDetailKind.information)
        .firstOrNull;
    Widget heading(String text) => SportsDetailHeading(text);
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
              SportsDetailSurface(
                  accent: true,
                  child: Column(children: [
                    for (final (index, side)
                        in [g.first, g.second].indexed) ...[
                      if (index > 0)
                        Divider(
                            height: 9,
                            color: colors.outlineVariant.withValues(alpha: .3)),
                      _IdentityLine(
                          team: side,
                          score: snapshot
                              ? data!.scores[side.id]
                              : g.state == GameState.pre
                                  ? null
                                  : side.score),
                    ],
                  ])),
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
          if (periodsIndex >= 0) ...[
            const SizedBox(height: 8),
            SportsDetailPeriodSummary(
                title: profile.periods,
                columns: sections[periodsIndex].columns,
                rows: [
                  for (final row in sections[periodsIndex].rows.take(2))
                    (row.label, row.values)
                ],
                onOpen: () => onSection(periodsIndex)),
          ],
          if (featured.isNotEmpty) ...[
            heading(comparison!.title == 'Pregame comparison'
                ? 'Season comparison'
                : 'At a glance'),
            SportsDetailSurface(
                child: Column(children: [
              SportsDetailComparisonRow('', comparison.columns, heading: true),
              for (final row in featured)
                Padding(
                    padding: const EdgeInsets.symmetric(vertical: 7),
                    child: SportsDetailComparisonRow(row.label, row.values)),
            ])),
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
            heading(team == null ? 'Event information' : 'Profile'),
            if (information != null)
              for (final row in information.rows.where((r) =>
                  team != null ||
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
            size: 34,
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
              child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 100),
                  child: Tooltip(
                      message: score!,
                      child: Text(score!,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 28,
                              fontWeight: FontWeight.w700,
                              fontFeatures: [FontFeature.tabularFigures()]))))),
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
            Text(
                league.kind == SportsKind.racing ||
                        league.kind == SportsKind.golf
                    ? 'Season overview'
                    : league.kind == SportsKind.tennis ||
                            league.kind == SportsKind.fight
                        ? 'Player record'
                        : 'Team record',
                style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: colors.onSurfaceVariant)),
          ]),
          const SizedBox(height: 10),
          if (records.isNotEmpty)
            SportsDetailMetrics(entries: records, primary: true),
          if (records.isNotEmpty && metrics.isNotEmpty)
            Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Divider(
                    height: 1,
                    color: colors.outlineVariant.withValues(alpha: .4))),
          if (metrics.isNotEmpty)
            SportsDetailMetrics(entries: metrics, primary: records.isEmpty),
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
            padding: const WidgetStatePropertyAll(
                EdgeInsets.symmetric(horizontal: 10, vertical: 9)),
            backgroundColor: WidgetStateProperty.resolveWith((states) =>
                states.contains(WidgetState.focused) ||
                        states.contains(WidgetState.pressed)
                    ? colors.primary.withValues(alpha: .16)
                    : colors.onSurface.withValues(alpha: .035))),
        onPressed: action,
        child: Row(children: [
          Icon(icon, size: 17, color: colors.primary.withValues(alpha: .85)),
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
  const SportsDetailTable({super.key, required this.section, this.league});
  final SportsDetailSection section;
  final SportsLeague? league;
  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, box) {
        final colors = Theme.of(context).colorScheme;
        final tv = context.read<AppPreferences>().isTelevision;
        final scale = MediaQuery.textScalerOf(context).scale(12) / 12;
        final comparison = section.kind == SportsDetailKind.comparison;
        final periods = section.kind == SportsDetailKind.periods;
        final roster = section.kind == SportsDetailKind.lineup &&
            section.columns.length == 2 &&
            section.columns.first == '#';
        final information = section.kind == SportsDetailKind.information ||
            section.kind == SportsDetailKind.record;
        final count = math.min(
            section.columns.length,
            math.max(
                1,
                ((box.maxWidth / scale - (periods ? 72 : 130)) /
                        (periods ? 28 : 48))
                    .floor()));
        // Same column widths and outer inset for the header and mounted rows.
        final cellWidth =
            (box.maxWidth * (periods ? .80 : .56) / math.max(count, 1));
        Widget cells(List<String> values, {bool heading = false}) =>
            Row(mainAxisSize: MainAxisSize.min, children: [
              for (var i = 0; i < count; i++)
                SizedBox(
                    width: cellWidth,
                    child: Text(
                        i < values.length && values[i].isNotEmpty
                            ? values[i]
                            : '–',
                        textAlign: TextAlign.center,
                        maxLines: heading ? 2 : 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: heading ? 10 : 12,
                            color: heading
                                ? colors.onSurfaceVariant
                                : colors.onSurface,
                            fontWeight:
                                heading ? FontWeight.w500 : FontWeight.w600,
                            fontFeatures: const [
                              FontFeature.tabularFigures()
                            ]))),
            ]);
        Widget title(SportsDetailRow row) => Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(row.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 12,
                          height: 1.2,
                          color: colors.onSurface,
                          fontWeight: FontWeight.w500)),
                  if (row.detail?.isNotEmpty == true)
                    Text(row.detail!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 10,
                            height: 1.2,
                            color: colors.onSurfaceVariant)),
                ]);
        Widget content(SportsDetailRow row) {
          if (comparison) {
            return Center(
                child: SportsDetailComparisonRow(row.label, row.values));
          }
          if (roster) {
            return Row(children: [
              Container(
                  width: 32,
                  height: 30,
                  alignment: Alignment.center,
                  margin: const EdgeInsets.only(right: 9),
                  decoration: BoxDecoration(
                      color: colors.primary.withValues(alpha: .065),
                      borderRadius: BorderRadius.circular(4)),
                  child: Text(
                      row.values.firstOrNull?.isNotEmpty == true
                          ? row.values.first
                          : '–',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: colors.primary,
                          fontFeatures: const [FontFeature.tabularFigures()]))),
              Expanded(child: title(row)),
              const SizedBox(width: 6),
              SizedBox(
                  width: math.min(90 * scale, box.maxWidth * .28),
                  child: Text(row.values.length > 1 ? row.values[1] : '–',
                      textAlign: TextAlign.end,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 11, color: colors.onSurfaceVariant))),
              Icon(Icons.chevron_right,
                  size: 16, color: colors.onSurfaceVariant),
            ]);
          }
          return Row(children: [
            Expanded(child: title(row)),
            const SizedBox(width: 5),
            if (information)
              SizedBox(
                  width: box.maxWidth * .48,
                  child: Text(row.values.join(' · '),
                      textAlign: TextAlign.end,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: section.kind == SportsDetailKind.record
                              ? colors.primary
                              : colors.onSurface,
                          fontFeatures: const [FontFeature.tabularFigures()])))
            else
              cells(row.values),
            SizedBox(
                width: 18,
                child: Icon(Icons.chevron_right,
                    size: 14,
                    color: colors.onSurfaceVariant.withValues(alpha: .6))),
          ]);
        }

        final labels = <String, int>{};
        for (final row in section.rows) {
          labels.update(row.id ?? row.label, (v) => v + 1, ifAbsent: () => 1);
        }
        return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (box.maxHeight >= 230 * scale)
                SportsDetailHeading(section.title,
                    detail:
                        '${section.rows.length} ${sportsPlayerSection(section) ? 'players' : 'rows'}'),
              Container(
                  padding: EdgeInsets.fromLTRB(9, 8, comparison ? 9 : 27, 8),
                  decoration: BoxDecoration(
                      color: colors.onSurface.withValues(alpha: .045),
                      border: Border(
                          bottom: BorderSide(
                              color: colors.outlineVariant
                                  .withValues(alpha: .45)))),
                  child: comparison
                      ? SportsDetailComparisonRow('Statistic', section.columns,
                          heading: true)
                      : Row(children: [
                          Expanded(
                              child: Text(
                                  sportsPlayerSection(section)
                                      ? 'Player'
                                      : periods
                                          ? 'Team'
                                          : league?.kind == SportsKind.racing
                                              ? 'Driver'
                                              : league?.kind == SportsKind.golf
                                                  ? 'Player'
                                                  : 'Detail',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                      fontSize: 10,
                                      color: colors.onSurfaceVariant))),
                          if (roster)
                            Text('Position',
                                style: TextStyle(
                                    fontSize: 10,
                                    color: colors.onSurfaceVariant))
                          else if (information)
                            Text(section.columns.firstOrNull ?? 'Value',
                                style: TextStyle(
                                    fontSize: 10,
                                    color: colors.onSurfaceVariant))
                          else
                            cells(section.columns, heading: true)
                        ])),
              if (count < section.columns.length &&
                  !comparison &&
                  !roster &&
                  !information)
                Padding(
                    padding:
                        const EdgeInsets.symmetric(vertical: 4, horizontal: 9),
                    child: Text(
                        'Select a row for all ${section.columns.length} statistics',
                        style: TextStyle(
                            fontSize: 10, color: colors.onSurfaceVariant))),
              Expanded(
                  child: CompactChoiceList(
                      polished: true,
                      striped: true,
                      showNavigation: tv,
                      rowHeight: (comparison
                              ? 49
                              : tv
                                  ? 43
                                  : compactSportsControls(context)
                                      ? 46
                                      : 52) *
                          scale,
                      choices: [
                    for (final (index, row) in section.rows.indexed)
                      CompactChoice(
                          id:
                              'detail-${row.id ?? row.label}${labels[row.id ?? row.label] == 1 ? '' : ':$index'}',
                          title: row.label,
                          contentBuilder: (_) => content(row),
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
                                              padding: const EdgeInsets.only(
                                                  bottom: 10),
                                              child: Text(row.detail!,
                                                  style: TextStyle(
                                                      fontSize: 11,
                                                      color: Theme.of(context)
                                                          .colorScheme
                                                          .onSurfaceVariant))),
                                        for (final (i, value)
                                            in row.values.indexed)
                                          Container(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                      horizontal: 8,
                                                      vertical: 5),
                                              color: i.isOdd
                                                  ? colors.onSurface
                                                      .withValues(alpha: .025)
                                                  : null,
                                              child: _InformationLine(
                                                  i < section.columns.length
                                                      ? section.columns[i]
                                                      : '',
                                                  value)),
                                      ]))))
                  ])),
            ]);
      });
}
