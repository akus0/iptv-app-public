import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Only the visible TV home route owns the physical Back hold. Dialogs and
/// fullscreen keep normal Back behavior; playback itself is never restarted.
class TvPreviewRemoteNavigation extends StatefulWidget {
  const TvPreviewRemoteNavigation(
      {super.key,
      required this.enabled,
      required this.onFullscreen,
      required this.child});
  final bool enabled;
  final VoidCallback onFullscreen;
  final Widget child;
  @override
  State<TvPreviewRemoteNavigation> createState() =>
      _TvPreviewRemoteNavigationState();
}

class _TvPreviewRemoteNavigationState extends State<TvPreviewRemoteNavigation> {
  static const _channel = MethodChannel('com.nox.nox_iptv/tv_remote');
  static bool? _sent;
  static final _clients = <_TvPreviewRemoteNavigationState>[];
  ModalRoute<dynamic>? _route;
  bool get _active => mounted && widget.enabled && (_route?.isCurrent ?? true);
  @override
  void initState() {
    super.initState();
    _clients.add(this);
    if (_clients.length == 1) {
      _channel.setMethodCallHandler((call) async {
        if (call.method != 'fullscreen') return false;
        for (final client in _clients.reversed) {
          if (client._active) {
            client.widget.onFullscreen();
            return true;
          }
        }
        return false;
      });
    }
  }

  static Future<void> _configure(bool enabled) async {
    try {
      await _channel.invokeMethod<void>('setEnabled', enabled);
    } on MissingPluginException {
      // Desktop and widget tests do not intercept Android's Back key.
    } on PlatformException {/* Activity may have been detached. */}
  }

  static void _sync() {
    final enabled = _clients.any((c) => c._active);
    if (_sent == enabled) return;
    _sent = enabled;
    unawaited(_configure(enabled));
  }

  @override
  Widget build(BuildContext context) {
    ModalRoute.isCurrentOf(
        context); // Re-evaluate when a dialog or route covers us.
    _route = ModalRoute.of(context);
    _sync();
    return widget.child;
  }

  @override
  void dispose() {
    _clients.remove(this);
    if (_clients.isEmpty) _channel.setMethodCallHandler(null);
    _sync();
    super.dispose();
  }
}
