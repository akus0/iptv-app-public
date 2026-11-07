import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../utils/time_format.dart';
import '../l10n/l10n.dart';
import '../models/channel.dart';
import '../services/epg_service.dart';
import '../services/app_preferences.dart';
import '../services/playback_service.dart';
import '../services/playlist_manager.dart';

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
  final Future<void> Function(Channel)? onPlay;

  static const double width = 440;

  @override
  State<PlayerSidePanel> createState() => _PlayerSidePanelState();
}

class _PlayerSidePanelState extends State<PlayerSidePanel> {
  static const _tabs = ['Recent', 'Favourites', 'This group'];
  static const _tabOrder = [0, 1, 2];
  double get _rowHeight =>
      (104) +
      (MediaQuery.textScalerOf(context).scale(13) - 13).clamp(0, 40) * 6;

  /// Reopening lands on the tab used last (for the app session).
  static int _lastTab = 0;

  final FocusNode _focus = FocusNode(debugLabel: 'player-side-panel');
  final ScrollController _scroll = ScrollController();
  late int _tab = _lastTab;
  final List<int> _index = [0, 0, 0];
  final _search = TextEditingController();
  final _searchFocus = FocusNode(debugLabel: 'player-channel-search');
  final _tabKeys = List.generate(3, (_) => GlobalKey());
  Timer? _searchDebounce;
  List<Channel>? _catalog;
  Future<void>? _catalogLoad;
  List<Channel> _channelRows = const [];
  bool _channelLoading = false;
  int _searchGeneration = 0;
  bool get _searching => _search.text.trim().isNotEmpty;

  String? _message;
  Timer? _poll;

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

    _poll = Timer.periodic(const Duration(seconds: 30), (_) {
      if (!mounted) return;

      setState(() {});
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

  int get _count => _channelRows.length;

  Future<void> _ensureCatalog() => _catalogLoad ??= () async {
        final playlist = context.read<PlaylistManager>();
        await playlist.ensureLiveChannelsLoaded();
        if (!mounted) return;
        _catalog = playlist.visibleLiveChannels;
      }();

  Future<void> _updateChannels() async {
    final generation = ++_searchGeneration;

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
        } else if (_tab == 1) {
          final groups = favoriteGroups.putIfAbsent(channel.playlistId,
              () => playlist.favoritedGroupsFor(channel.playlistId));
          if (!channel.isFavorite && !groups.contains(channel.group)) continue;
        } else if (_tab == 2 &&
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
    });
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
  }

  Future<void> _activate() async {
    final i = _index[_tab];
    Channel? channel;

    if (i < _channelRows.length) channel = _channelRows[i];

    if (channel == null) return;
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
    if (event is KeyDownEvent) unawaited(_activate());
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
                          : _tab == 2
                              ? widget.current.group
                              : tr('{count} channels',
                                  {'count': _channelRows.length}),
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
                    tr('◀ ▶ tabs  ·  OK to watch  ·  Back to close'),
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
    if (_channelLoading) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    final channels = _channelRows;
    if (channels.isEmpty) {
      return _empty(tr(_searching
          ? 'No matching channels'
          : _tab == 1
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
            child:
                Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              CachedChannelLogo(url: c.logoUrl, size: 32),
              if (playing)
                Padding(
                    padding: const EdgeInsets.only(top: 7),
                    child:
                        Icon(Icons.equalizer_rounded, size: 16, color: accent)),
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
                      style: const TextStyle(fontSize: 9, color: playerMuted)),
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
}

/// Touch and mouse: the floating tab on the left edge of a fullscreen
/// player that opens [PlayerSidePanel] (a remote uses Left), shown with
/// the player bars.
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
