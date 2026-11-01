import 'dart:async';

import 'package:flutter/material.dart';

/// Hide a multiview tile's name bar after [visibleFor] to uncover the video. Reveal it when
/// [flashKey] changes or the pointer enters [hoverArea]; show [hidden] while the overlay is
/// absent.
class AutoHideOverlay extends StatefulWidget {
  const AutoHideOverlay({
    super.key,
    required this.flashKey,
    required this.overlay,
    required this.video,
    this.hidden,
    this.visibleFor = const Duration(seconds: 4),
  });

  final Object? flashKey;

  /// The tile's content (video); the overlay is stacked over it.
  final Widget video;

  /// The name bar, laid out by the caller (usually a top `Positioned`).
  final Widget overlay;
  final Widget? hidden;
  final Duration visibleFor;

  @override
  State<AutoHideOverlay> createState() => _AutoHideOverlayState();
}

class _AutoHideOverlayState extends State<AutoHideOverlay> {
  bool _shown = true;
  bool _hover = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _flash();
  }

  @override
  void didUpdateWidget(AutoHideOverlay old) {
    super.didUpdateWidget(old);
    if (old.flashKey != widget.flashKey) _flash();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _flash() {
    _timer?.cancel();
    if (!_shown) setState(() => _shown = true);
    _timer = Timer(widget.visibleFor, () {
      if (mounted) setState(() => _shown = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final visible = _shown || _hover;
    const fade = Duration(milliseconds: 300);
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) {
        setState(() => _hover = false);
        _flash(); // linger a moment after the pointer leaves
      },
      child: Stack(
        fit: StackFit.expand,
        children: [
          widget.video,
          Positioned.fill(
            child: IgnorePointer(
              ignoring: !visible,
              child: AnimatedOpacity(
                opacity: visible ? 1 : 0,
                duration: fade,
                child: Stack(fit: StackFit.expand, children: [widget.overlay]),
              ),
            ),
          ),
          if (widget.hidden != null)
            Positioned.fill(
              child: IgnorePointer(
                child: AnimatedOpacity(
                  opacity: visible ? 0 : 1,
                  duration: fade,
                  child:
                      Stack(fit: StackFit.expand, children: [widget.hidden!]),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// The small "this tile has the sound" badge shown while the name bar is
/// hidden: bottom-right, clear of the usual score-bug corners.
class MultiviewAudioBadge extends StatelessWidget {
  const MultiviewAudioBadge({super.key});

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.bottomRight,
      child: Container(
        margin: const EdgeInsets.all(6),
        padding: const EdgeInsets.all(4),
        decoration:
            const BoxDecoration(color: Colors.black54, shape: BoxShape.circle),
        child: const Icon(Icons.volume_up, color: Colors.amber, size: 14),
      ),
    );
  }
}
