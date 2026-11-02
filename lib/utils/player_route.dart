import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// Native video surfaces should change destinations without being snapshotted,
/// scaled or slid by a page animation. The player/controller stays alive.
class PlayerRoute extends MaterialPageRoute<void> {
  PlayerRoute({required super.builder})
      : super(
            settings: const RouteSettings(name: '/player'),
            allowSnapshotting: false);

  bool get _nativeAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  @override
  Duration get transitionDuration =>
      _nativeAndroid ? Duration.zero : super.transitionDuration;
  @override
  Duration get reverseTransitionDuration =>
      _nativeAndroid ? Duration.zero : super.reverseTransitionDuration;
}

/// All entry points share the same guard, including preview buttons, hold-Back,
/// PiP and event cards. Keep it until disposal, not merely Navigator.pop.
class PlayerNavigation {
  static final _open = Expando<Future<void>>();

  static Future<void> open(NavigatorState navigator, WidgetBuilder builder) {
    final existing = _open[navigator];
    if (existing != null) return existing;
    if (!navigator.mounted) return Future.value();
    final done = Completer<void>();
    _open[navigator] = done.future;
    () async {
      try {
        final route = PlayerRoute(builder: builder);
        await navigator.push(route);
        await route.completed;
        // Disposal schedules chrome/surface handoff at the end of this frame.
        await WidgetsBinding.instance.endOfFrame;
      } finally {
        _open[navigator] = null;
        done.complete();
      }
    }()
        .catchError((Object error, StackTrace stack) {
      FlutterError.reportError(FlutterErrorDetails(
          exception: error, stack: stack, library: 'player navigation'));
    });
    return done.future;
  }
}
