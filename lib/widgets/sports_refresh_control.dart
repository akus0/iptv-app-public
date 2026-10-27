import '../utils/interface_colors.dart';
import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

/// An inline refresh affordance. Only this small sliver rebuilds while dragging;
/// event cards and the fixed video preview do not participate in its animation.
class SportsRefreshControl extends StatefulWidget {
  const SportsRefreshControl(
      {super.key,
      required this.onRefresh,
      this.updatingLabel = 'Updating scores…',
      this.successLabel = 'Scores updated',
      this.externalStatus = false,
      this.onPullChanged});
  final bool externalStatus;
  final ValueChanged<String?>? onPullChanged;
  final String updatingLabel;
  final String successLabel;

  /// False means the existing scores were retained after a failed refresh.
  final Future<bool> Function()? onRefresh;

  @override
  State<SportsRefreshControl> createState() => _SportsRefreshControlState();
}

class _SportsRefreshControlState extends State<SportsRefreshControl> {
  bool _running = false;
  bool? _result;
  String? _pullLabel;
  int _pullGeneration = 0;

  void _reportPull(String? label) {
    if (_pullLabel == label) return;
    _pullLabel = label;
    final generation = ++_pullGeneration;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && generation == _pullGeneration) {
        widget.onPullChanged?.call(label);
      }
    });
  }

  Future<void> _refresh() async {
    final callback = widget.onRefresh;
    if (callback == null) return;
    setState(() {
      _running = true;
      _result = null;
    });
    if (widget.externalStatus) {
      _reportPull(null);
      try {
        await callback();
      } catch (_) {
        /* Caller presents refresh errors in the shared status row. */
      } finally {
        if (mounted) setState(() => _running = false);
      }
      return;
    }
    // Hold the indicator long enough to avoid a flash on a fast cached response.
    // This never delays publishing the actual scores.
    final minimum = Future<void>.delayed(const Duration(milliseconds: 450));
    var success = false;
    try {
      success = await callback();
    } catch (_) {
      // Always release the gesture, even if a caller fails unexpectedly.
    }
    await minimum;
    if (!mounted) return;
    setState(() => _result = success);
    await Future<void>.delayed(const Duration(milliseconds: 500));
    if (mounted) setState(() => _running = false);
  }

  @override
  Widget build(BuildContext context) => CupertinoSliverRefreshControl(
        refreshTriggerPullDistance: 92,
        refreshIndicatorExtent: widget.externalStatus ? 0 : 48,
        onRefresh: widget.onRefresh == null ? null : _refresh,
        builder: (context, mode, extent, trigger, heldExtent) {
          if (widget.externalStatus) {
            _reportPull(_running || widget.onRefresh == null || extent < 12
                ? null
                : mode == RefreshIndicatorMode.armed
                    ? 'Release to refresh'
                    : mode == RefreshIndicatorMode.drag
                        ? 'Pull to refresh'
                        : null);
            return const SizedBox.shrink();
          }
          if (extent < 1 || (widget.onRefresh == null && !_running)) {
            return const SizedBox.shrink();
          }
          final active = mode == RefreshIndicatorMode.armed ||
              mode == RefreshIndicatorMode.refresh;
          final finished =
              (active || mode == RefreshIndicatorMode.done) && _result != null;
          final progress = (extent / trigger).clamp(0.0, 1.0);
          final reducedMotion = MediaQuery.disableAnimationsOf(context);
          final accent = Theme.of(context).colorScheme.primary;
          final color = finished && _result == false
              ? interfaceColor(context, Colors.white60)
              : active || finished
                  ? accent
                  : interfaceColor(context, Colors.white60);
          final label = finished
              ? (_result! ? widget.successLabel : 'Couldn’t refresh')
              : active
                  ? widget.updatingLabel
                  : 'Pull to refresh';
          return ClipRect(
            child: OverflowBox(
              minHeight: 0,
              maxHeight: double.infinity,
              alignment: Alignment.bottomCenter,
              child: SizedBox(
                height: 48,
                child: Center(
                  child: Opacity(
                    opacity: ((extent - 12) / 32).clamp(0.0, 1.0),
                    child: Semantics(
                      liveRegion: active || finished,
                      label: label,
                      child: ExcludeSemantics(
                        child: AnimatedSwitcher(
                          duration: reducedMotion
                              ? Duration.zero
                              : const Duration(milliseconds: 160),
                          child: Row(
                            key: ValueKey(label),
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              SizedBox(
                                width: 22,
                                height: 22,
                                child: finished
                                    ? Icon(
                                        _result!
                                            ? Icons.check_rounded
                                            : Icons.cloud_off_outlined,
                                        size: 19,
                                        color: color)
                                    : active
                                        ? CupertinoActivityIndicator(
                                            radius: 9,
                                            color: color,
                                            animating: !reducedMotion)
                                        : Stack(
                                            alignment: Alignment.center,
                                            children: [
                                                CircularProgressIndicator(
                                                  value: progress,
                                                  strokeWidth: 1.5,
                                                  color: color.withValues(
                                                      alpha: .6),
                                                ),
                                                Transform.rotate(
                                                  angle: reducedMotion
                                                      ? 0
                                                      : progress * math.pi,
                                                  child: Icon(
                                                      Icons
                                                          .arrow_downward_rounded,
                                                      size: 13,
                                                      color: color),
                                                ),
                                              ]),
                              ),
                              const SizedBox(width: 9),
                              Text(label,
                                  style: TextStyle(
                                      fontSize: 11.5,
                                      fontWeight: FontWeight.w500,
                                      color: color)),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      );
}
