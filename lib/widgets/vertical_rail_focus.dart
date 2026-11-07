import 'package:flutter/widgets.dart';
import 'package:flutter/rendering.dart';

/// Up/Down in a single vertical rail, without repeatedly sorting screen
/// coordinates for every focusable row. Compare each mounted row once per key;
/// content offsets also follow folder expansion and category reordering.
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
    final render = current.context?.findRenderObject();
    final viewport =
        render == null ? null : RenderAbstractViewport.maybeOf(render);
    final originOffset = viewport != null && render != null
        ? viewport.getOffsetToReveal(render, .5).offset
        : null;
    final down = direction == TraversalDirection.down;
    FocusNode? next;
    var distance = double.infinity;
    for (final candidate in scope.traversalDescendants) {
      if (identical(candidate, current)) continue;
      final target = candidate.context?.findRenderObject();
      // Retained offscreen slivers may have clamped paint coordinates. Their
      // reveal offset still identifies the actual row in the scroll content.
      final sameViewport = originOffset != null &&
          target != null &&
          identical(RenderAbstractViewport.maybeOf(target), viewport);
      final center = sameViewport
          ? viewport!.getOffsetToReveal(target, .5).offset
          : candidate.rect.center.dy;
      final from = sameViewport ? originOffset : origin.center.dy;
      final delta = down ? center - from : from - center;
      if (delta > .5 && delta < distance) {
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
