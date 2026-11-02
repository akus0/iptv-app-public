import '../models/sports.dart';

/// Resolve remembered context against this pane's capabilities, without I/O.
SportsLeague? resolveSportsBrowseLeague(Iterable<SportsLeague> leagues,
    {String? leagueId, String? sport, String? fallbackId}) {
  final exact = leagues.where((l) => l.id == leagueId).firstOrNull;
  if (exact != null) return exact;
  if (sport != null) {
    final sameSport =
        leagues.where((l) => l.espnPath.split('/').first == sport);
    final previous = sameSport.where((l) => l.id == fallbackId).firstOrNull;
    if (previous != null) return previous;
    if (sameSport.firstOrNull case final league?) return league;
  }
  return leagues.where((l) => l.id == fallbackId).firstOrNull ??
      leagues.firstOrNull;
}
