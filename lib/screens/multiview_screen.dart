import '../utils/guarded_dialog.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:video_player_hdr/video_player_hdr.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../models/channel.dart';
import '../services/app_preferences.dart';
import '../services/device_memory_service.dart';
import '../services/multiview_session.dart';
import '../services/playback_service.dart';
import '../services/storage_service.dart';
import '../widgets/hold_to_activate.dart';
import '../widgets/multiview_channel_picker.dart';
import '../widgets/player_dialog.dart';
import '../widgets/tv_menu_tile.dart';

enum _MultiviewLayout { automatic, sideBySide, stacked, grid }

/// An independent, bounded playback session. Opening/closing this route is the
/// ownership boundary: the normal preview stops before any grid player opens.
class MultiviewScreen extends StatefulWidget {
  const MultiviewScreen(
      {super.key, this.initialChannel, this.additionalChannel, this.session});
  final Channel? initialChannel;
  final Channel? additionalChannel;
  @visibleForTesting
  final MultiviewSession? session;
  @override
  State<MultiviewScreen> createState() => _MultiviewScreenState();
}

class _MultiviewScreenState extends State<MultiviewScreen>
    with WidgetsBindingObserver {
  late final MultiviewSession _session;
  final _nodes =
      List.generate(4, (i) => FocusNode(debugLabel: 'multiview-cell-$i'));
  final _back = FocusNode(debugLabel: 'multiview-back');
  final _layoutNode = FocusNode(debugLabel: 'multiview-layout');
  final _muteNode = FocusNode(debugLabel: 'multiview-mute');
  final _helpNode = FocusNode(debugLabel: 'multiview-help');
  final _optionsNode = FocusNode(debugLabel: 'multiview-options');
  final _changeNode = FocusNode(debugLabel: 'multiview-change');
  final _focused = ValueNotifier<int>(0);
  final _touchChrome = ValueNotifier<bool>(true);
  Timer? _chromeTimer;

  void _showTouchControls() {
    if (_tv) return;
    _touchChrome.value = true;
    _chromeTimer?.cancel();
    _chromeTimer = Timer(const Duration(seconds: 4), () {
      if (!mounted) return;
      if (_dialog) {
        _showTouchControls();
      } else {
        _touchChrome.value = false;
      }
    });
  }

  void _tapCell(int i) {
    final revealOnly =
        !_tv && !_touchChrome.value && _session.cells[i].channel != null;
    _showTouchControls();
    if (!revealOnly) _activate(i);
  }

  late final Listenable _chromeChanges;
  late final List<Listenable> _cellChanges;
  final _audible = List.generate(4, (_) => ValueNotifier<bool>(false));
  void _syncAudioIndicators() {
    for (var i = 0; i < _audible.length; i++) {
      _audible[i].value = _session.active == i && !_session.muted;
    }
  }

  _MultiviewLayout _layout = _MultiviewLayout.automatic;
  bool _fillVideo = false;
  int get _count => _layout == _MultiviewLayout.grid ? 4 : 2;
  int _columns(Size size) => switch (_layout) {
        _MultiviewLayout.stacked => 1,
        _MultiviewLayout.automatic => size.height > size.width ? 1 : 2,
        _ => 2,
      };
  int? _fullscreen;
  bool _ready = false, _dialog = false, _leaving = false, _smallDevice = true;
  bool get _tv => context.read<AppPreferences>().isTelevision;

  @override
  void initState() {
    super.initState();
    final storage = context.read<StorageService>();
    _layout = _MultiviewLayout.values.firstWhere(
        (layout) => layout.name == storage.getMultiviewLayout(),
        orElse: () => _MultiviewLayout.automatic);
    _fillVideo = storage.getMultiviewFill();
    _session = widget.session ?? MultiviewSession();
    unawaited(_session.setVisibleCount(_count));
    _chromeChanges = Listenable.merge([_session, _focused, ..._session.cells]);
    _syncAudioIndicators();
    _session.addListener(_syncAudioIndicators);
    _cellChanges = [
      for (var i = 0; i < _session.cells.length; i++)
        Listenable.merge([_session.cells[i], _audible[i]])
    ];
    WidgetsBinding.instance.addObserver(this);
    unawaited(_start());
  }

  Future<void> _start() async {
    // Await release of the existing preview, including its provider connection.
    await context.read<PlaybackService>().stop();
    if (!mounted) return;
    await WakelockPlus.enable();
    if (!mounted) return;
    setState(() => _ready = true);
    _showTouchControls();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _nodes[widget.initialChannel == null ? 0 : 1].requestFocus();
    });
    if (widget.initialChannel != null) {
      // Register both intentions before yielding. The session serialises their
      // connections and cancels an older assignment if the user changes a tile.
      unawaited(_assign(0, widget.initialChannel!));
      if (widget.additionalChannel != null) {
        unawaited(_assign(1, widget.additionalChannel!));
      }
    }
    final memory = await DeviceMemoryService.getMemoryInfo();
    if (mounted) {
      setState(() => _smallDevice =
          memory == null || memory.isLowRamDevice || memory.totalMemGB < 3);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      unawaited(_session.suspend(true));
    } else if (state == AppLifecycleState.resumed) {
      unawaited(_session.suspend(false));
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _session.removeListener(_syncAudioIndicators);
    _session.dispose();
    for (final audible in _audible) {
      audible.dispose();
    }
    for (final n in _nodes) {
      n.dispose();
    }
    _back.dispose();
    _layoutNode.dispose();
    _muteNode.dispose();
    _helpNode.dispose();
    _optionsNode.dispose();
    _changeNode.dispose();
    _focused.dispose();
    _chromeTimer?.cancel();
    _touchChrome.dispose();
    unawaited(WakelockPlus.disable());
    super.dispose();
  }

  int _viewIntent = 0;
  Future<void> _exit() async {
    ++_viewIntent;
    if (_fullscreen != null) {
      final i = _fullscreen!;
      setState(() => _fullscreen = null);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _nodes[i].requestFocus();
      });
      return;
    }
    if (_leaving) return;
    setState(() => _leaving = true);
    await _session.close();
    await WidgetsBinding.instance.endOfFrame;
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _assign(int i, Channel c) async {
    try {
      await _session.assign(i, c);
    } on StateError catch (e) {
      if (!mounted || _leaving) return;
      if (_dialog) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.message)));
        return;
      }
      _dialog = true;
      await showGuardedDialog<void>(
          context: context,
          builder: (_) => PlayerDialog(
              title: 'Another stream cannot be opened',
              icon: Icons.info_outline,
              child: Padding(
                  padding: const EdgeInsets.all(16), child: Text(e.message))));
      _dialog = false;
      if (mounted) _nodes[i].requestFocus();
    }
  }

  Future<void> _pick(int i) async {
    if (_dialog || !_ready || _leaving) return;
    _dialog = true;
    final chosen = await Navigator.of(context).push<Channel>(PageRouteBuilder(
        transitionDuration: Duration.zero,
        reverseTransitionDuration: Duration.zero,
        pageBuilder: (_, __, ___) => MultiviewChannelPicker(
              screenNumber: i + 1,
              currentChannel: _session.cells[i].channel,
              unavailableReason: (c) => _session.problemFor(i, c),
              selectedIds: {
                for (var j = 0; j < 4; j++)
                  if (j != i &&
                      _session.cells[j].channel != null &&
                      (_session.cells[j].loading ||
                          _session.cells[j].controller != null))
                    _session.cells[j].channel!.id
              },
            )));
    _dialog = false;
    if (!mounted) return;
    _nodes[i].requestFocus();
    final cell = _session.cells[i];
    final unchanged = chosen?.url == cell.channel?.url &&
        cell.controller?.value.isInitialized == true &&
        cell.error == null;
    if (chosen != null && !unchanged) await _assign(i, chosen);
  }

  void _activate(int i) {
    _focused.value = i;
    final c = _session.cells[i];
    if (_leaving || _dialog) return;
    if (c.channel == null) {
      _pick(i);
    } else if (c.error != null) {
      _actions(i);
    } else if (_session.active != i || _session.muted) {
      _session.selectAudio(i);
    } else if (c.controller?.value.isInitialized == true) {
      if (_fullscreen == null) _expand(i);
    }
  }

  Future<void> _expand(int i) async {
    if (_leaving ||
        _dialog ||
        _session.cells[i].controller?.value.isInitialized != true) {
      return;
    }
    final intent = ++_viewIntent;
    await _session.selectAudio(i);
    if (mounted && !_leaving && intent == _viewIntent) {
      setState(() => _fullscreen = i);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_leaving && intent == _viewIntent) {
          _nodes[i].requestFocus();
        }
      });
    }
  }

  Future<void> _actions(int i) async {
    if (_dialog) return;
    _dialog = true;
    final c = _session.cells[i];
    final action = await showGuardedDialog<String>(
        context: context,
        builder: (ctx) => SwallowHeldActivate(
            child: PlayerDialog(
                title: 'Screen ${i + 1}',
                subtitle: c.channel?.name,
                icon: Icons.live_tv_outlined,
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  if (c.controller?.value.isInitialized == true)
                    TvMenuTile(
                        icon: _session.active == i && !_session.muted
                            ? Icons.volume_off_outlined
                            : Icons.volume_up_outlined,
                        title: _session.active == i && !_session.muted
                            ? 'Mute'
                            : 'Listen to this channel',
                        onTap: () => Navigator.pop(ctx, 'audio')),
                  if (c.controller?.value.isInitialized == true &&
                      _fullscreen == null)
                    TvMenuTile(
                        icon: Icons.fullscreen,
                        title: 'Fullscreen',
                        onTap: () => Navigator.pop(ctx, 'full')),
                  TvMenuTile(
                      icon: Icons.swap_horiz,
                      title:
                          c.channel == null ? 'Add channel' : 'Change channel',
                      autofocus: true,
                      onTap: () => Navigator.pop(ctx, 'change')),
                  if (c.channel != null)
                    TvMenuTile(
                        icon: Icons.refresh,
                        title: 'Reconnect',
                        onTap: () => Navigator.pop(ctx, 'retry')),
                  if (c.channel != null)
                    TvMenuTile(
                        icon: Icons.close,
                        title: 'Remove channel',
                        onTap: () => Navigator.pop(ctx, 'remove')),
                ]))));
    _dialog = false;
    if (!mounted) return;
    _nodes[i].requestFocus();
    switch (action) {
      case 'audio':
        if (_session.active == i && !_session.muted) {
          await _session.toggleMute();
        } else {
          await _session.selectAudio(i);
        }
      case 'full':
        await _expand(i);
      case 'change':
        await _pick(i);
      case 'retry':
        if (c.channel != null) await _assign(i, c.channel!);
      case 'remove':
        await _session.clear(i);
        if (_fullscreen == i && mounted) await _exit();
    }
  }

  Future<void> _layouts() async {
    if (_dialog) return;
    _dialog = true;
    final selected = await showGuardedDialog<_MultiviewLayout>(
        context: context,
        builder: (ctx) => StatefulBuilder(
            builder: (ctx, update) => PlayerDialog(
                title: 'Screen layout',
                icon: Icons.grid_view,
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  for (final option in [
                    (
                      _MultiviewLayout.automatic,
                      Icons.screen_rotation_outlined,
                      'Automatic',
                      'Two screens · follows device orientation'
                    ),
                    (
                      _MultiviewLayout.sideBySide,
                      Icons.view_column_outlined,
                      'Side by side',
                      'Two screens · left and right'
                    ),
                    (
                      _MultiviewLayout.stacked,
                      Icons.view_agenda_outlined,
                      'Stacked',
                      'Two screens · top and bottom'
                    ),
                    (
                      _MultiviewLayout.grid,
                      Icons.grid_view,
                      '4 screens',
                      _smallDevice
                          ? 'Use SD or 720p feeds for smoother playback'
                          : 'Four equal screens'
                    ),
                  ])
                    TvMenuTile(
                        icon: option.$2,
                        title: option.$3,
                        subtitle: option.$4,
                        trailing: _layout == option.$1
                            ? const Icon(Icons.check, size: 18)
                            : const SizedBox.shrink(),
                        autofocus: _layout == option.$1,
                        onTap: () => Navigator.pop(ctx, option.$1)),
                  const Divider(height: 1),
                  TvMenuTile(
                      key: const ValueKey('multiview-fill'),
                      icon: Icons.fit_screen,
                      title: 'Fill screens',
                      subtitle: _fillVideo
                          ? 'Fills each video area · edges are cropped'
                          : 'Off · keeps the complete picture visible',
                      trailing: Icon(
                          _fillVideo
                              ? Icons.check_box_outlined
                              : Icons.check_box_outline_blank,
                          size: 20),
                      onTap: () {
                        setState(() => _fillVideo = !_fillVideo);
                        update(() {});
                        unawaited(context
                            .read<StorageService>()
                            .setMultiviewFill(_fillVideo));
                      }),
                  if (_count == 4)
                    const Padding(
                        padding: EdgeInsets.fromLTRB(16, 0, 16, 12),
                        child: Text('Two-screen layouts close screens 3 and 4.',
                            style: TextStyle(
                                fontSize: 11, color: Colors.white60))),
                ]))));
    _dialog = false;
    if (!mounted || selected == null) return;
    final count = selected == _MultiviewLayout.grid ? 4 : 2;
    if (count != _count) await _session.setVisibleCount(count);
    if (!mounted) return;
    setState(() {
      _layout = selected;
      _focused.value = _focused.value.clamp(0, count - 1);
    });
    unawaited(context.read<StorageService>().setMultiviewLayout(selected.name));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _nodes[_focused.value].requestFocus();
    });
  }

  Future<void> _help() async {
    if (_dialog) return;
    _dialog = true;
    await showGuardedDialog<void>(
        context: context,
        builder: (_) => const PlayerDialog(
            title: 'Multiview',
            icon: Icons.grid_view,
            child: Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                    'Add a channel to each screen. The speaker icon marks the channel you hear.\n\n'
                    'Choose another screen to listen to it, then select it again for fullscreen. Channel options let you change, reconnect or remove it.\n\n'
                    'Each channel needs a provider connection. Other devices count too.\n\n'
                    'Two screens are recommended on smaller TVs. For four screens, choose SD or 720p feeds.'))));
    _dialog = false;
  }

  KeyEventResult _key(int i, KeyEvent e, int columns) {
    if (e is KeyUpEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    if (k == LogicalKeyboardKey.contextMenu || k == LogicalKeyboardKey.info) {
      _actions(i);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowUp) {
      if (_fullscreen != null || i < columns) {
        _back.requestFocus();
      } else {
        _nodes[i - columns].requestFocus();
      }
    } else if (k == LogicalKeyboardKey.arrowDown) {
      if (_fullscreen == null && i + columns < _count) {
        _nodes[i + columns].requestFocus();
      } else {
        _changeNode.requestFocus();
      }
    } else if (k == LogicalKeyboardKey.arrowLeft) {
      if (_fullscreen == null && i % columns > 0) _nodes[i - 1].requestFocus();
    } else if (k == LogicalKeyboardKey.arrowRight) {
      if (_fullscreen == null && i % columns < columns - 1 && i + 1 < _count) {
        _nodes[i + 1].requestFocus();
      }
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  String _primaryLabel(int i) {
    final cell = _session.cells[i];
    if (cell.channel == null) return 'Add channel';
    if (cell.error != null) return 'Channel options';
    if (cell.loading) return 'Connecting…';
    if (_session.active != i || _session.muted) return 'Listen to this channel';
    return _fullscreen == null
        ? 'Watch fullscreen'
        : 'Back returns to multiview';
  }

  Widget _cell(int i, int columns) => RepaintBoundary(
        key: ValueKey('multiview-surface-$i'),
        child: ListenableBuilder(
          listenable: _cellChanges[i],
          builder: (_, __) {
            final cell = _session.cells[i];
            final sound =
                _session.active == i && !_session.muted && cell.channel != null;
            final initialized = cell.controller?.value.isInitialized == true;
            return Focus(
              onKeyEvent: (_, e) => _key(i, e, columns),
              child: HoldToActivate(
                onTap: () => _activate(i),
                onHold: cell.channel == null ? null : () => _actions(i),
                child: InkWell(
                  key: ValueKey('multiview-cell-$i'),
                  focusNode: _nodes[i],
                  onFocusChange: (on) {
                    if (on && mounted) _focused.value = i;
                  },
                  onTap: () => _tapCell(i),
                  onLongPress: cell.channel == null ? null : () => _actions(i),
                  child: CustomPaint(
                    key: ValueKey('multiview-focus-$i'),
                    foregroundPainter: _MultiviewFocusPainter(_nodes[i]),
                    child: Container(
                      color: const Color(0xFF0A0E13),
                      child: Stack(children: [
                        Positioned.fill(
                            child: Stack(
                                key: ValueKey('multiview-video-area-$i'),
                                fit: StackFit.expand,
                                children: [
                              if (initialized)
                                ClipRect(
                                  child: SizedBox.expand(
                                    child: FittedBox(
                                      fit: _fillVideo && _fullscreen == null
                                          ? BoxFit.cover
                                          : BoxFit.contain,
                                      child: SizedBox(
                                        width:
                                            cell.controller!.value.aspectRatio >
                                                    0
                                                ? cell.controller!.value
                                                        .aspectRatio *
                                                    100
                                                : 160,
                                        height:
                                            cell.controller!.value.aspectRatio >
                                                    0
                                                ? 100
                                                : 90,
                                        child: RepaintBoundary(
                                            child: VideoPlayerHdr(
                                                cell.controller!,
                                                key: ObjectKey(
                                                    cell.controller))),
                                      ),
                                    ),
                                  ),
                                ),
                              if (cell.channel == null)
                                Center(
                                    child: Column(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                      Container(
                                          padding: const EdgeInsets.all(12),
                                          decoration: const BoxDecoration(
                                              color: Color(0xFF182632),
                                              shape: BoxShape.circle),
                                          child: const Icon(Icons.add,
                                              color: Color(0xFF9BCEF4),
                                              size: 28)),
                                      const SizedBox(height: 10),
                                      Text('Add channel',
                                          style: Theme.of(context)
                                              .textTheme
                                              .titleSmall),
                                      const SizedBox(height: 4),
                                      Text('Screen ${i + 1}',
                                          style: const TextStyle(
                                              fontSize: 11,
                                              color: Colors.white54)),
                                    ])),
                              if (cell.loading ||
                                  cell.error != null ||
                                  cell.controller?.value.isBuffering == true ||
                                  cell.controller?.value.isPlaying == false)
                                Center(
                                    child: Container(
                                        margin: const EdgeInsets.all(12),
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 12, vertical: 8),
                                        decoration: BoxDecoration(
                                            color: const Color(0xE6111820),
                                            borderRadius:
                                                BorderRadius.circular(4)),
                                        child: Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Icon(
                                                  cell.error == null
                                                      ? Icons.hourglass_top
                                                      : Icons.error_outline,
                                                  size: 17,
                                                  color:
                                                      const Color(0xFF9BCEF4)),
                                              const SizedBox(width: 8),
                                              Flexible(
                                                  child: Text(
                                                      cell.error ??
                                                          (cell.loading
                                                              ? 'Connecting…'
                                                              : cell.controller?.value
                                                                          .isBuffering ==
                                                                      true
                                                                  ? 'Buffering…'
                                                                  : 'Waiting for stream…'),
                                                      style: const TextStyle(
                                                          fontSize: 12))),
                                            ]))),
                            ])),
                        // Touch controls overlay the picture and hide together;
                        // they never change the dimensions of a video surface.
                        if (cell.channel != null && !_tv)
                          Positioned(
                            left: 0,
                            right: 0,
                            bottom: 0,
                            child: _overlayChrome(
                              nodes: const [],
                              child: SafeArea(
                                top: false,
                                left: _fullscreen != null || i % columns == 0,
                                right: _fullscreen != null ||
                                    i % columns == columns - 1,
                                bottom: _fullscreen != null ||
                                    i + columns >= _count,
                                child: SizedBox(
                                  key: ValueKey('multiview-channel-label-$i'),
                                  height: 44,
                                  child: Row(children: [
                                    IconButton(
                                      tooltip: sound
                                          ? 'Mute this channel'
                                          : 'Listen to this channel',
                                      iconSize: 19,
                                      constraints:
                                          const BoxConstraints.tightFor(
                                              width: 38, height: 44),
                                      onPressed: () {
                                        _focused.value = i;
                                        sound
                                            ? _session.toggleMute()
                                            : _session.selectAudio(i);
                                      },
                                      icon: Icon(
                                          sound
                                              ? Icons.volume_up
                                              : Icons.volume_off_outlined,
                                          color: sound
                                              ? const Color(0xFF9BCEF4)
                                              : Colors.white54),
                                    ),
                                    Expanded(
                                        child: Text(cell.channel!.name,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(
                                                fontSize: 12,
                                                fontWeight: FontWeight.w500))),
                                    IconButton(
                                      tooltip: _fullscreen == null
                                          ? 'Fullscreen'
                                          : 'Back to multiview',
                                      iconSize: 20,
                                      constraints:
                                          const BoxConstraints.tightFor(
                                              width: 38, height: 44),
                                      onPressed: !initialized
                                          ? null
                                          : _fullscreen == null
                                              ? () => _expand(i)
                                              : _exit,
                                      icon: Icon(_fullscreen == null
                                          ? Icons.fullscreen
                                          : Icons.fullscreen_exit),
                                    ),
                                    IconButton(
                                      tooltip: 'Screen options',
                                      iconSize: 20,
                                      constraints:
                                          const BoxConstraints.tightFor(
                                              width: 38, height: 44),
                                      onPressed: () {
                                        _focused.value = i;
                                        _actions(i);
                                      },
                                      icon: const Icon(Icons.more_horiz),
                                    ),
                                  ]),
                                ),
                              ),
                            ),
                          ),
                      ]),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      );

  Widget _toolbar(bool narrow) => ListenableBuilder(
        listenable: _chromeChanges,
        builder: (_, __) => Focus(
          onKeyEvent: (_, e) {
            final nodes = [
              _back,
              if (_fullscreen == null) _layoutNode,
              _muteNode,
              _helpNode
            ];
            if (e is KeyUpEvent) return KeyEventResult.ignored;
            final k = e.logicalKey;
            if (k == LogicalKeyboardKey.arrowLeft ||
                k == LogicalKeyboardKey.arrowRight) {
              final at = nodes.indexWhere((n) => n.hasFocus);
              if (at >= 0) {
                nodes[(at + (k == LogicalKeyboardKey.arrowRight ? 1 : -1))
                        .clamp(0, nodes.length - 1)]
                    .requestFocus();
              }
              return KeyEventResult.handled;
            }
            if (k == LogicalKeyboardKey.arrowUp) return KeyEventResult.handled;
            if (k == LogicalKeyboardKey.arrowDown) {
              _nodes[_fullscreen ?? _focused.value].requestFocus();
              return KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          },
          child: SizedBox(
              height: _tv ? 40 : 44,
              child: Row(children: [
                IconButton(
                    focusNode: _back,
                    tooltip: _fullscreen == null
                        ? 'Exit multiview'
                        : 'Back to multiview',
                    onPressed: _exit,
                    icon: const Icon(Icons.arrow_back, size: 21)),
                Expanded(
                    child: Text(
                        _fullscreen == null
                            ? 'Multiview'
                            : 'Screen ${_fullscreen! + 1}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 15, fontWeight: FontWeight.w600))),
                if (_fullscreen == null)
                  TextButton.icon(
                      key: const ValueKey('multiview-layout'),
                      focusNode: _layoutNode,
                      onPressed: _layouts,
                      icon: Icon(
                          _count == 2
                              ? (_columns(MediaQuery.sizeOf(context)) == 1
                                  ? Icons.view_agenda_outlined
                                  : Icons.view_column_outlined)
                              : Icons.grid_view,
                          size: 17),
                      label: Row(mainAxisSize: MainAxisSize.min, children: [
                        Text(narrow ? '$_count' : '$_count screens',
                            style: const TextStyle(fontSize: 12)),
                        const Icon(Icons.expand_more, size: 16),
                      ])),
                IconButton(
                    key: const ValueKey('multiview-mute'),
                    focusNode: _muteNode,
                    tooltip: _session.muted
                        ? 'Unmute screen ${_session.active + 1}'
                        : 'Mute screen ${_session.active + 1}',
                    onPressed: _session.toggleMute,
                    iconSize: 21,
                    icon: Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(_session.muted
                          ? Icons.volume_off_outlined
                          : Icons.volume_up_outlined),
                      const SizedBox(width: 4),
                      Text('${_session.active + 1}',
                          style: const TextStyle(fontSize: 11)),
                    ])),
                IconButton(
                    tooltip: 'Multiview help',
                    focusNode: _helpNode,
                    onPressed: _help,
                    iconSize: 20,
                    icon: const Icon(Icons.help_outline)),
              ])),
        ),
      );

  // Keep remote targets mounted so an explicit focus request can reveal them.
  // Only chrome rebuilds on focus changes; video geometry remains unchanged.
  Widget _overlayChrome(
          {required List<FocusNode> nodes, required Widget child}) =>
      ListenableBuilder(
        listenable: Listenable.merge([...nodes, _touchChrome]),
        child: Listener(
          onPointerDown: (_) => _showTouchControls(),
          child: ColoredBox(color: const Color(0xDC111820), child: child),
        ),
        builder: (_, child) {
          final visible =
              _tv ? nodes.any((node) => node.hasFocus) : _touchChrome.value;
          return IgnorePointer(
            ignoring: !visible,
            child: ExcludeSemantics(
              excluding: !visible,
              child: Opacity(opacity: visible ? 1 : 0, child: child),
            ),
          );
        },
      );

  Widget _remoteHelp() => ListenableBuilder(
      listenable: _chromeChanges,
      builder: (_, __) => SizedBox(
          height: 30,
          child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(children: [
                Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                    decoration: BoxDecoration(
                        color: const Color(0xFF263644),
                        borderRadius: BorderRadius.circular(3)),
                    child: Text(_fullscreen == null ? 'OK' : 'BACK',
                        style: const TextStyle(
                            fontSize: 10, fontWeight: FontWeight.w700))),
                const SizedBox(width: 7),
                Expanded(
                    child: Text(
                        _fullscreen == null
                            ? (_session.cells[_focused.value].channel != null
                                ? '${_session.cells[_focused.value].channel!.name} · ${_primaryLabel(_focused.value)}'
                                : _primaryLabel(_focused.value))
                            : 'Return to multiview',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 11, color: Colors.white70))),
                Focus(
                    onKeyEvent: (_, e) {
                      if (e is KeyUpEvent) {
                        return KeyEventResult.ignored;
                      }
                      if (e.logicalKey == LogicalKeyboardKey.arrowUp) {
                        _nodes[_fullscreen ?? _focused.value].requestFocus();
                        return KeyEventResult.handled;
                      }
                      if (e.logicalKey == LogicalKeyboardKey.arrowLeft) {
                        _changeNode.requestFocus();
                        return KeyEventResult.handled;
                      }
                      if (e.logicalKey == LogicalKeyboardKey.arrowRight) {
                        _optionsNode.requestFocus();
                        return KeyEventResult.handled;
                      }
                      if (e.logicalKey == LogicalKeyboardKey.arrowDown) {
                        return KeyEventResult.handled;
                      }
                      return KeyEventResult.ignored;
                    },
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      TextButton.icon(
                        key: const ValueKey('multiview-change'),
                        focusNode: _changeNode,
                        onPressed: () => _pick(_fullscreen ?? _focused.value),
                        icon: const Icon(Icons.swap_horiz, size: 16),
                        label: Text(
                            'Screen ${(_fullscreen ?? _focused.value) + 1} · ${_session.cells[_fullscreen ?? _focused.value].channel == null ? 'Add channel' : 'Change channel'}',
                            style: const TextStyle(fontSize: 11)),
                      ),
                      TextButton.icon(
                        key: const ValueKey('multiview-options'),
                        focusNode: _optionsNode,
                        onPressed: () =>
                            _actions(_fullscreen ?? _focused.value),
                        icon: const Icon(Icons.tune, size: 15),
                        label: const Text('Options',
                            style: TextStyle(fontSize: 11)),
                      )
                    ])),
              ]))));

  @override
  Widget build(BuildContext context) => PopScope(
        canPop: _leaving,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) _exit();
        },
        child: Scaffold(
            backgroundColor: const Color(0xFF111820),
            body: LayoutBuilder(builder: (context, box) {
              final columns = _columns(Size(box.maxWidth, box.maxHeight));
              return Stack(children: [
                Positioned.fill(
                    child: !_ready || _leaving
                        ? Center(
                            child: Text(_leaving
                                ? 'Closing multiview…'
                                : 'Preparing multiview…'))
                        : LayoutBuilder(builder: (_, area) {
                            final rows = (_count / columns).ceil();
                            final width = area.maxWidth / columns;
                            final height = area.maxHeight / rows;
                            // Stable sibling slots preserve video state without
                            // reparenting a surface during fullscreen transitions.
                            return Stack(children: [
                              for (var i = 0; i < _count; i++)
                                Positioned(
                                    left: _fullscreen == i
                                        ? 0
                                        : (i % columns) * width,
                                    top: _fullscreen == i
                                        ? 0
                                        : (i ~/ columns) * height,
                                    width: _fullscreen == i
                                        ? area.maxWidth
                                        : width,
                                    height: _fullscreen == i
                                        ? area.maxHeight
                                        : height,
                                    child: ExcludeFocus(
                                        excluding: _fullscreen != null &&
                                            _fullscreen != i,
                                        child: Offstage(
                                            offstage: _fullscreen != null &&
                                                _fullscreen != i,
                                            child: _cell(i, columns))))
                            ]);
                          })),
                Positioned(
                  left: 0,
                  right: 0,
                  top: 0,
                  child: _overlayChrome(
                    nodes: [
                      _back,
                      _layoutNode,
                      _muteNode,
                      _helpNode,
                      _changeNode,
                      _optionsNode
                    ],
                    child: SafeArea(
                        bottom: false, child: _toolbar(box.maxWidth < 600)),
                  ),
                ),
                if (_tv)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: _overlayChrome(
                      nodes: [
                        _back,
                        _layoutNode,
                        _muteNode,
                        _helpNode,
                        _changeNode,
                        _optionsNode
                      ],
                      child: _remoteHelp(),
                    ),
                  ),
              ]);
            })),
      );
}

/// Small neutral corner marks indicate remote focus only. Audio selection never
/// draws an outline around a stream, and focus changes only repaint this layer.
class _MultiviewFocusPainter extends CustomPainter {
  _MultiviewFocusPainter(this.focus) : super(repaint: focus);
  final FocusNode focus;
  @override
  void paint(Canvas canvas, Size size) {
    if (!focus.hasFocus) return;
    final pen = Paint()
      ..color = const Color(0xAAB8C4CD)
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;
    const inset = 2.0, length = 9.0;
    final right = size.width - inset, bottom = size.height - inset;
    final path = Path()
      ..moveTo(inset, inset + length)
      ..lineTo(inset, inset)
      ..lineTo(inset + length, inset)
      ..moveTo(right - length, inset)
      ..lineTo(right, inset)
      ..lineTo(right, inset + length)
      ..moveTo(inset, bottom - length)
      ..lineTo(inset, bottom)
      ..lineTo(inset + length, bottom)
      ..moveTo(right - length, bottom)
      ..lineTo(right, bottom)
      ..lineTo(right, bottom - length);
    canvas.drawPath(path, pen);
  }

  @override
  bool shouldRepaint(_MultiviewFocusPainter oldDelegate) =>
      oldDelegate.focus != focus;
}
