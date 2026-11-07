import 'package:flutter/foundation.dart' show listEquals, mapEquals;
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
        scoreboardBroadcasts: game.scoreboardBroadcasts,
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

/// Guide IDs can stay stable when a scheduled slot starts or merged coverage
/// is corrected. Compare display/evidence fields without serializing synopses.
bool sameGuideCoverage(List<SportsGame> a, List<SportsGame> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    final x = a[i], y = b[i];
    if (identical(x, y)) continue;
    if (x.id != y.id ||
        x.league.id != y.league.id ||
        x.state != y.state ||
        x.statusText != y.statusText ||
        x.start != y.start ||
        x.end != y.end ||
        x.event?.title != y.event?.title ||
        x.event?.venue != y.event?.venue ||
        x.event?.court != y.event?.court ||
        x.event?.session != y.event?.session ||
        !listEquals(x.event?.matchingNames, y.event?.matchingNames) ||
        !listEquals(x.event?.participantIds, y.event?.participantIds) ||
        !mapEquals(x.event?.participantNames, y.event?.participantNames) ||
        x.guideProgrammes.length != y.guideProgrammes.length) {
      return false;
    }
    for (var j = 0; j < x.guideProgrammes.length; j++) {
      final p = x.guideProgrammes[j], q = y.guideProgrammes[j];
      if (!identical(p, q) &&
          (p.channelId != q.channelId ||
              p.start != q.start ||
              p.stop != q.stop ||
              p.title != q.title ||
              p.description != q.description ||
              p.isLive != q.isLive)) {
        return false;
      }
    }
  }
  return true;
}
