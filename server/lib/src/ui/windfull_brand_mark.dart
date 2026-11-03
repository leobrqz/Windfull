import 'package:flutter/material.dart';

import 'windfull_theme.dart';

/// The WindFull mark: three calm air currents gathered into one clear route.
class WindfullBrandMark extends StatelessWidget {
  const WindfullBrandMark({this.size = 36, super.key});

  final double size;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      gradient: const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [Color(0xFF23383A), Color(0xFF172326)],
      ),
      borderRadius: BorderRadius.circular(size * .31),
    ),
    child: CustomPaint(painter: _WindfullMarkPainter()),
  );
}

class _WindfullMarkPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 36, size.height / 36);
    final path = Path()
      ..moveTo(8.15, 12.59)
      ..cubicTo(10.04, 12.59, 10.08, 23.72, 13.65, 23.72)
      ..cubicTo(17.31, 23.72, 16.99, 12.72, 19.52, 12.72)
      ..cubicTo(22.28, 12.72, 22.18, 24.42, 25.59, 24.42)
      ..cubicTo(28.27, 24.42, 29.20, 17.06, 31.64, 15.28);
    final halo = Paint()
      ..color = WindfullTheme.accent.withValues(alpha: .16)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 5.2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2.5);
    canvas.drawPath(path, halo);
    final stroke = Paint()
      ..shader = const LinearGradient(
        colors: [Color(0xFF5BC5BC), Color(0xFFBEF6E6)],
      ).createShader(const Rect.fromLTWH(7, 8, 26, 20))
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.55
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawPath(path, stroke);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _WindfullMarkPainter oldDelegate) => false;
}
