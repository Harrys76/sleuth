import 'package:flutter/material.dart';

import '../models/frame_stats.dart';
import '../models/performance_issue.dart';
import 'floating_issues_card.dart' show fpsColor;

/// Draggable 🐕 trigger button with issue count badge and live FPS number.
///
/// - Green: no issues / FPS ≥ 50
/// - Amber: warnings only / FPS 30–50
/// - Red: critical issues / FPS < 30
/// - ⚠️ badge: debug mode
class TriggerButton extends StatefulWidget {
  const TriggerButton({
    super.key,
    required this.issuesNotifier,
    required this.vmConnectedNotifier,
    required this.frameStatsNotifier,
    required this.isDebugMode,
    required this.onTap,
  });

  final ValueNotifier<List<PerformanceIssue>> issuesNotifier;
  final ValueNotifier<bool> vmConnectedNotifier;
  final ValueNotifier<FrameStatsBuffer> frameStatsNotifier;
  final bool isDebugMode;
  final VoidCallback onTap;

  @override
  State<TriggerButton> createState() => _TriggerButtonState();
}

class _TriggerButtonState extends State<TriggerButton> {
  Offset _position = const Offset(16, 100);

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) => GestureDetector(
        onPanUpdate: (details) {
          setState(() {
            final newPos = _position + details.delta;
            _position = Offset(
              newPos.dx.clamp(0, constraints.maxWidth - 56),
              newPos.dy.clamp(0, constraints.maxHeight - 78),
            );
          });
        },
        onTap: widget.onTap,
        child: Container(
          margin: EdgeInsets.only(left: _position.dx, top: _position.dy),
          width: 56,
          height: 78,
          child: ValueListenableBuilder<List<PerformanceIssue>>(
            valueListenable: widget.issuesNotifier,
            builder: (context, issues, _) {
              final hasCritical =
                  issues.any((i) => i.severity == IssueSeverity.critical);
              final hasWarning =
                  issues.any((i) => i.severity == IssueSeverity.warning);

              Color bgColor;
              if (hasCritical) {
                bgColor = const Color(0xFFEF4444); // red
              } else if (hasWarning) {
                bgColor = const Color(0xFFF59E0B); // amber
              } else {
                bgColor = const Color(0xFF10B981); // green
              }

              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Circle button
                  Container(
                    width: 56,
                    height: 56,
                    decoration: BoxDecoration(
                      color: bgColor,
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: bgColor.withValues(alpha: 0.4),
                          blurRadius: 12,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        const Text('🐕', style: TextStyle(fontSize: 24)),
                        if (issues.isNotEmpty && !widget.isDebugMode)
                          Positioned(
                            top: 2,
                            right: 2,
                            child: Container(
                              padding: const EdgeInsets.all(4),
                              decoration: const BoxDecoration(
                                color: Color(0xFF1F2937),
                                shape: BoxShape.circle,
                              ),
                              child: Text(
                                '${issues.length}',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ),
                        if (widget.isDebugMode)
                          Positioned(
                            top: 0,
                            right: 0,
                            child: Container(
                              padding: const EdgeInsets.all(2),
                              decoration: const BoxDecoration(
                                color: Color(0xFFF59E0B),
                                shape: BoxShape.circle,
                              ),
                              child: const Text('⚠️',
                                  style: TextStyle(fontSize: 10)),
                            ),
                          ),
                      ],
                    ),
                  ),
                  // FPS number below the circle
                  const SizedBox(height: 2),
                  ValueListenableBuilder<FrameStatsBuffer>(
                    valueListenable: widget.frameStatsNotifier,
                    builder: (_, buffer, __) {
                      final fps = buffer.averageFps;
                      return Text(
                        fps.toStringAsFixed(0),
                        style: TextStyle(
                          color: fpsColor(fps),
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          shadows: const [
                            Shadow(
                              color: Color(0xCC000000),
                              blurRadius: 4,
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
