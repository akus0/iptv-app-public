import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/sports.dart';
import '../services/app_preferences.dart';
import '../services/sports_follows.dart';
import '../services/sports_service.dart';
import '../utils/tv_theme.dart';
import '../widgets/hold_to_activate.dart';
import '../widgets/settings_scaffold.dart';
import '../widgets/sports_widgets.dart';
import '../l10n/l10n.dart';

/// League standings with explicit navigation between league, group and table zones.
/// Left/Right in the table switches groups; activating a team offers follow/unfollow.
class SportsStandingsScreen extends StatefulWidget {
  const SportsStandingsScreen({
    super.key,
    required this.leagues,
    required this.initialLeague,
    required this.follows,
    this.addingTeam = false,
  });

  final List<SportsLeague> leagues;
  final SportsLeague initialLeague;
  final SportsFollows follows;

  /// Opened from My Teams' "+ Add team": the follow hint is spelled out
  /// above the table instead of the quiet footer.
  final bool addingTeam;

  @override
  State<SportsStandingsScreen> createState() => _SportsStandingsScreenState();
}

class SportsStandingColumn {
  const SportsStandingColumn(this.label, this.stat, {this.width = 46});
  final String label;
  final String stat;
  final double width;
}

/// Columns per sport, most important first — narrow screens keep a prefix.
List<SportsStandingColumn> sportsStandingColumns(SportsLeague league) {
  const l10 = SportsStandingColumn('L10', 'Last Ten Games', width: 54);
  const strk = SportsStandingColumn('STRK', 'streak', width: 54);
  if (league.soccer) {
    return const [
      SportsStandingColumn('GP', 'gamesPlayed'),
      SportsStandingColumn('W', 'wins'),
      SportsStandingColumn('D', 'ties'),
      SportsStandingColumn('L', 'losses'),
      SportsStandingColumn('GD', 'pointDifferential', width: 50),
      SportsStandingColumn('PTS', 'points', width: 50),
    ];
  }
  if (league.kind == SportsKind.racing) {
    return const [SportsStandingColumn('PTS', 'championshipPts', width: 60)];
  }
  final sport = league.espnPath.split('/').first;
  switch (sport) {
    case 'hockey':
      return const [
        SportsStandingColumn('GP', 'gamesPlayed'),
        SportsStandingColumn('W', 'wins'),
        SportsStandingColumn('L', 'losses'),
        SportsStandingColumn('OTL', 'otLosses'),
        SportsStandingColumn('PTS', 'points', width: 50),
        SportsStandingColumn('DIFF', 'pointDifferential', width: 54),
        strk,
        l10,
      ];
    case 'football' when league.id == 'college-football':
      return const [
        SportsStandingColumn('REC', 'overall', width: 58),
        SportsStandingColumn('PF', 'pointsFor', width: 50),
        SportsStandingColumn('PA', 'pointsAgainst', width: 50),
        SportsStandingColumn('DIFF', 'pointDifferential', width: 54),
        strk,
        SportsStandingColumn('HOME', 'Home', width: 58),
        SportsStandingColumn('AWAY', 'Away', width: 58),
      ];
    case 'football':
      return const [
        SportsStandingColumn('W', 'wins'),
        SportsStandingColumn('L', 'losses'),
        SportsStandingColumn('T', 'ties'),
        SportsStandingColumn('PCT', 'winPercent', width: 58),
        SportsStandingColumn('DIFF', 'pointDifferential', width: 54),
        strk,
        SportsStandingColumn('HOME', 'Home', width: 58),
        SportsStandingColumn('AWAY', 'Road', width: 58),
      ];
    default: // basketball, baseball
      return const [
        SportsStandingColumn('W', 'wins'),
        SportsStandingColumn('L', 'losses'),
        SportsStandingColumn('PCT', 'winPercent', width: 58),
        SportsStandingColumn('GB', 'gamesBehind', width: 50),
        strk,
        l10,
        SportsStandingColumn('HOME', 'Home', width: 58),
        SportsStandingColumn('AWAY', 'Road', width: 58),
      ];
  }
}

class _SportsStandingsScreenState extends State<SportsStandingsScreen> {
  late final List<SportsLeague> _leagues;
  static const double _rowHeight = 44;

  late SportsLeague _league;
  int _groupIndex = 0;
  SportsStandings? _standings;
  bool _loading = true;
  int _loadToken = 0;

  int _zone = 2;
  int _row = 0;
  final Map<String, FocusNode> _chipNodes = {};
  final List<FocusNode> _rowNodes = [];
  final ScrollController _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    // Cups ESPN has no table for are left out (see SportsLeague.hasStandings).
    // Racing tables list drivers, who can't be followed — not offered
    // when the point is adding a team.
    bool usable(SportsLeague l) =>
        l.hasStandings && !(widget.addingTeam && l.kind != SportsKind.team);
    _leagues = [
      for (final l in widget.leagues)
        if (usable(l)) l
    ];
    if (_leagues.isEmpty) {
      _leagues = [
        for (final l in kSportsLeagues)
          if (l.hasStandings) l
      ];
    }
    _league =
        usable(widget.initialLeague) ? widget.initialLeague : _leagues.first;
    unawaited(_load());
  }

  @override
  void dispose() {
    for (final n in _chipNodes.values) {
      n.dispose();
    }
    for (final n in _rowNodes) {
      n.dispose();
    }
    _scroll.dispose();
    super.dispose();
  }

  FocusNode _chipNode(String id) =>
      _chipNodes[id] ??= FocusNode(debugLabel: 'standings-chip-$id');

  FocusNode _rowNode(int i) {
    while (_rowNodes.length <= i) {
      _rowNodes.add(FocusNode(debugLabel: 'standings-row-${_rowNodes.length}'));
    }
    return _rowNodes[i];
  }

  SportsStandingGroup? get _group {
    final groups = _standings?.groups ?? const [];
    if (groups.isEmpty) return null;
    return groups[_groupIndex.clamp(0, groups.length - 1)];
  }

  bool get _hasGroupBar => (_standings?.groups.length ?? 0) > 1;

  Future<void> _load() async {
    final token = ++_loadToken;
    setState(() => _loading = true);
    final result = await SportsService.instance.standings(_league);
    if (!mounted || token != _loadToken) return;
    final firstLoad = _standings == null;
    setState(() {
      _standings = result;
      _groupIndex = 0;
      _row = 0;
      _loading = false;
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
    if (firstLoad) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _focusZone(_group != null ? 2 : 0);
      });
    }
  }

  // ---------------------------------------------------------------- focus

  void _focusZone(int zone) {
    if (zone == 1 && !_hasGroupBar) zone = 2;
    if (zone == 2 && _group == null) zone = _hasGroupBar ? 1 : 0;
    if (zone == 0) {
      _chipNode('league:${_league.id}').requestFocus();
    } else if (zone == 1) {
      _chipNode('group:$_groupIndex').requestFocus();
    } else {
      _focusRow(_row);
    }
    _zone = zone;
  }

  void _focusRow(int i) {
    final rows = _group?.rows.length ?? 0;
    if (rows == 0) return;
    _row = i.clamp(0, rows - 1);
    _rowNode(_row).requestFocus();
    _keepRowVisible(_row);
  }

  /// Plain offset maths with jumpTo — never animateTo on a list (§10).
  void _keepRowVisible(int i) {
    if (!_scroll.hasClients) return;
    final pos = _scroll.position;
    final top = i * _rowHeight;
    final bottom = top + _rowHeight;
    if (top < pos.pixels) {
      _scroll.jumpTo(top);
    } else if (bottom > pos.pixels + pos.viewportDimension) {
      _scroll.jumpTo(
          (bottom - pos.viewportDimension).clamp(0.0, pos.maxScrollExtent));
    }
  }

  void _moveVertical(int delta) {
    if (_zone == 2) {
      final next = _row + delta;
      if (next < 0) {
        _focusZone(_hasGroupBar ? 1 : 0);
      } else if (next < (_group?.rows.length ?? 0)) {
        _focusRow(next);
      }
      return;
    }
    final target = _zone + delta;
    if (target == 1 && !_hasGroupBar) {
      _focusZone(delta > 0 ? 2 : 0);
    } else if (target >= 0 && target <= 2) {
      _focusZone(target);
    }
  }

  void _moveGroup(int delta) {
    final groups = _standings?.groups.length ?? 0;
    if (groups < 2) return;
    _setGroup((_groupIndex + delta) % groups, keepRowFocus: true);
  }

  // -------------------------------------------------------------- actions

  void _setLeague(SportsLeague league) {
    if (league.id == _league.id) return;
    setState(() {
      _league = league;
      _standings = null;
    });
    unawaited(_load());
  }

  void _setGroup(int index, {bool keepRowFocus = false}) {
    setState(() => _groupIndex = index);
    if (_scroll.hasClients) _scroll.jumpTo(0);
    if (keepRowFocus) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _focusRow(_row);
      });
    }
  }

  /// My Teams holds teams; a driver or constructor has no schedule there.
  bool get _canFollow => _league.kind == SportsKind.team;

  Future<void> _toggleFollow(SportsTeam team) async {
    if (!_canFollow) return;
    final follows = widget.follows;
    final followed = follows.isFollowed(_league.id, team.id);
    final confirmed =
        await showSportsFollowDialog(context, team: team, followed: followed);
    if (!confirmed || !mounted) return;
    if (followed) {
      await follows.unfollow(_league.id, team.id);
    } else {
      await follows.follow(_league.id, team.id);
    }
    if (mounted) setState(() {});
  }

  // ---------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
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
                },
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildLeagueBar(),
                      const SizedBox(height: 8),
                      _buildGroupBar(),
                      const SizedBox(height: 8),
                      if (widget.addingTeam) _buildAddHint(),
                      Expanded(child: _buildTable()),
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

  Widget _buildLeagueBar() {
    return SizedBox(
      height: 44,
      child: Row(
        children: [
          const SportsBackButton(),
          Text(tr('Standings'),
              style: Theme.of(context)
                  .textTheme
                  .headlineSmall
                  ?.copyWith(fontWeight: FontWeight.w800)),
          const SizedBox(width: 16),
          Expanded(
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                for (final l in _leagues)
                  SportsChip(
                    focusNode: _chipNode('league:${l.id}'),
                    label: l.name,
                    logoUrl: l.logoUrl,
                    selected: l.id == _league.id,
                    onFocus: () => _zone = 0,
                    onTap: () => _setLeague(l),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGroupBar() {
    final s = _standings;
    final groups = s?.groups ?? const <SportsStandingGroup>[];
    final label = [
      if (s?.season != null) s!.season!,
      if (s?.preseason ?? false) tr('Preseason'),
    ].join('  ·  ');
    return SizedBox(
      height: 40,
      child: Row(
        children: [
          Expanded(
            child: groups.length > 1
                ? ListView(
                    scrollDirection: Axis.horizontal,
                    children: [
                      for (var i = 0; i < groups.length; i++)
                        SportsChip(
                          focusNode: _chipNode('group:$i'),
                          label: groups[i].name,
                          selected: i == _groupIndex,
                          compact: true,
                          onFocus: () => _zone = 1,
                          onTap: () => _setGroup(i),
                        ),
                    ],
                  )
                : Align(
                    alignment: Alignment.centerLeft,
                    child: Text(groups.firstOrNull?.name ?? '',
                        style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                            color: Colors.white)),
                  ),
          ),
          if (label.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 12),
              child: Text(label,
                  style: const TextStyle(color: Colors.white54, fontSize: 13)),
            ),
        ],
      ),
    );
  }

  Widget _buildAddHint() {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: scheme.primary.withValues(alpha: 0.6)),
      ),
      child: Row(
        children: [
          Icon(Icons.star, size: 18, color: scheme.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
                tr('Pick a league above, then hold OK on a team to follow it. Back returns to My Teams.'),
                style: const TextStyle(color: Colors.white, fontSize: 14)),
          ),
        ],
      ),
    );
  }

  Widget _buildTable() {
    final group = _group;
    if (_loading && _standings == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (group == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off, size: 44, color: Colors.white38),
            const SizedBox(height: 10),
            Text(tr('Standings could not be loaded. Check the connection.'),
                style: const TextStyle(color: Colors.white70, fontSize: 16)),
          ],
        ),
      );
    }
    return LayoutBuilder(builder: (context, constraints) {
      // Keep as many columns as fit beside a readable team name.
      final all = sportsStandingColumns(_league);
      final columns = <SportsStandingColumn>[];
      var used = 36.0 + 40 + 160; // position + logo + minimum name width
      // Touch screens (a phone in portrait) keep every column and let the
      // table scroll sideways instead; a remote can't scroll sideways
      // (Left/Right switch conference), so TV boxes still drop columns.
      final scrollSideways = !context.read<AppPreferences>().isTelevision;
      for (final c in all) {
        if (!scrollSideways && used + c.width > constraints.maxWidth) break;
        used += c.width;
        columns.add(c);
      }
      // Slack for the row's own padding/accent bar beyond the estimate.
      final tableWidth =
          used + 40 > constraints.maxWidth ? used + 40 : constraints.maxWidth;
      final notes = <String, String>{};
      for (final r in group.rows) {
        if (r.note != null && r.noteColor != null) {
          notes.putIfAbsent(r.note!, () => r.noteColor!);
        }
      }
      return CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.arrowLeft): () =>
              _moveGroup(-1),
          const SingleActivator(LogicalKeyboardKey.arrowRight): () =>
              _moveGroup(1),
        },
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: SizedBox(
                  width: tableWidth,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _HeaderRow(columns: columns),
                      Expanded(
                        child: ListView.builder(
                          controller: _scroll,
                          itemExtent: _rowHeight,
                          padding: EdgeInsets.zero,
                          itemCount: group.rows.length,
                          itemBuilder: (context, i) {
                            final team = group.rows[i].team;
                            return HoldToActivate(
                              key: ValueKey(i),
                              onTap: () => _toggleFollow(team),
                              onHold: () => _toggleFollow(team),
                              child: _StandingRow(
                                focusNode: _rowNode(i),
                                row: group.rows[i],
                                columns: columns,
                                followed: widget.follows
                                    .isFollowed(_league.id, team.id),
                                onFocus: () {
                                  _zone = 2;
                                  _row = i;
                                },
                              ),
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            if (notes.isNotEmpty) _Legend(notes: notes),
            // Icons, not ◀ ▶ characters: Android draws those as emoji.
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                runSpacing: 4,
                children: [
                  if (_hasGroupBar) ...[
                    const Icon(Icons.chevron_left,
                        size: 16, color: Colors.white38),
                    const Icon(Icons.chevron_right,
                        size: 16, color: Colors.white38),
                    const SizedBox(width: 4),
                    Text(
                        _canFollow
                            ? tr('switch conference')
                            : tr('switch table'),
                        style: const TextStyle(
                            color: Colors.white38, fontSize: 12)),
                    const SizedBox(width: 20),
                  ],
                  if (_canFollow) ...[
                    const Icon(Icons.star, size: 14, color: Colors.white38),
                    const SizedBox(width: 4),
                    Text(tr('Hold OK on a team to follow it (My Teams)'),
                        style: const TextStyle(
                            color: Colors.white38, fontSize: 12)),
                  ],
                ],
              ),
            ),
          ],
        ),
      );
    });
  }
}

class _HeaderRow extends StatelessWidget {
  const _HeaderRow({required this.columns});
  final List<SportsStandingColumn> columns;

  @override
  Widget build(BuildContext context) {
    const style = TextStyle(
        color: Colors.white54, fontSize: 12, fontWeight: FontWeight.w700);
    return SizedBox(
      height: 28,
      child: Row(
        children: [
          const SizedBox(width: 36, child: Text('#', style: style)),
          const SizedBox(width: 40),
          Expanded(child: Text(tr('TEAM'), style: style)),
          for (final c in columns)
            SizedBox(
              width: c.width,
              child:
                  Text(tr(c.label), textAlign: TextAlign.center, style: style),
            ),
        ],
      ),
    );
  }
}

class _StandingRow extends StatefulWidget {
  const _StandingRow({
    required this.focusNode,
    required this.row,
    required this.columns,
    required this.followed,
    required this.onFocus,
  });

  final FocusNode focusNode;
  final SportsStandingRow row;
  final List<SportsStandingColumn> columns;
  final bool followed;
  final VoidCallback onFocus;

  @override
  State<_StandingRow> createState() => _StandingRowState();
}

class _StandingRowState extends State<_StandingRow> {
  // Seeded from the node: switching conference keeps the same row node
  // focused, so no focus-change callback would ever arrive for a new row.
  late bool _focused = widget.focusNode.hasFocus;

  @override
  Widget build(BuildContext context) {
    final row = widget.row;
    final team = row.team;
    final zone = sportsTeamColor(row.noteColor);
    return Focus(
      focusNode: widget.focusNode,
      onFocusChange: (f) {
        setState(() => _focused = f);
        if (f) widget.onFocus();
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => widget.focusNode.requestFocus(),
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 2),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            color: _focused
                ? Theme.of(context).colorScheme.primaryContainer
                : (row.position.isOdd
                    ? Colors.white.withValues(alpha: 0.04)
                    : Colors.transparent),
            border: Border.all(
                color: _focused ? Colors.white : Colors.transparent,
                width: 1.5),
          ),
          child: Row(
            children: [
              // Qualification zone stripe (soccer) — the table's colour key.
              Container(
                width: 4,
                margin: const EdgeInsets.symmetric(vertical: 6),
                decoration: BoxDecoration(
                  color: zone ?? Colors.transparent,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              SizedBox(
                width: 32,
                child: Text('${row.position}',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        color: Colors.white70,
                        fontWeight: FontWeight.w700,
                        fontSize: 14)),
              ),
              SportsLogo(
                  url: team.logoUrl,
                  size: 30,
                  fallback: team.abbreviation,
                  color: team.color),
              const SizedBox(width: 10),
              Expanded(
                child: Row(
                  children: [
                    Flexible(
                      child: Text(team.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              color: Colors.white,
                              fontSize: 15,
                              fontWeight: _focused
                                  ? FontWeight.w700
                                  : FontWeight.w500)),
                    ),
                    if (widget.followed)
                      Padding(
                        padding: const EdgeInsets.only(left: 6),
                        child: Icon(Icons.star,
                            size: 16,
                            color: Theme.of(context).colorScheme.primary),
                      ),
                  ],
                ),
              ),
              for (final c in widget.columns)
                SizedBox(
                  width: c.width,
                  child: Text(
                    row.stat(c.stat),
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    style: TextStyle(
                      color: _statColor(c, row.stat(c.stat)),
                      fontSize: 14,
                      fontWeight: c.stat == 'points'
                          ? FontWeight.w800
                          : FontWeight.w500,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  static Color _statColor(SportsStandingColumn c, String v) {
    if (c.stat == 'streak') {
      if (v.startsWith('W')) return const Color(0xFF6FD08C);
      if (v.startsWith('L')) return const Color(0xFFE57373);
    }
    if (c.stat == 'points') return Colors.white;
    return Colors.white70;
  }
}

class _Legend extends StatelessWidget {
  const _Legend({required this.notes});
  final Map<String, String> notes;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Wrap(
        spacing: 16,
        runSpacing: 4,
        children: [
          for (final e in notes.entries)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    color: sportsTeamColor(e.value),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(width: 6),
                Text(e.key,
                    style:
                        const TextStyle(color: Colors.white60, fontSize: 12)),
              ],
            ),
        ],
      ),
    );
  }
}
