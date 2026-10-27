import 'dart:async';
import '../utils/sports_calendar.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../models/sports.dart';
import '../services/sports_channel_matcher.dart';
import '../services/sports_follows.dart';
import '../services/sports_service.dart';
import '../utils/time_format.dart';
import '../utils/route_observer.dart';
import '../utils/tv_theme.dart';
import '../widgets/hold_to_activate.dart';
import '../widgets/settings_scaffold.dart';
import '../widgets/sports_widgets.dart';
import 'sports_standings_screen.dart';
import '../l10n/l10n.dart';

/// Signature of the Sports screen's game actions, so My Teams plays and
/// picks channels exactly like the game cards do (same picks, same player).
typedef SportsGameAction = Future<void> Function(
    SportsGame game, List<ChannelMatch> matches);

/// Followed teams with records, standings and upcoming games. Use explicit navigation
/// between the team list and details; hold a team to change its followed state.
class SportsMyTeamsScreen extends StatefulWidget {
  const SportsMyTeamsScreen({
    super.key,
    required this.leagues,
    required this.follows,
    required this.hideScores,
    required this.matchGames,
    required this.onActivate,
    required this.onMenu,
  });

  /// The user's Sports leagues (for "+ Add team" → Standings).
  final List<SportsLeague> leagues;
  final SportsFollows follows;
  final bool hideScores;
  final Future<Map<String, List<ChannelMatch>>> Function(List<SportsGame>)
      matchGames;
  final SportsGameAction onActivate;
  final SportsGameAction onMenu;

  @override
  State<SportsMyTeamsScreen> createState() => _SportsMyTeamsScreenState();
}

class _SportsMyTeamsScreenState extends State<SportsMyTeamsScreen>
    with RouteAware {
  static const double _teamRowHeight = 78;
  static const double _gameRowHeight = 76;
  static const _addKey = 'add';

  final Map<String, SportsTeamSchedule?> _schedules = {};
  final Set<String> _loadingTeams = {};
  final Map<String, SportsStandings?> _standings = {};
  final Map<String, Map<String, List<ChannelMatch>>> _matches = {};
  final Set<String> _matching = {};

  int _selected = 0;
  int _zone = 0; // 0 teams, 1 games
  int _gameRow = 0;
  final Map<String, FocusNode> _teamNodes = {};
  final Map<String, FocusNode> _gameNodes = {};
  final ScrollController _teamScroll = ScrollController();
  final ScrollController _gameScroll = ScrollController();

  Timer? _pollTimer;
  bool _covered = false;

  List<FollowedTeam> get _teams => [
        for (final t in widget.follows.teams)
          if (sportsLeagueById(t.leagueId) != null) t,
      ];

  /// Team rows + the "+ Add team" row.
  List<String> get _rowKeys => [for (final t in _teams) t.key, _addKey];

  FollowedTeam? get _selectedTeam {
    final teams = _teams;
    return _selected < teams.length ? teams[_selected] : null;
  }

  @override
  void initState() {
    super.initState();
    unawaited(_loadAll());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusTeam(0);
    });
    // Live scores and "next game" move on; the service's own freshness
    // window decides whether a tick really hits the network.
    _pollTimer = Timer.periodic(const Duration(seconds: 60), (_) {
      if (!_covered && mounted) unawaited(_loadAll());
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route is PageRoute<void>) appRouteObserver.subscribe(this, route);
  }

  @override
  void didPushNext() => _covered = true;

  @override
  void didPopNext() {
    _covered = false;
    // Back from Standings (teams may have been added) or the player.
    setState(() {
      _selected = _selected.clamp(0, _teams.length);
    });
    unawaited(_loadAll());
  }

  @override
  void dispose() {
    appRouteObserver.unsubscribe(this);
    _pollTimer?.cancel();
    for (final n in _teamNodes.values) {
      n.dispose();
    }
    for (final n in _gameNodes.values) {
      n.dispose();
    }
    _teamScroll.dispose();
    _gameScroll.dispose();
    super.dispose();
  }

  // ----------------------------------------------------------------- data

  Future<void> _loadAll() async {
    await Future.wait([for (final t in _teams) _loadTeam(t)]);
  }

  Future<void> _loadTeam(FollowedTeam t) async {
    final league = sportsLeagueById(t.leagueId);
    if (league == null) return;
    if (!_schedules.containsKey(t.key)) {
      setState(() => _loadingTeams.add(t.key));
    }
    final results = await Future.wait([
      SportsService.instance.teamSchedule(league, t.teamId),
      SportsService.instance.standings(league),
    ]);
    if (!mounted) return;
    setState(() {
      _loadingTeams.remove(t.key);
      final schedule = results[0] as SportsTeamSchedule?;
      // A failed refresh keeps what was shown.
      if (schedule != null || !_schedules.containsKey(t.key)) {
        _schedules[t.key] = schedule;
      }
      _standings[league.id] =
          (results[1] as SportsStandings?) ?? _standings[league.id];
    });
    if (_selectedTeam == t) unawaited(_matchTeam(t));
  }

  /// Channel matches for [t]'s next two weeks. Rerun after every load
  /// (scores change the game objects; picks may have changed).
  Future<void> _matchTeam(FollowedTeam t) async {
    final games = _schedules[t.key]?.upcoming() ?? const <SportsGame>[];
    if (games.isEmpty || _matching.contains(t.key)) return;
    setState(() => _matching.add(t.key));
    try {
      final matches = await widget.matchGames(games);
      if (mounted) setState(() => _matches[t.key] = matches);
    } catch (_) {
      // An interrupted guide check must not erase the last completed result.
    } finally {
      if (mounted) setState(() => _matching.remove(t.key));
    }
  }

  // ---------------------------------------------------------------- focus

  FocusNode _teamNode(String key) =>
      _teamNodes[key] ??= FocusNode(debugLabel: 'myteams-team-$key');

  FocusNode _gameNode(String key) =>
      _gameNodes[key] ??= FocusNode(debugLabel: 'myteams-game-$key');

  List<SportsGame> get _games {
    final t = _selectedTeam;
    return t == null
        ? const []
        : (_schedules[t.key]?.upcoming() ?? const <SportsGame>[]);
  }

  void _focusTeam(int i) {
    final keys = _rowKeys;
    final index = i.clamp(0, keys.length - 1);
    _teamNode(keys[index]).requestFocus();
    _keepVisible(_teamScroll, index, _teamRowHeight);
  }

  void _focusGame(int i) {
    final games = _games;
    if (games.isEmpty) return;
    _gameRow = i.clamp(0, games.length - 1);
    _gameNode(SportsChannelPicks.eventKey(games[_gameRow])).requestFocus();
    _keepVisible(_gameScroll, _gameRow, _gameRowHeight);
  }

  /// Plain offset maths with jumpTo — never animateTo on a list (§10).
  void _keepVisible(ScrollController c, int i, double extent) {
    if (!c.hasClients) return;
    final pos = c.position;
    final top = i * extent;
    final bottom = top + extent;
    if (top < pos.pixels) {
      c.jumpTo(top);
    } else if (bottom > pos.pixels + pos.viewportDimension) {
      c.jumpTo(
          (bottom - pos.viewportDimension).clamp(0.0, pos.maxScrollExtent));
    }
  }

  void _moveVertical(int delta) {
    if (_zone == 0) {
      final next = _selected + delta;
      if (next >= 0 && next < _rowKeys.length) _focusTeam(next);
    } else {
      final next = _gameRow + delta;
      if (next >= 0 && next < _games.length) _focusGame(next);
    }
  }

  void _moveHorizontal(int delta) {
    if (delta > 0 && _zone == 0 && _games.isNotEmpty) {
      _focusGame(0);
    } else if (delta < 0 && _zone == 1) {
      _focusTeam(_selected);
    }
  }

  void _onTeamFocus(int i) {
    _zone = 0;
    if (_selected == i) return;
    setState(() {
      _selected = i;
      _gameRow = 0;
    });
    if (_gameScroll.hasClients) _gameScroll.jumpTo(0);
    final t = _selectedTeam;
    if (t != null && !_matches.containsKey(t.key)) unawaited(_matchTeam(t));
  }

  // -------------------------------------------------------------- actions

  Future<void> _addTeam() async {
    if (widget.leagues.isEmpty) return;
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => SportsStandingsScreen(
        leagues: widget.leagues,
        initialLeague: widget.leagues.first,
        follows: widget.follows,
        addingTeam: true,
      ),
    ));
  }

  Future<void> _unfollow(FollowedTeam t) async {
    final schedule = _schedules[t.key];
    final team = schedule?.team ??
        SportsTeam(
            id: t.teamId,
            name: tr('this team'),
            shortName: '',
            abbreviation: '');
    final confirmed =
        await showSportsFollowDialog(context, team: team, followed: true);
    if (!confirmed || !mounted) return;
    await widget.follows.unfollow(t.leagueId, t.teamId);
    if (!mounted) return;
    setState(() {
      _selected = _selected.clamp(0, _teams.length);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusTeam(_selected);
    });
  }

  Future<void> _runGame(SportsGameAction action, SportsGame g) async {
    final t = _selectedTeam;
    final matches = t == null
        ? const <ChannelMatch>[]
        : (_matches[t.key]?[SportsChannelPicks.eventKey(g)] ??
            const <ChannelMatch>[]);
    await action(g, matches);
    // A pick may have been made or forgotten.
    if (mounted && t != null) unawaited(_matchTeam(t));
  }

  // ---------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final team = _selectedTeam;
    final schedule = team == null ? null : _schedules[team.key];
    return SportsScreenFrame(
        child: withTvThemeIfNeeded(
      context,
      (context) => Stack(
        children: [
          const Positioned.fill(child: SettingsGradientBackground()),
          Scaffold(
            backgroundColor: Colors.transparent,
            body: SafeArea(
              child: CallbackShortcuts(
                bindings: {
                  const SingleActivator(LogicalKeyboardKey.arrowUp): () =>
                      _moveVertical(-1),
                  const SingleActivator(LogicalKeyboardKey.arrowDown): () =>
                      _moveVertical(1),
                  const SingleActivator(LogicalKeyboardKey.arrowLeft): () =>
                      _moveHorizontal(-1),
                  const SingleActivator(LogicalKeyboardKey.arrowRight): () =>
                      _moveHorizontal(1),
                },
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(24, 12, 24, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        height: 44,
                        child: Row(
                          children: [
                            const SportsBackButton(),
                            Text(tr('My Teams'),
                                style: Theme.of(context)
                                    .textTheme
                                    .headlineSmall
                                    ?.copyWith(fontWeight: FontWeight.w800)),
                            const SizedBox(width: 16),
                            Expanded(
                              child: Text(
                                  tr(
                                      'Hold OK on a team to unfollow · on a game to pick the channel'),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      color: Colors.white38, fontSize: 12)),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 8),
                      Expanded(
                        // Phone in portrait: team list on top, details
                        // below, instead of side by side.
                        child: _narrow(context)
                            ? Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Flexible(flex: 2, child: _buildTeamList()),
                                  const SizedBox(height: 12),
                                  Expanded(
                                      flex: 5,
                                      child: _buildDetails(team, schedule)),
                                ],
                              )
                            : Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  SizedBox(width: 300, child: _buildTeamList()),
                                  const SizedBox(width: 20),
                                  Expanded(
                                      child: _buildDetails(team, schedule)),
                                ],
                              ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    ));
  }

  /// Phone in portrait — see [build].
  static bool _narrow(BuildContext context) =>
      MediaQuery.sizeOf(context).width < 600;

  Widget _buildTeamList() {
    final teams = _teams;
    return ListView.builder(
      controller: _teamScroll,
      itemExtent: _teamRowHeight,
      padding: EdgeInsets.zero,
      itemCount: teams.length + 1,
      itemBuilder: (context, i) {
        if (i == teams.length) {
          return _TeamRow(
            key: const ValueKey(_addKey),
            focusNode: _teamNode(_addKey),
            selected: false,
            onFocus: () => _onTeamFocus(i),
            onTap: _addTeam,
            child: Row(
              children: [
                Icon(Icons.add_circle_outline,
                    size: 34, color: Theme.of(context).colorScheme.primary),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(tr('Add team'),
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                              fontWeight: FontWeight.w700)),
                      Text(tr('Follow one from Standings'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: Colors.white54, fontSize: 12)),
                    ],
                  ),
                ),
              ],
            ),
          );
        }
        final t = teams[i];
        final s = _schedules[t.key];
        final league = sportsLeagueById(t.leagueId)!;
        return HoldToActivate(
          key: ValueKey(t.key),
          onTap: () => _moveHorizontal(1),
          onHold: () => _unfollow(t),
          child: _TeamRow(
            focusNode: _teamNode(t.key),
            selected: i == _selected,
            onFocus: () => _onTeamFocus(i),
            onTap: () => _teamNode(t.key).requestFocus(),
            child: Row(
              children: [
                SportsLogo(
                    url: s?.team.logoUrl,
                    size: 44,
                    fallback: s?.team.abbreviation ?? league.shortName,
                    color: s?.team.color),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                                s?.team.name ??
                                    (_loadingTeams.contains(t.key)
                                        ? tr('Loading…')
                                        : tr('Could not load')),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 16,
                                    fontWeight: FontWeight.w700)),
                          ),
                          const SizedBox(width: 6),
                          Text(league.shortName,
                              style: const TextStyle(
                                  color: Colors.white38, fontSize: 11)),
                        ],
                      ),
                      if (s?.team.record != null)
                        Text(s!.team.record!,
                            style: const TextStyle(
                                color: Colors.white60, fontSize: 13)),
                      if (s?.nextGame case final g?)
                        _NextGameLine(
                            game: g,
                            teamId: s!.team.id,
                            hideScores: widget.hideScores),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildDetails(FollowedTeam? t, SportsTeamSchedule? s) {
    if (t == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.star_border, size: 48, color: Colors.white38),
            const SizedBox(height: 10),
            Text(
                _teams.isEmpty
                    ? tr('Follow your teams to see them here')
                    : tr('Follow another team'),
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70, fontSize: 17)),
            const SizedBox(height: 4),
            Text(
                tr('Add team opens Standings: hold OK on a team to follow it.'),
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white38, fontSize: 13)),
          ],
        ),
      );
    }
    if (s == null) {
      return Center(
        child: _loadingTeams.contains(t.key)
            ? const CircularProgressIndicator()
            : Text(tr('This team could not be loaded. Check the connection.'),
                style: const TextStyle(color: Colors.white70, fontSize: 16)),
      );
    }
    final team = s.team;
    final last = s.lastGame;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            SportsLogo(
                url: team.logoUrl,
                size: 84,
                fallback: team.abbreviation,
                color: team.color),
            const SizedBox(width: 18),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(team.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 28,
                          fontWeight: FontWeight.w800,
                          color: Colors.white)),
                  Text(
                      [
                        if (team.record != null) team.record!,
                        if (s.standingSummary != null)
                          trSports(s.standingSummary!),
                      ].join('  ·  '),
                      style:
                          const TextStyle(fontSize: 16, color: Colors.white70)),
                  if (last != null)
                    Text(_lastGameLabel(last, team.id, widget.hideScores),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 14, color: Colors.white54)),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Expanded(
          child: Flex(
            direction: _narrow(context) ? Axis.vertical : Axis.horizontal,
            crossAxisAlignment: _narrow(context)
                ? CrossAxisAlignment.stretch
                : CrossAxisAlignment.start,
            children: [
              Expanded(flex: 3, child: _buildGames(t, s)),
              const SizedBox(width: 20, height: 12),
              _narrow(context)
                  ? Expanded(
                      flex: 2,
                      child: _MiniTable(
                        standings: _standings[s.league.id],
                        league: s.league,
                        teamId: team.id,
                      ),
                    )
                  : SizedBox(
                      width: 310,
                      child: _MiniTable(
                        standings: _standings[s.league.id],
                        league: s.league,
                        teamId: team.id,
                      ),
                    ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildGames(FollowedTeam t, SportsTeamSchedule s) {
    final games = s.upcoming();
    final matches = _matches[t.key];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(tr('Next 2 weeks'),
            style: const TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w700,
                color: Colors.white)),
        const SizedBox(height: 6),
        Expanded(
          child: games.isEmpty
              ? Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(tr('No games in the next two weeks.'),
                      style:
                          const TextStyle(color: Colors.white54, fontSize: 15)),
                )
              : ListView.builder(
                  controller: _gameScroll,
                  itemExtent: _gameRowHeight,
                  padding: EdgeInsets.zero,
                  itemCount: games.length,
                  itemBuilder: (context, i) {
                    final g = games[i];
                    final key = SportsChannelPicks.eventKey(g);
                    return HoldToActivate(
                      key: ValueKey(key),
                      onTap: () => _runGame(widget.onActivate, g),
                      onHold: () => _runGame(widget.onMenu, g),
                      child: _GameRow(
                        focusNode: _gameNode(key),
                        game: g,
                        teamId: s.team.id,
                        match: matches?[key]?.firstOrNull,
                        matching: _matching.contains(t.key) || matches == null,
                        hideScores: widget.hideScores,
                        onFocus: () {
                          _zone = 1;
                          _gameRow = i;
                        },
                        onTap: () => _runGame(widget.onActivate, g),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

// =================================================================== helpers

/// "vs BOS" when [teamId] is at home, "at TOR" away.
String _opponentLabel(SportsGame g, String teamId) {
  final home = g.home.id == teamId;
  final other = home ? g.away : g.home;
  return '${home ? tr('vs') : tr('at')} ${other.shortName}';
}

String _whenLabel(DateTime utc) {
  final local = utc.toLocal();
  final now = DateTime.now();
  final time = TimeFormat.hm.format(local);
  final diff = sportsCalendarDayOffset(now, local);
  if (diff == 0) return tr('Today {time}', {'time': time});
  if (diff == 1) return tr('Tomorrow {time}', {'time': time});
  return '${DateFormat.MMMEd().format(local)} · $time';
}

/// "W 4-2 vs Bruins" (scores hidden: "Final vs Bruins").
String _lastGameLabel(SportsGame g, String teamId, bool hideScores) {
  final opponent = _opponentLabel(g, teamId);
  if (hideScores) {
    return tr('Last game: {opponent} · Final', {'opponent': opponent});
  }
  final mineTeam = g.home.id == teamId ? g.home : g.away;
  final otherTeam = g.home.id == teamId ? g.away : g.home;
  final mine = int.tryParse(mineTeam.score ?? '');
  final other = int.tryParse(otherTeam.score ?? '');
  if (mine == null || other == null) {
    return tr('Last game: {opponent} · Final', {'opponent': opponent});
  }
  final result = mine > other ? 'W' : (mine < other ? 'L' : 'D');
  return tr('Last game: {result} {mine}-{other} {opponent}', {
    'result': tr(result),
    'mine': mine,
    'other': other,
    'opponent': opponent
  });
}

class _NextGameLine extends StatelessWidget {
  const _NextGameLine(
      {required this.game, required this.teamId, required this.hideScores});
  final SportsGame game;
  final String teamId;
  final bool hideScores;

  @override
  Widget build(BuildContext context) {
    final live = game.state == GameState.live;
    final mine = game.home.id == teamId ? game.home : game.away;
    final other = game.home.id == teamId ? game.away : game.home;
    final text = live
        ? [
            tr('LIVE'),
            if (!hideScores) '${mine.score ?? '-'}-${other.score ?? '-'}',
            _opponentLabel(game, teamId),
          ].join(' ')
        : '${_whenLabel(game.start)} ${_opponentLabel(game, teamId)}';
    return Text(text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: live
                ? Colors.redAccent
                : Theme.of(context).colorScheme.primary));
  }
}

class _FocusBox extends StatelessWidget {
  const _FocusBox(
      {required this.focused, required this.selected, required this.child});
  final bool focused;
  final bool selected;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      margin: const EdgeInsets.symmetric(vertical: 3),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color:
            focused ? scheme.primaryContainer : scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(
          color: focused
              ? scheme.primary
              : (selected
                  ? scheme.primary.withValues(alpha: 0.4)
                  : Colors.transparent),
          width: focused ? 2.5 : 1,
        ),
      ),
      child: child,
    );
  }
}

class _TeamRow extends StatefulWidget {
  const _TeamRow({
    super.key,
    required this.focusNode,
    required this.selected,
    required this.onFocus,
    required this.onTap,
    required this.child,
  });

  final FocusNode focusNode;
  final bool selected;
  final VoidCallback onFocus;
  final VoidCallback onTap;
  final Widget child;

  @override
  State<_TeamRow> createState() => _TeamRowState();
}

class _TeamRowState extends State<_TeamRow> {
  late bool _focused = widget.focusNode.hasFocus;

  @override
  void didUpdateWidget(_TeamRow old) {
    super.didUpdateWidget(old);
    if (old.focusNode != widget.focusNode) {
      _focused = widget.focusNode.hasFocus;
    }
  }

  @override
  Widget build(BuildContext context) {
    return InkWell(
      focusNode: widget.focusNode,
      borderRadius: BorderRadius.circular(4),
      onTap: widget.onTap,
      onFocusChange: (f) {
        setState(() => _focused = f);
        if (f) widget.onFocus();
      },
      child: _FocusBox(
          focused: _focused, selected: widget.selected, child: widget.child),
    );
  }
}

class _GameRow extends StatefulWidget {
  const _GameRow({
    required this.focusNode,
    required this.game,
    required this.teamId,
    required this.match,
    required this.matching,
    required this.hideScores,
    required this.onFocus,
    required this.onTap,
  });

  final FocusNode focusNode;
  final SportsGame game;
  final String teamId;
  final ChannelMatch? match;
  final bool matching;
  final bool hideScores;
  final VoidCallback onFocus;
  final VoidCallback onTap;

  @override
  State<_GameRow> createState() => _GameRowState();
}

class _GameRowState extends State<_GameRow> {
  late bool _focused = widget.focusNode.hasFocus;

  @override
  void didUpdateWidget(_GameRow old) {
    super.didUpdateWidget(old);
    if (old.focusNode != widget.focusNode) {
      _focused = widget.focusNode.hasFocus;
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final g = widget.game;
    final live = g.state == GameState.live;
    final home = g.home.id == widget.teamId;
    final opponent = home ? g.away : g.home;
    final mine = home ? g.home : g.away;
    final when = live
        ? [
            if (g.statusText.isNotEmpty) trSports(g.statusText) else tr('LIVE'),
            if (!widget.hideScores)
              '${mine.score ?? '-'}-${opponent.score ?? '-'}',
          ].join('  ')
        : _whenLabel(g.start);
    return InkWell(
      focusNode: widget.focusNode,
      borderRadius: BorderRadius.circular(4),
      onTap: widget.onTap,
      onFocusChange: (f) {
        setState(() => _focused = f);
        if (f) widget.onFocus();
      },
      child: _FocusBox(
        focused: _focused,
        selected: false,
        // Two lines fit the opponent and channel in a narrow TV column.
        child: Row(
          children: [
            SportsLogo(
                url: opponent.logoUrl,
                size: 38,
                fallback: opponent.abbreviation,
                color: opponent.color),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${home ? tr('vs') : tr('at')} ${opponent.shortName}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: Colors.white)),
                  Row(
                    children: [
                      if (live)
                        Container(
                          width: 7,
                          height: 7,
                          margin: const EdgeInsets.only(right: 6),
                          decoration: const BoxDecoration(
                              shape: BoxShape.circle, color: Colors.redAccent),
                        ),
                      Flexible(
                        child: Text(when,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color:
                                    live ? Colors.redAccent : Colors.white70)),
                      ),
                    ],
                  ),
                  Row(
                    children: [
                      Icon(
                          widget.match != null
                              ? Icons.live_tv
                              : Icons.add_circle_outline,
                          size: 13,
                          color: widget.match != null
                              ? scheme.primary
                              : Colors.white38),
                      const SizedBox(width: 5),
                      Flexible(
                        child: Text(
                          widget.match?.channel.name ??
                              (widget.matching
                                  ? tr('Looking…')
                                  : tr('Pick a channel')),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 12,
                              color: widget.match != null
                                  ? scheme.primary
                                  : Colors.white38),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A few rows of the team's table around its own place (not focusable).
class _MiniTable extends StatelessWidget {
  const _MiniTable(
      {required this.standings, required this.league, required this.teamId});
  final SportsStandings? standings;
  final SportsLeague league;
  final String teamId;

  /// The deciding columns per sport — the full set doesn't fit here.
  List<String> get _stats {
    if (league.soccer) {
      return const ['gamesPlayed', 'pointDifferential', 'points'];
    }
    if (league.id == 'college-football') {
      return const ['overall', 'pointDifferential'];
    }
    return switch (league.espnPath.split('/').first) {
      'hockey' => const ['wins', 'losses', 'otLosses', 'points'],
      'football' => const ['wins', 'losses', 'ties', 'winPercent'],
      _ => const ['wins', 'losses', 'winPercent', 'gamesBehind'],
    };
  }

  @override
  Widget build(BuildContext context) {
    SportsStandingGroup? group;
    var index = -1;
    for (final g in standings?.groups ?? const <SportsStandingGroup>[]) {
      final i = g.rows.indexWhere((r) => r.team.id == teamId);
      if (i >= 0) {
        group = g;
        index = i;
        break;
      }
    }
    if (group == null) return const SizedBox();
    final all = sportsStandingColumns(league);
    final columns = [
      for (final stat in _stats)
        if (all.where((c) => c.stat == stat).firstOrNull case final c?) c,
    ];
    final from = (index - 2).clamp(0, (group.rows.length - 5).clamp(0, 999));
    final rows = group.rows.skip(from).take(5).toList();
    const head = TextStyle(
        color: Colors.white54, fontSize: 11, fontWeight: FontWeight.w700);
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white10),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(group.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          Row(
            children: [
              const SizedBox(width: 26, child: Text('#', style: head)),
              Expanded(child: Text(tr('TEAM'), style: head)),
              for (final c in columns)
                SizedBox(
                    width: 36,
                    child: Text(tr(c.label),
                        textAlign: TextAlign.center, style: head)),
            ],
          ),
          for (final r in rows)
            Container(
              height: 32,
              margin: const EdgeInsets.only(top: 3),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(6),
                color: r.team.id == teamId
                    ? scheme.primary.withValues(alpha: 0.18)
                    : null,
                border: r.team.id == teamId
                    ? Border.all(color: scheme.primary.withValues(alpha: 0.6))
                    : null,
              ),
              child: Row(
                children: [
                  SizedBox(
                    width: 26,
                    child: Text('${r.position}',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 13,
                            fontWeight: FontWeight.w700)),
                  ),
                  SportsLogo(
                      url: r.team.logoUrl,
                      size: 22,
                      fallback: r.team.abbreviation,
                      color: r.team.color),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(r.team.shortName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                            fontWeight: r.team.id == teamId
                                ? FontWeight.w800
                                : FontWeight.w500)),
                  ),
                  for (final c in columns)
                    SizedBox(
                      width: 36,
                      child: Text(r.stat(c.stat),
                          textAlign: TextAlign.center,
                          maxLines: 1,
                          style: TextStyle(
                              color: c.stat == 'points'
                                  ? Colors.white
                                  : Colors.white70,
                              fontSize: 13,
                              fontWeight: c.stat == 'points'
                                  ? FontWeight.w800
                                  : FontWeight.w500,
                              fontFeatures: const [
                                FontFeature.tabularFigures()
                              ])),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
