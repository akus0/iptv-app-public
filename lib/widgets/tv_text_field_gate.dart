import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../services/app_preferences.dart';

/// Keep TV text fields read-only until OK/Select opens the keyboard. Restore field focus if
/// dismissing the keyboard clears it; close input when focus leaves. The builder must pass
/// readOnly and focusNode through. Phone and desktop use normal editable fields.
/// FocusNodeOwner supplies a managed node for dialogs without one.
class FocusNodeOwner extends StatefulWidget {
  const FocusNodeOwner({super.key, required this.builder});

  final Widget Function(BuildContext context, FocusNode node) builder;

  @override
  State<FocusNodeOwner> createState() => _FocusNodeOwnerState();
}

class _FocusNodeOwnerState extends State<FocusNodeOwner> {
  final _node = FocusNode(debugLabel: 'gated-text-field');

  @override
  void dispose() {
    _node.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _node);
}

class TvTextFieldGate extends StatefulWidget {
  const TvTextFieldGate({
    super.key,
    required this.focusNode,
    required this.builder,
  });

  final FocusNode focusNode;
  final Widget Function(BuildContext context, bool readOnly) builder;

  @override
  State<TvTextFieldGate> createState() => _TvTextFieldGateState();
}

class _TvTextFieldGateState extends State<TvTextFieldGate> {
  bool _typing = false;

  @override
  void initState() {
    super.initState();
    widget.focusNode.addListener(_onFocus);
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  @override
  void didUpdateWidget(TvTextFieldGate oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.focusNode != widget.focusNode) {
      oldWidget.focusNode.removeListener(_onFocus);
      widget.focusNode.addListener(_onFocus);
    }
  }

  @override
  void dispose() {
    widget.focusNode.removeListener(_onFocus);
    HardwareKeyboard.instance.removeHandler(_onKey);
    super.dispose();
  }

  /// The next field never opens its keyboard by itself, even after the
  /// keyboard's Next: Fire OS reports Back on its keyboard as that same
  /// Next, and keeping the keyboard up across fields made Back walk from
  /// field to field with the keyboard reopening each time (Fire Stick 4K
  /// Max, 2026-10-19). One more OK per field, never stuck.
  void _onFocus() {
    if (widget.focusNode.hasFocus || !_typing) return;
    setState(() => _typing = false);
    // Fire OS: Back on its keyboard drops Flutter's focus altogether.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final now = FocusManager.instance.primaryFocus;
      if (now == null || now is FocusScopeNode) {
        widget.focusNode.requestFocus();
      }
    });
  }

  /// A raw handler, not a `Focus.onKeyEvent`: it runs before anything in
  /// the field's own subtree can claim the key.
  bool _onKey(KeyEvent event) {
    if (event is! KeyDownEvent || !widget.focusNode.hasFocus) return false;
    if (!context.read<AppPreferences>().isTelevision) return false;
    final key = event.logicalKey;
    final ok = key == LogicalKeyboardKey.select ||
        key == LogicalKeyboardKey.gameButtonA;
    if (_typing) {
      // Keyboard dismissed but the field kept focus (Formuler): OK raises
      // it again. Only the remote's own OK key: Fire OS turns Back on its
      // keyboard into a numpadEnter, which must not reopen it.
      if (!ok) return false;
      SystemChannels.textInput.invokeMethod<void>('TextInput.show');
      return true;
    }
    if (!ok &&
        key != LogicalKeyboardKey.enter &&
        key != LogicalKeyboardKey.numpadEnter) {
      return false;
    }
    // readOnly -> false while focused opens the input connection and shows
    // the keyboard (EditableText.didUpdateWidget).
    setState(() => _typing = true);
    return true;
  }

  /// D-pad arrows on the field move focus, not the cursor. Once a field has
  /// a cursor (typed in once), EditableText's own arrow actions move it —
  /// Up/Down to the start/end of a one-line field, Left/Right a character —
  /// and consume the key even with the keyboard closed and the field
  /// read-only, and Flutter's fallback for arrows in a text field is "stay".
  /// So on screens without their own arrow handling the remote could not
  /// get past a search field it had typed in (the long-standing "stuck in
  /// the text field" report, 2026-10-21). While the keyboard is up it owns
  /// the D-pad, so this only acts once it's closed.
  ///
  /// A screen's own key handler (Add Playlist's field-to-field Up/Down) gets
  /// the key first, but Flutter still delivers it to the field afterwards.
  /// Its focus change is applied in a microtask queued before this one, so
  /// the move only happens when nothing else has moved focus already.
  void _move(TraversalDirection direction) => scheduleMicrotask(() {
        if (mounted && widget.focusNode.hasPrimaryFocus) {
          widget.focusNode.focusInDirection(direction);
        }
      });

  @override
  Widget build(BuildContext context) {
    if (!context.read<AppPreferences>().isTelevision) {
      return widget.builder(context, false);
    }
    return Actions(
      actions: {
        ExtendSelectionVerticallyToAdjacentLineIntent:
            CallbackAction<ExtendSelectionVerticallyToAdjacentLineIntent>(
          onInvoke: (i) => _move(
              i.forward ? TraversalDirection.down : TraversalDirection.up),
        ),
        ExtendSelectionByCharacterIntent:
            CallbackAction<ExtendSelectionByCharacterIntent>(
          onInvoke: (i) => _move(
              i.forward ? TraversalDirection.right : TraversalDirection.left),
        ),
      },
      child: widget.builder(context, !_typing),
    );
  }
}
