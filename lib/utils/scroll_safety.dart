import 'package:flutter/widgets.dart';

/// Attachment precedes layout. Reading extents, or starting jumpTo's ballistic
/// activity, is unsafe until the scroll view has both pixels and dimensions.
ScrollPosition? laidOutScrollPosition(ScrollController controller) {
  final positions = controller.positions;
  if (positions.length != 1) return null;
  final position = positions.single;
  return position.hasPixels &&
          position.hasContentDimensions &&
          position.hasViewportDimension
      ? position
      : null;
}

bool jumpToIfLaidOut(ScrollController controller, double offset) {
  final position = laidOutScrollPosition(controller);
  if (position == null) return false;
  final target =
      offset.clamp(position.minScrollExtent, position.maxScrollExtent);
  if ((position.pixels - target).abs() > .01) controller.jumpTo(target);
  return true;
}
