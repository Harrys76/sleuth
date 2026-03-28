import 'package:flutter/material.dart';

import '../models/frame_stats.dart';

/// A 60-frame bar chart showing frame times with jank highlighting.
class FrameChart extends StatelessWidget {
  const FrameChart({super.key, required this.buffer});

  final FrameStatsBuffer buffer;

  @override
  Widget build(BuildContext context) {
    final frames = buffer.frames;
    if (frames.isEmpty) {
      return const Center(
        child: Text(
          'Waiting for frames...',
          style: TextStyle(color: Color(0xFF6B7280), fontSize: 12),
        ),
      );
    }

    return CustomPaint(
      painter: _FrameChartPainter(frames: frames),
      size: Size.infinite,
    );
  }
}

class _FrameChartPainter extends CustomPainter {
  _FrameChartPainter({required this.frames});

  final List<FrameStats> frames;

  static const _greenColor = Color(0xFF10B981);
  static const _yellowColor = Color(0xFFF59E0B);
  static const _redColor = Color(0xFFEF4444);
  static const _budgetColor = Color(0xFF4B5563);

  @override
  void paint(Canvas canvas, Size size) {
    if (frames.isEmpty) return;

    final barWidth = size.width / 60;
    final maxMs = 50.0; // Cap at 50ms for display
    final budgetMs = frames.first.frameBudgetMs.toDouble();
    final budgetY = size.height * (1 - budgetMs / maxMs);

    // Draw budget line
    final budgetPaint = Paint()
      ..color = _budgetColor
      ..strokeWidth = 1;
    canvas.drawLine(
      Offset(0, budgetY),
      Offset(size.width, budgetY),
      budgetPaint,
    );

    // Draw bars
    for (var i = 0; i < frames.length && i < 60; i++) {
      final frame = frames[i];
      final ms = frame.effectiveTotalDuration.inMilliseconds.toDouble();
      final normalizedMs = ms.clamp(0, maxMs);
      final barHeight = (normalizedMs / maxMs) * size.height;

      final budget = frame.frameBudgetMs;
      Color color;
      if (ms >= budget * 2) {
        color = _redColor;
      } else if (ms >= budget) {
        color = _yellowColor;
      } else {
        color = _greenColor;
      }

      final paint = Paint()..color = color;
      final x = i * barWidth;
      canvas.drawRRect(
        RRect.fromRectAndCorners(
          Rect.fromLTWH(
            x + 1,
            size.height - barHeight,
            barWidth - 2,
            barHeight,
          ),
          topLeft: const Radius.circular(2),
          topRight: const Radius.circular(2),
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_FrameChartPainter oldDelegate) =>
      oldDelegate.frames.length != frames.length ||
      (frames.isNotEmpty &&
          oldDelegate.frames.isNotEmpty &&
          oldDelegate.frames.last.frameNumber != frames.last.frameNumber);
}
