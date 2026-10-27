import 'package:flutter/material.dart';

/// Shared across the app so any screen can find out when a route pushed
/// on top of it (typically the fullscreen player) has been popped and it's
/// visible again — via `RouteAware.didPopNext()`. Lives in its own file
/// (rather than `main.dart`) so screens can import it without a cycle back
/// to the file that builds them.
final RouteObserver<PageRoute<void>> appRouteObserver =
    RouteObserver<PageRoute<void>>();
