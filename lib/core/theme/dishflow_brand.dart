import 'package:flutter/material.dart';

import 'app_colors.dart';

/// DishFlow brand name as shown on the till.
abstract final class DishflowBrand {
  static const name = 'Dishflow';
}

/// Compact DishFlow mark (sky ring + receipt) for app bars and strips.
class DishflowBrandIcon extends StatelessWidget {
  const DishflowBrandIcon({super.key, this.size = 28});

  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.center,
        children: [
          Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: const SweepGradient(
                startAngle: 0.8,
                endAngle: 5.6,
                colors: [
                  AppColors.primaryLight,
                  AppColors.primary,
                  AppColors.primaryDark,
                  AppColors.primaryLight,
                ],
              ),
              boxShadow: [
                BoxShadow(
                  color: AppColors.primary.withValues(alpha: 0.35),
                  blurRadius: size * 0.18,
                  offset: Offset(0, size * 0.06),
                ),
              ],
            ),
          ),
          CustomPaint(
            size: Size(size, size),
            painter: _PlateRingPainter(),
          ),
          Positioned(
            top: size * 0.06,
            right: size * 0.02,
            child: Container(
              width: size * 0.34,
              height: size * 0.42,
              padding: EdgeInsets.symmetric(
                horizontal: size * 0.05,
                vertical: size * 0.04,
              ),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(size * 0.05),
                border: Border.all(color: AppColors.primary, width: 1.2),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(
                  3,
                  (_) => Container(
                    margin: EdgeInsets.only(bottom: size * 0.025),
                    height: size * 0.028,
                    decoration: BoxDecoration(
                      color: AppColors.primary,
                      borderRadius: BorderRadius.circular(1),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Logo + wordmark for headers (floor strip, login).
class DishflowBrandMark extends StatelessWidget {
  const DishflowBrandMark({
    super.key,
    this.height = 28,
    this.showSubtitle = false,
  });

  final double height;
  final bool showSubtitle;

  @override
  Widget build(BuildContext context) {
    final onSurface = Theme.of(context).colorScheme.onSurface;
    final muted = Theme.of(context).brightness == Brightness.dark
        ? AppColors.textSecondaryDark
        : AppColors.textMutedLight;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        DishflowBrandIcon(size: height),
        SizedBox(width: height * 0.28),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              DishflowBrand.name,
              style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: height * 0.55,
                fontWeight: FontWeight.w700,
                color: onSurface,
                height: 1.05,
              ),
            ),
            if (showSubtitle)
              Text(
                'RESTAURANT POS',
                style: TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: height * 0.22,
                  fontWeight: FontWeight.w600,
                  color: muted,
                  letterSpacing: 1.2,
                ),
              ),
          ],
        ),
      ],
    );
  }
}

class _PlateRingPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width * 0.36;
    final paint = Paint()
      ..color = Colors.white.withValues(alpha: 0.92)
      ..style = PaintingStyle.stroke
      ..strokeWidth = size.width * 0.07
      ..strokeCap = StrokeCap.round;

    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      -0.6,
      5.2,
      false,
      paint,
    );

    final arrow = Path()
      ..moveTo(size.width * 0.78, size.height * 0.72)
      ..lineTo(size.width * 0.9, size.height * 0.86)
      ..lineTo(size.width * 0.72, size.height * 0.88);
    canvas.drawPath(arrow, paint..style = PaintingStyle.fill);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
