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
      required this.child});
  final bool enabled;
  final ValueChanged<FocusNode> onDown;
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
          if (key == LogicalKeyboardKey.arrowUp) return KeyEventResult.handled;
          final delta = key == LogicalKeyboardKey.arrowLeft
              ? -1
              : key == LogicalKeyboardKey.arrowRight
                  ? 1
                  : 0;
          if (delta == 0) return KeyEventResult.ignored;
          final nodes = scope.traversalDescendants
              .where((n) =>
                  n.context != null && n.rect.width > 0 && n.rect.height > 0)
              .toList()
            ..sort((a, b) => a.rect.center.dx.compareTo(b.rect.center.dx));
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
