import 'package:flutter/material.dart';

/// Shared across the app so any screen can find out when a route pushed
/// on top of it (typically the fullscreen player) has been popped and it's
/// visible again — via `RouteAware.didPopNext()`. Lives in its own file
/// (rather than `main.dart`) so screens can import it without a cycle back
/// to the file that builds them.
final RouteObserver<PageRoute<void>> appRouteObserver =
    RouteObserver<PageRoute<void>>();

/// Observe route visibility without making the whole screen depend on it.
/// Returning the retained child keeps navigation from rebuilding a large
/// catalogue underneath the incoming page. Data dependencies remain on the
/// screen itself and still rebuild it normally.
class RouteAwareRegion extends StatefulWidget {
  const RouteAwareRegion({
    super.key,
    required this.listener,
    required this.onRouteChanged,
    required this.child,
  });

  final RouteAware listener;
  final ValueChanged<ModalRoute<dynamic>?> onRouteChanged;
  final Widget child;

  @override
  State<RouteAwareRegion> createState() => _RouteAwareRegionState();
}

class _RouteAwareRegionState extends State<RouteAwareRegion> {
  ModalRoute<dynamic>? _route;

  void _subscribe() {
    widget.onRouteChanged(_route);
    if (_route case final PageRoute<void> route) {
      appRouteObserver.subscribe(widget.listener, route);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (identical(route, _route)) return;
    appRouteObserver.unsubscribe(widget.listener);
    _route = route;
    _subscribe();
  }

  @override
  void didUpdateWidget(RouteAwareRegion oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.listener, widget.listener)) {
      appRouteObserver.unsubscribe(oldWidget.listener);
      _subscribe();
    }
  }

  @override
  void dispose() {
    appRouteObserver.unsubscribe(widget.listener);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
