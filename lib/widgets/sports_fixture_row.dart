import 'package:flutter/material.dart';
import '../models/sports.dart';
import '../utils/sports_detail_presentation.dart';
import '../utils/sports_fixture_presentation.dart';
import 'sports_widgets.dart';

/// Uses only the fixture snapshot; browsing never requests match details.
class SportsFixtureRow extends StatelessWidget {
  const SportsFixtureRow(
      {super.key,
      required this.game,
      required this.time,
      required this.hideScores,
      required this.use24h,
      this.showLeague = false});
  final SportsGame game;
  final String time;
  final bool hideScores, use24h, showLeague;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final showScore = !hideScores && game.state != GameState.pre;
    final insight = sportsFixtureInsight(game, hideScores: hideScores);
    Widget team(SportsTeam side) => Row(children: [
          ExcludeSemantics(
              child: SportsLogo(
                  url: side.logoUrl,
                  size: 18,
                  fallback: side.abbreviation.isEmpty
                      ? side.shortName
                      : side.abbreviation,
                  color: side.color,
                  animate: false)),
          const SizedBox(width: 6),
          Expanded(
              child: Text(side.name.isEmpty ? side.shortName : side.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      height: 1.25))),
          const SizedBox(width: 8),
          Text(
              showScore
                  ? side.score ?? '–'
                  : hideScores
                      ? ''
                      : side.record ?? '',
              style: TextStyle(
                  fontSize: showScore ? 13 : 10,
                  fontWeight: showScore ? FontWeight.w600 : FontWeight.w400,
                  fontFeatures: const [FontFeature.tabularFigures()],
                  color:
                      showScore ? colors.onSurface : colors.onSurfaceVariant)),
        ]);
    final status = game.isLive ? 'LIVE' : sportsFixtureStatus(game);
    final progress =
        game.isLive && !hideScores ? sportsFixtureStatus(game) : null;
    return Row(children: [
      SizedBox(
          width: (use24h ? 42.0 : 62.0) *
              MediaQuery.textScalerOf(context).scale(11) /
              11,
          child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(time,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                        fontFeatures: const [FontFeature.tabularFigures()],
                        color: colors.onSurface)),
                if (showLeague)
                  Tooltip(
                      message: game.league.name,
                      child: Text(game.league.shortName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 9, color: colors.onSurfaceVariant))),
                if (status != 'Scheduled')
                  Text(status,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 9,
                          fontWeight: FontWeight.w600,
                          color: game.isLive
                              ? colors.primary
                              : colors.onSurfaceVariant)),
                if (!showLeague &&
                    progress != null &&
                    progress.isNotEmpty &&
                    progress.toUpperCase() != 'LIVE')
                  Text(progress,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 9, color: colors.onSurfaceVariant)),
              ])),
      Container(
          width: 1,
          height: 28,
          margin: const EdgeInsets.symmetric(horizontal: 10),
          color: colors.outlineVariant.withValues(alpha: .45)),
      Expanded(
          child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
            if (!game.league.isField) ...[
              team(game.first),
              const SizedBox(height: 2),
              team(game.second)
            ] else ...[
              Text(game.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 12, fontWeight: FontWeight.w600)),
              if (insight != null)
                Text(insight,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 10.5, color: colors.onSurfaceVariant)),
            ],
          ])),
      const SizedBox(width: 6),
      Icon(Icons.chevron_right, size: 15, color: colors.onSurfaceVariant),
    ]);
  }
}
