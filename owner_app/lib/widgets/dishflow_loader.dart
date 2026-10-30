import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../theme.dart';
import 'dishflow_brand.dart';

/// Animated Dishflow mark used for every full-screen / dialog load.
class DishflowLoader extends StatefulWidget {
  const DishflowLoader({
    super.key,
    this.size = 72,
    this.label,
    this.onDark = false,
  });

  final double size;
  final String? label;
  final bool onDark;

  @override
  State<DishflowLoader> createState() => _DishflowLoaderState();
}

class _DishflowLoaderState extends State<DishflowLoader>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final muted = widget.onDark
        ? Colors.white.withValues(alpha: 0.7)
        : AppColors.muted;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: widget.size * 1.35,
          height: widget.size * 1.35,
          child: AnimatedBuilder(
            animation: _c,
            builder: (context, child) {
              final t = _c.value;
              final pulse = 0.92 + 0.08 * math.sin(t * math.pi * 2);
              return Stack(
                alignment: Alignment.center,
                children: [
                  Transform.rotate(
                    angle: t * math.pi * 2,
                    child: CustomPaint(
                      size: Size(widget.size * 1.35, widget.size * 1.35),
                      painter: _OrbitPainter(
                        color: AppColors.sky.withValues(alpha: 0.35),
                      ),
                    ),
                  ),
                  Transform.scale(
                    scale: pulse,
                    child: child,
                  ),
                ],
              );
            },
            child: DishflowBrandIcon(size: widget.size),
          ),
        ),
        if (widget.label != null) ...[
          const SizedBox(height: 14),
          Text(
            widget.label!,
            style: GoogleFonts.cairo(
              color: muted,
              fontWeight: FontWeight.w700,
              fontSize: 14,
            ),
          ),
        ],
      ],
    );
  }
}

class _OrbitPainter extends CustomPainter {
  _OrbitPainter({required this.color});
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    final r = size.shortestSide / 2;
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(
      Rect.fromCircle(center: c, radius: r - 2),
      -math.pi / 2,
      math.pi * 1.35,
      false,
      paint,
    );
    final tip = Offset(
      c.dx + (r - 2) * math.cos(-math.pi / 2 + math.pi * 1.35),
      c.dy + (r - 2) * math.sin(-math.pi / 2 + math.pi * 1.35),
    );
    canvas.drawCircle(tip, 4.5, Paint()..color = AppColors.skyDark);
  }

  @override
  bool shouldRepaint(covariant _OrbitPainter oldDelegate) =>
      oldDelegate.color != color;
}

/// Centered loader for Scaffold bodies / dialogs.
class DishflowLoadingBody extends StatelessWidget {
  const DishflowLoadingBody({
    super.key,
    this.label,
    this.onDark = false,
  });

  final String? label;
  final bool onDark;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: DishflowLoader(
        label: label,
        onDark: onDark,
      ),
    );
  }
}

/// Blocking dialog with the animated Dishflow mark.
Future<T?> showDishflowLoadingDialog<T>(
  BuildContext context, {
  String? label,
}) {
  return showDialog<T>(
    context: context,
    barrierDismissible: false,
    barrierColor: const Color(0xFF0F172A).withValues(alpha: 0.45),
    builder: (_) => PopScope(
      canPop: false,
      child: Center(
        child: Material(
          color: Colors.white,
          borderRadius: BorderRadius.circular(24),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(28, 28, 28, 24),
            child: DishflowLoader(label: label, size: 64),
          ),
        ),
      ),
    ),
  );
}
