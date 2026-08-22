import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../online/audio_output_bridge.dart';

/// Lucide-style call-output glyphs painted in a 24×24 view box.
///
/// Speaker = filled Volume2, earpiece = phone handset, mute = VolumeX,
/// headset = Headphones.
class LucideAudioGlyph extends StatelessWidget {
  const LucideAudioGlyph({
    super.key,
    required this.kind,
    required this.color,
    required this.size,
  });

  final AudioOutputGlyphKind kind;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _LucideAudioPainter(kind: kind, color: color),
      ),
    );
  }
}

class _LucideAudioPainter extends CustomPainter {
  const _LucideAudioPainter({required this.kind, required this.color});

  final AudioOutputGlyphKind kind;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.shortestSide / 24;
    canvas
      ..save()
      ..scale(scale);

    switch (kind) {
      case AudioOutputGlyphKind.speaker:
        _paintVolume(canvas, filled: true, waves: true, muted: false);
      case AudioOutputGlyphKind.earpiece:
        _paintPhone(canvas);
      case AudioOutputGlyphKind.muted:
        _paintVolume(canvas, filled: false, waves: false, muted: true);
      case AudioOutputGlyphKind.headset:
        _paintHeadphones(canvas);
    }

    canvas.restore();
  }

  void _paintVolume(
    Canvas canvas, {
    required bool filled,
    required bool waves,
    required bool muted,
  }) {
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final body = Path()
      ..moveTo(11, 5)
      ..lineTo(6.6, 8.2)
      ..lineTo(3, 8.2)
      ..lineTo(3, 15.8)
      ..lineTo(6.6, 15.8)
      ..lineTo(11, 19)
      ..close();

    if (filled) {
      canvas.drawPath(
        body,
        Paint()
          ..color = color
          ..style = PaintingStyle.fill
          ..strokeJoin = StrokeJoin.round,
      );
    }
    canvas.drawPath(body, stroke);

    if (waves) {
      final inner = Path()
        ..addArc(
          Rect.fromCircle(center: const Offset(13.2, 12), radius: 4.2),
          -0.85,
          1.7,
        );
      final outer = Path()
        ..addArc(
          Rect.fromCircle(center: const Offset(13.2, 12), radius: 7.6),
          -0.95,
          1.9,
        );
      canvas
        ..drawPath(inner, stroke)
        ..drawPath(outer, stroke);
    }

    if (muted) {
      canvas
        ..drawLine(const Offset(16, 9), const Offset(22, 15), stroke)
        ..drawLine(const Offset(22, 9), const Offset(16, 15), stroke);
    }
  }

  void _paintHeadphones(Canvas canvas) {
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    canvas.drawArc(
      const Rect.fromLTWH(3, 3, 18, 18),
      math.pi,
      math.pi,
      false,
      stroke,
    );

    final cup = RRect.fromLTRBR(3, 14, 8, 21, const Radius.circular(2));
    final cupRight = RRect.fromLTRBR(16, 14, 21, 21, const Radius.circular(2));
    canvas
      ..drawRRect(cup, stroke)
      ..drawRRect(cupRight, stroke);
  }

  void _paintPhone(Canvas canvas) {
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final handset = Path()
      ..moveTo(6.6, 3.5)
      ..cubicTo(5.1, 3.5, 4, 4.7, 4, 6.1)
      ..cubicTo(4, 13.8, 10.2, 20, 17.9, 20)
      ..cubicTo(19.3, 20, 20.5, 18.9, 20.5, 17.4)
      ..lineTo(20.5, 15.2)
      ..lineTo(15.7, 13.8)
      ..lineTo(14.2, 16.2)
      ..cubicTo(11.5, 15, 9, 12.5, 7.8, 9.8)
      ..lineTo(10.2, 8.3)
      ..lineTo(8.8, 3.5)
      ..close();
    canvas.drawPath(handset, stroke);
  }

  @override
  bool shouldRepaint(covariant _LucideAudioPainter oldDelegate) {
    return oldDelegate.kind != kind || oldDelegate.color != color;
  }
}
