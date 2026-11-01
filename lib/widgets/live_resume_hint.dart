import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/channel.dart';
import '../screens/player_screen.dart';
import '../services/playback_service.dart';
import '../l10n/l10n.dart';

/// Text-only reminder and hold-Right shortcut for the active live channel or
/// pending startup-resume channel. Reuse the shared playback session without
/// mounting another native video surface.
///
/// Mounted beside the root Navigator so the shortcut works across screens;
/// [navigatorKey] supplies navigation because this widget is not its descendant.
class LiveResumeHint extends StatefulWidget {
  const LiveResumeHint({super.key, required this.navigatorKey});

  final GlobalKey<NavigatorState> navigatorKey;

  /// Screens that hide the reminder pill while they're open (Sports and
  /// Standings — it covered their tables). A count, not a bool, so stacked
  /// screens don't un-hide each other; use [hideWhileMounted]. Only the
  /// pill goes away; hold-Right still resumes. Shared with
  /// `DesktopLiveResumeHint`.
  static final ValueNotifier<int> hiddenBy = ValueNotifier(0);

  /// Settings > General > "Show the resume reminder" (set from storage at
  /// startup and by that switch). Off hides the pill everywhere; the
  /// hold-Right gesture keeps working.
  static final ValueNotifier<bool> pillEnabled = ValueNotifier(true);

  /// Whether a pill may be drawn right now (setting on, no screen hiding it).
  static bool get pillAllowed => pillEnabled.value && hiddenBy.value == 0;

  /// Call from a screen's initState; call the returned function from its
  /// dispose.
  static VoidCallback hideWhileMounted() {
    hiddenBy.value++;
    var released = false;
    return () {
      if (released) return;
      released = true;
      hiddenBy.value--;
    };
  }

  @override
  State<LiveResumeHint> createState() => _LiveResumeHintState();
}

/// setState for a pill listening to [LiveResumeHint.hiddenBy]: screens bump
/// it from initState/dispose, i.e. mid-frame, where a direct setState on
/// another widget asserts — defer to after the frame then.
void rebuildResumeHintSafely(State state, VoidCallback rebuild) {
  final phase = SchedulerBinding.instance.schedulerPhase;
  if (phase == SchedulerPhase.idle ||
      phase == SchedulerPhase.postFrameCallbacks) {
    rebuild();
  } else {
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (state.mounted) rebuild();
    });
  }
}

class _LiveResumeHintState extends State<LiveResumeHint> {
  // Deliberate hold threshold shared with the resume hint's other hold gestures.
  static const _holdDuration = Duration(milliseconds: 1200);

  Timer? _holdTimer;

  late final PlaybackService _playback;

  @override
  void initState() {
    super.initState();
    _playback = context.read<PlaybackService>();
    _playback.addListener(_onPlaybackChanged);
    LiveResumeHint.hiddenBy.addListener(_onHiddenChanged);
    LiveResumeHint.pillEnabled.addListener(_onHiddenChanged);
    // Two earlier versions of this each got half of it right and not the
    // other — see [_handleGlobalKey] for why neither the pill's own
    // "consume everything, synthesize a substitute on release" pattern
    // nor a fully non-blocking observer actually work for Right
    // specifically, and what this does instead.
    FocusManager.instance.addEarlyKeyEventHandler(_handleGlobalKey);
  }

  void _onPlaybackChanged() {
    if (mounted) setState(() {});
  }

  void _onHiddenChanged() =>
      rebuildResumeHintSafely(this, () => setState(() {}));

  @override
  void dispose() {
    _playback.removeListener(_onPlaybackChanged);
    LiveResumeHint.hiddenBy.removeListener(_onHiddenChanged);
    LiveResumeHint.pillEnabled.removeListener(_onHiddenChanged);
    FocusManager.instance.removeEarlyKeyEventHandler(_handleGlobalKey);
    _holdTimer?.cancel();
    super.dispose();
  }

  /// Whichever channel the pill would act on — a real already-playing
  /// background channel if there is one, otherwise the cold-launch
  /// [PlaybackService.pendingResumeChannel] nothing has actually opened
  /// yet. [PlayerScreen.initState] calling `play()` unconditionally is
  /// what makes a single code path in [_resume] correct for both: a
  /// no-op for the already-playing case (same channel, controller already
  /// exists), a real start for the pending one.
  Channel? get _resumableChannel =>
      _playback.currentChannel ?? _playback.pendingResumeChannel;

  bool get _canResume {
    final channel = _resumableChannel;
    if (channel == null ||
        // rawId, not the composite `id` — Channel.isLiveId expects the
        // raw, unprefixed id. With `id` here this always read false,
        // silently disabling this whole bubble for every live channel.
        !Channel.isLiveId(channel.rawId)) {
      return false;
    }
    if (_playback.currentChannel == null) {
      // Cold-launch pending case — nothing is open yet at all, so there's
      // no controller/fullscreen state to check.
      return true;
    }
    return _playback.controller != null && !_playback.isFullscreenActive;
  }

  /// Detect text editing from the focused node's context. Suppress resume gestures while
  /// editing because system keyboard navigation can generate indistinguishable arrow events.
  bool get _textFieldFocused =>
      FocusManager.instance.primaryFocus?.context
          ?.findAncestorWidgetOfExactType<EditableText>() !=
      null;

  /// Observe Right holds without consuming ordinary presses, preserving custom
  /// column-navigation shortcuts. Synthesized geometric focus movement would not reproduce
  /// those actions.
  KeyEventResult _handleGlobalKey(KeyEvent event) {
    if (!_canResume || _textFieldFocused) return KeyEventResult.ignored;
    if (event.logicalKey != LogicalKeyboardKey.arrowRight) {
      return KeyEventResult.ignored;
    }

    if (event is KeyDownEvent) {
      _holdTimer?.cancel();
      _holdTimer = Timer(_holdDuration, _resume);
      return KeyEventResult.ignored;
    }
    if (event is KeyRepeatEvent) return KeyEventResult.handled;
    if (event is KeyUpEvent) {
      _holdTimer?.cancel();
      _holdTimer = null;
      return KeyEventResult.ignored;
    }
    return KeyEventResult.ignored;
  }

  void _resume() {
    _holdTimer = null;
    // Re-check text-field focus when the delayed resume timer fires; focus may have moved
    // into an editor after the hold began.
    if (!mounted || !_canResume || _textFieldFocused) return;
    final channel = _resumableChannel;
    if (channel == null) return;
    final navigator = widget.navigatorKey.currentState;
    if (navigator != null) PlayerScreen.open(navigator, channel);
  }

  @override
  Widget build(BuildContext context) {
    final channel = _resumableChannel;
    final show = _canResume && channel != null && LiveResumeHint.pillAllowed;

    // Always Positioned, shown or not — a bare non-Positioned child here
    // would collapse this whole Stack (and the Navigator painted
    // alongside it) to 0x0. See player_screen.dart's `UpNextBubble` for
    // the full story on why.
    if (!show) {
      return const Positioned(
          bottom: 24, left: 0, right: 0, child: SizedBox.shrink());
    }

    // Portrait phone: clear TvHomeScreen's bottom tab bar.
    final size = MediaQuery.sizeOf(context);
    final phonePortrait = size.width < 600 && size.height > size.width;
    return Positioned(
      bottom: phonePortrait ? 104 : 24,
      left: 0,
      right: 0,
      child: Center(
        child: SafeArea(
          top: false,
          // A sibling of the Navigator has no Material ancestor, so plain
          // Text here fell back to Flutter's debug style (yellow double
          // underline, monospace). The transparent Material supplies the
          // app's normal text style.
          child: Material(
            type: MaterialType.transparency,
            child: GestureDetector(
              onTap: _resume,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.black87,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                      color: Theme.of(context).colorScheme.primary, width: 1.5),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.circle, color: Colors.redAccent, size: 10),
                    const SizedBox(width: 8),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 320),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            channel.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: 13,
                                fontWeight: FontWeight.w600),
                          ),
                          // Place the D-pad Right instruction on a separate line so long
                          // channel names cannot truncate it.
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                tr('Hold '),
                                style: const TextStyle(
                                    color: Colors.white70, fontSize: 11),
                              ),
                              const Icon(Icons.keyboard_arrow_right,
                                  color: Colors.white70, size: 14),
                              Text(
                                tr(' to resume'),
                                style: const TextStyle(
                                    color: Colors.white70, fontSize: 11),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
