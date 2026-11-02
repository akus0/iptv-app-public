import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

// A detached FocusNode can retain a non-null context. Lazy rows and tab
// changes must check attachment before focusing or reading render geometry.
bool sportsFocusAttached(FocusNode node) =>
    node.parent != null && (node.context?.mounted ?? false);

/// Keep a TV toolbar on one horizontal path. Spatial traversal can otherwise
/// prefer a large event card below a short tab or icon button.
class SportsToolbarNavigation extends StatelessWidget {
  const SportsToolbarNavigation(
      {super.key,
      required this.enabled,
      required this.onDown,
      this.onUp,
      required this.child});
  final bool enabled;
  final ValueChanged<FocusNode> onDown;
  final VoidCallback? onUp;
  final Widget child;

  @override
  Widget build(BuildContext context) => Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onKeyEvent: (scope, event) {
          if (!enabled ||
              (event is! KeyDownEvent && event is! KeyRepeatEvent)) {
            return KeyEventResult.ignored;
          }
          final key = event.logicalKey;
          final current = FocusManager.instance.primaryFocus;
          if (current == null) return KeyEventResult.ignored;
          if (key == LogicalKeyboardKey.arrowDown) {
            onDown(current);
            return KeyEventResult.handled;
          }
          if (key == LogicalKeyboardKey.arrowUp) {
            onUp?.call();
            return KeyEventResult.handled;
          }
          final delta = key == LogicalKeyboardKey.arrowLeft
              ? -1
              : key == LogicalKeyboardKey.arrowRight
                  ? 1
                  : 0;
          if (delta == 0) return KeyEventResult.ignored;
          double logicalX(FocusNode node) =>
              node.rect.center.dx +
              (Scrollable.maybeOf(node.context!, axis: Axis.horizontal)
                      ?.position
                      .pixels ??
                  0);
          final nodes = scope.traversalDescendants
              .where((n) =>
                  n.context != null && n.rect.width > 0 && n.rect.height > 0)
              .toList();
          final positions = {for (final node in nodes) node: logicalX(node)};
          final groups = {
            for (final node in nodes)
              node: switch (FocusTraversalOrder.maybeOf(node.context!)) {
                NumericFocusOrder(:final order) => order,
                _ => 0.0,
              }
          };
          // Keep clipped tab/filter strips in their visual group. Their
          // offscreen coordinates can overlap the next group during scrolling.
          nodes.sort((a, b) {
            final group = groups[a]!.compareTo(groups[b]!);
            return group != 0 ? group : positions[a]!.compareTo(positions[b]!);
          });
          final index = nodes.indexOf(current);
          final next = index + delta;
          if (index >= 0 && next >= 0 && next < nodes.length) {
            nodes[next].requestFocus();
            Scrollable.ensureVisible(nodes[next].context!);
          }
          return KeyEventResult.handled;
        },
        child: child,
      );
}
