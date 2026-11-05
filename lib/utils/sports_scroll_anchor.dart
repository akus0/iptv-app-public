import 'package:flutter/widgets.dart';

/// Apply content movement during viewport layout, before paint. A post-frame
/// jump would show one displaced frame and can interrupt an active drag.
class SportsScrollController extends ScrollController {
  double _correction = 0;
  void compensate(double delta) {
    if (!hasClients || delta.abs() < .01) return;
    _correction += delta;
  }

  @override
  ScrollPosition createScrollPosition(ScrollPhysics physics,
          ScrollContext context, ScrollPosition? oldPosition) =>
      _SportsScrollPosition(
          owner: this,
          physics: physics,
          context: context,
          oldPosition: oldPosition,
          initialPixels: initialScrollOffset,
          keepScrollOffset: keepScrollOffset);
}

class _SportsScrollPosition extends ScrollPositionWithSingleContext {
  _SportsScrollPosition(
      {required this.owner,
      required super.physics,
      required super.context,
      super.oldPosition,
      super.initialPixels,
      super.keepScrollOffset});
  final SportsScrollController owner;
  @override
  bool applyContentDimensions(double minScrollExtent, double maxScrollExtent) {
    if (owner._correction != 0) {
      final target =
          (pixels + owner._correction).clamp(minScrollExtent, maxScrollExtent);
      owner._correction = 0;
      if ((target - pixels).abs() > .01) {
        correctPixels(target);
        return false;
      }
    }
    return super.applyContentDimensions(minScrollExtent, maxScrollExtent);
  }
}

/// Preserve the first surviving item intersecting/following the viewport. If
/// that item disappeared, use its next neighbour, then the previous neighbour.
/// Maps are in display order. Work is linear in events, never playlist size.
double sportsAnchorDelta(Map<String, double> before, Map<String, double> after,
    double offset, double itemExtent) {
  String? previous;
  for (final e in before.entries) {
    if (!after.containsKey(e.key)) continue;
    previous = e.key;
    if (e.value + itemExtent > offset) return after[e.key]! - e.value;
  }
  return previous == null ? 0 : after[previous]! - before[previous]!;
}
