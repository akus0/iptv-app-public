import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../utils/constants.dart';
import '../utils/time_format.dart';
import '../l10n/l10n.dart';
import '../models/channel.dart';
import '../models/sports.dart';
import '../services/epg_service.dart';
import '../services/app_preferences.dart';
import '../services/playback_service.dart';
import '../services/playlist_manager.dart';
import '../services/sports_channel_matcher.dart';
import '../services/sports_follows.dart';
import '../services/sports_service.dart';
import '../services/storage_service.dart';
import '../screens/sports_live_list_screen.dart';
import 'hold_to_activate.dart';
import 'sports_widgets.dart';
import 'player_chrome.dart';
import 'cached_channel_logo.dart';
import 'tv_text_field_gate.dart';

/// Fullscreen channel and sports picker with in-place playback and optional game
/// details. Dispatch tabs and row selection from one focus node rather than building a
/// focus node for every result.
class PlayerSidePanel extends StatefulWidget {
  const PlayerSidePanel(
      {super.key,
      required this.current,
      required this.onClose,
      this.onPlay,
      this.focusSearch = false});

  final Channel current;
  final bool focusSearch;
  final VoidCallback onClose;

  /// Plays a picked channel. Null = [PlaybackService.play] (Android);
  /// Windows passes its own player's switch (DesktopPlayerScreen).
  final Future<void> Function(Channel)? onPlay;

  static const double width = 440;

  @override
  State<PlayerSidePanel> createState() => _PlayerSidePanelState();
}

class _PlayerSidePanelState extends State<PlayerSidePanel> {
  static const _tabs = [
    'Recent',
    'My teams',
    'Live sport',
    'Favourites',
    'This group'
  ];
  static const _tabOrder = [0, 3, 4, 2, 1];
  double get _rowHeight =>
      (_channelTab ? 104 : 116) +
      (MediaQuery.textScalerOf(context).scale(13) - 13).clamp(0, 40) * 6;

  /// Reopening lands on the tab used last (for the app session).
  static int _lastTab = 0;

  final FocusNode _focus = FocusNode(debugLabel: 'player-side-panel');
  final ScrollController _scroll = ScrollController();
  late int _tab = _lastTab;
  final List<int> _index = [0, 0, 0, 0, 0];
  final _search = TextEditingController();
  final _searchFocus = FocusNode(debugLabel: 'player-channel-search');
  final _tabKeys = List.generate(5, (_) => GlobalKey());
  Timer? _searchDebounce;
  List<Channel>? _catalog;
  Future<void>? _catalogLoad;
  List<Channel> _channelRows = const [];
  bool _channelLoading = false, _sportsBusy = false;
  int _searchGeneration = 0;
  bool get _searching => _search.text.trim().isNotEmpty;
  bool get _channelTab => _searching || _tab == 0 || _tab >= 3;

  List<SportsGame> _teamGames = const [];
  List<SportsGame> _liveGames = const [];
  Map<String, List<ChannelMatch>> _matches = const {};
  bool _sportsLoading = true;
  bool _hasFollows = false;
  bool _hideScores = false;
  String? _message;
  Timer? _poll;

  /// Hold OK on a game row (see [_onKey]): like [HoldToActivate], a hold
  /// needs the remote's own key repeats, not just time — a late key-up
  /// after a click on a busy box has none — so it fires from a repeat.
  bool _selectDown = false;
  bool _holdFired = false;
  final Stopwatch _held = Stopwatch();
  static const _holdDuration = Duration(milliseconds: 550);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        if (widget.focusSearch) {
          _searchFocus.requestFocus();
        } else {
          _focus.requestFocus();
        }
      }
    });
    _updateChannels();
    if (!_channelTab) unawaited(_loadSports());
    _poll = Timer.periodic(const Duration(seconds: 30), (_) {
      if (!mounted) return;
      if (_channelTab) {
        setState(() {});
      } else {
        unawaited(_loadSports());
      }
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    _searchGeneration++;
    _searchDebounce?.cancel();
    _search.dispose();
    _searchFocus.dispose();
    _focus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  List<Channel> get _recent {
    final seen = <String>{widget.current.id};
    final out = <Channel>[widget.current];
    for (final c in context.read<PlaybackService>().recentlyPlayed) {
      if (!Channel.isLiveId(c.rawId) || !seen.add(c.id)) continue;
      out.add(c);
      if (out.length >= 40) break;
    }
    return out;
  }

  int get _count => _channelTab
      ? _channelRows.length
      : _tab == 1
          ? _teamGames.length
          : _liveGames.length;

  Future<void> _ensureCatalog() => _catalogLoad ??= () async {
        final playlist = context.read<PlaylistManager>();
        await playlist.ensureLiveChannelsLoaded();
        if (!mounted) return;
        _catalog = playlist.visibleLiveChannels;
      }();

  Future<void> _updateChannels() async {
    final generation = ++_searchGeneration;
    if (!_channelTab) return;
    final query = _search.text.trim().toLowerCase();
    if (query.isEmpty && _tab == 0) {
      setState(() {
        _channelRows = _recent;
        _channelLoading = false;
        _message = null;
      });
      return;
    }
    setState(() {
      _channelLoading = true;
      _message = null;
    });
    try {
      await _ensureCatalog();
      if (!mounted || generation != _searchGeneration) return;
      final playlist = context.read<PlaylistManager>();
      final epg = context.read<EpgService>();
      final terms = query.split(RegExp(r'\s+'));
      final found = <Channel>[];
      final favoriteGroups = <String, Set<String>>{};
      var scanned = 0;
      for (final channel in _catalog ?? const <Channel>[]) {
        if (++scanned % 750 == 0) {
          await Future<void>.delayed(Duration.zero);
          if (!mounted || generation != _searchGeneration) return;
        }
        if (channel.name.trimLeft().startsWith('###')) continue;
        if (query.isNotEmpty) {
          final name = channel.name.toLowerCase();
          final now =
              epg.getCurrentProgram(channel.epgId)?.title.toLowerCase() ?? '';
          if (!terms
              .every((term) => name.contains(term) || now.contains(term))) {
            continue;
          }
        } else if (_tab == 3) {
          final groups = favoriteGroups.putIfAbsent(channel.playlistId,
              () => playlist.favoritedGroupsFor(channel.playlistId));
          if (!channel.isFavorite && !groups.contains(channel.group)) continue;
        } else if (_tab == 4 &&
            (channel.playlistId != widget.current.playlistId ||
                channel.group != widget.current.group)) {
          continue;
        }
        found.add(channel);
        if (query.isNotEmpty && found.length == 200) break;
      }
      if (!mounted || generation != _searchGeneration) return;
      setState(() {
        _channelRows = found;
        _channelLoading = false;
        _index[_tab] = 0;
      });
    } catch (_) {
      if (mounted && generation == _searchGeneration) {
        setState(() {
          _channelLoading = false;
          _message = tr('Channels unavailable. Try again.');
          _catalogLoad = null;
        });
      }
    }
  }

  void _searchChanged(String _) {
    _searchGeneration++;
    _searchDebounce?.cancel();
    setState(() {
      _index[_tab] = 0;
      _channelRows = const [];
      _channelLoading = _searching;
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
    _searchDebounce = Timer(const Duration(milliseconds: 220), () {
      if (!mounted) return;
      unawaited(_updateChannels());
      if (!_channelTab) unawaited(_loadSports());
    });
  }

  Future<void> _loadSports() async {
    if (_sportsBusy || _channelTab) return;
    _sportsBusy = true;
    try {
      final storage = context.read<StorageService>();
      final follows = SportsFollows.load(storage);
      final saved = savedSportsLeagues(storage);
      final leagues = <String, SportsLeague>{
        for (final l in saved) l.id: l,
        for (final t in follows.teams)
          if (sportsLeagueById(t.leagueId) case final l?) l.id: l,
      };
      final games = await SportsService.instance
          .gamesForDay(leagues.values.toList(), DateTime.now());
      if (!mounted || _channelTab) return;
      int byState(SportsGame g) => switch (g.state) {
            GameState.live => 0,
            GameState.pre => 1,
            GameState.post => 2,
          };
      final team = games.where(follows.involves).toList()
        ..sort((a, b) {
          final s = byState(a).compareTo(byState(b));
          return s != 0 ? s : a.start.compareTo(b.start);
        });
      final savedIds = {for (final l in saved) l.id};
      // The favourite league's games first, then My Teams' games, each
      // keeping the start order.
      final favoriteId = favoriteSportsLeague(storage)?.id;
      int rank(SportsGame g) =>
          (g.league.id == favoriteId ? 0 : 2) + (follows.involves(g) ? 0 : 1);
      final live = [
        for (var r = 0; r < 4; r++)
          ...games.where((g) =>
              g.state == GameState.live &&
              savedIds.contains(g.league.id) &&
              rank(g) == r),
      ];
      setState(() {
        _teamGames = team;
        _liveGames = live;
        _hasFollows = !follows.isEmpty;
        _hideScores = storage.getSportsHideScores();
        _sportsLoading = false;
        for (var t = 1; t < 3; t++) {
          final n = t == 1 ? team.length : live.length;
          if (_index[t] >= n) _index[t] = n == 0 ? 0 : n - 1;
        }
      });

      final playlist = context.read<PlaylistManager>();
      final matcher = SportsChannelMatcher.shared(context.read<EpgService>());
      await playlist.ensureLiveChannelsLoaded();
      if (!mounted || _channelTab) return;
      await matcher.prepare(playlist.visibleLiveChannels);
      if (!mounted || _channelTab) return;
      try {
        final matches = await matcher.matchDay(
            {...team, ...live}.toList(), SportsChannelPicks.load(storage));
        if (mounted) setState(() => _matches = matches);
      } catch (_) {
        // Keep known channels when the local guide is temporarily unavailable.
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _sportsLoading = false;
          _message = tr('Sports unavailable. Try again.');
        });
      }
    } finally {
      if (mounted) {
        setState(() => _sportsBusy = false);
      } else {
        _sportsBusy = false;
      }
    }
  }

  void _select(int tab, int index) {
    setState(() {
      _tab = tab;
      _lastTab = tab;
      _index[tab] = index;
      _message = null;
    });
    // Keep the selected row on screen — jumpTo, never animateTo (§10).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      final pos = _scroll.position;
      final top = _index[_tab] * _rowHeight;
      if (top < pos.pixels) {
        _scroll.jumpTo(top);
      } else if (top + _rowHeight > pos.pixels + pos.viewportDimension) {
        _scroll.jumpTo((top + _rowHeight - pos.viewportDimension)
            .clamp(0.0, pos.maxScrollExtent));
      }
    });
  }

  void _switchTab(int tab) {
    if (tab < 0 || tab >= _tabs.length || tab == _tab) return;
    if (_scroll.hasClients) _scroll.jumpTo(0);
    _select(tab, 0);
    unawaited(_updateChannels());
    if (!_channelTab) unawaited(_loadSports());
  }

  Future<void> _activate() async {
    final i = _index[_tab];
    Channel? channel;
    if (_channelTab) {
      if (i < _channelRows.length) channel = _channelRows[i];
    } else {
      final games = _tab == 1 ? _teamGames : _liveGames;
      if (i >= games.length) return;
      channel =
          _matches[SportsChannelPicks.eventKey(games[i])]?.firstOrNull?.channel;
      if (channel == null) {
        setState(() => _message = tr('No channel found for this game'));
        return;
      }
    }
    if (channel == null) return;
    widget.onClose();
    await _play(channel);
  }

  /// Hold OK on a game: its box score / stats over the stream, see-through.
  /// Watch on a channel there plays it like OK does.
  Future<void> _openStats() async {
    if (_channelTab) return;
    final games = _tab == 1 ? _teamGames : _liveGames;
    final i = _index[_tab];
    if (i >= games.length) return;
    final g = games[i];
    final size = MediaQuery.sizeOf(context);
    final channel = await showDialog<Channel>(
      context: context,
      barrierColor: Colors.transparent,
      // Landscape phone: the dialog places itself around the notch (see
      // SportsGameDetailsDialog.build); the default SafeArea pushed it off
      // the panel's edge.
      useSafeArea: context.read<AppPreferences>().isTelevision ||
          size.width <= size.height,
      // Opened by a hold: drop the held OK's repeats.
      builder: (_) => SwallowHeldActivate(
        child: SportsGameDetailsDialog(
          game: g,
          matches: _matches[SportsChannelPicks.eventKey(g)] ?? const [],
          hideScores: _hideScores,
          overStream: true,
        ),
      ),
    );
    if (!mounted) return;
    if (channel == null) {
      _focus.requestFocus();
      return;
    }
    widget.onClose();
    await _play(channel);
  }

  Future<void> _play(Channel channel) {
    final play = widget.onPlay;
    return play != null
        ? play(channel)
        : context.read<PlaybackService>().play(channel);
  }

  static bool _isSelect(LogicalKeyboardKey key) =>
      key == LogicalKeyboardKey.select ||
      key == LogicalKeyboardKey.enter ||
      key == LogicalKeyboardKey.numpadEnter ||
      key == LogicalKeyboardKey.gameButtonA;

  /// OK on a game tab: tap = watch (on key-up), hold = stats. Last
  /// channels has no hold, so it plays on key-down as before.
  KeyEventResult _onSelectKey(KeyEvent event) {
    if (_channelTab) {
      if (event is KeyDownEvent) unawaited(_activate());
      return KeyEventResult.handled;
    }
    if (event is KeyDownEvent) {
      _selectDown = true;
      _holdFired = false;
      _held
        ..reset()
        ..start();
    } else if (event is KeyRepeatEvent) {
      if (_selectDown && !_holdFired && _held.elapsed >= _holdDuration) {
        _holdFired = true;
        unawaited(_openStats());
      }
    } else if (event is KeyUpEvent) {
      // Only a press that started here (an orphaned key-up is ignored).
      final tap = _selectDown && !_holdFired;
      _selectDown = false;
      _held.stop();
      if (tap) unawaited(_activate());
    }
    return KeyEventResult.handled;
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (_searchFocus.hasFocus) {
      if (event is KeyDownEvent &&
          event.logicalKey == LogicalKeyboardKey.arrowDown) {
        _focus.requestFocus();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    if (!_focus.hasPrimaryFocus) return KeyEventResult.ignored;
    if (_isSelect(event.logicalKey)) return _onSelectKey(event);
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    // Windows keyboard: Esc closes, like Back on a remote.
    if (key == LogicalKeyboardKey.escape) {
      if (event is KeyDownEvent) widget.onClose();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      if (_index[_tab] > 0) {
        _select(_tab, _index[_tab] - 1);
      } else {
        _searchFocus.requestFocus();
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      if (_index[_tab] < _count - 1) _select(_tab, _index[_tab] + 1);
      return KeyEventResult.handled;
    }
    if (_searching &&
        (key == LogicalKeyboardKey.arrowLeft ||
            key == LogicalKeyboardKey.arrowRight)) {
      _searchFocus.requestFocus();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft) {
      if (event is KeyDownEvent) {
        final i = _tabOrder.indexOf(_tab);
        if (i > 0) _switchTab(_tabOrder[i - 1]);
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowRight) {
      if (event is KeyDownEvent) {
        final i = _tabOrder.indexOf(_tab);
        if (i < _tabOrder.length - 1) _switchTab(_tabOrder[i + 1]);
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    context.watch<PlaybackService>();
    final epg = context.watch<EpgService>();
    return Focus(
      focusNode: _focus,
      onKeyEvent: _onKey,
      child: Material(
        color: playerPanelColor,
        child: SafeArea(
          right: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                  padding: const EdgeInsets.fromLTRB(14, 0, 4, 0),
                  child: Row(children: [
                    Expanded(
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                          Text(tr('Channels'),
                              style: const TextStyle(
                                  fontSize: 15, fontWeight: FontWeight.w600)),
                        ])),
                    PlayerAction(
                        icon: Icons.close_rounded,
                        label: 'Close channels',
                        compact: true,
                        onPressed: widget.onClose),
                  ])),
              Padding(
                  padding: const EdgeInsets.fromLTRB(10, 0, 10, 3),
                  child: TvTextFieldGate(
                      focusNode: _searchFocus,
                      builder: (context, readOnly) => TextField(
                            key: const ValueKey('player-channel-search'),
                            controller: _search,
                            focusNode: _searchFocus,
                            readOnly: readOnly,
                            style: const TextStyle(fontSize: 12),
                            onChanged: _searchChanged,
                            onSubmitted: (_) => _focus.requestFocus(),
                            decoration: InputDecoration(
                                hintText: tr('Search channels or on now'),
                                isDense: true,
                                filled: true,
                                fillColor: const Color(0xFF1C2631),
                                contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 10, vertical: 8),
                                prefixIcon: const Icon(Icons.search, size: 17),
                                prefixIconConstraints: const BoxConstraints(
                                    minWidth: 36, minHeight: 40),
                                suffixIconConstraints: const BoxConstraints(
                                    minWidth: 40, minHeight: 40),
                                suffixIcon: _searching
                                    ? IconButton(
                                        tooltip: tr('Clear search'),
                                        icon: const Icon(Icons.close, size: 17),
                                        onPressed: () {
                                          _search.clear();
                                          _searchChanged('');
                                        })
                                    : null,
                                enabledBorder: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(5),
                                    borderSide: const BorderSide(
                                        color: Color(0xFF303D4B))),
                                focusedBorder: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(5),
                                    borderSide: BorderSide(color: accent)),
                                border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(4),
                                    borderSide: const BorderSide(
                                        color: Color(0xFF344150)))),
                          ))),
              if (!_searching)
                Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    child: Row(children: [
                      for (final tab in _tabOrder)
                        Expanded(
                            child: InkWell(
                                key: _tabKeys[tab],
                                canRequestFocus: false,
                                onTap: () => _switchTab(tab),
                                child: Container(
                                    height: 40,
                                    alignment: Alignment.center,
                                    decoration: BoxDecoration(
                                        color: _tab == tab
                                            ? const Color(0xFF253544)
                                            : Colors.transparent,
                                        border: Border(
                                            bottom: BorderSide(
                                                width: 2,
                                                color: _tab == tab
                                                    ? accent
                                                    : const Color(
                                                        0xFF2B3541)))),
                                    child: Text(tr(_tabs[tab]),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                            fontSize: 10,
                                            fontWeight: _tab == tab
                                                ? FontWeight.w600
                                                : FontWeight.w400,
                                            color: _tab == tab
                                                ? Colors.white
                                                : playerMuted)))))
                    ])),
              Padding(
                  padding: const EdgeInsets.fromLTRB(14, 5, 14, 5),
                  child: Text(
                      _searching
                          ? (_channelRows.length == 200
                              ? tr('First 200 matches · narrow your search')
                              : tr('{count} channels',
                                  {'count': _channelRows.length}))
                          : _tab == 4
                              ? widget.current.group
                              : _channelTab
                                  ? tr('{count} channels',
                                      {'count': _channelRows.length})
                                  : tr('{count} events · hold for details',
                                      {'count': _count}),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style:
                          const TextStyle(fontSize: 10, color: playerMuted))),
              Expanded(child: _buildList(accent, epg)),
              if (_message != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                  child: Text(_message!,
                      style: const TextStyle(
                          color: Colors.orangeAccent, fontSize: 13)),
                ),
              if (context.read<AppPreferences>().isTelevision)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                  child: Text(
                    _channelTab
                        ? tr('◀ ▶ tabs  ·  OK to watch  ·  Back to close')
                        : tr(
                            '◀ ▶ tabs  ·  OK to watch  ·  Hold OK for stats  ·  Back to close'),
                    style: const TextStyle(color: Colors.white54, fontSize: 11),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _empty(String text) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(text,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70, fontSize: 14)),
        ),
      );

  Widget _buildList(Color accent, EpgService epg) {
    if (_channelTab) {
      if (_channelLoading) {
        return const Center(child: CircularProgressIndicator(strokeWidth: 2));
      }
      final channels = _channelRows;
      if (channels.isEmpty) {
        return _empty(tr(_searching
            ? 'No matching channels'
            : _tab == 3
                ? 'Star channels in the guide to keep them here.'
                : 'No channels available.'));
      }
      return _list(channels.length, accent, (i) {
        final c = channels[i];
        final now = epg.getCurrentProgram(c.epgId);
        final next = epg.getNextProgram(c.epgId);
        final playing = c.id == widget.current.id;
        final nowTime = now == null
            ? null
            : '${TimeFormat.hm.format(now.start)}–${TimeFormat.hm.format(now.stop)}';
        final minutes = now == null
            ? 0
            : now.stop.difference(DateTime.now()).inMinutes.clamp(0, 1440);
        return Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
          SizedBox(
              width: 34,
              child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    CachedChannelLogo(url: c.logoUrl, size: 32),
                    if (playing)
                      Padding(
                          padding: const EdgeInsets.only(top: 7),
                          child: Icon(Icons.equalizer_rounded,
                              size: 16, color: accent)),
                  ])),
          const SizedBox(width: 10),
          Expanded(
              child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                Row(children: [
                  Expanded(
                      child: Text(c.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                              color: playing ? accent : playerMuted))),
                  if (playing)
                    Padding(
                        padding: const EdgeInsets.only(left: 6),
                        child: Text(tr('Current'),
                            style: TextStyle(fontSize: 9, color: accent))),
                ]),
                const SizedBox(height: 4),
                Text(now?.title ?? tr('Programme unavailable'),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 13,
                        height: 1.2,
                        fontWeight: FontWeight.w500,
                        color: Color(0xFFF0F4F8))),
                const SizedBox(height: 4),
                if (nowTime != null)
                  Row(children: [
                    Expanded(
                        child: Text(nowTime,
                            style: const TextStyle(
                                fontSize: 9, color: playerMuted))),
                    Text(tr('{minutes} min left', {'minutes': minutes}),
                        style:
                            const TextStyle(fontSize: 9, color: playerMuted)),
                  ]),
                const SizedBox(height: 3),
                Text(
                    next == null
                        ? c.group
                        : '${tr('Next')} ${TimeFormat.hm.format(next.start)} · ${next.title}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 10, color: playerMuted)),
              ])),
        ]);
      });
    }
    if (_sportsLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    final games = _tab == 1 ? _teamGames : _liveGames;
    if (games.isEmpty) {
      return _empty(_tab == 1
          ? (_hasFollows
              ? tr('None of your teams play today.')
              : tr('Follow teams from {tab} > Standings to see them here.',
                  {'tab': AppConstants.sportsTabName}))
          : tr('No games from your leagues are live right now.'));
    }
    return _list(games.length, accent, (i) => _gameRow(games[i]));
  }

  Widget _list(int count, Color accent, Widget Function(int i) row) =>
      ListView.builder(
        controller: _scroll,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        itemCount: count,
        itemExtent: _rowHeight,
        itemBuilder: (context, i) {
          final selected = i == _index[_tab];
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: InkWell(
              canRequestFocus: false,
              onTap: () {
                _select(_tab, i);
                unawaited(_activate());
              },
              onLongPress: _channelTab
                  ? null
                  : () {
                      _select(_tab, i);
                      unawaited(_openStats());
                    },
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                decoration: BoxDecoration(
                  color: selected
                      ? Color.lerp(Colors.black, accent, 0.25)
                      : const Color(0x991A222C),
                  border: Border.all(
                      color: selected
                          ? accent.withValues(alpha: .7)
                          : const Color(0xFF26313D),
                      width: 1),
                  borderRadius: BorderRadius.circular(5),
                ),
                child: row(i),
              ),
            ),
          );
        },
      );

  Widget _gameRow(SportsGame g) => PlayerSportRow(
        game: g,
        match: _matches[SportsChannelPicks.eventKey(g)]?.firstOrNull,
        guide: context.read<EpgService>(),
        currentChannelId: widget.current.id,
        hideScores: _hideScores,
        searching: _sportsBusy,
      );
}

/// A compact event card with separate competition, competitors and channel.
/// Only visible list rows perform cached guide/logo lookups.
class PlayerSportRow extends StatelessWidget {
  const PlayerSportRow(
      {super.key,
      required this.game,
      required this.guide,
      this.match,
      this.currentChannelId,
      this.hideScores = false,
      this.searching = false});
  final SportsGame game;
  final EpgService guide;
  final ChannelMatch? match;
  final String? currentChannelId;
  final bool hideScores, searching;
  @override
  Widget build(BuildContext context) {
    final g = game;
    final channel = match?.channel;
    final programme =
        channel == null ? null : guide.getCurrentProgram(channel.epgId);
    final playing = channel != null && channel.id == currentChannelId;
    final accent = Theme.of(context).colorScheme.primary;
    final status = g.state == GameState.pre
        ? TimeFormat.hm.format(g.start.toLocal())
        : trSports(g.statusText);
    final live =
        g.state == GameState.live && !g.isOnAirOnly && !g.isScheduleOnly;
    final score = !hideScores && g.state != GameState.pre;
    Widget team(SportsTeam t) => Row(children: [
          SportsLogo(
              url: t.logoUrl,
              size: 17,
              fallback: t.abbreviation,
              color: t.color),
          const SizedBox(width: 7),
          Expanded(
              child: Text(t.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 12,
                      height: 1.25,
                      fontWeight: FontWeight.w500))),
          if (score && t.score != null)
            Padding(
                padding: const EdgeInsets.only(left: 6),
                child: Text(t.score!,
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: accent))),
        ]);
    final badge = playing
        ? 'Playing'
        : match?.reason == MatchReason.pick
            ? 'Your pick'
            : match?.isConfident == true
                ? 'Matched'
                : 'Possible';
    return Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(children: [
            Expanded(
                child: Text(
                    g.league.isField
                        ? g.league.name
                        : g.event?.title ?? g.league.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 9, color: playerMuted))),
            const SizedBox(width: 8),
            ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 110),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  if (live)
                    const Padding(
                        padding: EdgeInsets.only(right: 4),
                        child: Icon(Icons.circle,
                            size: 5, color: Color(0xFFEF9C9C))),
                  Flexible(
                      child: Text(status,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.right,
                          style: TextStyle(
                              fontSize: 9,
                              color: live
                                  ? const Color(0xFFEF9C9C)
                                  : playerMuted))),
                ])),
          ]),
          const SizedBox(height: 5),
          if (g.league.isField)
            SizedBox(
                height: 38,
                child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(g.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 13,
                            height: 1.25,
                            fontWeight: FontWeight.w600))))
          else ...[team(g.first), const SizedBox(height: 3), team(g.second)],
          const Padding(
              padding: EdgeInsets.symmetric(vertical: 5),
              child: Divider(height: 1, color: Color(0x263B5269))),
          Row(children: [
            if (channel != null) ...[
              CachedChannelLogo(url: channel.logoUrl, size: 20),
              const SizedBox(width: 7)
            ],
            Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  Text(
                      channel?.name ??
                          tr(searching
                              ? 'Finding channels…'
                              : 'No channel found'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 10,
                          color: channel == null ? playerMuted : Colors.white)),
                  if (programme != null)
                    Text('${tr('Now')} · ${programme.title}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style:
                            const TextStyle(fontSize: 9, color: playerMuted)),
                ])),
            if (channel != null)
              Padding(
                  padding: const EdgeInsets.only(left: 6),
                  child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 5, vertical: 3),
                      decoration: BoxDecoration(
                          color: (match!.isConfident || playing
                                  ? accent
                                  : const Color(0xFFE3BE85))
                              .withValues(alpha: .10),
                          borderRadius: BorderRadius.circular(3)),
                      child: Text(tr(badge),
                          style: TextStyle(
                              fontSize: 8,
                              color: match!.isConfident || playing
                                  ? accent
                                  : const Color(0xFFE3BE85))))),
          ]),
        ]);
  }
}

/// Touch and mouse: the floating tab on the left edge of a fullscreen
/// player that opens [PlayerSidePanel] (a remote uses Left), shown with
/// the player bars. Phone (PlayerScreen) and Windows (DesktopPlayerScreen).
class PlayerSidePanelTab extends StatelessWidget {
  const PlayerSidePanelTab({super.key, required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.fromLTRB(8, 18, 10, 18),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.62),
            borderRadius:
                const BorderRadius.horizontal(right: Radius.circular(24)),
            border: Border.all(color: Colors.white24),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.view_list_rounded, color: scheme.primary, size: 24),
              const SizedBox(height: 4),
              const Icon(Icons.chevron_right, color: Colors.white70, size: 22),
            ],
          ),
        ),
      ),
    );
  }
}
