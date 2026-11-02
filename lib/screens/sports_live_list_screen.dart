import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../models/channel.dart';
import '../models/sports.dart';
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
  late List<SportsGame> _games =
      _ordered(widget.initialGames.where((g) => g.isLive).toList());
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
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final wasBackgrounded = _backgrounded;
    _backgrounded = state != AppLifecycleState.resumed;
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
        if (g.isLive || _keys.contains(_key(g))) g,
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
                    (g.isLive &&
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
    if (!mounted) return;
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
      unawaited(_openMenu(g));
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

  bool get _narrow => MediaQuery.sizeOf(context).width < 600;

  @override
  Widget build(BuildContext context) {
    final live = _games.where((g) => g.isLive).length;
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
                                      tr(
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
              },
              onTap: () => _openMenu(g),
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
    final live = g.isLive;
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
