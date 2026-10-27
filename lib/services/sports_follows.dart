import '../models/sports.dart';
import 'storage_service.dart';

/// The viewer's My Teams list (followed via Standings, hold OK on a team).
/// Stored per viewer profile, in follow order.
class SportsFollows {
  SportsFollows.load(this._storage)
      : _teams = [
          for (final raw in _storage.getSportsFollowedTeams())
            if (FollowedTeam.parse(raw) case final t?) t,
        ];

  final StorageService _storage;
  final List<FollowedTeam> _teams;

  List<FollowedTeam> get teams => List.unmodifiable(_teams);
  bool get isEmpty => _teams.isEmpty;

  bool isFollowed(String leagueId, String teamId) =>
      _teams.contains(FollowedTeam(leagueId, teamId));

  /// True when either side of [g] is followed.
  bool involves(SportsGame g) =>
      isFollowed(g.league.id, g.home.id) || isFollowed(g.league.id, g.away.id);

  Future<void> follow(String leagueId, String teamId) {
    final t = FollowedTeam(leagueId, teamId);
    if (_teams.contains(t)) return Future.value();
    _teams.add(t);
    return _save();
  }

  Future<void> unfollow(String leagueId, String teamId) {
    _teams.remove(FollowedTeam(leagueId, teamId));
    return _save();
  }

  Future<void> _save() =>
      _storage.setSportsFollowedTeams([for (final t in _teams) t.key]);
}
