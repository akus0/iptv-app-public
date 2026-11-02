import 'package:flutter/material.dart';

/// Makes a video tappable. A GestureDetector *around* video_player_hdr's
/// platform view never got the tap on a phone (the native view took it), so
/// the tap target is an invisible layer *over* the video instead. It paints
/// nothing, so it adds no compositing cost on top of the platform view.
class VideoTapLayer extends StatelessWidget {
  const VideoTapLayer({super.key, required this.onTap, required this.child});

  final VoidCallback? onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (onTap == null) return child;
    return Stack(
      children: [
        child,
        Positioned.fill(
          child:
              GestureDetector(behavior: HitTestBehavior.opaque, onTap: onTap),
        ),
      ],
    );
  }
}
