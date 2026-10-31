import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/i18n/l10n.dart';
import '../core/theme/app_colors.dart';

/// The sign-in page's picture: a drawn dashboard on the brand's navy, with
/// what the site is for underneath.
class LoginArt extends StatelessWidget {
  const LoginArt({super.key});

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [AppColors.brandNavy, Color(0xFF0B3B5C), AppColors.primaryDark],
        ),
      ),
      child: Stack(children: [
        const Positioned.fill(child: CustomPaint(painter: _GlowPainter())),
        Padding(
          padding: const EdgeInsets.all(48),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              const Icon(Icons.insights, color: Colors.white, size: 28),
              const SizedBox(width: 10),
              Text('Dishflow',
                  style: text.titleLarge
                      ?.copyWith(color: Colors.white, fontWeight: FontWeight.w700)),
            ]),
            const Spacer(),
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 480),
                child: const _DashboardMock(),
              ),
            ),
            const Spacer(),
            Text(tr(context, "Every branch's figures, as they happen"),
                style: text.headlineSmall
                    ?.copyWith(color: Colors.white, fontWeight: FontWeight.w700)),
            const SizedBox(height: 16),
            for (final line in const [
              'Sales from every till arrive on their own',
              'The same reports as the till',
              'Each account sees only what it is allowed to',
            ])
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Row(children: [
                  const Icon(Icons.check_circle, color: AppColors.primaryLight, size: 20),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(tr(context, line),
                        style: text.bodyLarge?.copyWith(color: Colors.white70)),
                  ),
                ]),
              ),
          ]),
        ),
      ]),
    );
  }
}

class _DashboardMock extends StatelessWidget {
  const _DashboardMock();

  @override
  Widget build(BuildContext context) => Directionality(
        textDirection: TextDirection.ltr,
        child: Stack(clipBehavior: Clip.none, children: [
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(20),
              boxShadow: const [
                BoxShadow(color: Color(0x55000000), blurRadius: 40, offset: Offset(0, 20)),
              ],
            ),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Row(children: [
                Expanded(child: _Kpi(Icons.payments_outlined, '24,860', AppColors.primary)),
                SizedBox(width: 12),
                Expanded(child: _Kpi(Icons.receipt_long_outlined, '312', AppColors.success)),
                SizedBox(width: 12),
                Expanded(child: _Kpi(Icons.storefront_outlined, '3', AppColors.warning)),
              ]),
              const SizedBox(height: 20),
              const SizedBox(
                height: 130,
                width: double.infinity,
                child: CustomPaint(painter: _ChartPainter()),
              ),
              const SizedBox(height: 20),
              Row(children: [
                const SizedBox.square(dimension: 64, child: CustomPaint(painter: _DonutPainter())),
                const SizedBox(width: 20),
                Expanded(
                  child: Column(children: [
                    for (final (color, width) in const [
                      (AppColors.primary, 1.0),
                      (AppColors.success, 0.7),
                      (AppColors.warning, 0.45),
                    ])
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Row(children: [
                          Container(
                            width: 10,
                            height: 10,
                            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: FractionallySizedBox(
                              alignment: Alignment.centerLeft,
                              widthFactor: width,
                              child: Container(
                                height: 8,
                                decoration: BoxDecoration(
                                  color: AppColors.surface,
                                  borderRadius: BorderRadius.circular(4),
                                ),
                              ),
                            ),
                          ),
                        ]),
                      ),
                  ]),
                ),
              ]),
            ]),
          ),
          Positioned(
            right: -18,
            top: -22,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(14),
                boxShadow: const [
                  BoxShadow(color: Color(0x40000000), blurRadius: 20, offset: Offset(0, 8)),
                ],
              ),
              child: const Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.trending_up, color: AppColors.success, size: 20),
                SizedBox(width: 6),
                Text('+18%',
                    style: TextStyle(
                        color: AppColors.success, fontWeight: FontWeight.w700, fontSize: 16)),
              ]),
            ),
          ),
        ]),
      );
}

class _Kpi extends StatelessWidget {
  const _Kpi(this.icon, this.value, this.color);

  final IconData icon;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(height: 8),
          Text(value,
              style: const TextStyle(
                  color: AppColors.textPrimaryLight, fontWeight: FontWeight.w700, fontSize: 16)),
          const SizedBox(height: 6),
          Container(
            height: 4,
            width: 36,
            decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(2)),
          ),
        ]),
      );
}

class _ChartPainter extends CustomPainter {
  const _ChartPainter();

  static const _bars = [0.45, 0.62, 0.5, 0.78, 0.66, 0.9, 0.72];
  static const _line = [0.3, 0.42, 0.38, 0.55, 0.5, 0.7, 0.64];

  @override
  void paint(Canvas canvas, Size size) {
    final grid = Paint()
      ..color = AppColors.surface
      ..strokeWidth = 1;
    for (var i = 0; i <= 3; i++) {
      final y = size.height * i / 3;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }

    final slot = size.width / _bars.length;
    final barWidth = slot * 0.5;
    for (var i = 0; i < _bars.length; i++) {
      final h = size.height * _bars[i];
      final rect = Rect.fromLTWH(
          slot * i + (slot - barWidth) / 2, size.height - h, barWidth, h);
      canvas.drawRRect(
        RRect.fromRectAndCorners(rect,
            topLeft: const Radius.circular(6), topRight: const Radius.circular(6)),
        Paint()
          ..shader = const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [AppColors.primaryLight, AppColors.primaryDark],
          ).createShader(rect),
      );
    }

    final points = [
      for (var i = 0; i < _line.length; i++)
        Offset(slot * i + slot / 2, size.height * (1 - _line[i]) - 18),
    ];
    final path = Path()..moveTo(points.first.dx, points.first.dy);
    for (var i = 1; i < points.length; i++) {
      final a = points[i - 1], b = points[i];
      final mid = (a.dx + b.dx) / 2;
      path.cubicTo(mid, a.dy, mid, b.dy, b.dx, b.dy);
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = AppColors.warning
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round,
    );
    for (final p in points) {
      canvas.drawCircle(p, 4.5, Paint()..color = Colors.white);
      canvas.drawCircle(
        p,
        4.5,
        Paint()
          ..color = AppColors.warning
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5,
      );
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _DonutPainter extends CustomPainter {
  const _DonutPainter();

  @override
  void paint(Canvas canvas, Size size) {
    const stroke = 12.0;
    final rect = Offset.zero & size;
    final arc = rect.deflate(stroke / 2);
    var start = -math.pi / 2;
    for (final (share, color) in const [
      (0.5, AppColors.primary),
      (0.3, AppColors.success),
      (0.2, AppColors.warning),
    ]) {
      final sweep = 2 * math.pi * share;
      canvas.drawArc(
        arc,
        start + 0.06,
        sweep - 0.12,
        false,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = stroke
          ..strokeCap = StrokeCap.round,
      );
      start += sweep;
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _GlowPainter extends CustomPainter {
  const _GlowPainter();

  @override
  void paint(Canvas canvas, Size size) {
    for (final (center, radius, alpha) in [
      (Offset(size.width * 0.9, size.height * 0.1), size.shortestSide * 0.45, 0.18),
      (Offset(size.width * 0.05, size.height * 0.85), size.shortestSide * 0.5, 0.12),
    ]) {
      canvas.drawCircle(
        center,
        radius,
        Paint()
          ..shader = RadialGradient(colors: [
            AppColors.primaryLight.withValues(alpha: alpha),
            AppColors.primaryLight.withValues(alpha: 0),
          ]).createShader(Rect.fromCircle(center: center, radius: radius)),
      );
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
