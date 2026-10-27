import 'dart:math' as math;

import 'package:flutter/material.dart';

/// A handful of small gold four-point stars drifting slowly across the whole
/// splash screen, with subtle ambient motion.
///
/// Deliberately cheap — the splash runs on weak TV boxes: ~18 flat-filled
/// paths in one [CustomPainter] behind a [RepaintBoundary], no blur/shader.
/// Every star moves an *integer* number of screen-widths per loop, so the
/// loop point is seamless.
class SplashStars extends StatefulWidget {
  const SplashStars({super.key});

  @override
  State<SplashStars> createState() => _SplashStarsState();
}

class _SplashStarsState extends State<SplashStars>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 24),
  )..repeat();

  static final List<_Star> _stars = () {
    final random = math.Random(7);
    return List.generate(18, (_) {
      return _Star(
        x: random.nextDouble(),
        y: random.nextDouble(),
        // Whole cycles per loop → seamless wrap-around.
        driftX: 1 + random.nextInt(2),
        driftY: -(1 + random.nextInt(2)),
        size: 4 + random.nextDouble() * 8,
        phase: random.nextDouble(),
        twinkles: 2 + random.nextInt(3),
      );
    });
  }();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: RepaintBoundary(
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, _) => CustomPaint(
            size: Size.infinite,
            painter: _StarPainter(_controller.value),
          ),
        ),
      ),
    );
  }
}

class _Star {
  const _Star({
    required this.x,
    required this.y,
    required this.driftX,
    required this.driftY,
    required this.size,
    required this.phase,
    required this.twinkles,
  });

  final double x;
  final double y;
  final int driftX;
  final int driftY;
  final double size;
  final double phase;
  final int twinkles;
}

class _StarPainter extends CustomPainter {
  _StarPainter(this.t);

  final double t; // 0..1 over the loop

  static const _gold = Color(0xFFF0C75E);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..style = PaintingStyle.fill;
    for (final star in _SplashStarsState._stars) {
      final px = ((star.x + star.driftX * t) % 1.0) * size.width;
      final py = ((star.y + star.driftY * t) % 1.0 + 1.0) % 1.0 * size.height;
      // 0..1 twinkle, a few full pulses per loop.
      final pulse =
          0.5 + 0.5 * math.sin((t * star.twinkles + star.phase) * 2 * math.pi);
      final alpha = 0.25 + 0.65 * pulse;
      final r = star.size * (0.7 + 0.3 * pulse);

      paint.color = _gold.withValues(alpha: alpha * 0.12);
      canvas.drawCircle(Offset(px, py), r * 1.8, paint);

      paint.color = _gold.withValues(alpha: alpha);
      canvas.drawPath(_starPath(Offset(px, py), r), paint);
    }
  }

  /// Four-point star: 8 vertices alternating outer/inner radius.
  static Path _starPath(Offset c, double r) {
    final inner = r * 0.28;
    final path = Path();
    for (var i = 0; i < 8; i++) {
      final radius = i.isEven ? r : inner;
      final angle = -math.pi / 2 + i * math.pi / 4;
      final p = Offset(
          c.dx + radius * math.cos(angle), c.dy + radius * math.sin(angle));
      if (i == 0) {
        path.moveTo(p.dx, p.dy);
      } else {
        path.lineTo(p.dx, p.dy);
      }
    }
    return path..close();
  }

  @override
  bool shouldRepaint(_StarPainter old) => old.t != t;
}
