import 'dart:async';
import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:video_player_hdr/video_player_hdr.dart';

import '../models/channel.dart';
import '../models/epg_program.dart';
import '../services/app_preferences.dart';
import '../services/epg_service.dart';
import '../services/playback_service.dart';
import '../services/playback_health.dart';
import '../services/playlist_manager.dart';
import '../utils/time_format.dart';
import '../utils/player_route.dart';
import '../utils/constants.dart';
import '../utils/tv_theme.dart';
import '../widgets/player_chrome.dart';
import '../widgets/player_stream_info.dart';
import '../widgets/player_controls.dart';
import '../widgets/subtitle_overlay.dart';
import '../widgets/player_side_panel.dart';
import 'multiview_screen.dart';
import 'search_screen.dart';
import '../l10n/l10n.dart';

/// Fullscreen playback shares the preview's [PlaybackService] controller.
/// Phone orientation and picture cropping are independent settings; TV layouts
/// leave orientation alone. Explicit remote navigation connects the side panel
/// and the two control bars, which hide after inactivity.
class PlayerScreen extends StatefulWidget {
  const PlayerScreen(
      {super.key, required this.channel, this.startInPictureInPicture = false});

  final Channel channel;
  final bool startInPictureInPicture;

  static Future<void> open(NavigatorState navigator, Channel channel,
          {bool startInPictureInPicture = false}) =>
      PlayerNavigation.open(
          navigator,
          (_) => PlayerScreen(
              channel: channel,
              startInPictureInPicture: startInPictureInPicture));

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  bool _immersive = false;
  bool _pictureFill = false;
  bool _topVisible = false;
  bool _bottomVisible = false;
  double _controlsHeight = 160;

  Timer? _hideTimer;

  /// CH+/CH- info card ([_ZapInfoCard]) — separate from the top bar so a
  /// zap shows what's on without moving focus or the bars.
  bool _zapInfoVisible = false;
  Timer? _zapInfoTimer;

  /// [PlayerSidePanel] showing (Left on a live channel). Back closes it
  /// instead of leaving the player (see the PopScope in [build]).
  bool _panelOpen = false;
  bool _panelSearch = false;

  /// The screen's own key-catching Focus — focus goes back here when the
  /// panel closes, so Up/Down/Left work again straight away.
  final FocusNode _rootFocus = FocusNode(debugLabel: 'player-root');
  final FocusNode _infoFocus = FocusNode(debugLabel: 'player-stream-info');

  void _showStreamInfo({bool fromHold = false}) {
    if (_panelOpen || ModalRoute.of(context)?.isCurrent == false) return;
    _hideTimer?.cancel();
    showPlayerStreamInfo(context, fromHold: fromHold).whenComplete(() {
      if (mounted) _resetHideTimer();
    });
  }

  void _focusTopBar() {
    if (!_topVisible) setState(() => _topVisible = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          !_topVisible ||
          ModalRoute.of(context)?.isCurrent == false) {
        return;
      }
      if (_infoFocus.context != null) {
        _infoFocus.requestFocus();
      } else {
        _topScope.requestFocus();
      }
    });
  }

  Timer? _infoHoldTimer;
  bool _infoDown = false,
      _infoRepeat = false,
      _infoElapsed = false,
      _infoHeld = false;
  void _cancelInfoHold() {
    _infoHoldTimer?.cancel();
    _infoDown = _infoRepeat = _infoElapsed = false;
  }

  void _openHeldInfo() {
    if (!_infoDown ||
        !_infoRepeat ||
        !_infoElapsed ||
        _infoHeld ||
        !_rootFocus.hasPrimaryFocus) {
      return;
    }
    _infoHeld = true;
    _showStreamInfo(fromHold: true);
  }

  KeyEventResult _rootKey(FocusNode node, KeyEvent event) {
    if (!node.hasPrimaryFocus || _touch || _panelOpen) {
      return KeyEventResult.ignored;
    }
    if (![
      LogicalKeyboardKey.select,
      LogicalKeyboardKey.enter,
      LogicalKeyboardKey.numpadEnter,
      LogicalKeyboardKey.gameButtonA
    ].contains(event.logicalKey)) {
      _cancelInfoHold();
      return KeyEventResult.ignored;
    }
    if (event is KeyDownEvent) {
      _cancelInfoHold();
      _infoDown = true;
      _infoHeld = false;
      _infoHoldTimer = Timer(const Duration(milliseconds: 550), () {
        _infoElapsed = true;
        _openHeldInfo();
      });
    } else if (event is KeyRepeatEvent) {
      _infoRepeat = true;
      _openHeldInfo();
    } else if (event is KeyUpEvent) {
      final tap = _infoDown && !_infoHeld;
      _cancelInfoHold();
      if (tap) _toggleInfoCard();
    }
    return KeyEventResult.handled;
  }

  void _openPanel({bool search = false}) {
    _hideTimer?.cancel();
    setState(() {
      _panelOpen = true;
      _panelSearch = search;
      _topVisible = false;
      _bottomVisible = false;
    });
  }

  void _closePanel() {
    if (!_panelOpen) return;
    setState(() => _panelOpen = false);
    _rootFocus.requestFocus();
  }

  /// Refreshed on every build (see [build]) and read from [_togglePictureFit]
  /// / [_restoreChrome] / [dispose] — those don't call [build] themselves,
  /// so this caches the last-known answer rather than doing a fresh
  /// `context.watch`/`MediaQuery.of` lookup from places where that's
  /// unsafe (dispose) or unnecessary (a plain button handler).
  bool _isTvLayout = false;

  /// A touch device (phone/tablet), refreshed on every build like
  /// [_isTvLayout] — unlike that one it stays true for a phone held
  /// sideways, whose width can pass the TV-layout threshold.
  bool _touch = false;

  /// The rotate button forced an orientation (released on leaving).
  bool _rotated = false;

  final FocusScopeNode _topScope = FocusScopeNode(debugLabel: 'player-top');
  final FocusNode _playFocus = FocusNode(debugLabel: 'player-play');
  final FocusScopeNode _bottomScope =
      FocusScopeNode(debugLabel: 'player-bottom');

  /// The "Switch to linked channel" button VideoPlayerPane shows on a
  /// playback error — owned here (not by that button itself) so Up/Down can
  /// treat it as a third explicit zone. See
  /// [VideoPlayerPane.switchButtonFocusNode]'s doc comment for why.
  final FocusNode _switchButtonFocus =
      FocusNode(debugLabel: 'player-switch-button');

  /// Refreshed on every build, same pattern as [_isTvLayout] — read from
  /// [_handleUp]/[_handleDown], which don't run during a build themselves.
  bool _hasLinkedChannel = false;
  bool get _hasSwitchButton =>
      _playback.health.value.phase == StreamPhase.failed &&
      (_hasLinkedChannel ||
          (_playback.currentChannel != null &&
              Channel.isLiveId(_playback.currentChannel!.rawId)));

  bool get _focusInBar => _topScope.hasFocus || _bottomScope.hasFocus;

  /// Search from the player should land on the tab that matches what's
  /// playing — inferred from the Xtream id prefix (see
  /// XtreamApiService.getVodStreams/getSeriesEpisodes/getLiveStreams).
  String get _searchScope {
    final id = (_playback.currentChannel ?? widget.channel).rawId;
    if (id.startsWith('xt_vod_')) return 'Movies';
    if (id.startsWith('xt_ep_')) return 'TV Shows';
    return 'TV';
  }

  late final PlaybackService _playback;

  @override
  void initState() {
    super.initState();
    _playback = context.read<PlaybackService>();
    _playback.play(widget.channel);
    _playback.claimFullscreen(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_playback.ownsFullscreen(this)) return;
      if (widget.startInPictureInPicture) unawaited(_enterMiniPlayer());
    });
    _topScope.addListener(_onBarFocusChange);
    _bottomScope.addListener(_onBarFocusChange);
    _switchButtonFocus.addListener(_onBarFocusChange);
    _resetHideTimer();
    // Fullscreen is a route, not a crop mode. Always start with the whole
    // picture visible; old zoom preferences must not crop a new viewing session.
    if (!context.read<AppPreferences>().isTelevision &&
        !widget.startInPictureInPicture) {
      _immersive = true;
      _topVisible = true;
      _bottomVisible = true;
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    }
  }

  void _onBarFocusChange() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Search, settings and modal sheets must not become a PiP window.
    _playback.pictureInPicture.setFullscreenVisible(
        ModalRoute.isCurrentOf(context) ?? true,
        playerOpen: true);
  }

  Future<void> _enterMiniPlayer() async {
    final entered = await _playback.pictureInPicture.enter();
    if (!mounted || entered) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      content: Text(
          'Start playback and allow picture-in-picture for iptv-app in Android settings.'),
    ));
  }

  Widget _holdControls(Widget child) => Listener(
        onPointerDown: (_) {
          _heldPointers++;
          _hideTimer?.cancel();
        },
        onPointerUp: (_) => _releasePointer(),
        onPointerCancel: (_) => _releasePointer(),
        child: child,
      );
  void _releasePointer() {
    if (_heldPointers > 0) _heldPointers--;
    _resetHideTimer();
  }

  int _heldPointers = 0;

  void _resetHideTimer() {
    _hideTimer?.cancel();
    if (_heldPointers > 0) return;
    _hideTimer = Timer(Duration(seconds: _touch ? 4 : 6), () {
      if (mounted) {
        setState(() {
          _topVisible = false;
          _bottomVisible = false;
        });
      }
    });
  }

  /// Try moving within the current control bar first, accepting the move only if it stays in
  /// that bar. Otherwise use explicit zone navigation to avoid skipping intermediate
  /// controls.
  bool _tryIntraBarMove(FocusScopeNode scope, TraversalDirection direction) {
    final previous = FocusManager.instance.primaryFocus;
    final moved = previous?.focusInDirection(direction) ?? false;
    if (moved && scope.hasFocus) return true;
    if (moved) previous?.requestFocus();
    return false;
  }

  void _handleUp() {
    _resetHideTimer();
    if (_switchButtonFocus.hasFocus) {
      _focusTopBar();
      return;
    }
    if (_bottomScope.hasFocus) {
      if (_tryIntraBarMove(_bottomScope, TraversalDirection.up)) return;
      if (_hasSwitchButton) {
        _switchButtonFocus.requestFocus();
        return;
      }
      _focusTopBar();
      return;
    }
    if (_topScope.hasFocus) {
      _tryIntraBarMove(_topScope, TraversalDirection.up);
      return;
    }
    _focusTopBar();
  }

  /// Shows the bottom bar with Play/Pause focused in one press. Showing it
  /// alone, then focusing the bar's scope (no child), left nothing
  /// highlighted: it took a second Down plus Left/Right to see where the
  /// remote was.
  void _focusBottomBar() {
    if (!_bottomVisible) setState(() => _bottomVisible = true);
    // Next frame: the bar is ExcludeFocus'd until it's visible.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_playFocus.context != null) {
        _playFocus.requestFocus();
      } else {
        _bottomScope.requestFocus();
      }
    });
  }

  void _handleDown() {
    _resetHideTimer();
    if (_switchButtonFocus.hasFocus) {
      _focusBottomBar();
      return;
    }
    if (_topScope.hasFocus) {
      if (_tryIntraBarMove(_topScope, TraversalDirection.down)) return;
      if (_hasSwitchButton) {
        _switchButtonFocus.requestFocus();
        return;
      }
      _focusBottomBar();
      return;
    }
    if (_bottomScope.hasFocus) {
      // All the buttons are on one line now (no second row to reveal).
      _tryIntraBarMove(_bottomScope, TraversalDirection.down);
      return;
    }
    _focusBottomBar();
  }

  /// Stop the normal preview before handing playback to Multiview. Each cell owns a separate
  /// decoder; retaining the preview would duplicate audio and consume another stream
  /// connection.
  bool _openingMultiview = false;
  Future<void> _openMultiview(Channel channel) async {
    if (_openingMultiview || ModalRoute.of(context)?.isCurrent == false) return;
    _openingMultiview = true;
    try {
      await _playback.stop();
      if (!mounted || ModalRoute.of(context)?.isCurrent == false) return;
      final route = MaterialPageRoute<void>(
          builder: (_) => MultiviewScreen(initialChannel: channel));
      await Navigator.of(context).push(route);
      await route.completed;
      if (mounted &&
          _playback.ownsFullscreen(this) &&
          ModalRoute.of(context)?.isCurrent != false) {
        await _playback.play(channel);
      }
    } finally {
      _openingMultiview = false;
    }
  }

  void _revealBottomOnTap() {
    // Touch: a tap on the video beside the open side panel closes it.
    if (_panelOpen) {
      _closePanel();
      return;
    }
    // Phone/tablet: tap to show controls; tap the picture again to hide.
    if (_touch) {
      final show = !(_topVisible && _bottomVisible);
      if (show) {
        _resetHideTimer();
      } else {
        _hideTimer?.cancel();
      }
      setState(() {
        _topVisible = show;
        _bottomVisible = show;
      });
      return;
    }
    _resetHideTimer();
    setState(() => _bottomVisible = true);
  }

  /// A remote's dedicated hardware Play/Pause button (or separate Play/
  /// Pause keys, on remotes that split them) should just work regardless
  /// of where D-pad focus currently is — requiring the user to navigate to
  /// the on-screen button first defeats the entire point of a physical
  /// media key existing. Bound alongside Up/Down below rather than gated
  /// by `!_focusInBar` the way Left/Right are: this should fire no matter
  /// which bar (if any) currently has focus, not just when none does. A
  /// remote with no such key simply never sends this event — the on-screen
  /// button (and D-pad navigation to it) keeps working exactly as before.
  Future<void> _handlePlayPause() async {
    final controller = _playback.controller;
    if (controller == null) return;
    _resetHideTimer();
    final native = await PlaybackHealthBridge.read(controller);
    if (!mounted || !identical(controller, _playback.controller)) return;
    final playing =
        (native?['playWhenReady'] as bool?) ?? controller.value.isPlaying;
    PlaybackHealthBridge.rememberIntent(controller, !playing);
    if (playing) {
      await controller.pause();
    } else {
      await controller.play();
    }
  }

  /// A remote's CH+/CH- (or Page Up/Down) keys: CH- = next channel (the
  /// one below in the list), CH+ = previous (above), matching the guide.
  /// Steps through the list the channel was picked from
  /// ([PlaybackService.zapList], e.g. Favourites), else the channel's own
  /// group; wraps at either end. Live only; a remote without these keys
  /// (Fire Stick) never sends them. Reveals the top bar so the new
  /// channel's name + now/next show.
  void _zapChannel(int step) {
    if (_panelOpen) return;
    final current = _playback.currentChannel ?? widget.channel;
    if (!Channel.isLiveId(current.rawId)) return;
    // A playlist can list the same channel twice (same id, e.g. a tvg-id
    // used as the id): find the exact entry playing, and step past any
    // copy with the same id — play() no-ops on it, which used to leave
    // CH+/- stuck on a duplicate (Favourites).
    int indexIn(List<Channel> l) {
      final exact = l.indexWhere((c) => identical(c, current));
      return exact >= 0 ? exact : l.indexWhere((c) => c.id == current.id);
    }

    var list = _playback.zapList ?? const <Channel>[];
    var i = indexIn(list);
    if (i < 0) {
      list = context.read<PlaylistManager>().visibleChannels(
          playlistId: current.playlistId,
          groupTitle: current.group,
          category: 'tv');
      i = indexIn(list);
    }
    if (i < 0) return;
    Channel? next;
    for (var n = 1; n < list.length; n++) {
      final c = list[(i + step * n) % list.length];
      if (c.id != current.id) {
        next = c;
        break;
      }
    }
    final target = next;
    if (target == null) return;
    // Info overlay stays up while the new stream connects, then for 3 s
    // once it's started — counted from the start, not the
    // key press, so a slow stream doesn't eat the whole window.
    _zapInfoTimer?.cancel();
    setState(() => _zapInfoVisible = true);
    _playback.play(target).whenComplete(() {
      if (!mounted || _playback.currentChannel?.id != target.id) return;
      _zapInfoTimer = Timer(const Duration(seconds: 3), () {
        if (mounted) setState(() => _zapInfoVisible = false);
      });
    });
  }

  /// OK with no bar focused on a live channel: the CH+/CH- info card for
  /// 4 s; OK again hides it.
  void _toggleInfoCard() {
    if (_panelOpen) return;
    final current = _playback.currentChannel ?? widget.channel;
    if (!Channel.isLiveId(current.rawId)) return;
    _zapInfoTimer?.cancel();
    if (_zapInfoVisible) {
      setState(() => _zapInfoVisible = false);
      return;
    }
    setState(() => _zapInfoVisible = true);
    _zapInfoTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => _zapInfoVisible = false);
    });
  }

  void _togglePictureFit() {
    _resetHideTimer();
    setState(() => _pictureFill = !_pictureFill);
  }

  /// Phone: flips between landscape and portrait without the system's
  /// rotation lock (the Rotate action in playback settings).
  Future<void> _toggleRotation() async {
    final toLandscape =
        MediaQuery.of(context).orientation == Orientation.portrait;
    _rotated = true;
    _resetHideTimer();
    await SystemChrome.setPreferredOrientations(toLandscape
        ? [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]
        : [DeviceOrientation.portraitUp]);
  }

  Future<void> _restoreChrome() async {
    if (_touch || !_isTvLayout) {
      // Release the lock instead of forcing portraitUp specifically — a
      // phone/tablet held sideways (or a tablet used in landscape as its
      // normal orientation) shouldn't get snapped to portrait just because
      // it watched a video fullscreen; letting go of the restriction lets
      // the sensor/app defaults decide instead.
      await SystemChrome.setPreferredOrientations([]);
    }
    // A newer player may have opened while orientation restoration awaited
    // Android. Its immersive mode must not be undone by this outgoing route.
    if (!_playback.isFullscreenActive) {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
  }

  @override
  void dispose() {
    final owned = _playback.releaseFullscreen(this);
    if (owned) _playback.pictureInPicture.setFullscreenVisible(false);
    final oldController = _playback.controller;
    final ch = _playback.currentChannel;
    final shouldStopVod = owned && ch != null && !Channel.isLiveId(ch.rawId);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (shouldStopVod &&
          !_playback.isFullscreenActive &&
          identical(_playback.controller, oldController)) {
        unawaited(_playback.stop());
      }
    });
    _hideTimer?.cancel();
    _zapInfoTimer?.cancel();
    _topScope.removeListener(_onBarFocusChange);
    _bottomScope.removeListener(_onBarFocusChange);
    _switchButtonFocus.removeListener(_onBarFocusChange);
    _topScope.dispose();
    _infoFocus.dispose();
    _cancelInfoHold();
    _bottomScope.dispose();
    _playFocus.dispose();
    _switchButtonFocus.dispose();
    _rootFocus.dispose();
    // Defensive: never leave the whole app stuck in landscape/immersive
    // mode if this screen is popped while _immersive was still on.
    if (owned && (_immersive || _rotated)) _restoreChrome();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final playback = context.watch<PlaybackService>();
    final controller = playback.controller;
    final miniPlayer = playback.pictureInPicture.active;
    final prefs = context.watch<AppPreferences>();
    // Just to rebuild (and so the star reflects the current state) when
    // toggled from this screen — widget.channel is the same object
    // instance PlaylistManager.toggleFavorite mutates, not a copy.
    final playlist = context.watch<PlaylistManager>();
    // Auto-advancing into the next episode (see PlaybackService's up-next
    // queue) swaps `playback.currentChannel` without this screen being
    // popped/re-pushed — everything below reflects whatever's *actually*
    // playing, not just the episode this screen was originally opened for.
    final channel = playback.currentChannel ?? widget.channel;
    // See PlayerControls.linkedChannel's doc comment. Resolved fresh on
    // every build (not cached) — a link the user just set in Settings, or
    // a channel that's disappeared from a refreshed catalog, should show
    // up/go away here without needing to reopen this screen.
    final channelLink = playlist.channelLinkFor(channel);
    final linkedChannel =
        channelLink == null ? null : playlist.resolveChannelLink(channelLink);
    // Read by [_handleUp]/[_handleDown] — kept in sync with whatever
    // VideoPlayerPane below actually decides to show (playback.error != null
    // && a linkedChannel to offer), same caching pattern as [_isTvLayout].
    _hasLinkedChannel = linkedChannel != null;
    _touch = !prefs.isTelevision;
    _isTvLayout = prefs.layoutMode == 'tv' ||
        (prefs.layoutMode == 'auto' &&
            (prefs.isTelevision ||
                MediaQuery.of(context).size.width >=
                    AppConstants.tvLayoutWidthThreshold));

    final controls = controller == null
        ? null
        : PlayerControls(
            controller: controller,
            active: _bottomVisible && !_panelOpen,
            onExitFullscreen: () => Navigator.of(context).pop(),
            onEnterPip:
                playback.pictureInPicture.supported ? _enterMiniPlayer : null,
            onRotate: _touch ? _toggleRotation : null,
            pictureFill: _pictureFill,
            onTogglePictureFit: _togglePictureFit,
            onOpenChannels: Channel.isLiveId(channel.rawId) ? _openPanel : null,
            title: channel.name,
            // epgId (rawId, or a manual override), not the composite `id` —
            // see PlaylistManager
            // .knownChannelIdsFor's doc comment;
            // Channel.isLiveId also documents
            // that it expects rawId, not id.
            channelId: channel.epgId,
            isLive: Channel.isLiveId(channel.rawId),
            isFavorite: channel.isFavorite,
            onToggleFavorite: () => playlist.toggleFavorite(channel),
            onPrevious: playback.previousUpChannel != null
                ? () => playback.play(playback.previousUpChannel!)
                : null,
            onNext: playback.nextUpChannel != null
                ? () => playback.play(playback.nextUpChannel!)
                : null,
            onActivity: _resetHideTimer,
            linkedChannel: linkedChannel,
            channel: channel,
            playFocusNode: _playFocus,
            onOpenMultiview:
                Channel.isLiveId(channel.rawId) && !prefs.hideMultiview
                    ? () => _openMultiview(channel)
                    : null,
          );

    return withTvThemeIfNeeded(
        context,
        (context) => PopScope(
            // Back with the side panel open just closes the panel.
            canPop: !_panelOpen,
            onPopInvokedWithResult: (didPop, _) {
              if (!didPop) _closePanel();
            },
            child: Scaffold(
              backgroundColor: Colors.black,
              body: CallbackShortcuts(
                bindings: <ShortcutActivator, VoidCallback>{
                  const SingleActivator(LogicalKeyboardKey.info,
                      includeRepeats: false): _showStreamInfo,
                  const SingleActivator(LogicalKeyboardKey.arrowUp): _handleUp,
                  const SingleActivator(LogicalKeyboardKey.arrowDown):
                      _handleDown,
                  // Some remotes send a single combined key, others send separate
                  // Play and Pause keys (e.g. a dedicated Pause button) — bound to
                  // the same toggle handler either way, since it already checks
                  // the actual current state rather than assuming.
                  const SingleActivator(LogicalKeyboardKey.mediaPlayPause):
                      _handlePlayPause,
                  const SingleActivator(LogicalKeyboardKey.mediaPlay):
                      _handlePlayPause,
                  const SingleActivator(LogicalKeyboardKey.mediaPause):
                      _handlePlayPause,
                  const SingleActivator(LogicalKeyboardKey.channelUp): () =>
                      _zapChannel(-1),
                  const SingleActivator(LogicalKeyboardKey.channelDown): () =>
                      _zapChannel(1),
                  const SingleActivator(LogicalKeyboardKey.pageUp): () =>
                      _zapChannel(-1),
                  const SingleActivator(LogicalKeyboardKey.pageDown): () =>
                      _zapChannel(1),
                  if (!_focusInBar) ...{
                    // Back is the only way out now; Left opens the side
                    // panel on a live channel (a no-op on movies/episodes).
                    const SingleActivator(LogicalKeyboardKey.arrowLeft): () {
                      if (Channel.isLiveId(channel.rawId)) _openPanel();
                    },
                    // Consume unhandled Right presses instead of searching focusable widgets
                    // on the covered catalogue route, which may contain a very large focus
                    // graph.
                    const SingleActivator(LogicalKeyboardKey.arrowRight): () {},
                    // No repeats: the OK held to open this player must not
                    // pop the card on arrival.
                  },
                },
                child: Focus(
                  focusNode: _rootFocus,
                  onKeyEvent: _rootKey,
                  autofocus: true,
                  child: _holdControls(GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: _revealBottomOnTap,
                    // Touch has no Left key: swipe right opens the side
                    // panel on a live channel, swipe left closes it.
                    onHorizontalDragEnd: _touch
                        ? (d) {
                            final v = d.primaryVelocity ?? 0;
                            if (v > 300 &&
                                !_panelOpen &&
                                Channel.isLiveId(channel.rawId)) {
                              _openPanel();
                            } else if (v < -300 && _panelOpen) {
                              _closePanel();
                            }
                          }
                        : null,
                    // No outer SafeArea here (deliberately — it was tried and
                    // wasn't the fix; left off anyway since it's unneeded once the
                    // real bug below is fixed). The top/bottom bars keep their own
                    // narrow `SafeArea(bottom: false)` for their own content.
                    //
                    // Every entry in this Stack's children list must resolve to a
                    // `Positioned` widget, with no exceptions — see [_UpNextBubble]
                    // for why: Stack only sizes itself to fill the available space
                    // (`constraints.biggest`) when *every* child is `Positioned`;
                    // a single non-positioned child (even a zero-size
                    // `SizedBox.shrink()`) makes Stack size itself to fit that
                    // child instead, which was collapsing this entire Stack —
                    // video included — to 0x0 whenever `_UpNextBubble` had nothing
                    // to show (i.e. essentially always). That was the actual cause
                    // of the black fullscreen screen.
                    child: Stack(
                      children: [
                        Positioned.fill(
                          // Key by channel so a new selection cannot retain the previous
                          // video surface.
                          child: VideoPlayerPane(
                            key: ValueKey(channel.id),
                            showControls: false,
                            showEpgBar: false,
                            fillScreen: !miniPlayer && _pictureFill,
                            fullscreen: true,
                            switchButtonFocusNode: _switchButtonFocus,
                          ),
                        ),
                        if (!miniPlayer) ...[
                          // Top bar: back, current/next EPG line (live only), search,
                          // fullscreen toggle. Positioned has to be the outermost
                          // widget of this Stack entry — burying it under
                          // ExcludeFocus/AnimatedOpacity (as an earlier draft of
                          // this did) breaks Stack's "nearest RenderObjectWidget
                          // ancestor" resolution for Positioned's parent data.
                          Positioned(
                            top: 0,
                            left: 0,
                            right: 0,
                            // Hidden = not tappable either (an invisible back
                            // button used to still catch taps up there).
                            child: IgnorePointer(
                              ignoring: !_topVisible,
                              child: ExcludeFocus(
                                excluding: !_topVisible,
                                child: AnimatedOpacity(
                                  opacity: _topVisible ? 1 : 0,
                                  duration: const Duration(milliseconds: 200),
                                  child: FocusTraversalGroup(
                                    child: FocusScope(
                                      node: _topScope,
                                      child: Container(
                                        decoration: const BoxDecoration(
                                            gradient: LinearGradient(
                                                begin: Alignment.topCenter,
                                                end: Alignment.bottomCenter,
                                                colors: [
                                              Color(0x50000000),
                                              Color(0x00000000)
                                            ])),
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 4, vertical: 4),
                                        child: SafeArea(
                                          bottom: false,
                                          child: Row(
                                            children: [
                                              _TopBarIconButton(
                                                icon: Icons.arrow_back,
                                                tooltip: tr('Back'),
                                                onPressed: () =>
                                                    Navigator.of(context).pop(),
                                              ),
                                              const Spacer(),
                                              if (controls != null)
                                                controls.utilityActions(context,
                                                    infoFocusNode: _infoFocus),
                                              if (!Channel.isLiveId(
                                                  channel.rawId))
                                                _TopBarIconButton(
                                                    icon: Icons.search,
                                                    tooltip: tr('Search'),
                                                    onPressed: () => Navigator
                                                            .of(context)
                                                        .push(MaterialPageRoute(
                                                            builder: (_) =>
                                                                SearchScreen(
                                                                    initialScope:
                                                                        _searchScope)))),
                                            ],
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),

                          // CH+/CH- info card (see _zapChannel).
                          Positioned(
                            top: 24,
                            left: 0,
                            right: 0,
                            child: IgnorePointer(
                              child: AnimatedOpacity(
                                opacity: _zapInfoVisible ? 1 : 0,
                                duration: const Duration(milliseconds: 200),
                                child: Center(
                                  child: _ZapInfoCard(channel: channel),
                                ),
                              ),
                            ),
                          ),

                          // Embedded subtitles picked in the controls'
                          // Subtitles button (see SubtitleOverlay).
                          if (controller != null)
                            Positioned(
                              left: 0,
                              right: 0,
                              bottom:
                                  (_bottomVisible ? _controlsHeight + 8 : 32) +
                                      MediaQuery.paddingOf(context).bottom,
                              child: IgnorePointer(
                                child: SubtitleOverlay(controller: controller),
                              ),
                            ),

                          // Bottom bar: title, seek bar, play/pause.
                          if (controller != null)
                            Positioned(
                                left: 0,
                                right: 0,
                                bottom: 0,
                                child: IgnorePointer(
                                  ignoring: !_bottomVisible || _panelOpen,
                                  child: ExcludeFocus(
                                    excluding: !_bottomVisible,
                                    child: AnimatedOpacity(
                                      opacity: _bottomVisible ? 1 : 0,
                                      duration:
                                          const Duration(milliseconds: 200),
                                      child: FocusTraversalGroup(
                                        child: FocusScope(
                                          node: _bottomScope,
                                          child: SafeArea(
                                            key: const ValueKey(
                                                'fullscreen-controls-safe-area'),
                                            top: false,
                                            child: PlayerControlsSize(
                                                onHeight: (height) {
                                                  if (mounted &&
                                                      (_controlsHeight - height)
                                                              .abs() >
                                                          .5) {
                                                    setState(() =>
                                                        _controlsHeight =
                                                            height);
                                                  }
                                                },
                                                child: controls!),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                )),

                          if (controller != null)
                            _UpNextBubble(
                              controller: controller,
                              nextChannel: playback.nextUpChannel,
                              onPlayNow: () {
                                final next = playback.nextUpChannel;
                                if (next != null) playback.play(next);
                              },
                              onDismiss: playback.dismissAutoAdvance,
                            ),

                          // Always Positioned (see the Stack comment above).
                          // Use portrait width for readable channel and programme names.
                          Positioned(
                            left: 0,
                            top: 0,
                            bottom: 0,
                            width: _panelOpen
                                ? math.min(
                                    PlayerSidePanel.width,
                                    MediaQuery.sizeOf(context).width *
                                        (MediaQuery.sizeOf(context).width < 600
                                            ? 1
                                            : .88))
                                : 0,
                            child: _panelOpen
                                ? GestureDetector(
                                    // Taps on the panel's empty space mustn't
                                    // reach the video's tap-to-close.
                                    onTap: () {},
                                    child: PlayerSidePanel(
                                        current: channel,
                                        focusSearch: _panelSearch,
                                        onClose: _closePanel),
                                  )
                                : const SizedBox.shrink(),
                          ),
                        ],
                      ],
                    ),
                  )),
                ),
              ),
            )),
        preserveSubtree: true);
  }
}

/// A Netflix-style "Up Next" card in the corner of the screen once an
/// episode is close to ending — [PlaybackService] already auto-advances
/// at 30 seconds remaining; this surfaces that instead of letting it
/// happen silently, and lets the user jump immediately or cancel it for
/// this episode. Reacts to the controller directly (not `PlaybackService`,
/// which only notifies on channel/controller changes) since it needs to
/// know the position every tick, the same way the seek bar does.
class _UpNextBubble extends StatelessWidget {
  const _UpNextBubble({
    required this.controller,
    required this.nextChannel,
    required this.onPlayNow,
    required this.onDismiss,
  });

  final VideoPlayerHdrController controller;
  final Channel? nextChannel;
  final VoidCallback onPlayNow;
  final VoidCallback onDismiss;

  static const _showAt = Duration(seconds: 45);
  static const _autoAdvanceAt = Duration(seconds: 30);

  // Return Positioned in every branch. A bare shrink widget changes Stack sizing and can
  // collapse the fullscreen video despite bounded incoming constraints.
  static const _hidden = Positioned(
      right: 24, bottom: 110, width: 0, height: 0, child: SizedBox.shrink());

  @override
  Widget build(BuildContext context) {
    final next = nextChannel;
    if (next == null) return _hidden;
    return ValueListenableBuilder<VideoPlayerHdrValue>(
      valueListenable: controller,
      builder: (context, value, _) {
        final duration = value.duration;
        if (duration <= Duration.zero) return _hidden;
        final remaining = duration - value.position;
        if (remaining > _showAt || remaining < Duration.zero) return _hidden;

        final countdown = (remaining - _autoAdvanceAt).inSeconds.clamp(0, 999);
        final hasLogo = next.logoUrl != null && next.logoUrl!.isNotEmpty;

        return Positioned(
          right: 24,
          bottom: 110,
          width: 320,
          child: Material(
            color: Colors.black87,
            borderRadius: BorderRadius.circular(12),
            clipBehavior: Clip.antiAlias,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 56,
                    height: 56,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: hasLogo
                          ? CachedNetworkImage(
                              imageUrl: next.logoUrl!,
                              fit: BoxFit.cover,
                              errorWidget: (_, __, ___) =>
                                  const _UpNextFallbackIcon(),
                            )
                          : const _UpNextFallbackIcon(),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(tr('Up Next'),
                            style: const TextStyle(
                                color: Colors.white70, fontSize: 12)),
                        Text(
                          next.name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: Colors.white, fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          countdown > 0
                              ? tr('Playing in {countdown}s',
                                  {'countdown': countdown})
                              : tr('Playing now...'),
                          style: const TextStyle(
                              color: Colors.white54, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.play_circle_fill,
                            color: Colors.white, size: 30),
                        tooltip: tr('Play now'),
                        onPressed: onPlayNow,
                      ),
                      IconButton(
                        icon: const Icon(Icons.close,
                            color: Colors.white54, size: 18),
                        tooltip: tr('Dismiss'),
                        onPressed: onDismiss,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _UpNextFallbackIcon extends StatelessWidget {
  const _UpNextFallbackIcon();

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.grey.shade800,
      alignment: Alignment.center,
      child: const Icon(Icons.movie, color: Colors.white38, size: 28),
    );
  }
}

/// Plain [IconButton]s gave no visible cue for which of the top bar's three
/// buttons the D-pad cursor was actually on — Material's default focus
/// highlight is too subtle to read at 10-foot distance, especially over a
/// busy video background. Same highlight pattern as the rest of the TV UI
/// (Material+InkWell+onFocusChange, e.g. TvHomeScreen's _SelectableRow): a
/// solid filled circle behind the icon while focused.
class _TopBarIconButton extends StatelessWidget {
  const _TopBarIconButton(
      {required this.icon, required this.onPressed, this.tooltip});
  final IconData icon;
  final VoidCallback onPressed;
  final String? tooltip;
  @override
  Widget build(BuildContext context) =>
      PlayerAction(icon: icon, label: tooltip ?? '', onPressed: onPressed);
}

class _ZapInfoCard extends StatelessWidget {
  const _ZapInfoCard({required this.channel});

  final Channel channel;

  @override
  Widget build(BuildContext context) {
    final epg = context.watch<EpgService>();
    // epgId (rawId or a manual override), not the composite id.
    final EpgProgram? program = epg.getCurrentProgram(channel.epgId);
    final now = DateTime.now();
    final time = TimeFormat.hm;
    final logo = channel.logoUrl;
    return Container(
      constraints: const BoxConstraints(maxWidth: 760),
      margin: const EdgeInsets.symmetric(horizontal: 24),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      decoration: BoxDecoration(
        // Lighter than the bars: the picture should show through.
        color: playerPanelColor,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: const Color(0xFF36424F)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 56,
            height: 56,
            child: (logo != null && logo.isNotEmpty)
                ? CachedNetworkImage(
                    imageUrl: logo,
                    fit: BoxFit.contain,
                    errorWidget: (_, __, ___) =>
                        const Icon(Icons.tv, color: Colors.white54))
                : const Icon(Icons.tv, color: Colors.white54),
          ),
          const SizedBox(width: 14),
          Flexible(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(channel.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context)
                        .textTheme
                        .titleMedium
                        ?.copyWith(color: Colors.white)),
                if (program == null)
                  Text(tr('No program data available'),
                      style: const TextStyle(color: Colors.white70))
                else ...[
                  Text(program.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white)),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Text(
                          '${time.format(program.start)} - ${time.format(program.stop)}',
                          style: const TextStyle(
                              color: Colors.white70, fontSize: 12)),
                      const SizedBox(width: 12),
                      Expanded(
                        child: LinearProgressIndicator(
                            value: program.stop.isAfter(program.start)
                                ? (now.difference(program.start).inSeconds /
                                        program.stop
                                            .difference(program.start)
                                            .inSeconds)
                                    .clamp(0.0, 1.0)
                                : 0.0),
                      ),
                    ],
                  ),
                  if (program.description != null) ...[
                    const SizedBox(height: 4),
                    Text(program.description!,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: Colors.white70, fontSize: 12)),
                  ],
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
