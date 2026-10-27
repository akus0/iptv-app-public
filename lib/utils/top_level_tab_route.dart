import 'package:flutter/material.dart';

/// Top-level destinations change immediately so their shared navigation remains
/// visually anchored. Detail pages keep their normal page transitions.
class TopLevelTabRoute<T> extends PageRouteBuilder<T> {
  TopLevelTabRoute({required WidgetBuilder builder})
      : super(
          transitionDuration: Duration.zero,
          reverseTransitionDuration: Duration.zero,
          allowSnapshotting: false,
          pageBuilder: (context, animation, secondaryAnimation) =>
              builder(context),
        );
}
