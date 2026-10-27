import 'dart:async';
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../utils/constants.dart';
import '../models/channel.dart';
import '../models/sports.dart';
import '../services/app_preferences.dart';
import '../services/playback_service.dart';
import '../services/sports_channel_matcher.dart';
import '../services/sports_match_session.dart';
import '../services/sports_follows.dart';
import '../services/sports_service.dart';
import '../utils/route_observer.dart';
import '../utils/sports_channel_filter.dart';
import '../utils/tv_theme.dart';
import '../widgets/hold_to_activate.dart';
import '../widgets/settings_scaffold.dart';
import '../widgets/sports_widgets.dart';
import '../l10n/l10n.dart';

/// Dense list of live games with details and playback actions. Retain games that finish
/// while the list is open so focused rows do not disappear. Navigate rows explicitly.
class SportsLiveListScreen extends StatefulWidget {
  const SportsLiveListScreen({
    super.key,
    required this.leagues,
    required this.day,
    required this.follows,
    required this.hideScores,
    required this.matchGames,
    required this.onWatch,
    required this.onMenu,
    this.channelFilter = SportsChannelFilter.all,
    this.scores,
    this.clock,
    this.initialMatches = const {},
    this.initialGames = const [],
  });

  /// What the hub already has, so the list (backdrop, rows, channels) is
  /// drawn from the first frame instead of after its own load and search.
  final Map<String, List<ChannelMatch>> initialMatches;
  final List<SportsGame> initialGames;

  final List<SportsLeague> leagues;
  final DateTime day;
  final SportsFollows follows;
  final bool hideScores;
  final SportsChannelFilter channelFilter;
  final SportsService? scores;
  final DateTime Function()? clock;
  final Future<Map<String, List<ChannelMatch>>> Function(List<SportsGame>)
      matchGames;

  /// Full-screen [Channel] (Sports' own player path).
  final Future<void> Function(Channel channel) onWatch;

  /// Hold OK: the hub's game menu (other channels / pick / forget), with
  /// [watch] playing the choice full screen from here.
  final Future<void> Function(SportsGame game, List<ChannelMatch> matches,
      Future<void> Function(Channel, SportsGame) watch) onMenu;

  @override
  State<SportsLiveListScreen> createState() => _SportsLiveListScreenState();
}

class _SportsLiveListScreenState extends State<SportsLiveListScreen>
    with RouteAware, WidgetsBindingObserver {
  static String _key(SportsGame g) => SportsChannelPicks.eventKey(g);

  final Set<String> _keys = {};
  late List<SportsGame> _games = _ordered(
      widget.initialGames.where((g) => g.state == GameState.live).toList());
  late Map<String, List<ChannelMatch>> _matches = widget.initialMatches;
  DateTime get _now => widget.clock?.call() ?? DateTime.now();
  late final _checkedAt = {
    for (final id in widget.initialMatches.keys) id: _now,
  };
  late bool _loading = _games.isEmpty;
  late bool _matching =
      _games.any((g) => !widget.initialMatches.containsKey(_key(g)));

  /// My Teams' games first, then the start order (like Live now).
  List<SportsGame> _ordered(List<SportsGame> games) => games
    ..sort((a, b) {
      final fa = widget.follows.involves(a) ? 0 : 1;
      final fb = widget.follows.involves(b) ? 0 : 1;
      return fa != fb ? fa - fb : a.start.compareTo(b.start);
    });

  final Map<String, FocusNode> _nodes = {};
  final Map<String, GlobalKey> _rowKeys = {};
  final ScrollController _scroll = ScrollController();
  int _focused = 0;

  Timer? _pollTimer;
  bool _covered = false;
  bool _backgrounded = false;
  bool get _active => mounted && !_covered && !_backgrounded;
  final _loadWork = SportsMatchWork();
  SportsService get _scores => widget.scores ?? SportsService.instance;
  String? _error;

  /// Resting on a row for a moment loads its stats in the background, so
  /// OK opens the pop-up already filled (scrolling past rows fetches none).
  Timer? _prefetchTimer;

  void _prefetchSoon(SportsGame g) {
    _prefetchTimer?.cancel();
    if (!_active) return;
    _prefetchTimer = Timer(const Duration(milliseconds: 400), () {
      if (_active) _scores.prefetchSummary(g);
    });
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _keys.addAll(_games.map(_key));
    if (_games.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _focusRow(0);
      });
    }
    unawaited(_load(first: _games.isEmpty));
    _pollTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (_active) unawaited(_load());
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route is PageRoute<void>) appRouteObserver.subscribe(this, route);
  }

  @override
  void didPushNext() {
    _covered = true;
    _prefetchTimer?.cancel();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final wasBackgrounded = _backgrounded;
    _backgrounded = state != AppLifecycleState.resumed;
    if (_backgrounded) _prefetchTimer?.cancel();
    if (wasBackgrounded && _active) unawaited(_load());
  }

  @override
  void didPopNext() {
    _covered = false;
    unawaited(_load());
  }

  @override
  void dispose() {
    appRouteObserver.unsubscribe(this);
    WidgetsBinding.instance.removeObserver(this);
    _pollTimer?.cancel();
    _prefetchTimer?.cancel();
    for (final n in _nodes.values) {
      n.dispose();
    }
    _scroll.dispose();
    super.dispose();
  }

  FocusNode _node(String key) =>
      _nodes[key] ??= FocusNode(debugLabel: 'sports-live-$key');

  Future<void> _load({bool first = false}) {
    if (!_active) return Future.value();
    return _loadWork.request(() async {
      if (!_active) return;
      try {
        await _loadOnce(first: first || _games.isEmpty);
      } catch (_) {
        if (!mounted) return;
        setState(() {
          _loading = false;
          _matching = false;
          _error = 'Could not update live games. Try again.';
        });
      }
    });
  }

  Future<void> _loadOnce({required bool first}) async {
    final all = await _scores.gamesForDay(widget.leagues, widget.day);
    if (!_active) return;
    // Upcoming games never appear in this list. Avoid matching the entire day
    // on every poll, while retaining games that finished during this visit.
    final candidates = [
      for (final g in all)
        if (g.state == GameState.live || _keys.contains(_key(g))) g,
    ];
    if (widget.channelFilter != SportsChannelFilter.all) {
      try {
        final matches = await widget.matchGames(candidates);
        if (!mounted) return;
        _matches = matches;
        for (final id in matches.keys) {
          _checkedAt[id] = _now;
        }
      } catch (e) {
        // Keep the last known matches if a background refresh fails.
        debugPrint('SportsLiveList: channel matching failed: ${e.runtimeType}');
        if (!mounted) return;
      }
    }
    final games = _ordered([
      for (final g in candidates)
        if (widget.channelFilter
            .accepts(_matches[_key(g)] ?? const [], pending: false))
          g,
    ]);
    // Keep the focused row's game under the focus when the order moves.
    final focusedKey =
        _games.isEmpty ? null : _games[_focused.clamp(0, _games.length - 1)];
    setState(() {
      _keys.addAll(games.map(_key));
      _games = games;
      _loading = false;
      _error = null;
      if (focusedKey != null) {
        final i = games.indexWhere((g) => _key(g) == _key(focusedKey));
        if (i >= 0) _focused = i;
      }
    });
    final removedFocus =
        focusedKey != null && !games.any((g) => _key(g) == _key(focusedKey));
    if ((first || removedFocus) && games.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _focusRow(first ? 0 : _focused);
      });
    }
    // Reuse the hub's results, but don't keep empty/old evidence forever in
    // All events. Recheck at expiry, without blanking existing rows first.
    final now = _now;
    final missing = [
      for (final g in games)
        if (!_matches.containsKey(_key(g)) ||
            (widget.channelFilter == SportsChannelFilter.all &&
                (_checkedAt[_key(g)] == null ||
                    now.difference(_checkedAt[_key(g)]!) >=
                        const Duration(minutes: 5) ||
                    (g.state == GameState.live &&
                        (_matches[_key(g)]?.any((m) =>
                                m.programme != null &&
                                !m.programme!.stop.isAfter(now)) ??
                            false)))))
          g,
    ];
    if (missing.isEmpty) {
      if (_matching) setState(() => _matching = false);
      return;
    }
    Map<String, List<ChannelMatch>> matches;
    if (!_matching) setState(() => _matching = true);
    try {
      final refreshed = await widget.matchGames(missing);
      matches = {..._matches, ...refreshed};
      for (final id in refreshed.keys) {
        _checkedAt[id] = _now;
      }
    } catch (e) {
      // Rows would say "Looking…" forever.
      debugPrint('SportsLiveList: channel matching failed: ${e.runtimeType}');
      matches = _matches;
    }
    if (!mounted) return;
    setState(() {
      _matches = matches;
      _matching = false;
    });
  }

  void _focusRow(int i) {
    if (_games.isEmpty) return;
    i = i.clamp(0, _games.length - 1);
    _focused = i;
    final key = _key(_games[i]);
    _node(key).requestFocus();
    final ctx = _rowKeys[key]?.currentContext;
    // Jump directly to the focused row without animating through intermediate content.
    if (ctx != null) Scrollable.ensureVisible(ctx, alignment: 0.4);
  }

  Future<void> _watch(Channel channel, SportsGame g) async {
    await widget.onWatch(channel);
    if (!mounted || Platform.isWindows) return;
    // Back from the player lands here: the stream would keep playing
    // unseen under the list.
    final playback = context.read<PlaybackService>();
    if (playback.currentChannel?.id == channel.id) await playback.stop();
  }

  void _onPlayKey() {
    if (_games.isEmpty) return;
    final g = _games[_focused.clamp(0, _games.length - 1)];
    final best = widget.channelFilter.preferred(_matches[_key(g)] ?? const []);
    if (best == null) {
      unawaited(_openDetails(g));
    } else {
      unawaited(_watch(best.channel, g));
    }
  }

  Future<void> _openMenu(SportsGame g) async {
    await widget.onMenu(g, _matches[_key(g)] ?? const [], _watch);
    if (!mounted) return;
    // A channel may have been picked or forgotten: search this game again.
    setState(() => _matches = {..._matches}..remove(_key(g)));
    unawaited(_load());
  }

  Future<void> _openDetails(SportsGame g) async {
    final channel = await showDialog<Channel>(
      context: context,
      builder: (_) => SportsGameDetailsDialog(
        game: g,
        matches: _matches[_key(g)] ?? const [],
        hideScores: widget.hideScores,
      ),
    );
    if (channel != null && mounted) await _watch(channel, g);
  }

  bool get _narrow => MediaQuery.sizeOf(context).width < 600;

  @override
  Widget build(BuildContext context) {
    final live = _games.where((g) => g.state == GameState.live).length;
    return SportsScreenFrame(
      child: withTvThemeIfNeeded(
        context,
        (context) => Stack(
          children: [
            const Positioned.fill(child: SettingsGradientBackground()),
            Positioned.fill(
                child: _LeagueBackdrop(
                    league: _games.isEmpty
                        ? null
                        : _games[_focused.clamp(0, _games.length - 1)].league)),
            Scaffold(
              backgroundColor: Colors.transparent,
              body: SafeArea(
                child: CallbackShortcuts(
                  bindings: {
                    const SingleActivator(LogicalKeyboardKey.arrowUp): () =>
                        _focusRow(_focused - 1),
                    const SingleActivator(LogicalKeyboardKey.arrowDown): () =>
                        _focusRow(_focused + 1),
                    const SingleActivator(LogicalKeyboardKey.arrowLeft): () {},
                    const SingleActivator(LogicalKeyboardKey.arrowRight): () {},
                    const SingleActivator(LogicalKeyboardKey.mediaPlayPause):
                        _onPlayKey,
                    const SingleActivator(LogicalKeyboardKey.mediaPlay):
                        _onPlayKey,
                    const SingleActivator(LogicalKeyboardKey.mediaPause):
                        _onPlayKey,
                  },
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(
                        _narrow ? 12 : 24, 12, _narrow ? 12 : 24, 0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          height: 44,
                          child: Row(
                            children: [
                              const SportsBackButton(),
                              Text(tr('Live games'),
                                  style: Theme.of(context)
                                      .textTheme
                                      .headlineSmall
                                      ?.copyWith(fontWeight: FontWeight.w800)),
                              const SizedBox(width: 10),
                              Text('$live',
                                  style: const TextStyle(
                                      fontSize: 17, color: Colors.white54)),
                              const SizedBox(width: 16),
                              if (!_narrow)
                                Expanded(
                                  child: Text(
                                      Platform.isWindows
                                          ? tr('Click a game for its stats')
                                          : tr(
                                              'OK = stats and standings · ▶❚❚ = watch'),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      textAlign: TextAlign.end,
                                      style: const TextStyle(
                                          color: Colors.white38, fontSize: 12)),
                                ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 6),
                        Expanded(child: _buildList()),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildList() {
    if (_loading && _games.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_games.isEmpty) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(_error ?? tr('No games are live right now'),
              style: const TextStyle(color: Colors.white70, fontSize: 16)),
          if (_error != null)
            TextButton(onPressed: _load, child: const Text('Retry')),
        ]),
      );
    }
    // Build the rows together so remote navigation can focus an off-screen neighbour.
    return SingleChildScrollView(
      controller: _scroll,
      padding: const EdgeInsets.only(bottom: 32),
      child: Column(
        children: [
          for (final (i, g) in _games.indexed)
            _LiveRow(
              key: _rowKeys[_key(g)] ??= GlobalKey(),
              focusNode: _node(_key(g)),
              game: g,
              match:
                  widget.channelFilter.preferred(_matches[_key(g)] ?? const []),
              matching: _matching,
              hideScores: widget.hideScores,
              starred: widget.follows.involves(g),
              narrow: _narrow,
              onFocus: () {
                final leagueChanged =
                    _games[_focused.clamp(0, _games.length - 1)].league.id !=
                        g.league.id;
                _focused = i;
                // The backdrop follows the focused game's league.
                if (leagueChanged) setState(() {});
                _prefetchSoon(g);
              },
              onTap: () => _openDetails(g),
              onHold: () => _openMenu(g),
            ),
        ],
      ),
    );
  }
}

String? _backdropUrl(SportsLeague l, {bool dark = true}) =>
    sportsLogoUrl(dark ? sportsDarkLogoUrl(l.logoUrl) : l.logoUrl, size: 500);

/// Downloads [league]'s backdrop logo ahead (focus on "See all"), so the
/// list opens with it already drawn.
void precacheLeagueBackdrop(BuildContext context, SportsLeague league) {
  final url = _backdropUrl(league);
  if (url == null) return;
  unawaited(precacheImage(CachedNetworkImageProvider(url), context,
      onError: (_, __) {}));
}

/// The focused game's league logo, faded behind the list. Cross-fades when focus moves to
/// another league's game.
class _LeagueBackdrop extends StatelessWidget {
  const _LeagueBackdrop({required this.league});
  final SportsLeague? league;

  @override
  Widget build(BuildContext context) {
    final l = league;
    final size = MediaQuery.sizeOf(context);
    return IgnorePointer(
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 400),
        child: l?.logoUrl == null
            ? const SizedBox.expand()
            : SizedBox.expand(
                key: ValueKey(l!.id),
                child: Align(
                  alignment: const Alignment(0.55, 0.35),
                  child: Opacity(
                    opacity: 0.10,
                    // Not SportsLogo: no disc, and a sharper fetch than its
                    // 200 px cap. Dark variant first (navy logos on black).
                    child: CachedNetworkImage(
                      imageUrl: _backdropUrl(l) ?? '',
                      width: size.shortestSide * 0.85,
                      height: size.shortestSide * 0.85,
                      fit: BoxFit.contain,
                      memCacheWidth: 500,
                      fadeInDuration: const Duration(milliseconds: 300),
                      errorWidget: (_, __, ___) => CachedNetworkImage(
                        imageUrl: _backdropUrl(l, dark: false) ?? '',
                        fit: BoxFit.contain,
                        memCacheWidth: 500,
                        errorWidget: (_, __, ___) => const SizedBox(),
                      ),
                    ),
                  ),
                ),
              ),
      ),
    );
  }
}

// ==================================================================== rows

/// "Q3 7:48" etc.; ESPN's short status, translated where we know it.
String _clock(SportsGame g) => g.state == GameState.post
    ? tr('Final')
    : (g.statusText.isEmpty ? tr('LIVE') : trSports(g.statusText));

class _LiveRow extends StatefulWidget {
  const _LiveRow({
    super.key,
    required this.focusNode,
    required this.game,
    required this.match,
    required this.matching,
    required this.hideScores,
    required this.starred,
    required this.narrow,
    required this.onFocus,
    required this.onTap,
    required this.onHold,
  });

  final FocusNode focusNode;
  final SportsGame game;
  final ChannelMatch? match;
  final bool matching;
  final bool hideScores;
  final bool starred;
  final bool narrow;
  final VoidCallback onFocus;
  final VoidCallback onTap;
  final VoidCallback onHold;

  @override
  State<_LiveRow> createState() => _LiveRowState();
}

class _LiveRowState extends State<_LiveRow> {
  late bool _focused = widget.focusNode.hasFocus;

  @override
  void didUpdateWidget(_LiveRow old) {
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
    final sit = g.situation;
    final leaders =
        widget.hideScores ? const <SportsLeader>[] : g.leaders.take(3).toList();

    final status = SizedBox(
      width: 104,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (live)
                Container(
                  width: 7,
                  height: 7,
                  margin: const EdgeInsets.only(right: 5),
                  decoration: const BoxDecoration(
                      shape: BoxShape.circle, color: Colors.redAccent),
                ),
              Flexible(
                child: Text(_clock(g),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: live ? Colors.redAccent : Colors.white54)),
              ),
            ],
          ),
          const SizedBox(height: 2),
          if (sit?.redZone ?? false)
            Text(tr('RED ZONE'),
                style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFFFF5A4E)))
          else
            Text(
                sit?.text ??
                    (g.league.shortName.isEmpty
                        ? g.league.name
                        : g.league.shortName),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11, color: Colors.white60)),
          if ((sit?.redZone ?? false) && sit?.text != null)
            Text(sit!.text!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11, color: Colors.white60)),
        ],
      ),
    );

    Widget teamLine(SportsTeam t) {
      final has =
          sit?.possessionTeamId != null && sit!.possessionTeamId == t.id;
      return Row(
        children: [
          SportsLogo(
              url: t.logoUrl,
              size: 20,
              fallback: t.abbreviation,
              color: t.color),
          const SizedBox(width: 6),
          Text(t.abbreviation,
              style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w800,
                  color: Colors.white)),
          if (has)
            const Padding(
              padding: EdgeInsets.only(left: 4),
              child:
                  Icon(Icons.sports_football, size: 11, color: Colors.white70),
            ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(t.record ?? '',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11, color: Colors.white38)),
          ),
          if (!widget.hideScores)
            Text(t.score ?? '-',
                style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                    color: Colors.white)),
        ],
      );
    }

    final teams = SizedBox(
      width: widget.narrow ? null : 200,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          teamLine(g.first),
          const SizedBox(height: 3),
          teamLine(g.second)
        ],
      ),
    );

    final leaderBlock = Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final l in leaders)
          Text.rich(
            TextSpan(children: [
              TextSpan(
                  text: '${l.stat}  ',
                  style: const TextStyle(color: Colors.white38)),
              TextSpan(
                  text: l.name,
                  style: const TextStyle(
                      color: Colors.white, fontWeight: FontWeight.w600)),
              TextSpan(
                  text: '  ${l.value}',
                  style: const TextStyle(color: Colors.white70)),
            ]),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12),
          ),
      ],
    );

    final channel = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (widget.starred)
          Padding(
            padding: const EdgeInsets.only(right: 4),
            child: Icon(Icons.star, size: 13, color: scheme.primary),
          ),
        Icon(widget.match != null ? Icons.live_tv : Icons.add_circle_outline,
            size: 13,
            color: widget.match != null ? scheme.primary : Colors.white38),
        const SizedBox(width: 5),
        Flexible(
          child: Text(
            widget.match?.channel.name ??
                (widget.matching ? tr('Looking…') : tr('No channel')),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                fontSize: 12,
                color: widget.match != null ? scheme.primary : Colors.white38),
          ),
        ),
      ],
    );

    final body = widget.narrow
        ? Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [status, Expanded(child: teams)]),
                if (leaders.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  leaderBlock,
                ],
                const SizedBox(height: 4),
                channel,
              ],
            ),
          )
        : SizedBox(
            height: 64,
            child: Row(
              children: [
                status,
                teams,
                const SizedBox(width: 18),
                Expanded(child: leaderBlock),
                const SizedBox(width: 12),
                SizedBox(width: 140, child: channel),
              ],
            ),
          );

    // Remote OK: short = stats, hold = channel menu (like the game cards).
    return HoldToActivate(
        onTap: widget.onTap,
        onHold: widget.onHold,
        child: InkWell(
          focusNode: widget.focusNode,
          borderRadius: BorderRadius.circular(12),
          onTap: widget.onTap,
          onLongPress: widget.onHold,
          onFocusChange: (f) {
            setState(() => _focused = f);
            if (f) widget.onFocus();
          },
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            margin: const EdgeInsets.symmetric(vertical: 3),
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: _focused ? null : Colors.white.withValues(alpha: 0.06),
              gradient: _focused ? sportsFocusSheen(scheme) : null,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: _focused ? scheme.primary : Colors.transparent,
                width: _focused ? 2.5 : 1,
              ),
            ),
            child: body,
          ),
        ));
  }
}

// ================================================================== dialog

/// A game's details drawn to the middle of the screen: the score line, the
/// channels to watch it on (pops the chosen [Channel]), then each team's
/// top performers, box score and injuries side by side, the team stats
/// compared, soccer scorers and the standings groups of both teams.
/// Refreshes every 30 s while live. Up/Down scroll (the content has no
/// focusable rows), Left/Right move along the Watch buttons.
class SportsGameDetailsDialog extends StatefulWidget {
  const SportsGameDetailsDialog({
    super.key,
    required this.game,
    required this.matches,
    required this.hideScores,
    this.overStream = false,
  });

  final SportsGame game;
  final List<ChannelMatch> matches;
  final bool hideScores;

  /// "Pull stats" from the fullscreen player's side panel: see-through, and
  /// to the right of the panel ([leftInset]) so the picture stays visible.
  final bool overStream;
  static const double leftInset = 400;

  @override
  State<SportsGameDetailsDialog> createState() =>
      _SportsGameDetailsDialogState();
}

class _SportsGameDetailsDialogState extends State<SportsGameDetailsDialog> {
  SportsGameSummary? _summary;
  bool _loading = true;
  Timer? _timer;
  final ScrollController _scroll = ScrollController();
  final List<FocusNode> _buttons = [];
  final FocusNode _closeNode = FocusNode(debugLabel: 'sports-details-close');

  @override
  void initState() {
    super.initState();
    unawaited(_load());
    if (widget.game.state == GameState.live) {
      _timer = Timer.periodic(const Duration(seconds: 30), (_) => _load());
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _scroll.dispose();
    for (final n in _buttons) {
      n.dispose();
    }
    _closeNode.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    var s = await SportsService.instance.gameSummary(widget.game);
    // Nothing yet: one more try a second later rather than at the next
    // 30 s refresh.
    if (s == null && _summary == null && mounted) {
      await Future<void>.delayed(const Duration(seconds: 1));
      if (!mounted) return;
      s = await SportsService.instance.gameSummary(widget.game);
    }
    if (!mounted) return;
    setState(() {
      _summary = s ?? _summary;
      _loading = false;
    });
  }

  void _scrollBy(double dy) {
    if (!_scroll.hasClients) return;
    final p = _scroll.position;
    _scroll.jumpTo((p.pixels + dy).clamp(0, p.maxScrollExtent));
  }

  FocusNode _button(int i) {
    while (_buttons.length <= i) {
      _buttons.add(FocusNode(debugLabel: 'sports-details-watch-$i'));
    }
    return _buttons[i];
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final narrow = size.width < 600;
    final g = widget.game;
    final channels = widget.matches.take(3).toList();
    final over = widget.overStream && !narrow;
    // Landscape phone/tablet: the TV's 5% margins left the card short and
    // the safe area pushed it off the panel. Full height instead, right
    // against the side panel (its phone width, see PlayerScreen), with a
    // strip on the right to tap out of it. TV unchanged.
    final phoneOver = over &&
        Platform.isAndroid &&
        size.width > size.height &&
        !context.read<AppPreferences>().isTelevision;
    // Windows: a card of its own size beside the panel, not the TV's
    // "everything right of the panel" (too big on a 4K monitor): at most 980 wide and 88% high, centred vertically.
    final desktopOver = over && Platform.isWindows;
    const desktopMaxWidth = 980.0;
    final pad = MediaQuery.paddingOf(context);
    final dialog = Dialog(
      backgroundColor: over ? const Color(0x9E101014) : const Color(0xF2121216),
      insetPadding: desktopOver
          ? EdgeInsets.fromLTRB(
              SportsGameDetailsDialog.leftInset + 16,
              size.height * 0.06,
              (size.width -
                      SportsGameDetailsDialog.leftInset -
                      16 -
                      desktopMaxWidth)
                  .clamp(16.0, double.infinity),
              size.height * 0.06)
          : phoneOver
              ? EdgeInsets.fromLTRB(
                  (size.width * 0.88)
                          .clamp(0.0, SportsGameDetailsDialog.leftInset) +
                      6,
                  pad.top + 6,
                  pad.right + 64,
                  pad.bottom + 6)
              : over
                  ? EdgeInsets.fromLTRB(SportsGameDetailsDialog.leftInset + 16,
                      size.height * 0.05, size.width * 0.03, size.height * 0.05)
                  : EdgeInsets.symmetric(
                      horizontal: narrow ? 8 : size.width * 0.06,
                      vertical: narrow ? 16 : size.height * 0.05),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
            color:
                Theme.of(context).colorScheme.primary.withValues(alpha: 0.4)),
      ),
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.arrowUp): () =>
              _scrollBy(-90),
          const SingleActivator(LogicalKeyboardKey.arrowDown): () =>
              _scrollBy(90),
        },
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 14, 18, 10),
          child: Column(
            children: [
              _ScoreHeader(game: g, hideScores: widget.hideScores),
              const SizedBox(height: 10),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (final (i, m) in channels.indexed)
                      SportsChip(
                        focusNode: _button(i),
                        label: tr(
                            'Watch on {channel}', {'channel': m.channel.name}),
                        icon: Icons.play_arrow,
                        selected: false,
                        onFocus: () {},
                        onTap: () => Navigator.of(context).pop(m.channel),
                      ),
                    if (channels.isEmpty)
                      Padding(
                        padding: const EdgeInsets.only(right: 12),
                        child: Text(
                            tr('No channel found. Hold OK on the game in {tab} to pick one.',
                                {'tab': AppConstants.sportsTabName}),
                            style: const TextStyle(
                                color: Colors.white54, fontSize: 13)),
                      ),
                    SportsChip(
                      focusNode: _closeNode,
                      label: tr('Close'),
                      icon: Icons.close,
                      selected: false,
                      onFocus: () {},
                      onTap: () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
              ),
              // Focus the first Watch button (or Close) once built.
              _AutoFocus(node: channels.isEmpty ? _closeNode : _button(0)),
              const SizedBox(height: 8),
              const Divider(height: 1, color: Colors.white12),
              Expanded(
                // While the box score loads, the scoreboard's top players
                // show at once (an empty summary falls back to them).
                child: SingleChildScrollView(
                  controller: _scroll,
                  padding: const EdgeInsets.only(top: 10, bottom: 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (_loading && _summary == null)
                        const Padding(
                          padding: EdgeInsets.only(bottom: 10),
                          child: LinearProgressIndicator(minHeight: 2),
                        ),
                      if (!_loading || _summary != null || g.leaders.isNotEmpty)
                        _SummaryBody(
                          game: g,
                          summary: _summary ??
                              (_loading ? const SportsGameSummary() : null),
                          narrow: narrow,
                        ),
                    ],
                  ),
                ),
              ),
              if (!narrow)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(tr('▲▼ scroll · Back closes'),
                      style:
                          const TextStyle(color: Colors.white30, fontSize: 11)),
                ),
            ],
          ),
        ),
      ),
    );
    return dialog;
  }
}

class _AutoFocus extends StatefulWidget {
  const _AutoFocus({required this.node});
  final FocusNode node;

  @override
  State<_AutoFocus> createState() => _AutoFocusState();
}

class _AutoFocusState extends State<_AutoFocus> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.node.requestFocus();
    });
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

class _ScoreHeader extends StatelessWidget {
  const _ScoreHeader({required this.game, required this.hideScores});
  final SportsGame game;
  final bool hideScores;

  @override
  Widget build(BuildContext context) {
    final g = game;
    final live = g.state == GameState.live;
    Widget side(SportsTeam t, {required bool end}) {
      final logo = SportsLogo(
          url: t.logoUrl, size: 40, fallback: t.abbreviation, color: t.color);
      final text = Flexible(
        child: Column(
          crossAxisAlignment:
              end ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            Text(t.shortName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                    color: Colors.white)),
            if (t.record != null)
              Text(t.record!,
                  style: const TextStyle(fontSize: 12, color: Colors.white54)),
          ],
        ),
      );
      final score = hideScores
          ? const SizedBox.shrink()
          : Text(t.score ?? '-',
              style: const TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w800,
                  color: Colors.white));
      return Expanded(
        child: Row(
          mainAxisAlignment:
              end ? MainAxisAlignment.end : MainAxisAlignment.start,
          children: end
              ? [
                  score,
                  const SizedBox(width: 12),
                  text,
                  const SizedBox(width: 8),
                  logo
                ]
              : [
                  logo,
                  const SizedBox(width: 8),
                  text,
                  const SizedBox(width: 12),
                  score
                ],
        ),
      );
    }

    final sit = g.situation;
    return Column(
      children: [
        Row(
          children: [
            side(g.first, end: false),
            SizedBox(
              width: 150,
              child: Column(
                children: [
                  Text(_clock(g),
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: live ? Colors.redAccent : Colors.white60)),
                  if (sit?.text != null)
                    Text(sit!.text!,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            fontSize: 12,
                            color: sit.redZone
                                ? const Color(0xFFFF5A4E)
                                : Colors.white60)),
                ],
              ),
            ),
            side(g.second, end: true),
          ],
        ),
        if (sit?.lastPlay != null && !hideScores)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(sit!.lastPlay!,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 12, color: Colors.white54)),
          ),
      ],
    );
  }
}

/// Section titles of the box score ([SportsPlayerGroup.title]).
String _groupTitle(String id) => switch (id) {
      'passing' => tr('Passing'),
      'rushing' => tr('Rushing'),
      'receiving' => tr('Receiving'),
      'defensive' => tr('Defense'),
      'kicking' => tr('Kicking'),
      'forwards' => tr('Forwards'),
      'defenses' => tr('Defensemen'),
      'goalies' => tr('Goalies'),
      'batting' => tr('Batting'),
      'pitching' => tr('Pitching'),
      _ => tr('Players'),
    };

const _sectionStyle = TextStyle(
    fontSize: 13,
    fontWeight: FontWeight.w800,
    letterSpacing: 0.6,
    color: Colors.white70);

class _SummaryBody extends StatelessWidget {
  const _SummaryBody(
      {required this.game, required this.summary, required this.narrow});
  final SportsGame game;
  final SportsGameSummary? summary;
  final bool narrow;

  @override
  Widget build(BuildContext context) {
    final s = summary;
    final g = game;
    final scheme = Theme.of(context).colorScheme;
    if (s == null || (s.isEmpty && g.leaders.isEmpty)) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: Text(tr('No stats for this game yet.'),
              style: const TextStyle(color: Colors.white54)),
        ),
      );
    }

    Widget teamColumn(SportsTeam t) {
      final leaders = s.leaders[t.id] ??
          [
            for (final l in g.leaders)
              if (l.teamId == t.id) l
          ];
      final groups = s.players[t.id] ?? const [];
      final injuries = s.injuries[t.id] ?? const [];
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SportsLogo(
                  url: t.logoUrl,
                  size: 22,
                  fallback: t.abbreviation,
                  color: t.color),
              const SizedBox(width: 8),
              Flexible(
                child: Text(t.name.toUpperCase(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: _sectionStyle.copyWith(color: scheme.primary)),
              ),
            ],
          ),
          if (leaders.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(tr('Top performers'), style: _sectionStyle),
            const SizedBox(height: 4),
            for (final l in leaders)
              Padding(
                padding: const EdgeInsets.only(bottom: 3),
                child: Text.rich(
                  TextSpan(children: [
                    TextSpan(
                        text: '${l.stat}\n',
                        style: const TextStyle(
                            fontSize: 11, color: Colors.white38)),
                    TextSpan(
                        text: l.name,
                        style: const TextStyle(
                            fontWeight: FontWeight.w700, color: Colors.white)),
                    if (l.position != null)
                      TextSpan(
                          text: ' ${l.position}',
                          style: const TextStyle(color: Colors.white38)),
                    TextSpan(
                        text: '  ${l.value}',
                        style: const TextStyle(color: Colors.white70)),
                  ]),
                  style: const TextStyle(fontSize: 13),
                ),
              ),
          ],
          for (final grp in groups) ...[
            const SizedBox(height: 10),
            Text(_groupTitle(grp.title), style: _sectionStyle),
            const SizedBox(height: 4),
            _BoxTable(group: grp),
          ],
          if (injuries.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(tr('Injuries'), style: _sectionStyle),
            const SizedBox(height: 4),
            for (final i in injuries.take(8))
              Text.rich(
                TextSpan(children: [
                  TextSpan(
                      text: i.name,
                      style: const TextStyle(color: Colors.white)),
                  if (i.position != null)
                    TextSpan(
                        text: ' ${i.position}',
                        style: const TextStyle(color: Colors.white38)),
                  TextSpan(
                      text: '  ${i.status}',
                      style: TextStyle(
                          color: i.status.toLowerCase() == 'out'
                              ? const Color(0xFFFF5A4E)
                              : const Color(0xFFFFB74D))),
                  if (i.detail != null)
                    TextSpan(
                        text: ' (${i.detail})',
                        style: const TextStyle(color: Colors.white38)),
                ]),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12),
              ),
          ],
        ],
      );
    }

    final columns = narrow
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              teamColumn(g.first),
              const SizedBox(height: 16),
              teamColumn(g.second),
            ],
          )
        : Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: teamColumn(g.first)),
              const SizedBox(width: 24),
              Expanded(child: teamColumn(g.second)),
            ],
          );

    // teamStats are away | home; show them in on-screen order.
    final flip = g.first.id == g.home.id;
    final stats = s.teamStats.take(14).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        columns,
        if (s.goals.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text(tr('Goals'), style: _sectionStyle),
          const SizedBox(height: 4),
          for (final goal in s.goals)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 1),
              child: Text(
                '${goal.period == null ? '' : '${trSports(goal.period!)} '}'
                '${goal.minute}  ${goal.scorer}'
                '${goal.penalty ? ' (${tr('pen.')})' : ''}'
                '${goal.assists.isEmpty ? '' : ' (${goal.assists.join(', ')})'}'
                '  · ${goal.teamId == g.home.id ? g.home.abbreviation : g.away.abbreviation}'
                // Running score, in on-screen order like the header.
                '${goal.score == null ? '' : '  ${flip ? goal.score!.split('-').reversed.join('-') : goal.score}'}',
                style: const TextStyle(fontSize: 13, color: Colors.white),
              ),
            ),
        ],
        if (stats.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text(tr('Team stats'), style: _sectionStyle),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                  child: Text(g.first.abbreviation,
                      style: const TextStyle(
                          fontWeight: FontWeight.w800, color: Colors.white))),
              Expanded(
                  child: Text(g.second.abbreviation,
                      textAlign: TextAlign.end,
                      style: const TextStyle(
                          fontWeight: FontWeight.w800, color: Colors.white))),
            ],
          ),
          for (final (label, away, home) in stats)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: [
                  SizedBox(
                      width: 80,
                      child: Text(flip ? home : away,
                          style: const TextStyle(
                              fontSize: 13, color: Colors.white))),
                  Expanded(
                      child: Text(label,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                              fontSize: 12, color: Colors.white54))),
                  SizedBox(
                      width: 80,
                      child: Text(flip ? away : home,
                          textAlign: TextAlign.end,
                          style: const TextStyle(
                              fontSize: 13, color: Colors.white))),
                ],
              ),
            ),
        ],
        for (final t in s.tables) ...[
          const SizedBox(height: 16),
          Text(t.title.isEmpty ? tr('Standings') : t.title,
              style: _sectionStyle),
          const SizedBox(height: 4),
          _StandingsMini(table: t, highlight: {g.home.id, g.away.id}),
        ],
      ],
    );
  }
}

class _BoxTable extends StatelessWidget {
  const _BoxTable({required this.group});
  final SportsPlayerGroup group;

  @override
  Widget build(BuildContext context) {
    const head = TextStyle(fontSize: 11, color: Colors.white38);
    const cell = TextStyle(fontSize: 12.5, color: Colors.white);
    Widget row(String name, List<String> values, TextStyle style,
            {bool bold = false}) =>
        Padding(
          padding: const EdgeInsets.only(bottom: 2),
          child: Row(
            children: [
              Expanded(
                child: Text(name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: bold
                        ? style.copyWith(fontWeight: FontWeight.w600)
                        : style),
              ),
              for (final v in values)
                SizedBox(
                  width: 44,
                  child: Text(v,
                      textAlign: TextAlign.end,
                      maxLines: 1,
                      overflow: TextOverflow.fade,
                      softWrap: false,
                      style: style),
                ),
            ],
          ),
        );
    return Column(
      children: [
        row('', group.labels, head),
        for (final (name, values) in group.rows)
          row(name, values, cell, bold: true),
      ],
    );
  }
}

class _StandingsMini extends StatelessWidget {
  const _StandingsMini({required this.table, required this.highlight});
  final SportsSummaryTable table;
  final Set<String> highlight;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    const head = TextStyle(fontSize: 11, color: Colors.white38);
    return Column(
      children: [
        Row(
          children: [
            const SizedBox(width: 24),
            const Expanded(child: SizedBox()),
            for (final l in table.labels)
              SizedBox(
                  width: 56,
                  child: Text(l, textAlign: TextAlign.end, style: head)),
          ],
        ),
        for (final (i, (id, name, values)) in table.rows.indexed)
          Container(
            padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 4),
            decoration: highlight.contains(id)
                ? BoxDecoration(
                    color: scheme.primary.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(6))
                : null,
            child: Row(
              children: [
                SizedBox(
                    width: 20,
                    child: Text('${i + 1}',
                        style: const TextStyle(
                            fontSize: 12, color: Colors.white38))),
                Expanded(
                  child: Text(name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 13,
                          fontWeight: highlight.contains(id)
                              ? FontWeight.w800
                              : FontWeight.w500,
                          color: highlight.contains(id)
                              ? scheme.primary
                              : Colors.white)),
                ),
                for (final v in values)
                  SizedBox(
                    width: 56,
                    child: Text(v,
                        textAlign: TextAlign.end,
                        style:
                            const TextStyle(fontSize: 13, color: Colors.white)),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}
