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

  static final _editors = <FocusNode, _TvTextFieldGateState>{};

  /// Screen-level navigation must yield while the TV keyboard owns a field,
  /// including overlay keyboards that report no bottom inset.
  static bool isEditing(FocusNode? node) => _editors[node]?._typing ?? false;

  static bool _endingEditOnBack = false;

  /// Parent PopScopes must yield the same Back press to the active editor,
  /// including callbacks dispatched after the editor has already closed.
  static bool get editingFocusedField =>
      _endingEditOnBack || isEditing(FocusManager.instance.primaryFocus);

  @override
  State<TvTextFieldGate> createState() => _TvTextFieldGateState();
}

class TvNavigationActivator extends SingleActivator {
  const TvNavigationActivator(super.trigger);

  @override
  bool accepts(KeyEvent event, HardwareKeyboard state) =>
      !TvTextFieldGate.isEditing(FocusManager.instance.primaryFocus) &&
      super.accepts(event, state);
}

class _TvTextFieldGateState extends State<TvTextFieldGate>
    with WidgetsBindingObserver {
  bool _typing = false;
  bool _keyboardShown = false;

  bool get _foreground =>
      WidgetsBinding.instance.lifecycleState == null ||
      WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;

  bool get _canRecover =>
      mounted && _foreground && (ModalRoute.of(context)?.isCurrent ?? true);

  @override
  void initState() {
    super.initState();
    widget.focusNode.addListener(_onFocus);
    TvTextFieldGate._editors[widget.focusNode] = this;
    HardwareKeyboard.instance.addHandler(_onKey);
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didUpdateWidget(TvTextFieldGate oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.focusNode != widget.focusNode) {
      oldWidget.focusNode.removeListener(_onFocus);
      if (TvTextFieldGate._editors[oldWidget.focusNode] == this) {
        TvTextFieldGate._editors.remove(oldWidget.focusNode);
      }
      TvTextFieldGate._editors[widget.focusNode] = this;
      _typing = false;
      _keyboardShown = false;
      widget.focusNode.addListener(_onFocus);
    }
  }

  @override
  void dispose() {
    widget.focusNode.removeListener(_onFocus);
    if (TvTextFieldGate._editors[widget.focusNode] == this) {
      TvTextFieldGate._editors.remove(widget.focusNode);
    }
    HardwareKeyboard.instance.removeHandler(_onKey);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeMetrics() {
    if (!_typing || !_canRecover) return;
    final shown = (View.maybeOf(context)?.viewInsets.bottom ?? 0) > 0;
    if (shown) {
      _keyboardShown = true;
    } else if (_keyboardShown) {
      _stopTyping(hideKeyboard: false);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Inactive may simply mean an overlay keyboard owns the window.
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      _keyboardShown = false;
      if (_typing) setState(() => _typing = false);
    }
  }

  void _stopTyping({bool hideKeyboard = true}) {
    if (!_typing) return;
    _keyboardShown = false;
    setState(() => _typing = false);
    if (hideKeyboard && _canRecover) {
      SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
    }
  }

  /// The next field never opens its keyboard by itself, even after the
  /// keyboard's Next: Fire OS reports Back on its keyboard as that same
  /// Next, and keeping the keyboard up across fields made Back walk from
  /// field to field with the keyboard reopening each time (Fire Stick 4K
  /// Max, 2026-10-19). One more OK per field, never stuck.
  void _onFocus() {
    if (widget.focusNode.hasFocus || !_typing) return;
    _keyboardShown = false;
    setState(() => _typing = false);
    // Fire OS: Back on its keyboard drops Flutter's focus altogether.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_canRecover) return;
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
    if (!context.read<AppPreferences>().isTelevision || !_canRecover) {
      return false;
    }
    final key = event.logicalKey;
    final ok = key == LogicalKeyboardKey.select ||
        key == LogicalKeyboardKey.gameButtonA;
    if (_typing) {
      if (key == LogicalKeyboardKey.escape ||
          key == LogicalKeyboardKey.goBack ||
          key == LogicalKeyboardKey.gameButtonB) {
        _stopTyping();
        return true;
      }
      // Forwarded arrows are editing input, not proof of keyboard dismissal.
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
    _keyboardShown = (View.maybeOf(context)?.viewInsets.bottom ?? 0) > 0;
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
        if (_canRecover && !_typing && widget.focusNode.hasPrimaryFocus) {
          widget.focusNode.focusInDirection(direction);
        }
      });

  @override
  Widget build(BuildContext context) {
    if (!context.read<AppPreferences>().isTelevision) {
      return widget.builder(context, false);
    }
    return PopScope(
      canPop: !_typing,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _typing) {
          // Every PopScope receives this callback. Claim the current dispatch
          // for keyboard dismissal regardless of registration order, but end
          // editing immediately so the next frame restores arrow navigation.
          TvTextFieldGate._endingEditOnBack = true;
          scheduleMicrotask(() => TvTextFieldGate._endingEditOnBack = false);
          _stopTyping();
        }
      },
      child: Actions(
        actions: _typing
            ? const <Type, Action<Intent>>{}
            : {
                ExtendSelectionVerticallyToAdjacentLineIntent: CallbackAction<
                    ExtendSelectionVerticallyToAdjacentLineIntent>(
                  onInvoke: (i) => _move(i.forward
                      ? TraversalDirection.down
                      : TraversalDirection.up),
                ),
                ExtendSelectionByCharacterIntent:
                    CallbackAction<ExtendSelectionByCharacterIntent>(
                  onInvoke: (i) => _move(i.forward
                      ? TraversalDirection.right
                      : TraversalDirection.left),
                ),
              },
        child: widget.builder(context, !_typing),
      ),
    );
  }
}
