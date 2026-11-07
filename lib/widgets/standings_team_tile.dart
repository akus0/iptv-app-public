import 'sports_header_controls.dart';
import 'sports_detail_components.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/app_preferences.dart';
import '../services/sports_standings_service.dart';
import '../utils/guarded_dialog.dart';
import 'sports_widgets.dart';

class StandingsColumn {
  const StandingsColumn(this.key, this.label, this.description, this.priority);
  final String key, label, description;
  final int priority;
}

const standingsColumns = [
  StandingsColumn('gamesPlayed', 'GP', 'Games played', 4),
  StandingsColumn('wins', 'W', 'Wins', 1),
  StandingsColumn('ties', 'D', 'Draws', 5),
  StandingsColumn('losses', 'L', 'Losses', 2),
  StandingsColumn('pointDifferential', 'DIFF', 'Points difference', 6),
  StandingsColumn('points', 'PTS', 'Points', 0),
  StandingsColumn('championshipPts', 'PTS', 'Championship points', 0),
  StandingsColumn('winPercent', 'PCT', 'Win percentage', 3),
];

const _footballColumns = [
  StandingsColumn('gamesPlayed', 'GP', 'Games played', 2),
  StandingsColumn('wins', 'W', 'Wins', 3),
  StandingsColumn('ties', 'D', 'Draws', 4),
  StandingsColumn('losses', 'L', 'Losses', 5),
  StandingsColumn('pointDifferential', 'GD', 'Goal difference', 1),
  StandingsColumn('points', 'PTS', 'Points', 0),
];
const _recordColumns = [
  StandingsColumn('wins', 'W', 'Wins', 0),
  StandingsColumn('losses', 'L', 'Losses', 1),
  StandingsColumn('ties', 'T', 'Ties', 4),
  StandingsColumn('winPercent', 'PCT', 'Win percentage', 2),
  StandingsColumn('gamesBehind', 'GB', 'Games behind', 3),
];
const _collegeColumns = [
  StandingsColumn('vs. Conf.', 'CONF', 'Conference record', 0),
  StandingsColumn('overall', 'OVER', 'Overall record', 1),
  StandingsColumn('streak', 'STK', 'Streak', 2),
  StandingsColumn('pointDifferential', 'DIFF', 'Points difference', 3),
];
const _hockeyColumns = [
  StandingsColumn('gamesPlayed', 'GP', 'Games played', 4),
  StandingsColumn('wins', 'W', 'Wins', 1),
  StandingsColumn('losses', 'L', 'Losses', 2),
  StandingsColumn('otLosses', 'OTL', 'Overtime losses', 3),
  StandingsColumn('pointDifferential', 'GD', 'Goal difference', 5),
  StandingsColumn('points', 'PTS', 'Points', 0),
];
const _rugbyColumns = [
  StandingsColumn('gamesPlayed', 'GP', 'Games played', 2),
  StandingsColumn('wins', 'W', 'Wins', 1),
  StandingsColumn('ties', 'D', 'Draws', 5),
  StandingsColumn('losses', 'L', 'Losses', 3),
  StandingsColumn('pointDifferential', 'DIFF', 'Points difference', 4),
  StandingsColumn('bonusPoints', 'BP', 'Bonus points', 6),
  StandingsColumn('points', 'PTS', 'Points', 0),
];
const _racingColumns = [
  StandingsColumn('wins', 'W', 'Wins', 1),
  StandingsColumn('championshipPts', 'PTS', 'Championship points', 0),
  StandingsColumn('points', 'PTS', 'Championship points', 0),
];
const _aflColumns = [
  StandingsColumn('gamesPlayed', 'GP', 'Games played', 2),
  StandingsColumn('wins', 'W', 'Wins', 3),
  StandingsColumn('losses', 'L', 'Losses', 4),
  StandingsColumn('ties', 'D', 'Draws', 5),
  StandingsColumn('percentage', '%', 'Percentage', 1),
  StandingsColumn('points', 'PTS', 'Premiership points', 0),
];
const _rankingColumns = [
  StandingsColumn('rankingPoints', 'RATING', 'Rating points', 0),
  StandingsColumn('wins', 'W', 'Wins', 0),
  StandingsColumn('losses', 'L', 'Losses', 2),
  StandingsColumn('ties', 'T', 'Ties', 3),
  StandingsColumn('pollPoints', 'PTS', 'Poll points', 1),
];

List<StandingsColumn> _columnsForSport(String? sport) => switch (sport) {
      'soccer' => _footballColumns,
      'basketball' ||
      'baseball' ||
      'football' ||
      'volleyball' =>
        _recordColumns,
      'australian-football' => _aflColumns,
      'hockey' => _hockeyColumns,
      'rugby' => _rugbyColumns,
      'racing' => _racingColumns,
      _ => standingsColumns,
    };

/// Keep useful statistics on small screens, then restore normal table order.
List<StandingsColumn> visibleStandingsColumns(
    Set<String> available, double width,
    {String? sport,
    String? leagueId,
    bool rankings = false,
    double columnWidth = 52}) {
  // College feeds may omit losses but supply complete conference and overall
  // records. Show those records directly instead of deriving missing values.
  final collegeRecords = leagueId?.contains('college-') == true &&
      const {'football', 'basketball', 'baseball', 'volleyball'}
          .contains(sport) &&
      available.contains('overall');
  final profile = rankings
      ? _rankingColumns
      : collegeRecords
          ? _collegeColumns
          : _columnsForSport(sport);
  final columns = profile
      .where((c) =>
          available.contains(c.key) &&
          (c.key != 'points' ||
              sport != null && sport != 'racing' ||
              !available.contains('championshipPts')))
      .toList()
    ..sort((a, b) => a.priority.compareTo(b.priority));
  final count = ((width - 265) / columnWidth).floor().clamp(0, columns.length);
  if ((identical(profile, _recordColumns) || rankings) &&
      count > 0 &&
      count <= 2 &&
      available.containsAll({'wins', 'losses'})) {
    return [
      StandingsColumn(
          'winLossRecord',
          available.contains('ties') ? 'W-L-T' : 'W-L',
          'Win–loss${available.contains('ties') ? '–tie' : ''} record',
          0),
      if (count == 2 && available.contains('winPercent'))
        _recordColumns.firstWhere((c) => c.key == 'winPercent')
      else if (count == 2 && available.contains('pollPoints'))
        _rankingColumns.firstWhere((c) => c.key == 'pollPoints'),
    ];
  }
  final picked = columns.take(count).toSet();
  return profile.where(picked.contains).toList();
}

String standingColumnValue(StandingTeam row, StandingsColumn column) =>
    column.key == 'winLossRecord'
        ? [row.stats['wins'], row.stats['losses'], row.stats['ties']]
            .whereType<String>()
            .join('-')
        : row.stats[column.key] ??
            (column.key == 'championshipPts' ? row.stats['points'] : null) ??
            '–';

/// Shared dimensions keep heading and data cells aligned independently of
/// Material button tap targets and ListTile's implicit trailing spacing.
class _StandingsGeometry {
  _StandingsGeometry(BuildContext context)
      : television = context.read<AppPreferences?>()?.isTelevision == true,
        compact = compactSportsControls(context);
  final bool television, compact;
  static const inset = 10.0,
      rank = 22.0,
      rankGap = 4.0,
      nameGap = 10.0,
      actionGap = 8.0;
  double get logo => television ? 26 : 30;
  double get action => television
      ? 32
      : compact
          ? 40
          : 48;
  double get minimumHeight => television
      ? 40
      : compact
          ? 44
          : 48;
}

/// One fixed heading keeps column meanings visible without scroll listeners.
class StandingsTableHeader extends StatelessWidget {
  const StandingsTableHeader(
      {super.key,
      required this.columns,
      required this.label,
      this.columnWidth = 52});
  final List<StandingsColumn> columns;
  final String label;
  final double columnWidth;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final geometry = _StandingsGeometry(context);
    return DecoratedBox(
        decoration: BoxDecoration(
            color: colors.surfaceContainerHighest.withValues(alpha: .28),
            border: Border(
                bottom: BorderSide(
                    color: colors.outlineVariant.withValues(alpha: .45)))),
        child: Padding(
            padding: EdgeInsets.symmetric(
                horizontal: _StandingsGeometry.inset,
                vertical: compactSportsControls(context) ? 3 : 5),
            child: DefaultTextStyle.merge(
                style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w500,
                    color: colors.onSurfaceVariant),
                child: Row(children: [
                  const SizedBox(
                      width: _StandingsGeometry.rank,
                      child: Text('#', textAlign: TextAlign.center)),
                  SizedBox(
                      width: _StandingsGeometry.rankGap +
                          geometry.logo +
                          _StandingsGeometry.nameGap),
                  Expanded(
                      child: Text(label,
                          maxLines: 1, overflow: TextOverflow.ellipsis)),
                  for (final column in columns)
                    SizedBox(
                        width: columnWidth,
                        child: Tooltip(
                            message: column.description,
                            child: Text(column.label,
                                textAlign: TextAlign.right,
                                style: column.priority == 0
                                    ? TextStyle(
                                        color: colors.onSurface,
                                        fontWeight: FontWeight.w700)
                                    : null))),
                  SizedBox(
                      width: _StandingsGeometry.actionGap + geometry.action),
                ]))));
  }
}

class StandingsTeamTile extends StatefulWidget {
  const StandingsTeamTile(
      {super.key,
      required this.row,
      this.logoFallback,
      required this.columns,
      this.columnWidth = 52,
      this.alternate = false,
      required this.followed,
      required this.directory,
      required this.onToggle,
      required this.onDetails});
  final StandingTeam row;
  final String? logoFallback;
  final List<StandingsColumn> columns;
  final double columnWidth;
  final bool followed, directory, alternate;
  final VoidCallback onToggle, onDetails;

  @override
  State<StandingsTeamTile> createState() => _StandingsTeamTileState();
}

class _StandingsTeamTileState extends State<StandingsTeamTile> {
  final _focused = ValueNotifier(false);

  @override
  void dispose() {
    _focused.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final row = widget.row;
    final geometry = _StandingsGeometry(context);
    final compactText = MediaQuery.textScalerOf(context).scale(13) <= 17;
    return ValueListenableBuilder<bool>(
      valueListenable: _focused,
      // Remote focus repaints the frame without rebuilding logos or statistics.
      builder: (context, focused, child) => DecoratedBox(
          decoration: BoxDecoration(
              color: focused
                  ? colors.primary.withValues(alpha: .15)
                  : widget.alternate
                      ? colors.onSurface.withValues(alpha: .025)
                      : null,
              border: focused
                  ? Border.all(color: colors.primary.withValues(alpha: .8))
                  : Border(
                      bottom: BorderSide(
                          color:
                              colors.outlineVariant.withValues(alpha: .12)))),
          child: child),
      child: Focus(
        canRequestFocus: false,
        onFocusChange: (value) => _focused.value = value,
        child: Padding(
          padding:
              const EdgeInsets.symmetric(horizontal: _StandingsGeometry.inset),
          child: Row(children: [
            Expanded(
                child: Semantics(
                    button: true,
                    label: widget.directory
                        ? null
                        : 'View record for ${row.team.name}',
                    child: InkWell(
                        key: ValueKey('record-${row.team.id}'),
                        focusColor: Colors.transparent,
                        onTap: widget.directory
                            ? widget.onToggle
                            : widget.onDetails,
                        child: ConstrainedBox(
                            constraints: BoxConstraints(
                                minHeight: geometry.minimumHeight),
                            child: Padding(
                                padding:
                                    const EdgeInsets.symmetric(vertical: 4),
                                child: Row(children: [
                                  if (!widget.directory) ...[
                                    SizedBox(
                                        width: _StandingsGeometry.rank,
                                        child: Text(
                                            row.position?.toString() ?? '–',
                                            textAlign: TextAlign.center,
                                            style: TextStyle(
                                                fontSize: 11.5,
                                                color: colors.onSurfaceVariant
                                                    .withValues(alpha: .8),
                                                fontFeatures: const [
                                                  FontFeature.tabularFigures()
                                                ]))),
                                    const SizedBox(
                                        width: _StandingsGeometry.rankGap),
                                  ],
                                  DecoratedBox(
                                      decoration: BoxDecoration(
                                          color: colors.onSurface
                                              .withValues(alpha: .055),
                                          borderRadius:
                                              BorderRadius.circular(4)),
                                      child: SportsLogo(
                                          url: row.team.logoUrl,
                                          size: geometry.logo,
                                          fallback: widget.logoFallback ??
                                              (row.team.abbreviation.isEmpty
                                                  ? row.team.name
                                                  : row.team.abbreviation),
                                          color: row.team.color,
                                          animate: false)),
                                  const SizedBox(
                                      width: _StandingsGeometry.nameGap),
                                  Expanded(
                                      child: Text(row.team.name,
                                          maxLines: compactText ? 1 : 2,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                              fontSize: geometry.television
                                                  ? 12.5
                                                  : 13,
                                              color: colors.onSurface,
                                              fontWeight: FontWeight.w500))),
                                  for (final column in widget.columns)
                                    SizedBox(
                                        width: widget.columnWidth,
                                        child: Tooltip(
                                            message:
                                                '${column.description}: ${standingColumnValue(row, column)}',
                                            child: Text(
                                                standingColumnValue(
                                                    row, column),
                                                textAlign: TextAlign.right,
                                                style: TextStyle(
                                                    fontSize:
                                                        column.priority == 0
                                                            ? 14
                                                            : 11.5,
                                                    fontWeight:
                                                        column.priority == 0
                                                            ? FontWeight.w700
                                                            : FontWeight.w400,
                                                    color: column.priority == 0
                                                        ? colors.onSurface
                                                        : colors
                                                            .onSurfaceVariant,
                                                    fontFeatures: const [
                                                      FontFeature
                                                          .tabularFigures()
                                                    ])))),
                                ])))))),
            const SizedBox(width: _StandingsGeometry.actionGap),
            SizedBox(
                width: geometry.action,
                height: geometry.action,
                child: IconButton(
                    key: ValueKey('follow-${row.team.id}'),
                    style: IconButton.styleFrom(
                        padding: EdgeInsets.zero,
                        minimumSize: Size(geometry.action, geometry.action),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                    tooltip:
                        widget.followed ? 'Remove favourite' : 'Add favourite',
                    isSelected: widget.followed,
                    color: widget.followed
                        ? colors.primary
                        : colors.onSurfaceVariant.withValues(alpha: .65),
                    icon: const Icon(Icons.star_border, size: 17),
                    selectedIcon: const Icon(Icons.star, size: 17),
                    onPressed: widget.onToggle)),
          ]),
        ),
      ),
    );
  }
}

Future<void> showStandingRecord(BuildContext context, StandingTeam row,
    {String? sport, bool rankings = false, String? rankingTitle}) {
  final labels = {
    for (final c in standingsColumns) c.key: c.description,
    for (final c in _columnsForSport(sport)) c.key: c.description,
    for (final c in _rankingColumns) c.key: c.description,
  };
  final seen = <String>{};
  final stats = <(String, String)>[];
  for (final entry in row.stats.entries) {
    if (entry.key == 'rank' || entry.key == 'playoffSeed') continue;
    if (entry.key == 'points' &&
        const {'basketball', 'baseball', 'football', 'volleyball'}
            .contains(sport)) {
      continue;
    }
    // The parser preserves the source field alongside its canonical alias.
    const aliases = {
      'gamesWon': 'wins',
      'gamesLost': 'losses',
      'gamesDrawn': 'ties',
      'pointsDifference': 'pointDifferential'
    };
    if (row.stats.containsKey(aliases[entry.key])) continue;
    final label = row.statLabels[entry.key] ?? labels[entry.key];
    if (label != null &&
        entry.value.isNotEmpty &&
        seen.add(label.toLowerCase())) {
      stats.add((label, entry.value));
    }
  }
  return showSportsDialog<void>(
      context: context,
      builder: (context) => SportsCompactDialog(
            title: row.team.name,
            actions: [
              TextButton(
                  style: sportsPopupButtonStyle(context),
                  autofocus: true,
                  onPressed: () => popRouteIfCurrent(context),
                  child: const Text('Close'))
            ],
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (row.position != null) ...[
                  SportsDetailMetrics(primary: true, entries: [
                    (
                      rankings
                          ? rankingTitle == 'World rankings'
                              ? 'World rank'
                              : 'Rank'
                          : 'Position',
                      '${row.position}'
                    ),
                  ]),
                  const SizedBox(height: 8),
                ],
                SportsDetailMetrics(entries: stats),
                if (stats.isEmpty)
                  const Text('No additional statistics are available.'),
              ],
            ),
          ));
}
