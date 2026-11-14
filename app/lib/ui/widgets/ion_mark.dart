import "dart:math" as math;

import "package:material_ui/material_ui.dart";

/// The Ion mark: three crossed orbits.
class IonMark extends StatelessWidget {
  const IonMark({super.key, required this.color, this.size = 14});

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) => CustomPaint(size: Size.square(size), painter: _MarkPainter(color));
}

class _MarkPainter extends CustomPainter {
  _MarkPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = size.width / 12;
    final c = size.center(Offset.zero);
    for (var i = 0; i < 3; i++) {
      canvas.save();
      canvas.translate(c.dx, c.dy);
      canvas.rotate(i * math.pi / 3);
      canvas.drawOval(Rect.fromCenter(center: Offset.zero, width: size.width * 0.83, height: size.height * 0.33), paint);
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_MarkPainter old) => old.color != color;
}
