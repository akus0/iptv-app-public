import 'dart:collection';
import '../models/sports.dart';
import 'storage_service.dart';

/// Saved team favourites, shared by Sports browsing and the optional team picker.
/// Stored per viewer profile, in follow order.
class SportsFollows {
  SportsFollows.load(this._storage)
      : _teams = [
          for (final raw in _storage.getSportsFollowedTeams())
            if (FollowedTeam.parse(raw) case final t?) t,
        ] {
    _index.addAll(_teams);
    _names.addAll(_storage.getSportsTeamNames());
    _logos.addAll(_storage.getSportsTeamLogos());
  }

  final StorageService _storage;
  final List<FollowedTeam> _teams;
  final _index = <FollowedTeam>{};
  int _revision = 0;
  int get revision => _revision;
  final _involvement = Expando<(int, bool)>();
  final _names = <String, String>{};
  final _logos = <String, String>{};
  String? logoOf(FollowedTeam team) => _logos[team.key];
  late final List<FollowedTeam> _view = UnmodifiableListView(_teams);
  String? nameOf(FollowedTeam team) => _names[team.key];
  Future<void>? _pending;
  Future<void> _write(Future<void> Function() action) {
    final result = _pending?.then((_) => action()) ?? action();
    late final Future<void> tail;
    void settled() {
      if (identical(_pending, tail)) _pending = null;
    }

    tail =
        result.then<void>((_) => settled(), onError: (Object _) => settled());
    _pending = tail;
    return result;
  }

  bool _remember(FollowedTeam key, SportsTeam team) {
    if (!_index.contains(key)) return false;
    var changed = false;
    if (_names[key.key] != team.name) {
      _names[key.key] = team.name;
      changed = true;
    }
    if (team.logoUrl != null && _logos[key.key] != team.logoUrl) {
      _logos[key.key] = team.logoUrl!;
      changed = true;
    }
    if (changed) _revision++;
    return changed;
  }

  Future<void> _saveIdentity() async {
    await _storage.setSportsTeamNames(_names);
    await _storage.setSportsTeamLogos(_logos);
  }

  Future<void> rememberTeams(String league, Iterable<SportsTeam> teams) =>
      _write(() async {
        var changed = false;
        for (final team in teams) {
          changed = _remember(FollowedTeam(league, team.id), team) || changed;
        }
        if (changed) await _saveIdentity();
      });

  /// Reuse identities already fetched for Sports without requesting team schedules.
  Future<void> rememberGames(Iterable<SportsGame> games) => _write(() async {
        var changed = false;
        for (final game in games) {
          for (final team in [game.home, game.away]) {
            changed = _remember(FollowedTeam(game.league.id, team.id), team) ||
                changed;
          }
        }
        if (changed) await _saveIdentity();
      });

  List<FollowedTeam> get teams => _view;
  bool get isEmpty => _teams.isEmpty;

  bool isFollowed(String leagueId, String teamId) =>
      _index.contains(FollowedTeam(leagueId, teamId));

  /// Membership is league-scoped; never infer entries from similar names.
  bool involves(SportsGame g) {
    if (isEmpty) return false;
    final cached = _involvement[g];
    if (cached?.$1 == _revision) return cached!.$2;
    final result = isFollowed(g.league.id, g.home.id) ||
        isFollowed(g.league.id, g.away.id) ||
        (g.event?.participantIds.any((id) {
              if (!isFollowed(g.league.id, id)) return false;
              if (g.league.kind != SportsKind.racing) return true;
              final saved = _names[FollowedTeam(g.league.id, id).key];
              final supplied = g.event!.participantNames[id];
              return saved != null &&
                  supplied != null &&
                  saved.trim().toLowerCase() == supplied.trim().toLowerCase();
            }) ??
            false);
    _involvement[g] = (_revision, result);
    return result;
  }

  Future<void> follow(String leagueId, String teamId,
          {String? name, String? logoUrl, int? atIndex}) =>
      _write(() async {
        final t = FollowedTeam(leagueId, teamId);
        if (!_index.add(t)) return;
        _teams.insert(atIndex?.clamp(0, _teams.length) ?? _teams.length, t);
        try {
          await _save();
        } catch (_) {
          _teams.remove(t);
          _index.remove(t);
          rethrow;
        }
        _revision++;
        if (name != null || logoUrl != null) {
          if (name != null) _names[t.key] = name;
          if (logoUrl != null) _logos[t.key] = logoUrl;
          try {
            await _saveIdentity();
          } catch (_) {}
        }
      });

  Future<void> unfollow(String leagueId, String teamId) => _write(() async {
        final t = FollowedTeam(leagueId, teamId);
        final position = _teams.indexOf(t);
        if (position < 0) return;
        _teams.removeAt(position);
        _index.remove(t);
        try {
          await _save();
        } catch (_) {
          _teams.insert(position.clamp(0, _teams.length), t);
          _index.add(t);
          rethrow;
        }
        _revision++;
        _names.remove(t.key);
        _logos.remove(t.key);
        try {
          await _saveIdentity();
        } catch (_) {}
      });

  Future<void> _save() =>
      _storage.setSportsFollowedTeams([for (final t in _teams) t.key]);
}
