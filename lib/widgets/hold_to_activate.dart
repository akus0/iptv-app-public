import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Prevent a held activation key from selecting items in a newly opened route. Ignore repeats
/// and the inherited key-up until a fresh non-repeat key-down arrives.
class SwallowHeldActivate extends StatefulWidget {
  const SwallowHeldActivate({super.key, required this.child});
  final Widget child;

  @override
  State<SwallowHeldActivate> createState() => _SwallowHeldActivateState();
}

class _SwallowHeldActivateState extends State<SwallowHeldActivate> {
  bool _armed = false;

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (_armed || !_isActivateKey(event.logicalKey)) {
      return KeyEventResult.ignored;
    }
    if (event is KeyDownEvent) {
      _armed = true;
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled; // repeat / key-up of the held press
  }

  @override
  Widget build(BuildContext context) => Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onKeyEvent: _onKey,
        child: widget.child,
      );
}

bool _isActivateKey(LogicalKeyboardKey key) =>
    key == LogicalKeyboardKey.select ||
    key == LogicalKeyboardKey.enter ||
    key == LogicalKeyboardKey.numpadEnter ||
    key == LogicalKeyboardKey.gameButtonA;

class HoldToActivate extends StatefulWidget {
  const HoldToActivate({
    super.key,
    required this.onTap,
    this.onHold,
    this.holdDuration = const Duration(milliseconds: 550),
    required this.child,
  });

  final VoidCallback onTap;
  final VoidCallback? onHold;
  final Duration holdDuration;
  final Widget child;

  @override
  State<HoldToActivate> createState() => _HoldToActivateState();
}

class _HoldToActivateState extends State<HoldToActivate> {
  Timer? _holdTimer;
  bool _holdFired = false;

  /// Accept key-up only after this instance received the matching key-down. Focus can move
  /// between those events; an orphaned release must not activate the newly focused row.
  bool _downReceived = false;

  /// A hold needs the remote's own auto-repeat as proof, not just the
  /// timer: on a busy Fire Stick (a stream starting) a quick click's key-up
  /// reached the app over [holdDuration] late, so the first click on the TV
  /// Favourites row opened "Clear favourites?". A real
  /// hold always sends repeats (Android after ~0.5 s, Windows keyboards
  /// too); a late key-up after a click never has any.
  bool _repeatSeen = false;
  bool _timerElapsed = false;

  void _fireHold() {
    final onHold = widget.onHold;
    if (onHold == null || _holdFired) return;
    _holdFired = true;
    onHold();
  }

  @override
  void dispose() {
    _holdTimer?.cancel();
    super.dispose();
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    final isActivateKey = event.logicalKey == LogicalKeyboardKey.select ||
        event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter ||
        event.logicalKey == LogicalKeyboardKey.gameButtonA;
    if (!isActivateKey) return KeyEventResult.ignored;

    if (event is KeyDownEvent) {
      _holdFired = false;
      _downReceived = true;
      _repeatSeen = false;
      _timerElapsed = false;
      _holdTimer?.cancel();
      if (widget.onHold != null) {
        _holdTimer = Timer(widget.holdDuration, () {
          _timerElapsed = true;
          if (_repeatSeen) _fireHold();
        });
      }
      return KeyEventResult.handled;
    }
    if (event is KeyRepeatEvent) {
      if (_downReceived) {
        _repeatSeen = true;
        if (_timerElapsed) _fireHold();
      }
      return KeyEventResult.handled;
    }
    if (event is KeyUpEvent) {
      _holdTimer?.cancel();
      final hadMatchingDown = _downReceived;
      _downReceived = false;
      if (hadMatchingDown && !_holdFired) widget.onTap();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return Shortcuts(
      // Consume activation keys here so the child's ambient Shortcuts cannot also fire after
      // the synthesized onTap.
      shortcuts: const <ShortcutActivator, Intent>{
        SingleActivator(LogicalKeyboardKey.select): DoNothingIntent(),
        SingleActivator(LogicalKeyboardKey.enter): DoNothingIntent(),
        SingleActivator(LogicalKeyboardKey.numpadEnter): DoNothingIntent(),
        SingleActivator(LogicalKeyboardKey.gameButtonA): DoNothingIntent(),
      },
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onKeyEvent: _handleKeyEvent,
        child: widget.onHold == null
            ? widget.child
            : RawGestureDetector(
                gestures: <Type, GestureRecognizerFactory>{
                  LongPressGestureRecognizer:
                      GestureRecognizerFactoryWithHandlers<
                          LongPressGestureRecognizer>(
                    () => LongPressGestureRecognizer(
                        duration: widget.holdDuration),
                    (instance) => instance.onLongPress = widget.onHold,
                  ),
                },
                child: widget.child,
              ),
      ),
    );
  }
}
