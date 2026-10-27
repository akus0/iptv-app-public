import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../services/parental_pin.dart';
import '../l10n/l10n.dart';

/// Index-matched 0-9 so a remote with a physical number pad (Formuler) can
/// type a PIN directly without ever moving focus around the on-screen grid.
const _digitKeys = [
  LogicalKeyboardKey.digit0,
  LogicalKeyboardKey.digit1,
  LogicalKeyboardKey.digit2,
  LogicalKeyboardKey.digit3,
  LogicalKeyboardKey.digit4,
  LogicalKeyboardKey.digit5,
  LogicalKeyboardKey.digit6,
  LogicalKeyboardKey.digit7,
  LogicalKeyboardKey.digit8,
  LogicalKeyboardKey.digit9,
];
const _numpadKeys = [
  LogicalKeyboardKey.numpad0,
  LogicalKeyboardKey.numpad1,
  LogicalKeyboardKey.numpad2,
  LogicalKeyboardKey.numpad3,
  LogicalKeyboardKey.numpad4,
  LogicalKeyboardKey.numpad5,
  LogicalKeyboardKey.numpad6,
  LogicalKeyboardKey.numpad7,
  LogicalKeyboardKey.numpad8,
  LogicalKeyboardKey.numpad9,
];

/// Prompts for the parental PIN and returns true only on a correct entry —
/// false on Back/cancel. Used wherever a restricted viewer needs to prove
/// they're not the kid (leaving the profile, opening Settings).
Future<bool> promptForPin(BuildContext context) async {
  final result = await Navigator.of(context).push<bool>(
    MaterialPageRoute(
        builder: (_) => const _PinPadScreen(mode: _PinPadMode.verify)),
  );
  return result ?? false;
}

/// Walks through "enter a new PIN, enter it again to confirm" (a mismatch
/// restarts rather than erroring) and saves it. Returns true only if a PIN
/// was actually set; false on cancel at either step.
Future<bool> setupPinFlow(BuildContext context) async {
  final result = await Navigator.of(context).push<bool>(
    MaterialPageRoute(
        builder: (_) => const _PinPadScreen(mode: _PinPadMode.setup)),
  );
  return result ?? false;
}

enum _PinPadMode { verify, setup }

/// On-screen PIN keypad with explicit row/column navigation and direct digit bindings.
/// Avoid a TextField so a system keyboard cannot intercept Back or remote input.
class _PinPadScreen extends StatefulWidget {
  const _PinPadScreen({required this.mode});
  final _PinPadMode mode;

  @override
  State<_PinPadScreen> createState() => _PinPadScreenState();
}

class _PinPadScreenState extends State<_PinPadScreen> {
  // Keys laid out as 1 2 3 / 4 5 6 / 7 8 9 / ⌫ 0 ✕ — [_keyLabels]/
  // [_keyValues] share this same 4x3 shape so row/column arithmetic in
  // [_moveFocus] and the lookup in [_focusNodeFor] line up by index.
  static const _keyValues = [
    ['1', '2', '3'],
    ['4', '5', '6'],
    ['7', '8', '9'],
    ['back', '0', 'cancel'],
  ];

  final List<List<FocusNode>> _nodes = List.generate(
      4, (_) => List.generate(3, (_) => FocusNode(debugLabel: 'pin-key')));

  String _buffer = '';
  String? _firstEntry; // setup mode only — the first of the two entries.
  String? _error;
  bool _isSecondSetupEntry = false;
  Timer? _lockoutTicker;
  Duration? _lockedFor;

  @override
  void initState() {
    super.initState();
    _checkLockout();
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _nodes[3][1].requestFocus()); // "0"
  }

  @override
  void dispose() {
    _lockoutTicker?.cancel();
    for (final row in _nodes) {
      for (final node in row) {
        node.dispose();
      }
    }
    super.dispose();
  }

  void _checkLockout() {
    final remaining = context.read<ParentalPin>().lockedForRemaining;
    setState(() => _lockedFor = remaining);
    if (remaining == null) return;
    _lockoutTicker?.cancel();
    _lockoutTicker = Timer.periodic(const Duration(seconds: 1), (_) {
      final left = context.read<ParentalPin>().lockedForRemaining;
      if (!mounted) return;
      setState(() => _lockedFor = left);
      if (left == null) _lockoutTicker?.cancel();
    });
  }

  void _moveFocus(int rowDelta, int colDelta) {
    final current = FocusManager.instance.primaryFocus;
    for (var r = 0; r < _nodes.length; r++) {
      for (var c = 0; c < _nodes[r].length; c++) {
        if (_nodes[r][c] == current) {
          final nr = (r + rowDelta).clamp(0, _nodes.length - 1);
          final nc = (c + colDelta).clamp(0, _nodes[r].length - 1);
          _nodes[nr][nc].requestFocus();
          return;
        }
      }
    }
  }

  void _pressDigit(String digit) {
    if (_lockedFor != null) return;
    if (_buffer.length >= 4) return;
    setState(() {
      _error = null;
      _buffer += digit;
    });
    if (_buffer.length == 4) _submit();
  }

  void _backspace() {
    if (_buffer.isEmpty) return;
    setState(() => _buffer = _buffer.substring(0, _buffer.length - 1));
  }

  void _cancel() => Navigator.of(context).pop(false);

  Future<void> _submit() async {
    final entered = _buffer;
    if (widget.mode == _PinPadMode.verify) {
      final ok = await context.read<ParentalPin>().verify(entered);
      if (!mounted) return;
      if (ok) {
        Navigator.of(context).pop(true);
        return;
      }
      _checkLockout();
      setState(() {
        _buffer = '';
        _error = _lockedFor != null ? null : tr('Incorrect PIN');
      });
      return;
    }

    // Setup mode: first entry just remembers itself and asks again.
    if (!_isSecondSetupEntry) {
      setState(() {
        _firstEntry = entered;
        _isSecondSetupEntry = true;
        _buffer = '';
      });
      return;
    }
    if (entered != _firstEntry) {
      setState(() {
        _error = tr("PINs didn't match — try again");
        _firstEntry = null;
        _isSecondSetupEntry = false;
        _buffer = '';
      });
      return;
    }
    await context.read<ParentalPin>().setPin(entered);
    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  String get _title {
    if (widget.mode == _PinPadMode.verify) return tr('Enter PIN');
    return _isSecondSetupEntry ? tr('Confirm PIN') : tr('Set a PIN');
  }

  @override
  Widget build(BuildContext context) {
    final locked = _lockedFor != null;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) Navigator.of(context).pop(false);
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 360),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(_title,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 22,
                          fontWeight: FontWeight.w600)),
                  const SizedBox(height: 24),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: List.generate(4, (i) {
                      final filled = i < _buffer.length;
                      return Container(
                        margin: const EdgeInsets.symmetric(horizontal: 8),
                        width: 18,
                        height: 18,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: filled ? Colors.white : Colors.transparent,
                          border: Border.all(color: Colors.white70, width: 2),
                        ),
                      );
                    }),
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    height: 20,
                    child: Text(
                      locked
                          ? tr('Too many attempts — try again in {p}s',
                              {'p': _lockedFor!.inSeconds})
                          : (_error ?? ''),
                      style: TextStyle(
                          color: Colors.redAccent.shade100, fontSize: 13),
                    ),
                  ),
                  const SizedBox(height: 24),
                  CallbackShortcuts(
                    bindings: <ShortcutActivator, VoidCallback>{
                      const SingleActivator(LogicalKeyboardKey.arrowUp): () =>
                          _moveFocus(-1, 0),
                      const SingleActivator(LogicalKeyboardKey.arrowDown): () =>
                          _moveFocus(1, 0),
                      const SingleActivator(LogicalKeyboardKey.arrowLeft): () =>
                          _moveFocus(0, -1),
                      const SingleActivator(LogicalKeyboardKey.arrowRight):
                          () => _moveFocus(0, 1),
                      for (var d = 0; d <= 9; d++)
                        SingleActivator(_digitKeys[d]): () => _pressDigit('$d'),
                      for (var d = 0; d <= 9; d++)
                        SingleActivator(_numpadKeys[d]): () =>
                            _pressDigit('$d'),
                    },
                    child: Focus(
                      autofocus: true,
                      child: Column(
                        children: List.generate(4, (r) {
                          return Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: List.generate(3, (c) {
                              return _PinKey(
                                focusNode: _nodes[r][c],
                                value: _keyValues[r][c],
                                enabled: !locked,
                                onPressed: () {
                                  final v = _keyValues[r][c];
                                  if (v == 'back') {
                                    _backspace();
                                  } else if (v == 'cancel') {
                                    _cancel();
                                  } else {
                                    _pressDigit(v);
                                  }
                                },
                              );
                            }),
                          );
                        }),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PinKey extends StatefulWidget {
  const _PinKey(
      {required this.focusNode,
      required this.value,
      required this.onPressed,
      required this.enabled});

  final FocusNode focusNode;
  final String value;
  final VoidCallback onPressed;
  final bool enabled;

  @override
  State<_PinKey> createState() => _PinKeyState();
}

class _PinKeyState extends State<_PinKey> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final isSpecial = widget.value == 'back' || widget.value == 'cancel';
    final label = switch (widget.value) {
      'back' => '⌫',
      'cancel' => '✕',
      final digit => digit,
    };
    return Padding(
      padding: const EdgeInsets.all(8),
      child: Material(
        color: _focused
            ? Colors.white
            : (isSpecial ? Colors.white12 : Colors.white10),
        shape: const CircleBorder(),
        child: InkWell(
          focusNode: widget.focusNode,
          onFocusChange: (f) => setState(() => _focused = f),
          onTap: widget.enabled ? widget.onPressed : null,
          customBorder: const CircleBorder(),
          child: SizedBox(
            width: 72,
            height: 72,
            child: Center(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 24,
                  color: widget.enabled
                      ? (_focused ? Colors.black : Colors.white)
                      : Colors.white30,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
