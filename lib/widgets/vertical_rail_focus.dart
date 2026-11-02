import 'package:flutter/widgets.dart';

/// Up/Down in a single vertical rail, without repeatedly sorting screen
/// coordinates for every focusable row. Read each rectangle once per key;
/// fresh geometry also follows folder expansion and category reordering.
class VerticalRailTraversalPolicy extends ReadingOrderTraversalPolicy {
  @override
  bool inDirection(FocusNode currentNode, TraversalDirection direction) {
    if (direction != TraversalDirection.up &&
        direction != TraversalDirection.down) {
      return super.inDirection(currentNode, direction);
    }
    final scope = currentNode.nearestScope;
    final current = scope?.focusedChild;
    if (scope == null || current == null) {
      return super.inDirection(currentNode, direction);
    }
    final origin = current.rect;
    final down = direction == TraversalDirection.down;
    FocusNode? next;
    var distance = double.infinity;
    for (final candidate in scope.traversalDescendants) {
      if (identical(candidate, current)) continue;
      final rect = candidate.rect;
      final delta =
          down ? rect.center.dy - origin.bottom : origin.top - rect.center.dy;
      if (delta >= 0 && delta < distance) {
        next = candidate;
        distance = delta;
      }
    }
    // Rails stop at their first/last row; Left/Right still change columns.
    if (next == null) return false;
    requestFocusCallback(next,
        alignmentPolicy: down
            ? ScrollPositionAlignmentPolicy.keepVisibleAtEnd
            : ScrollPositionAlignmentPolicy.keepVisibleAtStart);
    return true;
  }
}
