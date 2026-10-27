import '../models/epg_program.dart';
import '../models/sports.dart';

SportsGame copyGuideCoverage(SportsGame game, List<EpgProgram> programmes,
        {String? id, DateTime? start, DateTime? end, SportsEventInfo? event}) =>
    SportsGame(
        id: id ?? game.id,
        league: game.league,
        start: start ?? game.start,
        end: end ?? game.end,
        state: game.state,
        statusText: game.statusText,
        home: game.home,
        away: game.away,
        broadcasts: game.broadcasts,
        event: event ?? game.event,
        leaders: game.leaders,
        situation: game.situation,
        source: game.source,
        onlineBroadcasts: game.onlineBroadcasts,
        guideProgrammes: List.unmodifiable(programmes));

/// Weak caches keep repeated enrichment idempotent without retaining routes.
final _attached = Expando<(SportsGame, SportsGame)>();
final _bases = Expando<SportsGame>();

SportsGame withoutGuideCoverage(SportsGame game) =>
    game.guideProgrammes.isNotEmpty && !game.isGuideEvent
        ? _bases[game] ??= copyGuideCoverage(game, const [])
        : game;

SportsGame attachGuideCoverage(SportsGame target, SportsGame guide) {
  final previous = _attached[target];
  if (previous != null && identical(previous.$1, guide)) return previous.$2;
  final result = copyGuideCoverage(
      target, [...target.guideProgrammes, ...guide.guideProgrammes]);
  _bases[result] = _bases[target] ?? target;
  _attached[target] = (guide, result);
  return result;
}
